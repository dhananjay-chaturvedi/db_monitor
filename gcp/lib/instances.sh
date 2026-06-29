#!/usr/bin/env bash
# lib/instances.sh — manage saved Cloud SQL instances for monitoring
#
# Storage: .dbmonitor/runtime/cloudsql_instances.tsv
# Format (tab-separated, one instance per line):
#   NAME <TAB> DB_TYPE <TAB> PROJECT <TAB> REGION
# NAME    = Cloud SQL instance ID (not the full connection name project:region:id)
# PROJECT = GCP project ID; empty or "-" → use gcp_effective_project
# REGION  = GCP region; empty or "-" → use default from gcloud config
# Lines starting with # are comments.

# shellcheck source=../../common/lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/util.sh"
# shellcheck source=gcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/gcp.sh"

INSTANCES_FILE="${DBMONITOR_RUNTIME}/cloudsql_instances.tsv"

# Supported Cloud SQL engine types
SUPPORTED_TYPES="mysql postgresql sqlserver"

# ---------- helpers ----------

_instances_ensure_file() {
    ensure_dirs
    if [[ ! -f "$INSTANCES_FILE" ]]; then
        printf '# name\tdb_type\tproject\tregion\n' > "$INSTANCES_FILE"
    fi
}

_instance_exists() {
    local name="$1"
    awk -F'\t' -v name="$name" '$1 == name { found=1; exit } END { exit found ? 0 : 1 }' "$INSTANCES_FILE" 2>/dev/null
}

_type_valid() {
    local t="${1,,}"
    for supported in $SUPPORTED_TYPES; do
        [[ "$t" == "$supported" ]] && return 0
    done
    return 1
}

_engine_label() {
    case "${1,,}" in
        mysql)      echo "MySQL (Cloud SQL)" ;;
        postgresql) echo "PostgreSQL (Cloud SQL)" ;;
        sqlserver)  echo "SQL Server (Cloud SQL)" ;;
        *)          echo "$1" ;;
    esac
}

# ---------- add ----------

# instances_add NAME TYPE [PROJECT] [REGION]
# Adds a Cloud SQL instance to the monitoring list.
# NAME    = Cloud SQL instance ID (e.g. my-db-instance)
# TYPE    = mysql | postgresql | sqlserver
# PROJECT = GCP project ID — leave blank to use gcp_effective_project
# REGION  = GCP region (e.g. us-central1) — leave blank to use gcloud default
instances_add() {
    local name="$1" type="${2,,}" project="${3:-}" region="${4:-}"

    [[ -z "$name" ]] && { echo "ERROR: instance name is required." >&2; return 1; }
    [[ -z "$type" ]] && { echo "ERROR: instance type is required." >&2; return 1; }

    if ! _type_valid "$type"; then
        echo "ERROR: unsupported type '$type'." >&2
        echo "       Supported: $SUPPORTED_TYPES" >&2
        return 1
    fi

    _instances_ensure_file

    if _instance_exists "$name"; then
        echo "ERROR: instance '$name' is already saved. Use 'delete' first to replace it." >&2
        return 1
    fi

    local stored_project="${project:--}"
    local stored_region="${region:--}"
    printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$stored_project" "$stored_region" >> "$INSTANCES_FILE"

    local display_project="$project"
    [[ -z "$display_project" ]] && display_project=$(gcp_effective_project 2>/dev/null || echo "-")
    echo "Added: $name  ($(_engine_label "$type"), project=${display_project})"

    local overlay_status overlay_path
    overlay_status=$(scaffold_instance_thresholds_overlay "$name")
    overlay_path=$(instance_thresholds_ini "$name")
    case "$overlay_status" in
        created) echo "Created threshold overlay: $overlay_path" ;;
        exists)  echo "Threshold overlay unchanged: $overlay_path" ;;
    esac
}

# ---------- list ----------

# instances_list
# Prints a table of all saved Cloud SQL instances.
instances_list() {
    _instances_ensure_file

    local count
    count=$(grep -cE '^[^#]' "$INSTANCES_FILE" 2>/dev/null || true)

    if [[ "$count" -eq 0 ]]; then
        echo "No instances saved yet."
        echo "Add one with:  bash monitor.sh instances add --name <ID> --type <TYPE>"
        return
    fi

    printf '%-35s %-26s %-28s %s\n' "NAME (Cloud SQL Instance ID)" "TYPE" "PROJECT" "REGION"
    printf '%s\n' "$(printf '%.0s-' {1..100})"
    grep -v '^#' "$INSTANCES_FILE" | grep -v '^[[:space:]]*$' | \
        awk -F'\t' 'BEGIN { OFS=FS } { if ($3 == "") $3="-"; if ($4 == "") $4="-"; print $1,$2,$3,$4 }' | \
        while IFS=$'\t' read -r name type project region; do
            [[ -z "$name" ]] && continue
            local label; label=$(_engine_label "$type")
            printf '%-35s %-26s %-28s %s\n' "$name" "$label" "$project" "$region"
        done
    echo
    echo "Total: $count instance(s)"
}

