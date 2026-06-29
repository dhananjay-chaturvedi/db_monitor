#!/usr/bin/env bash
# lib/instances.sh — manage saved RDS/Aurora instances for monitoring
#
# Storage: .dbmonitor/runtime/rds_instances.tsv
# Format (tab-separated, one instance per line):
#   NAME <TAB> TYPE <TAB> REGION <TAB> AWS_PROFILE
# Use "-" for REGION when the AWS CLI should use its default region/metadata.
# Lines starting with # are comments.

# shellcheck source=../../common/lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/util.sh"
# shellcheck source=aws.sh
source "$(dirname "${BASH_SOURCE[0]}")/aws.sh"

INSTANCES_FILE="${DBMONITOR_RUNTIME}/rds_instances.tsv"

# Supported RDS/Aurora engine types (maps to CloudWatch namespace + RDS engine)
SUPPORTED_TYPES="mysql aurora-mysql postgresql aurora-postgresql mariadb oracle sqlserver"

# ---------- helpers ----------

_instances_ensure_file() {
    ensure_dirs
    if [[ ! -f "$INSTANCES_FILE" ]]; then
        printf '# name\ttype\tregion\taws_profile\n' > "$INSTANCES_FILE"
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

# _region_valid REGION → 0 if valid AWS region code (not an AZ)
_region_valid() {
    local region="$1"
    [[ -z "$region" || "$region" == "-" ]] && return 0
    # AZs look like ap-northeast-1a; regions are ap-northeast-1 (no trailing AZ letter)
    if [[ "$region" =~ -[a-z]$ ]]; then
        echo "ERROR: '$region' looks like an Availability Zone, not a region." >&2
        echo "       Use the region only (e.g. ap-northeast-1), not the AZ suffix (e.g. ap-northeast-1a)." >&2
        return 1
    fi
    return 0
}

_engine_label() {
    case "${1,,}" in
        mysql)              echo "MySQL RDS" ;;
        aurora-mysql)       echo "Aurora MySQL" ;;
        postgresql)         echo "PostgreSQL RDS" ;;
        aurora-postgresql)  echo "Aurora PostgreSQL" ;;
        mariadb)            echo "MariaDB RDS" ;;
        oracle)             echo "Oracle RDS" ;;
        sqlserver)          echo "SQL Server RDS" ;;
        *)                  echo "$1" ;;
    esac
}

# ---------- add ----------

