#!/usr/bin/env bash
# monitor.sh — main CLI entry point for the monitoring daemon
# Usage: bash monitor.sh <command> [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_ROOT="${SCRIPT_DIR}"
# shellcheck source=../common/lib/util.sh
source "${SCRIPT_DIR}/../common/lib/util.sh"
# shellcheck source=../common/lib/config.sh
source "${SCRIPT_DIR}/../common/lib/config.sh"
# shellcheck source=../common/lib/alerts.sh
source "${SCRIPT_DIR}/../common/lib/alerts.sh"
# shellcheck source=../common/lib/notify.sh
source "${SCRIPT_DIR}/../common/lib/notify.sh"
# shellcheck source=../common/lib/os_metrics.sh
source "${SCRIPT_DIR}/../common/lib/os_metrics.sh"
# shellcheck source=lib/gcp.sh
source "${SCRIPT_DIR}/lib/gcp.sh"
# shellcheck source=../common/lib/thresholds.sh
source "${SCRIPT_DIR}/../common/lib/thresholds.sh"
# shellcheck source=../common/lib/db_check.sh
source "${SCRIPT_DIR}/../common/lib/db_check.sh"
# shellcheck source=../common/lib/db_connections.sh
source "${SCRIPT_DIR}/../common/lib/db_connections.sh"
# shellcheck source=../common/lib/secrets.sh
source "${SCRIPT_DIR}/../common/lib/secrets.sh"
# shellcheck source=lib/instances.sh
source "${SCRIPT_DIR}/lib/instances.sh"
# shellcheck source=lib/poll.sh
source "${SCRIPT_DIR}/lib/poll.sh"
# shellcheck source=../common/lib/hosts.sh
source "${SCRIPT_DIR}/../common/lib/hosts.sh"

config_apply_runtime_paths

VERSION="${VERSION:-$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null || echo "1.0.0")}"

usage() {
    cat <<EOF
monitor.sh v${VERSION} — GCP Cloud SQL metrics, threshold alerts, daemon management

Usage:
  bash monitor.sh <command> [options]
  bash monitor.sh <command> --help     Show help for a specific command

Commands:
  daemon        Manage the background monitoring daemon
                  start | stop | restart | status | watchdog
  monitor       One-shot metric fetch and display for one or more instances
                  [--instance ID] [--instances saved|id1,id2] [--source os|gcp|db]
  os            Collect local OS metrics (CPU, memory, disk, network)
                  [--disk PATH] [--iface IFACE]
  cloud         Collect GCP Cloud SQL Cloud Monitoring metrics for one instance
                  --instance ID
  hosts         Manage SSH hosts for remote OS metric collection
                  add | list | delete | test
  db            Manage DB connectivity targets
                  add | add-mysql | list | delete | test
  instances     Register and manage Cloud SQL instances to monitor
                  add | list | test | delete
  alerts        View and manage the persistent alert log
                  list | clear  [--severity S] [--source S] [--instance I] [--limit N]
  notify        Test notification delivery and manage credentials
                  test | config
  thresholds    Show all active threshold rules from config
  config        Read a single value from config.ini
                  get SECTION KEY
  version       Print the installed version
  uninstall     Stop all agents and remove runtime data

Notes:
  Run 'bash monitor.sh <command> --help' for full options on any command.
  Do not run alongside the daemon — both acquire the poll-cycle lock.
EOF
}

cmd_poll() { _ini_load_global_cache; poll_cycle; }

# ----------------------------------------------------------------
# GCP metric display (shared by monitor + cloud)
# ----------------------------------------------------------------

_print_metric_tsv() {
    local data="$1"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local k v u rest
        k="${line%%$'\t'*}"
        [[ -z "$k" ]] && continue
        rest="${line#*$'\t'}"
        v="${rest%%$'\t'*}"
        u="${rest#*$'\t'}"
        [[ "$u" == "$rest" ]] && u=""
        printf '%s\t%s\t%s\n' "$k" "$(format_metric_value "$v")" "${u:-}"
    done <<< "$data" | column -t -s $'\t'
}

_fetch_and_print_metrics() {
    local lock_entity="$1" busy_msg="$2"
    shift 2
    if entity_fetch_lock_acquire "$lock_entity" 0; then
        local out; out="$("$@" 2>/dev/null || true)"
        entity_fetch_lock_release
        _print_metric_tsv "$out"
    else
        echo "(busy — ${busy_msg}; try again shortly)" >&2
    fi
}