# ---------- test ----------

# instances_test NAME
# Verifies the Cloud SQL instance is reachable via gcloud and fetches one monitoring metric.
# Returns 0 on success.
instances_test() {
    local name="$1"
    [[ -z "$name" ]] && { echo "ERROR: instance name is required." >&2; return 1; }

    _instances_ensure_file

    # Read instance record
    local record
    record=$(awk -F'\t' -v name="$name" \
        'BEGIN { OFS=FS } $1 == name { if ($3 == "") $3="-"; if ($4 == "") $4="-"; print $1,$2,$3,$4; exit }' \
        "$INSTANCES_FILE" 2>/dev/null || true)
    if [[ -z "$record" ]]; then
        echo "ERROR: instance '$name' not found. Run 'instances list' to see saved instances." >&2
        return 1
    fi

    local iname itype iproject iregion
    IFS=$'\t' read -r iname itype iproject iregion <<< "$record"

    local effective_project
    effective_project=$(gcp_effective_project 2>/dev/null || echo "unknown")
    local query_project="$iproject"
    [[ "$query_project" == "-" || -z "$query_project" ]] && query_project="$effective_project"

    echo "Testing instance: $iname  ($(_engine_label "$itype"))"
    if [[ "$iproject" == "-" || -z "$iproject" ]]; then
        echo "Project: $effective_project  (from gcloud config / ADC)"
    else
        echo "Project: $iproject"
    fi
    if [[ "$iregion" == "-" || -z "$iregion" ]]; then
        echo "Region:  (gcloud default)"
    else
        echo "Region:  $iregion"
    fi
    echo

    # Build optional project flag
    local project_flag=""
    [[ "$query_project" != "-" && -n "$query_project" ]] && project_flag="--project=${query_project}"

    # Step 1: describe the Cloud SQL instance
    printf 'Checking Cloud SQL instance exists... '
    local status_output
    # shellcheck disable=SC2086
    if ! status_output=$(gcloud sql instances describe "$iname" \
        $project_flag \
        --format='value(state,databaseVersion,settings.tier)' 2>&1); then
        echo "FAIL"
        echo "  Could not describe Cloud SQL instance '$iname' in project '$query_project'."
        echo "  Error: $status_output"
        if [[ "$status_output" == *"was not found"* || "$status_output" == *"NOT_FOUND"* ]]; then
            echo
            echo "  Hints:"
            echo "    - Confirm the instance ID in the Cloud SQL console (not the connection name)."
            echo "    - Re-add with the correct project:  bash monitor.sh instances add --name <ID> --type <TYPE> --project <PROJECT>"
            echo "    - List visible instances:  gcloud sql instances list --project $query_project"
        fi
        return 1
    fi

    local db_state db_version db_tier
    IFS=$'\t' read -r db_state db_version db_tier <<< "$status_output"
    echo "OK"
    printf '  Status:   %s\n' "${db_state:-unknown}"
    printf '  Version:  %s\n' "${db_version:-unknown}"
    printf '  Tier:     %s\n' "${db_tier:-unknown}"
    echo

    # Step 2: fetch one Cloud Monitoring metric (database/cpu/utilization)
    printf 'Fetching Cloud Monitoring database/cpu/utilization... '
    local lookback; lookback=$(mcfgi 'cloud' lookback_minutes 10)
    [[ "$lookback" -le 0 ]] && lookback=10

    local now_s; now_s=$(date +%s)
    local start_s; start_s=$(( now_s - lookback * 60 ))
    local start_ts; start_ts=$(date -u -d "@${start_s}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                             || date -u -r "${start_s}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                             || date -u '+%Y-%m-%dT%H:%M:%SZ')
    local end_ts;   end_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local filter
    filter="metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.labels.database_id=\"${query_project}:${iname}\""

    local metric_output metric_rc=0
    # shellcheck disable=SC2086
    metric_output=$(gcloud beta monitoring timeseries list \
        --filter="$filter" \
        --interval-start-time="$start_ts" \
        --interval-end-time="$end_ts" \
        $project_flag \
        --format='value(points[-1].value.doubleValue)' 2>&1) || metric_rc=$?

    if [[ "$metric_rc" -ne 0 ]]; then
        echo "FAIL"
        echo "  Cloud Monitoring query failed: $metric_output"
        return 1
    fi

    # Strip whitespace and check for data
    metric_output="${metric_output//[[:space:]]/}"
    if [[ -z "$metric_output" || "$metric_output" == "None" ]]; then
        echo "NO DATA"
        echo "  No datapoints returned in the last ${lookback} minutes."
        echo "  The instance may be stopped, or the lookback window is too short."
        echo "  Try increasing gcp_lookback_minutes in config.ini."
    else
        # Convert to percentage for display
        local cpu_pct
        cpu_pct=$(awk -v v="$metric_output" 'BEGIN { printf "%.2f", v * 100 }')
        printf 'OK  (CPU: %s%%)\n' "$cpu_pct"
    fi
    echo

    echo "Test complete. Instance '$iname' is reachable and ready to monitor."
    return 0
}

