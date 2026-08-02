#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/codex_share_package.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-cold-storage-test.XXXXXX")"
trap 'find "$TMP_ROOT" -depth -delete 2>/dev/null || true' EXIT

HOME_DIR="$TMP_ROOT/account"
SHARED_DIR="$TMP_ROOT/shared"
EXTERNAL_DIR="$TMP_ROOT/external"
INDEX_FILE="$TMP_ROOT/app-data/cold-index.json"
THREAD_ID="019fcold-0000-7000-8000-000000000001"
mkdir -p "$HOME_DIR" "$SHARED_DIR/sessions/2026/08/02" "$EXTERNAL_DIR"
ln -s "$SHARED_DIR/sessions" "$HOME_DIR/sessions"
printf '{"id":"%s","thread_name":"Cold storage test"}\n' "$THREAD_ID" > "$SHARED_DIR/session_index.jsonl"
ln -s "$SHARED_DIR/session_index.jsonl" "$HOME_DIR/session_index.jsonl"
ROLLOUT="$SHARED_DIR/sessions/2026/08/02/rollout-$THREAD_ID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s"}}\n{"type":"event_msg","payload":{"message":"cold storage payload"}}\n' "$THREAD_ID" > "$ROLLOUT"
ROLLOUT_HASH="$(shasum -a 256 "$ROLLOUT" | awk '{print $1}')"

python3 - "$HOME_DIR" "$ROLLOUT" "$THREAD_ID" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
rollout = sys.argv[2]
thread_id = sys.argv[3]
con = sqlite3.connect(home / "state_5.sqlite")
con.execute(
    "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, preview TEXT, rollout_path TEXT, archived INTEGER, cwd TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, model_provider TEXT, model TEXT)"
)
con.execute(
    "INSERT INTO threads VALUES (?, ?, ?, ?, 0, ?, 1, 2, 2, ?, ?)",
    (thread_id, "Cold storage test", "Cold storage test", rollout, str(home), "openai", "gpt-test"),
)
con.commit()
con.close()
(home / ".codex-global-state.json").write_text(
    json.dumps({"sidebar-thread-metadata": {thread_id: {"thread_name": "Cold storage test"}}, "projectless-thread-ids": [thread_id]}) + "\n",
    encoding="utf-8",
)
PY

python3 "$HELPER" cold-archive \
  --account-name account1 \
  --account-home "$HOME_DIR" \
  --thread-id "$THREAD_ID" \
  --archive-root "$EXTERNAL_DIR" \
  --index "$INDEX_FILE" \
  --target "account1=$HOME_DIR" \
  --compression-level 1 \
  --max-attachment-bytes 0 >/dev/null

[[ ! -e "$ROLLOUT" ]]
[[ -L "$HOME_DIR/sessions" ]]
[[ -L "$HOME_DIR/session_index.jsonl" ]]
[[ "$(python3 - "$HOME_DIR/state_5.sqlite" "$THREAD_ID" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute("SELECT archived, rollout_path FROM threads WHERE id = ?", (sys.argv[2],)).fetchone()
print(f"{row[0]}|{row[1]}")
PY
)" == "1|" ]]
! grep -q "$THREAD_ID" "$SHARED_DIR/session_index.jsonl"

COLD_LIST="$(python3 "$HELPER" cold-list --index "$INDEX_FILE")"
[[ "$COLD_LIST" == *$THREAD_ID* ]]
PACKAGE_PATH="$(printf '%s\n' "$COLD_LIST" | awk -F '\t' 'NR == 1 {print $7}')"
[[ -f "$PACKAGE_PATH" ]]

python3 "$HELPER" cold-restore \
  --thread-id "$THREAD_ID" \
  --index "$INDEX_FILE" \
  --target "account1=$HOME_DIR" >/dev/null

[[ -f "$ROLLOUT" ]]
[[ "$(shasum -a 256 "$ROLLOUT" | awk '{print $1}')" == "$ROLLOUT_HASH" ]]
[[ -L "$HOME_DIR/sessions" ]]
[[ -L "$HOME_DIR/session_index.jsonl" ]]
grep -q "$THREAD_ID" "$SHARED_DIR/session_index.jsonl"
RESTORED_STATE="$(python3 - "$HOME_DIR/state_5.sqlite" "$THREAD_ID" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute("SELECT archived, rollout_path FROM threads WHERE id = ?", (sys.argv[2],)).fetchone()
print(f"{row[0]}|{row[1]}")
PY
)"
[[ "${RESTORED_STATE%%|*}" == "0" ]]
RESTORED_ROLLOUT="${RESTORED_STATE#*|}"
[[ -f "$RESTORED_ROLLOUT" ]]
[[ "$(realpath "$RESTORED_ROLLOUT")" == "$(realpath "$ROLLOUT")" ]]
[[ -f "$PACKAGE_PATH" ]]
[[ -z "$(python3 "$HELPER" cold-list --index "$INDEX_FILE")" ]]

echo "Codex cold storage isolated checks passed"
