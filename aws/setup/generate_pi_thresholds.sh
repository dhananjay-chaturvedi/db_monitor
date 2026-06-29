#!/usr/bin/env bash
# setup/generate_pi_thresholds.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDR="${DIR}/catalog/pi_header.txt"
cat > "$HDR" <<'EOF'
# =============================================================================
# CATEGORY 2 - PERFORMANCE INSIGHTS (aws pi get-resource-metrics)
# Requires Performance Insights enabled on the RDS instance.
# Regenerate: bash setup/assemble_thresholds_ini.sh
# =============================================================================

EOF
bash "${DIR}/_generate_pi_like_thresholds.sh" "metric.aws.pi.RDS." "$HDR" "${1:-}"
