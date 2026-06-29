#!/usr/bin/env bash
# installer/uninstall.sh — stop agents and remove runtime data for one or more providers
#
# Stops all monitoring agents (daemon, run_monitor.sh, in-flight poll cycles),
# closes SSH multiplex sessions, then removes runtime data.
#
# Does NOT remove:
#   - The script bundle (monitor.sh, lib/, configs/, etc.)
#   - configs/config.ini or metrics_and_thresholds.ini (your settings)
#   - OS packages installed by install.sh
#   - Cloud CLIs (aws, gcloud) installed separately
#
# Usage:
#   bash installer/uninstall.sh                    # uninstall all providers
#   bash installer/uninstall.sh aws                # uninstall AWS only
#   bash installer/uninstall.sh gcp                # uninstall GCP only
#   bash installer/uninstall.sh aws gcp            # uninstall both explicitly
#   bash installer/uninstall.sh --yes              # skip confirmation
#   bash installer/uninstall.sh aws --keep-config  # stop agents only

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd -P)"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
fail()  { echo "[FAIL]  $*" >&2; exit 1; }

KNOWN_PROVIDERS=(aws gcp)

usage() {
    cat <<EOF
Usage:
  bash installer/uninstall.sh [provider ...] [options]

Providers:
  aws    Uninstall AWS provider
  gcp    Uninstall GCP provider
         (default: uninstall all providers)

What this removes (default):
  .dbmonitor/    Runtime data: secrets, logs, locks, PID files, connections.tsv
  alerts.log     Project-root alert log file, if present

What this keeps:
  Script bundle  monitor.sh, daemon.sh, run_monitor.sh and all lib/ files
  configs/       config.ini, metrics_and_thresholds.ini, properties.ini
  OS packages    Packages installed by install.sh are not reversed
  Cloud CLIs     aws CLI / gcloud are not uninstalled

Options:
  --yes, -y       Skip the confirmation prompt
  --keep-config   Stop all agents only; do not delete .dbmonitor/ or alerts.log
  --help, -h      Show this message

Examples:
  bash installer/uninstall.sh                     # uninstall all providers (with prompt)
  bash installer/uninstall.sh aws                 # uninstall AWS provider only
  bash installer/uninstall.sh --yes               # uninstall all without prompting
  bash installer/uninstall.sh gcp --keep-config   # stop GCP agents only, keep data
EOF
}

# Parse arguments
requested=()
confirm=true
keep_config=false

for arg in "$@"; do
    case "$arg" in
        --help|-h)     usage; exit 0 ;;
        --yes|-y)      confirm=false ;;
        --keep-config) keep_config=true ;;
        aws|gcp)       requested+=("$arg") ;;
        *)
            echo "Unknown provider or option: '$arg'" >&2
            usage >&2
            exit 1 ;;
    esac
done

# Default to all known providers when none specified
if [[ ${#requested[@]} -eq 0 ]]; then
    requested=("${KNOWN_PROVIDERS[@]}")
fi

# Deduplicate while preserving order
declare -A _seen=()
providers=()
for p in "${requested[@]}"; do
    if [[ -z "${_seen[$p]:-}" ]]; then
        _seen[$p]=1
        providers+=("$p")
    fi
done

echo ""
echo "====================================================="
echo "  DBX Monitor — Provider Uninstaller"
echo "  Root: ${ROOT}"
echo "  Providers: ${providers[*]}"
echo "====================================================="
echo ""

if [[ "$confirm" == "true" ]]; then
    if [[ "$keep_config" == "true" ]]; then
        read -r -p "Stop agents for providers [${providers[*]}] (keep .dbmonitor/)? [y/N] " ans
    else
        read -r -p "Stop agents and remove .dbmonitor/ for providers [${providers[*]}]? [y/N] " ans
    fi
    case "${ans,,}" in
        y|yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# Build forwarded flags for provider uninstallers
fwd_flags=(--yes)
[[ "$keep_config" == "true" ]] && fwd_flags+=(--keep-config)

failed=()
for provider in "${providers[@]}"; do
    provider_dir="${ROOT}/${provider}"
    uninstaller="${provider_dir}/installer/uninstall.sh"

    echo ""
    echo "-----------------------------------------------------"
    echo "  Uninstalling provider: ${provider}"
    echo "-----------------------------------------------------"

    if [[ ! -d "$provider_dir" ]]; then
        warn "Provider directory not found: ${provider_dir} — skipping"
        failed+=("$provider")
        continue
    fi
    if [[ ! -f "$uninstaller" ]]; then
        warn "Uninstaller not found: ${uninstaller} — skipping"
        failed+=("$provider")
        continue
    fi

    if bash "$uninstaller" "${fwd_flags[@]}"; then
        ok "Provider '${provider}' uninstalled"
    else
        warn "Provider '${provider}' uninstaller exited with error"
        failed+=("$provider")
    fi
done

echo ""
echo "====================================================="
if [[ ${#failed[@]} -gt 0 ]]; then
    warn "The following provider(s) had errors: ${failed[*]}"
    exit 1
else
    ok "Uninstall complete for: ${providers[*]}"
fi
echo "====================================================="
echo ""
