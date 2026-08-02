#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/codex_share_package.py"
TMP_ROOT="$(mktemp -d /tmp/codex-cold-batch-test.XXXXXX)"
HOLDER_PID=""
trap '[[ -z "$HOLDER_PID" ]] || kill "$HOLDER_PID" 2>/dev/null || true; find "$TMP_ROOT" -depth -delete 2>/dev/null || true' EXIT
HOME_DIR="$TMP_ROOT/account"
EXTERNAL_DIR="$TMP_ROOT/external"
INDEX_FILE="$TMP_ROOT/app-data/cold-index.json"
SAFE_ID="019fcold-1000-7000-8000-000000000001"
PINNED_ID="019fcold-1000-7000-8000-000000000002"
GOAL_ID="019fcold-1000-7000-8000-000000000003"
RECENT_ID="019fcold-1000-7000-8000-000000000004"
mkdir -p "$HOME_DIR/sessions" "$EXTERNAL_DIR"

python3 - "$HOME_DIR" "$SAFE_ID" "$PINNED_ID" "$GOAL_ID" "$RECENT_ID" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

home = Path(sys.argv[1])
safe_id, pinned_id, goal_id, recent_id = sys.argv[2:]
now_ms = int(time.time() * 1000)
old_ms = now_ms - 10 * 86_400_000
con = sqlite3.connect(home / "state_5.sqlite")
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, rollout_path TEXT, archived INTEGER, is_pinned INTEGER, cwd TEXT, updated_at_ms INTEGER, recency_at_ms INTEGER)")
for thread_id, pinned, updated in ((safe_id, 0, old_ms), (pinned_id, 1, old_ms), (goal_id, 0, old_ms), (recent_id, 0, now_ms)):
    rollout = home / "sessions" / f"rollout-{thread_id}.jsonl"
    rollout.write_text(json.dumps({"type": "session_meta", "payload": {"id": thread_id}}) + "\n", encoding="utf-8")
    if updated == old_ms:
        old_seconds = old_ms / 1000
        import os
        os.utime(rollout, (old_seconds, old_seconds))
    con.execute("INSERT INTO threads VALUES (?, ?, ?, 0, ?, ?, ?, ?)", (thread_id, thread_id, str(rollout), pinned, str(home), updated, updated))
con.commit()
con.close()
goals = sqlite3.connect(home / "goals_1.sqlite")
goals.execute("CREATE TABLE thread_goals (goal_id TEXT, thread_id TEXT, status TEXT)")
goals.execute("INSERT INTO thread_goals VALUES ('goal-1', ?, 'active')", (goal_id,))
goals.commit()
goals.close()
with (home / "session_index.jsonl").open("w", encoding="utf-8") as handle:
    for thread_id in (safe_id, pinned_id, goal_id, recent_id):
        handle.write(json.dumps({"id": thread_id, "thread_name": thread_id}) + "\n")
PY

CANDIDATES="$(python3 "$HELPER" cold-candidates \
  --account-home "$HOME_DIR" \
  --target "account1=$HOME_DIR" \
  --older-than-days 7 \
  --ids-only)"
[[ "$CANDIDATES" == "$SAFE_ID" ]]

READY="$TMP_ROOT/open-ready"
python3 - "$HOME_DIR/state_5.sqlite" "$READY" <<'PY' &
import signal
import sys
from pathlib import Path
with Path(sys.argv[1]).open("rb"):
    Path(sys.argv[2]).touch()
    signal.pause()
PY
HOLDER_PID=$!
for _ in {1..100}; do
  [[ -e "$READY" ]] && break
  sleep 0.02
done
[[ -e "$READY" ]]
busy_rc=0
python3 "$HELPER" cold-archive \
  --account-name account1 \
  --account-home "$HOME_DIR" \
  --thread-id "$SAFE_ID" \
  --archive-root "$EXTERNAL_DIR" \
  --index "$INDEX_FILE" \
  --target "account1=$HOME_DIR" \
  --max-attachment-bytes 0 >/dev/null 2>&1 || busy_rc=$?
[[ "$busy_rc" == "75" ]]
[[ -e "$HOME_DIR/sessions/rollout-$SAFE_ID.jsonl" ]]
kill "$HOLDER_PID"
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""

python3 "$HELPER" cold-archive-many \
  --account-name account1 \
  --account-home "$HOME_DIR" \
  --archive-root "$EXTERNAL_DIR" \
  --index "$INDEX_FILE" \
  --target "account1=$HOME_DIR" \
  --thread-id "$SAFE_ID" \
  --thread-id "$PINNED_ID" \
  --max-attachment-bytes 0 >/dev/null

[[ "$(python3 "$HELPER" cold-list --index "$INDEX_FILE" | awk 'NF {count++} END {print count+0}')" == "2" ]]
[[ ! -e "$HOME_DIR/sessions/rollout-$SAFE_ID.jsonl" ]]
[[ ! -e "$HOME_DIR/sessions/rollout-$PINNED_ID.jsonl" ]]
[[ -e "$HOME_DIR/sessions/rollout-$GOAL_ID.jsonl" ]]
[[ -e "$HOME_DIR/sessions/rollout-$RECENT_ID.jsonl" ]]

python3 "$HELPER" cold-restore-many \
  --index "$INDEX_FILE" \
  --target "account1=$HOME_DIR" \
  --thread-id "$SAFE_ID" \
  --thread-id "$PINNED_ID" >/dev/null

[[ -e "$HOME_DIR/sessions/rollout-$SAFE_ID.jsonl" ]]
[[ -e "$HOME_DIR/sessions/rollout-$PINNED_ID.jsonl" ]]
[[ -z "$(python3 "$HELPER" cold-list --index "$INDEX_FILE")" ]]
python3 - "$HOME_DIR/state_5.sqlite" "$SAFE_ID" "$PINNED_ID" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
for thread_id in sys.argv[2:]:
    archived, rollout = con.execute("SELECT archived, rollout_path FROM threads WHERE id = ?", (thread_id,)).fetchone()
    assert archived == 0
    assert rollout
PY

echo "Codex cold storage batch checks passed"