# instances_add NAME TYPE [REGION] [AWS_PROFILE]
# Adds an RDS/Aurora instance to the monitoring list.
# NAME     = RDS DB instance identifier (or Aurora cluster identifier)
# TYPE     = mysql | aurora-mysql | postgresql | aurora-postgresql | mariadb | oracle | sqlserver
# REGION   = AWS region (e.g. us-east-1) — leave blank to use IAM role's region
# PROFILE  = AWS CLI profile name — leave blank to use instance role credentials
instances_add() {
    local name="$1" type="${2,,}" region="${3:-}" profile="${4:-default}"

    [[ -z "$name" ]] && { echo "ERROR: instance name is required." >&2; return 1; }
    [[ -z "$type" ]] && { echo "ERROR: instance type is required." >&2; return 1; }

    if ! _type_valid "$type"; then
        echo "ERROR: unsupported type '$type'." >&2
        echo "       Supported: $SUPPORTED_TYPES" >&2
        return 1
    fi

    if ! _region_valid "$region"; then
        return 1
    fi

    _instances_ensure_file

    if _instance_exists "$name"; then
        echo "ERROR: instance '$name' is already saved. Use 'delete' first to replace it." >&2
        return 1
    fi

    local stored_region="${region:--}"
    printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$stored_region" "$profile" >> "$INSTANCES_FILE"

    echo "Added: $name  ($(_engine_label "$type"), region=${stored_region}, profile=${profile})"

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
# Prints a table of all saved RDS/Aurora instances.
instances_list() {
    _instances_ensure_file

    local count
    count=$(grep -cE '^[^#]' "$INSTANCES_FILE" 2>/dev/null || true)

    if [[ "$count" -eq 0 ]]; then
        echo "No instances saved yet."
        echo "Add one with:  bash monitor.sh instances add --name ID --type TYPE"
        return
    fi

    printf '%-40s %-26s %-20s %s\n' "NAME (RDS/Aurora Identifier)" "TYPE" "REGION" "AWS_PROFILE"
    printf '%s\n' "$(printf '%.0s-' {1..100})"
    grep -v '^#' "$INSTANCES_FILE" | grep -v '^[[:space:]]*$' | \
        awk -F'\t' 'BEGIN { OFS=FS } { if ($3 == "") $3="-"; if ($4 == "") $4="default"; print $1,$2,$3,$4 }' | \
        while IFS=$'\t' read -r name type region prof; do
            [[ -z "$name" ]] && continue
            local label; label=$(_engine_label "$type")
            printf '%-40s %-26s %-20s %s\n' "$name" "$label" "$region" "$prof"
        done
    echo
    echo "Total: $count instance(s)"
}

# ---------- test ----------

# instances_test NAME
# Verifies the RDS/Aurora instance exists in AWS and that CloudWatch metrics are available.
# Returns 0 on success.
instances_test() {
    local name="$1"
    [[ -z "$name" ]] && { echo "ERROR: instance name is required." >&2; return 1; }

    _instances_ensure_file

    # Read instance record
    local record
    record=$(awk -F'\t' -v name="$name" \
        'BEGIN { OFS=FS } $1 == name { if ($3 == "") $3="-"; if ($4 == "") $4="default"; print $1,$2,$3,$4; exit }' \
        "$INSTANCES_FILE" 2>/dev/null || true)
    if [[ -z "$record" ]]; then
        echo "ERROR: instance '$name' not found. Run 'instances list' to see saved instances." >&2
        return 1
    fi

    local iname itype iregion iprofile
    IFS=$'\t' read -r iname itype iregion iprofile <<< "$record"

    echo "Testing instance: $iname  ($(_engine_label "$itype"))"
    if [[ "$iregion" == "-" || -z "$iregion" ]]; then
        echo "Region:  (AWS default / IAM role region)"
    else
        echo "Region:  $iregion"
    fi
    echo "Profile: $iprofile"
    echo

    # Set env vars for this test
    local _old_region="${AWS_DEFAULT_REGION:-}"
    local _old_profile="${AWS_PROFILE:-}"
    [[ -n "$iregion" && "$iregion" != "-" ]]       && export AWS_DEFAULT_REGION="$iregion"
    [[ -n "$iprofile" && "$iprofile" != "default" ]] && export AWS_PROFILE="$iprofile"

    # Step 1: describe the RDS instance
    printf 'Checking RDS instance exists... '
    local status_output status_rc=0
    status_output=$(rds_instance_status "$iname" 2>&1) || status_rc=$?

    if [[ "$status_rc" -ne 0 || -z "$status_output" || "$status_output" == "unknown	unknown" ]]; then
        echo "FAIL"
        echo "  Could not describe RDS instance '$iname'."
        echo "  Error: $status_output"
        echo
        echo "  Hints:"
        echo "    - Confirm the DB identifier in the RDS console."
        echo "    - Re-add with the correct region/profile."
        echo "    - List visible instances:  aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text"
        [[ -n "$_old_region" ]]  && export AWS_DEFAULT_REGION="$_old_region"  || unset AWS_DEFAULT_REGION
        [[ -n "$_old_profile" ]] && export AWS_PROFILE="$_old_profile"         || unset AWS_PROFILE
        return 1
    fi

    local db_state db_engine
    IFS=$'\t' read -r db_state db_engine <<< "$status_output"
    echo "OK"
    printf '  Status:  %s\n' "${db_state:-unknown}"
    printf '  Engine:  %s\n' "${db_engine:-unknown}"
    echo

    # Step 2: fetch one CloudWatch metric (CPUUtilization)
    printf 'Fetching CloudWatch CPUUtilization... '
    local lookback; lookback=$(mcfgi 'cloud' lookback_minutes 5)
    [[ "$lookback" -le 0 ]] && lookback=5

    local now_s; now_s=$(date +%s)
    local start_s; start_s=$(( now_s - lookback * 60 ))
    local start_ts; start_ts=$(date -u -d "@${start_s}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                             || date -u -r "${start_s}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                             || date -u '+%Y-%m-%dT%H:%M:%SZ')
    local end_ts;   end_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local metric_output metric_rc=0
    metric_output=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name CPUUtilization \
        --dimensions "Name=DBInstanceIdentifier,Value=${iname}" \
        --start-time "$start_ts" \
        --end-time "$end_ts" \
        --period $(( lookback * 60 )) \
        --statistics Average \
        --query 'Datapoints[0].Average' \
        --output text 2>&1) || metric_rc=$?

    [[ -n "$_old_region" ]]  && export AWS_DEFAULT_REGION="$_old_region"  || unset AWS_DEFAULT_REGION
    [[ -n "$_old_profile" ]] && export AWS_PROFILE="$_old_profile"         || unset AWS_PROFILE

    if [[ "$metric_rc" -ne 0 ]]; then
        echo "FAIL"
        echo "  CloudWatch query failed: $metric_output"
        return 1
    fi

    metric_output="${metric_output//[[:space:]]/}"
    if [[ -z "$metric_output" || "$metric_output" == "None" ]]; then
        echo "NO DATA"
        echo "  No datapoints returned in the last ${lookback} minutes."
        echo "  The instance may be stopped, or the lookback window is too short."
        echo "  Try increasing aws_lookback_minutes in config.ini."
    else
        local cpu_pct
        cpu_pct=$(awk -v v="$metric_output" 'BEGIN { printf "%.2f", v }')
        printf 'OK  (CPU: %s%%)\n' "$cpu_pct"
    fi
    echo

    echo "Test complete. Instance '$iname' is reachable and ready to monitor."
    return 0
}

