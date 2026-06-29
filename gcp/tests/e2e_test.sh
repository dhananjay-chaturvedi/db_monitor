#!/usr/bin/env bash
# tests/e2e_test.sh — E2E validation against real saved Cloud SQL targets
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Use project .dbmonitor/ (ignore any runtime override)
unset DBMONITOR_RUNTIME DBMONITOR_HOME DBMONITOR_SECRETS 2>/dev/null || true

SAVED_INST="${SAVED_INST:-}"
DB_NAME="${DB_NAME:-}"
GCP_PROJECT="${GCP_PROJECT:-}"

THR="${ROOT}/configs/metrics_and_thresholds.ini"
THR_BAK="${ROOT}/configs/metrics_and_thresholds.ini.e2e.bak"
CFG="${ROOT}/configs/config.ini"
CFG_BAK="${ROOT}/configs/config.ini.e2e.bak"
THR_PATCH="${ROOT}/tests/e2e_threshold_patch.ini"
REPORT="${ROOT}/tests/e2e_report_$(date -u +%Y%m%dT%H%M%SZ).txt"

SKIP_RESTORE=false
PASS=0
FAIL=0
SKIP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-restore) SKIP_RESTORE=true; shift ;;
        --instance)     SAVED_INST="$2"; shift 2 ;;
        --project)      GCP_PROJECT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SAVED_INST" ]]; then
    echo "Usage: bash tests/e2e_test.sh --instance CLOUD_SQL_INSTANCE_ID [--project GCP_PROJECT]" >&2
    exit 1
fi

[[ -n "$GCP_PROJECT" ]] && export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

run_case() {
    local id="$1" title="$2" expect="$3"; shift 3
    log ""
    log "=== ${id}: ${title} ==="
    log "EXPECT: ${expect}"
    log "CMD: $*"
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    log "EXIT: ${rc}"
    log "OUTPUT (first 50 lines):"
    printf '%s\n' "$out" | head -50 | tee -a "$REPORT"
    if [[ $rc -eq 0 ]]; then
        PASS=$(( PASS + 1 ))
        log "RESULT: PASS"
    else
        FAIL=$(( FAIL + 1 ))
        log "RESULT: FAIL"
    fi
}

run_case_expect_fail() {
    local id="$1" title="$2"; shift 2
    log ""
    log "=== ${id}: ${title} (expect non-zero) ==="
    log "CMD: $*"
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        PASS=$(( PASS + 1 ))
        log "RESULT: PASS (failed as expected, exit=${rc})"
    else
        FAIL=$(( FAIL + 1 ))
        log "RESULT: FAIL (should have failed)"
    fi
}

