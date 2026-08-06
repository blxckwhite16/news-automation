#!/bin/bash
#
# rearm-news-collector-trigger.sh — re-arms ONLY the News Collector workflow's
# live Schedule Trigger via REST API deactivate+activate. No container
# restart, no CLI import, no content change. Intended to be invoked by the
# Windows Wake Bridge (C:\temp\s4-wake-bridge.ps1) each morning after wake,
# well before the 08:30 trigger.
#
# Why this exists (2026-08-06 incident): n8n's legacy scheduler
# (n8n-core ScheduledTaskManager) keys each cron job by
# {expression, timezone, targetId, group} and silently no-ops registration if
# a job with that exact key is already in its in-memory map, without checking
# whether that entry is actually alive — logged as "Skipped registration for
# already registered cron". A `setTimeout` armed before a host hibernate can
# also carry a stale monotonic baseline relative to wall-clock time after
# resume (WSL2 clock drift on sleep/resume). A REST deactivate+activate pair
# fixes both: deactivate calls ActiveWorkflowManager.remove() ->
# ActiveWorkflowTriggers.remove() -> ScheduledTaskManager.deregisterGroup(),
# which calls the old cron's job.stop() (clearTimeout) and deletes the map
# entry; activate then calls ScheduledTaskManager.register(), which finds no
# matching key and constructs a brand-new cron.CronJob(), whose delay is
# computed fresh from Date.now() at that exact moment. See
# docs/SESSION_SUMMARY.md (2026-08-06 entry) for the full investigation.
#
# Console log lines from n8n's default (non-JSON, non-debug) logger carry no
# workflowId/groupId — "Deregistered all crons" and "Skipped registration..."
# look identical regardless of which workflow triggered them (confirmed by
# reading @n8n/backend-common logger.js: the default console transport format
# is `winston.format.printf(({ message }) => message)`, all metadata
# dropped). So every log-line check here is corroborating evidence only; the
# decisive signal is workflow_publish_history, which IS keyed by workflowId.
#
# A single-workflow REST activate never logs "Activated workflow ..." — that
# line is only emitted by ActiveWorkflowManager.activateWorkflow(), which is
# exclusively used by the boot-time / leadership-change bulk activation path
# (addActiveWorkflows()). REST activate goes through
# WorkflowService.activateWorkflow() -> _addToActiveWorkflowManager() ->
# ActiveWorkflowManager.add() directly, which never logs that line (confirmed
# by reading workflow.service.js and active-workflow-manager.js). Do not add
# a check for it here — it would fail unconditionally.
#
# Clock-sync gate: before touching anything, this script requires the
# caller (PowerShell, running on the Windows host) to pass its current UTC
# epoch as an argument, and compares it against this WSL environment's own
# clock. If a REST activate runs while WSL's wall clock is still lagging from
# a hibernate/resume cycle, the new CronJob's delay would be computed from a
# wrong "now" and would arm for the wrong real time — a new bug, not a fix.
# The comparison uses `sleep`-counted elapsed time (unaffected by wall-clock
# jumps) rather than repeatedly re-reading `date` against a frozen reference,
# because two epoch snapshots taken 60s apart on a possibly-adjusting clock
# cannot otherwise distinguish "still drifting" from "our own polling delay".
#
# Usage:
#   rearm-news-collector-trigger.sh rearm <host-utc-epoch-seconds> <expected-hour> <expected-minute>
#
# <expected-hour>/<expected-minute> are NOT a default or a guess — the caller
# must state what schedule it expects to find after re-arming (e.g. the
# production Wake Bridge always passes 8 30; a same-day E2E test passes
# whatever temporary time was deployed, e.g. 14 10). This script never
# hardcodes a specific time: 2026-08-06 E2E test found that an earlier
# version hardcoded 08:30 here, which made the whole run report
# REARM_FAILED even though the actual deactivate/activate re-arm had fully
# succeeded — the workflow's schedule was deliberately 14:10 for that test,
# not 08:30. A schedule mismatch and a genuine re-arm failure are reported
# with distinct RESULT reasons (see Step 7) so a caller (or a human reading
# the log later) never has to guess which one happened.
#
# Exit codes:
#   0 = success: re-arm succeeded AND the live Schedule Trigger matches
#       <expected-hour>:<expected-minute>
#   1 = real failure — this covers two distinct situations, always
#       distinguishable by the RESULT= reason string:
#         - the re-arm mechanics themselves failed (clock not synced, HTTP
#           error, missing "Deregistered all crons" / "Skipped
#           registration..." evidence, missing/wrong publish_history row,
#           active flag wrong) — RESULT=FAILED:<reason other than
#           schedule-mismatch>
#         - the re-arm mechanics fully succeeded but the live schedule does
#           not match what the caller said to expect — RESULT=FAILED:
#           schedule-mismatch:expected=H:M actual=H:M. This is not a re-arm
#           bug; it means the caller passed the wrong expected time, or the
#           workflow's schedule was changed by something else.
#       Caller should NOT fall back to `docker restart n8n` automatically in
#       this first iteration; that fallback is deliberately not implemented
#       yet (see docs/SESSION_SUMMARY.md).
#   2 = skipped because News Collector itself has an in-flight execution —
#       nothing was touched; this is not the same as a failure, but the day's
#       verification should still be recorded as incomplete by the caller.
#
set -euo pipefail

