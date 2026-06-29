#!/usr/bin/env bash
# daemon.sh — monitor daemon lifecycle: start / stop / status / restart / run-loop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="${SCRIPT_DIR}"
# shellcheck source=../common/lib/util.sh
source "${SCRIPT_DIR}/../common/lib/util.sh"
# shellcheck source=../common/lib/config.sh
source "${SCRIPT_DIR}/../common/lib/config.sh"
# shellcheck source=lib/instances.sh
source "${SCRIPT_DIR}/lib/instances.sh"
# shellcheck source=../common/lib/ssh_os_metrics.sh
source "${SCRIPT_DIR}/../common/lib/ssh_os_metrics.sh"
# shellcheck source=../common/lib/thresholds.sh
source "${SCRIPT_DIR}/../common/lib/thresholds.sh"

config_apply_runtime_paths

POLL_PID=""
_STOP_FLAG="${DBMONITOR_RUNTIME}/daemon.stop"
_SKIP_PID_CLEAR="false"

usage() {
    cat <<EOF
Usage:
  bash daemon.sh <command> [options]

Commands:
  start       Start the monitor daemon in the background
  stop        Stop the running daemon gracefully
  restart     Stop then start the daemon
  status      Show daemon status (running / stopped) and PID
  watchdog    Start the daemon if it is not already running
              (safe to call from cron — no-op when daemon is healthy)
  run-loop    Run the polling loop in the foreground
              (used internally by 'start'; rarely called directly)

Options:
  --foreground   (start) Run in the foreground instead of daemonising;
                 logs go to stdout instead of the daemon log file
  --help         Show this message

Examples:
  bash daemon.sh start
  bash daemon.sh start --foreground
  bash daemon.sh status
  bash daemon.sh stop
  bash daemon.sh restart

Notes:
  The daemon polls all configured instances at the interval set in config.ini.
  Use 'bash monitor.sh daemon status' to check from the top-level CLI.
EOF
}

# _pid_is_daemon PID → 0 when PID looks like our run-loop
_pid_is_daemon() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local cmdline
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
    [[ "$cmdline" == *"daemon.sh run-loop"* ]]
}

# _cleanup_stale_pid → remove PID file when process is not our daemon
_cleanup_stale_pid() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 0
    fi
    local pid; pid=$(pid_read)
    if [[ -z "$pid" ]] || ! _pid_is_daemon "$pid"; then
        pid_clear
    fi
}

# _print_log_destinations — show where daemon and metric logs are written
_print_log_destinations() {
    echo "Daemon log:   $(daemon_log_path)"
    echo "OS metrics:   $(entity_metrics_log_path localhost)"
    local inst_name inst_type inst_region inst_profile
    while IFS=$'\t' read -r inst_name inst_type inst_region inst_profile; do
        [[ -z "$inst_name" ]] && continue
        echo "RDS metrics:  $(entity_metrics_log_path "$inst_name")  (${inst_name})"
    done < <(instances_load_saved 2>/dev/null || true)
}

# ---------- start ----------