# ---------- delete ----------

# instances_delete NAME
# Removes a Cloud SQL instance from the monitoring list.
instances_delete() {
    local name="$1"
    [[ -z "$name" ]] && { echo "ERROR: instance name is required." >&2; return 1; }

    _instances_ensure_file

    if ! _instance_exists "$name"; then
        echo "ERROR: instance '$name' not found." >&2
        return 1
    fi

    local tmp; tmp=$(mktemp)
    awk -F'\t' -v name="$name" '$1 != name' "$INSTANCES_FILE" > "$tmp"
    mv "$tmp" "$INSTANCES_FILE"

    local removed_overlay
    if removed_overlay=$(remove_instance_thresholds_overlay "$name"); then
        echo "Removed threshold overlay: $removed_overlay"
    fi
    echo "Deleted: $name"
}

# ---------- load_saved (used by poll.sh) ----------

# instances_load_saved → prints NAME<TAB>TYPE<TAB>PROJECT<TAB>REGION per line
# Empty PROJECT normalised to "-"; empty REGION normalised to "-".
instances_load_saved() {
    _instances_ensure_file
    grep -v '^#' "$INSTANCES_FILE" | grep -v '^[[:space:]]*$' | \
        awk -F'\t' 'BEGIN { OFS=FS } { if ($3 == "") $3="-"; if ($4 == "") $4="-"; print $1,$2,$3,$4 }'
}

# instances_lookup NAME → 0 when found; sets _inst_type _inst_project _inst_region
instances_lookup() {
    local name="$1" line
    _instances_ensure_file
    line=$(awk -F'\t' -v name="$name" '$1 == name { print; exit }' "$INSTANCES_FILE" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1
    local _n
    IFS=$'\t' read -r _n _inst_type _inst_project _inst_region <<< "$line"
    [[ -z "$_inst_project" ]] && _inst_project="-"
    [[ -z "$_inst_region"  ]] && _inst_region="-"
    return 0
}

# instances_resolve_metadata NAME
# Sets global vars: inst_type, inst_project, inst_region
# First tries instances_lookup (saved row); falls back to a live cloudsql_instance_status
# call to derive the type from the database version string.
#
# Database version → type mapping:
#   MYSQL_8_0, MYSQL_5_7, MYSQL_*  → mysql
#   POSTGRES_14, POSTGRES_15, POSTGRES_* → postgresql
#   SQLSERVER_*                    → sqlserver
instances_resolve_metadata() {
    local name="$1"
    inst_type=""
    inst_project=""
    inst_region=""

    if instances_lookup "$name"; then
        inst_type="$_inst_type"
        inst_project="$_inst_project"
        inst_region="$_inst_region"
    fi

    if [[ -z "$inst_type" ]]; then
        # Fall back to a live describe to infer type from databaseVersion
        local db_version
        local _fallback_project="${inst_project}"
        [[ "$_fallback_project" == "-" || -z "$_fallback_project" ]] && _fallback_project=""
        db_version=$(cloudsql_instance_status "$name" "$_fallback_project" 2>/dev/null \
                     | awk -F'\t' '{print $2}')
        if [[ -n "$db_version" && "$db_version" != "unknown" ]]; then
            case "${db_version^^}" in
                MYSQL_*)     inst_type="mysql" ;;
                POSTGRES_*)  inst_type="postgresql" ;;
                SQLSERVER_*) inst_type="sqlserver" ;;
            esac
        fi
    fi

    # Normalise sentinels
    [[ -z "$inst_project" ]] && inst_project="-"
    [[ -z "$inst_region"  ]] && inst_region="-"
}