apply_threshold_patch() {
    cp -a "$THR" "$THR_BAK"
    awk -v patch="$THR_PATCH" '
BEGIN {
    while ((getline line < patch) > 0) {
        if (line ~ /^\[[^]]+\]/) {
            sec = line; gsub(/^\[|\]$/, "", sec)
            continue
        }
        if (sec != "" && index(line, "=") > 0 && line !~ /^[[:space:]]*#/) {
            split(line, kv, "=")
            key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            val = substr(line, index(line, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            overrides[sec SUBSEP key] = val
        }
    }
    close(patch)
}
/^\[/ {
    cur = $0; gsub(/^\[|\]$/, "", cur)
    print $0
    next
}
{
    if (cur != "" && index($0, "=") > 0) {
        split($0, kv, "=")
        key = kv[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        ik = cur SUBSEP key
        if (ik in overrides) {
            print key " = " overrides[ik]
            next
        }
    }
    print $0
}
' "$THR" > "${THR}.tmp" && mv "${THR}.tmp" "$THR"
    log "Applied threshold patch from tests/e2e_threshold_patch.ini"
}

restore_thresholds() {
    if [[ -f "$THR_BAK" ]]; then
        mv -f "$THR_BAK" "$THR"
        log "Restored metrics_and_thresholds.ini from backup"
    fi
    if [[ -f "$CFG_BAK" ]]; then
        mv -f "$CFG_BAK" "$CFG"
        log "Restored config.ini from backup"
    fi
}

disable_notifications_for_e2e() {
    cp -a "$CFG" "$CFG_BAK"
    sed -i 's/^enabled[[:space:]]*=.*/enabled                  = false/' "$CFG"
    sed -i 's/^teams_enabled[[:space:]]*=.*/teams_enabled            = false/' "$CFG"
    sed -i 's/^email_enabled[[:space:]]*=.*/email_enabled            = false/' "$CFG"
    log "Disabled notifications for E2E"
}

cross_verify_gcp_metrics() {
    log ""
    log "=== GCP-VERIFY: Cross-check Cloud Monitoring connectivity ==="
    if ! command -v gcloud &>/dev/null; then
        log "SKIP: gcloud CLI not installed"
        SKIP=$(( SKIP + 1 ))
        return
    fi
    local project_flag=""
    [[ -n "${CLOUDSDK_CORE_PROJECT:-}" ]] && project_flag="--project=${CLOUDSDK_CORE_PROJECT}"
    local rc=0
    # shellcheck disable=SC2086
    gcloud sql instances describe "$SAVED_INST" $project_flag \
        --format='value(state)' >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        PASS=$(( PASS + 1 ))
        log "GCP-VERIFY: PASS (Cloud SQL API reachable)"
    else
        SKIP=$(( SKIP + 1 ))
        log "GCP-VERIFY: SKIP (Cloud SQL API unreachable or instance not found)"
    fi
}

mkdir -p tests
: > "$REPORT"
log "E2E test run $(date -u +%Y-%m-%dT%H%M%SZ)"
log "ROOT=$ROOT SAVED=$SAVED_INST DB=${DB_NAME:-none}"

disable_notifications_for_e2e
[[ -f "$THR_PATCH" ]] && apply_threshold_patch || log "No threshold patch file found — skipping patch"

run_case T01 "Local OS metrics (one-shot)" "metric rows with units" \
    bash monitor.sh os

run_case T02 "Cloud Monitoring saved instance" "GCP metric rows" \
    bash monitor.sh cloud --instance "$SAVED_INST"

run_case T03 "notify test logs alert" "dispatched" \
    bash monitor.sh notify test --severity WARNING --message "E2E notify test"

run_case T03b "alerts list" "shows entries" \
    bash monitor.sh alerts list --limit 5

run_case T04 "instances test saved" "connectivity OK" \
    bash monitor.sh instances test --name "$SAVED_INST"

if [[ -n "$DB_NAME" ]]; then
    run_case T05 "db test saved target" "OK or SKIPPED" \
        bash monitor.sh db test --name "$DB_NAME"
else
    log ""
    log "=== T05: SKIP (no DB_NAME provided) ==="
    SKIP=$(( SKIP + 1 ))
fi

run_case T06 "monitor one-shot saved gcp" "console output" \
    bash monitor.sh monitor --instances saved --source gcp

run_case T07 "monitor one-shot os" "localhost metrics" \
    bash monitor.sh monitor --instances saved --source os

log ""
log "=== T08: Full poll cycle (logs + eval + alerts) ==="
export MONITOR_POLL_MODE=daemon
export MONITOR_INCLUDE_OS=false
export MONITOR_INCLUDE_DB=false
export MONITOR_INCLUDE_LOCALHOST=false
export MONITOR_INCLUDE_SSH_HOSTS=false
if bash monitor.sh _poll >> "$REPORT" 2>&1; then
    PASS=$(( PASS + 1 )); log "RESULT: PASS"
else
    FAIL=$(( FAIL + 1 )); log "RESULT: FAIL"
fi
log "--- alerts (last 15) ---"
bash monitor.sh alerts list --limit 15 2>&1 | tee -a "$REPORT" || true

log ""
log "=== T09: run_monitor style cycle (instance + db) ==="
if timeout 180 bash -c "
    export MONITOR_POLL_MODE=continuous
    source lib/util.sh && source lib/config.sh && source lib/poll.sh
    poll_cycle_instances '$SAVED_INST'
    poll_db_connectivity
" >> "$REPORT" 2>&1; then
    PASS=$(( PASS + 1 )); log "RESULT: PASS"
else
    FAIL=$(( FAIL + 1 )); log "RESULT: FAIL"
fi

run_case T10 "secrets encrypt roundtrip" "OK" \
    bash -c 'source lib/util.sh && source lib/secrets.sh && save_cred e2e_test secret123 && test "$(get_cred e2e_test)" = secret123 && delete_cred e2e_test && echo OK'

run_case_expect_fail T11 "cloud fake instance" \
    bash monitor.sh cloud --instance definitely-not-a-real-cloudsql-instance-xyz

run_case_expect_fail T12 "instances test missing" \
    bash monitor.sh instances test --name __no_such_instance__

run_case_expect_fail T13 "db test missing" \
    bash monitor.sh db test --name __no_such_db__

run_case_expect_fail T14 "hosts test missing" \
    bash monitor.sh hosts test --name __no_such_host__

cross_verify_gcp_metrics

log ""
log "=== ARTEFACTS ==="
for f in \
    ".dbmonitor/runtime/logs/${SAVED_INST}/monitor_${SAVED_INST}.log" \
    ".dbmonitor/runtime/logs/localhost/monitor_localhost.log" \
    ".dbmonitor/runtime/breach_state.tsv" \
    "${ROOT}/alerts.log"
do
    if [[ -f "$f" ]]; then
        log "OK exists: $f ($(wc -l < "$f") lines)"
    else
        log "MISSING: $f"
    fi
done

if [[ "$SKIP_RESTORE" != true ]]; then
    restore_thresholds
fi

log ""
log "========================================"
log "E2E SUMMARY: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
log "Report: $REPORT"
log "========================================"
[[ "$FAIL" -eq 0 ]]
