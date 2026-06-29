#!/usr/bin/env bash
# lib/ssh_os_metrics.sh — collect OS metrics from a remote host via SSH
# Remote execution is non-interactive: `ssh … bash -s` reads a script on stdin.
# No login shell or TTY is allocated on the remote host.
set -euo pipefail

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

_SSH_LAST_ERROR=""

ssh_last_error() {
    printf '%s' "$_SSH_LAST_ERROR"
}

_ssh_set_error() {
    _SSH_LAST_ERROR="$1"
}

_ssh_control_dir() {
    printf '%s/ssh-control' "$DBMONITOR_RUNTIME"
}

# Reuse SSH master connections during daemon / run_monitor polling.
_ssh_multiplex_enabled() {
    [[ "${MONITOR_SSH_MUX:-true}" == "true" ]] || return 1
    case "${MONITOR_POLL_MODE:-}" in
        daemon|continuous) return 0 ;;
        *) return 1 ;;
    esac
}

_ssh_control_persist_seconds() {
    local configured interval
    configured=$(mcfgi monitoring ssh_control_persist_seconds 0)
    if [[ "$configured" -gt 0 ]]; then
        printf '%s' "$configured"
        return 0
    fi
    interval="${MONITOR_POLL_INTERVAL:-$(mcfgi monitoring default_poll_interval 30)}"
    printf '%s' $(( interval * 2 + 60 ))
}

_ssh_control_path() {
    local host_name="$1"
    local safe="${host_name//[^a-zA-Z0-9._-]/_}"
    printf '%s/%s.sock' "$(_ssh_control_dir)" "$safe"
}

_ssh_ensure_control_dir() {
    local dir; dir=$(_ssh_control_dir)
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
}

# Cached SSH config values — read once per process, reused on every _ssh_build_opts call.
_SSH_CONN_TO="" _SSH_ALIVE_INT="" _SSH_ALIVE_MAX=""

# Build ssh option args into global array _SSH_OPTS.
_ssh_build_opts() {
    local host_name="$1"
    local conn_to alive_int alive_max
    # Read config values once; pcfgi forks an awk subprocess each call
    [[ -z "$_SSH_CONN_TO" ]]    && _SSH_CONN_TO=$(pcfgi ssh connect_timeout_seconds 8)
    [[ -z "$_SSH_ALIVE_INT" ]]  && _SSH_ALIVE_INT=$(pcfgi ssh server_alive_interval_seconds 30)
    [[ -z "$_SSH_ALIVE_MAX" ]]  && _SSH_ALIVE_MAX=$(pcfgi ssh server_alive_count_max 3)
    conn_to="$_SSH_CONN_TO"
    alive_int="$_SSH_ALIVE_INT"
    alive_max="$_SSH_ALIVE_MAX"
    _SSH_OPTS=(
        -T
        -o RequestTTY=no
        -o StrictHostKeyChecking=accept-new
        -o "ConnectTimeout=${conn_to}"
        -o "ServerAliveInterval=${alive_int}"
        -o "ServerAliveCountMax=${alive_max}"
    )
    if _ssh_multiplex_enabled; then
        _ssh_ensure_control_dir
        local persist; persist=$(_ssh_control_persist_seconds)
        _SSH_OPTS+=(
            -o ControlMaster=auto
            -o "ControlPath=$(_ssh_control_path "$host_name")"
            -o "ControlPersist=${persist}s"
        )
    fi
}

# ssh_close_session HOST_NAME — close multiplex master for one host.
ssh_close_session() {
    local host_name="$1"
    local sock; sock=$(_ssh_control_path "$host_name")
    [[ -S "$sock" ]] || return 0
    ssh -o ControlPath="$sock" -O exit dummy 2>/dev/null || rm -f "$sock"
}

