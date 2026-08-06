#!/bin/bash
#
# deploy-production-workflow.sh — the ONLY sanctioned way to push a workflow
# JSON change to this project's live n8n instance.
#
# Why this exists (2026-08-05 incident): `n8n import:workflow` / `publish:workflow`
# only ever touch the database — they run in a short-lived CLI process that has
# no connection to the already-running server's in-memory ActiveWorkflowManager.
# Historically this was "fixed" with `docker restart n8n`, but that restarts the
# entire instance (every workflow, not just the one being deployed) and leaves no
# audit trail. REST API activate/deactivate calls run INSIDE the live server
# process and directly register/deregister the trigger.
#
# Why this was rewritten again (2026-08-06 incident): the original CLI-import ->
# REST-activate order still let the trigger go dark. n8n's legacy scheduler
# (n8n-core ScheduledTaskManager) keys each cron job by
# {expression, timezone, targetId, group} and silently no-ops registration if a
# job with that exact key is already sitting in its in-memory map — it never
# checks whether that existing entry is actually alive. CLI `import:workflow`
# only flips the DB `active` column for an already-active workflow; it never
# calls the live deregister path (ActiveWorkflowTriggers.remove() ->
# ScheduledTaskManager.deregisterGroup(), which is what actually clears that
# map and logs "Deregistered all crons"). So the old order left a stale
# registration in memory, and the subsequent REST activate found the same key
# still present and logged "Skipped registration for already registered cron"
# instead of arming a fresh timer — while still reporting active=true and a
# clean publish-history row, because neither of those reflect the live
# scheduler's internal map. Confirmed by reading scheduled-task-manager.js and
# active-workflow-triggers.js (n8n 2.32.6) and correlating the one occurrence
# of that log line, to the millisecond, with the deploy that broke the
# 2026-08-06 08:30 run.
#
# Fix: call REST deactivate BEFORE the CLI import (so the live deregister path
# actually runs and the in-memory key is genuinely cleared), then CLI import,
# then REST activate — and treat the container log as an active check, not
# just the DB/API response. Console log lines from n8n's default (non-JSON,
# non-debug) logger carry no workflowId/groupId — "Deregistered all crons" and
# "Skipped registration for already registered cron" look identical regardless
# of which workflow triggered them (confirmed by reading
# @n8n/backend-common logger.js: the default console transport format is
# `winston.format.printf(({ message }) => message)`, metadata included in the
# call is dropped). So log-line presence/absence is corroborating evidence,
# not proof by itself — this script also cross-checks workflow_publish_history
# (which IS keyed by workflowId) for a freshly-created row after each call.
# Both signals agreeing is the actual success condition.
#
# This script never restarts the container, never calls `publish:workflow`,
# and never calls `n8n execute` (that command can silently run the real
# workflow — including live Google Sheets/Telegram side effects — even when
# it prints a fatal-looking CLI error; confirmed by incident on 2026-08-05).
# See docs/SESSION_SUMMARY.md (2026-08-05, 2026-08-06 entries) for the full
# investigations this procedure is based on.
#
# Usage:
#   scripts/deploy-production-workflow.sh <workflow-id> <path-to-new-workflow.json>
#
# Requires:
#   - docker CLI access to the "n8n" container
#   - python3 on the host
#   - an n8n API key at $API_KEY_FILE (workflow:read, workflow:activate,
#     workflow:deactivate scopes) — never printed, logged, or committed
#
set -euo pipefail

# ---- config -----------------------------------------------------------
CONTAINER_NAME="${N8N_CONTAINER_NAME:-n8n}"
N8N_BASE_URL="${N8N_BASE_URL:-http://localhost:5678}"
API_KEY_FILE="${N8N_API_KEY_FILE:-$HOME/.config/n8n/api-key}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$REPO_ROOT/n8n/workflows/backups"
DEPLOY_LOG_DIR="$BACKUP_DIR/deploy-logs"
DB_WORK_DIR="$(mktemp -d)"

trap 'rm -rf "$DB_WORK_DIR"' EXIT

# ---- args ---------------------------------------------------------------
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <workflow-id> <path-to-new-workflow.json>" >&2
  exit 1
fi
WORKFLOW_ID="$1"
NEW_WORKFLOW_JSON="$2"

