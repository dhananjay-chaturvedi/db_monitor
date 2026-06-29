#!/usr/bin/env bash
# setup/scaffold_instance_thresholds.sh — create a per-instance threshold overlay stub
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  bash setup/scaffold_instance_thresholds.sh INSTANCE [options]

Description:
  Create a per-instance threshold overlay INI stub at:
    configs/thresholds/INSTANCE.ini

  The overlay lets you override any threshold values from the global
  metrics_and_thresholds.ini for a specific instance without affecting others.
  Edit the generated file to customise warning/critical thresholds.

Arguments:
  INSTANCE    Instance identifier (must match a saved instance name)

Options:
  --force     Overwrite an existing overlay file
  --help, -h  Show this message

Examples:
  bash setup/scaffold_instance_thresholds.sh prod-cloudsql-1
  bash setup/scaffold_instance_thresholds.sh prod-cloudsql-1 --force
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

# shellcheck source=lib/util.sh
source "${ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${ROOT}/lib/config.sh"

INSTANCE="${1:-}"
FORCE=0
[[ "${2:-}" == "--force" ]] && FORCE=1

if [[ -z "$INSTANCE" ]]; then
    echo "Error: INSTANCE argument is required." >&2
    usage >&2
    exit 1
fi

OUT=$(instance_thresholds_ini "$INSTANCE")
STATUS=$(scaffold_instance_thresholds_overlay "$INSTANCE" "$FORCE")

case "$STATUS" in
    created) echo "Created ${OUT}" ;;
    exists)
        if [[ "$FORCE" -eq 1 ]]; then
            echo "Created ${OUT}"
        else
            echo "Already exists: ${OUT} (use --force to overwrite)" >&2
            exit 1
        fi
        ;;
esac
