#!/usr/bin/env bash
# lib/thresholds.sh — threshold evaluation with file-backed sustained-breach state
# Uses awk for float comparison; state survives daemon restarts.

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

_state_file() {
    echo "${DBMONITOR_RUNTIME}/breach_state.tsv"
}

_BREACH_LOCK_FD=204

_BREACH_DIRS_INIT="false"
_breach_state_lock() {
    local wait="${1:-120}"
    local sf; sf=$(_state_file)
    if [[ "$_BREACH_DIRS_INIT" != "true" ]]; then
        ensure_dirs
        _BREACH_DIRS_INIT="true"
    fi
    touch "$sf"
    local lf="${sf}.lock"
    # shellcheck disable=SC2086
    eval "exec ${_BREACH_LOCK_FD}>\"${lf}\""
    if [[ "$wait" -eq 0 ]]; then
        flock -n "${_BREACH_LOCK_FD}" || return 1
    elif [[ "$wait" -lt 0 ]]; then
        flock "${_BREACH_LOCK_FD}" || return 1
    else
        flock -w "$wait" "${_BREACH_LOCK_FD}" || return 1
    fi
    return 0
}

_breach_state_unlock() {
    flock -u "${_BREACH_LOCK_FD}" 2>/dev/null || true
}

# _get_breach_count KEY → integer
_get_breach_count() {
    local sf; sf=$(_state_file)
    [[ -f "$sf" ]] || { echo 0; return; }
    awk -F'\t' -v k="$1" '$1==k{print $2; found=1} END{if(!found)print 0}' "$sf"
}

# _set_breach_count KEY COUNT
_set_breach_count() {
    local sf; sf=$(_state_file)
    local tmp; tmp=$(mktemp)
    local now; now=$(date +%s)
    {
        [[ -f "$sf" ]] && awk -F'\t' -v k="$1" '$1!=k' "$sf"
        printf '%s\t%s\t%s\n' "$1" "$2" "$now"
    } > "$tmp"
    mv "$tmp" "$sf"
}

# _float_compare VALUE OPERATOR THRESHOLD → 1 (true) or 0 (false)
_float_compare() {
    awk -v v="$1" -v op="$2" -v t="$3" '
    BEGIN {
        if (op == ">"  && v >  t) print 1
        else if (op == ">=" && v >= t) print 1
        else if (op == "<"  && v <  t) print 1
        else if (op == "<=" && v <= t) print 1
        else if (op == "==" && v == t) print 1
        else if (op == "!=" && v != t) print 1
        else print 0
    }'
}

# check_threshold KEY VALUE OPERATOR THRESHOLD [WINDOW]
# Returns 0 (exit 0) when a SUSTAINED breach fires; 1 otherwise.
# Side effect: updates breach state file.
check_threshold() {
    local key="$1" value="$2" op="$3" thresh="$4" window="${5:-3}"

    # Non-numeric values (None, empty, NaN) don't reset or advance the counter
    [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] || return 1

    _breach_state_lock 120 || return 1
    trap '_breach_state_unlock; trap - RETURN' RETURN

    local breached; breached=$(_float_compare "$value" "$op" "$thresh")
    local count; count=$(_get_breach_count "$key")
    local fire=1

    if [[ "$breached" -eq 1 ]]; then
        count=$(( count + 1 ))
        _set_breach_count "$key" "$count"
        if [[ $count -ge $window ]]; then
            fire=0
        fi
    else
        if [[ $count -gt 0 ]]; then
            _set_breach_count "$key" 0
        fi
    fi

    return "$fire"
}

