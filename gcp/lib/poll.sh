#!/usr/bin/env bash
# lib/poll.sh — shared polling logic used by daemon and one-shot commands
set -euo pipefail

# shellcheck source=../../common/lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/util.sh"
# shellcheck source=../../common/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/config.sh"
# shellcheck source=../../common/lib/os_metrics.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/os_metrics.sh"
# shellcheck source=../../common/lib/ssh_os_metrics.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/ssh_os_metrics.sh"
# shellcheck source=gcp.sh
source "$(dirname "${BASH_SOURCE[0]}")/gcp.sh"
# shellcheck source=../../common/lib/thresholds.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/thresholds.sh"
# shellcheck source=../../common/lib/notify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/notify.sh"
# shellcheck source=../../common/lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/secrets.sh"
# shellcheck source=instances.sh
source "$(dirname "${BASH_SOURCE[0]}")/instances.sh"
# shellcheck source=../../common/lib/hosts.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/hosts.sh"
# shellcheck source=../../common/lib/db_connections.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/db_connections.sh"

_poll_mode() { printf '%s' "${MONITOR_POLL_MODE:-daemon}"; }

# _poll_one_shot_active — one-shot monitor bypasses config.ini collection gates.
_poll_one_shot_active() {
    [[ "${MONITOR_ONE_SHOT_POLL:-}" == "true" ]]
}

# _poll_log_info — during one-shot display, metric tables go to stdout; skip duplicate poll lines.
_poll_log_info() {
    [[ "${MONITOR_METRIC_STDOUT:-}" == "true" ]] && return 0
    log_info "$@"
}

# _poll_with_display_env FUNC [ARGS...]
# Run a one-shot poll command with display mode (no lock wait, stdout metrics).
_poll_with_display_env() {
    local _old_mode="${MONITOR_POLL_MODE:-}"
    local _old_stdout="${MONITOR_METRIC_STDOUT:-}"
    local _old_oneshot="${MONITOR_ONE_SHOT_POLL:-}"
    export MONITOR_POLL_MODE=display
    export MONITOR_METRIC_STDOUT=true
    export MONITOR_ONE_SHOT_POLL=true
    "$@"
    if [[ -n "$_old_mode" ]]; then export MONITOR_POLL_MODE="$_old_mode"; else unset MONITOR_POLL_MODE; fi
    if [[ -n "$_old_stdout" ]]; then export MONITOR_METRIC_STDOUT="$_old_stdout"; else unset MONITOR_METRIC_STDOUT; fi
    if [[ -n "$_old_oneshot" ]]; then export MONITOR_ONE_SHOT_POLL="$_old_oneshot"; else unset MONITOR_ONE_SHOT_POLL; fi
}

# _poll_print_metrics_file FILE — formatted metric lines to stdout.
# Uses awk to split on literal \t so empty value fields (consecutive tabs) are preserved.
_poll_print_metrics_file() {
    local metrics_file="$1"
    [[ -s "$metrics_file" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local k v u
        k="${line%%$'\t'*}"
        [[ -z "$k" ]] && continue
        local rest="${line#*$'\t'}"
        v="${rest%%$'\t'*}"
        u="${rest#*$'\t'}"
        [[ "$u" == "$rest" ]] && u=""   # no second tab → no unit field
        printf '%s\t%s\t%s\n' "$k" "$(format_metric_value "$v")" "${u:-}"
    done < "$metrics_file" | column -t -s $'\t'
}

_poll_pipeline_wait_seconds() {
    case "$(_poll_mode)" in
        display) mcfgi monitoring cli_lock_wait_seconds 0 ;;
        *)       mcfgi monitoring daemon_lock_wait_seconds 300 ;;
    esac
}

_poll_fetch_wait_seconds() {
    # Fetch is always short; display should never wait.
    case "$(_poll_mode)" in
        display) echo 0 ;;
        *)       mcfgi monitoring daemon_lock_wait_seconds 300 ;;
    esac
}