cmd_start() {
    local foreground=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --foreground|-f) foreground=true; shift ;;
            --help) usage; exit 0 ;;
            *) shift ;;
        esac
    done

    ensure_dirs
    # Prevent concurrent start/watchdog double-fork.
    if ! daemon_start_lock_acquire; then
        # Another start is already in progress; treat as success.
        exit 0
    fi
    _cleanup_stale_pid
    rm -f "$_STOP_FLAG" 2>/dev/null || true

    # Optional per-entity metrics archival + archive retention (never delete live logs)
    local archive_on_start; archive_on_start=$(mcfgb logs.metrics archive_on_start false)
    local archive_keep_days; archive_keep_days=$(mcfgi logs.metrics archive_keep_days 0)
    if [[ "$archive_on_start" == "true" ]]; then
        local suffix; suffix="$(date '+%Y%m%d')"

        # Rotate localhost metrics log
        local host_dir; host_dir="$(entity_log_dir localhost)"
        local host_log; host_log="$(entity_metrics_log_path localhost)"
        if [[ -s "$host_log" ]]; then
            mv "$host_log" "${host_dir}/monitor_localhost_Archive_${suffix}.log" 2>/dev/null || true
        fi

        # Rotate each saved instance metrics log
        while IFS=$'\t' read -r inst_name inst_type inst_region inst_profile; do
            [[ -z "$inst_name" ]] && continue
            local d; d="$(entity_log_dir "$inst_name")"
            local f; f="$(entity_metrics_log_path "$inst_name")"
            if [[ -s "$f" ]]; then
                mv "$f" "${d}/monitor_$(sanitize_name "$inst_name")_Archive_${suffix}.log" 2>/dev/null || true
            fi
        done < <(instances_load_saved) || true
    fi
    if [[ "$archive_keep_days" -gt 0 ]]; then
        find "$DBMONITOR_LOGS_ROOT" -type f -name 'monitor_*_Archive_*.log' -mtime +"$archive_keep_days" -delete 2>/dev/null || true
    fi

    if pid_running && _pid_is_daemon "$(pid_read)"; then
        echo "Daemon is already running (PID $(pid_read))."
        daemon_start_lock_release
        exit 0
    fi
    pid_clear

    if [[ "$foreground" == "true" ]]; then
        echo "Starting monitor in foreground (Ctrl-C to stop)..."
        _print_log_destinations
        export MONITOR_STDOUT=true
        daemon_start_lock_release
        cmd_run_loop
    else
        # Daemon logging is handled by lib/util.sh via daemon_log_path().
        # Avoid redirecting stdout to the same file (would duplicate every line).
        MONITOR_STDOUT=false nohup bash "${SCRIPT_DIR}/daemon.sh" run-loop \
            >> /dev/null 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        sleep "$(pcfgi lifecycle daemon_start_verify_delay_seconds 1)"
        if _pid_is_daemon "$pid"; then
            echo "Daemon started (PID ${pid})."
            _print_log_destinations
            daemon_start_lock_release
        else
            echo "ERROR: Daemon failed to start. Check: $(daemon_log_path)" >&2
            pid_clear
            daemon_start_lock_release
            exit 1
        fi
    fi
}

# ---------- stop ----------

cmd_stop() {
    _cleanup_stale_pid

    if ! pid_running; then
        echo "Daemon is not running."
        pid_clear
        return 0
    fi

    local pid; pid=$(pid_read)
    if ! _pid_is_daemon "$pid"; then
        echo "Daemon is not running (stale PID file removed)."
        pid_clear
        return 0
    fi

    # Mark as an intentional stop so auto-restart doesn't trigger
    : > "$_STOP_FLAG" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true

    # Also stop an in-flight poll subprocess if it outlives the signal to the parent
    if [[ -f "${DBMONITOR_RUNTIME}/poll.pid" ]]; then
        local ppid; ppid=$(cat "${DBMONITOR_RUNTIME}/poll.pid" 2>/dev/null || true)
        if [[ -n "$ppid" ]] && kill -0 "$ppid" 2>/dev/null; then
            kill -TERM "$ppid" 2>/dev/null || true
            local poll_waited=0
            while kill -0 "$ppid" 2>/dev/null && [[ $poll_waited -lt 20 ]]; do
                sleep 0.1; (( poll_waited++ )) || true
            done
            local poll_waited2=0
            while kill -0 "$ppid" 2>/dev/null && [[ $poll_waited2 -lt 118 ]]; do
                sleep 1; (( poll_waited2++ )) || true
            done
            if kill -0 "$ppid" 2>/dev/null; then
                kill -KILL "$ppid" 2>/dev/null || true
            fi
        fi
    fi

    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 20 ]]; do
        sleep 0.1; (( waited++ )) || true
    done
    local waited2=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited2 -lt 28 ]]; do
        sleep 1; (( waited2++ )) || true
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        echo "Daemon (PID $pid) killed after timeout."
    else
        echo "Daemon stopped."
    fi
    rm -f "${DBMONITOR_RUNTIME}/poll.pid"
    ssh_close_all_sessions 2>/dev/null || true
    pid_clear
}

# ---------- restart ----------

cmd_restart() {
    cmd_stop
    sleep "$(pcfgi lifecycle daemon_restart_delay_seconds 2)"
    cmd_start "$@"
}

