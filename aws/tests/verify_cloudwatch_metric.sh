#!/usr/bin/env bash
# Double-check one CloudWatch metric: monitor collector vs aws CLI
# Usage: bash tests/verify_cloudwatch_metric.sh INSTANCE METRIC [REGION]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="${1:?instance id}"
METRIC="${2:?metric name}"
REGION="${3:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"

mon=$(cd "$ROOT" && bash monitor.sh cloud --instance "$INST" 2>/dev/null | awk -v k="$METRIC" '$1==k{print $2; exit}')
aws_v=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS --metric-name "$METRIC" \
    --dimensions Name=DBInstanceIdentifier,Value="$INST" \
    --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period 60 --statistics Average \
    --region "$REGION" \
    --query 'Datapoints | sort_by(@, &Timestamp) | [-1].Average' --output text 2>/dev/null || echo "N/A")

printf 'instance\t%s\nmetric\t%s\nmonitor\t%s\naws_cli\t%s\nregion\t%s\n' "$INST" "$METRIC" "${mon:-N/A}" "$aws_v" "$REGION"
