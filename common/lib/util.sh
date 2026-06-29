#!/usr/bin/env bash
# lib/util.sh — shared helpers: paths, logging, PID management

# Root of the project (provider dir — must be pre-set by the entrypoint before sourcing this file)
MONITOR_ROOT="${MONITOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DBMONITOR_HOME="${DBMONITOR_HOME:-${MONITOR_ROOT}/.dbmonitor}"
DBMONITOR_RUNTIME="${DBMONITOR_RUNTIME:-${DBMONITOR_HOME}/runtime}"
DBMONITOR_SECRETS="${DBMONITOR_SECRETS:-${DBMONITOR_HOME}/secrets}"

DBMONITOR_LOGS_ROOT="${DBMONITOR_LOGS_ROOT:-${DBMONITOR_RUNTIME}/logs}"

sanitize_name() {
    # Keep filenames safe and predictable: A-Z a-z 0-9 . _ -; everything else → _
    local s="${1:-unknown}"
    [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] && { printf '%s' "$s"; return; }
    s="${s//\//_}"
    s=$(sed -E 's/[^A-Za-z0-9._-]+/_/g; s/_+/_/g; s/^_+|_+$//g' <<< "$s")
    [[ -z "$s" ]] && s="unknown"
    printf '%s' "$s"
}

daemon_log_dir() {
    printf '%s' "${DBMONITOR_LOGS_ROOT}/daemon"
}

daemon_log_path() {
    printf '%s/daemon_%s.log' "$(daemon_log_dir)" "$(date '+%Y%m%d')"
}

entity_log_dir() {
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/%s' "$DBMONITOR_LOGS_ROOT" "$name"
}

entity_metrics_log_path() {
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/%s/monitor_%s_%s.log' "$DBMONITOR_LOGS_ROOT" "$name" "$name" "$(date '+%Y%m%d')"
}

entity_alert_log_path() {
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/%s/alert_%s_%s.log' "$DBMONITOR_LOGS_ROOT" "$name" "$name" "$(date '+%Y%m%d')"
}

entity_poll_log_path() {
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/%s/poll_%s.log' "$DBMONITOR_LOGS_ROOT" "$name" "$name"
}

# Per-poll-entity path cache — populated once by poll_entity_log_begin, used by poll_record_metric.
# Each _poll_collect_* runs in its own subshell so variables are isolated; no cross-entity mutation.
_POLL_ENTITY_LOG_DIR=""
_POLL_ENTITY_METRIC_PATH=""
_POLL_ENTITY_ALERT_PATH=""
_POLL_ENTITY_POLL_PATH=""

# poll_entity_log_begin NAME — truncate the entity's poll log and set MONITOR_POLL_ENTITY.
# Also pre-computes log paths so per-metric forks are avoided.
# Call at the start of each _poll_collect_* so the file only contains the latest poll.
poll_entity_log_begin() {
    export MONITOR_POLL_ENTITY="$1"
    local _sname; _sname="$(sanitize_name "$1")"
    _POLL_ENTITY_LOG_DIR="${DBMONITOR_LOGS_ROOT}/${_sname}"
    local _ds; _ds=$(date '+%Y%m%d')
    _POLL_ENTITY_METRIC_PATH="${_POLL_ENTITY_LOG_DIR}/monitor_${_sname}_${_ds}.log"
    _POLL_ENTITY_ALERT_PATH="${_POLL_ENTITY_LOG_DIR}/alert_${_sname}_${_ds}.log"
    _POLL_ENTITY_POLL_PATH="${_POLL_ENTITY_LOG_DIR}/poll_${_sname}.log"
    mkdir -p "$_POLL_ENTITY_LOG_DIR"
    > "${_POLL_ENTITY_POLL_PATH}"
}

ensure_dirs() {
    mkdir -p "$DBMONITOR_RUNTIME" "$DBMONITOR_SECRETS" "${DBMONITOR_LOGS_ROOT}/daemon"
    chmod 700 "$DBMONITOR_SECRETS" 2>/dev/null || true
}

