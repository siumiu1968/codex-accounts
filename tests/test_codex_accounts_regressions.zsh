#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
HELPER="$ROOT/scripts/codex_multi_account.zsh"
SWIFT_SOURCE="$ROOT/macos/CodexAccounts/Sources/CodexAccounts.swift"
TMP_ROOT="$(mktemp -d /tmp/codex-accounts-regression.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PRIMARY_HOME="$TMP_ROOT/primary"
PROFILE_HOME="$TMP_ROOT/profile"
mkdir -p "$PRIMARY_HOME" "$PROFILE_HOME" "$TMP_ROOT/accounts" "$TMP_ROOT/app-data"
touch "$TMP_ROOT/accounts/.deleted-account2"
export SHARED_HISTORY_ROOT="$TMP_ROOT/shared-history"
export SHARED_MEMORY_DIR="$TMP_ROOT/shared-memory"

make_fake_desktop_app() {
  local app_path="$1"
  local bundle_identifier="$2"
  mkdir -p "$app_path/Contents/MacOS"
  cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_identifier</string>
  <key>CFBundleExecutable</key>
  <string>ChatGPT</string>
</dict>
</plist>
PLIST
  printf '%s\n' '#!/bin/zsh' 'exit 0' > "$app_path/Contents/MacOS/ChatGPT"
  chmod +x "$app_path/Contents/MacOS/ChatGPT"
}

DETECTION_CLASSIC_APPS="$TMP_ROOT/detection-classic-apps"
DETECTION_SYSTEM_APPS="$TMP_ROOT/detection-system-apps"
DETECTION_USER_APPS="$TMP_ROOT/detection-user-apps"
DETECTION_EMPTY_APPS="$TMP_ROOT/detection-empty-apps"
mkdir -p "$DETECTION_CLASSIC_APPS" "$DETECTION_SYSTEM_APPS" "$DETECTION_USER_APPS" "$DETECTION_EMPTY_APPS"

# ChatGPT Classic is a different bundle and must never be mistaken for the
# unified ChatGPT/Codex app merely because its outer bundle is ChatGPT.app.
make_fake_desktop_app "$DETECTION_CLASSIC_APPS/ChatGPT.app" "com.openai.chat"
mkdir -p "$DETECTION_CLASSIC_APPS/ChatGPT.app/Contents/Resources"
printf '%s\n' '#!/bin/zsh' 'exit 0' > "$DETECTION_CLASSIC_APPS/ChatGPT.app/Contents/Resources/codex"
chmod +x "$DETECTION_CLASSIC_APPS/ChatGPT.app/Contents/Resources/codex"
classic_detection_output="$(
  CODEX_APP='' \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_CLASSIC_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  "$HELPER" codex-app-path 2>&1 || true
)"
[[ "$classic_detection_output" == *"Compatible Codex/ChatGPT app not found."* ]]
[[ "$classic_detection_output" == *"ChatGPT Classic is installed"* ]]
classic_override_output="$(
  CODEX_APP="$DETECTION_CLASSIC_APPS/ChatGPT.app" \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  "$HELPER" codex-app-path 2>&1 || true
)"
[[ "$classic_override_output" == *"Compatible Codex/ChatGPT app not found."* ]]
[[ "$classic_override_output" == *"ChatGPT Classic is installed"* ]]

