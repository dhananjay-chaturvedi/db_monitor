#!/usr/bin/env bash
# setup/generate_gcp_thresholds.sh — emit GCP Cloud SQL INI sections from catalog TSV
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  bash setup/generate_gcp_thresholds.sh

Description:
  Generate INI threshold sections for all GCP Cloud SQL and Query Insights
  metrics from the catalog TSV and print them to stdout.

  This script is called internally by assemble_thresholds_ini.sh.
  You do not normally need to run it directly.

  Input:  setup/catalog/cloudsql_metrics.tsv
  Output: stdout (INI sections for metrics_and_thresholds.ini.default)

Options:
  --help, -h  Show this message

Notes:
  To rebuild the full INI, run:
    bash setup/assemble_thresholds_ini.sh
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

TSV="${ROOT}/setup/catalog/cloudsql_metrics.tsv"

cat <<'HDR'
# =============================================================================
# GCP CLOUD SQL METRICS (Cloud Monitoring) — auto-generated catalog
# metric_name must be the full GCP metric type (cloudsql.googleapis.com/database/...).
#
# Keys:
#   collect     = true | false   fetch from Cloud Monitoring (default: false)
#   enabled     = true | false   evaluate thresholds / fire alerts
#   engines     = all | mysql | postgresql | sqlserver  (comma-separated)
#   metric_name = full GCP Cloud Monitoring metric type
# Regenerate: bash setup/assemble_thresholds_ini.sh
# =============================================================================

HDR

[[ -f "$TSV" ]] || { echo "Missing $TSV" >&2; exit 1; }

qi_section_written=false
while IFS=$'\t' read -r ns rule desc engines unit op warn crit mname || [[ -n "${ns:-}" ]]; do
    [[ -z "${ns:-}" || "${ns}" == \#* || -z "${rule:-}" ]] && continue
    [[ -z "${mname:-}" ]] && mname="$rule"

    if [[ "$ns" == "CloudSQL.QI" ]]; then
        if [[ "$qi_section_written" == "false" ]]; then
            printf '# =============================================================================\n'
            printf '# GCP CLOUD SQL QUERY INSIGHTS — requires Query Insights enabled on the instance\n'
            printf '# =============================================================================\n\n'
            qi_section_written=true
        fi
        # Query Insights sections use metric.gcp.qi.CloudSQL.* (separate reader in gcp.sh)
        printf '[metric.gcp.qi.CloudSQL.%s]\n' "$rule"
    else
        printf '[metric.gcp.monitoring.%s.%s]\n' "$ns" "$rule"
    fi

    printf 'collect     = false\n'
    printf 'enabled     = false\n'
    printf 'description = %s\n' "$desc"
    printf 'metric_name = %s\n' "$mname"
    [[ -n "${op:-}" ]]      && printf 'operator    = %s\n' "$op"
    [[ -n "${unit:-}" ]]    && printf 'unit        = %s\n' "$unit"
    printf 'window      = 3\n'
    [[ -n "${warn:-}" ]]    && printf 'warning     = %s\n' "$warn"
    [[ -n "${crit:-}" ]]    && printf 'critical    = %s\n' "$crit"
    [[ -n "${engines:-}" ]] && printf 'engines     = %s\n' "$engines"
    printf '\n'
done < "$TSV"
