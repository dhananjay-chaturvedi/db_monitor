#!/usr/bin/env bash
# stop_monitor.sh — stop processes started by run_monitor.sh
#
# Usage:
#   bash stop_monitor.sh                          # stop everything (sends TERM to main process)
#   bash stop_monitor.sh --all                    # same
#   bash stop_monitor.sh --instance NAME [...]    # stop specific AWS instance loop(s)
#   bash stop_monitor.sh --db NAME [...]          # stop specific DB loop(s)
#   bash stop_monitor.sh --ssh NAME [...]         # stop specific SSH host loop(s)
#   bash stop_monitor.sh --localhost-os           # stop localhost OS loop
#   bash stop_monitor.sh --list                   # list running loops
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../common/lib/util.sh"
source "${SCRIPT_DIR}/../common/lib/config.sh"
config_apply_runtime_paths

usage() {
    cat <<EOF
Usage:
  bash stop_monitor.sh [options]

Options:
  (no args)                  Stop all active run_monitor sessions and their loops
  --all                      Same as no args — stop everything
  --instance NAME [...]      Stop the polling loop for one or more AWS instance(s)
  --db NAME [...]            Stop the DB connectivity loop for one or more target(s)
  --ssh NAME [...]           Stop the SSH host OS metrics loop for one or more host(s)
  --localhost-os             Stop the localhost OS metrics collection loop
  --list                     List all running sessions and their loop PIDs
                             (grouped by run_monitor session)
  --help                     Show this message

Examples:
  bash stop_monitor.sh                              # stop everything
  bash stop_monitor.sh --all                        # same
  bash stop_monitor.sh --list                       # show what is running
  bash stop_monitor.sh --instance my-rds-instance
  bash stop_monitor.sh --instance inst-a inst-b --db mydb
EOF
}

# _loop_pid_file SESSION TYPE [NAME]
_loop_pid_file() {
    local session="$1" type="$2" name="${3:-}"
    local safe="${name//[^a-zA-Z0-9._-]/_}"
    if [[ -n "$name" ]]; then
        printf '%s/loop.%s.%s.%s.pid' "$DBMONITOR_RUNTIME" "$session" "$type" "$safe"
    else
        printf '%s/loop.%s.%s.pid' "$DBMONITOR_RUNTIME" "$session" "$type"
    fi
}

_kill_loop() {
    local label="$1" pid_file="$2"
    if [[ ! -f "$pid_file" ]]; then
        echo "  $label: no PID file found (already stopped or never started)"
        return 0
    fi
    local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        echo "  $label: PID file empty"
        rm -f "$pid_file"
        return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "  $label: process $pid not running (stale PID file removed)"
        rm -f "$pid_file"
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
        sleep 1
        (( waited++ )) || true
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        echo "  $label: killed (PID $pid) after timeout"
    else
        echo "  $label: stopped (PID $pid)"
    fi
    rm -f "$pid_file"
}