display_instance_gcp_metrics() {
    local inst="$1" inst_type="${2:-}" inst_project="${3:-}"

    echo "=== GCP Cloud Monitoring: $inst ==="
    _fetch_and_print_metrics "$inst" "metrics are being fetched for ${inst}" \
        collect_cloudsql_metrics "$inst" "$inst_type" "$inst_project"

    if gcp_collect_query_insights_enabled_for_instance "$inst"; then
        echo
        echo "=== Query Insights: $inst ==="
        _fetch_and_print_metrics "$inst" "Query Insights metrics are being fetched for ${inst}" \
            collect_cloudsql_query_insights_metrics "$inst"
    fi
}

# ----------------------------------------------------------------
# monitor — one-shot metric display
# ----------------------------------------------------------------
cmd_monitor() {
    local instance="" instances="" source="all"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance|-i) instance="$2"; shift 2 ;;
            --instances)   instances="$2"; shift 2 ;;
            --source|-s)   source="$2";   shift 2 ;;
            --help|-h)     usage; return 0 ;;
            -*)
                echo "Unknown option: $1" >&2
                echo "Usage: bash monitor.sh monitor [--instance ID] [--source os|gcp|db]" >&2
                exit 1
                ;;
            *)
                echo "Unknown argument: $1" >&2
                echo "Usage: bash monitor.sh monitor [--instance ID] [--source os|gcp|db]" >&2
                exit 1
                ;;
        esac
    done

    ensure_dirs

    # Build list of instances to check (if --instances provided)
    local -a inst_list=()
    if [[ -n "$instances" ]]; then
        if [[ "$instances" == "saved" ]]; then
            while IFS=$'\t' read -r n t r p; do
                [[ -z "$n" ]] && continue
                inst_list+=("$n")
            done < <(instances_load_saved) || true
        else
            IFS=',' read -ra inst_list <<< "$instances"
        fi
    elif [[ -n "$instance" ]]; then
        if [[ "$instance" == "saved" ]]; then
            while IFS=$'\t' read -r n t r p; do
                [[ -z "$n" ]] && continue
                inst_list+=("$n")
            done < <(instances_load_saved) || true
        else
            inst_list+=("$instance")
        fi
    fi

    local -a db_list=()
    if [[ "$source" == "db" ]]; then
        poll_build_db_name_filter db_list "$instances" "$instance"
    fi

    if [[ "$source" == "all" || "$source" == "os" ]]; then
        poll_display_os_metrics || true
        echo
    fi

    if [[ ("$source" == "all" || "$source" == "gcp") && ${#inst_list[@]} -gt 0 ]]; then
        local inst
        for inst in "${inst_list[@]}"; do
            inst="${inst//[[:space:]]/}"
            [[ -z "$inst" ]] && continue
        local inst_type="" inst_region="" inst_project=""
        instances_resolve_metadata "$inst" || true
        local _old_project="${CLOUDSDK_CORE_PROJECT:-}"
        local _old_region="${CLOUDSDK_COMPUTE_REGION:-}"
        [[ -n "$inst_project" && "$inst_project" != "-" ]] && export CLOUDSDK_CORE_PROJECT="$inst_project"
        [[ -n "$inst_region" && "$inst_region" != "-" ]]  && export CLOUDSDK_COMPUTE_REGION="$inst_region"
        display_instance_gcp_metrics "$inst" "$inst_type" "$inst_project" || true
        [[ -n "$_old_project" ]] && export CLOUDSDK_CORE_PROJECT="$_old_project" || unset CLOUDSDK_CORE_PROJECT
        [[ -n "$_old_region" ]]  && export CLOUDSDK_COMPUTE_REGION="$_old_region"  || unset CLOUDSDK_COMPUTE_REGION
        echo
        done
    fi

    if [[ "$source" == "all" || "$source" == "db" ]]; then
        local -a db_targets=()
        poll_monitor_db_targets "$source" inst_list db_list db_targets || true
        if [[ ${#db_targets[@]} -gt 0 ]]; then
            poll_display_db_metrics "${db_targets[@]}" || true
        fi
        echo
    fi
}

# ----------------------------------------------------------------
# os — collect and print OS metrics
# ----------------------------------------------------------------
cmd_os() {
    local disk_path="/" iface=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk)  disk_path="$2"; shift 2 ;;
            --iface) iface="$2";     shift 2 ;;
            --help|-h)
                cat <<'EOHELP'
Usage:
  bash monitor.sh os [options]

Description:
  Collect and display local OS metrics: CPU utilisation, free memory,
  disk usage, and network I/O. Records results to the localhost metrics log
  and evaluates any configured threshold rules.

Options:
  --disk PATH    Filesystem path to measure disk usage for (default: /)
  --iface IFACE  Network interface to report on (default: auto-detected)
  --help         Show this message

Examples:
  bash monitor.sh os
  bash monitor.sh os --disk /data
  bash monitor.sh os --disk /var --iface eth0
EOHELP
                return 0
                ;;
            *) shift ;;
        esac
    done
    if entity_fetch_lock_acquire "localhost" 0; then
        local out; out="$(collect_os_metrics "$disk_path" "$iface" || true)"
        entity_fetch_lock_release
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local k v u rest
            k="${line%%$'\t'*}"
            [[ -z "$k" ]] && continue
            rest="${line#*$'\t'}"
            v="${rest%%$'\t'*}"
            u="${rest#*$'\t'}"
            [[ "$u" == "$rest" ]] && u=""
            printf '%s\t%s\t%s\n' "$k" "$(format_metric_value "$v")" "${u:-}"
        done <<< "$out" | column -t -s $'\t'
    else
        echo "(busy — OS metrics are being collected; try again shortly)" >&2
        return 0
    fi
}

# ----------------------------------------------------------------
# cloud — collect GCP Cloud SQL metrics
# ----------------------------------------------------------------
cmd_cloud() {
    local instance=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance|-i) instance="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOHELP'
Usage:
  bash monitor.sh cloud --instance ID

Description:
  One-shot fetch and display of GCP Cloud Monitoring metrics for a single
  Cloud SQL instance. Also fetches Query Insights metrics when enabled for
  the instance in metrics_and_thresholds.ini.

Options:
  --instance, -i ID   Cloud SQL instance identifier (required)
  --help              Show this message

Examples:
  bash monitor.sh cloud --instance prod-cloudsql-1
  bash monitor.sh cloud -i my-postgres-db
EOHELP
                return 0
                ;;
            *) shift ;;
        esac
    done
    if [[ -z "$instance" ]]; then
        echo "Usage: monitor.sh cloud --instance CLOUD_SQL_INSTANCE_ID  (use --help for details)" >&2
        exit 1
    fi
    local inst_type="" inst_region="" inst_project=""
    instances_resolve_metadata "$instance"
    local _old_project="${CLOUDSDK_CORE_PROJECT:-}"
    local _old_region="${CLOUDSDK_COMPUTE_REGION:-}"
    [[ -n "$inst_project" && "$inst_project" != "-" ]] && export CLOUDSDK_CORE_PROJECT="$inst_project"
    [[ -n "$inst_region" && "$inst_region" != "-" ]]   && export CLOUDSDK_COMPUTE_REGION="$inst_region"

    display_instance_gcp_metrics "$instance" "$inst_type" "$inst_project"

    [[ -n "$_old_project" ]] && export CLOUDSDK_CORE_PROJECT="$_old_project" || unset CLOUDSDK_CORE_PROJECT
    [[ -n "$_old_region" ]]  && export CLOUDSDK_COMPUTE_REGION="$_old_region"  || unset CLOUDSDK_COMPUTE_REGION
}

