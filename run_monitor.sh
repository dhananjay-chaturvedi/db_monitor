#!/usr/bin/env bash
# run_monitor.sh — top-level dispatcher for foreground continuous monitoring
#
# Usage:
#   bash run_monitor.sh <provider> <instance1> [instance2 ...] [options]
#   bash run_monitor.sh <provider> --instances id1,id2,id3 [options]
#
# Providers:
#   aws       AWS RDS / Aurora
#   gcp       GCP Cloud SQL
#
# Options (passed through to provider):
#   --interval SECS           Poll interval (default: from config)
#   --include-localhost       Force localhost OS metrics on
#   --include-db              Force DB connectivity checks on
#   --project PROJECT         (gcp only) Override GCP project
#
# Examples:
#   bash run_monitor.sh aws my-rds-1 my-rds-2
#   bash run_monitor.sh gcp my-cloudsql --project my-gcp-project
#   bash run_monitor.sh aws --instances inst-a,inst-b --interval 60

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage:
  bash run_monitor.sh <provider> <instance1> [instance2 ...] [options]
  bash run_monitor.sh <provider> --instances id1,id2,id3 [options]
  bash run_monitor.sh <provider> --help   Show provider-specific options

Providers:
  aws    Amazon RDS and Aurora instances
  gcp    Google Cloud SQL instances

Common options:
  --instances ID,...     Comma-separated list of instance IDs
  --interval SECS        Poll interval in seconds (default: from config.ini)
  --include-localhost    Force localhost OS metrics collection on
  --no-include-localhost Force localhost OS metrics collection off
  --include-db           Force DB connectivity checks on
  --no-include-db        Force DB connectivity checks off
  --project PROJECT      (gcp only) GCP project ID override
  --help                 Show provider-specific help with all options

Examples:
  bash run_monitor.sh aws my-rds-1 my-rds-2
  bash run_monitor.sh aws --instances inst-a,inst-b --interval 60
  bash run_monitor.sh gcp my-cloudsql --project my-gcp-project
  bash run_monitor.sh aws --help
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

exec bash "${variant_dir}/run_monitor.sh" "$@"