# A clean install can use ChatGPT.app while keeping the Codex bundle identity.
make_fake_desktop_app "$DETECTION_SYSTEM_APPS/ChatGPT.app" "com.openai.codex"
[[ "$(
  CODEX_APP='' \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_SYSTEM_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_USER_APPS" \
  "$HELPER" codex-app-path
)" == "$DETECTION_SYSTEM_APPS/ChatGPT.app" ]]

# Preserve the existing Codex.app path when both compatible outer names exist.
make_fake_desktop_app "$DETECTION_SYSTEM_APPS/Codex.app" "com.openai.codex"
[[ "$(
  CODEX_APP='' \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_SYSTEM_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_USER_APPS" \
  "$HELPER" codex-app-path
)" == "$DETECTION_SYSTEM_APPS/Codex.app" ]]

# User-local Applications is a supported fallback, while an explicit override
# remains authoritative for development and non-standard installations.
make_fake_desktop_app "$DETECTION_USER_APPS/ChatGPT.app" "com.openai.codex"
[[ "$(
  CODEX_APP='' \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_USER_APPS" \
  "$HELPER" codex-app-path
)" == "$DETECTION_USER_APPS/ChatGPT.app" ]]
make_fake_desktop_app "$TMP_ROOT/CustomDesktop.app" "example.custom.desktop"
[[ "$(
  CODEX_APP="$TMP_ROOT/CustomDesktop.app" \
  CODEX_SYSTEM_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  CODEX_USER_APPLICATIONS_DIR="$DETECTION_EMPTY_APPS" \
  "$HELPER" codex-app-path
)" == "$TMP_ROOT/CustomDesktop.app" ]]

python3 - "$PROFILE_HOME" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
(home / "config.toml").write_text(
    'model = "qwen3.7-plus"\nmodel_provider = "openai"\nmodel_reasoning_effort = "xhigh"\n\n[features]\nmemories = true\n',
    encoding="utf-8",
)
(home / "models_cache.json").write_text(
    json.dumps(
        {
            "models": [
                {"slug": "gpt-5.6-terra", "visibility": "list", "priority": 2},
                {"slug": "gpt-5.5", "visibility": "list", "priority": 7},
                {"slug": "codex-auto-review", "visibility": "hide", "priority": 43},
            ]
        }
    ),
    encoding="utf-8",
)

con = sqlite3.connect(home / "state_5.sqlite")
con.executescript(
    """
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      archived INTEGER NOT NULL DEFAULT 0,
      source TEXT,
      thread_source TEXT,
      model_provider TEXT,
      model TEXT,
      reasoning_effort TEXT
    );
    INSERT INTO threads VALUES ('keep', 0, 'vscode', 'user', 'openai', 'gpt-5.6-luna', 'medium');
    INSERT INTO threads VALUES ('legacy', 0, 'vscode', 'user', 'ai_proxy', 'qwen3.7-plus', 'high');
    INSERT INTO threads VALUES ('old-default', 0, 'vscode', 'user', 'openai', 'gpt-5.5', 'medium');
    INSERT INTO threads VALUES ('archived', 1, 'vscode', 'user', 'ai_proxy', 'qwen3.7-plus', 'high');
    CREATE TRIGGER codex_accounts_openai_thread_provider_ai
    AFTER INSERT ON threads
    BEGIN
      UPDATE threads SET model_provider = 'openai', model = 'gpt-5.5' WHERE id = NEW.id;
    END;
    CREATE TRIGGER codex_accounts_openai_thread_provider_au
    AFTER UPDATE OF model_provider, model ON threads
    BEGIN
      SELECT 1;
    END;
    """
)
con.commit()
con.close()
PY

PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" restore-openai-config-home "$PROFILE_HOME"

PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" restore-thread-models-home "$PROFILE_HOME" no-backup

# Private history is a persisted per-profile boundary. Exercise the real helper
# against only temporary roots: a hostile inherited shared-history environment
# must not re-link it during launch preparation, synchronization, or link-all.
PRIVATE_HISTORY_NAME="private-history"
SHARED_HISTORY_NAME="shared-history"
FAILED_HISTORY_NAME="failed-history"
CATALOG_ONLY_HISTORY_NAME="catalog-only-history"
ROLLBACK_HISTORY_NAME="rollback-history"
PRIVATE_HISTORY_HOME="$TMP_ROOT/accounts/$PRIVATE_HISTORY_NAME"
SHARED_HISTORY_HOME="$TMP_ROOT/accounts/$SHARED_HISTORY_NAME"
FAILED_HISTORY_HOME="$TMP_ROOT/accounts/$FAILED_HISTORY_NAME"
CATALOG_ONLY_HISTORY_HOME="$TMP_ROOT/accounts/$CATALOG_ONLY_HISTORY_NAME"
ROLLBACK_HISTORY_HOME="$TMP_ROOT/accounts/$ROLLBACK_HISTORY_NAME"

PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
CODEX_SHARED_SESSIONS=1 \
"$HELPER" init-account "$PRIVATE_HISTORY_NAME" >/dev/null

[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$PRIVATE_HISTORY_NAME")" == "private" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/session_index.jsonl" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/sessions" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/shell_snapshots" ]]
printf 'PRIVATE-ONLY\n' > "$PRIVATE_HISTORY_HOME/session_index.jsonl"
printf 'PRIVATE-ONLY\n' > "$PRIVATE_HISTORY_HOME/sessions/private-thread.jsonl"
mkdir -p "$PRIMARY_HOME/memories" "$PRIVATE_HISTORY_HOME/memories"
printf 'SHARED-MEMORY\n' > "$PRIMARY_HOME/memories/shared-memory.txt"
printf 'PRIVATE-MEMORY\n' > "$PRIVATE_HISTORY_HOME/memories/private-memory.txt"

mkdir -p "$SHARED_HISTORY_HOME"
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" link-history "$SHARED_HISTORY_NAME" >/dev/null
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$SHARED_HISTORY_NAME")" == "shared" ]]

# A failed private transition must restore the shared links and leave memories
# untouched; the test hook models a metadata cleanup failure without touching
# a real Codex database.
mkdir -p "$FAILED_HISTORY_HOME/memories"
printf 'keep until success\n' > "$FAILED_HISTORY_HOME/memories/keep.txt"
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" link-history "$FAILED_HISTORY_NAME" >/dev/null
if PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_PRIVATE_HISTORY_CLEANUP_FORCE_FAIL=1 \
  "$HELPER" separate-history "$FAILED_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Forced private history cleanup failure unexpectedly succeeded." >&2
  exit 1
fi
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$FAILED_HISTORY_NAME")" == "shared" ]]
[[ -L "$FAILED_HISTORY_HOME/session_index.jsonl" ]]
[[ -L "$FAILED_HISTORY_HOME/sessions" ]]
[[ -L "$FAILED_HISTORY_HOME/shell_snapshots" ]]
[[ -e "$FAILED_HISTORY_HOME/memories/keep.txt" ]]

# A late memories quarantine failure must roll back the already-cleaned local
# metadata and keep the profile shared instead of reporting a false success.
if PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_PRIVATE_HISTORY_QUARANTINE_FORCE_FAIL=1 \
  "$HELPER" separate-history "$FAILED_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Forced private memory quarantine failure unexpectedly succeeded." >&2
  exit 1
fi
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$FAILED_HISTORY_NAME")" == "shared" ]]
[[ -L "$FAILED_HISTORY_HOME/session_index.jsonl" ]]
[[ -L "$FAILED_HISTORY_HOME/sessions" ]]
[[ -L "$FAILED_HISTORY_HOME/shell_snapshots" ]]
[[ -e "$FAILED_HISTORY_HOME/memories/keep.txt" ]]

# If SQLite cannot make a consistent online snapshot, abort before detaching.
mkdir -p "$FAILED_HISTORY_HOME/sqlite"
printf 'not a sqlite database\n' > "$FAILED_HISTORY_HOME/sqlite/codex-dev.db"
if PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  "$HELPER" separate-history "$FAILED_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Invalid SQLite snapshot unexpectedly allowed a private transition." >&2
  exit 1
fi
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$FAILED_HISTORY_NAME")" == "shared" ]]
[[ -L "$FAILED_HISTORY_HOME/session_index.jsonl" ]]
[[ -L "$FAILED_HISTORY_HOME/sessions" ]]
[[ -L "$FAILED_HISTORY_HOME/shell_snapshots" ]]
[[ -e "$FAILED_HISTORY_HOME/memories/keep.txt" ]]
rm -f "$FAILED_HISTORY_HOME/sqlite/codex-dev.db"

# A live lock with no waits must reject the transition before it changes mode,
# links, or memories.
LOCK_DIR="$TMP_ROOT/private-history-mode.lock"
mkdir -p "$LOCK_DIR"
sleep 5 &
LOCK_PID=$!
printf '%s\n' "$LOCK_PID" > "$LOCK_DIR/pid"
printf '%s\n' 'private-history-test' > "$LOCK_DIR/command"
if PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  SYNC_LOCK_DIR="$LOCK_DIR" \
  CODEX_HISTORY_MODE_LOCK_MAX_WAITS=0 \
  CODEX_SYNC_STALE_LOCK_SECONDS=9999 \
  "$HELPER" separate-history "$FAILED_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Private history lock timeout unexpectedly succeeded." >&2
  kill "$LOCK_PID" 2>/dev/null || true
  exit 1
fi
kill "$LOCK_PID" 2>/dev/null || true
wait "$LOCK_PID" 2>/dev/null || true
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$FAILED_HISTORY_NAME")" == "shared" ]]
[[ -L "$FAILED_HISTORY_HOME/session_index.jsonl" ]]
[[ -L "$FAILED_HISTORY_HOME/sessions" ]]
[[ -L "$FAILED_HISTORY_HOME/shell_snapshots" ]]
[[ -e "$FAILED_HISTORY_HOME/memories/keep.txt" ]]