# ----------------------------------------------------------------
# hosts — manage SSH hosts for OS metrics
# ----------------------------------------------------------------
cmd_hosts() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)
            local name="" ssh_target="" disk="/" password=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    --ssh)     ssh_target="$2"; shift 2 ;;
                    --disk)    disk="$2"; shift 2 ;;
                    --password) password="$2"; shift 2 ;;
                    -p*)       password="${1#-p}"; shift ;;
                    *) shift ;;
                esac
            done
            hosts_add "$name" "$ssh_target" "$disk" "$password"
            ;;
        list)
            hosts_list
            ;;
        delete)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            hosts_delete "$name"
            ;;
        test)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            hosts_test "$name"
            ;;
        *)
            cat <<'EOHELP' >&2
Usage:
  bash monitor.sh hosts <subcommand> [options]

Subcommands:
  add     --name NAME --ssh TARGET [--disk PATH] [--password <PASSWORD>]
          Register an SSH host for remote OS metric collection
  list    Show all saved SSH hosts
  test    --name NAME   Test SSH connectivity and metric collection
  delete  --name NAME   Remove a saved SSH host
EOHELP
            ;;
    esac
}

# ----------------------------------------------------------------
# db — manage DB connectivity targets
# ----------------------------------------------------------------
_cmd_db_add_usage() {
    cat <<EOF
Usage:
  bash monitor.sh db add --name NAME --type TYPE --host HOST --port PORT --user USER [options]

Required:
  --name, -n NAME      Unique connection name (used as identifier in the connection list)
  --type, -t TYPE      Database type: mysql | postgresql | oracle | sqlserver | mariadb | mongodb
  --host HOST          Database hostname or IP address
  --port, -P PORT      TCP port number
  --user, -u USER      Database username for the monitoring connection

Optional:
  --database, -D NAME  Database name or Oracle service name to connect to
  --password, -p <PASSWORD>  Password (stored encrypted in secrets store; omit to prompt or set later)
  --help               Show this message

Examples:
  bash monitor.sh db add --name prod-pg --type postgresql \\
      --host db.example.com --port 5432 --user monitor --database appdb
  bash monitor.sh db add --name prod-mysql --type mysql \\
      --host db.example.com --port 3306 --user dbmon

Notes:
  Passwords are stored encrypted. Use 'bash monitor.sh db test --name NAME' to verify connectivity.
EOF
}