# housekeep_logs — delete dated log files older than configured keep_days.
# Safe to call on every startup or run-loop iteration; uses -mtime so it's a no-op
# until files are actually old enough.
housekeep_logs() {
    local daemon_keep; daemon_keep=$(mcfgi logs.daemon keep_days 5)
    local metric_keep; metric_keep=$(mcfgi logs.metrics keep_days 5)

    if [[ "$daemon_keep" -gt 0 ]]; then
        find "${DBMONITOR_LOGS_ROOT}/daemon" -maxdepth 1 -type f -name 'daemon_*.log' \
            -mtime +"$daemon_keep" -delete 2>/dev/null || true
    fi

    if [[ "$metric_keep" -gt 0 ]]; then
        find "$DBMONITOR_LOGS_ROOT" -mindepth 2 -maxdepth 2 -type f \
            \( -name 'monitor_*_*.log' -o -name 'alert_*_*.log' \) \
            -mtime +"$metric_keep" -delete 2>/dev/null || true
    fi
}

# ---------- logging ----------

_log() {
    local level="$1"; shift
    # Single date call — suffix %Y%m%d is extracted from the ISO timestamp without a second fork
    local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    local date_suffix="${ts:0:4}${ts:5:2}${ts:8:2}"
    local line="[$ts] [$level] $*"
    local log_file="${DBMONITOR_LOGS_ROOT}/daemon/daemon_${date_suffix}.log"
    echo "$line" >> "$log_file"
    # Per-entity poll log: when MONITOR_POLL_ENTITY is set, mirror to that entity's daily poll log
    if [[ -n "${MONITOR_POLL_ENTITY:-}" ]]; then
        mkdir -p "${_POLL_ENTITY_LOG_DIR}" && echo "$line" >> "${_POLL_ENTITY_POLL_PATH}"
    fi
    if [[ "${MONITOR_STDOUT:-true}" == "true" ]]; then
        echo "$line"
    fi
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@" >&2; }
log_debug() { [[ "${MONITOR_DEBUG:-false}" == "true" ]] && _log DEBUG "$@"; true; }

append_entity_metric_line() {
    local name="$1" line="$2"
    local sname; sname="$(sanitize_name "$name")"
    local dir="${DBMONITOR_LOGS_ROOT}/${sname}"
    mkdir -p "$dir"
    printf '%s\n' "$line" >> "${dir}/monitor_${sname}_$(date '+%Y%m%d').log"
}

append_entity_alert_line() {
    local name="$1" line="$2"
    local sname; sname="$(sanitize_name "$name")"
    local dir="${DBMONITOR_LOGS_ROOT}/${sname}"
    mkdir -p "$dir"
    printf '%s\n' "$line" >> "${dir}/alert_${sname}_$(date '+%Y%m%d').log"
}

# ---------- PID helpers ----------

PID_FILE="${DBMONITOR_RUNTIME}/daemon.pid"

pid_write() { echo "$$" > "$PID_FILE"; }

pid_read() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

pid_running() {
    local pid; pid=$(pid_read)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

pid_clear() { rm -f "$PID_FILE"; }

# ---------- formatting ----------

# format_source_tag SOURCE → bracketed tag, e.g. [AWS][cloudwatch], [AWS][PI], [OS]
format_source_tag() {
    case "${1^^}" in
        AWS)     printf '[AWS][cloudwatch]' ;;
        AWS/PI)  printf '[AWS][PI]' ;;
        AWS/DBI) printf '[AWS][DBI]' ;;
        OS)      printf '[OS]' ;;
        DB)      printf '[DB]' ;;
        GCP)     printf '[GCP][monitoring]' ;;
        GCP/QI)  printf '[GCP][QI]' ;;
        *)       printf '[%s]' "${1^^}" ;;
    esac
}

# format_metric_value VALUE → 2 decimal places for numeric; N/A for empty/None; passthrough otherwise.
# Uses bash printf to avoid forking awk on every metric line.
format_metric_value() {
    local v="${1:-}"
    if [[ -z "$v" || "$v" == "None" ]]; then
        printf 'N/A\n'
        return
    fi
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
        printf '%.2f\n' "$v" 2>/dev/null && return || true
    fi
    printf '%s\n' "$v"
}

# ---------- locking ----------

_LOCK_DIR_INIT="false"

_ensure_lock_dir() {
    if [[ "$_LOCK_DIR_INIT" != "true" ]]; then
        mkdir -p "${DBMONITOR_RUNTIME}/locks"
        _LOCK_DIR_INIT="true"
    fi
}

