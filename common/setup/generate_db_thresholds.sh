#!/usr/bin/env bash
# setup/generate_db_thresholds.sh — emit DB connectivity INI sections
set -euo pipefail
COMMON_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage:
  bash common/setup/generate_db_thresholds.sh

Description:
  Generate INI threshold sections for DB connectivity metrics from the catalog
  TSV and print them to stdout.

  This script is called internally by each provider's assemble_thresholds_ini.sh.
  You do not normally need to run it directly.

  Input:  common/setup/catalog/db_metrics.tsv
  Output: stdout (INI sections for metrics_and_thresholds.ini.default)

Options:
  --help, -h  Show this message

Notes:
  To rebuild the full provider INI, run from the provider directory:
    bash setup/assemble_thresholds_ini.sh
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

TSV="${COMMON_SETUP}/catalog/db_metrics.tsv"

cat <<'HDR'
# =============================================================================
# CATEGORY 0B - DB CONNECTIVITY METRICS
# Targets from connections.tsv; gated by collect_db_metrics in config.ini.
# Regenerate catalog: bash setup/assemble_thresholds_ini.sh
# =============================================================================

# =============================================================================
# DB CONNECTIVITY METRICS (auto-generated catalog)
#
# Keys:
#   enabled   = true | false   evaluate thresholds / fire alerts
#   operator  = > | >= | < | <= | == | !=
#   unit      = display unit for alert messages
#   window    = consecutive breaches before firing
#   warning / critical / info = optional severity thresholds
# Regenerate: bash setup/assemble_thresholds_ini.sh
# =============================================================================

HDR

[[ -f "$TSV" ]] || { echo "Missing $TSV" >&2; exit 1; }

while IFS=$'\t' read -r metric_key desc unit op warn crit _rest || [[ -n "${metric_key:-}" ]]; do
    [[ -z "${metric_key:-}" || "$metric_key" =~ ^# ]] && continue

    printf '[metric.db.%s]\n' "$metric_key"
    printf 'enabled     = false\n'
    printf 'description = %s\n' "$desc"
    printf 'operator    = %s\n' "$op"
    if [[ "$unit" == "-" ]]; then
        printf 'unit        = \n'
    else
        printf 'unit        = %s\n' "$unit"
    fi
    printf 'window      = 3\n'
    [[ -n "${warn:-}" && "$warn" != "-" ]] && printf 'warning     = %s\n' "$warn"
    [[ -n "${crit:-}" && "$crit" != "-" ]] && printf 'critical    = %s\n' "$crit"
    printf '\n'
done < "$TSV"
