#!/usr/bin/env bash
# installer/install.sh — top-level installer for one or more cloud providers
#
# Installs the selected provider(s) by delegating to each provider's own
# installer/install.sh, which handles OS packages, cloud CLI, PBKDF2 helper,
# runtime directories, and default config files.
#
# Usage:
#   bash installer/install.sh                      # install all providers
#   bash installer/install.sh aws                  # install AWS only
#   bash installer/install.sh gcp                  # install GCP only
#   bash installer/install.sh aws gcp              # install both explicitly
#
# Provider-level environment variables are forwarded:
#   INSTALL_PACKAGES=0    Skip OS package installation (check only)
#   INSTALL_DB_CLIENTS=1  Also install mysql/psql clients
#   SUDO=command          Override sudo command

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
  bash installer/install.sh [provider ...]

Providers:
  aws    Install AWS provider (installs AWS CLI v2, Python PBKDF2 helper, runtime dirs, default config)
  gcp    Install GCP provider (installs gcloud CLI, Python PBKDF2 helper, runtime dirs, default config)
         (default: install all providers)

Examples:
  bash installer/install.sh             # install all providers
  bash installer/install.sh aws         # install AWS provider only
  bash installer/install.sh gcp         # install GCP provider only
  bash installer/install.sh aws gcp     # install both explicitly

Environment variables:
  INSTALL_PACKAGES=0    Skip OS package installation (packages already present)
  INSTALL_DB_CLIENTS=1  Also install database client tools (mysql, psql, etc.)
  SUDO=command          Override the sudo command (e.g. SUDO='' to run without sudo)
EOF
}

# Parse arguments — collect requested providers
requested=()
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        aws|gcp)   requested+=("$arg") ;;
        *)
            echo "Unknown provider or option: '$arg'" >&2
            echo "Known providers: ${KNOWN_PROVIDERS[*]}" >&2
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
echo "  DBX Monitor — Provider Installer"
echo "  Root: ${ROOT}"
echo "  Providers: ${providers[*]}"
echo "====================================================="

failed=()
for provider in "${providers[@]}"; do
    provider_dir="${ROOT}/${provider}"
    installer="${provider_dir}/installer/install.sh"

    echo ""
    echo "-----------------------------------------------------"
    echo "  Installing provider: ${provider}"
    echo "-----------------------------------------------------"

    if [[ ! -d "$provider_dir" ]]; then
        warn "Provider directory not found: ${provider_dir} — skipping"
        failed+=("$provider")
        continue
    fi
    if [[ ! -f "$installer" ]]; then
        warn "Installer not found: ${installer} — skipping"
        failed+=("$provider")
        continue
    fi

    if bash "$installer"; then
        ok "Provider '${provider}' installed successfully"
    else
        warn "Provider '${provider}' installer exited with error"
        failed+=("$provider")
    fi
done

echo ""
echo "====================================================="
if [[ ${#failed[@]} -gt 0 ]]; then
    warn "The following provider(s) failed: ${failed[*]}"
    echo ""
    echo "  Re-run for a single failed provider:"
    for p in "${failed[@]}"; do
        echo "    bash ${ROOT}/installer/install.sh ${p}"
    done
    exit 1
else
    ok "All providers installed: ${providers[*]}"
    echo ""
    echo "  Start monitoring (examples):"
    echo "    bash ${ROOT}/monitor.sh aws daemon start"
    echo "    bash ${ROOT}/monitor.sh gcp daemon start"
    echo ""
    echo "  Uninstall:"
    echo "    bash ${ROOT}/installer/uninstall.sh"
fi
echo "====================================================="
echo ""