# evaluate_metric SOURCE INSTANCE METRIC_KEY METRIC_VALUE
# Reads threshold rules from metrics_and_thresholds.ini, checks each severity level.
# If a sustained breach fires, prints: SEVERITY<TAB>MESSAGE
# Returns 0 if an alert was emitted, 1 otherwise.
evaluate_metric() {
    local source="$1" instance="$2" metric_key="$3" value="$4"

    # Build candidate section names to look up (engine-specific first, then generic)
    local -a sections=()
    case "$source" in
        os)  sections=("metric.os.${metric_key}") ;;
        db)  sections=("metric.db.${instance}.${metric_key}" "metric.db.${metric_key}") ;;
        aws) sections=("metric.aws.cloudwatch.Aurora.${metric_key}" "metric.aws.cloudwatch.RDS.${metric_key}" "metric.aws.pi.RDS.${metric_key}" "metric.aws.dbinsights.RDS.${metric_key}") ;;
        gcp) sections=("metric.gcp.monitoring.CloudSQL.${metric_key}" "metric.gcp.qi.CloudSQL.${metric_key}") ;;
        *)   sections=("metric.${source}.${metric_key}") ;;
    esac

    local section=""
    local s
    for s in "${sections[@]}"; do
        if thresh_section_exists "$instance" "$s"; then
            section="$s"
            break
        fi
    done
    [[ -z "$section" ]] && return 1

    local enabled; enabled=$(thresh_ini_get "$instance" "$section" "enabled" "true")
    [[ "${enabled,,}" == "false" ]] && return 1

    local op;     op=$(thresh_ini_get "$instance" "$section" "operator" ">")
    local unit;   unit=$(thresh_ini_get "$instance" "$section" "unit" "")
    local window; window=$(thresh_ini_get "$instance" "$section" "window" "3")
    local desc;   desc=$(thresh_ini_get "$instance" "$section" "description" "$metric_key")

    # Check CRITICAL → WARNING → INFO (highest severity wins)
    local -a levels=(CRITICAL WARNING INFO)
    local -a keys=(critical warning info)
    local idx
    for (( idx=0; idx<3; idx++ )); do
        local level="${levels[$idx]}" cfg_key="${keys[$idx]}"
        local thresh; thresh=$(thresh_ini_get "$instance" "$section" "$cfg_key" "")
        [[ -z "$thresh" ]] && continue

        local breach_key="${source}.${instance}.${metric_key}.${level}"
        if check_threshold "$breach_key" "$value" "$op" "$thresh" "$window"; then
            local dir
            case "$op" in
                ">"|">=") dir="HIGH" ;;
                "<"|"<=") dir="LOW"  ;;
                *)        dir="MATCH" ;;
            esac
            local tag; tag=$(format_source_tag "$source")
            local msg="${tag} ${instance} | ${desc}: ${dir} ${value}${unit:+ $unit} (threshold ${op} ${thresh}${unit:+ $unit})"
            printf '%s\t%s\n' "$level" "$msg"
            return 0
        fi
    done
    return 1
}

# reset_breach_state — clears all breach counters so window restarts from zero.
# Call on daemon/run_monitor shutdown so the next start requires fresh consecutive breaches.
reset_breach_state() {
    local sf; sf=$(_state_file)
    [[ -f "$sf" ]] || return 0
    _breach_state_lock 5 || return 0
    trap '_breach_state_unlock; trap - RETURN' RETURN
    > "$sf"
}

# purge_stale_breach_state [TTL_SECONDS]
# Removes breach counters whose per-row timestamp is older than TTL_SECONDS.
purge_stale_breach_state() {
    local ttl="${1:-$(mcfgi monitoring sustained_breach_ttl_seconds 86400)}"
    local sf; sf=$(_state_file)
    [[ -f "$sf" ]] || return
    _breach_state_lock 120 || return
    trap '_breach_state_unlock; trap - RETURN' RETURN
    local now; now=$(date +%s)
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v now="$now" -v ttl="$ttl" '
        NF >= 2 {
            ts = (NF >= 3) ? $3 : 0
            if ((now - ts) <= ttl) print
        }
    ' "$sf" > "$tmp"
    mv "$tmp" "$sf"
}
