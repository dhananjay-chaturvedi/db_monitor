#!/usr/bin/env bash
# run_monitor.sh — continuous monitoring without daemon (instances-only by default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="${SCRIPT_DIR}"

# shellcheck source=../common/lib/util.sh
source "${SCRIPT_DIR}/../common/lib/util.sh"
# shellcheck source=../common/lib/config.sh
source "${SCRIPT_DIR}/../common/lib/config.sh"
# shellcheck source=lib/poll.sh
source "${SCRIPT_DIR}/lib/poll.sh"
# shellcheck source=../common/lib/ssh_os_metrics.sh
source "${SCRIPT_DIR}/../common/lib/ssh_os_metrics.sh"

config_apply_runtime_paths

usage() {
    cat <<EOF
Usage:
  bash run_monitor.sh <instance1> [instance2 ...]
  bash run_monitor.sh --instances id1,id2,id3 [options]

Options:
  --instances ID,...        Comma-separated list of Cloud SQL instance IDs
  --interval SECS           Poll interval in seconds
                            (default: monitoring.default_poll_interval from config.ini)
  --project PROJECT         GCP project ID (overrides config; required if not set in config.ini)
  --include-localhost       Force localhost OS metrics collection on (overrides config)
  --no-include-localhost    Force localhost OS metrics collection off (overrides config)
  --include-ssh             Force SSH host OS metrics collection on (overrides config)
  --no-include-ssh          Force SSH host OS metrics collection off (overrides config)
  --include-db              Force DB connectivity checks on (overrides config)
  --no-include-db           Force DB connectivity checks off (overrides config)
  --include-cloud           Force GCP Cloud Monitoring metric collection on (overrides config)
  --no-include-cloud        Force GCP Cloud Monitoring metric collection off (overrides config)
  --help                    Show this message

Examples:
  bash run_monitor.sh my-cloudsql-instance
  bash run_monitor.sh inst-a inst-b --interval 60
  bash run_monitor.sh --instances inst-a,inst-b --project my-gcp-project

Collection defaults (from config.ini [monitoring]):
  collect_os_metrics    = true    Local OS metrics (CPU, memory, disk)
  collect_cloud_metrics = true    GCP Cloud SQL / Cloud Monitoring metrics
  collect_db_metrics    = true    DB connectivity checks
  collect_localhost_os  = false   Localhost OS metrics (disabled by default)
  collect_ssh_hosts_os  = false   Remote SSH host OS metrics (disabled by default)

Notes:
  This script runs continuously. Stop it with Ctrl-C or bash stop_monitor.sh gcp.
  Do not run alongside the daemon — both acquire the poll-cycle lock.
  For one-shot collection: bash monitor.sh os  |  bash monitor.sh cloud --instance ID
EOF
}

interval=""
instances_csv=""
override_localhost=""
override_ssh=""
override_db=""
override_cloud=""
declare -a instances=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) interval="$2"; shift 2 ;;
        --instances) instances_csv="$2"; shift 2 ;;
        --include-localhost) override_localhost="true"; shift ;;
        --no-include-localhost) override_localhost="false"; shift ;;
        --include-ssh) override_ssh="true"; shift ;;
        --no-include-ssh) override_ssh="false"; shift ;;
        --include-db) override_db="true"; shift ;;
        --no-include-db) override_db="false"; shift ;;
        --include-cloud) override_cloud="true"; shift ;;
        --no-include-cloud) override_cloud="false"; shift ;;
        --project) export CLOUDSDK_CORE_PROJECT="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *)
            instances+=("$1"); shift ;;
    esac
done

if [[ -n "$instances_csv" ]]; then
    IFS=',' read -ra _parts <<< "$instances_csv"
    for p in "${_parts[@]}"; do
        p="${p//[[:space:]]/}"
        [[ -n "$p" ]] && instances+=("$p")
    done
fi

