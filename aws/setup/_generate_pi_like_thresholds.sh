#!/usr/bin/env bash
# setup/_generate_pi_like_thresholds.sh PREFIX HEADER — shared PI / DB Insights generator
set -euo pipefail
PREFIX="${1:?prefix e.g. metric.aws.pi.RDS.}"
HEADER="${2:?header text file or - for stdin}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="${ROOT}/setup/catalog/pi_metrics.tsv"
SUPP="${3:-${ROOT}/setup/catalog/pi_metrics_api_supplement.json}"

if [[ "$HEADER" == "-" ]]; then
    cat
else
    cat "$HEADER"
fi

[[ -f "$TSV" ]] || { echo "Missing $TSV" >&2; exit 1; }

_emit_pi_rule() {
    local rule="$1" desc="$2" mname="$3" engines="$4" op="$5" unit="$6" warn="$7" crit="$8"
    printf '[%s%s]\n' "$PREFIX" "$rule"
    printf 'collect     = false\n'
    printf 'enabled     = false\n'
    printf 'description = %s\n' "$desc"
    printf 'metric_name = %s\n' "$mname"
    printf 'engines     = %s\n' "$engines"
    printf 'operator    = %s\n' "$op"
    printf 'unit        = %s\n' "$unit"
    printf 'window      = 3\n'
    [[ -n "${warn:-}" ]] && printf 'warning     = %s\n' "$warn"
    [[ -n "${crit:-}" ]] && printf 'critical    = %s\n' "$crit"
    printf '\n'
}

while IFS=$'\t' read -r rule desc mname engines op unit warn crit || [[ -n "${rule:-}" ]]; do
    [[ -z "${rule:-}" ]] && continue
    _emit_pi_rule "$rule" "$desc" "$mname" "$engines" "$op" "$unit" "$warn" "$crit"
done < "$TSV"

# Append supplement JSON entries (minimal parser — no jq)
if [[ -f "$SUPP" && -s "$SUPP" ]]; then
    awk -v pfx="$PREFIX" '
BEGIN { inm=0; rule=desc=mname=engines=unit="" ; op=">" }
/"metric_base"/ { gsub(/.*"metric_base"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); rule=$0; next }
/"metric_name"/ { gsub(/.*"metric_name"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); mname=$0; next }
/"description"/ { gsub(/.*"description"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); desc=$0; next }
/"engines"/ { gsub(/.*"engines"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); engines=$0; next }
/"unit"/ { gsub(/.*"unit"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); unit=$0; next }
/\}/ {
    if (rule != "") {
        if (mname == "") mname = rule;
        if (engines == "") engines = "all";
        gsub(/\t/, " ", desc);
        sub(/^db\./, "", rule);
        gsub(/[^a-zA-Z0-9._-]/, "_", rule);
        printf "[%s%s]\n", pfx, rule;
        print "collect     = false";
        print "enabled     = false";
        printf "description = %s\n", desc;
        printf "metric_name = %s\n", mname;
        printf "engines     = %s\n", engines;
        print "operator    = >";
        printf "unit        = %s\n", unit;
        print "window      = 3";
        print "";
        rule=desc=mname=engines=unit="";
        op=">";
    }
}
' "$SUPP"
fi