# _poll_run_timed ENTITY FUNC [ARGS...]
# Run FUNC in a background subshell, wait up to poll_cycle_timeout_seconds.
# Sends TERM then KILL if it overruns; logs on timeout or non-zero exit.
# Always returns 0 so the caller's loop continues.
_poll_run_timed() {
    local entity="$1"; shift
    local timeout; timeout=$(mcfgi monitoring poll_cycle_timeout_seconds 120)

    # Refresh the global metrics INI cache before each iteration so that edits
    # to metrics_and_thresholds.ini are picked up by the next loop cycle in
    # run_monitor mode (daemon mode gets a fresh process per cycle via cmd_poll).
    _ini_load_global_cache

    local pid rc=0
    "$@" &
    pid=$!
    _POLL_LOOP_CHILD_PID=$pid

    if [[ "$timeout" -gt 0 ]]; then
        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
            sleep "$timeout" &
            local _sentinel=$!
            wait -n "$pid" "$_sentinel" 2>/dev/null || true
            kill "$_sentinel" 2>/dev/null || true; wait "$_sentinel" 2>/dev/null || true
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "poll: ${entity} timed out after ${timeout}s — killing (PID ${pid})"
                kill -TERM "$pid" 2>/dev/null || true
                sleep "$(pcfgi lifecycle signal_escalation_delay_seconds 2)"
                kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                _POLL_LOOP_CHILD_PID=""
                return 0
            fi
        else
            local _waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $_waited -lt $timeout ]]; do
                sleep 1; (( _waited++ )) || true
            done
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "poll: ${entity} timed out after ${timeout}s — killing (PID ${pid})"
                kill -TERM "$pid" 2>/dev/null || true
                sleep "$(pcfgi lifecycle signal_escalation_delay_seconds 2)"
                kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                _POLL_LOOP_CHILD_PID=""
                return 0
            fi
        fi
    fi

    wait "$pid" || rc=$?
    _POLL_LOOP_CHILD_PID=""
    if [[ $rc -ne 0 ]]; then
        log_warn "poll: ${entity} poll cycle failed (exit ${rc})"
    fi
    return 0
}

# _poll_with_pipeline_lock ENTITY_NAME FUNC [ARGS...]
# End-to-end lock for a single entity when acting as the authoritative collector.
_poll_with_pipeline_lock() {
    local entity="$1" wait_secs; wait_secs=$(_poll_pipeline_wait_seconds)
    shift
    if ! entity_pipeline_lock_acquire "$entity" "$wait_secs"; then
        log_warn "poll: skipping ${entity} — pipeline lock held"
        return 0
    fi
    local _rc=0
    "$@" || _rc=$?
    entity_pipeline_lock_release
    return $_rc
}

# poll_record_metric SOURCE NAME KEY RAW_VALUE UNIT
poll_record_metric() {
    local src="$1" name="$2" key="$3" raw_value="$4" unit="${5:-}"
    local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    local v; v="$(format_metric_value "$raw_value")"
    local tag; tag=$(format_source_tag "$src")
    local line="[${ts}] ${tag} ${name} ${key}=${v}${unit:+ $unit}"
    if [[ -n "$_POLL_ENTITY_METRIC_PATH" ]]; then
        mkdir -p "$_POLL_ENTITY_LOG_DIR"
        printf '%s\n' "$line" >> "$_POLL_ENTITY_METRIC_PATH"
    else
        append_entity_metric_line "$name" "$line"
    fi
    _poll_log_info "poll: metric ${tag} ${name} ${key}=${v}${unit:+ $unit}"
}

# poll_evaluate_metric SOURCE NAME KEY RAW_VALUE UNIT
poll_evaluate_metric() {
    local source="$1" name="$2" metric_key="$3" raw_value="$4" unit="${5:-}"
    poll_record_metric "$source" "$name" "$metric_key" "$raw_value" "$unit"
    local eval_source="${source,,}"
    local result; result=$(evaluate_metric "$eval_source" "$name" "$metric_key" "$raw_value" || true)
    if [[ -n "$result" ]]; then
        local severity message
        IFS=$'\t' read -r severity message <<< "$result"
        log_warn "ALERT: [$severity] $message"
        dispatch_alert "$severity" "$source" "$name" "$message"
    fi
}

