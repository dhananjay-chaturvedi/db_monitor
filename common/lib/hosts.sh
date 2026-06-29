#!/usr/bin/env bash
# lib/hosts.sh — manage SSH hosts for OS metrics
set -euo pipefail

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
# shellcheck source=lib/ssh_os_metrics.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh_os_metrics.sh"

# Host metadata (no passwords) lives in secrets beside connections.tsv.
HOSTS_FILE="${DBMONITOR_SECRETS}/ssh_hosts.tsv"

_hosts_ensure_file() {
    ensure_dirs
    local legacy="${DBMONITOR_RUNTIME}/ssh_hosts.tsv"
    if [[ ! -f "$HOSTS_FILE" && -f "$legacy" ]]; then
        mv "$legacy" "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE" 2>/dev/null || true
    fi
    if [[ ! -f "$HOSTS_FILE" ]]; then
        printf '# name\tssh_target\tdisk_path\n' > "$HOSTS_FILE"
        chmod 600 "$HOSTS_FILE" 2>/dev/null || true
    fi
}

# hosts_add NAME SSH_TARGET [DISK_PATH] [PASSWORD]
# Password (if provided) is stored encrypted as ssh_pass_<name> in secrets/.
hosts_add() {
    local name="$1" target="$2" disk_path="${3:-/}" password="${4:-}"
    [[ -n "$name" && -n "$target" ]] || {
        echo "Usage: hosts add --name NAME --ssh user@host [--disk /] [--password <PASSWORD>|-p<PASSWORD>]" >&2
        return 1
    }
    _hosts_ensure_file
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="$name" '$1 != n' "$HOSTS_FILE" > "$tmp"
    mv "$tmp" "$HOSTS_FILE"
    printf '%s\t%s\t%s\n' "$name" "$target" "$disk_path" >> "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE" 2>/dev/null || true

    if [[ -n "$password" ]]; then
        save_cred "ssh_pass_${name}" "$password"
        echo "Saved host: $name ($target) [password stored encrypted]"
    else
        echo "Saved host: $name ($target) [key-based SSH]"
    fi
}

hosts_list() {
    _hosts_ensure_file
    printf '%-22s %-32s %-8s %s\n' "NAME" "SSH_TARGET" "AUTH" "DISK"
    printf '%s\n' "$(printf '%.0s-' {1..78})"
    grep -v '^#' "$HOSTS_FILE" | grep -v '^[[:space:]]*$' | while IFS=$'\t' read -r name target disk; do
        local auth="key"
        cred_exists "ssh_pass_${name}" && auth="password"
        printf '%-22s %-32s %-8s %s\n' "$name" "$target" "$auth" "${disk:-/}"
    done
}

hosts_delete() {
    local name="$1"
    _hosts_ensure_file
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="$name" '$1 != n' "$HOSTS_FILE" > "$tmp"
    mv "$tmp" "$HOSTS_FILE"
    delete_cred "ssh_pass_${name}" 2>/dev/null || true
    echo "Deleted host: $name"
}

hosts_load_saved() {
    _hosts_ensure_file
    grep -v '^#' "$HOSTS_FILE" | grep -v '^[[:space:]]*$'
}

# hosts_get NAME → prints "name\ttarget\tdisk" or returns 1
hosts_get() {
    local name="$1" line
    _hosts_ensure_file
    line=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$HOSTS_FILE")
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# hosts_test NAME — verify SSH connectivity to a saved host.
hosts_test() {
    local name="$1" line target disk rc err
    [[ -n "$name" ]] || {
        echo "Usage: bash monitor.sh hosts test --name NAME" >&2
        return 1
    }
    line=$(hosts_get "$name") || {
        echo "ERROR: host not found: $name" >&2
        return 1
    }
    IFS=$'\t' read -r _ target disk <<< "$line"
    disk="${disk:-/}"
    echo "Testing SSH (non-interactive remote command): $name ($target) ..."
    set +e
    test_ssh_connection "$name" "$target"
    rc=$?
    set -e
    err=$(ssh_last_error)
    case $rc in
        0)
            echo "OK: remote command succeeded ($name → $target)"
            return 0
            ;;
        2)
            echo "FAILED: $name ($target)" >&2
            [[ -n "$err" ]] && echo "  $err" >&2
            return 2
            ;;
        *)
            echo "FAILED: cannot run remote command on $name ($target)" >&2
            [[ -n "$err" ]] && echo "  $err" >&2
            return 1
            ;;
    esac
}
