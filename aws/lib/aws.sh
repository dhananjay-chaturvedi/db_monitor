#!/usr/bin/env bash
# lib/aws.sh — AWS CloudWatch + RDS metrics via aws CLI v2
# All calls use --output text + JMESPath so no JSON parser is needed.
# AWS credential chain (IAM role > env vars > profile) is handled by aws CLI.

# shellcheck source=../../common/lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/util.sh"
# shellcheck source=../../common/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/config.sh"

# ---------- helpers ----------

# aws_effective_region → region the AWS CLI will use (env, config, IMDS)
aws_effective_region() {
    if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
        echo "$AWS_DEFAULT_REGION"
        return
    fi
    if [[ -n "${AWS_REGION:-}" ]]; then
        echo "$AWS_REGION"
        return
    fi
    local configured; configured=$(aws configure get region 2>/dev/null || true)
    if [[ -n "$configured" ]]; then
        echo "$configured"
        return
    fi
    # aws configure get region is empty on some EC2 setups; parse configure list / IMDS
    configured=$(aws configure list 2>/dev/null | awk '/^[[:space:]]*region[[:space:]]/{print $2; exit}')
    if [[ -n "$configured" && "$configured" != "<not set>" ]]; then
        echo "$configured"
        return
    fi
    local token region imds_to token_ttl
    imds_to=$(pcfgi cloud.metadata metadata_connect_timeout_seconds 1)
    token_ttl=$(pcfgi cloud.metadata metadata_token_ttl_seconds 60)
    token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: ${token_ttl}" --connect-timeout "$imds_to" 2>/dev/null || true)
    if [[ -n "$token" ]]; then
        region=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
            --connect-timeout "$imds_to" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
        if [[ -n "$region" ]]; then
            echo "$region"
            return
        fi
    fi
    echo "unknown"
}

_aws_start_time() {
    local minutes="${1:-10}"
    date -u -d "${minutes} minutes ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v-"${minutes}"M '+%Y-%m-%dT%H:%M:%SZ'
}

_aws_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_lookback_minutes() {
    mcfgi 'cloud' lookback_minutes 10
}

_cluster_lookback_minutes() {
    mcfgi 'cloud' cluster_lookback_minutes 180
}

_metric_period() {
    mcfgi 'cloud' metric_period_seconds 60
}

_cluster_metric_period() {
    mcfgi 'cloud' cluster_metric_period_seconds 3600
}

_metric_fetch_timeout_seconds() {
    mcfgi 'cloud' metric_fetch_timeout_seconds 30
}

# Shared fetch budget for one instance pass (CloudWatch + PI + DB Insights).
_AWS_METRIC_FETCH_DEADLINE=0

# aws_metric_fetch_deadline_begin — start shared timeout budget for AWS metric fetches
aws_metric_fetch_deadline_begin() {
    local t; t=$(_metric_fetch_timeout_seconds)
    if [[ "$t" -gt 0 ]]; then
        _AWS_METRIC_FETCH_DEADLINE=$(( $(date +%s) + t ))
    else
        _AWS_METRIC_FETCH_DEADLINE=0
    fi
}

# aws_metric_fetch_deadline_end — clear shared fetch budget
aws_metric_fetch_deadline_end() {
    _AWS_METRIC_FETCH_DEADLINE=0
}

# _aws_metric_fetch_call_timeout — seconds for the next API call (remaining budget or per-call max)
_aws_metric_fetch_call_timeout() {
    local max; max=$(_metric_fetch_timeout_seconds)
    [[ -z "$max" || "$max" -le 0 ]] && { echo 0; return; }
    if [[ "${_AWS_METRIC_FETCH_DEADLINE:-0}" -gt 0 ]]; then
        local now rem; now=$(date +%s)
        rem=$(( _AWS_METRIC_FETCH_DEADLINE - now ))
        [[ "$rem" -le 0 ]] && { echo 0; return; }
        echo "$rem"
        return
    fi
    echo "$max"
}