cmd_db() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)
            local name="" db_type="" host="" port="" user="" db="" pass=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help|-h)
                        _cmd_db_add_usage
                        return 0
                        ;;
                    --name|-n)
                        [[ $# -ge 2 ]] || { echo "ERROR: --name requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        name="$2"; shift 2
                        ;;
                    --type|-t)
                        [[ $# -ge 2 ]] || { echo "ERROR: --type requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        db_type="$2"; shift 2
                        ;;
                    --host)
                        [[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        host="$2"; shift 2
                        ;;
                    --port|-P)
                        [[ $# -ge 2 ]] || { echo "ERROR: --port requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        port="$2"; shift 2
                        ;;
                    --user|-u)
                        [[ $# -ge 2 ]] || { echo "ERROR: --user requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        user="$2"; shift 2
                        ;;
                    --database|-D)
                        [[ $# -ge 2 ]] || { echo "ERROR: --database requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        db="$2"; shift 2
                        ;;
                    --password|-p)
                        [[ $# -ge 2 ]] || { echo "ERROR: --password requires a value" >&2; _cmd_db_add_usage >&2; return 1; }
                        pass="$2"; shift 2
                        ;;
                    *)
                        echo "ERROR: unknown option: $1" >&2
                        _cmd_db_add_usage >&2
                        return 1
                        ;;
                esac
            done
            dbconn_add_generic "$name" "$db_type" "$host" "$port" "$user" "$db" "$pass"
            ;;
        add-mysql)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    --) shift; break ;;
                    *) shift ;;
                esac
            done
            # Remaining args are mysql flags: -h -P -u -p -D
            dbconn_add_mysql_from_args "$name" "$@"
            ;;
        list)
            dbconn_list
            ;;
        delete)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            dbconn_delete "$name"
            delete_cred "db_pass_${name}" 2>/dev/null || true
            ;;
        test)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            dbconn_test "$name"
            ;;
        --help|help)
            cat <<EOF
Usage:
  bash monitor.sh db <subcommand> [options]

Subcommands:
  add          Add a DB connectivity target (structured flags)
  add-mysql    Add a MySQL/MariaDB target using mysql-style flags after --
  list         List all saved DB connectivity targets
  delete       Remove a saved target  --name NAME
  test         Test connectivity to a saved target  --name NAME

Examples:
  bash monitor.sh db add --help
  bash monitor.sh db list
  bash monitor.sh db test --name prod-pg
  bash monitor.sh db delete --name old-db
EOF
            ;;
        *)
            echo "Usage: bash monitor.sh db <add|add-mysql|list|delete|test>" >&2
            echo "  Run 'bash monitor.sh db --help' for subcommand descriptions." >&2
            ;;
    esac
}