# A profile can have only a local catalog/session index (for example when its
# state database was reset). Those IDs still have to be captured and removed
# before this profile becomes private.
mkdir -p "$CATALOG_ONLY_HISTORY_HOME/sqlite" "$SHARED_HISTORY_ROOT/sessions"
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" link-history "$CATALOG_ONLY_HISTORY_NAME" >/dev/null
printf '{"id":"catalog-only-thread","title":"shared catalog only"}\n' > "$SHARED_HISTORY_ROOT/session_index.jsonl"
printf 'catalog-only source\n' > "$SHARED_HISTORY_ROOT/sessions/catalog-only-thread.jsonl"
python3 - "$CATALOG_ONLY_HISTORY_HOME" <<'PY'
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
assert not (home / "state_5.sqlite").exists()
catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
catalog.execute("CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT, source_created_at REAL, source_updated_at REAL, cwd TEXT, source_kind TEXT, source_detail TEXT, model_provider TEXT, git_branch TEXT, observation_sequence INTEGER, missing_candidate INTEGER)")
catalog.execute("INSERT INTO local_thread_catalog VALUES ('local', 'catalog-only-thread', 'shared catalog only', 0, 0, '', 'vscode', '', '', '', 0, 0)")
catalog.commit()
catalog.close()
PY
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" separate-history "$CATALOG_ONLY_HISTORY_NAME" >/dev/null
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$CATALOG_ONLY_HISTORY_NAME")" == "private" ]]
[[ ! -e "$CATALOG_ONLY_HISTORY_HOME/state_5.sqlite" ]]
[[ ! -L "$CATALOG_ONLY_HISTORY_HOME/session_index.jsonl" ]]
[[ "$(cat "$CATALOG_ONLY_HISTORY_HOME/session_index.jsonl")" != *"catalog-only-thread"* ]]
python3 - "$CATALOG_ONLY_HISTORY_HOME" "$SHARED_HISTORY_ROOT" <<'PY'
import sqlite3
import sys
from pathlib import Path

home, shared = map(Path, sys.argv[1:])
catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
assert catalog.execute("SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='catalog-only-thread'").fetchone()[0] == 0
catalog.close()
assert (shared / "sessions" / "catalog-only-thread.jsonl").exists()
PY
mkdir -p "$SHARED_HISTORY_ROOT/sessions" "$SHARED_HISTORY_HOME/memories" "$SHARED_HISTORY_HOME/sqlite"
printf 'shared rollout\n' > "$SHARED_HISTORY_ROOT/sessions/shared-thread.jsonl"
printf 'direct shared rollout\n' > "$SHARED_HISTORY_ROOT/sessions/direct-shared-thread.jsonl"
printf 'synchronized summary\n' > "$SHARED_HISTORY_HOME/memories/shared-era.txt"
python3 - "$SHARED_HISTORY_HOME" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
rollout = home / "sessions" / "shared-thread.jsonl"
direct_rollout = home.parent.parent / "shared-history" / "sessions" / "direct-shared-thread.jsonl"
con = sqlite3.connect(home / "state_5.sqlite")
con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER DEFAULT 0)")
con.execute("INSERT INTO threads VALUES (?, ?, 0)", ("shared-thread", str(rollout)))
con.execute("INSERT INTO threads VALUES (?, ?, 0)", ("direct-shared-thread", str(direct_rollout)))
con.commit()
con.close()

catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
catalog.execute(
    "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT, source_created_at REAL, source_updated_at REAL, cwd TEXT, source_kind TEXT, source_detail TEXT, model_provider TEXT, git_branch TEXT, observation_sequence INTEGER, missing_candidate INTEGER)"
)
catalog.execute(
    "INSERT INTO local_thread_catalog VALUES (?, ?, ?, 0, 0, '', 'vscode', '', '', '', 0, 0)",
    ("local", "shared-thread", "shared title"),
)
catalog.execute(
    "INSERT INTO local_thread_catalog VALUES (?, ?, ?, 0, 0, '', 'vscode', '', '', '', 0, 0)",
    ("local", "direct-shared-thread", "direct shared title"),
)
catalog.execute("CREATE TABLE local_thread_catalog_metadata (id INTEGER PRIMARY KEY, catalog_revision INTEGER)")
catalog.execute("INSERT INTO local_thread_catalog_metadata VALUES (1, 0)")
catalog.commit()
catalog.close()

(home / ".codex-global-state.json").write_text(
    json.dumps({
        "pinned-thread-ids": ["shared-thread", "direct-shared-thread"],
        "projectless-thread-ids": ["shared-thread", "direct-shared-thread"],
        "thread-projectless-output-directories": {"shared-thread": "/tmp", "direct-shared-thread": "/tmp"},
    }),
    encoding="utf-8",
)
PY
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" separate-history "$SHARED_HISTORY_NAME" >/dev/null
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$SHARED_HISTORY_NAME")" == "private" ]]
[[ ! -L "$SHARED_HISTORY_HOME/session_index.jsonl" ]]
[[ ! -L "$SHARED_HISTORY_HOME/sessions" ]]
[[ ! -L "$SHARED_HISTORY_HOME/shell_snapshots" ]]
python3 - "$SHARED_HISTORY_HOME" "$SHARED_HISTORY_ROOT" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
shared_root = Path(sys.argv[2])
con = sqlite3.connect(home / "state_5.sqlite")
assert con.execute("SELECT COUNT(*) FROM threads WHERE id='shared-thread'").fetchone()[0] == 0
assert con.execute("SELECT COUNT(*) FROM threads WHERE id='direct-shared-thread'").fetchone()[0] == 0
con.close()
catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
assert catalog.execute("SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='shared-thread'").fetchone()[0] == 0
assert catalog.execute("SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='direct-shared-thread'").fetchone()[0] == 0
catalog.close()
state = json.loads((home / ".codex-global-state.json").read_text(encoding="utf-8"))
assert "shared-thread" not in state.get("pinned-thread-ids", [])
assert "shared-thread" not in state.get("projectless-thread-ids", [])
assert "shared-thread" not in state.get("thread-projectless-output-directories", {})
assert "direct-shared-thread" not in state.get("pinned-thread-ids", [])
assert "direct-shared-thread" not in state.get("projectless-thread-ids", [])
assert "direct-shared-thread" not in state.get("thread-projectless-output-directories", {})
assert (shared_root / "sessions" / "shared-thread.jsonl").exists()
assert (shared_root / "sessions" / "direct-shared-thread.jsonl").exists()
assert not (home / "memories" / "shared-era.txt").exists()
assert any((home / "backups").glob("history-private-*/memories/shared-era.txt"))
PY