# _poll_apply_metric_lines SOURCE ENTITY_NAME METRICS_FILE [RECORD_ONLY]
# Reads KEY<TAB>VALUE<TAB>UNIT lines and records/evaluates.
_poll_apply_metric_lines() {
    local source="$1" entity="$2" metrics_file="$3" record_only="${4:-false}"
    [[ -s "$metrics_file" ]] || return 0
    while IFS=$'\t' read -r metric_key value unit; do
        [[ -z "$metric_key" ]] && continue
        # QI collector currently may not provide unit; fill from INI.
        if [[ -z "${unit:-}" && "$source" == "GCP/QI" ]]; then
            unit=$(thresh_ini_get "$entity" "metric.gcp.qi.CloudSQL.${metric_key}" "unit" "")
        fi
        if [[ "$record_only" == "true" ]]; then
            poll_record_metric "$source" "$entity" "$metric_key" "$value" "$unit"
            local result; result=$(evaluate_metric "gcp" "$entity" "$metric_key" "$value" || true)
            if [[ -n "$result" ]]; then
                local severity message
                IFS=$'\t' read -r severity message <<< "$result"
                log_warn "ALERT: [$severity] $message"
                dispatch_alert "$severity" "GCP/QI" "$entity" "$message"
            fi
        else
            poll_evaluate_metric "$source" "$entity" "$metric_key" "$value" "$unit"
        fi
    done < "$metrics_file"
}

# _poll_collect_gcp_instance INST_NAME INST_TYPE INST_PROJECT INST_REGION
_poll_collect_gcp_instance() {
    local inst_name="$1" inst_type="$2" inst_project="$3" inst_region="$4"
    trap 'kill -- -$$ 2>/dev/null || true; trap - TERM' TERM
    poll_entity_log_begin "$inst_name"
    log_info "poll: collecting GCP Cloud Monitoring metrics for ${inst_name} (${inst_type})"

    local _old_project="${CLOUDSDK_CORE_PROJECT:-}"
    local _old_region="${CLOUDSDK_COMPUTE_REGION:-}"
    [[ -n "$inst_project" && "$inst_project" != "-" ]] && export CLOUDSDK_CORE_PROJECT="$inst_project"
    [[ -n "$inst_region" && "$inst_region" != "-" ]]   && export CLOUDSDK_COMPUTE_REGION="$inst_region"

    gcp_metric_fetch_deadline_begin

    local metrics_file; metrics_file=$(mktemp)
    if entity_fetch_lock_acquire "$inst_name" "$(_poll_fetch_wait_seconds)"; then
        collect_cloudsql_metrics "$inst_name" "$inst_type" "$inst_project" > "$metrics_file" || true
        entity_fetch_lock_release
    else
        log_warn "poll: skipping ${inst_name} — fetch lock held"
        rm -f "$metrics_file"
        gcp_metric_fetch_deadline_end
        [[ -n "$_old_project" ]] && export CLOUDSDK_CORE_PROJECT="$_old_project" || unset CLOUDSDK_CORE_PROJECT
        [[ -n "$_old_region" ]]  && export CLOUDSDK_COMPUTE_REGION="$_old_region" || unset CLOUDSDK_COMPUTE_REGION
        return 0
    fi
    _poll_apply_metric_lines "GCP" "$inst_name" "$metrics_file"
    rm -f "$metrics_file"

    if gcp_collect_query_insights_enabled_for_instance "$inst_name"; then
        log_info "poll: collecting Query Insights metrics for ${inst_name}"
        metrics_file=$(mktemp)
        if entity_fetch_lock_acquire "$inst_name" "$(_poll_fetch_wait_seconds)"; then
            collect_cloudsql_query_insights_metrics "$inst_name" "$inst_project" > "$metrics_file" || true
            entity_fetch_lock_release
            _poll_apply_metric_lines "GCP/QI" "$inst_name" "$metrics_file" "true"
        else
            log_warn "poll: skipping Query Insights for ${inst_name} — fetch lock held"
        fi
        rm -f "$metrics_file"
    fi

    gcp_metric_fetch_deadline_end

    [[ -n "$_old_project" ]] && export CLOUDSDK_CORE_PROJECT="$_old_project" || unset CLOUDSDK_CORE_PROJECT
    [[ -n "$_old_region" ]]  && export CLOUDSDK_COMPUTE_REGION="$_old_region" || unset CLOUDSDK_COMPUTE_REGION
}

