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
assert 'if cachedUsage.quota == "__auth_invalid__" {' in swift
assert 'refreshProfiles(showLoading: true, replayQuota: false, liveUsage: true)' in swift
assert 'private func quotaAuthenticationStatus(_ profile: CodexProfile, compact: Bool) -> some View' in swift
assert 'tr("打開重新登入", "Open to sign in again")' in swift
assert 'private func quotaUnavailableStatus(compact: Bool) -> some View' in swift
assert 'tr("暫時未能取得用量", "Usage is temporarily unavailable")' in swift
assert '"version":"2.6.0"' in helper

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

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/CodexAccounts/Info.plist")" == "2.6.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/macos/CodexAccounts/Info.plist")" == "60" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/macos/CodexAccounts/Info.plist")" == "14.0" ]]

echo "✅ Codex Accounts regression checks passed"
