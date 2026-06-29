#!/usr/bin/env bash
# lib/lifecycle.sh — stop agents and remove runtime data
set -euo pipefail

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/ssh_os_metrics.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh_os_metrics.sh"

POLL_PID_FILE="${DBMONITOR_RUNTIME}/poll.pid"
DAEMON_STOP_FLAG="${DBMONITOR_RUNTIME}/daemon.stop"

_lifecycle_cmdline() {
    ps -p "${1:-}" -o args= 2>/dev/null || true
}

_lifecycle_is_daemon_pid() {
    local cmd; cmd=$(_lifecycle_cmdline "$1")
    [[ "$cmd" == *"daemon.sh run-loop"* ]]
}

_lifecycle_is_run_monitor_pid() {
    local cmd; cmd=$(_lifecycle_cmdline "$1")
    [[ "$cmd" == *"run_monitor.sh"* ]]
}

_lifecycle_is_poll_pid() {
    local cmd; cmd=$(_lifecycle_cmdline "$1")
    [[ "$cmd" == *"monitor.sh _poll"* ]]
}

_lifecycle_kill_pid() {
    local pid="$1" label="$2" timeout="${3:-$(pcfgi lifecycle process_stop_timeout_seconds 30)}"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt $timeout ]]; do
        sleep 1
        waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        echo "  Killed ${label} (PID ${pid}) after timeout."
    else
        echo "  Stopped ${label} (PID ${pid})."
    fi
}

# agent_stop_poll — stop in-flight monitor.sh _poll subprocess
agent_stop_poll() {
    local pid=""
    if [[ -f "$POLL_PID_FILE" ]]; then
        pid=$(cat "$POLL_PID_FILE" 2>/dev/null || true)
    fi
    if [[ -n "$pid" ]] && _lifecycle_is_poll_pid "$pid"; then
        _lifecycle_kill_pid "$pid" "poll cycle" "$(pcfgi lifecycle poll_cycle_kill_timeout_seconds 120)"
    fi
    rm -f "$POLL_PID_FILE"

    # Orphan poll processes (no pid file)
    local orphan
    while IFS= read -r orphan; do
        [[ -z "$orphan" || "$orphan" == "$$" ]] && continue
        _lifecycle_kill_pid "$orphan" "orphan poll" "$(pcfgi lifecycle process_stop_timeout_seconds 30)"
    done < <(pgrep -f "${MONITOR_ROOT}/monitor.sh _poll" 2>/dev/null || true)
}

# agent_stop_run_monitor — stop run_monitor.sh loop
agent_stop_run_monitor() {
    local rm_pid_file pid=""
    for rm_pid_file in "${DBMONITOR_RUNTIME}"/run_monitor.*.pid; do
        [[ -f "$rm_pid_file" ]] || continue
        pid=$(cat "$rm_pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && _lifecycle_is_run_monitor_pid "$pid"; then
            _lifecycle_kill_pid "$pid" "run_monitor"
        fi
        rm -f "$rm_pid_file"
    done

    local orphan
    while IFS= read -r orphan; do
        [[ -z "$orphan" || "$orphan" == "$$" ]] && continue
        _lifecycle_kill_pid "$orphan" "orphan run_monitor"
    done < <(pgrep -f "${MONITOR_ROOT}/run_monitor.sh" 2>/dev/null || true)
}

# agent_stop_daemon — stop daemon.sh run-loop
agent_stop_daemon() {
    ensure_dirs 2>/dev/null || true
    : > "$DAEMON_STOP_FLAG" 2>/dev/null || true

    local pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid=$(pid_read 2>/dev/null || true)
    fi

    if [[ -n "$pid" ]] && _lifecycle_is_daemon_pid "$pid"; then
        agent_stop_poll
        _lifecycle_kill_pid "$pid" "daemon"
    elif [[ -n "$pid" ]]; then
        pid_clear 2>/dev/null || true
    fi

    rm -f "$POLL_PID_FILE" "$DAEMON_STOP_FLAG"

    local orphan
    while IFS= read -r orphan; do
        [[ -z "$orphan" || "$orphan" == "$$" ]] && continue
        _lifecycle_kill_pid "$orphan" "orphan daemon"
    done < <(pgrep -f "${MONITOR_ROOT}/daemon.sh run-loop" 2>/dev/null || true)

    pid_clear 2>/dev/null || true
    ssh_close_all_sessions 2>/dev/null || true
}

# agent_stop_all — stop every monitoring agent
agent_stop_all() {
    echo "Stopping monitoring agents..."
    agent_stop_run_monitor
    agent_stop_daemon
    ssh_close_all_sessions 2>/dev/null || true
    echo "All agents stopped."
}

# agent_remove_data — remove runtime artefacts created by the tool
agent_remove_data() {
    local home="${DBMONITOR_HOME:-${MONITOR_ROOT}/.dbmonitor}"
    local alerts_log="${MONITOR_ALERTS_LOG_FILE:-}"
    [[ -z "$alerts_log" ]] && alerts_log=$(_path_setting alerts_log_file)
    [[ -z "$alerts_log" ]] && alerts_log="${MONITOR_ROOT}/alerts.log"

    echo "Removing runtime data..."
    if [[ -d "$home" ]]; then
        rm -rf "$home"
        echo "  Removed ${home}"
    fi
    if [[ -f "$alerts_log" ]]; then
        rm -f "$alerts_log"
        echo "  Removed ${alerts_log}"
    fi
    echo "Runtime data removed."
}