if [[ ! -f "$NEW_WORKFLOW_JSON" ]]; then
  echo "FAILED AT STEP 0 (args): file not found: $NEW_WORKFLOW_JSON" >&2
  exit 1
fi
if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "FAILED AT STEP 0 (args): API key file not found: $API_KEY_FILE" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR" "$DEPLOY_LOG_DIR"
DEPLOY_LOG="$DEPLOY_LOG_DIR/${TS}-${WORKFLOW_ID}.log"

log() {
  # Never pass secret material to this function.
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" | tee -a "$DEPLOY_LOG"
}

fail() {
  log "FAILED AT STEP $1: $2"
  log "Deploy aborted. Live workflow state may be inconsistent — verify manually before retrying."
  exit 1
}

# Copies database.sqlite + WAL + SHM together; a WAL-less copy can silently
# show stale data (bit us during the 2026-08-03 investigation). The main
# .sqlite file is mandatory; -wal/-shm may legitimately not exist right after
# a checkpoint, so their absence is only a warning, not a hard failure.
pull_db() {
  local dest="$1"
  if ! docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite" "$dest.sqlite" 2>>"$DEPLOY_LOG"; then
    return 1
  fi
  docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite-wal" "$dest.sqlite-wal" 2>>"$DEPLOY_LOG" \
    || log "WARNING: could not copy database.sqlite-wal (may not exist right now) — continuing"
  docker cp "$CONTAINER_NAME:/home/node/.n8n/database.sqlite-shm" "$dest.sqlite-shm" 2>>"$DEPLOY_LOG" \
    || log "WARNING: could not copy database.sqlite-shm (may not exist right now) — continuing"
  return 0
}

