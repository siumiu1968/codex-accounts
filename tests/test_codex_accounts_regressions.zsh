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

python3 - "$PROFILE_HOME" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
(home / "config.toml").write_text(
    'model = "qwen3.7-plus"\nmodel_provider = "openai"\n\n[features]\nmemories = true\n',
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
      model TEXT
    );
    INSERT INTO threads VALUES ('keep', 0, 'vscode', 'user', 'openai', 'gpt-5.6-luna');
    INSERT INTO threads VALUES ('legacy', 0, 'vscode', 'user', 'ai_proxy', 'qwen3.7-plus');
    INSERT INTO threads VALUES ('archived', 1, 'vscode', 'user', 'ai_proxy', 'qwen3.7-plus');
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

python3 - "$PROFILE_HOME" "$HELPER" "$SWIFT_SOURCE" <<'PY'
import re
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
helper = Path(sys.argv[2]).read_text(encoding="utf-8")
swift = Path(sys.argv[3]).read_text(encoding="utf-8")
config = (home / "config.toml").read_text(encoding="utf-8")

assert 'model = "gpt-5.6-terra"' in config
assert 'model_provider = "openai"' in config

con = sqlite3.connect(home / "state_5.sqlite")
rows = dict(con.execute("SELECT id, model_provider || '|' || model FROM threads"))
triggers = {
    row[0]
    for row in con.execute(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'codex_accounts_openai_thread_provider_%'"
    )
}
con.close()

assert rows["keep"] == "openai|gpt-5.6-luna"
assert rows["legacy"] == "openai|gpt-5.6-terra"
assert rows["archived"] == "ai_proxy|qwen3.7-plus"
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

assert "syncBeforeLaunch: Bool = true" in swift
assert 'let launchCommand = syncBeforeLaunch ? "launch-account" : "launch-account-nosync"' in swift
assert "startSidebarPruneLoop()" not in swift
assert "if silent {\n            lastAutoSyncAt = Date()" in swift
PY

echo "✅ Codex Accounts regression checks passed"
