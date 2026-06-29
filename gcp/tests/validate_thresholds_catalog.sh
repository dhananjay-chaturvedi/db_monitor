#!/usr/bin/env bash
# tests/validate_thresholds_catalog.sh - sanity-check metrics_and_thresholds.ini structure (GCP variant)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INI="${1:-${ROOT}/configs/metrics_and_thresholds.ini}"

if [[ ! -f "$INI" ]]; then
    echo "FAIL: missing $INI" >&2
    exit 1
fi

awk -v ini="$INI" '
BEGIN {
    errors = 0; gcp = 0; qi = 0; os = 0; db = 0; total = 0
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
function validate_section(    req, k) {
    total++
    if (current ~ /^metric\.gcp\.monitoring\./) {
        gcp++
        req = "collect enabled description engines metric_name operator unit window"
    } else if (current ~ /^metric\.gcp\.qi\./) {
        qi++
        req = "collect enabled description engines metric_name operator unit window"
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
            printf "FAIL: %s missing key: %s\n", current, k
            errors++
        }
    }
}
END {
    if (current != "") validate_section()
    printf "Catalog: GCP_monitoring=%d GCP_QI=%d OS=%d DB=%d total_sections=%d\n", gcp, qi, os, db, total
    if (gcp < 13) { printf "FAIL: GCP monitoring section count low: %d (expected >= 13)\n", gcp; errors++ }
    if (os < 12) { printf "FAIL: OS section count low: %d (expected >= 12)\n", os; errors++ }
    if (db < 1) { printf "FAIL: DB section count low: %d (expected >= 1)\n", db; errors++ }
    if (errors == 0) print "PASS: thresholds catalog structure OK"
    exit (errors > 0 ? 1 : 0)
}
' "$INI"

# duplicate GCP section detection
dupes=$(grep -E '^\[metric\.gcp\.' "$INI" | sort | uniq -d | head -5)
if [[ -n "$dupes" ]]; then
    echo "FAIL: duplicate sections: $dupes" >&2
    exit 1
fi