# poll_gcp_instance INSTANCE TYPE PROJECT REGION
# Per-instance atomic collection (pipeline lock held for full collect + log + evaluate + alerts).
poll_gcp_instance() {
    local inst_name="$1" inst_type="$2" inst_project="$3" inst_region="$4"
    _poll_with_pipeline_lock "$inst_name" _poll_collect_gcp_instance \
        "$inst_name" "$inst_type" "$inst_project" "$inst_region"
}

# poll_os_metrics — localhost metrics under entity lock
poll_os_metrics() {
    _poll_with_pipeline_lock "localhost" _poll_collect_os_metrics
}

# _poll_include_os_metrics — env MONITOR_INCLUDE_OS overrides config.ini
_poll_include_os_metrics() {
    _poll_one_shot_active && return 0
    if [[ -n "${MONITOR_INCLUDE_OS+set}" ]]; then
        [[ "${MONITOR_INCLUDE_OS}" == "true" ]]
        return
    fi
    [[ "$(mcfgb monitoring collect_os_metrics true)" == "true" ]]
}

# _poll_include_db_metrics — env MONITOR_INCLUDE_DB overrides config.ini
_poll_include_db_metrics() {
    _poll_one_shot_active && return 0
    if [[ -n "${MONITOR_INCLUDE_DB+set}" ]]; then
        [[ "${MONITOR_INCLUDE_DB}" == "true" ]]
        return
    fi
    [[ "$(mcfgb monitoring collect_db_metrics true)" == "true" ]]
}

# _poll_include_cloud_metrics — env MONITOR_INCLUDE_CLOUD overrides config.ini
_poll_include_cloud_metrics() {
    _poll_one_shot_active && return 0
    if [[ -n "${MONITOR_INCLUDE_CLOUD+set}" ]]; then
        [[ "${MONITOR_INCLUDE_CLOUD}" == "true" ]]
        return
    fi
    [[ "$(mcfgb monitoring collect_cloud_metrics true)" == "true" ]]
}

# _poll_include_localhost_os — env MONITOR_INCLUDE_LOCALHOST overrides config.ini
_poll_include_localhost_os() {
    _poll_one_shot_active && return 0
    _poll_include_os_metrics || return 1
    if [[ -n "${MONITOR_INCLUDE_LOCALHOST+set}" ]]; then
        [[ "${MONITOR_INCLUDE_LOCALHOST}" == "true" ]]
        return
    fi
    [[ "$(mcfgb monitoring collect_localhost_os false)" == "true" ]]
}

# _poll_include_ssh_hosts_os — env MONITOR_INCLUDE_SSH_HOSTS overrides config.ini
_poll_include_ssh_hosts_os() {
    _poll_one_shot_active && return 0
    _poll_include_os_metrics || return 1
    if [[ -n "${MONITOR_INCLUDE_SSH_HOSTS+set}" ]]; then
        [[ "${MONITOR_INCLUDE_SSH_HOSTS}" == "true" ]]
        return
    fi
    [[ "$(mcfgb monitoring collect_ssh_hosts_os false)" == "true" ]]
}

_poll_collect_os_metrics() {
    local disk_path; disk_path=$(mcfg monitoring default_disk_path /)
    trap 'kill -- -$$ 2>/dev/null || true; trap - TERM' TERM
    poll_entity_log_begin "localhost"
    _poll_log_info "poll: collecting OS metrics"
    [[ "${MONITOR_METRIC_STDOUT:-}" == true ]] && echo "=== OS Metrics: localhost ==="
    local metrics_file; metrics_file=$(mktemp)
    if entity_fetch_lock_acquire "localhost" "$(_poll_fetch_wait_seconds)"; then
        collect_os_metrics "$disk_path" > "$metrics_file" || true
        entity_fetch_lock_release
    else
        log_warn "poll: skipping localhost — fetch lock held"
        rm -f "$metrics_file"
        return 0
    fi
    [[ "${MONITOR_METRIC_STDOUT:-}" == true ]] && _poll_print_metrics_file "$metrics_file"
    _poll_apply_metric_lines "OS" "localhost" "$metrics_file"
    rm -f "$metrics_file"
}

