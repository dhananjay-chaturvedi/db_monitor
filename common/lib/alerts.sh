#!/usr/bin/env bash
# lib/alerts.sh — JSONL alert log
# Appends use plain >> which is atomic for lines under 4KB (all our records are ~150 bytes).
# Concurrent writers for the same entity are serialized via entity pipeline locks in poll.sh.

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

_alerts_log_path() {
    if [[ -n "${MONITOR_ALERTS_LOG_FILE:-}" ]]; then
        echo "$MONITOR_ALERTS_LOG_FILE"
        return
    fi
    local override; override=$(_path_setting alerts_log_file)
    if [[ -n "$override" ]]; then
        echo "$override"
        return
    fi
    echo "${MONITOR_ROOT}/alerts.log"
}

# log_alert SEVERITY SOURCE INSTANCE MESSAGE
# Appends one line to alerts.log (script directory by default).
log_alert() {
    local severity="$1" source="$2" instance="$3" message="$4"
    local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    local log_path; log_path=$(_alerts_log_path)
    ensure_dirs
    local line
    line=$(printf '[%s] [%s] [%s] %s | %s' "$ts" "$severity" "$source" "$instance" "$message")
    printf '%s\n' "$line" >> "$log_path"
    append_entity_alert_line "$instance" "$line"
}

# list_alerts [--severity LEVEL] [--source SRC] [--instance INST] [--limit N]
# Prints matching alert records, newest first, in a readable table.
list_alerts() {
    local severity="" source="" instance="" limit
    limit=$(pcfgi alerts default_list_limit 50)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity) severity="$2"; shift 2 ;;
            --source)   source="$2";   shift 2 ;;
            --instance) instance="$2"; shift 2 ;;
            --limit)    limit="$2";    shift 2 ;;
            *) shift ;;
        esac
    done

    local log_path; log_path=$(_alerts_log_path)
    [[ -f "$log_path" ]] || { echo "No alerts log found at: $log_path"; return; }

    # Apply all filters in a single awk pass
    local content
    content=$(awk -v sev="$severity" -v src="$source" -v inst="$instance" '
        (sev == "" || index($0, "[" sev "]")) &&
        (src == "" || index($0, "[" src "]")) &&
        (inst == "" || index($0, "] " inst " |"))
    ' "$log_path")

    local total; total=$(printf '%s\n' "$content" | grep -c . 2>/dev/null || true)
    if [[ "$total" -eq 0 ]]; then
        echo "No matching alerts."
        return
    fi

    printf "%-24s %-10s %-14s %-22s %s\n" "TIME" "SEVERITY" "SOURCE" "INSTANCE" "MESSAGE"
    printf '%0.s-' {1..95}; echo

    printf '%s\n' "$content" | tail -n "$limit" | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--)print lines[i]}' | while IFS= read -r line; do
        [[ "$line" =~ ^\[([^]]+)\]\ \[([^]]+)\]\ \[([^]]+)\]\ ([^|]+)\ \|\ (.*)$ ]] || continue
        printf "%-24s %-10s %-14s %-22s %s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    done
    echo
    printf 'Showing %d of %d matching record(s).\n' "$(( total < limit ? total : limit ))" "$total"
}

# clear_alerts [--severity LEVEL] [--source SRC] [--instance INST]
# Removes matching records. No args = clear all.
clear_alerts() {
    local severity="" source="" instance=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity) severity="$2"; shift 2 ;;
            --source)   source="$2";   shift 2 ;;
            --instance) instance="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local log_path; log_path=$(_alerts_log_path)
    [[ -f "$log_path" ]] || return 0

    local lock_file="${log_path}.lock"

    if [[ -z "$severity" && -z "$source" && -z "$instance" ]]; then
        (
            flock -x 9
            > "$log_path"
        ) 9>"$lock_file"
        echo "Alerts log cleared."
        return
    fi

    # Remove lines matching all specified filters
    local tmp; tmp=$(mktemp "${log_path}.XXXXXX")
    (
        flock -x 9
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local remove=true
            [[ -n "$severity" && "$line" != *"[${severity}]"* ]] && remove=false
            [[ -n "$source" && "$line" != *"[${source}]"* ]] && remove=false
            [[ -n "$instance" && "$line" != *"] ${instance} |"* ]] && remove=false
            [[ "$remove" == true ]] && continue
            printf '%s\n' "$line"
        done < "$log_path" > "$tmp"
        mv "$tmp" "$log_path"
    ) 9>"$lock_file"
    echo "Matching alerts removed."
}
