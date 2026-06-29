#!/usr/bin/env bash
# setup/export_catalog_tsv.sh — one-time export of catalog TSV from metrics_and_thresholds.ini.default
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  bash setup/export_catalog_tsv.sh [INI_FILE]

Description:
  Export the metric catalog from metrics_and_thresholds.ini.default into
  tab-separated TSV files used by the threshold generator scripts.

  Output files written to setup/catalog/:
    cloudwatch_rds_metrics.tsv    RDS CloudWatch metric definitions
    cloudwatch_aurora_metrics.tsv Aurora CloudWatch metric definitions
    cloudwatch_metrics.tsv        Combined RDS + Aurora (alias)
    pi_metrics.tsv                Performance Insights metric definitions

  Run this whenever the .ini.default file has been hand-edited to add or
  remove metric sections. Afterwards, regenerate the INI with:
    bash setup/assemble_thresholds_ini.sh

Arguments:
  INI_FILE    Path to source INI file
              (default: configs/metrics_and_thresholds.ini.default)

Options:
  --help, -h  Show this message

Examples:
  bash setup/export_catalog_tsv.sh
  bash setup/export_catalog_tsv.sh /path/to/custom.ini.default
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

INI="${1:-${ROOT}/configs/metrics_and_thresholds.ini.default}"
OUT="${ROOT}/setup/catalog"
mkdir -p "$OUT"

_export_sections() {
    local prefix="$1" outfile="$2"
    awk -v pfx="$prefix" '
BEGIN { sec=""; insec=0 }
/^\[/ {
    if (sec != "" && insec) {
        if (mname == "") mname = rule;
        gsub(/\t/, " ", desc);
        print ns "\t" rule "\t" desc "\t" engines "\t" dim "\t" unit "\t" op "\t" warn "\t" crit "\t" mname;
    }
    sec = $0;
    gsub(/^\[|\]$/, "", sec);
    if (index(sec, pfx) == 1) {
        ns = pfx; sub(/\.$/, "", ns);
        sub(/^metric\.aws\.cloudwatch\./, "", ns);
        rule = sec; sub(/^metric\.aws\.cloudwatch\.[^.]+\./, "", rule);
        desc = engines = dim = unit = op = warn = crit = mname = "";
        insec = 1;
    } else {
        insec = 0;
        sec = "";
    }
    next;
}
insec && /^[[:space:]]*[a-zA-Z_]/ {
    line = $0;
    split(line, kv, "=");
    key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
    val = substr(line, index(line, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
    if (key == "description") desc = val;
    else if (key == "engines") engines = val;
    else if (key == "dimension") dim = val;
    else if (key == "unit") unit = val;
    else if (key == "operator") op = val;
    else if (key == "warning") warn = val;
    else if (key == "critical") crit = val;
    else if (key == "metric_name") mname = val;
    next;
}
END {
    if (sec != "" && insec) {
        if (mname == "") mname = rule;
        gsub(/\t/, " ", desc);
        print ns "\t" rule "\t" desc "\t" engines "\t" dim "\t" unit "\t" op "\t" warn "\t" crit "\t" mname;
    }
}
' "$INI" > "$outfile"
}

_export_pi_sections() {
    local prefix="$1" outfile="$2"
    awk -v pfx="$prefix" '
BEGIN { sec=""; insec=0 }
/^\[/ {
    if (sec != "" && insec) {
        gsub(/\t/, " ", desc);
        print rule "\t" desc "\t" mname "\t" engines "\t" op "\t" unit "\t" warn "\t" crit;
    }
    sec = $0; gsub(/^\[|\]$/, "", sec);
    if (index(sec, pfx) == 1) {
        rule = sec; sub(/^[^.]+\.[^.]+\.[^.]+\.[^.]+\./, "", rule);
        desc = mname = engines = op = unit = warn = crit = "";
        insec = 1;
    } else { insec = 0; sec = ""; }
    next;
}
insec && /^[[:space:]]*[a-zA-Z_]/ {
    line = $0;
    split(line, kv, "=");
    key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
    val = substr(line, index(line, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
    if (key == "description") desc = val;
    else if (key == "metric_name") mname = val;
    else if (key == "engines") engines = val;
    else if (key == "operator") op = val;
    else if (key == "unit") unit = val;
    else if (key == "warning") warn = val;
    else if (key == "critical") crit = val;
    next;
}
END {
    if (sec != "" && insec) {
        gsub(/\t/, " ", desc);
        print rule "\t" desc "\t" mname "\t" engines "\t" op "\t" unit "\t" warn "\t" crit;
    }
}
' "$INI" > "$outfile"
}

_export_sections "metric.aws.cloudwatch.RDS." "${OUT}/cloudwatch_rds_metrics.tsv"
_export_sections "metric.aws.cloudwatch.Aurora." "${OUT}/cloudwatch_aurora_metrics.tsv"
_export_pi_sections "metric.aws.pi.RDS." "${OUT}/pi_metrics.tsv"
cat "${OUT}/cloudwatch_rds_metrics.tsv" "${OUT}/cloudwatch_aurora_metrics.tsv" > "${OUT}/cloudwatch_metrics.tsv"
echo "Exported:"
wc -l "${OUT}/cloudwatch_metrics.tsv" "${OUT}/pi_metrics.tsv"
