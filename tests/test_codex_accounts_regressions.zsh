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
assert 'Never reuse an invalid-login marker as a new verdict' in helper
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
assert helper.count('$CODEX_APP/Contents/MacOS/ChatGPT') >= 2

assert "syncBeforeLaunch: Bool = true" in swift
assert 'let launchCommand = syncBeforeLaunch ? "launch-account" : "launch-account-nosync"' in swift
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
assert 'command.contains("/Applications/Codex.app/Contents/MacOS/ChatGPT")' in usage_reconcile_match.group(1)
assert 'command.contains("/Applications/Codex.app/Contents/MacOS/Codex")' in usage_reconcile_match.group(1)
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
assert 'Only the current account-status probe may confirm an invalid login' in swift
assert '"version":"2.5.5"' in helper

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
{"auth_mode":"chatgpt","tokens":{"access_token":"test","refresh_token":"test"}}
JSON
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
[[ "$marker_status" == *" | signed_in_local |"* ]]
[[ "$marker_status" != *" | auth_invalid |"* ]]
[[ ! -e "$QUOTA_CACHE" ]]

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/CodexAccounts/Info.plist")" == "2.5.5" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/macos/CodexAccounts/Info.plist")" == "50" ]]

echo "✅ Codex Accounts regression checks passed"
