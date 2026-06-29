#!/usr/bin/env bash
# setup/generate_cloudwatch_thresholds.sh — emit CloudWatch INI sections from catalog TSV
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  bash setup/generate_cloudwatch_thresholds.sh

Description:
  Generate INI threshold sections for all AWS CloudWatch (RDS and Aurora)
  metrics from the catalog TSV and print them to stdout.

  This script is called internally by assemble_thresholds_ini.sh.
  You do not normally need to run it directly.

  Input:  setup/catalog/cloudwatch_metrics.tsv
  Output: stdout (INI sections for metrics_and_thresholds.ini.default)

Options:
  --help, -h  Show this message

Notes:
  To regenerate the catalog TSV from the current .ini.default, run:
    bash setup/export_catalog_tsv.sh
  To rebuild the full INI, run:
    bash setup/assemble_thresholds_ini.sh
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

TSV="${ROOT}/setup/catalog/cloudwatch_metrics.tsv"

cat <<'HDR'
# =============================================================================
# AWS RDS / AURORA - CLOUDWATCH METRICS (auto-generated catalog)
# MetricName must match CloudWatch exactly (case-sensitive).
#
# Keys:
#   collect   = true | false   fetch from CloudWatch (default: false)
#   enabled   = true | false   evaluate thresholds / fire alerts
#   engines   = comma-separated instance types this rule applies to
#   dimension = instance | cluster
#   metric_name = override when section name differs from CloudWatch name
# Regenerate: bash setup/assemble_thresholds_ini.sh
# =============================================================================

HDR

[[ -f "$TSV" ]] || { echo "Missing $TSV — run bash setup/export_catalog_tsv.sh" >&2; exit 1; }

while IFS=$'\t' read -r ns rule desc engines dim unit op warn crit mname || [[ -n "${ns:-}" ]]; do
    [[ -z "${ns:-}" || -z "${rule:-}" ]] && continue
    [[ -z "${mname:-}" ]] && mname="$rule"
    printf '[metric.aws.cloudwatch.%s.%s]\n' "$ns" "$rule"
    printf 'collect     = false\n'
    printf 'enabled     = false\n'
    printf 'description = %s\n' "$desc"
    printf 'engines     = %s\n' "$engines"
    printf 'dimension   = %s\n' "$dim"
    printf 'operator    = %s\n' "$op"
    printf 'unit        = %s\n' "$unit"
    printf 'window      = 3\n'
    [[ "$mname" != "$rule" ]] && printf 'metric_name = %s\n' "$mname"
    [[ -n "${warn:-}" ]] && printf 'warning     = %s\n' "$warn"
    [[ -n "${crit:-}" ]] && printf 'critical    = %s\n' "$crit"
    printf '\n'
done < "$TSV"
