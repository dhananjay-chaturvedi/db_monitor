#!/usr/bin/env bash
# lib/gcp.sh — GCP Cloud SQL monitoring via gcloud CLI
# All calls use gcloud --format=value(...) so no JSON parser is needed.
# GCP credential chain (ADC > service account > metadata server) handled by gcloud.

# shellcheck source=../../common/lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/util.sh"
# shellcheck source=../../common/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/config.sh"

# ---------- project / region resolution ----------

_GCP_EFFECTIVE_PROJECT_CACHE=""

# gcp_effective_project → project id from gcloud config (or CLOUDSDK_CORE_PROJECT env)
gcp_effective_project() {
    if [[ -n "${CLOUDSDK_CORE_PROJECT:-}" ]]; then
        echo "$CLOUDSDK_CORE_PROJECT"
        return
    fi
    if [[ -n "${_GCP_EFFECTIVE_PROJECT_CACHE:-}" ]]; then
        echo "$_GCP_EFFECTIVE_PROJECT_CACHE"
        return
    fi
    local proj
    proj=$(gcloud config get-value project 2>/dev/null || true)
    if [[ -n "$proj" && "$proj" != "(unset)" ]]; then
        _GCP_EFFECTIVE_PROJECT_CACHE="$proj"
        echo "$proj"
        return
    fi
    # Older SDK: gcloud config get project
    proj=$(gcloud config get project 2>/dev/null || true)
    if [[ -n "$proj" && "$proj" != "(unset)" ]]; then
        _GCP_EFFECTIVE_PROJECT_CACHE="$proj"
        echo "$proj"
        return
    fi
    echo "unknown"
    # Don't cache "unknown" — allow retry on next call
}

_GCP_EFFECTIVE_REGION_CACHE=""