# ---------- status ----------

cmd_status() {
    _cleanup_stale_pid
    if pid_running && _pid_is_daemon "$(pid_read)"; then
        echo "running (PID $(pid_read))"
    else
        echo "stopped"
        pid_clear 2>/dev/null || true
    fi
}

# ---------- watchdog (user crontab, no sudo) ----------

cmd_watchdog() {
    _cleanup_stale_pid
    if [[ -f "$_STOP_FLAG" ]]; then
        echo "Watchdog: daemon intentionally stopped (remove .dbmonitor/runtime/daemon.stop or run: bash monitor.sh daemon start)" >&2
        exit 0
    fi
    if pid_running && _pid_is_daemon "$(pid_read)"; then
        exit 0
    fi
    cmd_start
}

# ---------- run-loop (internal) ----------


cmd_run_loop() {
    ensure_dirs
    export MONITOR_STDOUT=false
    trap '_on_signal' SIGTERM SIGINT SIGHUP
    trap '_on_exit' EXIT
    pid_write

    local interval; interval=$(mcfgi monitoring default_poll_interval 30)
    log_info "daemon: started (PID $$, poll interval ${interval}s)"

    while true; do
        # Housekeeping: remove dated log files older than keep_days
        housekeep_logs

        if [[ -f "${DBMONITOR_RUNTIME}/poll.pid" ]]; then
            local old_poll; old_poll=$(cat "${DBMONITOR_RUNTIME}/poll.pid" 2>/dev/null || true)
            if [[ -n "$old_poll" ]] && kill -0 "$old_poll" 2>/dev/null; then
                log_warn "daemon: previous poll still running (PID ${old_poll}), waiting"
                sleep "$interval"
                continue
            fi
            rm -f "${DBMONITOR_RUNTIME}/poll.pid"
        fi

        log_info "daemon: poll cycle starting"
        local cycle_start; cycle_start=$(date +%s)
        local poll_timeout; poll_timeout=$(mcfgi monitoring poll_cycle_timeout_seconds 120)
        [[ "$poll_timeout" -le 0 ]] && poll_timeout=120

        trap "" SIGTERM SIGINT
        MONITOR_POLL_MODE=daemon MONITOR_POLL_INTERVAL="$interval" \
            bash "${SCRIPT_DIR}/monitor.sh" _poll &
        POLL_PID=$!
        echo "$POLL_PID" > "${DBMONITOR_RUNTIME}/poll.pid"
        trap '_on_signal' SIGTERM SIGINT

        # Wait up to poll_cycle_timeout_seconds; kill gracefully on overrun.
        # Use a sentinel sleep + wait -n so we block in the kernel with zero CPU spin.
        # Falls back to sleep-1 polling on bash < 4.3 (released 2014).
        local poll_rc=0
        if [[ "$poll_timeout" -gt 0 ]]; then
            if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
                sleep "$poll_timeout" &
                local _sentinel=$!
                wait -n "$POLL_PID" "$_sentinel" 2>/dev/null || true
                if kill -0 "$POLL_PID" 2>/dev/null; then
                    kill "$_sentinel" 2>/dev/null || true; wait "$_sentinel" 2>/dev/null || true
                    log_warn "daemon: poll cycle timed out after ${poll_timeout}s — killing (PID ${POLL_PID})"
                    kill -TERM "$POLL_PID" 2>/dev/null || true
                    sleep "$(pcfgi lifecycle signal_escalation_delay_seconds 2)"
                    kill -0 "$POLL_PID" 2>/dev/null && kill -KILL "$POLL_PID" 2>/dev/null || true
                    wait "$POLL_PID" 2>/dev/null || true
                    poll_rc=124
                else
                    kill "$_sentinel" 2>/dev/null || true; wait "$_sentinel" 2>/dev/null || true
                    wait "$POLL_PID" || poll_rc=$?
                fi
            else
                local _waited=0
                while kill -0 "$POLL_PID" 2>/dev/null && [[ $_waited -lt $poll_timeout ]]; do
                    sleep 1; (( _waited++ )) || true
                done
                if kill -0 "$POLL_PID" 2>/dev/null; then
                    log_warn "daemon: poll cycle timed out after ${poll_timeout}s — killing (PID ${POLL_PID})"
                    kill -TERM "$POLL_PID" 2>/dev/null || true
                    sleep "$(pcfgi lifecycle signal_escalation_delay_seconds 2)"
                    kill -0 "$POLL_PID" 2>/dev/null && kill -KILL "$POLL_PID" 2>/dev/null || true
                    wait "$POLL_PID" 2>/dev/null || true
                    poll_rc=124
                else
                    wait "$POLL_PID" || poll_rc=$?
                fi
            fi
        else
            wait "$POLL_PID" || poll_rc=$?
        fi

        POLL_PID=""
        rm -f "${DBMONITOR_RUNTIME}/poll.pid"

        local cycle_end elapsed
        cycle_end=$(date +%s)
        elapsed=$(( cycle_end - cycle_start ))

        if [[ $poll_rc -eq 124 ]]; then
            log_warn "daemon: poll cycle timed out (${elapsed}s)"
        elif [[ $poll_rc -ne 0 ]]; then
            log_warn "daemon: poll cycle failed (exit ${poll_rc}, duration ${elapsed}s)"
        else
            log_info "daemon: poll cycle complete (${elapsed}s)"
        fi

        sleep "$interval"
    done
}