poll_ssh_hosts_os_metrics() {
    local -a _ssh_pids=()
    _poll_ssh_shutdown() {
        for _p in "${_ssh_pids[@]:-}"; do kill -TERM "$_p" 2>/dev/null || true; done
        for _p in "${_ssh_pids[@]:-}"; do wait "$_p" 2>/dev/null || true; done
        exit 0
    }
    trap '_poll_ssh_shutdown' TERM INT
    while IFS=$'\t' read -r name target disk; do
        [[ -z "$name" || "$name" =~ ^# ]] && continue
        ( _poll_with_pipeline_lock "$name" _poll_collect_ssh_host_os_metrics "$name" "$target" "${disk:-/}" ) &
        _ssh_pids+=($!)
    done < <(hosts_load_saved) || true
    wait
    trap - TERM INT
}

_poll_collect_ssh_host_os_metrics() {
    local name="$1" target="$2" disk="${3:-/}"
    trap 'kill -- -$$ 2>/dev/null || true; trap - TERM' TERM
    poll_entity_log_begin "$name"
    _poll_log_info "poll: collecting OS metrics via SSH for ${name} (${target})"
    [[ "${MONITOR_METRIC_STDOUT:-}" == true ]] && echo "=== OS Metrics: ${name} (${target}) ==="
    local metrics_file; metrics_file=$(mktemp)
    if entity_fetch_lock_acquire "$name" "$(_poll_fetch_wait_seconds)"; then
        collect_ssh_os_metrics "$name" "$target" "$disk" > "$metrics_file" || true
        entity_fetch_lock_release
    else
        log_warn "poll: skipping ${name} — fetch lock held"
        rm -f "$metrics_file"
        return 0
    fi
    [[ "${MONITOR_METRIC_STDOUT:-}" == true ]] && _poll_print_metrics_file "$metrics_file"
    _poll_apply_metric_lines "OS" "$name" "$metrics_file"
    rm -f "$metrics_file"
}

# _poll_one_gcp_instance INST_NAME INST_TYPE INST_PROJECT INST_REGION
# Runs in a subshell — polls one GCP Cloud SQL instance.
_poll_one_gcp_instance() {
    local inst_name="$1" inst_type="$2" inst_project="$3" inst_region="$4"
    # Re-resolve type/project/region if not known at startup (instance not saved).
    if [[ -z "$inst_type" ]]; then
        instances_resolve_metadata "$inst_name" || true
    fi
    poll_gcp_instance "$inst_name" "$inst_type" "$inst_project" "$inst_region"
}

# poll_cycle
# Spawns one background subshell per instance — they run concurrently and independently.
# The cycle lock is released immediately after spawning; per-instance pipeline locks
# prevent a new cycle from double-fetching an instance that is still running.
poll_cycle() {
    ensure_dirs
    poll_cycle_lock_acquire 0 || { log_warn "poll: cycle already running — skipping"; return 0; }
    log_info "poll: cycle begin (PID $BASHPID)"

    local -a _cycle_pids=()
    _poll_cycle_shutdown() {
        for _p in "${_cycle_pids[@]:-}"; do kill -TERM "$_p" 2>/dev/null || true; done
        for _p in "${_cycle_pids[@]:-}"; do wait "$_p" 2>/dev/null || true; done
        poll_cycle_lock_release
        exit 0
    }
    trap '_poll_cycle_shutdown' TERM INT

    _poll_include_localhost_os && { poll_os_metrics & _cycle_pids+=($!); }
    _poll_include_ssh_hosts_os && { poll_ssh_hosts_os_metrics & _cycle_pids+=($!); }

    if _poll_include_cloud_metrics; then
        local inst_name inst_type inst_project inst_region
        while IFS=$'\t' read -r inst_name inst_type inst_project inst_region; do
            [[ -z "$inst_name" ]] && continue
            ( _poll_one_gcp_instance "$inst_name" "$inst_type" "$inst_project" "$inst_region" ) &
            _cycle_pids+=($!)
        done < <(instances_load_saved) || true
    fi

    _poll_include_db_metrics && { poll_db_connectivity & _cycle_pids+=($!); }

    for _p in "${_cycle_pids[@]:-}"; do wait "$_p" 2>/dev/null || true; done

    trap - TERM INT
    purge_stale_breach_state
    log_info "poll: cycle complete (PID $BASHPID)"
    poll_cycle_lock_release
}

# poll_cycle_instances INSTANCE_ID...
# Like poll_cycle, but only for the provided instances. Intended for run_monitor.sh.
poll_cycle_instances() {
    ensure_dirs
    poll_cycle_lock_acquire 0 || { log_warn "poll: cycle already running — skipping"; return 0; }
    log_info "poll: cycle begin (instances-only, PID $BASHPID)"

    local -a inst_list=("$@")
    local -a _pids=()

    if _poll_include_cloud_metrics; then
        local inst_name inst_type inst_project inst_region
        for inst_name in "${inst_list[@]}"; do
            inst_name="${inst_name//[[:space:]]/}"
            [[ -z "$inst_name" ]] && continue

            inst_type="" inst_project="" inst_region=""
            instances_resolve_metadata "$inst_name" || true

            (
                _poll_one_gcp_instance "$inst_name" "$inst_type" "$inst_project" "$inst_region"
            ) &
            _pids+=($!)
        done
        for _pid in "${_pids[@]}"; do wait "$_pid" || true; done
    fi

    purge_stale_breach_state
    log_info "poll: cycle complete (instances-only, PID $BASHPID)"
    poll_cycle_lock_release
}

# _poll_loop_shutdown — SIGTERM handler shared by all loop subshells.
# Kills the current poll cycle child (if any) then exits cleanly.
_POLL_LOOP_CHILD_PID=""
_poll_loop_shutdown() {
    if [[ -n "$_POLL_LOOP_CHILD_PID" ]] && kill -0 "$_POLL_LOOP_CHILD_PID" 2>/dev/null; then
        kill -TERM "$_POLL_LOOP_CHILD_PID" 2>/dev/null || true
        wait "$_POLL_LOOP_CHILD_PID" 2>/dev/null || true
    fi
    exit 0
}

# _poll_interruptible_sleep SECONDS — sleep that exits immediately on SIGTERM.
_poll_interruptible_sleep() {
    local secs="$1"
    sleep "$secs" &
    _POLL_LOOP_CHILD_PID=$!
    wait "$_POLL_LOOP_CHILD_PID" 2>/dev/null || true
    _POLL_LOOP_CHILD_PID=""
}

# poll_instance_loop INST_NAME INST_TYPE INST_PROJECT INST_REGION INTERVAL
# Per-instance continuous loop — polls one instance every INTERVAL seconds independently.
poll_instance_loop() {
    local inst_name="$1" inst_type="$2" inst_project="$3" inst_region="$4"
    local interval="${5:-$(mcfgi monitoring default_poll_interval 30)}"
    trap '_poll_loop_shutdown' TERM INT
    log_info "poll: instance loop started for ${inst_name} (interval ${interval}s, PID $BASHPID)"
    while true; do
        _poll_run_timed "$inst_name" _poll_one_gcp_instance \
            "$inst_name" "$inst_type" "$inst_project" "$inst_region"
        _poll_interruptible_sleep "$interval"
    done
}

# poll_ssh_host_loop NAME TARGET DISK INTERVAL
# Per-SSH-host continuous loop.
poll_ssh_host_loop() {
    local name="$1" target="$2" disk="${3:-/}" interval="${4:-$(mcfgi monitoring default_poll_interval 30)}"
    trap '_poll_loop_shutdown' TERM INT
    log_info "poll: SSH host loop started for ${name} (interval ${interval}s, PID $BASHPID)"
    while true; do
        _poll_run_timed "$name" _poll_with_pipeline_lock \
            "$name" _poll_collect_ssh_host_os_metrics "$name" "$target" "$disk"
        _poll_interruptible_sleep "$interval"
    done
}

# poll_db_loop NAME INTERVAL
# Per-DB-target continuous loop.
poll_db_loop() {
    local name="$1" interval="${2:-$(mcfgi monitoring default_poll_interval 30)}"
    trap '_poll_loop_shutdown' TERM INT
    log_info "poll: DB loop started for ${name} (interval ${interval}s, PID $BASHPID)"
    while true; do
        _poll_run_timed "$name" _poll_db_connectivity_named "$name"
        _poll_interruptible_sleep "$interval"
    done
}

# poll_localhost_os_loop INTERVAL
# Localhost OS metrics continuous loop.
poll_localhost_os_loop() {
    local interval="${1:-$(mcfgi monitoring default_poll_interval 30)}"
    trap '_poll_loop_shutdown' TERM INT
    log_info "poll: localhost OS loop started (interval ${interval}s, PID $BASHPID)"
    while true; do
        _poll_run_timed "localhost" _poll_with_pipeline_lock \
            "localhost" _poll_collect_os_metrics
        _poll_interruptible_sleep "$interval"
    done
}

poll_db_connectivity() {
    [[ -f "$CONN_FILE" ]] || return 0
    _poll_log_info "poll: checking DB connectivity"
    local -a _db_pids=()
    _poll_db_shutdown() {
        for _p in "${_db_pids[@]:-}"; do kill -TERM "$_p" 2>/dev/null || true; done
        for _p in "${_db_pids[@]:-}"; do wait "$_p" 2>/dev/null || true; done
        exit 0
    }
    trap '_poll_db_shutdown' TERM INT
    if [[ $# -gt 0 ]]; then
        local name
        for name in "$@"; do
            name="${name//[[:space:]]/}"
            [[ -z "$name" ]] && continue
            ( _poll_db_connectivity_named "$name" ) &
            _db_pids+=($!)
        done
    else
        _poll_db_connectivity_parallel() {
            ( _poll_check_db_connection_parsed "$@" ) &
            _db_pids+=($!)
        }
        dbconn_foreach_line _poll_db_connectivity_parallel
    fi
    wait
    trap - TERM INT
}

_poll_db_connectivity_named() {
    local name="$1" line
    line=$(dbconn_get "$name") || {
        log_warn "poll: DB target not found: $name"
        if [[ "${MONITOR_METRIC_STDOUT:-}" == true ]]; then
            echo "=== DB: $name ==="
            echo "(not found — use: bash monitor.sh db list)"
        fi
        return 0
    }
    dbconn_parse_line "$line"
    _poll_check_db_connection_parsed
}

_poll_check_db_connection_parsed() {
    if [[ "${MONITOR_METRIC_STDOUT:-}" == true ]]; then
        echo "=== DB: $_dbc_name (${_dbc_type} ${_dbc_host}:${_dbc_port}) ==="
    fi
    _poll_with_pipeline_lock "db_${_dbc_name}" _poll_check_db_connection \
        "$_dbc_name" "$_dbc_type" "$_dbc_host" "$_dbc_port" "$_dbc_db" "$_dbc_user"
}

_poll_check_db_connection() {
    local name="$1" db_type="$2" host="$3" port="$4" db="$5" user="$6"
    trap 'kill -- -$$ 2>/dev/null || true; trap - TERM' TERM
    poll_entity_log_begin "$name"
    local rc val
    dbconn_run_check "$name"
    rc=$?
    case $rc in
        0) val=0 ;;
        1) val=1 ;;
        2)
            if [[ "${MONITOR_METRIC_STDOUT:-}" == true ]]; then
                echo "(skipped — no client installed for ${db_type})"
            fi
            _poll_log_info "poll: metric [DB] ${name} connection=SKIPPED (no CLI for ${db_type})"
            return 0
            ;;
        3)
            log_warn "poll: DB target not found: $name"
            [[ "${MONITOR_METRIC_STDOUT:-}" == true ]] && echo "(not found — use: bash monitor.sh db list)"
            return 0
            ;;
        *)
            log_warn "poll: metric [DB] ${name} connection=ERROR (${db_type} ${host}:${port})"
            return 0
            ;;
    esac
    if [[ "${MONITOR_METRIC_STDOUT:-}" == true ]]; then
        printf 'connection\t%s\t\n' "$val" | column -t -s $'\t'
    fi
    if [[ "$val" -eq 1 ]]; then
        log_warn "poll: metric [DB] ${name} connection=FAILED (${db_type} ${host}:${port})"
    fi
    poll_evaluate_metric "DB" "$name" "connection" "$val" ""
}