# gcp_effective_region → region from env, gcloud config, or GCE metadata server
# Result is cached per-process to avoid repeated gcloud/curl calls.
gcp_effective_region() {
    if [[ -n "${_GCP_EFFECTIVE_REGION_CACHE:-}" ]]; then
        echo "$_GCP_EFFECTIVE_REGION_CACHE"
        return
    fi
    if [[ -n "${CLOUDSDK_COMPUTE_REGION:-}" ]]; then
        _GCP_EFFECTIVE_REGION_CACHE="$CLOUDSDK_COMPUTE_REGION"
        echo "$_GCP_EFFECTIVE_REGION_CACHE"
        return
    fi
    local region
    region=$(gcloud config get-value compute/region 2>/dev/null || true)
    if [[ -n "$region" && "$region" != "(unset)" ]]; then
        _GCP_EFFECTIVE_REGION_CACHE="$region"
        echo "$_GCP_EFFECTIVE_REGION_CACHE"
        return
    fi
    # Attempt GCE metadata server: zone looks like projects/PROJECT/zones/ZONE
    local zone
    zone=$(curl -s --connect-timeout 1 \
        -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/zone" 2>/dev/null || true)
    if [[ -n "$zone" ]]; then
        # zone = projects/PROJECT_NUM/zones/REGION-ZONE_LETTER  →  strip last character for region
        local z; z="${zone##*/}"          # e.g. us-central1-a
        region="${z%-*}"                  # e.g. us-central1
        if [[ -n "$region" ]]; then
            _GCP_EFFECTIVE_REGION_CACHE="$region"
            echo "$_GCP_EFFECTIVE_REGION_CACHE"
            return
        fi
    fi
    # Don't cache "unknown" — allow retry on next call
    echo "unknown"
}

# ---------- time helpers ----------

# _gcp_start_time MINUTES → ISO8601 timestamp N minutes ago (GNU date and BSD date)
_gcp_start_time() {
    local minutes="${1:-10}"
    date -u -d "${minutes} minutes ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v-"${minutes}"M '+%Y-%m-%dT%H:%M:%SZ'
}

# _gcp_now → current UTC ISO8601
_gcp_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------- config helpers ----------

# _lookback_minutes → mcfgi cloud lookback_minutes 10
_lookback_minutes() {
    mcfgi 'cloud' lookback_minutes 10
}

# _metric_period → mcfgi cloud metric_period_seconds 60
_metric_period() {
    mcfgi 'cloud' metric_period_seconds 60
}

# _metric_fetch_timeout_seconds → mcfgi cloud metric_fetch_timeout_seconds 30
_metric_fetch_timeout_seconds() {
    mcfgi 'cloud' metric_fetch_timeout_seconds 30
}

# ---------- shared fetch budget ----------

# Shared fetch budget for one instance pass (Cloud Monitoring).
_GCP_METRIC_FETCH_DEADLINE=0

# gcp_metric_fetch_deadline_begin — start shared timeout budget for GCP metric fetches
gcp_metric_fetch_deadline_begin() {
    local t; t=$(_metric_fetch_timeout_seconds)
    if [[ "$t" -gt 0 ]]; then
        _GCP_METRIC_FETCH_DEADLINE=$(( $(date +%s) + t ))
    else
        _GCP_METRIC_FETCH_DEADLINE=0
    fi
}

# gcp_metric_fetch_deadline_end — clear shared fetch budget
gcp_metric_fetch_deadline_end() {
    _GCP_METRIC_FETCH_DEADLINE=0
}

# _gcp_metric_fetch_call_timeout — seconds for the next API call (remaining budget or per-call max)
_gcp_metric_fetch_call_timeout() {
    local max; max=$(_metric_fetch_timeout_seconds)
    [[ "$max" -le 0 ]] && { echo 0; return; }
    if [[ "${_GCP_METRIC_FETCH_DEADLINE:-0}" -gt 0 ]]; then
        local now rem; now=$(date +%s)
        rem=$(( _GCP_METRIC_FETCH_DEADLINE - now ))
        [[ "$rem" -le 0 ]] && { echo 0; return; }
        echo "$rem"
        return
    fi
    echo "$max"
}

# _gcp_metric_fetch_budget_exhausted — true when shared deadline elapsed
_gcp_metric_fetch_budget_exhausted() {
    [[ "${_GCP_METRIC_FETCH_DEADLINE:-0}" -gt 0 ]] || return 1
    [[ "$(_gcp_metric_fetch_call_timeout)" -le 0 ]]
}

# ---------- command wrapper ----------

# _gcp_cmd_timeout SECS CMD... — wraps with timeout(1) if available and SECS > 0
_gcp_cmd_timeout() {
    local secs="$1"; shift
    [[ "$secs" -gt 0 ]] || { "$@"; return $?; }
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# ---------- engine filter ----------

# _engine_matches TYPE ENGINES_CSV → 0 when the instance engine is included in the list
_engine_matches() {
    local type="${1,,}" engines="${2,,}"
    [[ -z "$engines" || "$engines" == "all" ]] && return 0
    local part
    IFS=',' read -ra _eng_parts <<< "$engines"
    for part in "${_eng_parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ "$part" == "$type" ]] && return 0
    done
    return 1
}

# ---------- Cloud SQL instance info ----------

# cloudsql_instance_status INSTANCE_NAME [PROJECT]
# Prints: STATUS<TAB>DB_VERSION  (e.g. "RUNNABLE	MYSQL_8_0")
# On error prints: "unknown	unknown"
cloudsql_instance_status() {
    local instance="$1" project="${2:-}"
    local proj_flag=()
    [[ -n "$project" ]] && proj_flag=(--project "$project")

    local out rc=0
    out=$(gcloud sql instances describe "$instance" \
        --format="value(state,databaseVersion)" \
        "${proj_flag[@]}" 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 || -z "$out" ]]; then
        printf 'unknown\tunknown\n'
        return
    fi
    # gcloud --format=value with multiple fields outputs tab-separated on one line
    printf '%s\n' "$out"
}

# cloudsql_instance_tier INSTANCE_NAME [PROJECT]
# Prints the machine type / tier string (e.g. "db-n1-standard-2")
cloudsql_instance_tier() {
    local instance="$1" project="${2:-}"
    local proj_flag=()
    [[ -n "$project" ]] && proj_flag=(--project "$project")

    gcloud sql instances describe "$instance" \
        --format="value(settings.tier)" \
        "${proj_flag[@]}" 2>/dev/null || true
}

# ---------- Cloud Monitoring time-series fetch ----------

# _gcp_monitoring_fetch INSTANCE_NAME PROJECT METRIC_TYPE PERIOD_SECONDS LOOKBACK_MINUTES
# Fetches the most recent datapoint for a single Cloud Monitoring metric via
# gcloud beta monitoring timeseries list.
# Prints KEY<TAB>VALUE<TAB>UNIT on success; prints nothing on failure or empty data.
# Caller is responsible for printing KEY / UNIT; this function only prints raw VALUE.
# Actually: caller passes KEY and UNIT via _gcp_batch_fetch_metrics; this function
# returns the raw numeric value string, or empty on miss.
_gcp_monitoring_fetch() {
    local instance="$1" project="$2" metric_type="$3"
    local period="${4:-60}" lookback="${5:-10}"
    local start end val rc=0

    start=$(_gcp_start_time "$lookback")
    end=$(_gcp_now)

    local call_to; call_to=$(_gcp_metric_fetch_call_timeout)

    # Build the filter: match metric type AND the Cloud SQL resource label database_id = PROJECT:INSTANCE
    local filter
    filter="metric.type=\"${metric_type}\" AND resource.labels.database_id=\"${project}:${instance}\""

    local raw
    raw=$(_gcp_cmd_timeout "$call_to" \
        gcloud beta monitoring timeseries list \
            --filter="$filter" \
            --interval-start-time="$start" \
            --interval-end-time="$end" \
            --format='json(points[-1].value)' \
            --project="$project" \
        2>/dev/null) || rc=$?

    if [[ "$rc" -eq 124 ]]; then
        return 124
    fi

    # Extract doubleValue or int64Value from JSON output
    val=$(printf '%s' "$raw" | \
        grep -oE '"(doubleValue|int64Value)": *[0-9eE.+-]+' | head -1 | \
        grep -oE '[0-9eE.+-]+$' || true)
    val="${val//[[:space:]]/}"
    [[ -z "$val" || "$val" == "None" ]] && return 1

    printf '%s' "$val"
    return 0
}

# ---------- INI-driven metric query file ----------

# _gcp_build_metric_query_file INSTANCE PROJECT DB_TYPE OUTFILE
# Reads [metric.gcp.monitoring.CloudSQL.*] sections from metrics_and_thresholds.ini
# (with per-instance overlay via thresh_ini_get/thresh_ini_sections).
# For each section with collect=true that matches DB_TYPE, writes:
#   RULE_KEY<TAB>FULL_METRIC_TYPE<TAB>UNIT
# to OUTFILE.  metric_name field must hold the full GCP metric type,
# e.g. cloudsql.googleapis.com/database/cpu/utilization
_gcp_build_metric_query_file() {
    local instance="$1" project="$2" db_type="${3,,}" outfile="$4"

    : > "$outfile"
    local section collect engines metric_name unit rule_key

    while IFS= read -r section; do
        [[ "$section" =~ ^metric\.gcp\.monitoring\.CloudSQL\. ]] || continue

        collect=$(thresh_ini_get "$instance" "$section" "collect" "false")
        [[ "${collect,,}" == "true" ]] || continue

        engines=$(thresh_ini_get "$instance" "$section" "engines" "all")
        _engine_matches "$db_type" "$engines" || continue

        metric_name=$(thresh_ini_get "$instance" "$section" "metric_name" "")
        [[ -z "$metric_name" ]] && continue

        unit=$(thresh_ini_get "$instance" "$section" "unit" "")
        rule_key="${section##*.}"

        printf '%s\t%s\t%s\n' "$rule_key" "$metric_name" "$unit" >> "$outfile"
    done < <(thresh_ini_sections "$instance")
}

# ---------- batch metric fetch ----------

# _gcp_batch_fetch_metrics INSTANCE_NAME PROJECT DB_TYPE QUERY_FILE PERIOD LOOKBACK
# Reads QUERY_FILE (KEY<TAB>METRIC_TYPE<TAB>UNIT lines).
# For each line calls _gcp_monitoring_fetch and prints KEY<TAB>VALUE<TAB>UNIT.
# Respects budget exhaustion; exits early when budget is gone.
_gcp_batch_fetch_metrics() {
    local instance="$1" project="$2" db_type="$3" query_file="$4"
    local period="${5:-$(_metric_period)}" lookback="${6:-$(_lookback_minutes)}"
    local line rule_key metric_type unit val rc

    [[ ! -s "$query_file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if _gcp_metric_fetch_budget_exhausted; then
            log_warn "gcp: metric fetch budget exhausted — skipping remaining Cloud Monitoring metrics for ${instance}"
            break
        fi

        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r rule_key metric_type unit <<< "$line"
        [[ -z "$rule_key" || -z "$metric_type" ]] && continue

        rc=0
        val=$(_gcp_monitoring_fetch "$instance" "$project" "$metric_type" "$period" "$lookback") || rc=$?

        if [[ "$rc" -eq 124 ]]; then
            log_warn "gcp: metric fetch timed out (${rule_key} / ${metric_type}) — skipping"
            continue
        fi

        [[ -z "$val" ]] && continue

        printf '%s\t%s\t%s\n' "$rule_key" "$val" "${unit:-}"
    done < "$query_file"
}

# ---------- top-level collect functions ----------

# collect_cloudsql_metrics INSTANCE_NAME [DB_TYPE] [PROJECT]
# Resolves project via gcp_effective_project when not supplied.
# Builds the metric query file from [metric.gcp.monitoring.CloudSQL.*] INI sections,
# fetches each metric, and prints KEY<TAB>VALUE<TAB>UNIT to stdout.
collect_cloudsql_metrics() {
    local instance="$1" db_type="${2:-}" project="${3:-}"

    [[ -z "$project" ]] && project=$(gcp_effective_project)

    local period; period=$(_metric_period)
    local lookback; lookback=$(_lookback_minutes)
    local query_file; query_file=$(mktemp)
    trap 'rm -f "$query_file"' EXIT

    _gcp_build_metric_query_file "$instance" "$project" "$db_type" "$query_file"
    _gcp_batch_fetch_metrics "$instance" "$project" "$db_type" "$query_file" "$period" "$lookback"

    rm -f "$query_file"
}

# ---------- Query Insights ----------

# gcp_collect_query_insights_enabled_for_instance INSTANCE_NAME
# Returns 0 (true) when any [metric.gcp.qi.CloudSQL.*] section has collect=true
# for the given instance (respecting per-instance overlay).
gcp_collect_query_insights_enabled_for_instance() {
    local instance="$1" section collect

    while IFS= read -r section; do
        [[ "$section" =~ ^metric\.gcp\.qi\.CloudSQL\. ]] || continue
        collect=$(thresh_ini_get "$instance" "$section" "collect" "false")
        [[ "${collect,,}" == "true" ]] && return 0
    done < <(thresh_ini_sections "$instance")

    return 1
}

# _gcp_build_qi_query_file INSTANCE PROJECT DB_TYPE OUTFILE
# Same as _gcp_build_metric_query_file but reads [metric.gcp.qi.CloudSQL.*] sections.
_gcp_build_qi_query_file() {
    local instance="$1" project="$2" db_type="${3,,}" outfile="$4"

    : > "$outfile"
    local section collect engines metric_name unit rule_key

    while IFS= read -r section; do
        [[ "$section" =~ ^metric\.gcp\.qi\.CloudSQL\. ]] || continue

        collect=$(thresh_ini_get "$instance" "$section" "collect" "false")
        [[ "${collect,,}" == "true" ]] || continue

        engines=$(thresh_ini_get "$instance" "$section" "engines" "all")
        _engine_matches "$db_type" "$engines" || continue

        metric_name=$(thresh_ini_get "$instance" "$section" "metric_name" "")
        [[ -z "$metric_name" ]] && continue

        unit=$(thresh_ini_get "$instance" "$section" "unit" "")
        rule_key="${section##*.}"

        printf '%s\t%s\t%s\n' "$rule_key" "$metric_name" "$unit" >> "$outfile"
    done < <(thresh_ini_sections "$instance")
}

# collect_cloudsql_query_insights_metrics INSTANCE_NAME [PROJECT]
# Collects [metric.gcp.qi.CloudSQL.*] sections (Query Insights metrics via Cloud Monitoring).
# Prints KEY<TAB>VALUE<TAB>UNIT to stdout.
collect_cloudsql_query_insights_metrics() {
    local instance="$1" project="${2:-}"

    [[ -z "$project" ]] && project=$(gcp_effective_project)

    local period; period=$(_metric_period)
    local lookback; lookback=$(_lookback_minutes)
    local query_file; query_file=$(mktemp)
    trap 'rm -f "$query_file"' EXIT

    # Determine db_type from INI — engines field tells us what this instance runs.
    # QI metrics are fetched regardless of db_type filter at this layer; the per-section
    # engines filter inside _gcp_build_qi_query_file handles engine scoping.
    local db_type=""

    _gcp_build_qi_query_file "$instance" "$project" "$db_type" "$query_file"
    _gcp_batch_fetch_metrics "$instance" "$project" "$db_type" "$query_file" "$period" "$lookback"

    rm -f "$query_file"
}
