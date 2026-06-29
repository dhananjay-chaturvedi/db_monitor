#!/usr/bin/env bash
# uninstall.sh — stop agents and remove runtime data created by the monitor
#
# Does NOT remove:
#   - The script bundle (monitor.sh, lib/, configs/, etc.)
#   - configs/config.ini or metrics_and_thresholds.ini (your settings)
#   - OS packages installed by installer/install.sh (sshpass, curl, DB clients, etc.)
#   - AWS CLI v2 (installed separately under /usr/local/aws-cli)
#
# Usage:
#   bash installer/uninstall.sh
#   bash installer/uninstall.sh --yes          # skip confirmation prompt
#   bash installer/uninstall.sh --keep-config  # stop agents only, keep .dbmonitor/

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MONITOR_ROOT="${BUNDLE_DIR}"

# shellcheck source=../../common/lib/lifecycle.sh
source "${BUNDLE_DIR}/../common/lib/lifecycle.sh"

usage() {
    cat <<EOF
Usage:
  bash installer/uninstall.sh [options]

Description:
  Stops all monitoring agents (daemon, run_monitor.sh, in-flight poll cycles),
  closes SSH multiplex sessions, then removes runtime data created by this tool.

What this removes (default):
  .dbmonitor/    Runtime data: secrets, logs, locks, PID files, connections.tsv
  alerts.log     Project-root alert log file, if present

What this keeps:
  Script bundle  ${BUNDLE_DIR}
  configs/       config.ini, metrics_and_thresholds.ini, properties.ini
  OS packages    Packages installed by install.sh are not reversed (apt/yum)
  AWS CLI v2     Not uninstalled (installed under /usr/local/aws-cli)

Options:
  --yes, -y       Skip the confirmation prompt
  --keep-config   Stop all agents only; do not delete .dbmonitor/ or alerts.log
  --help, -h      Show this message

Examples:
  bash installer/uninstall.sh                   # uninstall with prompt
  bash installer/uninstall.sh --yes             # uninstall without prompting
  bash installer/uninstall.sh --keep-config     # stop agents only, keep data

Equivalent:
  bash monitor.sh uninstall [--yes] [--keep-config]
EOF
}

confirm=true
keep_config=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)      confirm=false; shift ;;
        --keep-config) keep_config=true; shift ;;
        --help|-h)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

echo ""
echo "====================================================="
echo "  Monitoring Daemon Uninstaller"
echo "  Bundle: ${BUNDLE_DIR}"
echo "====================================================="
echo ""

if [[ "$confirm" == "true" ]]; then
    if [[ "$keep_config" == "true" ]]; then
        read -r -p "Stop all monitoring agents (keep .dbmonitor/)? [y/N] " ans
    else
        read -r -p "Stop agents and remove .dbmonitor/ runtime data? [y/N] " ans
    fi
    case "${ans,,}" in
        y|yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

agent_stop_all

if [[ "$keep_config" == "true" ]]; then
    echo ""
    echo "Agents stopped. Runtime data kept (--keep-config)."
    echo "  ${DBMONITOR_HOME:-${BUNDLE_DIR}/.dbmonitor} was not deleted."
else
    agent_remove_data
    echo ""
    echo "Uninstall complete."
    echo ""
    echo "  Removed: .dbmonitor/ and alerts.log (if present)"
    echo "  Kept:    script bundle and configs/ under:"
    echo "             ${BUNDLE_DIR}"
    echo ""
    echo "  To recreate runtime directories:"
    echo "    bash ${BUNDLE_DIR}/installer/install.sh"
    echo ""
    echo "  To remove edited configs manually:"
    echo "    rm -f ${BUNDLE_DIR}/configs/config.ini"
    echo "    rm -f ${BUNDLE_DIR}/configs/metrics_and_thresholds.ini"
fi
echo "====================================================="
echo ""