# ---------- delete ----------

# instances_delete NAME
# Removes an RDS/Aurora instance from the monitoring list.
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

# instances_load_saved → prints NAME<TAB>TYPE<TAB>REGION<TAB>AWS_PROFILE per line
# Empty REGION normalised to "-"; empty PROFILE normalised to "default".
instances_load_saved() {
    _instances_ensure_file
    grep -v '^#' "$INSTANCES_FILE" | grep -v '^[[:space:]]*$' | \
        awk -F'\t' 'BEGIN { OFS=FS } { if ($3 == "") $3="-"; if ($4 == "") $4="default"; print $1,$2,$3,$4 }'
}

# instances_lookup NAME → 0 when found; sets _inst_type _inst_region _inst_profile
instances_lookup() {
    local name="$1" line
    _instances_ensure_file
    line=$(awk -F'\t' -v name="$name" '$1 == name { print; exit }' "$INSTANCES_FILE" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1
    local _n
    IFS=$'\t' read -r _n _inst_type _inst_region _inst_profile <<< "$line"
    [[ -z "$_inst_region"  ]] && _inst_region="-"
    [[ -z "$_inst_profile" ]] && _inst_profile="default"
    return 0
}

# instances_resolve_metadata NAME
# Sets global vars: inst_type, inst_region, inst_profile
# First tries instances_lookup (saved row); falls back to a live rds_instance_status
# call to derive the type from the engine string.
#
# Engine → type mapping:
#   mysql           → mysql
#   aurora-mysql    → aurora-mysql
#   postgres        → postgresql
#   aurora-postgresql → aurora-postgresql
#   mariadb         → mariadb
#   oracle-*        → oracle
#   sqlserver-*     → sqlserver
instances_resolve_metadata() {
    local name="$1"
    inst_type=""
    inst_region=""
    inst_profile="default"

    if instances_lookup "$name"; then
        inst_type="$_inst_type"
        inst_region="$_inst_region"
        inst_profile="$_inst_profile"
    fi

    if [[ -z "$inst_type" ]]; then
        # Fall back to a live describe to infer type from engine
        local db_engine
        db_engine=$(rds_instance_status "$name" 2>/dev/null | awk -F'\t' '{print $2}')
        if [[ -n "$db_engine" && "$db_engine" != "unknown" ]]; then
            case "${db_engine,,}" in
                mysql)                inst_type="mysql" ;;
                aurora-mysql)         inst_type="aurora-mysql" ;;
                postgres)             inst_type="postgresql" ;;
                aurora-postgresql)    inst_type="aurora-postgresql" ;;
                mariadb)              inst_type="mariadb" ;;
                oracle-*)             inst_type="oracle" ;;
                sqlserver-*)          inst_type="sqlserver" ;;
            esac
        fi
    fi

    # Normalise sentinels
    [[ -z "$inst_region"  ]] && inst_region="-"
    [[ -z "$inst_profile" ]] && inst_profile="default"
}