# If cleanup/pruning completed but a later transition step fails, restore the
# exact metadata snapshot before re-attaching the shared history links.
mkdir -p "$ROLLBACK_HISTORY_HOME/memories" "$ROLLBACK_HISTORY_HOME/sqlite" "$SHARED_HISTORY_ROOT/sessions"
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" link-history "$ROLLBACK_HISTORY_NAME" >/dev/null
printf 'rollback source\n' > "$SHARED_HISTORY_ROOT/sessions/rollback-thread.jsonl"
printf '{"id":"rollback-thread","title":"rollback shared"}\n' > "$SHARED_HISTORY_ROOT/session_index.jsonl"
printf 'retain memory through rollback\n' > "$ROLLBACK_HISTORY_HOME/memories/retain.txt"
python3 - "$ROLLBACK_HISTORY_HOME" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
rollout = home / "sessions" / "rollback-thread.jsonl"
state = sqlite3.connect(home / "state_5.sqlite")
state.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER DEFAULT 0)")
state.execute("INSERT INTO threads VALUES (?, ?, 0)", ("rollback-thread", str(rollout)))
state.commit()
state.close()
catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
catalog.execute("CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, display_title TEXT, source_created_at REAL, source_updated_at REAL, cwd TEXT, source_kind TEXT, source_detail TEXT, model_provider TEXT, git_branch TEXT, observation_sequence INTEGER, missing_candidate INTEGER)")
catalog.execute("INSERT INTO local_thread_catalog VALUES ('local', 'rollback-thread', 'rollback title', 0, 0, '', 'vscode', '', '', '', 0, 0)")
catalog.commit()
catalog.close()
(home / ".codex-global-state.json").write_text(json.dumps({
    "pinned-thread-ids": ["rollback-thread"],
    "projectless-thread-ids": ["rollback-thread"],
    "thread-projectless-output-directories": {"rollback-thread": "/tmp"},
}), encoding="utf-8")
PY
if PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_PRIVATE_HISTORY_POST_CLEANUP_FORCE_FAIL=1 \
  "$HELPER" separate-history "$ROLLBACK_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Post-cleanup private history failure unexpectedly succeeded." >&2
  exit 1
fi
[[ "$(PRIMARY_CODEX_HOME="$PRIMARY_HOME" ACCOUNTS_ROOT="$TMP_ROOT/accounts" APP_DATA_ROOT="$TMP_ROOT/app-data" "$HELPER" history-mode "$ROLLBACK_HISTORY_NAME")" == "shared" ]]
[[ -L "$ROLLBACK_HISTORY_HOME/session_index.jsonl" ]]
[[ -L "$ROLLBACK_HISTORY_HOME/sessions" ]]
[[ -L "$ROLLBACK_HISTORY_HOME/shell_snapshots" ]]
[[ -e "$ROLLBACK_HISTORY_HOME/memories/retain.txt" ]]
python3 - "$ROLLBACK_HISTORY_HOME" "$SHARED_HISTORY_ROOT" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home, shared = map(Path, sys.argv[1:])
state = sqlite3.connect(home / "state_5.sqlite")
assert state.execute("SELECT rollout_path FROM threads WHERE id='rollback-thread'").fetchone()[0] == str(home / "sessions" / "rollback-thread.jsonl")
state.close()
catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
assert catalog.execute("SELECT display_title FROM local_thread_catalog WHERE thread_id='rollback-thread'").fetchone()[0] == "rollback title"
catalog.close()
global_state = json.loads((home / ".codex-global-state.json").read_text(encoding="utf-8"))
assert global_state["pinned-thread-ids"] == ["rollback-thread"]
assert global_state["projectless-thread-ids"] == ["rollback-thread"]
assert global_state["thread-projectless-output-directories"] == {"rollback-thread": "/tmp"}
assert (shared / "sessions" / "rollback-thread.jsonl").exists()
PY

MOCK_OPEN_BIN="$TMP_ROOT/mock-open-bin"
mkdir -p "$MOCK_OPEN_BIN" "$TMP_ROOT/FakeCodex.app"
printf '%s\n' '#!/bin/zsh' 'exit 0' > "$MOCK_OPEN_BIN/open"
chmod +x "$MOCK_OPEN_BIN/open"
if PATH="$MOCK_OPEN_BIN:$PATH" \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_APP="$TMP_ROOT/FakeCodex.app" \
  CODEX_PRELAUNCH_SYNC=0 \
  CODEX_SHARED_SESSIONS=1 \
  CODEX_SYNC_THREAD_HISTORY=1 \
  CODEX_LAUNCH_VERIFY_MAX_WAITS=0 \
  "$HELPER" launch-account-nosync "$PRIVATE_HISTORY_NAME" >/dev/null 2>&1; then
  echo "Private launch test unexpectedly reported a running fake Codex process." >&2
  exit 1
fi
[[ ! -L "$PRIVATE_HISTORY_HOME/session_index.jsonl" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/sessions" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/shell_snapshots" ]]
[[ "$(cat "$PRIVATE_HISTORY_HOME/session_index.jsonl")" == "PRIVATE-ONLY" ]]

PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
CODEX_SYNC_THREAD_HISTORY=1 \
"$HELPER" sync-history-once >/dev/null
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
CODEX_SYNC_THREAD_HISTORY=1 \
"$HELPER" sync-once >/dev/null
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
CODEX_SYNC_THREAD_HISTORY=1 \
"$HELPER" sync-account-for-launch "$PRIVATE_HISTORY_NAME" >/dev/null
PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
APP_DATA_ROOT="$TMP_ROOT/app-data" \
"$HELPER" link-all-history >/dev/null
[[ ! -L "$PRIVATE_HISTORY_HOME/session_index.jsonl" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/sessions" ]]
[[ ! -L "$PRIVATE_HISTORY_HOME/shell_snapshots" ]]
[[ "$(cat "$PRIVATE_HISTORY_HOME/session_index.jsonl")" == "PRIVATE-ONLY" ]]
[[ ! -e "$SHARED_HISTORY_ROOT/sessions/private-thread.jsonl" ]]
[[ ! -e "$SHARED_MEMORY_DIR/memories/private-memory.txt" ]]
[[ ! -e "$PRIVATE_HISTORY_HOME/memories/shared-memory.txt" ]]

python3 - "$PROFILE_HOME" "$HELPER" "$SWIFT_SOURCE" <<'PY'
import re
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
helper = Path(sys.argv[2]).read_text(encoding="utf-8")
swift = Path(sys.argv[3]).read_text(encoding="utf-8")
config = (home / "config.toml").read_text(encoding="utf-8")

assert 'model = "gpt-5.6-sol"' in config
assert 'model_provider = "openai"' in config
assert 'model_reasoning_effort = "xhigh"' in config

con = sqlite3.connect(home / "state_5.sqlite")
rows = dict(con.execute("SELECT id, model_provider || '|' || model || '|' || reasoning_effort FROM threads"))
triggers = {
    row[0]
    for row in con.execute(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'codex_accounts_openai_thread_provider_%'"
    )
}
con.close()

assert rows["keep"] == "openai|gpt-5.6-luna|medium"
assert rows["legacy"] == "openai|gpt-5.6-sol|xhigh"
assert rows["old-default"] == "openai|gpt-5.6-sol|xhigh"
assert rows["archived"] == "ai_proxy|qwen3.7-plus|high"
assert not triggers

sync_match = re.search(
    r"sync_history_selected_homes\(\) \{(.*?)\n\}",
    helper,
    flags=re.DOTALL,
)
assert sync_match
assert "CODEX_SKIP_ACTIVE_STATE_DB_WRITES=0" not in sync_match.group(1)
assert "post_launch_thread_index_repair_for_home" not in helper
assert 'model = "gpt-5.5"' not in helper
assert 'CODEX_PRUNE_GLOBAL_STATE_ON_SYNC="${CODEX_PRUNE_GLOBAL_STATE_ON_SYNC:-0}"' in helper
assert 'CODEX_USAGE_LIVE_MIN_PARALLELISM="${CODEX_USAGE_LIVE_MIN_PARALLELISM:-10}"' in helper
assert 'Keep that verdict until a later live probe' in helper
assert 'if [[ "$CODEX_USAGE_LIVE_LOOKUP" != "1" ]]; then' in helper
assert 'status_parallelism="$live_min_parallelism"' in helper
assert 'merge_reset_credits_detail_into_raw_summary "$auth_file" "$raw_summary" "$cache_file"' in helper
assert 'CODEX_HISTORY_ANCHOR_FILE="${CODEX_HISTORY_ANCHOR_FILE:-$APP_DATA_ROOT/history-anchor-home}"' in helper
assert 'CODEX_HISTORY_ANCHOR_HOME="${CODEX_HISTORY_ANCHOR_HOME:-$PRIMARY_CODEX_HOME}"' in helper
assert not re.search(
    r'CODEX_HISTORY_ANCHOR_HOME="\$\{CODEX_HISTORY_ANCHOR_HOME:-\$ACCOUNTS_ROOT/[0-9]+\}"',
    helper,
)

forbidden_403 = re.search(
    r'if \[\[ "\$http_status" == "403" \]\]; then(.*?)\n  fi\n\n  if \[\[ "\$http_status" == "401"',
    helper,
    flags=re.DOTALL,
)
assert forbidden_403
assert "write_auth_invalid_usage_marker" not in forbidden_403.group(1)
assert "does not prove that the local Codex login is invalid" in forbidden_403.group(1)
assert re.search(
    r'"\$codex_bin" -c \'mcp_servers=\{\}\' -c \'plugins=\{\}\' app-server --listen stdio://',
    helper,
)
assert 'secure_auth_file_permissions() {' in helper
assert '--data-binary @-' in helper
assert '--data "$refresh_body"' not in helper
assert '--arg refresh_token' not in helper
assert '-H "Authorization: Bearer $token"' not in helper
assert '--header "@$header_file"' in helper
assert 'tmp_auth="$(mktemp "${auth_file}.tmp.XXXXXX")"' in helper
assert helper.count('chmod 600 "$auth_file"') >= 2
assert 'local max_attempts=2' in helper

global_sync_match = re.search(
    r"sync_global_state_for_homes\(\) \{(.*?)\n\}",
    helper,
    flags=re.DOTALL,
)
assert global_sync_match
assert "active_sqlite_homes_payload" in global_sync_match.group(1)
assert 'CODEX_ACTIVE_DB_HOMES="$active_home_payload"' in global_sync_match.group(1)
assert "str(home) in active_home_keys" in global_sync_match.group(1)

launch_match = re.search(r"launch_account\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert launch_match
assert 'prune_global_state_for_home "$home_dir"' not in launch_match.group(1)
assert 'CODEX_INJECT_PROXY_ENV="${CODEX_INJECT_PROXY_ENV:-auto}"' in helper
assert 'proxy_injection_enabled() {' in helper
assert 'if proxy_injection_enabled; then' in launch_match.group(1)
assert 'launch_args+=(--proxy-server="$CODEX_PROXY_URL")' in launch_match.group(1)
assert '--args "${launch_args[@]}"' in launch_match.group(1)
assert 'CODEX_APP_CANDIDATES=(' in helper
assert '"$CODEX_SYSTEM_APPLICATIONS_DIR/Codex.app"' in helper
assert '"$CODEX_SYSTEM_APPLICATIONS_DIR/ChatGPT.app"' in helper
assert '"$CODEX_USER_APPLICATIONS_DIR/Codex.app"' in helper
assert '"$CODEX_USER_APPLICATIONS_DIR/ChatGPT.app"' in helper
assert '[[ "$bundle_identifier" == "com.openai.codex" || -x "$app_path/Contents/Resources/codex" ]]' in helper
assert '[[ "$bundle_identifier" != "com.openai.chat" ]] || return 1' in helper
assert 'ChatGPT Classic is installed, but it cannot open isolated Codex profiles.' in helper
assert helper.count('is_codex_gui_process_args "$args" || continue') == 3
codex_process_match = re.search(r"is_codex_gui_process_args\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert codex_process_match
assert '"$app_path/Contents/MacOS/ChatGPT"' in codex_process_match.group(1)
assert '"$app_path/Contents/MacOS/Codex"' in codex_process_match.group(1)
assert 'CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH="${CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH:-0}"' in helper
assert 'CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH="${CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH:-0}"' in helper
assert helper.count('CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH=1 \\\n    repair_compacted_image_payloads_for_home') >= 2
assert 'prepare_profile_login_storage_for_launch "$home_dir"' in launch_match.group(1)
assert 'history_mode="$(history_mode_for_home "$home_dir")"' in launch_match.group(1)
assert 'CODEX_SHARED_SESSIONS=0' in launch_match.group(1)
assert 'CODEX_SYNC_THREAD_HISTORY=0' in launch_match.group(1)
assert launch_match.group(1).count('stop_codex_windows_for_app_data "$app_data"') == 1
assert launch_match.group(1).count('stop_codex_servers_for_home "$home_dir"') == 1
assert 'wait_for_codex_window_exit "$app_data"' in launch_match.group(1)
assert 'wait_for_codex_window_start "$app_data"' in launch_match.group(1)
assert 'open -na "$CODEX_APP"' in launch_match.group(1)
assert launch_match.group(1).index('wait_for_codex_window_start "$app_data"') > launch_match.group(1).index('open -na "$CODEX_APP"')
heavy_launch_match = re.search(
    r'if \[\[ "\$CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH" == "1" \]\]; then(.*?)\n  fi',
    launch_match.group(1),
    flags=re.DOTALL,
)
assert heavy_launch_match
for heavy_call in (
    'refresh_shared_history_for_home "$home_dir"',
    'repair_compacted_image_payloads_for_home "$home_dir"',
    'cleanup_thread_index_for_home "$home_dir"',
    'normalize_thread_sources_for_home "$home_dir"',
    'restore_default_thread_model_providers_for_home "$home_dir"',
    'restore_account1_visible_thread_model_providers_for_home "$home_dir"',
):
    assert heavy_call in heavy_launch_match.group(1)
    assert launch_match.group(1).count(heavy_call) == 1

link_ready_match = re.search(r"shared_history_links_ready\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert link_ready_match
for item in ("session_index.jsonl", "sessions", "shell_snapshots"):
    assert item in link_ready_match.group(1)
assert "seed_shared_history_from_home" not in link_ready_match.group(1)
assert "recover_shared_history_backups_from_home" not in link_ready_match.group(1)
assert "rsync" not in link_ready_match.group(1)
transition_match = re.search(r"profile_transition_is_busy\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert transition_match
assert 'profile_window_is_running "$name"' in transition_match.group(1)
assert '"codex app-server"' in transition_match.group(1)
assert 'process_env_contains "$pid" "CODEX_HOME=$home_dir"' in transition_match.group(1)
assert 'active_sqlite_homes_payload "$home_dir"' in transition_match.group(1)
private_transition_match = re.search(r"separate_history_for_unlocked\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert private_transition_match
assert 'profile_transition_is_busy "$name" "$account_home"' in private_transition_match.group(1)
assert 'backup_private_history_transaction_metadata "$account_home" "$transaction_backup_dir"' in private_transition_match.group(1)
assert 'CODEX_PRIVATE_HISTORY_POST_CLEANUP_FORCE_FAIL' in private_transition_match.group(1)
assert 'restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir"' in private_transition_match.group(1)
assert private_transition_match.group(1).index('quarantine_memories_for_private_history') < private_transition_match.group(1).index('set_history_mode_for_home "$account_home" private')
link_history_match = re.search(r"link_history_for_unlocked\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert link_history_match
assert 'profile_transition_is_busy "$name" "$account_home"' in link_history_match.group(1)
restore_transaction_match = re.search(r"restore_private_history_transaction_metadata\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert restore_transaction_match
assert "target.name + '-wal'" in restore_transaction_match.group(1)
assert "target.name + '-shm'" in restore_transaction_match.group(1)
launch_prepare_match = re.search(r"prepare_profile_login_storage_for_launch\(\) \{(.*?)\n\}", helper, flags=re.DOTALL)
assert launch_prepare_match
assert 'shared_history_links_ready "$account_home" && return 0' in launch_prepare_match.group(1)
assert 'prepare_profile_login_storage "$account_home"' in launch_prepare_match.group(1)

assert "syncBeforeLaunch: Bool = false" in swift
assert 'let launchCommand = syncBeforeLaunch ? "launch-account" : "launch-account-nosync"' in swift
assert '.codex-accounts-history-mode' in swift
assert 'Private local chats (this profile only)' in swift
assert 'Share local chats (visible to other profiles)' in swift
assert 'OpenAI cloud processing stays on' in swift
assert 'launchEnvironment["CODEX_SHARED_SESSIONS"] = sharesLocalHistory ? "1" : "0"' in swift
assert 'launchEnvironment["CODEX_SYNC_THREAD_HISTORY"] = syncBeforeLaunch && sharesLocalHistory ? "1" : "0"' in swift
assert 'private let codexAccountsLaunchQueue = DispatchQueue(label: "local.codex.accounts.launch", qos: .userInitiated)' in swift
assert 'queue: DispatchQueue = codexAccountsWorkQueue' in swift
assert 'runBackground(loadingText, queue: codexAccountsLaunchQueue)' in swift
assert 'runBackground(tr("關閉 \\(profile.displayName)...", "Closing \\(profile.displayName)..."), queue: codexAccountsLaunchQueue)' in swift
assert 'busyProfiles.isDisjoint(with: busyIDs)' in swift
assert '.disabled(busyProfiles.contains(profile.id) || isClosingAllAccounts)' in swift
assert 'alertMessage(failureText, detail.isEmpty ? fallback : detail)' in swift
assert 'var arguments = ["launch-account-nosync", routed.name]' in swift
assert '.repeatForever(' not in swift
assert 'environment["CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH"] = "1"' in swift
assert "startSidebarPruneLoop()" not in swift
assert "if silent {\n            lastAutoSyncAt = Date()" in swift
assert "private let liveUsageParallelism = 10" in swift
assert "private let liveUsageStatusTimeout: TimeInterval = 60" in swift
assert 'environment["USAGE_DIRECT_TIMEOUT_SECONDS"] = "6"' in swift
assert 'private struct DailyUsageRecord: Codable' in swift
assert '@AppStorage("codexUsageRecordV2")' in swift
assert 'min(max(date.timeIntervalSince(lastSample), 0), 90)' in swift
assert 'return min(max(record.seconds + liveSeconds, 0), 86_400)' in swift
usage_reconcile_match = re.search(
    r'private func reconcileUsageSession\(\) \{(.*?)\n    \}\n\n    private func currentUsageSeconds',
    swift,
    flags=re.DOTALL,
)
assert usage_reconcile_match
assert 'private func supportedCodexGUIExecutablePaths() -> [String]' in swift
assert '"/Applications/Codex.app"' in swift
assert '"/Applications/ChatGPT.app"' in swift
assert 'bundle?.bundleIdentifier == "com.openai.codex"' in swift
assert 'guard bundle?.bundleIdentifier != "com.openai.chat" else {' in swift
assert 'let codexExecutablePaths = supportedCodexGUIExecutablePaths()' in usage_reconcile_match.group(1)
assert 'codexExecutablePaths.contains { command.contains($0) }' in usage_reconcile_match.group(1)
assert 'command.contains("/Applications/Codex.app/Contents/MacOS/ChatGPT")' not in swift
assert '--user-data-dir=' not in usage_reconcile_match.group(1)
assert 'enum KeepAwakeMode: Int, CaseIterable, Identifiable' in swift
assert 'case clamshell = 2' in swift
assert '/usr/bin/pmset -a disablesleep \\(value)' in swift
assert 'keep-awake-clamshell-owned' in swift
assert 'var ownsSystemSleepOverride: Bool' in swift
assert 'private struct KeepAwakeLevelSlider: View' in swift
assert 'Slider(' in swift
assert 'onEditingChanged:' in swift
assert 'private func finishKeepAwakeTerminationCleanup' in swift
assert 'guard !controller.isSwitching else {' in swift
assert 'guard controller.isSwitching || controller.ownsSystemSleepOverride else {' in swift
assert 'guard controller.ownsSystemSleepOverride else {' in swift
assert '.minimumScaleFactor(0.62)' in swift
assert '.allowsTightening(true)' in swift
assert 'if cachedUsage.quota == "__auth_invalid__" {' in swift
assert 'refreshProfiles(showLoading: true, replayQuota: false, liveUsage: true)' in swift
assert 'private func quotaAuthenticationStatus(_ profile: CodexProfile, compact: Bool) -> some View' in swift
assert 'tr("打開重新登入", "Open to sign in again")' in swift
assert 'private func quotaUnavailableStatus(compact: Bool) -> some View' in swift
assert 'tr("暫時未能取得用量", "Usage is temporarily unavailable")' in swift
assert '"version":"2.6.2"' in helper

theme_match = re.search(
    r'private var themeOptions: \[AppThemeOption\] \{(.*?)\n    \}\n\n    private func canonicalThemeID',
    swift,
    flags=re.DOTALL,
)
assert theme_match
assert theme_match.group(1).count('AppThemeOption(') == 8
for theme_id in ("graphite", "aurora", "amber", "violet", "ocean", "sakura", "forest", "midnight"):
    assert f'id: "{theme_id}"' in theme_match.group(1)
PY

QUOTA_PROFILE="$TMP_ROOT/accounts/quota-test"
QUOTA_CACHE="$TMP_ROOT/app-data/.usage-cache-v8/quota-test.status"
mkdir -p "$QUOTA_PROFILE" "${QUOTA_CACHE:h}"
cat > "$QUOTA_PROFILE/auth.json" <<'JSON'
{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-access-secret","refresh_token":"synthetic-refresh-secret"}}
JSON
chmod 644 "$QUOTA_PROFILE/auth.json"
FUTURE_RESET="$(date -v+1d '+%m/%d %H:%M')"

printf '5h 80%% / 7d 55%%\t5h 23:59 / 7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
touch -t "$(date -v-6H '+%Y%m%d%H%M.%S')" "$QUOTA_CACHE"
expired_status="$(
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=0 \
  "$HELPER" account-status quota-test
)"
[[ "$expired_status" == *" | unknown | unknown | unknown" ]]
[[ ! -e "$QUOTA_CACHE" ]]
[[ "$(stat -f '%Lp' "$QUOTA_PROFILE/auth.json")" == "600" ]]

# Refuse auth.json symlinks rather than following, chmodding, or replacing the
# target. The profile must remain login-needed and both filesystem objects stay
# byte-for-byte/metadata unchanged.
SYMLINK_TARGET="$TMP_ROOT/symlink-auth-target.json"
cat > "$SYMLINK_TARGET" <<'JSON'
{"auth_mode":"chatgpt","tokens":{"access_token":"symlink-access-secret","refresh_token":"symlink-refresh-secret"}}
JSON
chmod 644 "$SYMLINK_TARGET"
SYMLINK_HASH_BEFORE="$(shasum -a 256 "$SYMLINK_TARGET" | awk '{print $1}')"
rm "$QUOTA_PROFILE/auth.json"
ln -s "$SYMLINK_TARGET" "$QUOTA_PROFILE/auth.json"
symlink_status="$(
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$symlink_status" == *" | login_needed |"* ]]
[[ -L "$QUOTA_PROFILE/auth.json" ]]
[[ "$(readlink "$QUOTA_PROFILE/auth.json")" == "$SYMLINK_TARGET" ]]
[[ "$(stat -f '%Lp' "$SYMLINK_TARGET")" == "644" ]]
[[ "$(shasum -a 256 "$SYMLINK_TARGET" | awk '{print $1}')" == "$SYMLINK_HASH_BEFORE" ]]
rm "$QUOTA_PROFILE/auth.json"
cat > "$QUOTA_PROFILE/auth.json" <<'JSON'
{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-access-secret","refresh_token":"synthetic-refresh-secret"}}
JSON
chmod 600 "$QUOTA_PROFILE/auth.json"

printf '7d 55%%\t7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
current_status="$(
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=0 \
  "$HELPER" account-status quota-test
)"
[[ "$current_status" == *" | 7d 55% | 7d $FUTURE_RESET | 0" ]]
[[ -e "$QUOTA_CACHE" ]]

printf '__auth_invalid__\tunknown\tunknown\n' > "$QUOTA_CACHE"
marker_status="$(
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=0 \
  "$HELPER" account-status quota-test
)"
[[ "$marker_status" == *" | auth_invalid |"* ]]
[[ -e "$QUOTA_CACHE" ]]

MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" <<'MOCK_CURL'
#!/bin/zsh
set -euo pipefail

output_file=""
url=""
data_source=""
request_body=""
original_args=("$@")
if [[ -n "${MOCK_CURL_ARGS_LOG:-}" ]]; then
  printf '%s\n' "${(j: :)original_args}" >> "$MOCK_CURL_ARGS_LOG"
fi
while (( $# > 0 )); do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    -H|--header)
      if [[ "$2" == @* ]]; then
        private_header_file="${2#@}"
        [[ -f "$private_header_file" ]]
        [[ "$(stat -f '%Lp' "$private_header_file")" == "600" ]]
        [[ "$(head -n 1 "$private_header_file")" == "Authorization: Bearer "* ]]
        if [[ -n "${MOCK_HEADER_PATH_LOG:-}" ]]; then
          printf '%s\n' "$private_header_file" >> "$MOCK_HEADER_PATH_LOG"
        fi
      fi
      shift 2
      ;;
    --connect-timeout|--max-time|-w)
      shift 2
      ;;
    --data|--data-binary)
      data_source="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [[ "$data_source" == "@-" ]]; then
  request_body="$(cat)"
elif [[ -n "$data_source" ]]; then
  request_body="$data_source"
fi

if [[ "$url" == */oauth/token ]]; then
  [[ "$data_source" == "@-" ]]
  [[ "$request_body" == *'"grant_type":"refresh_token"'* ]]
  case "${MOCK_CURL_MODE:-}" in
    invalid_grant)
      printf '{"error":"invalid_grant"}\n' > "$output_file"
      printf '400'
      ;;
    invalid_refresh_token)
      printf '{"error":"invalid_refresh_token"}\n' > "$output_file"
      printf '401'
      ;;
    refresh_token_reused)
      printf '{"error":"refresh_token_reused"}\n' > "$output_file"
      printf '401'
      ;;
    transient)
      printf '{"error":"temporarily_unavailable"}\n' > "$output_file"
      printf '503'
      ;;
    rotation_success)
      count=0
      if [[ -f "$MOCK_CURL_COUNT_FILE" ]]; then
        count="$(cat "$MOCK_CURL_COUNT_FILE")"
      fi
      count=$(( count + 1 ))
      printf '%s\n' "$count" > "$MOCK_CURL_COUNT_FILE"
      if (( count == 1 )); then
        rotated_tmp="$(mktemp "${MOCK_AUTH_FILE}.race.XXXXXX")"
        chmod 600 "$rotated_tmp"
        jq '.tokens.access_token = "race-access" | .tokens.refresh_token = "race-refresh"' \
          "$MOCK_AUTH_FILE" > "$rotated_tmp"
        chmod 600 "$rotated_tmp"
        mv "$rotated_tmp" "$MOCK_AUTH_FILE"
        printf '{"error":"invalid_refresh_token"}\n' > "$output_file"
        printf '401'
      else
        printf '{"access_token":"fresh-access","refresh_token":"fresh-refresh","id_token":"fresh-id"}\n' > "$output_file"
        printf '200'
      fi
      ;;
    *)
      exit 1
      ;;
  esac
else
  if [[ "${MOCK_CURL_MODE:-}" == "rotation_success" ]] \
      && [[ "$(jq -r '.tokens.access_token // empty' "$MOCK_AUTH_FILE")" == "fresh-access" ]]; then
    printf '{"rate_limit":{"unlimited":false,"primary_window":{"used_percent":12,"reset_at":2000000000,"limit_window_seconds":18000},"secondary_window":null},"rate_limit_reset_credits":{"available_count":0}}\n' > "$output_file"
    printf '200'
  else
    printf '{}\n' > "$output_file"
    printf '401'
  fi
fi
MOCK_CURL
chmod +x "$MOCK_BIN/curl"
ARGV_LOG="$TMP_ROOT/all-curl-argv.log"
HEADER_PATH_LOG="$TMP_ROOT/private-header-paths.log"
export MOCK_CURL_ARGS_LOG="$ARGV_LOG"
export MOCK_HEADER_PATH_LOG="$HEADER_PATH_LOG"

printf '7d 55%%\t7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
invalid_grant_status="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_CURL_MODE=invalid_grant \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$invalid_grant_status" == *" | auth_invalid |"* ]]
[[ "$(head -n 1 "$QUOTA_CACHE")" == $'__auth_invalid__\tunknown\tunknown' ]]