_lock_open_and_acquire() {
    local fd="$1" lock_path="$2" wait_secs="$3" owner_path="$4" owner_label="$5"
    # Bash requires eval for variable FD numbers (no other safe syntax before Bash 4.1 {fd} auto-alloc).
    # lock_path is always a subdirectory of DBMONITOR_RUNTIME (admin-controlled env var, not user input).
    # shellcheck disable=SC2086
    eval "exec ${fd}>\"\${lock_path}\""
    [[ "$wait_secs" -lt 0 ]] && { log_warn "lock: invalid negative wait_secs for ${owner_label}"; return 1; }
    if [[ "$wait_secs" -eq 0 ]]; then
        flock -n "${fd}" || return 1
    else
        if ! flock -n "${fd}" 2>/dev/null; then
            local holder; holder=$(cat "$owner_path" 2>/dev/null || echo "unknown")
            log_warn "lock: waiting for ${owner_label} (holder PID ${holder}, up to ${wait_secs}s)"
            flock -w "$wait_secs" "${fd}" || return 1
        fi
    fi
    printf '%s\n' "$$" > "$owner_path" 2>/dev/null || true
    return 0
}

# Per-entity locks:
# - fetch lock: only while hitting external API (CloudWatch/PI/SSH/etc.)
# - pipeline lock: full end-to-end processing for that entity (fetch+log+eval+alert)

_FETCH_LOCK_FD=200
_FETCH_LOCK_HELD=""
_PIPELINE_LOCK_FD=201
_PIPELINE_LOCK_HELD=""

entity_fetch_lock_path() {
    _ensure_lock_dir
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/locks/%s.fetch.lock' "$DBMONITOR_RUNTIME" "$name"
}

entity_pipeline_lock_path() {
    _ensure_lock_dir
    local name; name="$(sanitize_name "${1:-unknown}")"
    printf '%s/locks/%s.pipeline.lock' "$DBMONITOR_RUNTIME" "$name"
}

entity_fetch_lock_acquire() {
    local entity="$1" wait_secs="${2:-0}"
    local lf; lf="$(entity_fetch_lock_path "$entity")"
    _lock_open_and_acquire "$_FETCH_LOCK_FD" "$lf" "$wait_secs" "${lf}.owner" "fetch lock on ${entity}" || return 1
    _FETCH_LOCK_HELD="$entity"
    return 0
}

entity_fetch_lock_release() {
    [[ -z "$_FETCH_LOCK_HELD" ]] && return 0
    flock -u "${_FETCH_LOCK_FD}" 2>/dev/null || true
    _FETCH_LOCK_HELD=""
}

entity_pipeline_lock_acquire() {
    local entity="$1" wait_secs="${2:-300}"
    local lf; lf="$(entity_pipeline_lock_path "$entity")"
    _lock_open_and_acquire "$_PIPELINE_LOCK_FD" "$lf" "$wait_secs" "${lf}.owner" "pipeline lock on ${entity}" || return 1
    _PIPELINE_LOCK_HELD="$entity"
    return 0
}

entity_pipeline_lock_release() {
    [[ -z "$_PIPELINE_LOCK_HELD" ]] && return 0
    flock -u "${_PIPELINE_LOCK_FD}" 2>/dev/null || true
    _PIPELINE_LOCK_HELD=""
}

# Global cycle lock: ensures only one continuous poller (daemon _poll or run_monitor) runs at a time.
_CYCLE_LOCK_FD=202

poll_cycle_lock_acquire() {
    _ensure_lock_dir
    local wait_secs="${1:-0}"
    local lf="${DBMONITOR_RUNTIME}/locks/poll.cycle.lock"
    _lock_open_and_acquire "$_CYCLE_LOCK_FD" "$lf" "$wait_secs" "${lf}.owner" "poll cycle lock" || return 1
    return 0
}

poll_cycle_lock_release() {
    flock -u "${_CYCLE_LOCK_FD}" 2>/dev/null || true
}

# Daemon start lock: prevents concurrent cmd_start/watchdog double-fork.
_START_LOCK_FD=203

daemon_start_lock_acquire() {
    _ensure_lock_dir
    local lf="${DBMONITOR_RUNTIME}/locks/daemon.start.lock"
    # Always non-blocking: if another start is in progress, exit silently.
    _lock_open_and_acquire "$_START_LOCK_FD" "$lf" 0 "${lf}.owner" "daemon start lock" || return 1
    return 0
}

daemon_start_lock_release() {
    flock -u "${_START_LOCK_FD}" 2>/dev/null || true
}
