#!/usr/bin/env bash
# tests/verify_cloudwatch_metrics.sh — cross-check enabled CloudWatch metrics vs AWS CLI
# Uses collect_rds_cloudwatch_metrics directly (no PI/DBI — those are slow from some hosts).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="${1:?instance id}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
CLUSTER="${2:-}"

source "${ROOT}/lib/util.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/instances.sh"
source "${ROOT}/lib/aws.sh"

lookback=$(mcfgi cloud lookback_minutes 10)
cluster_lookback=$(mcfgi cloud cluster_lookback_minutes 180)
period=$(mcfgi cloud metric_period_seconds 60)
cluster_period=$(mcfgi cloud cluster_metric_period_seconds 3600)

start_inst=$(date -u -d "${lookback} minutes ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-"${lookback}"M +%Y-%m-%dT%H:%M:%S)
start_cluster=$(date -u -d "${cluster_lookback} minutes ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-"${cluster_lookback}"M +%Y-%m-%dT%H:%M:%S)
end=$(date -u +%Y-%m-%dT%H:%M:%S)

inst_type=""
instances_resolve_metadata "$INST" 2>/dev/null || inst_type="aurora-mysql"
[[ -z "$inst_type" || "$inst_type" == "-" ]] && inst_type="aurora-mysql"
[[ -z "$CLUSTER" ]] && CLUSTER=$(rds_cluster_identifier "$INST" 2>/dev/null || true)

mon_out=""
mon_out=$(bash -c "source '${ROOT}/lib/util.sh' && source '${ROOT}/lib/config.sh' && source '${ROOT}/lib/aws.sh' && collect_rds_cloudwatch_metrics '$INST' '$inst_type'" 2>/dev/null || true)
if [[ "$inst_type" == aurora-* && -n "$CLUSTER" && "$CLUSTER" != "None" ]]; then
    mon_out+=$'\n'"$(bash -c "source '${ROOT}/lib/util.sh' && source '${ROOT}/lib/config.sh' && source '${ROOT}/lib/aws.sh' && collect_aurora_cluster_cloudwatch_metrics '$CLUSTER' '$inst_type'" 2>/dev/null || true)"
fi

aws_inst_metric() {
    local metric="$1"
    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS --metric-name "$metric" \
        --dimensions Name=DBInstanceIdentifier,Value="$INST" \
        --start-time "$start_inst" --end-time "$end" \
        --period "$period" --statistics Average \
        --region "$REGION" \
        --query 'Datapoints | sort_by(@, &Timestamp) | [-1].Average' \
        --output text 2>/dev/null || echo "N/A"
}

aws_cluster_metric() {
    local metric="$1" cid="$2"
    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS --metric-name "$metric" \
        --dimensions Name=DBClusterIdentifier,Value="$cid" \
        --start-time "$start_cluster" --end-time "$end" \
        --period "$cluster_period" --statistics Average \
        --region "$REGION" \
        --query 'Datapoints | sort_by(@, &Timestamp) | [-1].Average' \
        --output text 2>/dev/null || echo "N/A"
}

compare() {
    local key="$1" aws_val="$2"
    local mon_val
    mon_val=$(printf '%s\n' "$mon_out" | awk -v k="$key" '$1==k{print $2; exit}')
    local status="OK"
    if [[ -z "$mon_val" ]]; then
        status="MISSING"
    elif [[ "$aws_val" == "N/A" || -z "$aws_val" ]]; then
        status="NO_AWS_DATA"
    else
        awk -v m="$mon_val" -v a="$aws_val" 'BEGIN {
            if (m == "" || a == "" || a == "N/A") exit 1
            mf = m + 0; af = a + 0
            if (mf != mf || af != af) exit (m == a ? 0 : 1)
            if (af == 0) exit (mf < 0.01 && mf > -0.01 ? 0 : 1)
            diff = (mf - af) / (af < 0 ? -af : af)
            if (diff < 0) diff = -diff
            exit (diff < 0.05 ? 0 : 1)
        }' || status="MISMATCH"
    fi
    printf '%s\t%s\t%s\t%s\n' "$key" "${mon_val:-}" "$aws_val" "$status"
}

printf 'metric\tmonitor\taws\tstatus\n'
for m in CPUUtilization FreeableMemory DatabaseConnections ConnectionAttempts ReadLatency WriteLatency; do
    compare "$m" "$(aws_inst_metric "$m")"
done
for m in Queries SelectLatency DMLLatency; do
    compare "$m" "$(aws_inst_metric "$m")"
done
if [[ -n "$CLUSTER" && "$CLUSTER" != "None" ]]; then
    compare "VolumeBytesUsed" "$(aws_cluster_metric VolumeBytesUsed "$CLUSTER")"
fi
