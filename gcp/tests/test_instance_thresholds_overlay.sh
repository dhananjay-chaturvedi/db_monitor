#!/usr/bin/env bash
# tests/test_instance_thresholds_overlay.sh — per-instance threshold overlay unit tests
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/util.sh
source "${ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=lib/gcp.sh
source "${ROOT}/lib/gcp.sh"
# shellcheck source=lib/thresholds.sh
source "${ROOT}/lib/thresholds.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

GLOBAL_INI="${TMP}/metrics_and_thresholds.ini"
INST_DIR="${TMP}/instances"
mkdir -p "$INST_DIR"
export METRICS_AND_THRESHOLDS_INI="$GLOBAL_INI"
export CONFIGS_DIR="$TMP"

cat > "$GLOBAL_INI" <<'EOF'
[metric.gcp.monitoring.CloudSQL.cpu_utilization]
collect     = true
enabled     = true
description = Cloud SQL CPU utilisation
engines     = all
metric_name = cloudsql.googleapis.com/database/cpu/utilization
operator    = >
unit        = %
window      = 1
warning     = 75
critical    = 90

[metric.gcp.monitoring.CloudSQL.memory_utilization]
collect     = true
enabled     = true
description = Cloud SQL memory utilisation
engines     = all
metric_name = cloudsql.googleapis.com/database/memory/utilization
operator    = >
unit        = %
window      = 1
critical    = 95

[metric.gcp.qi.CloudSQL.execution_count]
collect     = true
enabled     = true
description = Query Insights execution count
engines     = all
metric_name = cloudsql.googleapis.com/database/query_insights/total_queries
unit        = qps
operator    = >
window      = 1
critical    = 5000
EOF

INSTANCE="test-cloudsql-instance"
INST_INI="${INST_DIR}/test-cloudsql-instance.ini"
cat > "$INST_INI" <<'EOF'
[metric.gcp.monitoring.CloudSQL.cpu_utilization]
critical = 50
warning  = 40
EOF

pass=0
fail=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $label"
        pass=$(( pass + 1 ))
    else
        echo "FAIL: $label (expected '$expected', got '$actual')" >&2
        fail=$(( fail + 1 ))
    fi
}

# instance_thresholds_ini must resolve to our temp instance file
assert_eq "instance_thresholds_ini path" "$INST_INI" "$(instance_thresholds_ini "$INSTANCE")"

# Overlay: critical overridden, operator falls back to global
assert_eq "thresh_ini_get critical override" "50" \
    "$(thresh_ini_get "$INSTANCE" "metric.gcp.monitoring.CloudSQL.cpu_utilization" "critical" "")"
assert_eq "thresh_ini_get operator fallback" ">" \
    "$(thresh_ini_get "$INSTANCE" "metric.gcp.monitoring.CloudSQL.cpu_utilization" "operator" ">")"
assert_eq "thresh_ini_key_present on override" "0" \
    "$(thresh_ini_key_present "$INSTANCE" "metric.gcp.monitoring.CloudSQL.cpu_utilization" "critical"; echo $?)"
assert_eq "thresh_ini_key_present on fallback" "1" \
    "$(thresh_ini_key_present "$INSTANCE" "metric.gcp.monitoring.CloudSQL.cpu_utilization" "operator"; echo $?)"

# collect=false in instance overlay skips metric even when global collect=true
cat >> "$INST_INI" <<'EOF'

[metric.gcp.monitoring.CloudSQL.memory_utilization]
collect = false
EOF

query_file=$(mktemp)
_gcp_build_metric_query_file "$INSTANCE" "" "mysql" "$query_file"
if grep -q 'memory_utilization' "$query_file" 2>/dev/null; then
    echo "FAIL: collect=false overlay should skip memory_utilization" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: collect=false overlay skips memory_utilization"
    pass=$(( pass + 1 ))
fi
if ! grep -q 'cpu_utilization' "$query_file" 2>/dev/null; then
    echo "FAIL: cpu_utilization should still be collected" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: cpu_utilization still collected"
    pass=$(( pass + 1 ))
fi
rm -f "$query_file"

# evaluate_metric uses instance-specific critical threshold (50), not global (90)
export DBMONITOR_RUNTIME="${TMP}/runtime"
mkdir -p "$DBMONITOR_RUNTIME"
result=$(evaluate_metric "gcp" "$INSTANCE" "cpu_utilization" "55" || true)
if [[ "$result" == CRITICAL* ]]; then
    echo "PASS: evaluate_metric fires at instance critical=50"
    pass=$(( pass + 1 ))
else
    echo "FAIL: evaluate_metric should fire CRITICAL at value 55 (got: ${result:-empty})" >&2
    fail=$(( fail + 1 ))
fi

# Per-instance QI gate respects overlay collect=false
cat > "$INST_INI" <<'EOF'
[metric.gcp.qi.CloudSQL.execution_count]
collect = false
EOF
if gcp_collect_query_insights_enabled_for_instance "$INSTANCE"; then
    echo "FAIL: QI collect should be disabled via instance overlay" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: QI collect disabled via instance overlay"
    pass=$(( pass + 1 ))
fi

echo
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