if [[ ${#instances[@]} -eq 0 ]]; then
    echo "ERROR: Provide at least one instance id." >&2
    usage >&2
    exit 1
fi

if [[ -z "$interval" ]]; then
    interval="$(mcfgi monitoring default_poll_interval 30)"
fi

if [[ -n "$override_localhost" ]]; then
    export MONITOR_INCLUDE_LOCALHOST="$override_localhost"
fi
if [[ -n "$override_ssh" ]]; then
    export MONITOR_INCLUDE_SSH_HOSTS="$override_ssh"
fi
if [[ -n "$override_db" ]]; then
    export MONITOR_INCLUDE_DB="$override_db"
fi
if [[ -n "$override_cloud" ]]; then
    export MONITOR_INCLUDE_CLOUD="$override_cloud"
fi

export MONITOR_POLL_MODE=continuous
export MONITOR_POLL_INTERVAL="$interval"
ensure_dirs
housekeep_logs
# Scope all PID files to this process's PID so multiple concurrent run_monitor
# sessions do not overwrite each other's files.
_RM_SESSION=$$
_RM_PID_FILE="${DBMONITOR_RUNTIME}/run_monitor.${_RM_SESSION}.pid"
echo "${_RM_SESSION}" > "${_RM_PID_FILE}"

_loop_pid_file() {
    # _loop_pid_file TYPE NAME → e.g. loop.1234.instance.my-cloudsql.pid
    local type="$1" name="${2:-}"
    local safe="${name//[^a-zA-Z0-9._-]/_}"
    if [[ -n "$name" ]]; then
        printf '%s/loop.%s.%s.%s.pid' "$DBMONITOR_RUNTIME" "${_RM_SESSION}" "$type" "$safe"
    else
        printf '%s/loop.%s.%s.pid' "$DBMONITOR_RUNTIME" "${_RM_SESSION}" "$type"
    fi
}

_cleanup_run_monitor() {
    # kill only the loops belonging to this session (scoped by _RM_SESSION)
    for _pf in "${DBMONITOR_RUNTIME}"/loop."${_RM_SESSION}".*.pid; do
        [[ -f "$_pf" ]] || continue
        local _p; _p=$(cat "$_pf" 2>/dev/null) || continue
        kill -TERM "$_p" 2>/dev/null || true
        rm -f "$_pf"
    done
    rm -f "${_RM_PID_FILE}"
    ssh_close_all_sessions 2>/dev/null || true
    reset_breach_state 2>/dev/null || true
}
trap _cleanup_run_monitor EXIT INT TERM

echo "run_monitor: starting (interval ${interval}s)"
echo "run_monitor: instances: ${instances[*]}"
poll_print_collection_status run_monitor

# Each resource (GCP Cloud SQL instance, SSH host, DB target, localhost OS) gets its own
# independent background loop — they never block each other.

if _poll_include_localhost_os; then
    ( poll_localhost_os_loop "$interval" ) &
    echo $! > "$(_loop_pid_file localhost_os)"
fi

if _poll_include_ssh_hosts_os; then
    while IFS=$'\t' read -r _name _target _disk; do
        [[ -z "$_name" || "$_name" =~ ^# ]] && continue
        ( poll_ssh_host_loop "$_name" "$_target" "${_disk:-/}" "$interval" ) &
        echo $! > "$(_loop_pid_file sshhost "$_name")"
    done < <(hosts_load_saved) || true
fi

if _poll_include_db_metrics && [[ -f "$CONN_FILE" ]]; then
    while IFS=$'\t' read -r _name _rest; do
        [[ -z "$_name" || "$_name" =~ ^# ]] && continue
        ( poll_db_loop "$_name" "$interval" ) &
        echo $! > "$(_loop_pid_file db "$_name")"
    done < "$CONN_FILE" || true
fi

if _poll_include_cloud_metrics; then
    for _inst in "${instances[@]}"; do
        _inst="${_inst//[[:space:]]/}"
        [[ -z "$_inst" ]] && continue
        inst_type="" inst_project="" inst_region=""
        instances_resolve_metadata "$_inst" || true
        ( poll_instance_loop "$_inst" "$inst_type" "$inst_project" "$inst_region" "$interval" ) &
        echo $! > "$(_loop_pid_file instance "$_inst")"
    done
fi

# Main process just waits — all work is in background loops.
# trap on EXIT/INT/TERM (set above) kills all background jobs on stop.
wait