# ----------------------------------------------------------------
# instances
# ----------------------------------------------------------------
cmd_instances() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)
            local name="" type="" region="" project=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n)    name="$2";    shift 2 ;;
                    --type|-t)    type="$2";    shift 2 ;;
                    --project|-p) project="$2"; shift 2 ;;
                    --region|-r)  region="$2";  shift 2 ;;
                    *) shift ;;
                esac
            done
            instances_add "$name" "$type" "$project" "$region"
            ;;
        list)
            instances_list
            ;;
        test)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    --help|-h)
                        cat <<EOF
Usage:
  bash monitor.sh instances test --name ID

Description:
  Verifies that a saved Cloud SQL instance is reachable. Checks that:
    - The instance ID exists in GCP (via gcloud sql instances describe)
    - Cloud Monitoring can return a CPUUtilization datapoint for it
    - The configured GCP project is correct

Examples:
  bash monitor.sh instances test --name prod-cloudsql
EOF
                        return 0
                        ;;
                    *) shift ;;
                esac
            done
            instances_test "$name"
            ;;
        delete|remove)
            local name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name|-n) name="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            instances_delete "$name"
            ;;
        --help|help)
            cat <<EOF
Usage:
  bash monitor.sh instances <subcommand> [options]

Subcommands:
  add     --name ID --type TYPE [--project PROJECT] [--region REGION]
          Register a Cloud SQL instance for continuous monitoring
  list    Show all saved instances with type, project, and region
  test    --name ID   Verify the instance exists and Cloud Monitoring is reachable
  delete  --name ID   Remove a saved instance from the monitor list

Supported types:
  mysql        Cloud SQL MySQL
  postgresql   Cloud SQL PostgreSQL
  sqlserver    Cloud SQL SQL Server

Examples:
  bash monitor.sh instances add --name prod-db --type postgresql --project my-gcp-project
  bash monitor.sh instances list
  bash monitor.sh instances test --name prod-db
  bash monitor.sh instances delete --name old-db
EOF
            ;;
        *)
            echo "Unknown subcommand: $sub" >&2
            echo "Run 'bash monitor.sh instances --help' for usage." >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# alerts
# ----------------------------------------------------------------
cmd_alerts() {
    local action="${1:-list}"; shift || true
    case "$action" in
        list)  list_alerts "$@" ;;
        clear) clear_alerts "$@" ;;
        --help|-h)
            cat <<'EOHELP'
Usage:
  bash monitor.sh alerts <subcommand> [options]

Description:
  View or clear entries in the persistent alert log (alerts.log).

Subcommands:
  list    Display recent alerts, newest first
  clear   Remove matching alerts from the log (no args = clear all)

Options for list:
  --severity LEVEL   Filter by severity: INFO | WARNING | CRITICAL
  --source SRC       Filter by alert source (e.g. GCP, OS, DB)
  --instance INST    Filter by instance name
  --limit N          Maximum number of entries to show (default: 50)

Options for clear:
  --severity LEVEL   Remove only alerts of this severity
  --source SRC       Remove only alerts from this source
  --instance INST    Remove only alerts for this instance

  --help             Show this message

Examples:
  bash monitor.sh alerts list
  bash monitor.sh alerts list --severity CRITICAL
  bash monitor.sh alerts list --instance prod-cloudsql-1 --limit 20
  bash monitor.sh alerts clear
  bash monitor.sh alerts clear --severity INFO
EOHELP
            return 0
            ;;
        *)
            echo "Unknown subcommand: $action" >&2
            echo "Run 'bash monitor.sh alerts --help' for usage." >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# notify
# ----------------------------------------------------------------
_usage_notify() {
    cat <<'EOHELP'
Usage:
  bash monitor.sh notify <subcommand> [options]

Description:
  Test notification delivery and manage stored credentials. Credentials
  (webhook URLs, passwords) are encrypted at rest in .dbmonitor/secrets/.

Subcommands:
  test          Send a test alert through all configured channels
  config set    Store a notification credential
  config get    Retrieve a stored notification credential

Options for test:
  --severity LEVEL   Alert severity: INFO | WARNING | CRITICAL (default: INFO)
  --message TEXT     Alert body text (default: "Test alert from monitor.sh")

Options for config set:
  --key KEY          Credential name (required)
  --value VALUE      Credential value (required)

Options for config get:
  --key KEY          Credential name to retrieve (required)

  --help             Show this message

Examples:
  bash monitor.sh notify test
  bash monitor.sh notify test --severity WARNING --message "Disk check"
  bash monitor.sh notify config set --key teams_webhook_url --value https://...
  bash monitor.sh notify config get --key teams_webhook_url

Notes:
  Supported credential keys: teams_webhook_url, smtp_password
  Notification channels are configured in config.ini [notifications].
EOHELP
}

