#!/usr/bin/env bash
# setup/refresh_pi_catalog_from_aws.sh — merge PI metrics from AWS into supplement JSON
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE=""
REGION="${AWS_DEFAULT_REGION:-}"
OUT="${ROOT}/setup/catalog/pi_metrics_api_supplement.json"

usage() {
    cat <<EOF
Usage:
  bash setup/refresh_pi_catalog_from_aws.sh --instance ID [options]

Description:
  Query the AWS Performance Insights API to discover available PI metrics for a
  live RDS instance and merge any new metric definitions into the supplement
  JSON file used by the threshold generator.

  Run this when you want to capture PI metrics that are available on your
  specific instance but not yet in the bundled catalog. After running, rebuild
  the INI with:
    bash setup/assemble_thresholds_ini.sh

Arguments:
  --instance ID    RDS DB instance identifier (required)

Options:
  --region REGION  AWS region (default: AWS_DEFAULT_REGION or aws configure)
  --output FILE    Output JSON file path
                   (default: setup/catalog/pi_metrics_api_supplement.json)
  --help, -h       Show this message

Examples:
  bash setup/refresh_pi_catalog_from_aws.sh --instance prod-rds-1
  bash setup/refresh_pi_catalog_from_aws.sh --instance prod-rds-1 --region us-west-2
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance) INSTANCE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --output) OUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done
[[ -n "$INSTANCE" ]] || usage
[[ -n "$REGION" ]] || REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

RID=$(aws rds describe-db-instances --db-instance-identifier "$INSTANCE" --region "$REGION" \
    --query 'DBInstances[0].DbiResourceId' --output text 2>/dev/null) || true
[[ -n "$RID" && "$RID" != "None" ]] || { echo "No DbiResourceId for $INSTANCE" >&2; exit 1; }

API_JSON=$(mktemp)
aws pi list-available-resource-metrics --service-type RDS --identifier "$RID" \
    --metric-types os db --region "$REGION" --output json > "$API_JSON" 2>/dev/null || {
    echo "list-available-resource-metrics failed" >&2; exit 1
}

KNOWN=$(mktemp)
awk -F '\t' '{print $3}' "${ROOT}/setup/catalog/pi_metrics.tsv" | sed 's/\.avg$//' | sort -u > "$KNOWN"

EXISTING_BASES=$(mktemp)
if [[ -f "$OUT" ]]; then
    awk '/"metric_base"/{gsub(/.*"metric_base"[[:space:]]*:[[:space:]]*"/,"");gsub(/".*/,"");print}' "$OUT" | sort -u > "$EXISTING_BASES"
else
    : > "$EXISTING_BASES"
    printf '{"metrics":[]}\n' > "$OUT"
fi

ADDED=0
NEW_ENTRIES=$(mktemp)
aws --query 'Metrics[*].[Metric,Description,Unit]' --output text < "$API_JSON" 2>/dev/null | while IFS=$'\t' read -r metric desc unit; do
    [[ -z "$metric" || "$metric" == "None" ]] && continue
    base="${metric%.avg}"
    grep -Fxq "$base" "$KNOWN" && continue
    grep -Fxq "$base" "$EXISTING_BASES" && continue
    rule="${base#db.}"
    rule=$(printf '%s' "$rule" | sed 's/[^a-zA-Z0-9._-]/_/g')
    desc="${desc:-PI API supplement ${base}}"
    unit="${unit:-}"
  cat >> "$NEW_ENTRIES" <<EOF
    {
      "metric_base": "$base",
      "metric_name": "${metric}",
      "description": "$desc",
      "unit": "$unit",
      "engines": "all"
    },
EOF
    ADDED=$((ADDED + 1))
done

UPDATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Rebuild supplement JSON (append new metric objects)
{
    echo '{'
    echo "  \"updated\": \"${UPDATED}\","
    echo "  \"source_instance\": \"${INSTANCE}\","
    echo "  \"source_resource_id\": \"${RID}\","
    echo "  \"region\": \"${REGION}\","
    echo '  "metrics": ['
    if [[ -f "$OUT" ]]; then
        awk '/"metric_base"/{p=1} p{print}' "$OUT" | sed '1d;$d' | sed '/^$/d'
    fi
    if [[ -s "$NEW_ENTRIES" ]]; then
        sed '$ s/,$//' "$NEW_ENTRIES"
    fi
    echo '  ]'
    echo '}'
} > "${OUT}.new"
mv "${OUT}.new" "$OUT"
rm -f "$API_JSON" "$KNOWN" "$EXISTING_BASES" "$NEW_ENTRIES"
echo "Wrote ${OUT}"
