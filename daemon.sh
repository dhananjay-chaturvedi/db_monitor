#!/usr/bin/env bash
# daemon.sh — top-level dispatcher for the monitor daemon lifecycle
#
# Usage:
#   bash daemon.sh <provider> <command> [options]
#
# Providers:
#   aws       AWS RDS / Aurora
#   gcp       GCP Cloud SQL
#
# Commands (passed through to the provider daemon):
#   start [--foreground]   Start the daemon
#   stop                   Stop the daemon
#   restart [--foreground] Stop then start
#   status                 Show running/stopped status
#   watchdog               Start if not running (for crontab)
#   run-loop               Run polling loop in foreground (internal)
#
# Examples:
#   bash daemon.sh aws start
#   bash daemon.sh gcp start --foreground
#   bash daemon.sh aws status
#   bash daemon.sh gcp stop

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage:
  bash daemon.sh <provider> <command> [options]

Providers:
  aws    Amazon RDS and Aurora
  gcp    Google Cloud SQL

Commands:
  start       Start the monitoring daemon in the background
  stop        Stop the running daemon gracefully
  restart     Stop then start the daemon
  status      Show daemon status (running / stopped) and PID
  watchdog    Start the daemon if it is not already running
              (safe to call from cron — no-op when daemon is healthy)
  run-loop    Run the polling loop in the foreground (used internally by start)

Options:
  --foreground   (start / restart) Run in the foreground; logs go to stdout
  --help         Show help for the selected provider's daemon

Examples:
  bash daemon.sh aws start
  bash daemon.sh gcp start --foreground
  bash daemon.sh aws status
  bash daemon.sh gcp stop
  bash daemon.sh aws restart
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

exec bash "${variant_dir}/daemon.sh" "$@"