CONTAINER_NAME="${N8N_CONTAINER_NAME:-n8n}"
N8N_BASE_URL="${N8N_BASE_URL:-http://localhost:5678}"
API_KEY_FILE="${N8N_API_KEY_FILE:-$HOME/.config/n8n/api-key}"
WORKFLOW_ID="2hzQvxGKNmK6WgQW"
LOG_DIR="${N8N_WAKE_LOG_DIR:-$HOME/.config/n8n/wake-bridge-logs}"
CLOCK_TOLERANCE_SECONDS=5
CLOCK_MAX_WAIT_SECONDS=60
CLOCK_POLL_INTERVAL_SECONDS=5

mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/${TS}-rearm.log"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# log() must never be passed API key material. Every call site in this
# script is written so the key only ever appears inside a `$(cat "$API_KEY_FILE")`
# expansion directly inside a `curl -H` argument — never captured into a
# variable, never echoed, never diffed into a file.
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" | tee -a "$LOG_FILE"
}

result() {
  log "RESULT=$1"
}

if [[ ! -f "$API_KEY_FILE" ]]; then
  log "RESULT=FAILED:api-key-file-missing"
  exit 1
fi

# ---- args -------------------------------------------------------------
if [[ "${1:-}" != "rearm" || -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
  echo "Usage: $0 rearm <host-utc-epoch-seconds> <expected-hour> <expected-minute>" >&2
  exit 1
fi
HOST_EPOCH="$2"
EXPECTED_HOUR="$3"
EXPECTED_MINUTE="$4"
if ! [[ "$HOST_EPOCH" =~ ^[0-9]+$ ]]; then
  log "RESULT=FAILED:host-epoch-not-numeric ($HOST_EPOCH)"
  exit 1
fi
if ! [[ "$EXPECTED_HOUR" =~ ^[0-9]+$ && "$EXPECTED_MINUTE" =~ ^[0-9]+$ ]]; then
  log "RESULT=FAILED:expected-schedule-not-numeric (hour=$EXPECTED_HOUR minute=$EXPECTED_MINUTE)"
  exit 1
fi

log "=== rearm start: workflow=$WORKFLOW_ID host_epoch=$HOST_EPOCH expected_schedule=${EXPECTED_HOUR}:${EXPECTED_MINUTE} ==="

pull_db() {
  local dest="$1"
  docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite" "$dest.sqlite" 2>>"$LOG_FILE" || return 1
  docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite-wal" "$dest.sqlite-wal" 2>>"$LOG_FILE" || true
  docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite-shm" "$dest.sqlite-shm" 2>>"$LOG_FILE" || true
  return 0
}

# 'unknown' included alongside running/new/waiting: n8n's ExecutionStatusList
# treats canceled/crashed/error/success as the only terminal states.
check_inflight() {
  local db="$1"
  python3 - "$db" "$WORKFLOW_ID" <<'PYEOF'
import sqlite3, sys
db, workflow_id = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute(
    "SELECT id, mode, status, startedAt FROM execution_entity "
    "WHERE workflowId=? AND status IN ('running','new','waiting','unknown')",
    (workflow_id,),
)
rows = cur.fetchall()
if rows:
    print("INFLIGHT_FOUND")
    for r in rows:
        print(r)
    sys.exit(1)
print("NO_INFLIGHT")
PYEOF
}

count_log_lines() { docker logs "$CONTAINER_NAME" 2>&1 | wc -l; }
new_log_lines() { docker logs "$CONTAINER_NAME" 2>&1 | tail -n "+$(( $1 + 1 ))"; }

get_active() {
  python3 - "$1" "$WORKFLOW_ID" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
cur.execute("SELECT active FROM workflow_entity WHERE id=?", (sys.argv[2],))
row = cur.fetchone(); print(row[0] if row else "MISSING")
PYEOF
}

latest_publish_event() {
  python3 - "$1" "$WORKFLOW_ID" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
cur.execute("SELECT id, event, createdAt FROM workflow_publish_history "
            "WHERE workflowId=? ORDER BY id DESC LIMIT 1", (sys.argv[2],))
row = cur.fetchone(); print(row if row else "NONE")
PYEOF
}

# Reads the live Schedule Trigger's hour/minute and compares against the
# expected values the caller passed in (never a hardcoded literal — see the
# 2026-08-06 header note on why). Also rejects a node with a missing/invalid
# interval config as its own distinct failure, separate from a mismatch.
schedule_trigger_matches() {
  python3 - "$1" "$WORKFLOW_ID" "$2" "$3" <<'PYEOF'
import sqlite3, json, sys
db, workflow_id, expected_hour, expected_minute = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
con = sqlite3.connect(db); cur = con.cursor()
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (workflow_id,))
nodes = json.loads(cur.fetchone()[0])
for n in nodes:
    if n.get("type") == "n8n-nodes-base.scheduleTrigger":
        try:
            interval = n["parameters"]["rule"]["interval"][0]
            hour, minute = interval.get("triggerAtHour"), interval.get("triggerAtMinute")
        except (KeyError, IndexError):
            print("SCHEDULE_INVALID: no valid hour/minute interval on Schedule Trigger node")
            sys.exit(2)
        print(f"schedule trigger: {n['name']} hour={hour} minute={minute} "
              f"(expected {expected_hour}:{expected_minute})")
        if hour == expected_hour and minute == expected_minute:
            print("SCHEDULE_MATCH")
            sys.exit(0)
        print(f"SCHEDULE_MISMATCH:expected={expected_hour}:{expected_minute} actual={hour}:{minute}")
        sys.exit(1)
print("SCHEDULE_INVALID: no Schedule Trigger node found")
sys.exit(2)
PYEOF
}

# ---- Step 1: in-flight check for News Collector only ------------------
log "Step 1: checking for in-flight News Collector executions"
if ! pull_db "$WORK_DIR/pre"; then
  result "FAILED:db-read-pre"
  exit 1
fi
if ! check_inflight "$WORK_DIR/pre.sqlite" | tee -a "$LOG_FILE" | grep -q "NO_INFLIGHT"; then
  result "SKIPPED_IN_FLIGHT"
  exit 2
fi

PRE_ACTIVE="$(get_active "$WORK_DIR/pre.sqlite")"
log "active before rearm = $PRE_ACTIVE"
if [[ "$PRE_ACTIVE" != "1" ]]; then
  result "FAILED:not-active-before-rearm(expected 1, got $PRE_ACTIVE)"
  exit 1
fi

# ---- Step 2: clock-sync gate -------------------------------------------
log "Step 2: verifying WSL clock is synced with host (tolerance ${CLOCK_TOLERANCE_SECONDS}s, budget ${CLOCK_MAX_WAIT_SECONDS}s)"
CLOCK_SYNCED=0
ATTEMPT=0
while true; do
  ELAPSED=$(( ATTEMPT * CLOCK_POLL_INTERVAL_SECONDS ))
  WSL_EPOCH="$(date +%s)"
  EXPECTED_EPOCH=$(( HOST_EPOCH + ELAPSED ))
  DIFF=$(( WSL_EPOCH - EXPECTED_EPOCH ))
  ABS_DIFF=$(( DIFF < 0 ? -DIFF : DIFF ))
  log "clock check #$ATTEMPT: host_epoch=$HOST_EPOCH elapsed(sleep-counted)=${ELAPSED}s expected=$EXPECTED_EPOCH wsl_epoch=$WSL_EPOCH diff=${DIFF}s"
  if [[ "$ABS_DIFF" -le "$CLOCK_TOLERANCE_SECONDS" ]]; then
    log "clock sync OK (diff=${DIFF}s)"
    CLOCK_SYNCED=1
    break
  fi
  if [[ "$ELAPSED" -ge "$CLOCK_MAX_WAIT_SECONDS" ]]; then
    log "clock sync FAILED after ${CLOCK_MAX_WAIT_SECONDS}s budget (last diff=${DIFF}s)"
    break
  fi
  sleep "$CLOCK_POLL_INTERVAL_SECONDS"
  ATTEMPT=$(( ATTEMPT + 1 ))
done
if [[ "$CLOCK_SYNCED" -ne 1 ]]; then
  result "FAILED:CLOCK_NOT_SYNCED"
  exit 1
fi

# ---- Step 3: REST API deactivate ---------------------------------------
log "Step 3: REST API deactivate"
PRE_DEACT_LINES="$(count_log_lines)"
HTTP="$(curl -s -o "$WORK_DIR/deact.json" -w "%{http_code}" -X POST \
  -H "X-N8N-API-KEY: $(cat "$API_KEY_FILE")" \
  "${N8N_BASE_URL}/api/v1/workflows/${WORKFLOW_ID}/deactivate")"
log "deactivate HTTP=$HTTP"
if [[ "$HTTP" != "200" ]]; then
  result "FAILED:deactivate-http-$HTTP"
  exit 1
fi

# ---- Step 4: verify live deregistration + fresh 'deactivated' history --
log "Step 4: verifying live cron deregistration"
DEREG_HITS="$(new_log_lines "$PRE_DEACT_LINES" | grep -c "Deregistered all crons" || true)"
log "'Deregistered all crons' occurrences in post-deactivate log window: $DEREG_HITS"
if [[ "$DEREG_HITS" -eq 0 ]]; then
  result "FAILED:no-deregister-log"
  exit 1
fi
if ! pull_db "$WORK_DIR/postdeact"; then
  result "FAILED:db-read-postdeact"
  exit 1
fi
DEACT_EVENT="$(latest_publish_event "$WORK_DIR/postdeact.sqlite")"
log "publish_history after deactivate: $DEACT_EVENT"
if [[ "$DEACT_EVENT" != *"'deactivated'"* ]]; then
  result "FAILED:no-deactivated-publish-row"
  exit 1
fi
ACTIVE_AFTER_DEACT="$(get_active "$WORK_DIR/postdeact.sqlite")"
log "active after deactivate = $ACTIVE_AFTER_DEACT"
if [[ "$ACTIVE_AFTER_DEACT" != "0" ]]; then
  result "FAILED:active-not-0-after-deactivate"
  exit 1
fi

# ---- Step 5: REST API activate ------------------------------------------
log "Step 5: REST API activate"
PRE_ACT_LINES="$(count_log_lines)"
HTTP="$(curl -s -o "$WORK_DIR/act.json" -w "%{http_code}" -X POST \
  -H "X-N8N-API-KEY: $(cat "$API_KEY_FILE")" \
  "${N8N_BASE_URL}/api/v1/workflows/${WORKFLOW_ID}/activate")"
log "activate HTTP=$HTTP"
if [[ "$HTTP" != "200" ]]; then
  result "FAILED:activate-http-$HTTP"
  exit 1
fi

# ---- Step 6: verify no skip + fresh 'activated' history + active=true --
log "Step 6: verifying live cron registration (no skip)"
NEW_LINES_FILE="$WORK_DIR/post-activate-log.txt"
new_log_lines "$PRE_ACT_LINES" > "$NEW_LINES_FILE"
cat "$NEW_LINES_FILE" | tee -a "$LOG_FILE" >/dev/null
if grep -q "Skipped registration for already registered cron" "$NEW_LINES_FILE"; then
  result "FAILED:skip-detected-after-activate"
  exit 1
fi
if ! pull_db "$WORK_DIR/postact"; then
  result "FAILED:db-read-postact"
  exit 1
fi
ACT_EVENT="$(latest_publish_event "$WORK_DIR/postact.sqlite")"
log "publish_history after activate: $ACT_EVENT"
if [[ "$ACT_EVENT" != *"'activated'"* ]]; then
  result "FAILED:no-activated-publish-row"
  exit 1
fi
ACTIVE_FINAL="$(get_active "$WORK_DIR/postact.sqlite")"
log "active after activate = $ACTIVE_FINAL"
if [[ "$ACTIVE_FINAL" != "1" ]]; then
  result "FAILED:active-not-1-after-activate"
  exit 1
fi

# ---- Step 7: Schedule Trigger must match the caller's expected value ----
# This check runs AFTER the re-arm (Steps 3-6) has already fully succeeded.
# A failure here means the re-arm mechanics worked but the schedule wasn't
# what the caller expected — a configuration mismatch, not a re-arm bug.
# schedule_trigger_matches() exits 0 (match), 1 (mismatch), or 2 (no valid
# Schedule Trigger found at all) — each mapped to its own RESULT reason so
# this is never confused with a deactivate/activate/log/DB failure above.
log "Step 7: verifying Schedule Trigger matches expected ${EXPECTED_HOUR}:${EXPECTED_MINUTE}"
set +e
SCHEDULE_CHECK_OUTPUT="$(schedule_trigger_matches "$WORK_DIR/postact.sqlite" "$EXPECTED_HOUR" "$EXPECTED_MINUTE")"
SCHEDULE_CHECK_STATUS=$?
set -e
echo "$SCHEDULE_CHECK_OUTPUT" | tee -a "$LOG_FILE"
if [[ "$SCHEDULE_CHECK_STATUS" -eq 1 ]]; then
  MISMATCH_DETAIL="$(echo "$SCHEDULE_CHECK_OUTPUT" | grep "SCHEDULE_MISMATCH" || true)"
  result "FAILED:schedule-mismatch (re-arm itself succeeded — see Steps 3-6 above; $MISMATCH_DETAIL)"
  exit 1
elif [[ "$SCHEDULE_CHECK_STATUS" -eq 2 ]]; then
  result "FAILED:schedule-invalid (re-arm itself succeeded — see Steps 3-6 above; no valid Schedule Trigger config found)"
  exit 1
fi

# ---- Step 8: final in-flight sanity check --------------------------------
log "Step 8: final in-flight check"
if ! check_inflight "$WORK_DIR/postact.sqlite" | tee -a "$LOG_FILE" | grep -q "NO_INFLIGHT"; then
  result "FAILED:inflight-after-rearm(unexpected)"
  exit 1
fi

result "SUCCESS"
exit 0
