#!/usr/bin/env bash
# setup/assemble_thresholds_ini.sh — rebuild metrics_and_thresholds.ini.default + live ini
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${ROOT}/setup"
COMMON_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../common/setup" && pwd)"
DEFAULT_INI="${ROOT}/configs/metrics_and_thresholds.ini.default"
HEADER_MARKER="[metric.gcp."

usage() {
    cat <<EOF
Usage:
  bash setup/assemble_thresholds_ini.sh

Description:
  Rebuild metrics_and_thresholds.ini.default from the catalog TSV files, then
  sync it to metrics_and_thresholds.ini with the default set of metrics enabled.

  This script is run during provider setup whenever the metric catalog changes.
  It assembles sections in order:
    1. File header (from existing .default or live ini)
    2. OS threshold rules  (from common/setup/generate_os_thresholds.sh)
    3. DB connectivity rules  (from common/setup/generate_db_thresholds.sh)
    4. GCP Cloud SQL / Query Insights rules  (from setup/generate_gcp_thresholds.sh)

  Output: configs/metrics_and_thresholds.ini.default
          configs/metrics_and_thresholds.ini  (default metrics enabled)

Options:
  --help, -h  Show this message

Notes:
  To regenerate the catalog TSV files first, run:
    bash setup/export_catalog_tsv.sh
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

read_prefix() {
    local candidate line
    for candidate in "$DEFAULT_INI" "${ROOT}/configs/metrics_and_thresholds.ini"; do
        [[ -f "$candidate" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "$HEADER_MARKER"* ]] && break
            printf '%s\n' "$line"
        done < "$candidate"
        return 0
    done
    echo "No metrics_and_thresholds.ini or .default found for header prefix" >&2
    exit 1
}

{
    read_prefix
    echo
    bash "${COMMON_SETUP}/generate_os_thresholds.sh"
    echo
    bash "${COMMON_SETUP}/generate_db_thresholds.sh"
    echo
    echo "# ============================================================================="
    echo "# CATEGORY 2 - GCP CLOUD SQL METRICS (Cloud Monitoring)"
    echo "# Gated by collect_cloud_metrics in config.ini [monitoring]."
    echo "# metric_name = full GCP metric type (cloudsql.googleapis.com/database/...)"
    echo "# Regenerate catalog: bash setup/assemble_thresholds_ini.sh"
    echo "# ============================================================================="
    echo
    bash "${SETUP}/generate_gcp_thresholds.sh"
} > "$DEFAULT_INI"

echo "Wrote ${DEFAULT_INI}"
bash "${SETUP}/patch_enabled_metrics.sh" --live-only
