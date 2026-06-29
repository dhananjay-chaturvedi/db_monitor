#!/usr/bin/env bash
# lib/db_connections.sh — manage DB connectivity targets
set -euo pipefail

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
# shellcheck source=lib/db_check.sh
source "$(dirname "${BASH_SOURCE[0]}")/db_check.sh"

CONN_FILE="${DBMONITOR_SECRETS}/connections.tsv"

# dbconn_parse_line LINE
# Sets _dbc_name _dbc_type _dbc_host _dbc_port _dbc_db _dbc_user.
dbconn_parse_line() {
    local line="$1"
    IFS=$'\t' read -r _dbc_name _dbc_type _dbc_host _dbc_port _dbc_db _dbc_user <<< "$line"
}

# dbconn_foreach_line CALLBACK
# Invokes CALLBACK once per connection row; sets _dbc_* variables before each call.
dbconn_foreach_line() {
    local callback="$1"
    _dbconn_ensure_file
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        dbconn_parse_line "$line"
        "$callback"
    done < "$CONN_FILE"
}

_dbconn_ensure_file() {
    ensure_dirs
    if [[ ! -f "$CONN_FILE" ]]; then
        install -m 0600 /dev/null "$CONN_FILE"
        printf '# name\ttype\thost\tport\tdatabase\tuser\n' > "$CONN_FILE"
    fi
}

dbconn_add_generic() {
    local name="$1" db_type="$2" host="$3" port="$4" user="$5" db="${6:-}" pass="${7:-}"
    _dbconn_ensure_file
    [[ -n "$name" && -n "$db_type" && -n "$host" && -n "$user" ]] || {
        echo "Usage: dbconn_add_generic NAME TYPE HOST PORT USER [DATABASE] [PASSWORD]" >&2
        return 1
    }
    db_type="${db_type,,}"
    case "$db_type" in
        mysql|mariadb|postgresql|postgres|oracle|sqlserver|mssql|mongodb|documentdb) ;;
        *)
            echo "ERROR: unsupported DB type: $db_type" >&2
            return 1
            ;;
    esac
    [[ "$db_type" == "postgres" ]] && db_type="postgresql"
    [[ "$db_type" == "mssql" ]] && db_type="sqlserver"
    if [[ -z "$port" ]]; then
        port=$(db_default_port "$db_type")
        [[ "$port" -gt 0 ]] || port=""
    fi
    [[ -n "$port" ]] || { echo "ERROR: port required (or set default in properties.ini [database.ports])" >&2; return 1; }

    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="$name" '$1 != n' "$CONN_FILE" > "$tmp"
    mv "$tmp" "$CONN_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$db_type" "$host" "$port" "${db:-}" "$user" >> "$CONN_FILE"
    if [[ -n "$pass" ]]; then
        save_cred "db_pass_${name}" "$pass"
    fi
    echo "Saved DB: $name ($db_type ${host}:${port}${db:+ db=$db})"
}

dbconn_add_mysql_from_args() {
    local name="$1"; shift
    _dbconn_ensure_file

    local host="" port="" user="" db="" pass=""
    port=$(db_default_port mysql)
    [[ "$port" -gt 0 ]] || port=""

    # Parse a subset of mysql args: -h -P -u -p -D
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h) host="$2"; shift 2 ;;
            -P) port="$2"; shift 2 ;;
            -u) user="$2"; shift 2 ;;
            -D) db="$2"; shift 2 ;;
            -p*)
                # -p<PASSWORD> or -p <PASSWORD>
                if [[ "$1" == "-p" ]]; then
                    pass="$2"; shift 2
                else
                    pass="${1#-p}"; shift
                fi
                ;;
            *) shift ;;
        esac
    done

    [[ -n "$host" && -n "$user" ]] || {
        echo "Usage: bash monitor.sh db add-mysql --name NAME -- -h HOST -P PORT -u USER -pPASS [-D DB]" >&2
        return 1
    }
    [[ -n "$port" ]] || { echo "ERROR: mysql port required (set default in properties.ini [database.ports] mysql=)" >&2; return 1; }
    [[ -n "$pass" ]] || { echo "ERROR: mysql password required via -p<PASSWORD> or -p <PASSWORD>" >&2; return 1; }

    # Remove existing record with same name
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="$name" '$1 != n' "$CONN_FILE" > "$tmp"
    mv "$tmp" "$CONN_FILE"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "mysql" "$host" "$port" "${db:-}" "$user" >> "$CONN_FILE"
    save_cred "db_pass_${name}" "$pass"
    echo "Saved DB: $name (mysql $host:$port ${db:+db=$db})"
}

dbconn_list() {
    _dbconn_ensure_file
    printf '%-18s %-10s %-28s %-6s %-14s %s\n' "NAME" "TYPE" "HOST" "PORT" "DB" "USER"
    printf '%s\n' "$(printf '%.0s-' {1..90})"
    dbconn_foreach_line _dbconn_list_row
}

_dbconn_list_row() {
    printf '%-18s %-10s %-28s %-6s %-14s %s\n' \
        "$_dbc_name" "$_dbc_type" "$_dbc_host" "$_dbc_port" "${_dbc_db:-}" "$_dbc_user"
}

dbconn_delete() {
    local name="$1"
    _dbconn_ensure_file
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="$name" '$1 != n' "$CONN_FILE" > "$tmp"
    mv "$tmp" "$CONN_FILE"
    delete_cred "db_pass_${name}" 2>/dev/null || true
    echo "Deleted DB: $name"
}

# dbconn_get NAME → prints "name\ttype\thost\tport\tdb\tuser" or returns 1
dbconn_get() {
    local name="$1" line
    _dbconn_ensure_file
    line=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$CONN_FILE")
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# dbconn_run_check NAME
# Loads target into _dbc_* and runs check_db. Returns 0=ok, 1=failed, 2=no client, 3=not found.
dbconn_run_check() {
    local name="$1" line pass rc
    line=$(dbconn_get "$name") || return 3
    dbconn_parse_line "$line"
    pass=$(get_cred "db_pass_${_dbc_name}")
    set +e
    check_db "$_dbc_type" "$_dbc_host" "$_dbc_port" "$_dbc_db" "$_dbc_user" "$pass" >/dev/null 2>&1
    rc=$?
    set -e
    return "$rc"
}

# dbconn_test NAME — verify DB connectivity for a saved target.
dbconn_test() {
    local name="$1" rc line
    [[ -n "$name" ]] || {
        echo "Usage: bash monitor.sh db test --name NAME" >&2
        return 1
    }
    line=$(dbconn_get "$name") || {
        echo "ERROR: DB target not found: $name" >&2
        return 1
    }
    dbconn_parse_line "$line"
    echo "Testing DB connection: $name ($_dbc_type ${_dbc_host}:${_dbc_port} user=${_dbc_user}${_dbc_db:+ database=$_dbc_db}) ..."
    dbconn_run_check "$name"
    rc=$?
    case $rc in
        0)
            echo "OK: DB connection successful ($name)"
            return 0
            ;;
        1)
            echo "FAILED: cannot connect to $name (${_dbc_type} ${_dbc_host}:${_dbc_port})" >&2
            return 1
            ;;
        2)
            echo "SKIPPED: no client installed for $_dbc_type (install mysql/psql/etc.)" >&2
            return 2
            ;;
        *)
            echo "FAILED: unexpected error testing $name" >&2
            return 1
            ;;
    esac
}

