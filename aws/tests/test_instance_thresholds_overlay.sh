#!/usr/bin/env bash
# tests/test_instance_thresholds_overlay.sh — per-instance threshold overlay unit tests
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/util.sh
source "${ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=lib/aws.sh
source "${ROOT}/lib/aws.sh"
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
[metric.aws.cloudwatch.RDS.CPUUtilization]
collect     = true
enabled     = true
description = RDS CPU utilisation
engines     = all
dimension   = instance
operator    = >
unit        = %
window      = 1
warning     = 75
critical    = 90

[metric.aws.cloudwatch.RDS.SwapUsage]
collect     = true
enabled     = true
description = RDS swap usage
engines     = all
dimension   = instance
operator    = >
unit        = bytes
window      = 1
critical    = 536870912

[metric.aws.pi.RDS.db.load.avg]
collect     = true
enabled     = true
metric_name = db.load.avg
unit        = AAS
operator    = >
window      = 1
critical    = 10
EOF

INSTANCE="test-rds-instance"
INST_INI="${INST_DIR}/test-rds-instance.ini"
cat > "$INST_INI" <<'EOF'
[metric.aws.cloudwatch.RDS.CPUUtilization]
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
    "$(thresh_ini_get "$INSTANCE" "metric.aws.cloudwatch.RDS.CPUUtilization" "critical" "")"
assert_eq "thresh_ini_get operator fallback" ">" \
    "$(thresh_ini_get "$INSTANCE" "metric.aws.cloudwatch.RDS.CPUUtilization" "operator" ">")"
assert_eq "thresh_ini_key_present on override" "0" \
    "$(thresh_ini_key_present "$INSTANCE" "metric.aws.cloudwatch.RDS.CPUUtilization" "critical"; echo $?)"
assert_eq "thresh_ini_key_present on fallback" "1" \
    "$(thresh_ini_key_present "$INSTANCE" "metric.aws.cloudwatch.RDS.CPUUtilization" "operator"; echo $?)"

# collect=false in instance overlay skips metric even when global collect=true
cat >> "$INST_INI" <<'EOF'

[metric.aws.cloudwatch.RDS.SwapUsage]
collect = false
EOF

query_file=$(mktemp)
_cw_build_metric_query_file "$INSTANCE" "mysql" "instance" "" "$query_file"
if grep -q '^SwapUsage' "$query_file" 2>/dev/null; then
    echo "FAIL: collect=false overlay should skip SwapUsage" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: collect=false overlay skips SwapUsage"
    pass=$(( pass + 1 ))
fi
if ! grep -q '^CPUUtilization' "$query_file" 2>/dev/null; then
    echo "FAIL: CPUUtilization should still be collected" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: CPUUtilization still collected"
    pass=$(( pass + 1 ))
fi
rm -f "$query_file"

# evaluate_metric uses instance-specific critical threshold (50), not global (90)
export DBMONITOR_RUNTIME="${TMP}/runtime"
mkdir -p "$DBMONITOR_RUNTIME"
result=$(evaluate_metric "aws" "$INSTANCE" "CPUUtilization" "55" || true)
if [[ "$result" == CRITICAL* ]]; then
    echo "PASS: evaluate_metric fires at instance critical=50"
    pass=$(( pass + 1 ))
else
    echo "FAIL: evaluate_metric should fire CRITICAL at value 55 (got: ${result:-empty})" >&2
    fail=$(( fail + 1 ))
fi

# Per-instance PI gate respects overlay collect=false for all PI metrics
cat > "$INST_INI" <<'EOF'
[metric.aws.pi.RDS.db.load.avg]
collect = false
EOF
if aws_collect_pi_enabled_for_instance "$INSTANCE"; then
    echo "FAIL: PI collect should be disabled via instance overlay" >&2
    fail=$(( fail + 1 ))
else
    echo "PASS: PI collect disabled via instance overlay"
    pass=$(( pass + 1 ))
fi

echo
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