# 'unknown' added alongside running/new/waiting: n8n's ExecutionStatusList
# treats canceled/crashed/error/success as the only terminal states, so
# 'unknown' is still in-flight-shaped even though it's rare in practice.
check_no_inflight() {
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

# Deterministic log-window helper: docker logs --since has been unreliable in
# this environment (see docs/SESSION_SUMMARY.md, 2026-08-03/08-05 notes), so
# every "did X get logged by this call" check is done by line-count offset
# instead of a timestamp filter.
count_log_lines() {
  docker logs "$CONTAINER_NAME" 2>&1 | wc -l
}

new_log_lines() {
  local offset="$1"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -n "+$((offset + 1))"
}

latest_publish_event() {
  local db="$1"
  python3 - "$db" "$WORKFLOW_ID" <<'PYEOF'
import sqlite3, sys
db, workflow_id = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute(
    "SELECT id, event, createdAt FROM workflow_publish_history "
    "WHERE workflowId=? ORDER BY id DESC LIMIT 1",
    (workflow_id,),
)
row = cur.fetchone()
print(row if row else "NONE")
PYEOF
}

get_active() {
  local db="$1"
  python3 - "$db" "$WORKFLOW_ID" <<'PYEOF'
import sqlite3, sys
db, workflow_id = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("SELECT active FROM workflow_entity WHERE id=?", (workflow_id,))
row = cur.fetchone()
print(row[0] if row else "MISSING")
PYEOF
}

log "=== Deploy start: workflow=$WORKFLOW_ID source=$NEW_WORKFLOW_JSON ==="

# ---- Step 1: pre-flight in-flight execution check --------------------------
log "Step 1: pre-flight in-flight execution check"
if ! pull_db "$DB_WORK_DIR/pre"; then
  fail 1 "could not read database.sqlite from container before deploy"
fi
if ! check_no_inflight "$DB_WORK_DIR/pre.sqlite" | tee -a "$DEPLOY_LOG" | grep -q "NO_INFLIGHT"; then
  fail 1 "in-flight execution(s) found before deploy started — aborting without touching the workflow"
fi
PRE_ACTIVE="$(get_active "$DB_WORK_DIR/pre.sqlite")"
log "active before deploy = $PRE_ACTIVE"

# ---- Step 2: backup live workflow (export) + diff against new JSON ---------
log "Step 2: exporting live workflow as pre-deploy backup"
if ! docker exec "$CONTAINER_NAME" n8n export:workflow --id="$WORKFLOW_ID" --output="/tmp/predeploy-${TS}.json" >>"$DEPLOY_LOG" 2>&1; then
  fail 2 "n8n export:workflow failed"
fi
BACKUP_FILE="$BACKUP_DIR/${WORKFLOW_ID}-${TS}-preDeploy.json"
if ! docker cp "$CONTAINER_NAME:/tmp/predeploy-${TS}.json" "$BACKUP_FILE" 2>>"$DEPLOY_LOG"; then
  fail 2 "could not copy exported backup out of container"
fi
if [[ ! -s "$BACKUP_FILE" ]]; then
  fail 2 "backup file is missing or empty after export"
fi
log "Backup written to $BACKUP_FILE"

log "Step 2b: diffing new workflow against live backup"
DIFF_FILE="$DB_WORK_DIR/diff.txt"
if ! python3 - "$BACKUP_FILE" "$NEW_WORKFLOW_JSON" > "$DIFF_FILE" 2>>"$DEPLOY_LOG" <<'PYEOF'
import json, sys, difflib
a_path, b_path = sys.argv[1], sys.argv[2]
with open(a_path) as f:
    a = json.load(f)
with open(b_path) as f:
    b = json.load(f)
a_norm = json.dumps(a, indent=2, sort_keys=True).splitlines()
b_norm = json.dumps(b, indent=2, sort_keys=True).splitlines()
diff = list(difflib.unified_diff(a_norm, b_norm, lineterm=""))
print("\n".join(diff))
PYEOF
then
  fail 2 "diff computation failed (invalid JSON in backup or new file?)"
fi
if [[ ! -s "$DIFF_FILE" ]]; then
  fail 2 "new workflow JSON is identical to the live version — nothing to deploy"
fi
log "Diff (live backup -> new):"
cat "$DIFF_FILE" | tee -a "$DEPLOY_LOG"

# ---- Step 3: REST API deactivate (BEFORE the CLI import) -------------------
# This is the fix: only a REST-driven deactivate walks the live
# ActiveWorkflowTriggers.remove() -> ScheduledTaskManager.deregisterGroup()
# path that actually clears the in-memory cron map. Skip the call entirely if
# the workflow is already inactive (nothing to deregister, and n8n's own
# deregisterGroup() only logs when it found something to remove).
log "Step 3: REST API deactivate (pre-import)"
PRE_DEACTIVATE_LINES="$(count_log_lines)"
if [[ "$PRE_ACTIVE" == "1" ]]; then
  DEACTIVATE_RESP_FILE="$DB_WORK_DIR/deactivate-resp.json"
  HTTP_CODE="$(curl -s -o "$DEACTIVATE_RESP_FILE" -w "%{http_code}" -X POST \
    -H "X-N8N-API-KEY: $(cat "$API_KEY_FILE")" \
    -H "Content-Type: application/json" \
    "${N8N_BASE_URL}/api/v1/workflows/${WORKFLOW_ID}/deactivate")"
  log "deactivate HTTP status = $HTTP_CODE"
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail 3 "deactivate call returned HTTP $HTTP_CODE (response body in $DEACTIVATE_RESP_FILE, API key never logged)"
  fi
else
  log "workflow was already active=0 before this deploy — skipping deactivate call (nothing to deregister)"
fi

# ---- Step 4: verify the live deregister actually happened ------------------
# Two independent signals, both required when a deactivate call was made:
#   (a) "Deregistered all crons" appears in the log lines written since Step 3
#       started — this message is NOT workflowId-scoped in n8n's default
#       (non-JSON) console format, so it is corroborating, not conclusive, on
#       its own (see header comment).
#   (b) workflow_publish_history has a fresh 'deactivated' row for THIS
#       workflow ID specifically — this table IS scoped by workflowId, so it
#       is the conclusive half of the check.
# Both together confirm "something in the live process deregistered a cron
# AND the DB recorded that it was this workflow's deactivation" — as close to
# proof as the current logging setup allows without switching n8n to
# N8N_LOG_FORMAT=json (a separate, bigger change, not made here).
log "Step 4: verifying live cron deregistration"
if [[ "$PRE_ACTIVE" == "1" ]]; then
  DEREGISTER_LOG_HIT="$(new_log_lines "$PRE_DEACTIVATE_LINES" | grep -c "Deregistered all crons" || true)"
  log "'Deregistered all crons' occurrences in post-deactivate log window: $DEREGISTER_LOG_HIT"
  if [[ "$DEREGISTER_LOG_HIT" -eq 0 ]]; then
    fail 4 "no 'Deregistered all crons' log line appeared after REST deactivate — live process may not have deregistered the cron (this is exactly the 2026-08-06 failure mode)"
  fi
  if ! pull_db "$DB_WORK_DIR/postdeactivate"; then
    fail 4 "could not read database.sqlite from container after deactivate"
  fi
  DEACTIVATE_EVENT="$(latest_publish_event "$DB_WORK_DIR/postdeactivate.sqlite")"
  log "latest publish_history row after deactivate: $DEACTIVATE_EVENT"
  if [[ "$DEACTIVATE_EVENT" != *"'deactivated'"* ]]; then
    fail 4 "no fresh 'deactivated' event found in workflow_publish_history for this workflow ID"
  fi
else
  log "no deactivate call was made (already inactive) — skipping log/publish-history check"
  pull_db "$DB_WORK_DIR/postdeactivate" || fail 4 "could not read database.sqlite"
fi

# ---- Step 5: verify active=0 before importing content ----------------------
log "Step 5: verifying active=0 before CLI import"
ACTIVE_BEFORE_IMPORT="$(get_active "$DB_WORK_DIR/postdeactivate.sqlite")"
log "active before import = $ACTIVE_BEFORE_IMPORT"
if [[ "$ACTIVE_BEFORE_IMPORT" != "0" ]]; then
  fail 5 "expected active=0 before import, got '$ACTIVE_BEFORE_IMPORT'"
fi

# ---- Step 6: CLI import (content only) --------------------------------------
log "Step 6: docker exec n8n import:workflow (content-only)"
if ! docker cp "$NEW_WORKFLOW_JSON" "$CONTAINER_NAME:/tmp/deploy-${TS}.json" 2>>"$DEPLOY_LOG"; then
  fail 6 "could not copy new workflow JSON into container"
fi
if ! docker exec "$CONTAINER_NAME" n8n import:workflow --input="/tmp/deploy-${TS}.json" >>"$DEPLOY_LOG" 2>&1; then
  fail 6 "n8n import:workflow failed"
fi

# ---- Step 7: verify active=0 held after import ------------------------------
log "Step 7: verifying active=0 held after import"
if ! pull_db "$DB_WORK_DIR/postimport"; then
  fail 7 "could not read database.sqlite from container after import"
fi
ACTIVE_AFTER_IMPORT="$(get_active "$DB_WORK_DIR/postimport.sqlite")"
log "active after import = $ACTIVE_AFTER_IMPORT"
if [[ "$ACTIVE_AFTER_IMPORT" != "0" ]]; then
  fail 7 "expected active=0 after import, got '$ACTIVE_AFTER_IMPORT'"
fi

# ---- Step 8: REST API activate ----------------------------------------------
log "Step 8: calling REST API activate"
PRE_ACTIVATE_LINES="$(count_log_lines)"
API_RESP_FILE="$DB_WORK_DIR/activate-resp.json"
HTTP_CODE="$(curl -s -o "$API_RESP_FILE" -w "%{http_code}" -X POST \
  -H "X-N8N-API-KEY: $(cat "$API_KEY_FILE")" \
  -H "Content-Type: application/json" \
  "${N8N_BASE_URL}/api/v1/workflows/${WORKFLOW_ID}/activate")"
log "activate HTTP status = $HTTP_CODE"
if [[ "$HTTP_CODE" != "200" ]]; then
  fail 8 "activate call returned HTTP $HTTP_CODE (response body in $API_RESP_FILE, API key never logged)"
fi

# ---- Step 9: verify the live registration actually happened ----------------
# Hard failure condition: "Skipped registration for already registered cron"
# anywhere in the log lines written since Step 8 started. This is the exact
# line that caused the 2026-08-06 08:30 miss, and the whole point of moving
# deactivate before the import was to make sure this line can no longer
# appear here. If it does anyway, something is still wrong and this deploy
# must not be reported as a success.
log "Step 9: verifying live cron registration (no skip)"
NEW_LINES_FILE="$DB_WORK_DIR/post-activate-log.txt"
new_log_lines "$PRE_ACTIVATE_LINES" > "$NEW_LINES_FILE"
cat "$NEW_LINES_FILE" | tee -a "$DEPLOY_LOG" >/dev/null
if grep -q "Skipped registration for already registered cron" "$NEW_LINES_FILE"; then
  fail 9 "'Skipped registration for already registered cron' appeared after REST activate — the trigger was NOT freshly armed, even though the API will report active=true. Do not trust this deploy; investigate the live ScheduledTaskManager state before retrying."
fi
# NOTE: there is no positive log line to require here. "Activated workflow
# ..." is only ever logged by ActiveWorkflowManager.activateWorkflow(), which
# is exclusively used by the boot-time / leadership-change bulk activation
# path (addActiveWorkflows()). A single-workflow REST activate goes through
# WorkflowService.activateWorkflow() -> _addToActiveWorkflowManager() ->
# ActiveWorkflowManager.add() directly, which never logs that line (confirmed
# by reading workflow.service.js and active-workflow-manager.js) — requiring
# it here would make every future deploy fail Step 9 unconditionally. The
# real success node ("Registered cron") is only logged at debug level, which
# this instance doesn't run with. So the achievable positive signal is: no
# skip line here, HTTP 200 on the activate call (Step 8), and a fresh
# workflow-scoped 'activated' row in workflow_publish_history (Step 11) — not
# a console log line proving the trigger was registered.
log "confirmed: no 'Skipped registration' line in the post-activate log window"

# ---- Step 10: verify API response active=true -------------------------------
log "Step 10: verifying API response active=true"
API_ACTIVE="$(python3 - "$API_RESP_FILE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("active"))
PYEOF
)"
if [[ "$API_ACTIVE" != "True" ]]; then
  fail 10 "activate API response did not report active=true (got '$API_ACTIVE')"
