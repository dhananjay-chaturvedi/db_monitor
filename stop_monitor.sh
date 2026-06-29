#!/usr/bin/env bash
# stop_monitor.sh — top-level dispatcher to stop run_monitor.sh loops
#
# Usage:
#   bash stop_monitor.sh <provider> [options]
#
# Providers:
#   aws       AWS RDS / Aurora
#   gcp       GCP Cloud SQL
#
# Options (passed through to provider):
#   (no args)               Stop everything
#   --all                   Stop all resources
#   --instance NAME [...]   Stop specific instance loop(s)
#   --db NAME [...]         Stop specific DB connectivity loop(s)
#   --ssh NAME [...]        Stop specific SSH host loop(s)
#   --localhost-os          Stop localhost OS metrics loop
#   --list                  List running loops
#
# Examples:
#   bash stop_monitor.sh aws
#   bash stop_monitor.sh gcp --instance my-cloudsql
#   bash stop_monitor.sh aws --list

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage:
  bash stop_monitor.sh <provider> [options]

Providers:
  aws    Amazon RDS and Aurora
  gcp    Google Cloud SQL

Options:
  (no args)                  Stop all active run_monitor sessions for the provider
  --all                      Same as no args — stop everything
  --instance NAME [...]      Stop the polling loop for one or more instance(s)
  --db NAME [...]            Stop the DB connectivity loop for one or more target(s)
  --ssh NAME [...]           Stop the SSH host OS metrics loop for one or more host(s)
  --localhost-os             Stop the localhost OS metrics collection loop
  --list                     List all running sessions and their loop PIDs
  --help                     Show provider-specific help

Examples:
  bash stop_monitor.sh aws                              # stop all AWS loops
  bash stop_monitor.sh gcp --list                       # list GCP sessions
  bash stop_monitor.sh aws --instance my-rds-instance
  bash stop_monitor.sh gcp --instance my-cloudsql
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

exec bash "${variant_dir}/stop_monitor.sh" "$@"
