#!/usr/bin/env bash
# monitor.sh — top-level dispatcher for cloud + OS + DB metric commands
#
# Usage:
#   bash monitor.sh <provider> <command> [options]
#
# Providers:
#   aws       AWS RDS / Aurora
#   gcp       GCP Cloud SQL
#
# Commands (passed through to the provider monitor):
#   daemon <start|stop|restart|status|watchdog>
#   monitor [--instance ID] [--source os|cloud|db]
#   os [--disk /path] [--iface eth0]
#   cloud --instance ID
#   hosts <add|list|delete|test>
#   db <add|add-mysql|list|delete|test>
#   instances <add|list|test|delete>
#   alerts <list|clear> [filters]
#   notify <test|config>
#   thresholds list
#   config get SECTION KEY
#   version
#
# Examples:
#   bash monitor.sh aws instances list
#   bash monitor.sh gcp cloud --instance my-cloudsql
#   bash monitor.sh aws daemon start

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage:
  bash monitor.sh <provider> <command> [options]
  bash monitor.sh <provider> <command> --help   Show help for a specific command

Providers:
  aws    Amazon RDS and Aurora instance monitoring
  gcp    Google Cloud SQL instance monitoring

Commands:
  daemon        Manage the background monitoring daemon
  monitor       One-shot metric fetch and display
  os            Collect local OS metrics (CPU, memory, disk, network)
  cloud         Collect cloud provider metrics for one instance
  hosts         Manage SSH hosts for remote OS metrics
  db            Manage DB connectivity targets
  instances     Register and manage monitored cloud instances
  alerts        View and clear the persistent alert log
  notify        Test notifications and manage credentials
  thresholds    Show active threshold rules
  config        Read a value from config.ini
  version       Print installed version
  uninstall     Stop all agents and remove runtime data

Examples:
  bash monitor.sh aws daemon start
  bash monitor.sh aws instances list
  bash monitor.sh aws instances add --name my-rds --type mysql --region us-east-1
  bash monitor.sh gcp cloud --instance my-cloudsql
  bash monitor.sh gcp alerts list --severity CRITICAL
  bash monitor.sh aws instances --help
EOF
}

provider="${1:-}"
if [[ -z "$provider" || "$provider" == "--help" || "$provider" == "-h" ]]; then
    usage
    exit 0
fi
shift

case "$provider" in
    aws)  variant_dir="${ROOT}/aws" ;;
    gcp)  variant_dir="${ROOT}/gcp" ;;
    *)
        echo "Unknown provider: '${provider}'. Valid providers: aws, gcp" >&2
        usage >&2
        exit 1 ;;
esac

exec bash "${variant_dir}/monitor.sh" "$@"
