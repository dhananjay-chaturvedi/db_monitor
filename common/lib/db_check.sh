#!/usr/bin/env bash
# lib/db_check.sh — optional DB connectivity tests via CLI tools
# Each function returns: 0=ok, 1=connection failed, 2=no client installed
# All clients are optional — monitoring continues without them.

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# check_postgresql HOST PORT DB USER PASS [TIMEOUT]
check_postgresql() {
    command -v psql &>/dev/null || return 2
    local host="$1" port="$2" db="$3" user="$4" pass="$5" timeout="${6:-$(db_connection_timeout_seconds)}"
    PGPASSWORD="$pass" PGCONNECT_TIMEOUT="$timeout" \
        psql -h "$host" -p "$port" -U "$user" ${db:+-d "$db"} \
             -c '\q' -w -q 2>/dev/null
}

# check_mysql HOST PORT DB USER PASS [TIMEOUT]
check_mysql() {
    command -v mysql &>/dev/null || return 2
    local host="$1" port="$2" db="$3" user="$4" pass="$5" timeout="${6:-$(db_connection_timeout_seconds)}"
    MYSQL_PWD="$pass" mysql -h "$host" -P "$port" -u "$user" ${db:+-D "$db"} \
          --connect-timeout="$timeout" -e 'SELECT 1' --silent 2>/dev/null
}

# check_mariadb — same client as mysql
check_mariadb() { check_mysql "$@"; }

# check_sqlserver HOST PORT DB USER PASS [TIMEOUT]
check_sqlserver() {
    command -v sqlcmd &>/dev/null || return 2
    local host="$1" port="$2" db="$3" user="$4" pass="$5" timeout="${6:-$(db_connection_timeout_seconds)}"
    # SQLCMDPASSWORD env var keeps the password out of the process argument list
    SQLCMDPASSWORD="$pass" sqlcmd -S "${host},${port}" ${db:+-d "$db"} -U "$user" \
           -l "$timeout" -Q 'SELECT 1' 2>/dev/null
}

# check_oracle HOST PORT SERVICE USER PASS [TIMEOUT]
check_oracle() {
    command -v sqlplus &>/dev/null || return 2
    oracle_client_path_prefix
    local host="$1" port="$2" service="$3" user="$4" pass="$5" timeout="${6:-$(db_connection_timeout_seconds)}"
    # Password is passed via stdin (/ in connection string triggers stdin prompt read)
    printf '%s\nSELECT 1 FROM DUAL;\nexit\n' "$pass" \
        | timeout "$timeout" sqlplus -S -L "${user}/@//${host}:${port}/${service}" 2>/dev/null \
        | grep -qE '^[[:space:]]*1'
}

check_mongodb() {
    command -v mongosh &>/dev/null || return 2
    local host="$1" port="$2" db="$3" user="$4" pass="$5" timeout="${6:-$(db_connection_timeout_seconds)}"
    printf '%s\n' "$pass" | \
        mongosh --host "$host" --port "$port" --username "$user" --passwordPrompt \
        ${db:+--authenticationDatabase "$db"} --quiet \
        --eval 'db.runCommand({ping:1})' \
        --serverSelectionTimeoutMS $(( timeout * 1000 )) 2>/dev/null | \
        grep -qE '"ok"\s*:\s*1|ok:\s*1'
}

# check_db TYPE HOST PORT DB USER PASS [TIMEOUT]
# Dispatches to the right check function.
check_db() {
    local db_type="${1,,}" host="$2" port="$3" db="$4" user="$5" pass="$6" timeout="${7:-$(db_connection_timeout_seconds)}"
    case "$db_type" in
        postgresql|postgres)    check_postgresql "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        mysql)                  check_mysql      "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        mariadb)                check_mariadb    "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        sqlserver|mssql)        check_sqlserver  "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        oracle)                 check_oracle     "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        mongodb|documentdb)     check_mongodb    "$host" "$port" "$db" "$user" "$pass" "$timeout" ;;
        sqlite)
            [[ -f "$db" ]] && return 0 || return 1
            ;;
        *)
            log_warn "db_check: unsupported type '$db_type' — skipping"
            return 2
            ;;
    esac
}