printf '7d 55%%\t7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
invalid_refresh_status="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_CURL_MODE=invalid_refresh_token \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$invalid_refresh_status" == *" | auth_invalid |"* ]]
[[ "$(head -n 1 "$QUOTA_CACHE")" == $'__auth_invalid__\tunknown\tunknown' ]]

printf '7d 55%%\t7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
reused_refresh_status="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_CURL_MODE=refresh_token_reused \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$reused_refresh_status" == *" | auth_invalid |"* ]]
[[ "$(head -n 1 "$QUOTA_CACHE")" == $'__auth_invalid__\tunknown\tunknown' ]]

printf '7d 55%%\t7d %s\t0\n' "$FUTURE_RESET" > "$QUOTA_CACHE"
transient_status="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_CURL_MODE=transient \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$transient_status" == *" | signed_in_local |"* ]]
[[ "$transient_status" == *" | 7d 55% | 7d $FUTURE_RESET | 0"* ]]
[[ "$(head -n 1 "$QUOTA_CACHE")" == $'7d 55%\t7d '"$FUTURE_RESET"$'\t0' ]]

# A concurrent Codex process may rotate the token while an older refresh is in
# flight. Retry the newer token once, do not publish auth_invalid, atomically
# replace the credentials with mode 0600, and clear an older invalid marker.
cat > "$QUOTA_PROFILE/auth.json" <<'JSON'
{"auth_mode":"chatgpt","tokens":{"access_token":"stale-access","refresh_token":"stale-refresh"}}
JSON
chmod 644 "$QUOTA_PROFILE/auth.json"
printf '__auth_invalid__\tunknown\tunknown\n' > "$QUOTA_CACHE"
CURL_COUNT_FILE="$TMP_ROOT/oauth-count"
rotation_status="$(
  PATH="$MOCK_BIN:$PATH" \
  MOCK_CURL_MODE=rotation_success \
  MOCK_CURL_ARGS_LOG="$ARGV_LOG" \
  MOCK_HEADER_PATH_LOG="$HEADER_PATH_LOG" \
  MOCK_CURL_COUNT_FILE="$CURL_COUNT_FILE" \
  MOCK_AUTH_FILE="$QUOTA_PROFILE/auth.json" \
  PRIMARY_CODEX_HOME="$PRIMARY_HOME" \
  ACCOUNTS_ROOT="$TMP_ROOT/accounts" \
  APP_DATA_ROOT="$TMP_ROOT/app-data" \
  CODEX_USAGE_LIVE_LOOKUP=1 \
  CODEX_USAGE_APP_SERVER_FALLBACK=0 \
  "$HELPER" account-status quota-test
)"
[[ "$rotation_status" == *" | signed_in_local |"* ]]
[[ "$rotation_status" == *" | 5h 88% |"* ]]
[[ "$(cat "$CURL_COUNT_FILE")" == "2" ]]
[[ "$(jq -r '.tokens.access_token' "$QUOTA_PROFILE/auth.json")" == "fresh-access" ]]
[[ "$(jq -r '.tokens.refresh_token' "$QUOTA_PROFILE/auth.json")" == "fresh-refresh" ]]
[[ "$(stat -f '%Lp' "$QUOTA_PROFILE/auth.json")" == "600" ]]
[[ "$(head -n 1 "$QUOTA_CACHE")" != $'__auth_invalid__\tunknown\tunknown' ]]
! grep -q 'synthetic-access-secret\|synthetic-refresh-secret\|stale-access\|stale-refresh\|race-access\|race-refresh\|fresh-access\|fresh-refresh\|grant_type' "$ARGV_LOG"
while IFS= read -r private_header_file; do
  [[ ! -e "$private_header_file" ]]
done < "$HEADER_PATH_LOG"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/CodexAccounts/Info.plist")" == "2.6.2" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/macos/CodexAccounts/Info.plist")" == "62" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/macos/CodexAccounts/Info.plist")" == "14.0" ]]

echo "✅ Codex Accounts regression checks passed"