fi
log "API response confirms active=true"

# ---- Step 11: verify workflow_publish_history has a fresh 'activated' event -
log "Step 11: verifying workflow_publish_history logged the activation"
if ! pull_db "$DB_WORK_DIR/postactivate"; then
  fail 11 "could not read database.sqlite from container after activation"
fi
PUBLISH_EVENT="$(latest_publish_event "$DB_WORK_DIR/postactivate.sqlite")"
log "latest publish_history row: $PUBLISH_EVENT"
if [[ "$PUBLISH_EVENT" != *"'activated'"* ]]; then
  fail 11 "no fresh 'activated' event found in workflow_publish_history"
fi

# ---- Step 12: final content + in-flight sanity check ------------------------
log "Step 12: confirming Schedule Trigger / Telegram / Sheets config and final in-flight state"
python3 - "$DB_WORK_DIR/postactivate.sqlite" "$WORKFLOW_ID" <<'PYEOF' | tee -a "$DEPLOY_LOG"
import sqlite3, json, sys
db, workflow_id = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("SELECT active, activeVersionId FROM workflow_entity WHERE id=?", (workflow_id,))
print("active/activeVersionId:", cur.fetchone())
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (workflow_id,))
nodes = json.loads(cur.fetchone()[0])
for n in nodes:
    t = n.get("type", "")
    if t == "n8n-nodes-base.scheduleTrigger":
        print("schedule trigger:", n["name"], n["parameters"])
    elif t == "n8n-nodes-base.telegram":
        print("telegram node:", n["name"], "disabled:", n.get("disabled", False),
              "chatId set:", "chatId" in n.get("parameters", {}))
    elif t == "n8n-nodes-base.googleSheets":
        print("sheets node:", n["name"], "documentId set:",
              n.get("parameters", {}).get("documentId") is not None)
PYEOF

if ! check_no_inflight "$DB_WORK_DIR/postactivate.sqlite" | tee -a "$DEPLOY_LOG" | grep -q "NO_INFLIGHT"; then
  fail 12 "in-flight execution(s) detected after activation — investigate before trusting this deploy"
fi

# ---- deploy summary ----------------------------------------------------
log "Deploy summary"
log "workflow_id=$WORKFLOW_ID"
log "backup_file=$BACKUP_FILE"
log "deployed_file=$NEW_WORKFLOW_JSON"
log "result=SUCCESS"
log "=== Deploy complete ==="

echo "Deploy log: $DEPLOY_LOG"