cmd_notify() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        --help|-h) _usage_notify; return 0 ;;
        test)
            local severity="INFO" message="Test alert from monitor.sh"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --severity) severity="$2"; shift 2 ;;
                    --message)  message="$2";  shift 2 ;;
                    --help|-h)  _usage_notify; return 0 ;;
                    *) shift ;;
                esac
            done
            dispatch_alert "$severity" "test" "monitor.sh" "$message"
            echo "Test alert dispatched (severity: $severity)"
            ;;
        config)
            local action="${1:-}"; shift || true
            case "$action" in
                set)
                    local key="" value=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --key)   key="$2";   shift 2 ;;
                            --value) value="$2"; shift 2 ;;
                            --help|-h) _usage_notify; return 0 ;;
                            *) shift ;;
                        esac
                    done
                    [[ -z "$key" ]] && { echo "--key is required  (use --help for details)" >&2; exit 1; }
                    save_cred "$key" "$value"
                    echo "Saved credential: $key"
                    ;;
                get)
                    local key=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --key) key="$2"; shift 2 ;;
                            --help|-h) _usage_notify; return 0 ;;
                            *) shift ;;
                        esac
                    done
                    [[ -z "$key" ]] && { echo "--key is required  (use --help for details)" >&2; exit 1; }
                    get_cred "$key"
                    ;;
                --help|-h) _usage_notify; return 0 ;;
                *)
                    echo "Usage: monitor.sh notify config <set|get> --key K [--value V]" >&2
                    echo "Run 'bash monitor.sh notify --help' for full usage." >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Unknown subcommand: ${sub:-}" >&2
            echo "Run 'bash monitor.sh notify --help' for usage." >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# thresholds
# ----------------------------------------------------------------
_thresholds_rule_has_override() {
    local instance="$1" section="$2" key
    for key in enabled collect operator unit window critical warning info description; do
        thresh_ini_key_present "$instance" "$section" "$key" && return 0
    done
    return 1
}

_thresholds_print_rule() {
    local instance="$1" section="$2" use_overlay="$3"
    local enabled desc op crit warn unit status mark=""
    if [[ "$use_overlay" == "1" ]]; then
        enabled=$(thresh_ini_get "$instance" "$section" "enabled" "true")
        desc=$(thresh_ini_get    "$instance" "$section" "description" "")
        op=$(thresh_ini_get      "$instance" "$section" "operator" ">")
        crit=$(thresh_ini_get    "$instance" "$section" "critical" "")
        warn=$(thresh_ini_get    "$instance" "$section" "warning" "")
        unit=$(thresh_ini_get    "$instance" "$section" "unit" "")
        _thresholds_rule_has_override "$instance" "$section" && mark="*"
    else
        enabled=$(ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "enabled" "true")
        desc=$(ini_get    "$METRICS_AND_THRESHOLDS_INI" "$section" "description" "")
        op=$(ini_get      "$METRICS_AND_THRESHOLDS_INI" "$section" "operator" ">")
        crit=$(ini_get    "$METRICS_AND_THRESHOLDS_INI" "$section" "critical" "")
        warn=$(ini_get    "$METRICS_AND_THRESHOLDS_INI" "$section" "warning" "")
        unit=$(ini_get    "$METRICS_AND_THRESHOLDS_INI" "$section" "unit" "")
    fi
    [[ "${enabled,,}" == "true" ]] && status="ON" || status="OFF"
    printf '%-8s %-55s %s %s CRIT=%s WARN=%s %s%s\n' \
        "[$status]" "$section" "$op" "$unit" "$crit" "$warn" "$desc" "$mark"
}