# ssh_close_all_sessions — close every multiplex master socket.
ssh_close_all_sessions() {
    local dir; dir=$(_ssh_control_dir)
    [[ -d "$dir" ]] || return 0
    local sock
    for sock in "$dir"/*.sock; do
        [[ -S "$sock" ]] || continue
        ssh -o "ControlPath=$sock" -O exit dummy 2>/dev/null || rm -f "$sock"
    done
}

# _ssh_run_remote HOST_NAME TARGET REMOTE_SCRIPT [DISK_PATH]
# Runs REMOTE_SCRIPT on TARGET via `bash -s` (stdin). Returns:
#   0 = success
#   1 = SSH or remote command failed
#   2 = password auth requested but sshpass is missing
_ssh_run_remote() {
    local host_name="$1" target="$2" remote_script="$3" disk_path="${4:-/}"
    local pass="" rc=0 err
    _ssh_set_error ""

    if [[ -n "$host_name" ]] && cred_exists "ssh_pass_${host_name}"; then
        pass=$(get_cred "ssh_pass_${host_name}")
    fi

    _ssh_build_opts "$host_name"

    if [[ -n "$pass" ]]; then
        if ! command -v sshpass &>/dev/null; then
            err="sshpass is not installed (required for password SSH). Install: sudo apt-get install -y sshpass"
            log_warn "ssh: ${err}"
            _ssh_set_error "$err"
            return 2
        fi
        local _out _stderr_file; _stderr_file=$(mktemp)
        set +e
        _out=$(SSHPASS="$pass" sshpass -e ssh "${_SSH_OPTS[@]}" \
            -o PreferredAuthentications=password,keyboard-interactive \
            -o PubkeyAuthentication=no \
            -o KbdInteractiveAuthentication=yes \
            -o NumberOfPasswordPrompts=1 \
            "$target" bash -s -- "$disk_path" <<< "$remote_script" 2>"$_stderr_file")
        rc=$?
        set -e
        err=$(cat "$_stderr_file" 2>/dev/null || true); rm -f "$_stderr_file"
        if [[ $rc -ne 0 ]]; then
            _ssh_set_error "${err:-SSH password auth failed for ${host_name} (${target})}"
            return 1
        fi
        [[ -n "$err" ]] && log_info "ssh: remote stderr from ${host_name}: ${err}"
        printf '%s' "$_out"
        return 0
    fi

    local _out _stderr_file; _stderr_file=$(mktemp)
    set +e
    _out=$(ssh "${_SSH_OPTS[@]}" -o BatchMode=yes \
        "$target" bash -s -- "$disk_path" <<< "$remote_script" 2>"$_stderr_file")
    rc=$?
    set -e
    err=$(cat "$_stderr_file" 2>/dev/null || true); rm -f "$_stderr_file"
    if [[ $rc -ne 0 ]]; then
        _ssh_set_error "${err:-SSH key auth failed for ${host_name} (${target})}"
        return 1
    fi
    [[ -n "$err" ]] && log_info "ssh: remote stderr from ${host_name}: ${err}"
    printf '%s' "$_out"
    return 0
}

# test_ssh_connection HOST_NAME SSH_TARGET
# Quick non-interactive connectivity check (echo OK via remote bash -s).
# Returns: 0=ok, 1=failed, 2=sshpass missing
test_ssh_connection() {
    local host_name="$1" target="$2"
    local script='echo OK' out rc=0

    [[ -n "$target" ]] || {
        _ssh_set_error "SSH target is empty"
        return 1
    }

    out=$(_ssh_run_remote "$host_name" "$target" "$script" "/" 2>&1) || rc=$?
    if [[ $rc -eq 2 ]]; then
        return 2
    fi
    if [[ $rc -eq 0 && "$out" == *OK* ]]; then
        _ssh_set_error ""
        return 0
    fi
    [[ -z "$(ssh_last_error)" ]] && _ssh_set_error "${out:-SSH remote test command failed}"
    return 1
}

# collect_ssh_os_metrics HOST_NAME SSH_TARGET [DISK_PATH]
# Prints KEY<TAB>VALUE<TAB>UNIT (same schema as collect_os_metrics).
collect_ssh_os_metrics() {
    local host_name="$1" target="$2" disk_path="${3:-/}"
    [[ -n "$target" ]] || return 1

    local remote_script
    remote_script=$(cat <<'EOSSH'
set -euo pipefail
disk_path="${1:-/}"

cpu_percent() {
  # Use a snapshot file to avoid sleep — same approach as the local get_cpu_percent().
  # First call writes a snapshot and returns 0.0; subsequent calls compute the delta.
  local snap="/tmp/.dbmon_cpu_snap_${USER:-root}"
  read -r _ u2 n2 s2 i2 rest < /proc/stat
  if [[ -f "$snap" ]]; then
    local u1 n1 s1 i1
    IFS=$'\t' read -r u1 n1 s1 i1 < "$snap"
    printf '%s\t%s\t%s\t%s\n' "$u2" "$n2" "$s2" "$i2" > "$snap"
    awk -v u1="$u1" -v n1="$n1" -v s1="$s1" -v i1="$i1" -v u2="$u2" -v n2="$n2" -v s2="$s2" -v i2="$i2" 'BEGIN{
      total=(u2+n2+s2+i2)-(u1+n1+s1+i1); idle=i2-i1;
      if(total==0){print "0.0"; exit}
      printf "%.1f\n",(1-idle/total)*100
    }'
  else
    printf '%s\t%s\t%s\t%s\n' "$u2" "$n2" "$s2" "$i2" > "$snap"
    echo "0.0"
  fi
}

mem_pct() {
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{ if(t==0){print "0.0"; exit} printf "%.1f\n",(1-a/t)*100 }' /proc/meminfo
}

mem_free_mb() { awk '/MemAvailable/ { printf "%.1f\n", $2/1024 }' /proc/meminfo; }
disk_free_gb() { df -P "${disk_path}" | awk 'NR==2 { printf "%.2f\n", $4/1024/1024 }'; }
disk_pct() { df -P "${disk_path}" | awk 'NR==2 { gsub(/%/,"",$5); print $5+0 }'; }
load_1m() { awk '{print $1}' /proc/loadavg; }
load_5m() { awk '{print $2}' /proc/loadavg; }
load_15m() { awk '{print $3}' /proc/loadavg; }
swap_used_mb() { awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{ printf "%.1f\n",(t-f)/1024 }' /proc/meminfo; }

printf 'cpu_utilization\t%s\t%%\n'        "$(cpu_percent)"
printf 'memory_utilization\t%s\t%%\n'     "$(mem_pct)"
printf 'free_memory_mb\t%s\tMB\n'         "$(mem_free_mb)"
printf 'free_disk_gb\t%s\tGB\n'           "$(disk_free_gb)"
printf 'disk_utilization\t%s\t%%\n'       "$(disk_pct)"
printf 'load_avg_1m\t%s\t\n'              "$(load_1m)"
printf 'load_avg_5m\t%s\t\n'              "$(load_5m)"
printf 'load_avg_15m\t%s\t\n'             "$(load_15m)"
printf 'swap_used_mb\t%s\tMB\n'           "$(swap_used_mb)"
EOSSH
)

    _ssh_run_remote "$host_name" "$target" "$remote_script" "$disk_path" || return 1
}