# poll_build_db_name_filter ARRAY_NAME INSTANCES INSTANCE
# Populates named array when filtering one-shot DB polls.
poll_build_db_name_filter() {
    local -n _out=$1
    local instances="${2:-}" instance="${3:-}"
    _out=()
    if [[ -z "$instances" && -z "$instance" ]]; then
        return 0
    fi
    _poll_collect_db_names() { _out+=("$_dbc_name"); }
    if [[ -n "$instances" ]]; then
        if [[ "$instances" == "saved" ]]; then
            dbconn_foreach_line _poll_collect_db_names
        else
            IFS=',' read -ra _out <<< "$instances"
        fi
    elif [[ -n "$instance" ]]; then
        if [[ "$instance" == "saved" ]]; then
            dbconn_foreach_line _poll_collect_db_names
        else
            _out+=("$instance")
        fi
    fi
    unset -f _poll_collect_db_names 2>/dev/null || true
}

# poll_monitor_db_targets SOURCE INST_LIST_REF DB_FILTER_REF TARGETS_REF
# Resolve which DB connection names to poll for monitor.sh one-shot runs.
#   --source db: use explicit filter, or all saved DB targets
#   --source all + --instance: only DB targets whose name matches a Cloud SQL instance id
#   --source all (no instance): all saved DB targets
poll_monitor_db_targets() {
    local source="$1"
    local -n _inst_list=$2
    local -n _db_filter=$3
    local -n _targets=$4
    _targets=()

    if [[ "$source" == "db" ]]; then
        if [[ ${#_db_filter[@]} -gt 0 ]]; then
            _targets=("${_db_filter[@]}")
        else
            _poll_collect_db_names() { _targets+=("$_dbc_name"); }
            dbconn_foreach_line _poll_collect_db_names
            unset -f _poll_collect_db_names 2>/dev/null || true
        fi
        return 0
    fi

    [[ "$source" == "all" ]] || return 0

    if [[ ${#_inst_list[@]} -gt 0 ]]; then
        local inst
        for inst in "${_inst_list[@]}"; do
            inst="${inst//[[:space:]]/}"
            [[ -z "$inst" ]] && continue
            dbconn_get "$inst" >/dev/null 2>&1 && _targets+=("$inst")
        done
        return 0
    fi

    _poll_collect_db_names() { _targets+=("$_dbc_name"); }
    dbconn_foreach_line _poll_collect_db_names
    unset -f _poll_collect_db_names 2>/dev/null || true
}

# poll_display_os_metrics
# One-shot OS poll: localhost + all SSH hosts; record, evaluate thresholds, fire alerts.
poll_display_os_metrics() {
    _poll_with_display_env _poll_display_os_metrics_impl
}

_poll_display_os_metrics_impl() {
    poll_os_metrics
    poll_ssh_hosts_os_metrics
}

# poll_display_db_metrics [NAME ...]
# One-shot DB poll: print metrics to stdout, record history, evaluate thresholds, fire alerts.
poll_display_db_metrics() {
    [[ -f "$CONN_FILE" ]] || {
        echo "No DB targets configured (bash monitor.sh db list)" >&2
        return 0
    }
    _poll_with_display_env poll_db_connectivity "$@"
}

# poll_print_collection_status PREFIX
# Print enabled/disabled lines for run_monitor startup (PREFIX e.g. run_monitor).
poll_print_collection_status() {
    local prefix="${1:-run_monitor}"
    if _poll_include_os_metrics; then
        echo "${prefix}: OS metrics: enabled"
    else
        echo "${prefix}: OS metrics: disabled (collect_os_metrics)"
    fi
    if _poll_include_localhost_os; then
        echo "${prefix}: localhost OS metrics: enabled"
    else
        echo "${prefix}: localhost OS metrics: disabled"
    fi
    if _poll_include_ssh_hosts_os; then
        echo "${prefix}: SSH host OS metrics: enabled"
    else
        echo "${prefix}: SSH host OS metrics: disabled"
    fi
    if _poll_include_cloud_metrics; then
        echo "${prefix}: cloud metrics (GCP): enabled"
    else
        echo "${prefix}: cloud metrics (GCP): disabled (collect_cloud_metrics)"
    fi
    if _poll_include_db_metrics; then
        echo "${prefix}: DB connectivity: enabled"
    else
        echo "${prefix}: DB connectivity: disabled (collect_db_metrics)"
    fi
}