_on_signal() {
    log_info "daemon: received signal — shutting down"

    # If enabled and this was NOT an intentional stop, restart in-place after delay.
    local auto_restart; auto_restart=$(mcfgb daemon auto_restart_enabled false)
    if [[ "$auto_restart" == "true" && ! -f "$_STOP_FLAG" ]]; then
        local delay; delay=$(mcfgi daemon auto_restart_delay_seconds 10)
        log_warn "daemon: auto-restart enabled; restarting in ${delay}s"
        _SKIP_PID_CLEAR="true"
        if [[ -n "${POLL_PID:-}" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
            kill -TERM "$POLL_PID" 2>/dev/null || true
            local _sig_max; _sig_max=$(pcfgi lifecycle signal_stop_max_wait_seconds 15)
            local _sw=0; while kill -0 "$POLL_PID" 2>/dev/null && [[ $_sw -lt $_sig_max ]]; do sleep 1; ((_sw++)) || true; done; kill -0 "$POLL_PID" 2>/dev/null && kill -KILL "$POLL_PID" 2>/dev/null || true; wait "$POLL_PID" 2>/dev/null || true
        fi
        rm -f "${DBMONITOR_RUNTIME}/poll.pid" 2>/dev/null || true
        sleep "$delay"
        exec bash "${SCRIPT_DIR}/daemon.sh" run-loop
    fi
    if [[ -n "${POLL_PID:-}" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        kill -TERM "$POLL_PID" 2>/dev/null || true
        local _sig_max; _sig_max=$(pcfgi lifecycle signal_stop_max_wait_seconds 15)
        local _sw=0; while kill -0 "$POLL_PID" 2>/dev/null && [[ $_sw -lt $_sig_max ]]; do sleep 1; ((_sw++)) || true; done; kill -0 "$POLL_PID" 2>/dev/null && kill -KILL "$POLL_PID" 2>/dev/null || true; wait "$POLL_PID" 2>/dev/null || true
    fi
    rm -f "${DBMONITOR_RUNTIME}/poll.pid"
    ssh_close_all_sessions 2>/dev/null || true
    exit 0
}

_on_exit() {
    log_info "daemon: exiting"
    if [[ "$_SKIP_PID_CLEAR" != "true" ]]; then
        pid_clear 2>/dev/null || true
    fi
    rm -f "${DBMONITOR_RUNTIME}/poll.pid" 2>/dev/null || true
    reset_breach_state 2>/dev/null || true
}

# ---------- dispatch ----------

case "${1:-}" in
    start)      shift; cmd_start "$@" ;;
    stop)       shift; cmd_stop ;;
    restart)    shift; cmd_restart "$@" ;;
    status)     cmd_status ;;
    watchdog)   cmd_watchdog ;;
    run-loop)   cmd_run_loop ;;
    --help|-h)  usage ;;
    *)
        echo "Unknown command: ${1:-}" >&2
        usage >&2
        exit 1
        ;;
esac
