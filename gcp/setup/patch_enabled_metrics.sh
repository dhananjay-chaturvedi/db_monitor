#!/usr/bin/env bash
# setup/patch_enabled_metrics.sh — set collect/enabled flags in metrics_and_thresholds.ini
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  bash setup/patch_enabled_metrics.sh [options]

Description:
  Set the collect= and enabled= flags in metrics_and_thresholds.ini files.

  By default, ALL metrics are disabled in metrics_and_thresholds.ini.default.
  With --live-only, a curated default set of key metrics is also enabled in
  the live metrics_and_thresholds.ini.

  This script is called automatically by assemble_thresholds_ini.sh.
  You do not normally need to run it directly.

Options:
  --live-only   Also sync .default to the live ini and enable the default
                metric set (CPU, memory, connections, latency, storage)
  --help, -h    Show this message

Examples:
  bash setup/patch_enabled_metrics.sh             # disable all in .default only
  bash setup/patch_enabled_metrics.sh --live-only # sync + enable defaults in live ini
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

LIVE_ONLY=0
[[ "${1:-}" == "--live-only" ]] && LIVE_ONLY=1

ENABLED_LIVE=(
    metric.os.cpu_utilization
    metric.os.free_memory_mb
    metric.db.connection
    metric.gcp.monitoring.CloudSQL.cpu_utilization
    metric.gcp.monitoring.CloudSQL.network_connections
    metric.gcp.monitoring.CloudSQL.replication_replica_lag
    metric.gcp.monitoring.CloudSQL.postgresql_num_backends
    metric.gcp.monitoring.CloudSQL.sqlserver_connections_total
)

_is_enabled_live() {
    local sec="$1" e
    for e in "${ENABLED_LIVE[@]}"; do
        [[ "$e" == "$sec" ]] && return 0
    done
    return 1
}

_patch_file() {
    local path="$1" live_subset="$2"
    local current="" on val tmp
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[(metric\.[^]]+)\][[:space:]]*$ ]]; then
            current="${BASH_REMATCH[1]}"
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        if [[ -n "$current" && "$current" == metric.* ]]; then
            if [[ "$line" =~ ^([[:space:]]*collect[[:space:]]*=[[:space:]]*)(true|false)([[:space:]]*)$ ]]; then
                if [[ "$live_subset" == "1" ]] && _is_enabled_live "$current"; then on=true; else on=false; fi
                val=$([[ "$on" == true ]] && echo true || echo false)
                printf '%s%s%s\n' "${BASH_REMATCH[1]}" "$val" "${BASH_REMATCH[3]}" >> "$tmp"
                continue
            fi
            if [[ "$line" =~ ^([[:space:]]*enabled[[:space:]]*=[[:space:]]*)(true|false)([[:space:]]*)$ ]]; then
                if [[ "$live_subset" == "1" ]] && _is_enabled_live "$current"; then on=true; else on=false; fi
                val=$([[ "$on" == true ]] && echo true || echo false)
                printf '%s%s%s\n' "${BASH_REMATCH[1]}" "$val" "${BASH_REMATCH[3]}" >> "$tmp"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$path"
    mv "$tmp" "$path"
}

_patch_file "${ROOT}/configs/metrics_and_thresholds.ini.default" 0
echo "Patched metrics_and_thresholds.ini.default (all metrics disabled)"

if [[ "$LIVE_ONLY" -eq 1 ]]; then
    cp "${ROOT}/configs/metrics_and_thresholds.ini.default" "${ROOT}/configs/metrics_and_thresholds.ini"
    _patch_file "${ROOT}/configs/metrics_and_thresholds.ini" 1
    echo "Synced + patched metrics_and_thresholds.ini (${#ENABLED_LIVE[@]} metrics enabled)"
else
    _patch_file "${ROOT}/configs/metrics_and_thresholds.ini" 1
    echo "Patched metrics_and_thresholds.ini (${#ENABLED_LIVE[@]} metrics enabled)"
fi
