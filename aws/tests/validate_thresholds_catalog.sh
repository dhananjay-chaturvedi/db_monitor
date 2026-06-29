#!/usr/bin/env bash
# tests/validate_thresholds_catalog.sh - sanity-check metrics_and_thresholds.ini structure
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INI="${1:-${ROOT}/configs/metrics_and_thresholds.ini}"

if [[ ! -f "$INI" ]]; then
    echo "FAIL: missing $INI" >&2
    exit 1
fi

awk -v ini="$INI" '
BEGIN {
    errors = 0; warnings = 0; cw = 0; pi = 0; dbi = 0; os = 0; db = 0; total = 0
}
/^\[(metric\.[^]]+)\][[:space:]]*$/ {
    if (current != "") validate_section()
    current = substr($0, 2, length($0) - 2)
    delete keys
    next
}
current != "" && /=/ && $0 !~ /^[[:space:]]*#/ {
    split($0, kv, "=")
    key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    val = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    keys[key] = val
    next
}
function validate_section(    req, k, mn) {
    total++
    if (current ~ /^metric\.aws\.cloudwatch\./) {
        cw++
        req = "collect enabled description engines dimension operator unit window"
    } else if (current ~ /^metric\.aws\.(pi|dbinsights)\./) {
        if (current ~ /^metric\.aws\.pi\./) pi++
        else dbi++
        req = "collect enabled description metric_name engines operator unit window"
        mn = keys["metric_name"]
        if (mn != "" && mn !~ /\.avg$/) {
            printf "WARN: %s metric_name should end with .avg: %s\n", current, mn > "/dev/stderr"
            warnings++
        }
    } else if (current ~ /^metric\.os\./) {
        os++
        req = "enabled description operator unit window"
    } else if (current ~ /^metric\.db\./) {
        db++
        req = "enabled description operator unit window"
    } else return
    split(req, rk, " ")
    for (i = 1; i <= length(rk); i++) {
        k = rk[i]
        if (!(k in keys)) {
            printf "FAIL: %s missing keys: %s\n", current, k
            errors++
        }
    }
}
END {
    if (current != "") validate_section()
    printf "Catalog: CloudWatch=%d PI=%d DBInsights=%d OS=%d DB=%d total_sections=%d\n", cw, pi, dbi, os, db, total
    if (cw < 160) { printf "FAIL: CloudWatch section count low: %d\n", cw; errors++ }
    if (pi < 200) { printf "FAIL: PI section count low: %d\n", pi; errors++ }
    if (dbi < 200) { printf "FAIL: DB Insights section count low: %d\n", dbi; errors++ }
    if (dbi != pi) { printf "FAIL: DB Insights count (%d) != PI count (%d)\n", dbi, pi; errors++ }
    if (os < 12) { printf "FAIL: OS section count low: %d (expected >= 12)\n", os; errors++ }
    if (db < 1) { printf "FAIL: DB section count low: %d (expected >= 1)\n", db; errors++ }
    if (errors == 0) print "PASS: thresholds catalog structure OK"
    exit (errors > 0 ? 1 : 0)
}
' "$INI"

# duplicate PI/DBI section detection
dupes=$(grep -E '^\[metric\.aws\.(pi|dbinsights)\.' "$INI" | sort | uniq -d | head -5)
if [[ -n "$dupes" ]]; then
    echo "FAIL: duplicate sections: $dupes" >&2
    exit 1
fi