# _aws_metric_fetch_budget_exhausted — true when shared deadline elapsed
_aws_metric_fetch_budget_exhausted() {
    [[ "${_AWS_METRIC_FETCH_DEADLINE:-0}" -gt 0 ]] || return 1
    [[ "$(_aws_metric_fetch_call_timeout)" -le 0 ]]
}

# _aws_cmd_timeout SECONDS -- COMMAND...
# Runs COMMAND with timeout(1) when SECS > 0. Exit 124 = timed out.
_aws_cmd_timeout() {
    local secs="$1"; shift
    [[ "$secs" -gt 0 ]] || { "$@"; return $?; }
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# _aws_json_escape STRING → JSON string body (no surrounding quotes)
_aws_json_escape() {
    local s="${1:-}" out="" i c
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            \\) out+='\\' ;;
            \") out+='\"' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *) out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# _aws_sanitize_query_id KEY INDEX → CloudWatch MetricDataQueries Id
_aws_sanitize_query_id() {
    local key="$1" idx="$2" base
    base="${key//[^a-zA-Z0-9_]/_}"; base="${base,,}"
    [[ "$base" =~ ^[a-z] ]] || base="m_${base}"
    local _qmax; _qmax=$(mcfgi cloud query_id_max_chars 240)
    printf '%s_%s' "${base:0:${_qmax}}" "$idx"
}

# _aws_escape_dbi_metric METRIC → escape single quotes for DB_PERF_INSIGHTS expression
_aws_escape_dbi_metric() {
    local m="${1:-}"
    m="${m//\'/\\\'}"
    printf '%s' "$m"
}

# ---------- RDS instance info ----------

# rds_instance_status INSTANCE_ID
# Prints: STATUS<TAB>ENGINE  (e.g. "available    mysql")
rds_instance_status() {
    aws rds describe-db-instances \
        --db-instance-identifier "$1" \
        --query 'DBInstances[0].[DBInstanceStatus,Engine]' \
        --output text 2>/dev/null || echo "unknown	unknown"
}

# rds_pi_enabled INSTANCE_ID → "True" or "False"
rds_pi_enabled() {
    aws rds describe-db-instances \
        --db-instance-identifier "$1" \
        --query 'DBInstances[0].PerformanceInsightsEnabled' \
        --output text 2>/dev/null || echo "False"
}

# _ini_any_collect_enabled SECTION_PREFIX — true when any rule under PREFIX has collect=true
_ini_any_collect_enabled() {
    local prefix="$1" section collect
    while IFS= read -r section; do
        [[ "$section" == "${prefix}"* ]] || continue
        collect=$(ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "collect" "false")
        [[ "${collect,,}" == "true" ]] && return 0
    done < <(ini_sections "$METRICS_AND_THRESHOLDS_INI")
    return 1
}

# _ini_any_collect_enabled_for_instance INSTANCE SECTION_PREFIX — per-instance overlay + global
_ini_any_collect_enabled_for_instance() {
    local instance="$1" prefix="$2" section collect
    while IFS= read -r section; do
        [[ "$section" == "${prefix}"* ]] || continue
        collect=$(thresh_ini_get "$instance" "$section" "collect" "false")
        [[ "${collect,,}" == "true" ]] && return 0
    done < <(thresh_ini_sections "$instance")
    return 1
}

# aws_collect_pi_enabled / aws_collect_dbinsights_enabled — driven by metrics_and_thresholds.ini
aws_collect_pi_enabled() {
    _ini_any_collect_enabled "metric.aws.pi.RDS."
}

aws_collect_dbinsights_enabled() {
    _ini_any_collect_enabled "metric.aws.dbinsights.RDS."
}

# Per-instance gates (respect instance overlay collect=false)
aws_collect_pi_enabled_for_instance() {
    _ini_any_collect_enabled_for_instance "$1" "metric.aws.pi.RDS."
}

aws_collect_dbinsights_enabled_for_instance() {
    _ini_any_collect_enabled_for_instance "$1" "metric.aws.dbinsights.RDS."
}

# rds_dbi_resource_id INSTANCE_ID → resource id string (for PI calls)
rds_dbi_resource_id() {
    aws rds describe-db-instances \
        --db-instance-identifier "$1" \
        --query 'DBInstances[0].DbiResourceId' \
        --output text 2>/dev/null
}

# rds_cluster_identifier INSTANCE_ID → Aurora DB cluster identifier (or empty)
rds_cluster_identifier() {
    aws rds describe-db-instances \
        --db-instance-identifier "$1" \
        --query 'DBInstances[0].DBClusterIdentifier' \
        --output text 2>/dev/null || true
}

# _is_aurora_type TYPE → 0 when type is aurora-mysql or aurora-postgresql
_is_aurora_type() {
    case "${1,,}" in
        aurora-mysql|aurora-postgresql) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- CloudWatch metrics ----------

# _engine_matches TYPE ENGINES_CSV → 0 when the instance type is included
_engine_matches() {
    local type="${1,,}" engines="${2,,}"
    [[ -z "$engines" || "$engines" == "all" ]] && return 0
    if [[ "$engines" == "aurora" ]]; then
        _is_aurora_type "$type" && return 0
        return 1
    fi
    local part
    IFS=',' read -ra _eng_parts <<< "$engines"
    for part in "${_eng_parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ "$part" == "$type" ]] && return 0
    done
    return 1
}

# _cw_build_metric_query_file INSTANCE_ID INSTANCE_TYPE DIMENSION CLUSTER_ID OUTFILE
# Writes lines: OUTPUT_KEY<TAB>METRIC_NAME<TAB>UNIT for all matching INI rules.
_cw_build_metric_query_file() {
    local instance="$1" instance_type="${2,,}" dimension="$3" cluster_id="${4:-}" outfile="$5"
    local overlay_entity="$instance"
    [[ "$dimension" == "cluster" && -n "$cluster_id" && "$cluster_id" != "None" ]] && overlay_entity="$cluster_id"

    : > "$outfile"
    local section metric_name collect engines dim unit
    while IFS= read -r section; do
        [[ "$section" =~ ^metric\.aws\.cloudwatch\.(RDS|Aurora)\. ]] || continue

        collect=$(thresh_ini_get "$overlay_entity" "$section" "collect" "true")
        [[ "${collect,,}" == "false" ]] && continue

        engines=$(thresh_ini_get "$overlay_entity" "$section" "engines" "all")
        _engine_matches "$instance_type" "$engines" || continue

        dim=$(thresh_ini_get "$overlay_entity" "$section" "dimension" "instance")
        [[ "$dim" != "$dimension" ]] && continue

        if [[ "$dimension" == "cluster" ]]; then
            [[ -z "$cluster_id" || "$cluster_id" == "None" ]] && continue
        fi

        metric_name=$(thresh_ini_get "$overlay_entity" "$section" "metric_name" "")
        [[ -z "$metric_name" ]] && metric_name="${section##*.}"
        unit=$(thresh_ini_get "$overlay_entity" "$section" "unit" "")
        printf '%s\t%s\t%s\n' "${section##*.}" "$metric_name" "$unit" >> "$outfile"
    done < <(thresh_ini_sections "$overlay_entity")
}

# _cw_batch_fetch_metrics RESOURCE_ID DIMENSION_NAME QUERY_FILE PERIOD LOOKBACK
# Fetches all metrics in QUERY_FILE (KEY<TAB>MetricName<TAB>UnitLabel) via get-metric-data; prints KEY<TAB>VALUE<TAB>UnitLabel.
_cw_batch_fetch_metrics() {
    local resource_id="$1" dimension_name="$2" query_file="$3"
    local period="${4:-$(_metric_period)}" lookback="${5:-$(_lookback_minutes)}"
    local start end json meta idx first qid key name unit line rid dim name_esc
    local -a parts

    [[ ! -s "$query_file" ]] && return 0
    start=$(_aws_start_time "$lookback")
    end=$(_aws_now)

    json=$(mktemp)
    meta=$(mktemp)
    printf '{"MetricDataQueries":[' > "$json"
    idx=0
    first=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r key name unit <<< "$line"
        [[ -z "$key" || -z "$name" ]] && continue
        qid=$(_aws_sanitize_query_id "$key" "$idx")
        printf '%s\t%s\t%s\n' "$qid" "$key" "${unit:-}" >> "$meta"
        ((idx++)) || true
        [[ $first -eq 1 ]] || printf ',' >> "$json"
        first=0
        rid=$(_aws_json_escape "$resource_id")
        dim=$(_aws_json_escape "$dimension_name")
        name_esc=$(_aws_json_escape "$name")
        printf '{"Id":"%s","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"%s","Dimensions":[{"Name":"%s","Value":"%s"}]},"Period":%s,"Stat":"Average"},"ReturnData":true}' \
            "$qid" "$name_esc" "$dim" "$rid" "$period" >> "$json"
    done < "$query_file"
    [[ $first -eq 1 ]] && { rm -f "$json" "$meta"; return 0; }
    printf '],"StartTime":"%s","EndTime":"%s","ScanBy":"TimestampAscending"}' "$start" "$end" >> "$json"

    local call_to cw_out cw_rc=0
    if _aws_metric_fetch_budget_exhausted; then
        log_warn "aws: metric fetch budget exhausted — skipping CloudWatch batch"
        rm -f "$json" "$meta"
        return 0
    fi
    call_to=$(_aws_metric_fetch_call_timeout)
    cw_out=$(_aws_cmd_timeout "$call_to" aws cloudwatch get-metric-data --cli-input-json "file://${json}" \
        --query 'MetricDataResults[?length(Values)>`0`].[Id,Values[-1]]' \
        --output text 2>/dev/null) || cw_rc=$?
    if [[ "$cw_rc" -eq 124 ]]; then
        log_warn "aws: metric fetch timed out after ${call_to}s (CloudWatch batch) — skipping"
        rm -f "$json" "$meta"
        return 0
    fi

    while IFS=$'\t' read -r qid val; do
        [[ -z "$qid" || -z "$val" || "$val" == "None" ]] && continue
        line=$(awk -F '\t' -v q="$qid" '$1==q{print; exit}' "$meta")
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r _ key unit <<< "$line"
        printf '%s\t%s\t%s\n' "$key" "$val" "${unit:-}"
    done <<< "$cw_out"

    rm -f "$json" "$meta"
}

# _collect_cloudwatch_metrics_from_ini INSTANCE_ID INSTANCE_TYPE DIMENSION [CLUSTER_ID]
# Reads [metric.aws.cloudwatch.RDS.*] and [metric.aws.cloudwatch.Aurora.*] from thresholds.ini.
_collect_cloudwatch_metrics_from_ini() {
    local instance="$1" instance_type="${2,,}" dimension="$3" cluster_id="${4:-}"
    local period lookback query_file
    if [[ "$dimension" == "cluster" ]]; then
        period=$(_cluster_metric_period)
        lookback=$(_cluster_lookback_minutes)
    else
        period=$(_metric_period)
        lookback=$(_lookback_minutes)
    fi
    query_file=$(mktemp)

    _cw_build_metric_query_file "$instance" "$instance_type" "$dimension" "$cluster_id" "$query_file"

    if [[ "$dimension" == "cluster" ]]; then
        _cw_batch_fetch_metrics "$cluster_id" "DBClusterIdentifier" "$query_file" "$period" "$lookback"
    else
        _cw_batch_fetch_metrics "$instance" "DBInstanceIdentifier" "$query_file" "$period" "$lookback"
    fi

    rm -f "$query_file"
}

# collect_rds_cloudwatch_metrics INSTANCE_ID [INSTANCE_TYPE]
# Prints KEY<TAB>VALUE for all collect=true CloudWatch rules matching the instance type.
collect_rds_cloudwatch_metrics() {
    local instance="$1" instance_type="${2,,}"
    _collect_cloudwatch_metrics_from_ini "$instance" "$instance_type" "instance"
}

# collect_aurora_cluster_cloudwatch_metrics CLUSTER_ID [INSTANCE_TYPE]
# Cluster-scoped metrics (call once per cluster per poll cycle).
collect_aurora_cluster_cloudwatch_metrics() {
    local cluster_id="$1" instance_type="${2:-aurora-mysql}"
    [[ -z "$cluster_id" || "$cluster_id" == "None" ]] && return
    _collect_cloudwatch_metrics_from_ini "" "$instance_type" "cluster" "$cluster_id"
}

# ---------- Performance Insights ----------

# _pi_build_query_file INSTANCE SECTION_PREFIX OUTFILE
# Writes RULE_ID<TAB>METRIC_NAME<TAB>UNIT for collect=true rules under SECTION_PREFIX.
_pi_build_query_file() {
    local instance="$1" prefix="$2" outfile="$3"
    : > "$outfile"
    local section collect metric_name unit rule_id
    while IFS= read -r section; do
        [[ "$section" =~ ^${prefix} ]] || continue
        collect=$(thresh_ini_get "$instance" "$section" "collect" "false")
        [[ "${collect,,}" == "false" ]] && continue
        metric_name=$(thresh_ini_get "$instance" "$section" "metric_name" "")
        [[ -z "$metric_name" ]] && continue
        unit=$(thresh_ini_get "$instance" "$section" "unit" "")
        rule_id="${section##*.}"
        printf '%s\t%s\t%s\n' "$rule_id" "$metric_name" "$unit" >> "$outfile"
    done < <(thresh_ini_sections "$instance")
}

# _pi_batch_fetch RESOURCE_ID QUERY_FILE PERIOD LOOKBACK
# Prints RULE_ID<TAB>VALUE<TAB>UNIT via aws pi get-resource-metrics (one call per metric).
_pi_batch_fetch() {
    local resource_id="$1" query_file="$2" period="$3" lookback="$4"
    local start end line rule_id metric unit metric_esc val rc call_to
    [[ ! -s "$query_file" ]] && return 0

    start=$(_aws_start_time "$lookback")
    end=$(_aws_now)

    while IFS= read -r line || [[ -n "$line" ]]; do
        if _aws_metric_fetch_budget_exhausted; then
            log_warn "aws: metric fetch budget exhausted — skipping remaining PI metrics"
            break
        fi
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r rule_id metric unit <<< "$line"
        [[ -z "$rule_id" || -z "$metric" ]] && continue
        call_to=$(_aws_metric_fetch_call_timeout)
        metric_esc=$(_aws_json_escape "$metric")
        rc=0
        val=$(_aws_cmd_timeout "$call_to" aws pi get-resource-metrics \
            --service-type RDS \
            --identifier "$resource_id" \
            --start-time "$start" \
            --end-time "$end" \
            --period-in-seconds "$period" \
            --metric-queries "[{\"Metric\":\"${metric_esc}\"}]" \
            --query 'MetricList[0].DataPoints[-1].Value' \
            --output text 2>/dev/null) || rc=$?
        if [[ "$rc" -eq 124 ]]; then
            log_warn "aws: metric fetch timed out after ${call_to}s (PI ${rule_id}) — skipping"
            continue
        fi
        [[ -z "$val" || "$val" == "None" ]] && continue
        printf '%s\t%s\t%s\n' "$rule_id" "$val" "${unit:-}"
    done < "$query_file"
}

# _dbinsights_batch_fetch RESOURCE_ID QUERY_FILE PERIOD LOOKBACK
# Prints RULE_ID<TAB>VALUE<TAB>UNIT via CloudWatch DB_PERF_INSIGHTS (one query per metric).
_dbinsights_batch_fetch() {
    local resource_id="$1" query_file="$2" period="$3" lookback="$4"
    local start end line rule_id metric unit qid metric_esc rid_esc expr val rc call_to json
    [[ ! -s "$query_file" ]] && return 0

    start=$(_aws_start_time "$lookback")
    end=$(_aws_now)
    json=$(mktemp)

    while IFS= read -r line || [[ -n "$line" ]]; do
        if _aws_metric_fetch_budget_exhausted; then
            log_warn "aws: metric fetch budget exhausted — skipping remaining Database Insights metrics"
            break
        fi
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r rule_id metric unit <<< "$line"
        [[ -z "$rule_id" || -z "$metric" ]] && continue
        call_to=$(_aws_metric_fetch_call_timeout)
        qid=$(_aws_sanitize_query_id "$rule_id" 0)
        metric_esc=$(_aws_escape_dbi_metric "$metric")
        rid_esc=$(_aws_escape_dbi_metric "$resource_id")
        expr="DB_PERF_INSIGHTS('RDS', '${rid_esc}', '${metric_esc}')"
        printf '{"MetricDataQueries":[{"Id":"%s","Expression":"%s","ReturnData":true,"Period":%s}],"StartTime":"%s","EndTime":"%s","ScanBy":"TimestampAscending"}' \
            "$qid" "$expr" "$period" "$start" "$end" > "$json"
        rc=0
        val=$(_aws_cmd_timeout "$call_to" aws cloudwatch get-metric-data \
            --cli-input-json "file://${json}" \
            --query 'MetricDataResults[?length(Values)>`0`].Values[-1] | [0]' \
            --output text 2>/dev/null) || rc=$?
        if [[ "$rc" -eq 124 ]]; then
            log_warn "aws: metric fetch timed out after ${call_to}s (DBI ${rule_id}) — skipping"
            continue
        fi
        [[ -z "$val" || "$val" == "None" ]] && continue
        printf '%s\t%s\t%s\n' "$rule_id" "$val" "${unit:-}"
    done < "$query_file"
    rm -f "$json"
}

# collect_rds_pi_metrics INSTANCE_ID
# Collects [metric.aws.pi.RDS.*] rules where collect=true. Prints RULE_ID<TAB>VALUE<TAB>UNIT.
collect_rds_pi_metrics() {
    local instance="$1"
    local resource_id; resource_id=$(rds_dbi_resource_id "$instance")
    [[ -z "$resource_id" || "$resource_id" == "None" ]] && return

    local period lookback query_file
    period=$(mcfgi 'cloud' insights_period_seconds 300)
    lookback=$(mcfgi 'cloud' insights_lookback_minutes 60)
    query_file=$(mktemp)
    _pi_build_query_file "$instance" "metric.aws.pi.RDS." "$query_file"
    _pi_batch_fetch "$resource_id" "$query_file" "$period" "$lookback"
    rm -f "$query_file"
}

# collect_rds_dbinsights_metrics INSTANCE_ID
# Collects [metric.aws.dbinsights.RDS.*] rules where collect=true via DB_PERF_INSIGHTS.
collect_rds_dbinsights_metrics() {
    local instance="$1"
    local resource_id; resource_id=$(rds_dbi_resource_id "$instance")
    [[ -z "$resource_id" || "$resource_id" == "None" ]] && return

    local period lookback query_file
    period=$(mcfgi 'cloud' insights_period_seconds 300)
    lookback=$(mcfgi 'cloud' insights_lookback_minutes 60)
    query_file=$(mktemp)
    _pi_build_query_file "$instance" "metric.aws.dbinsights.RDS." "$query_file"
    _dbinsights_batch_fetch "$resource_id" "$query_file" "$period" "$lookback"
    rm -f "$query_file"
}