# _stop_session SESSION_PID — stop one run_monitor session by its PID
_stop_session() {
    local session="$1"
    local rm_pid="${DBMONITOR_RUNTIME}/run_monitor.${session}.pid"
    local pid; pid=$(cat "$rm_pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "Stopping run_monitor session ${session} (PID $pid) — loops cleaned up by its trap..."
        kill -TERM "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 15 ]]; do
            sleep 1; (( waited++ )) || true
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            echo "  session ${session}: killed after timeout."
        else
            echo "  session ${session}: stopped."
        fi
        rm -f "${rm_pid}"
    else
        echo "  session ${session}: PID $pid not running (stale PID file removed)."
        rm -f "$rm_pid"
        # Clean up any orphaned loop PID files for this session
        for pf in "${DBMONITOR_RUNTIME}"/loop."${session}".*.pid; do
            [[ -f "$pf" ]] || continue
            local base; base=$(basename "$pf" .pid)
            _kill_loop "$base" "$pf"
        done
    fi
}

_stop_all() {
    local found=0
    for rm_pid in "${DBMONITOR_RUNTIME}"/run_monitor.*.pid; do
        [[ -f "$rm_pid" ]] || continue
        found=1
        local session; session=$(basename "$rm_pid" .pid)
        session="${session#run_monitor.}"
        _stop_session "$session"
    done
    if [[ $found -eq 0 ]]; then
        echo "No run_monitor sessions found."
        # Fall back: clean up any orphaned loop PID files
        local loop_found=0
        for pf in "${DBMONITOR_RUNTIME}"/loop.*.pid; do
            [[ -f "$pf" ]] || continue
            loop_found=1
            local base; base=$(basename "$pf" .pid)
            _kill_loop "$base" "$pf"
        done
        [[ $loop_found -eq 0 ]] && echo "No running loops found."
    fi
}

_list_loops() {
    local any_session=0
    for rm_pid in "${DBMONITOR_RUNTIME}"/run_monitor.*.pid; do
        [[ -f "$rm_pid" ]] || continue
        any_session=1
        local session; session=$(basename "$rm_pid" .pid)
        session="${session#run_monitor.}"
        local mpid; mpid=$(cat "$rm_pid" 2>/dev/null || true)
        if [[ -n "$mpid" ]] && kill -0 "$mpid" 2>/dev/null; then
            echo "run_monitor session ${session}: PID $mpid (running)"
        else
            echo "run_monitor session ${session}: PID ${mpid:-?} (not running)"
        fi
        local found=0
        for pf in "${DBMONITOR_RUNTIME}"/loop."${session}".*.pid; do
            [[ -f "$pf" ]] || continue
            found=1
            local pid; pid=$(cat "$pf" 2>/dev/null || true)
            local base; base=$(basename "$pf" .pid)
            # strip session prefix for display: loop.SESSION.type.name → type.name
            local label="${base#loop.${session}.}"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                printf '  %-42s PID %-8s running\n' "$label" "$pid"
            else
                printf '  %-42s PID %-8s NOT running (stale)\n' "$label" "${pid:-?}"
            fi
        done
        [[ $found -eq 0 ]] && echo "  (no loop PID files for this session)"
        echo
    done
    if [[ $any_session -eq 0 ]]; then
        echo "No run_monitor sessions found (no PID files)."
    fi
}

# --- argument parsing ---

if [[ $# -eq 0 ]]; then
    _stop_all
    exit 0
fi

declare -a _instances=()
declare -a _dbs=()
declare -a _sshs=()
_localhost_os=false
_do_all=false
_do_list=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            _do_all=true; shift ;;
        --instance)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                _instances+=("$1"); shift
            done ;;
        --db)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                _dbs+=("$1"); shift
            done ;;
        --ssh)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                _sshs+=("$1"); shift
            done ;;
        --localhost-os)
            _localhost_os=true; shift ;;
        --list)
            _do_list=true; shift ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

if [[ "$_do_list" == "true" ]]; then
    _list_loops
    exit 0
fi

if [[ "$_do_all" == "true" ]]; then
    _stop_all
    exit 0
fi

# Targeted stops — search across all sessions for the named loop
_any=false

_kill_named_loop() {
    local type="$1" name="${2:-}"
    local safe="${name//[^a-zA-Z0-9._-]/_}"
    local label
    if [[ -n "$name" ]]; then
        label="${type}.${name}"
    else
        label="${type}"
    fi
    local matched=0
    local pf
    if [[ -n "$name" ]]; then
        for pf in "${DBMONITOR_RUNTIME}"/loop.*."${type}"."${safe}".pid; do
            [[ -f "$pf" ]] || continue
            matched=1
            local base; base=$(basename "$pf" .pid)
            _kill_loop "$base" "$pf"
        done
    else
        for pf in "${DBMONITOR_RUNTIME}"/loop.*."${type}".pid; do
            [[ -f "$pf" ]] || continue
            matched=1
            local base; base=$(basename "$pf" .pid)
            _kill_loop "$base" "$pf"
        done
    fi
    if [[ $matched -eq 0 ]]; then
        echo "  ${label}: no PID file found in any session (already stopped or never started)"
    fi
}

for _n in "${_instances[@]}"; do
    _any=true
    _kill_named_loop instance "$_n"
done

for _n in "${_dbs[@]}"; do
    _any=true
    _kill_named_loop db "$_n"
done

for _n in "${_sshs[@]}"; do
    _any=true
    _kill_named_loop sshhost "$_n"
done

if [[ "$_localhost_os" == "true" ]]; then
    _any=true
    _kill_named_loop localhost_os
fi

if [[ "$_any" == "false" ]]; then
    echo "No targets specified." >&2
    usage >&2
    exit 1
fi