_usage_thresholds() {
    cat <<'EOHELP'
Usage:
  bash monitor.sh thresholds list [options]

Description:
  Print all metric threshold rules from metrics_and_thresholds.ini.
  When --instance is given, shows the effective merged ruleset for that
  instance, combining the global catalog with its per-instance overlay file.
  Rules overridden in the instance overlay are marked with *.

Options:
  --instance, -i ID   Show merged thresholds for a specific saved instance
  --help              Show this message

Examples:
  bash monitor.sh thresholds list
  bash monitor.sh thresholds list --instance prod-cloudsql-1

Notes:
  Per-instance overlay files live under:
    configs/thresholds/<instance>.ini
  Create an overlay with: bash setup/scaffold_instance_thresholds.sh INSTANCE
EOHELP
}

cmd_thresholds() {
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { _usage_thresholds; return 0; }
    local sub="${1:-list}"; shift || true
    local instance=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance|-i) instance="$2"; shift 2 ;;
            --help|-h)     _usage_thresholds; return 0 ;;
            *) break ;;
        esac
    done
    case "$sub" in
        list)
            if [[ -n "$instance" ]]; then
                local inst_file; inst_file=$(instance_thresholds_ini "$instance")
                echo "Effective threshold rules for instance: $instance"
                echo "Global catalog: $METRICS_AND_THRESHOLDS_INI"
                echo "Instance overlay: $inst_file"
                echo "(* = value overridden in instance overlay)"
                echo
                thresh_ini_sections "$instance" | grep '^metric\.' | while IFS= read -r section; do
                    _thresholds_print_rule "$instance" "$section" "1"
                done
            else
                echo "Threshold rules from: $METRICS_AND_THRESHOLDS_INI"
                echo
                ini_sections "$METRICS_AND_THRESHOLDS_INI" | grep '^metric\.' | while IFS= read -r section; do
                    _thresholds_print_rule "" "$section" "0"
                done
            fi
            ;;
        --help|-h)
            _usage_thresholds
            ;;
        *)
            echo "Unknown subcommand: $sub" >&2
            echo "Run 'bash monitor.sh thresholds --help' for usage." >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# config
# ----------------------------------------------------------------
cmd_config() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        get)
            local section="${1:-}" key="${2:-}"
            [[ -z "$section" || -z "$key" ]] && {
                echo "Usage: monitor.sh config get SECTION KEY  (use --help for details)" >&2
                exit 1
            }
            local val
            val=$(pcfg "$section" "$key" "")
            if [[ -n "$val" ]]; then
                echo "$val"
            else
                ini_get "$CONFIG_INI" "$section" "$key"
            fi
            ;;
        --help|-h)
            cat <<'EOHELP'
Usage:
  bash monitor.sh config get SECTION KEY

Description:
  Read a single configuration value. Checks properties.ini first,
  then falls back to config.ini.

Arguments:
  SECTION   INI section name (e.g. monitoring, notifications, ssh, lifecycle)
  KEY       Key name within that section

  --help    Show this message

Examples:
  bash monitor.sh config get monitoring default_poll_interval
  bash monitor.sh config get monitoring poll_cycle_timeout_seconds
  bash monitor.sh config get notifications min_severity
  bash monitor.sh config get ssh connect_timeout_seconds
  bash monitor.sh config get lifecycle signal_escalation_delay_seconds
EOHELP
            return 0
            ;;
        *)
            echo "Unknown subcommand: ${sub:-}" >&2
            echo "Run 'bash monitor.sh config --help' for usage." >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# dispatch
# ----------------------------------------------------------------
case "${1:-}" in
    daemon)         shift; exec bash "${SCRIPT_DIR}/daemon.sh" "$@" ;;
    instances|instance) shift; cmd_instances "$@" ;;
    hosts)         shift; cmd_hosts "$@" ;;
    db)            shift; cmd_db "$@" ;;
    monitor)        shift; cmd_monitor "$@" ;;
    os)             shift; cmd_os "$@" ;;
    cloud)          shift; cmd_cloud "$@" ;;
    alerts)         shift; cmd_alerts "$@" ;;
    notify)         shift; cmd_notify "$@" ;;
    thresholds)     shift; cmd_thresholds "$@" ;;
    config)         shift; cmd_config "$@" ;;
    version)        echo "monitor.sh v${VERSION}" ;;
    uninstall)      shift; exec bash "${SCRIPT_DIR}/installer/uninstall.sh" "$@" ;;
    _poll)          cmd_poll ;;
    --help|-h|help) usage ;;
    "")             usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
