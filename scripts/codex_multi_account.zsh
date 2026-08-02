#!/usr/bin/env zsh
set -euo pipefail
setopt typesetsilent

# Launch a second Codex profile and sync local memory files between profiles.
# This intentionally does not copy auth.json, cookies, or SQLite logs.

CODEX_SYSTEM_APPLICATIONS_DIR="${CODEX_SYSTEM_APPLICATIONS_DIR:-/Applications}"
CODEX_USER_APPLICATIONS_DIR="${CODEX_USER_APPLICATIONS_DIR:-$HOME/Applications}"
CODEX_APP_CANDIDATES=(
  "$CODEX_SYSTEM_APPLICATIONS_DIR/Codex.app"
  "$CODEX_SYSTEM_APPLICATIONS_DIR/ChatGPT.app"
  "$CODEX_USER_APPLICATIONS_DIR/Codex.app"
  "$CODEX_USER_APPLICATIONS_DIR/ChatGPT.app"
)

codex_app_has_gui_executable() {
  local app_path="$1"
  [[ -x "$app_path/Contents/MacOS/ChatGPT" || -x "$app_path/Contents/MacOS/Codex" ]]
}

codex_app_bundle_identifier() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  [[ -r "$info_plist" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null
}

# ChatGPT Classic uses com.openai.chat and cannot host isolated Codex profiles.
# The unified ChatGPT/Codex app keeps com.openai.codex even when its outer
# bundle is named ChatGPT.app. A bundled codex executable is a secondary
# capability signal for compatible preview builds.
codex_app_is_capable() {
  local app_path="$1"
  local bundle_identifier
  codex_app_has_gui_executable "$app_path" || return 1
  bundle_identifier="$(codex_app_bundle_identifier "$app_path" || true)"
  [[ "$bundle_identifier" != "com.openai.chat" ]] || return 1
  [[ "$bundle_identifier" == "com.openai.codex" || -x "$app_path/Contents/Resources/codex" ]]
}

CODEX_APP_EXPLICIT=0
if [[ -n "${CODEX_APP:-}" ]]; then
  CODEX_APP_EXPLICIT=1
else
  CODEX_APP=""
  for candidate in "${CODEX_APP_CANDIDATES[@]}"; do
    if codex_app_is_capable "$candidate"; then
      CODEX_APP="$candidate"
      break
    fi
  done
  CODEX_APP="${CODEX_APP:-$CODEX_SYSTEM_APPLICATIONS_DIR/Codex.app}"
fi

selected_codex_app_is_usable() {
  local bundle_identifier
  codex_app_has_gui_executable "$CODEX_APP" || return 1
  bundle_identifier="$(codex_app_bundle_identifier "$CODEX_APP" || true)"
  [[ "$bundle_identifier" != "com.openai.chat" ]] || return 1
  [[ "$CODEX_APP_EXPLICIT" == "1" ]] || codex_app_is_capable "$CODEX_APP"
}

CODEX_GUI_APP_PATHS=()
typeset -A CODEX_GUI_APP_PATH_SEEN
for candidate in "$CODEX_APP" "${CODEX_APP_CANDIDATES[@]}"; do
  [[ -n "$candidate" && -z "${CODEX_GUI_APP_PATH_SEEN[$candidate]:-}" ]] || continue
  if [[ "$candidate" == "$CODEX_APP" ]]; then
    selected_codex_app_is_usable || continue
  else
    codex_app_is_capable "$candidate" || continue
  fi
  CODEX_GUI_APP_PATH_SEEN[$candidate]=1
  CODEX_GUI_APP_PATHS+=("$candidate")
done
unset CODEX_GUI_APP_PATH_SEEN

report_missing_codex_app() {
  echo "Compatible Codex/ChatGPT app not found." >&2
  echo "Install the current ChatGPT app with Codex in Applications." >&2
  echo "Checked:" >&2
  printf '  %s\n' "${CODEX_APP_CANDIDATES[@]}" >&2
  for candidate in "$CODEX_APP" "${CODEX_APP_CANDIDATES[@]}"; do
    if [[ -d "$candidate" ]] \
      && [[ "$(codex_app_bundle_identifier "$candidate" || true)" == "com.openai.chat" ]]; then
      echo "ChatGPT Classic is installed, but it cannot open isolated Codex profiles." >&2
      break
    fi
  done
}

PRIMARY_CODEX_HOME="${PRIMARY_CODEX_HOME:-$HOME/.codex}"
SECOND_CODEX_HOME="${SECOND_CODEX_HOME:-$HOME/.codex-account2}"
SECOND_APP_DATA="${SECOND_APP_DATA:-$HOME/Library/Application Support/Codex Account 2}"
ACCOUNTS_ROOT="${ACCOUNTS_ROOT:-$HOME/.codex-accounts}"
APP_DATA_ROOT="${APP_DATA_ROOT:-$HOME/Library/Application Support/Codex Accounts}"
SHARED_MEMORY_DIR="${SHARED_MEMORY_DIR:-$HOME/.codex-shared-memory}"
SHARED_HISTORY_ROOT="${SHARED_HISTORY_ROOT:-$HOME/.codex-shared-history}"
SHARED_SESSION_INDEX_FILE="${SHARED_SESSION_INDEX_FILE:-$SHARED_HISTORY_ROOT/session_index.jsonl}"
SHARED_SESSIONS_DIR="${SHARED_SESSIONS_DIR:-$SHARED_HISTORY_ROOT/sessions}"
SHARED_SHELL_SNAPSHOTS_DIR="${SHARED_SHELL_SNAPSHOTS_DIR:-$SHARED_HISTORY_ROOT/shell_snapshots}"
CODEX_HISTORY_ANCHOR_FILE="${CODEX_HISTORY_ANCHOR_FILE:-$APP_DATA_ROOT/history-anchor-home}"
if [[ -z "${CODEX_HISTORY_ANCHOR_HOME:-}" && -r "$CODEX_HISTORY_ANCHOR_FILE" ]]; then
  IFS= read -r CODEX_HISTORY_ANCHOR_HOME < "$CODEX_HISTORY_ANCHOR_FILE" || true
fi
CODEX_HISTORY_ANCHOR_HOME="${CODEX_HISTORY_ANCHOR_HOME:-$PRIMARY_CODEX_HOME}"
CODEX_HISTORY_MODE_MARKER_NAME="${CODEX_HISTORY_MODE_MARKER_NAME:-.codex-accounts-history-mode}"
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-20}"
CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS="${CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS:-5}"
USAGE_API_URL="${USAGE_API_URL:-https://chatgpt.com/backend-api/wham/usage}"
RESET_CREDITS_API_URL="${RESET_CREDITS_API_URL:-https://chatgpt.com/backend-api/wham/rate-limit-reset-credits}"
TOKEN_REFRESH_URL="${TOKEN_REFRESH_URL:-https://auth.openai.com/oauth/token}"
CHATGPT_CLIENT_ID="${CHATGPT_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
USAGE_CACHE_SECONDS="${USAGE_CACHE_SECONDS:-120}"
USAGE_CACHE_ROOT="${USAGE_CACHE_ROOT:-$APP_DATA_ROOT/.usage-cache-v8}"
USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS="${USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS:-1}"
USAGE_DIRECT_TIMEOUT_SECONDS="${USAGE_DIRECT_TIMEOUT_SECONDS:-3}"
TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS="${TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS:-3}"
TOKEN_REFRESH_TIMEOUT_SECONDS="${TOKEN_REFRESH_TIMEOUT_SECONDS:-6}"
APP_SERVER_USAGE_TIMEOUT_SECONDS="${APP_SERVER_USAGE_TIMEOUT_SECONDS:-3}"
CODEX_USAGE_APP_SERVER_FALLBACK="${CODEX_USAGE_APP_SERVER_FALLBACK:-1}"
CODEX_SYNC_PLUGIN_CONFIG="${CODEX_SYNC_PLUGIN_CONFIG:-0}"
CODEX_SYNC_PLUGIN_PAYLOADS="${CODEX_SYNC_PLUGIN_PAYLOADS:-0}"
CODEX_FAST_SYNC_PLUGIN_PAYLOADS="${CODEX_FAST_SYNC_PLUGIN_PAYLOADS:-0}"
CODEX_PRELAUNCH_SYNC="${CODEX_PRELAUNCH_SYNC:-1}"
CODEX_SHARED_SESSIONS="${CODEX_SHARED_SESSIONS:-1}"
CODEX_SYNC_THREAD_HISTORY="${CODEX_SYNC_THREAD_HISTORY:-0}"
CODEX_CLONE_PRIMARY_ON_LAUNCH="${CODEX_CLONE_PRIMARY_ON_LAUNCH:-0}"
CODEX_PRELAUNCH_PLUGIN_PAYLOADS="${CODEX_PRELAUNCH_PLUGIN_PAYLOADS:-0}"
CODEX_PRELAUNCH_SYNC_LOCK_MAX_WAITS="${CODEX_PRELAUNCH_SYNC_LOCK_MAX_WAITS:-40}"
CODEX_AUTO_SYNC_LOCK_MAX_WAITS="${CODEX_AUTO_SYNC_LOCK_MAX_WAITS:-0}"
CODEX_SYNC_STALE_LOCK_SECONDS="${CODEX_SYNC_STALE_LOCK_SECONDS:-15}"
CODEX_SKIP_ACTIVE_STATE_DB_WRITES="${CODEX_SKIP_ACTIVE_STATE_DB_WRITES:-1}"
CODEX_DELETE_STALE_THREAD_ROWS="${CODEX_DELETE_STALE_THREAD_ROWS:-0}"
CODEX_DEFAULT_OPENAI_MODEL="${CODEX_DEFAULT_OPENAI_MODEL:-gpt-5.6-sol}"
CODEX_DEFAULT_OPENAI_REASONING_EFFORT="${CODEX_DEFAULT_OPENAI_REASONING_EFFORT:-xhigh}"
CODEX_PRUNE_GLOBAL_STATE_ON_SYNC="${CODEX_PRUNE_GLOBAL_STATE_ON_SYNC:-0}"
CODEX_PRUNE_LOCAL_THREAD_CATALOG="${CODEX_PRUNE_LOCAL_THREAD_CATALOG:-1}"
CODEX_CATALOG_ORPHAN_GRACE_SECONDS="${CODEX_CATALOG_ORPHAN_GRACE_SECONDS:-120}"
CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH="${CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH:-0}"
CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH="${CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH:-0}"
CODEX_COMPACTED_IMAGE_REPAIR_MIN_BYTES="${CODEX_COMPACTED_IMAGE_REPAIR_MIN_BYTES:-67108864}"
CODEX_SESSION_PAYLOAD_IMAGE_MIN_CHARS="${CODEX_SESSION_PAYLOAD_IMAGE_MIN_CHARS:-65536}"
CODEX_SESSION_PAYLOAD_STRING_MAX_CHARS="${CODEX_SESSION_PAYLOAD_STRING_MAX_CHARS:-200000}"
CODEX_ACTIVE_DB_LSOF_MAX_WAITS="${CODEX_ACTIVE_DB_LSOF_MAX_WAITS:-4}"
CODEX_ACTIVE_DB_LSOF_WAIT_SECONDS="${CODEX_ACTIVE_DB_LSOF_WAIT_SECONDS:-0.05}"
CODEX_RSYNC_MAX_WAITS="${CODEX_RSYNC_MAX_WAITS:-80}"
CODEX_RSYNC_WAIT_SECONDS="${CODEX_RSYNC_WAIT_SECONDS:-0.1}"
CODEX_USAGE_LIVE_LOOKUP="${CODEX_USAGE_LIVE_LOOKUP:-0}"
CODEX_USAGE_LIVE_MIN_PARALLELISM="${CODEX_USAGE_LIVE_MIN_PARALLELISM:-10}"
USAGE_CACHE_STALE_SECONDS="${USAGE_CACHE_STALE_SECONDS:-604800}"
SYNC_LOCK_DIR="${SYNC_LOCK_DIR:-$APP_DATA_ROOT/.sync.lock}"
CODEX_INJECT_PROXY_ENV="${CODEX_INJECT_PROXY_ENV:-auto}"
CODEX_PROXY_URL="${CODEX_PROXY_URL:-http://127.0.0.1:7897}"
CODEX_NO_PROXY="${CODEX_NO_PROXY:-localhost,127.0.0.1,::1}"
DASHSCOPE_SECRET_ENV_FILE="${DASHSCOPE_SECRET_ENV_FILE:-$ACCOUNTS_ROOT/.secrets/dashscope.env}"
ALIYUN_CODING_PLAN_BRIDGE_HOST="${ALIYUN_CODING_PLAN_BRIDGE_HOST:-127.0.0.1}"
ALIYUN_CODING_PLAN_BRIDGE_PORT="${ALIYUN_CODING_PLAN_BRIDGE_PORT:-31416}"
ALIYUN_CODING_PLAN_BRIDGE_ROOT="${ALIYUN_CODING_PLAN_BRIDGE_ROOT:-$ACCOUNTS_ROOT/.tools/aliyun-codex-bridge}"
ALIYUN_CODING_PLAN_BRIDGE_VERSION="${ALIYUN_CODING_PLAN_BRIDGE_VERSION:-0.1.2}"
ALIYUN_CODING_PLAN_BASE_URL="${ALIYUN_CODING_PLAN_BASE_URL:-https://coding.dashscope.aliyuncs.com/v1}"
CODEX_BUNDLED_NODE_BIN="${CODEX_BUNDLED_NODE_BIN:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"
CODEX_BUNDLED_NPM_BIN="${CODEX_BUNDLED_NPM_BIN:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/npm}"
OPENCODEX_PACKAGE="@bitkyc08/opencodex"
OPENCODEX_VERSION="2.7.33"
OPENCODEX_LAB_ACCOUNT="opencodex-lab"
OPENCODEX_LAB_CODEX_HOME="${OPENCODEX_LAB_CODEX_HOME:-$ACCOUNTS_ROOT/$OPENCODEX_LAB_ACCOUNT}"
OPENCODEX_LAB_APP_DATA="${OPENCODEX_LAB_APP_DATA:-$APP_DATA_ROOT/$OPENCODEX_LAB_ACCOUNT}"
OPENCODEX_ROOT="${OPENCODEX_ROOT:-$APP_DATA_ROOT/OpenCodex}"
OPENCODEX_STATE_DIR="${OPENCODEX_STATE_DIR:-$OPENCODEX_ROOT/state}"
OPENCODEX_NPM_PREFIX="${OPENCODEX_NPM_PREFIX:-$OPENCODEX_ROOT/runtime}"
OPENCODEX_FAKE_HOME="${OPENCODEX_FAKE_HOME:-$OPENCODEX_ROOT/home}"
OPENCODEX_LOG_DIR="${OPENCODEX_LOG_DIR:-$OPENCODEX_ROOT/logs}"
OPENCODEX_BIN="${OPENCODEX_BIN:-$OPENCODEX_NPM_PREFIX/node_modules/.bin/ocx}"
OPENCODEX_PACKAGE_JSON="${OPENCODEX_PACKAGE_JSON:-$OPENCODEX_NPM_PREFIX/node_modules/@bitkyc08/opencodex/package.json}"
OPENCODEX_PACKAGE_ROOT="${OPENCODEX_PACKAGE_ROOT:-${OPENCODEX_PACKAGE_JSON:h}}"
OPENCODEX_CURL_BIN="${OPENCODEX_CURL_BIN:-/usr/bin/curl}"
OPENCODEX_OPEN_BIN="${OPENCODEX_OPEN_BIN:-/usr/bin/open}"
OPENCODEX_START_MAX_WAITS="${OPENCODEX_START_MAX_WAITS:-100}"
OPENCODEX_START_WAIT_SECONDS="${OPENCODEX_START_WAIT_SECONDS:-0.1}"
OPENCODEX_SYNC_MAX_WAITS="${OPENCODEX_SYNC_MAX_WAITS:-200}"
OPENCODEX_SYNC_WAIT_SECONDS="${OPENCODEX_SYNC_WAIT_SECONDS:-0.1}"
OPENCODEX_FORCE_SYNC="${OPENCODEX_FORCE_SYNC:-0}"
OPENCODEX_OWNERSHIP_MARKER=".codex-accounts-opencodex-lab"
OPENCODEX_OWNERSHIP_VALUE="managed-by-codex-accounts-opencodex-lab-v1"
OPENCODEX_SHARED_CATALOG="$OPENCODEX_LAB_CODEX_HOME/opencodex-catalog.json"
OPENCODEX_CATALOG_FINGERPRINT="$OPENCODEX_STATE_DIR/catalog-verification.json"
OPENCODEX_CATALOG_FINGERPRINT_OWNER="managed-by-codex-accounts-opencodex-catalog-v1"
OPENCODEX_CATALOG_FINGERPRINT_MAX_AGE_SECONDS="${OPENCODEX_CATALOG_FINGERPRINT_MAX_AGE_SECONDS:-86400}"
OPENCODEX_PROFILE_ROUTE_MARKER=".codex-accounts-opencodex-route.json"
OPENCODEX_PROFILE_ROUTE_OWNER="managed-by-codex-accounts-opencodex-route-v1"
OPENCODEX_CLI_WRAPPER_DIR="$OPENCODEX_ROOT/bin"
OPENCODEX_CLI_WRAPPER="$OPENCODEX_CLI_WRAPPER_DIR/codex-opencodex-router"
OPENCODEX_CLI_WRAPPER_OWNER="managed-by-codex-accounts-opencodex-cli-route-v1"
SCRIPT_DIR="${0:A:h}"
OPENCODEX_RUNTIME_SEED_DIR="${OPENCODEX_RUNTIME_SEED_DIR:-}"
OPENCODEX_RUNTIME_SEED_HELPER="${OPENCODEX_RUNTIME_SEED_HELPER:-$SCRIPT_DIR/opencodex_runtime_seed.py}"
OPENCODEX_RUNTIME_ARCH="${OPENCODEX_RUNTIME_ARCH:-$(uname -m)}"
OPENCODEX_HK_GUI_OVERLAY_DIR="${OPENCODEX_HK_GUI_OVERLAY_DIR:-}"
OPENCODEX_HK_GUI_INDEX_SHA256="6378a09aedf2ee6e884e1eddc40620c335a0039bdc9ab59c7348b26a3c39b29c"
OPENCODEX_HK_GUI_JS_NAME="index-Cgt7VoIY.js"
OPENCODEX_HK_GUI_JS_SHA256="c149306ad9aeb9aeaa07f7bd7f117bd02b0c0d261482a025389859196f771c08"
OPENCODEX_HK_GUI_CSS_NAME="index-D6Fcl4yM.css"
OPENCODEX_HK_GUI_CSS_SHA256="bfd8420ec02a19a72e07be650f2da8fb256fbc2390af047b75b38ebf1ae3f742"
CODEX_SHARE_HELPER="${CODEX_SHARE_HELPER:-$SCRIPT_DIR/codex_share_package.py}"
COLD_STORAGE_INDEX_FILE="${COLD_STORAGE_INDEX_FILE:-$APP_DATA_ROOT/Tiered Storage/cold-index.json}"

SYNC_ITEMS=(
  "AGENTS.md"
  "memories"
  "rules"
)

PLUGIN_SYNC_ITEMS=(
  "plugins"
  "skills"
  "vendor_imports"
)

usage() {
  cat <<'USAGE'
Usage:
  scripts/codex_multi_account.zsh init
  scripts/codex_multi_account.zsh launch-account2
  scripts/codex_multi_account.zsh sync-once
  scripts/codex_multi_account.zsh sync-history-once
  scripts/codex_multi_account.zsh sync-account <account-name>
  scripts/codex_multi_account.zsh sync-account-for-launch <account-name>
  scripts/codex_multi_account.zsh repair-account1
  scripts/codex_multi_account.zsh restore-openai-config-home <CODEX_HOME>
  scripts/codex_multi_account.zsh repair-compactions <account-name>
  scripts/codex_multi_account.zsh sync-loop
  scripts/codex_multi_account.zsh init-account <account-name>
  scripts/codex_multi_account.zsh init-shared-account <account-name>
  scripts/codex_multi_account.zsh launch-account <account-name> [display-name]
  scripts/codex_multi_account.zsh launch-account-nosync <account-name> [display-name]
  scripts/codex_multi_account.zsh codex-app-path
  scripts/codex_multi_account.zsh close-account <account-name>
  scripts/codex_multi_account.zsh close-all-accounts
  scripts/codex_multi_account.zsh list-accounts
  scripts/codex_multi_account.zsh account-status <account-name>
  scripts/codex_multi_account.zsh list-accounts-status
  scripts/codex_multi_account.zsh opencodex-status
  scripts/codex_multi_account.zsh opencodex-install
  scripts/codex_multi_account.zsh opencodex-start
  scripts/codex_multi_account.zsh opencodex-stop
  scripts/codex_multi_account.zsh opencodex-restore
  scripts/codex_multi_account.zsh opencodex-dashboard
  scripts/codex_multi_account.zsh opencodex-launch
  scripts/codex_multi_account.zsh opencodex-enable-all-profiles
  scripts/codex_multi_account.zsh delete-account <account-name>
  scripts/codex_multi_account.zsh link-history <account-name>
  scripts/codex_multi_account.zsh unlink-history <account-name>
  scripts/codex_multi_account.zsh separate-history <account-name>
  scripts/codex_multi_account.zsh history-mode <account-name>
  scripts/codex_multi_account.zsh separate-all-history
  scripts/codex_multi_account.zsh cleanup-empty-projects
  scripts/codex_multi_account.zsh list-exportable-threads <account-name> [limit]
  scripts/codex_multi_account.zsh export-thread-package <account-name> <thread-id> <output.codexshare> [--include-generated-images] [--include-local-assets]
  scripts/codex_multi_account.zsh inspect-thread-package <package.codexshare>
  scripts/codex_multi_account.zsh import-thread-package <package.codexshare> <account-name|all> [--mark-latest]
  scripts/codex_multi_account.zsh archive-thread-cold <account-name> <thread-id> <external-root> [--include-generated-images] [--include-local-assets]
  scripts/codex_multi_account.zsh archive-threads-cold <account-name> <external-root> <thread-id>...
  scripts/codex_multi_account.zsh archive-cold-older-than <account-name> <external-root> <days>
  scripts/codex_multi_account.zsh list-cold-archives
  scripts/codex_multi_account.zsh restore-thread-cold <thread-id>
  scripts/codex_multi_account.zsh restore-threads-cold <thread-id>...
  scripts/codex_multi_account.zsh link-all-history
  CODEX_SYNC_PLUGIN_PAYLOADS=1 scripts/codex_multi_account.zsh sync-once
  scripts/codex_multi_account.zsh link-account2-history
  scripts/codex_multi_account.zsh unlink-account2-history

Environment overrides:
  CODEX_APP=/custom/path/App.app  # optional; default auto-detects Codex.app or ChatGPT.app
  PRIMARY_CODEX_HOME=$HOME/.codex
  SECOND_CODEX_HOME=$HOME/.codex-account2
  SECOND_APP_DATA="$HOME/Library/Application Support/Codex Account 2"
  ACCOUNTS_ROOT=$HOME/.codex-accounts
  APP_DATA_ROOT="$HOME/Library/Application Support/Codex Accounts"
  SHARED_MEMORY_DIR=$HOME/.codex-shared-memory
  SYNC_INTERVAL_SECONDS=20
  CODEX_PROXY_URL=http://127.0.0.1:7897
  CODEX_INJECT_PROXY_ENV=1
  CODEX_CLONE_PRIMARY_ON_LAUNCH=0

OpenCodex Lab:
  - Uses only $HOME/.codex-accounts/opencodex-lab for Codex data.
  - Uses only "$HOME/Library/Application Support/Codex Accounts/OpenCodex/state"
    for OpenCodex state, with a managed npm runtime and fake HOME beside it.
  - Version is pinned to @bitkyc08/opencodex@2.7.33.
  - It never installs an OpenCodex service or Codex shim.
  - The dashboard is loopback-only; no remote management token is created.

Notes:
  - Login separately inside the second Codex window.
  - This syncs local shared state: AGENTS.md, memories/, and rules/.
    Conversation indexes, project/sidebar workspace roots, and goal mode state
    stay profile-local by default. Set CODEX_SYNC_THREAD_HISTORY=1 when you
    explicitly want to merge local conversation history across profiles.
    Plugin config/payload fan-out is off by default because large plugin
    marketplaces can make Codex startup and SQLite backfill time out. Set
    CODEX_SYNC_PLUGIN_CONFIG=1 to merge enabled plugin config entries, or
    CODEX_SYNC_PLUGIN_PAYLOADS=1 to copy every plugins/, skills/, and
    vendor_imports/ payload.
  - init-account creates a blank, isolated profile. It does not copy the primary
    profile and it does not link conversation history.
  - launch-account opens an isolated profile by default. It does not clone the
    primary profile unless CODEX_CLONE_PRIMARY_ON_LAUNCH=1.
  - Use sync-account-for-launch/sync-once to read shared memory/config, and set
    CODEX_SYNC_THREAD_HISTORY=1 only when you explicitly want to merge local
    conversation history across profiles. Use link-history/link-all-history when
    you want persistent shared local conversation files.
  - Plugin enablement is merged across accounts from config.toml
    [plugins."..."] sections without copying the full config file.
  - link-account2-history is experimental: it makes Account 2 use Account 1's
    local Codex history files through symlinks, while keeping auth/cookies
    separate. Quit the second Codex profile before running it.
  - It does not sync cloud conversation history, ChatGPT account memory,
    auth.json, cookies, SQLite logs, or browser cookies/local storage.
  - Usage status is fetched per profile from Codex's authenticated usage
    endpoint. Tokens are only read for the request and are not cached.
  - Conversation packages (.codexshare) export/import one selected local Codex
    conversation, including the rollout JSONL and thread SQLite row. They never
    include auth.json, cookies, or Codex config by default.
  - Proxy injection defaults to auto: the bundled localhost proxy URL is used
    only while its listener is available. Set CODEX_INJECT_PROXY_ENV=1 to force
    a configured proxy, or CODEX_INJECT_PROXY_ENV=0 to disable proxy injection.
USAGE
}

proxy_injection_enabled() {
  local target host port

  [[ -n "$CODEX_PROXY_URL" ]] || return 1
  case "$CODEX_INJECT_PROXY_ENV" in
    1) return 0 ;;
    0) return 1 ;;
    auto) ;;
    *) return 1 ;;
  esac

  target="${CODEX_PROXY_URL#*://}"
  target="${target%%/*}"
  host="${target%:*}"
  port="${target##*:}"
  [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]] || return 1
  [[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || return 1
  command -v nc >/dev/null 2>&1 || return 1
  nc -z "$host" "$port" >/dev/null 2>&1
}

require_rsync() {
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required but was not found." >&2
    exit 1
  fi
}

lsof_quick() {
  command -v lsof >/dev/null 2>&1 || return 1

  local pid waited max_waits wait_interval command_rc
  max_waits="${CODEX_ACTIVE_DB_LSOF_MAX_WAITS:-10}"
  wait_interval="${CODEX_ACTIVE_DB_LSOF_WAIT_SECONDS:-0.05}"

  lsof "$@" >/dev/null 2>&1 &
  pid=$!
  waited=0

  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= max_waits )); then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.05
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$wait_interval"
    waited=$(( waited + 1 ))
  done

  command_rc=0
  wait "$pid" 2>/dev/null || command_rc=$?
  return "$command_rc"
}

active_sqlite_homes_payload() {
  local home_dir db_name db_path lsof_status
  local -A seen
  for home_dir in "$@"; do
    [[ -n "$home_dir" && -z "${seen[$home_dir]:-}" ]] || continue
    for db_name in "state_5.sqlite" "sqlite/state_5.sqlite" "goals_1.sqlite"; do
      db_path="$home_dir/$db_name"
      [[ -e "$db_path" || -e "$db_path-wal" || -e "$db_path-shm" ]] || continue
      if lsof_quick "$db_path" "$db_path-wal" "$db_path-shm"; then
        lsof_status=0
      else
        lsof_status=$?
      fi
      if (( lsof_status == 0 || lsof_status == 124 )); then
        seen[$home_dir]=1
        printf '%s\n' "$home_dir"
        break
      fi
    done
  done
}

sync_debug() {
  [[ "${CODEX_SYNC_DEBUG:-0}" == "1" ]] || return 0
  echo "[codex-sync] $*" >&2
}

run_with_waits() {
  local max_waits="$1"
  local wait_interval="$2"
  shift 2

  local pid waited command_rc
  "$@" &
  pid=$!
  waited=0

  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= max_waits )); then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.05
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$wait_interval"
    waited=$(( waited + 1 ))
  done

  command_rc=0
  wait "$pid" 2>/dev/null || command_rc=$?
  return "$command_rc"
}

rsync_quick() {
  run_with_waits "${CODEX_RSYNC_MAX_WAITS:-80}" "${CODEX_RSYNC_WAIT_SECONDS:-0.1}" rsync "$@"
}

ensure_dirs() {
  mkdir -p "$PRIMARY_CODEX_HOME" "$SECOND_CODEX_HOME" "$SECOND_APP_DATA" "$ACCOUNTS_ROOT" "$APP_DATA_ROOT" "$SHARED_MEMORY_DIR" "$SHARED_SESSIONS_DIR" "$USAGE_CACHE_ROOT"
}

load_dashscope_api_key() {
  local env_file="${DASHSCOPE_SECRET_ENV_FILE:-}"
  local loaded_key

  [[ -n "${DASHSCOPE_API_KEY:-}" ]] && return 0
  [[ -n "$env_file" && -f "$env_file" ]] || return 0

  loaded_key="$(
    awk '
      BEGIN { FS = "=" }
      $1 == "DASHSCOPE_API_KEY" {
        sub(/^[^=]*=/, "")
        gsub(/\r$/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        print
        exit
      }
    ' "$env_file" 2>/dev/null || true
  )"
  if [[ -n "$loaded_key" ]]; then
    DASHSCOPE_API_KEY="$loaded_key"
    export DASHSCOPE_API_KEY
  fi
}

load_aliyun_coding_plan_key() {
  load_dashscope_api_key
  if [[ -z "${AI_API_KEY:-}" && -n "${DASHSCOPE_API_KEY:-}" ]]; then
    AI_API_KEY="$DASHSCOPE_API_KEY"
    export AI_API_KEY
  fi
}

resolve_node_bin() {
  local candidate
  for candidate in \
    "${NODE_BIN:-}" \
    "$CODEX_APP/Contents/Resources/cua_node/bin/node" \
    "$CODEX_BUNDLED_NODE_BIN" \
    "/usr/local/bin/node" \
    "/opt/homebrew/bin/node"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  command -v node 2>/dev/null || return 1
}

resolve_npm_bin() {
  local candidate
  for candidate in \
    "${NPM_BIN:-}" \
    "$CODEX_BUNDLED_NPM_BIN" \
    "/usr/local/bin/npm" \
    "/opt/homebrew/bin/npm"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  command -v npm 2>/dev/null || return 1
}

opencodex_managed_path() {
  local node_bin
  node_bin="$(resolve_node_bin 2>/dev/null || true)"
  [[ -n "$node_bin" ]] || return 1
  printf '%s\n' "$OPENCODEX_NPM_PREFIX/node_modules/.bin:${node_bin:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
}

run_opencodex_lab() {
  local managed_path
  # Providers may reference AI_API_KEY in OpenCodex's local state. Load the
  # existing protected Coding Plan secret into this process only; never copy it
  # into another Profile or the bundled release.
  load_aliyun_coding_plan_key
  managed_path="$(opencodex_managed_path)" || {
    echo "node is required to run OpenCodex Lab." >&2
    return 1
  }
  /usr/bin/env \
    HOME="$OPENCODEX_FAKE_HOME" \
    CODEX_HOME="$OPENCODEX_LAB_CODEX_HOME" \
    OPENCODEX_HOME="$OPENCODEX_STATE_DIR" \
    NPM_CONFIG_PREFIX="$OPENCODEX_NPM_PREFIX" \
    npm_config_prefix="$OPENCODEX_NPM_PREFIX" \
    npm_config_cache="$OPENCODEX_ROOT/npm-cache" \
    PATH="$managed_path" \
    "$@"
}

validate_opencodex_lab_paths() {
  OPENCODEX_VALIDATE_ACCOUNTS_ROOT="$ACCOUNTS_ROOT" \
  OPENCODEX_VALIDATE_APP_DATA_ROOT="$APP_DATA_ROOT" \
  OPENCODEX_VALIDATE_LAB_HOME="$OPENCODEX_LAB_CODEX_HOME" \
  OPENCODEX_VALIDATE_LAB_APP_DATA="$OPENCODEX_LAB_APP_DATA" \
  OPENCODEX_VALIDATE_ROOT="$OPENCODEX_ROOT" \
  OPENCODEX_VALIDATE_STATE="$OPENCODEX_STATE_DIR" \
  OPENCODEX_VALIDATE_RUNTIME="$OPENCODEX_NPM_PREFIX" \
  OPENCODEX_VALIDATE_FAKE_HOME="$OPENCODEX_FAKE_HOME" \
  OPENCODEX_VALIDATE_LOGS="$OPENCODEX_LOG_DIR" \
  python3 - <<'PY'
import os
from pathlib import Path

accounts_root = Path(os.environ["OPENCODEX_VALIDATE_ACCOUNTS_ROOT"]).expanduser().resolve(strict=False)
app_data_root = Path(os.environ["OPENCODEX_VALIDATE_APP_DATA_ROOT"]).expanduser().resolve(strict=False)
lab_home = Path(os.environ["OPENCODEX_VALIDATE_LAB_HOME"]).expanduser()
lab_app_data = Path(os.environ["OPENCODEX_VALIDATE_LAB_APP_DATA"]).expanduser()
managed_root = Path(os.environ["OPENCODEX_VALIDATE_ROOT"]).expanduser()

expected_lab = accounts_root / "opencodex-lab"
expected_lab_app_data = app_data_root / "opencodex-lab"
expected_root = app_data_root / "OpenCodex"
if lab_home.resolve(strict=False) != expected_lab:
    raise SystemExit(f"Refusing unexpected OpenCodex Lab path: {lab_home}")
if lab_app_data.resolve(strict=False) != expected_lab_app_data:
    raise SystemExit(f"Refusing unexpected OpenCodex Lab app-data path: {lab_app_data}")
if managed_root.resolve(strict=False) != expected_root:
    raise SystemExit(f"Refusing unexpected OpenCodex managed root: {managed_root}")

managed_children = [
    Path(os.environ["OPENCODEX_VALIDATE_STATE"]).expanduser(),
    Path(os.environ["OPENCODEX_VALIDATE_RUNTIME"]).expanduser(),
    Path(os.environ["OPENCODEX_VALIDATE_FAKE_HOME"]).expanduser(),
    Path(os.environ["OPENCODEX_VALIDATE_LOGS"]).expanduser(),
]
for candidate in [lab_home, lab_app_data, managed_root, *managed_children]:
    if candidate.is_symlink():
        raise SystemExit(f"Refusing OpenCodex symlink path: {candidate}")
for candidate in managed_children:
    try:
        candidate.resolve(strict=False).relative_to(expected_root)
    except ValueError:
        raise SystemExit(f"Refusing OpenCodex path outside managed root: {candidate}")
PY
}

claim_opencodex_managed_dir() {
  local managed_dir="$1"
  local marker="$managed_dir/$OPENCODEX_OWNERSHIP_MARKER"
  local existing_value=""

  if [[ -L "$managed_dir" || -L "$marker" ]]; then
    echo "Refusing OpenCodex symlink ownership path: $managed_dir" >&2
    return 1
  fi
  mkdir -p "$managed_dir"
  if [[ -f "$marker" ]]; then
    IFS= read -r existing_value < "$marker" || true
    if [[ "$existing_value" == "$OPENCODEX_OWNERSHIP_VALUE" ]]; then
      return 0
    fi
    echo "OpenCodex ownership marker is invalid: $marker" >&2
    return 1
  fi
  if find "$managed_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "Refusing to adopt an existing unowned OpenCodex directory: $managed_dir" >&2
    return 1
  fi

  local tmp_marker="${marker}.tmp.$$"
  printf '%s\n' "$OPENCODEX_OWNERSHIP_VALUE" > "$tmp_marker"
  chmod 600 "$tmp_marker"
  mv "$tmp_marker" "$marker"
}

prepare_opencodex_lab_dirs() {
  local home_was_missing=0
  [[ -d "$OPENCODEX_LAB_CODEX_HOME" ]] || home_was_missing=1

  validate_opencodex_lab_paths
  ensure_dirs
  claim_opencodex_managed_dir "$OPENCODEX_LAB_CODEX_HOME"
  claim_opencodex_managed_dir "$OPENCODEX_LAB_APP_DATA"
  claim_opencodex_managed_dir "$OPENCODEX_ROOT"
  mkdir -p \
    "$OPENCODEX_LAB_CODEX_HOME/sessions" \
    "$OPENCODEX_LAB_CODEX_HOME/shell_snapshots" \
    "$OPENCODEX_STATE_DIR" \
    "$OPENCODEX_FAKE_HOME" \
    "$OPENCODEX_LOG_DIR" \
    "$OPENCODEX_ROOT/npm-cache"
  chmod 700 "$OPENCODEX_STATE_DIR" "$OPENCODEX_FAKE_HOME" "$OPENCODEX_LOG_DIR" 2>/dev/null || true

  if (( home_was_missing == 1 )); then
    set_history_mode_for_home "$OPENCODEX_LAB_CODEX_HOME" private
    : > "$OPENCODEX_LAB_CODEX_HOME/session_index.jsonl"
  fi

  OPENCODEX_CODEX_CONFIG="$OPENCODEX_LAB_CODEX_HOME/config.toml" python3 - <<'PY'
import os
import tempfile
from pathlib import Path

path = Path(os.environ["OPENCODEX_CODEX_CONFIG"])
if path.exists():
    raise SystemExit(0)
path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=".config.toml.", suffix=".tmp", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("[features]\nfast_mode = true\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o600)
    if path.exists():
        os.unlink(tmp_name)
    else:
        os.replace(tmp_name, path)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
PY
}

write_safe_opencodex_lab_config() {
  OPENCODEX_CONFIG_PATH="$OPENCODEX_STATE_DIR/config.json" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

path = Path(os.environ["OPENCODEX_CONFIG_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
if path.is_symlink():
    raise SystemExit(f"Refusing OpenCodex config symlink: {path}")

config = {}
if path.exists():
    try:
        parsed = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"OpenCodex config is invalid; refusing to overwrite it: {exc}")
    if not isinstance(parsed, dict):
        raise SystemExit("OpenCodex config must be a JSON object; refusing to overwrite it")
    config = parsed

providers = config.get("providers")
if not isinstance(providers, dict):
    providers = {}
openai = providers.get("openai")
if not isinstance(openai, dict):
    openai = {}
openai.update({
    "adapter": "openai-responses",
    "baseUrl": "https://chatgpt.com/backend-api/codex",
    "authMode": "forward",
    "codexAccountMode": "direct",
})
providers["openai"] = openai
config["providers"] = providers
if not isinstance(config.get("defaultProvider"), str) or config["defaultProvider"] not in providers:
    config["defaultProvider"] = "openai"
port = config.get("port")
if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
    config["port"] = 10100
config["hostname"] = "127.0.0.1"
config["openaiProviderTierVersion"] = 2
config["syncResumeHistory"] = False
config["codexAutoStart"] = False
config.setdefault("websockets", False)
claude = config.get("claudeCode")
if not isinstance(claude, dict):
    claude = {}
claude["enabled"] = False
claude["systemEnv"] = False
config["claudeCode"] = claude

fd, tmp_name = tempfile.mkstemp(prefix=".config.json.", suffix=".tmp", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, path)
    dir_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
PY
}

prepare_opencodex_lab() {
  prepare_opencodex_lab_dirs
  write_safe_opencodex_lab_config
}

opencodex_installed_version() {
  validate_opencodex_lab_paths >/dev/null 2>&1 || return 1
  [[ -x "$OPENCODEX_BIN" && -f "$OPENCODEX_PACKAGE_JSON" ]] || return 1
  python3 - "$OPENCODEX_PACKAGE_JSON" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("version")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value.strip())
PY
}

require_opencodex_lab_install() {
  local installed_version
  installed_version="$(opencodex_installed_version 2>/dev/null || true)"
  if [[ "$installed_version" != "$OPENCODEX_VERSION" ]]; then
    echo "OpenCodex Lab requires $OPENCODEX_PACKAGE@$OPENCODEX_VERSION; run opencodex-install first." >&2
    return 1
  fi
}

opencodex_hk_gui_overlay_dir() {
  local candidate
  if [[ -n "$OPENCODEX_HK_GUI_OVERLAY_DIR" ]]; then
    [[ -d "$OPENCODEX_HK_GUI_OVERLAY_DIR" && ! -L "$OPENCODEX_HK_GUI_OVERLAY_DIR" ]] || return 1
    printf '%s\n' "$OPENCODEX_HK_GUI_OVERLAY_DIR"
    return 0
  fi
  for candidate in \
    "$SCRIPT_DIR/opencodex-zh-hk/$OPENCODEX_VERSION" \
    "$SCRIPT_DIR/../resources/opencodex-zh-hk/$OPENCODEX_VERSION"; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

opencodex_sha256_matches() {
  local path="$1"
  local expected="$2"
  local actual
  [[ -f "$path" && ! -L "$path" ]] || return 1
  actual="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

opencodex_runtime_seed_dir() {
  local candidate
  if [[ -n "$OPENCODEX_RUNTIME_SEED_DIR" ]]; then
    [[ -d "$OPENCODEX_RUNTIME_SEED_DIR" && ! -L "$OPENCODEX_RUNTIME_SEED_DIR" ]] || return 1
    printf '%s\n' "$OPENCODEX_RUNTIME_SEED_DIR"
    return 0
  fi
  for candidate in \
    "$SCRIPT_DIR/opencodex-runtime/$OPENCODEX_VERSION/$OPENCODEX_RUNTIME_ARCH" \
    "$SCRIPT_DIR/../resources/opencodex-runtime/$OPENCODEX_VERSION/$OPENCODEX_RUNTIME_ARCH"; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

opencodex_runtime_matches_seed() {
  local seed_dir="$1"
  [[ -f "$OPENCODEX_RUNTIME_SEED_HELPER" && ! -L "$OPENCODEX_RUNTIME_SEED_HELPER" ]] || {
    echo "OpenCodex runtime seed verifier is missing." >&2
    return 1
  }
  python3 "$OPENCODEX_RUNTIME_SEED_HELPER" validate-current \
    --seed-dir "$seed_dir" \
    --runtime "$OPENCODEX_NPM_PREFIX" \
    --version "$OPENCODEX_VERSION" \
    --arch "$OPENCODEX_RUNTIME_ARCH" >/dev/null
}

opencodex_install_runtime_seed() {
  local seed_dir="$1"
  validate_opencodex_lab_paths || return 1
  [[ -f "$OPENCODEX_RUNTIME_SEED_HELPER" && ! -L "$OPENCODEX_RUNTIME_SEED_HELPER" ]] || {
    echo "OpenCodex runtime seed verifier is missing." >&2
    return 1
  }
  python3 "$OPENCODEX_RUNTIME_SEED_HELPER" install \
    --seed-dir "$seed_dir" \
    --runtime "$OPENCODEX_NPM_PREFIX" \
    --managed-root "$OPENCODEX_ROOT" \
    --version "$OPENCODEX_VERSION" \
    --arch "$OPENCODEX_RUNTIME_ARCH" >/dev/null
}

validate_opencodex_gui_target() {
  OPENCODEX_VALIDATE_PACKAGE_ROOT="$OPENCODEX_PACKAGE_ROOT" \
  OPENCODEX_VALIDATE_PACKAGE_JSON="$OPENCODEX_PACKAGE_JSON" \
  OPENCODEX_VALIDATE_PREFIX="$OPENCODEX_NPM_PREFIX" \
  python3 - <<'PY'
import os
from pathlib import Path

prefix = Path(os.environ["OPENCODEX_VALIDATE_PREFIX"]).expanduser().resolve(strict=False)
package_root = Path(os.environ["OPENCODEX_VALIDATE_PACKAGE_ROOT"]).expanduser()
package_json = Path(os.environ["OPENCODEX_VALIDATE_PACKAGE_JSON"]).expanduser()
expected_root = prefix / "node_modules" / "@bitkyc08" / "opencodex"
if package_root.resolve(strict=False) != expected_root.resolve(strict=False):
    raise SystemExit(f"Refusing unexpected OpenCodex package path: {package_root}")
if package_json.resolve(strict=False) != (expected_root / "package.json").resolve(strict=False):
    raise SystemExit(f"Refusing unexpected OpenCodex package metadata path: {package_json}")
dist = package_root / "gui" / "dist"
assets = dist / "assets"
for candidate in (package_root, package_json, package_root / "gui", dist, assets):
    if candidate.is_symlink():
        raise SystemExit(f"Refusing OpenCodex GUI symlink path: {candidate}")
if assets.exists():
    try:
        assets.resolve(strict=False).relative_to(dist.resolve(strict=False))
    except ValueError:
        raise SystemExit(f"Refusing OpenCodex assets path outside GUI dist: {assets}")
PY
}

opencodex_hk_gui_is_current() {
  local dist="$OPENCODEX_PACKAGE_ROOT/gui/dist"
  validate_opencodex_gui_target >/dev/null 2>&1 || return 1
  opencodex_sha256_matches "$dist/index.html" "$OPENCODEX_HK_GUI_INDEX_SHA256" || return 1
  opencodex_sha256_matches "$dist/assets/$OPENCODEX_HK_GUI_JS_NAME" "$OPENCODEX_HK_GUI_JS_SHA256" || return 1
  opencodex_sha256_matches "$dist/assets/$OPENCODEX_HK_GUI_CSS_NAME" "$OPENCODEX_HK_GUI_CSS_SHA256"
}

opencodex_apply_hk_gui() {
  local overlay dist rel source target tmp expected
  require_opencodex_lab_install || return 1
  validate_opencodex_gui_target || return 1
  overlay="$(opencodex_hk_gui_overlay_dir 2>/dev/null || true)"
  if [[ -z "$overlay" ]]; then
    echo "OpenCodex Hong Kong Chinese interface files are missing." >&2
    return 1
  fi

  opencodex_sha256_matches "$overlay/index.html" "$OPENCODEX_HK_GUI_INDEX_SHA256" || {
    echo "OpenCodex Hong Kong Chinese index verification failed." >&2
    return 1
  }
  opencodex_sha256_matches "$overlay/assets/$OPENCODEX_HK_GUI_JS_NAME" "$OPENCODEX_HK_GUI_JS_SHA256" || {
    echo "OpenCodex Hong Kong Chinese script verification failed." >&2
    return 1
  }
  opencodex_sha256_matches "$overlay/assets/$OPENCODEX_HK_GUI_CSS_NAME" "$OPENCODEX_HK_GUI_CSS_SHA256" || {
    echo "OpenCodex Hong Kong Chinese style verification failed." >&2
    return 1
  }

  dist="$OPENCODEX_PACKAGE_ROOT/gui/dist"
  mkdir -p "$dist/assets"
  for rel expected in \
    "index.html" "$OPENCODEX_HK_GUI_INDEX_SHA256" \
    "assets/$OPENCODEX_HK_GUI_JS_NAME" "$OPENCODEX_HK_GUI_JS_SHA256" \
    "assets/$OPENCODEX_HK_GUI_CSS_NAME" "$OPENCODEX_HK_GUI_CSS_SHA256"; do
    source="$overlay/$rel"
    target="$dist/$rel"
    [[ ! -L "$target" ]] || {
      echo "Refusing OpenCodex GUI symlink target: $target" >&2
      return 1
    }
    tmp="${target}.codex-accounts.$$"
    cp "$source" "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
    opencodex_sha256_matches "$target" "$expected" || return 1
  done
  opencodex_hk_gui_is_current
}

opencodex_runtime_values() {
  local runtime_file="$OPENCODEX_STATE_DIR/runtime-port.json"
  validate_opencodex_lab_paths >/dev/null 2>&1 || return 1
  [[ -f "$runtime_file" && ! -L "$runtime_file" ]] || return 1
  python3 - "$runtime_file" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
pid = state.get("pid")
port = state.get("port")
hostname = state.get("hostname") or "127.0.0.1"
if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
    raise SystemExit(1)
if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
    raise SystemExit(1)
if hostname not in {"127.0.0.1", "localhost", "::1", "[::1]"}:
    raise SystemExit(1)
print(f"{pid}\t{port}")
PY
}

opencodex_running_url() {
  local runtime_values pid port health
  runtime_values="$(opencodex_runtime_values 2>/dev/null || true)"
  [[ -n "$runtime_values" ]] || return 1
  IFS=$'\t' read -r pid port <<< "$runtime_values"
  [[ "$pid" == <-> && "$port" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -x "$OPENCODEX_CURL_BIN" ]] || return 1
  health="$($OPENCODEX_CURL_BIN --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  [[ -n "$health" ]] || return 1
  printf '%s' "$health" | python3 -c '
import json, sys
expected_pid, expected_port = map(int, sys.argv[1:3])
expected_version = sys.argv[3]
value = json.load(sys.stdin)
ok = (
    isinstance(value, dict)
    and value.get("status") == "ok"
    and value.get("service") == "opencodex"
    and value.get("version") == expected_version
    and value.get("pid") == expected_pid
    and value.get("port") == expected_port
)
raise SystemExit(0 if ok else 1)
' "$pid" "$port" "$OPENCODEX_VERSION" >/dev/null 2>&1 || return 1
  printf 'http://127.0.0.1:%s/\n' "$port"
}

opencodex_verify_shared_catalog_structure() {
  local url="$1"
  local log_file="$OPENCODEX_LOG_DIR/opencodex.log"
  local expected_base_url="${url%/}/v1"

  OPENCODEX_VERIFY_CONFIG="$OPENCODEX_LAB_CODEX_HOME/config.toml" \
    OPENCODEX_VERIFY_CATALOG="$OPENCODEX_SHARED_CATALOG" \
    OPENCODEX_VERIFY_STATE_CONFIG="$OPENCODEX_STATE_DIR/config.json" \
    OPENCODEX_VERIFY_BASE_URL="$expected_base_url" \
    python3 - 2>>"$log_file" <<'PY'
import ast
import json
import os
import re
from pathlib import Path

config_path = Path(os.environ["OPENCODEX_VERIFY_CONFIG"]).expanduser()
catalog_path = Path(os.environ["OPENCODEX_VERIFY_CATALOG"]).expanduser()
state_config_path = Path(os.environ["OPENCODEX_VERIFY_STATE_CONFIG"]).expanduser()
expected_base_url = os.environ["OPENCODEX_VERIFY_BASE_URL"]

for path, label in (
    (config_path, "config"),
    (catalog_path, "catalog"),
    (state_config_path, "state config"),
):
    if path.is_symlink():
        raise SystemExit(f"Refusing OpenCodex {label} symlink: {path}")
    if not path.is_file():
        raise SystemExit(f"OpenCodex {label} is missing: {path}")
if not catalog_path.is_absolute():
    raise SystemExit("OpenCodex shared catalog path must be absolute")

values: dict[str, list[str]] = {"openai_base_url": [], "model_catalog_json": []}
for raw_line in config_path.read_text(encoding="utf-8-sig", errors="strict").splitlines():
    stripped = raw_line.strip()
    if stripped.startswith("["):
        break
    match = re.match(r"^(openai_base_url|model_catalog_json)\s*=\s*(.+?)\s*$", stripped)
    if not match:
        continue
    raw_value = match.group(2)
    try:
        value = ast.literal_eval(raw_value)
    except (SyntaxError, ValueError):
        raise SystemExit(f"Invalid top-level OpenCodex setting: {match.group(1)}")
    if not isinstance(value, str):
        raise SystemExit(f"OpenCodex setting must be a string: {match.group(1)}")
    values[match.group(1)].append(value)

if values["openai_base_url"] != [expected_base_url]:
    raise SystemExit("OpenCodex did not write the verified loopback openai_base_url")
if values["model_catalog_json"] != [str(catalog_path)]:
    raise SystemExit("OpenCodex did not write the shared model_catalog_json")

catalog = json.loads(catalog_path.read_text(encoding="utf-8-sig"))
if not isinstance(catalog, dict) or not isinstance(catalog.get("models"), list) or not catalog["models"]:
    raise SystemExit("OpenCodex shared model catalog is empty or invalid")
catalog_namespaces = {
    slug.split("/", 1)[0]
    for model in catalog["models"]
    if isinstance(model, dict)
    and isinstance((slug := model.get("slug")), str)
    and "/" in slug
}

state_config = json.loads(state_config_path.read_text(encoding="utf-8-sig"))
providers = state_config.get("providers") if isinstance(state_config, dict) else None
expected_namespaces = {
    name
    for name, provider in (providers.items() if isinstance(providers, dict) else ())
    if name != "openai"
    and isinstance(provider, dict)
    and provider.get("disabled") is not True
    and isinstance(provider.get("models"), list)
    and provider["models"]
}
missing_namespaces = expected_namespaces - catalog_namespaces
if missing_namespaces:
    raise SystemExit(
        "OpenCodex shared catalog is missing configured provider namespaces: "
        + ", ".join(sorted(missing_namespaces))
    )
PY
}

opencodex_catalog_fingerprint() {
  local mode="$1"
  local freshness="${2:-fresh}"

  OPENCODEX_FINGERPRINT_MODE="$mode" \
  OPENCODEX_FINGERPRINT_FRESHNESS="$freshness" \
  OPENCODEX_FINGERPRINT_PATH="$OPENCODEX_CATALOG_FINGERPRINT" \
  OPENCODEX_FINGERPRINT_STATE_DIR="$OPENCODEX_STATE_DIR" \
  OPENCODEX_FINGERPRINT_STATE_CONFIG="$OPENCODEX_STATE_DIR/config.json" \
  OPENCODEX_FINGERPRINT_CATALOG="$OPENCODEX_SHARED_CATALOG" \
  OPENCODEX_FINGERPRINT_OWNER="$OPENCODEX_CATALOG_FINGERPRINT_OWNER" \
  OPENCODEX_FINGERPRINT_VERSION="$OPENCODEX_VERSION" \
  OPENCODEX_FINGERPRINT_MAX_AGE="$OPENCODEX_CATALOG_FINGERPRINT_MAX_AGE_SECONDS" \
  python3 - <<'PY'
import hashlib
import hmac
import json
import os
import re
import stat
import tempfile
import time
from pathlib import Path

mode = os.environ["OPENCODEX_FINGERPRINT_MODE"]
freshness = os.environ["OPENCODEX_FINGERPRINT_FRESHNESS"]
fingerprint_path = Path(os.environ["OPENCODEX_FINGERPRINT_PATH"])
state_dir = Path(os.environ["OPENCODEX_FINGERPRINT_STATE_DIR"])
state_config_path = Path(os.environ["OPENCODEX_FINGERPRINT_STATE_CONFIG"])
catalog_path = Path(os.environ["OPENCODEX_FINGERPRINT_CATALOG"])
owner = os.environ["OPENCODEX_FINGERPRINT_OWNER"]
version = os.environ["OPENCODEX_FINGERPRINT_VERSION"]
max_age = int(os.environ["OPENCODEX_FINGERPRINT_MAX_AGE"])

if mode not in {"write", "verify"} or freshness not in {"fresh", "allow-stale"}:
    raise SystemExit("Invalid OpenCodex catalog fingerprint operation")
if state_dir.is_symlink() or not state_dir.is_dir():
    raise SystemExit(f"Refusing invalid OpenCodex state directory: {state_dir}")
if fingerprint_path.parent != state_dir or fingerprint_path.name != "catalog-verification.json":
    raise SystemExit("Refusing unexpected OpenCodex catalog fingerprint path")
for path, label in ((state_config_path, "state config"), (catalog_path, "catalog")):
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Refusing invalid OpenCodex {label}: {path}")
if fingerprint_path.is_symlink():
    raise SystemExit(f"Refusing OpenCodex catalog fingerprint symlink: {fingerprint_path}")
if fingerprint_path.exists() and not fingerprint_path.is_file():
    raise SystemExit(f"Refusing invalid OpenCodex catalog fingerprint: {fingerprint_path}")

state = json.loads(state_config_path.read_text(encoding="utf-8-sig"))
if not isinstance(state, dict):
    raise SystemExit("OpenCodex state config must be an object")

secret_names = {
    "apikey", "accesskey", "accesstoken", "refreshtoken", "idtoken",
    "authtoken", "oauthtoken", "sessiontoken", "bearer", "secret",
    "clientsecret", "password", "cookie", "cookies", "credential",
    "credentials", "authorization", "header", "headers", "customheaders",
}

def is_secret_key(key):
    normalized = re.sub(r"[^a-z0-9]", "", key.lower())
    return normalized in secret_names or normalized.endswith("apikey")

def sanitize(value, key=""):
    if is_secret_key(key):
        return {"secret_present": bool(value), "secret_type": type(value).__name__}
    if isinstance(value, dict):
        return {str(k): sanitize(v, str(k)) for k, v in sorted(value.items(), key=lambda item: str(item[0]))}
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise SystemExit(f"Unsupported OpenCodex state value type for {key}")

# Exclude runtime/UI-only fields. All other current and future state keys are
# fingerprinted so model definitions, provider URLs, selections, capabilities,
# and enabled/disabled flags cannot silently reuse an older catalog.
runtime_only = {"hostname", "port", "codexAutoStart", "syncResumeHistory"}
catalog_inputs = {
    key: sanitize(value, key)
    for key, value in sorted(state.items())
    if key not in runtime_only
}
inputs_bytes = json.dumps(
    {"opencodex_version": version, "state": catalog_inputs},
    ensure_ascii=True,
    sort_keys=True,
    separators=(",", ":"),
    allow_nan=False,
).encode("utf-8")
expected_inputs_hash = hashlib.sha256(inputs_bytes).hexdigest()
expected_catalog_hash = hashlib.sha256(catalog_path.read_bytes()).hexdigest()

if mode == "verify":
    if not fingerprint_path.is_file():
        raise SystemExit("OpenCodex catalog fingerprint is missing")
    if stat.S_IMODE(fingerprint_path.stat().st_mode) != 0o600:
        raise SystemExit("OpenCodex catalog fingerprint permissions are invalid")
    fingerprint = json.loads(fingerprint_path.read_text(encoding="utf-8-sig"))
    if not isinstance(fingerprint, dict):
        raise SystemExit("OpenCodex catalog fingerprint must be an object")
    if fingerprint.get("schema") != 1 or fingerprint.get("owner") != owner:
        raise SystemExit("OpenCodex catalog fingerprint owner/schema mismatch")
    if fingerprint.get("opencodex_version") != version:
        raise SystemExit("OpenCodex catalog fingerprint version mismatch")
    if not hmac.compare_digest(str(fingerprint.get("catalog_inputs_sha256", "")), expected_inputs_hash):
        raise SystemExit("OpenCodex provider/model settings changed after catalog verification")
    if not hmac.compare_digest(str(fingerprint.get("catalog_sha256", "")), expected_catalog_hash):
        raise SystemExit("OpenCodex shared catalog changed after verification")
    written_at = fingerprint.get("written_at")
    if isinstance(written_at, bool) or not isinstance(written_at, (int, float)):
        raise SystemExit("OpenCodex catalog fingerprint timestamp is invalid")
    now = time.time()
    if written_at > now + 300:
        raise SystemExit("OpenCodex catalog fingerprint timestamp is in the future")
    if freshness == "fresh" and max_age >= 0 and now - written_at > max_age:
        raise SystemExit("OpenCodex catalog fingerprint is stale")
    raise SystemExit(0)

payload = {
    "schema": 1,
    "owner": owner,
    "opencodex_version": version,
    "catalog_inputs_sha256": expected_inputs_hash,
    "catalog_sha256": expected_catalog_hash,
    "written_at": int(time.time()),
}
fd, tmp_name = tempfile.mkstemp(prefix=".catalog-verification.", suffix=".tmp", dir=state_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, fingerprint_path)
    dir_fd = os.open(state_dir, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
PY
}

opencodex_verify_shared_catalog() {
  local url="$1"
  local freshness="${2:-fresh}"
  local log_file="$OPENCODEX_LOG_DIR/opencodex.log"
  opencodex_verify_shared_catalog_structure "$url" || return 1
  opencodex_catalog_fingerprint verify "$freshness" 2>>"$log_file"
}

opencodex_sync_and_verify_lab() {
  local url="$1"
  local log_file="$OPENCODEX_LOG_DIR/opencodex.log"
  local attempt=1 max_attempts=3 sync_status=0

  [[ "$url" =~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/$' ]] || {
    echo "Refusing to synchronize OpenCodex through a non-loopback URL." >&2
    return 1
  }

  # A fresh fingerprint binds the provider/model settings and exact catalog
  # bytes to the current loopback route. Do not make every Profile launch wait
  # on provider discovery again unless a caller explicitly requests it.
  if [[ "$OPENCODEX_FORCE_SYNC" != "1" ]] && opencodex_verify_shared_catalog "$url" fresh; then
    return 0
  fi

  while (( attempt <= max_attempts )); do
    sync_status=0
    run_with_waits "$OPENCODEX_SYNC_MAX_WAITS" "$OPENCODEX_SYNC_WAIT_SECONDS" \
      run_opencodex_lab "$OPENCODEX_BIN" sync >>"$log_file" 2>&1 || sync_status=$?

    if (( sync_status == 124 )); then
      if opencodex_verify_shared_catalog "$url" allow-stale; then
        echo "OpenCodex model synchronization timed out; using the existing verified shared model catalog." >&2
        return 0
      fi
      echo "OpenCodex model synchronization timed out without a verified shared model catalog; see $log_file" >&2
      return 1
    fi
    if (( sync_status != 0 )); then
      echo "OpenCodex model synchronization failed; see $log_file" >&2
      return 1
    fi

    if opencodex_verify_shared_catalog_structure "$url"; then
      if opencodex_catalog_fingerprint write fresh 2>>"$log_file" \
        && opencodex_verify_shared_catalog "$url" fresh; then
        return 0
      fi
      echo "OpenCodex catalog verification fingerprint could not be recorded safely; see $log_file" >&2
      return 1
    fi
    attempt=$(( attempt + 1 ))
    (( attempt <= max_attempts )) && sleep 0.1
  done

  echo "OpenCodex synchronized, but its shared model catalog did not become complete; see $log_file" >&2
  return 1
}

opencodex_status() {
  local installed=0 running=0 version="unknown" url=""
  version="$(opencodex_installed_version 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    installed=1
  else
    version="unknown"
  fi
  url="$(opencodex_running_url 2>/dev/null || true)"
  [[ -n "$url" ]] && running=1
  printf '%s\t%s\t%s\t%s\n' "$installed" "$running" "$version" "$url"
}

opencodex_install() {
  local npm_bin node_bin managed_path installed_version running_url="" restart_after_patch=0 seed_dir=""
  prepare_opencodex_lab || return 1
  seed_dir="$(opencodex_runtime_seed_dir 2>/dev/null || true)"
  installed_version="$(opencodex_installed_version 2>/dev/null || true)"
  if [[ "$installed_version" == "$OPENCODEX_VERSION" ]]; then
    if [[ -z "$seed_dir" ]] || opencodex_runtime_matches_seed "$seed_dir"; then
      if ! opencodex_hk_gui_is_current; then
        running_url="$(opencodex_running_url 2>/dev/null || true)"
        if [[ -n "$running_url" ]]; then
          restart_after_patch=1
          opencodex_stop >/dev/null
        fi
        opencodex_apply_hk_gui || return 1
        if (( restart_after_patch == 1 )); then
          opencodex_start >/dev/null
        fi
      fi
      echo "OpenCodex Lab $OPENCODEX_VERSION is already installed."
      return 0
    fi

    running_url="$(opencodex_running_url 2>/dev/null || true)"
    if [[ -n "$running_url" ]]; then
      restart_after_patch=1
      opencodex_stop >/dev/null
    fi
  elif [[ -x "$OPENCODEX_BIN" ]]; then
    opencodex_stop >/dev/null 2>&1 || true
  fi

  if [[ -n "$seed_dir" ]]; then
    if ! opencodex_install_runtime_seed "$seed_dir"; then
      echo "Bundled OpenCodex runtime verification failed; refusing network fallback." >&2
      return 1
    fi
    installed_version="$(opencodex_installed_version 2>/dev/null || true)"
    if [[ "$installed_version" != "$OPENCODEX_VERSION" ]]; then
      echo "Bundled OpenCodex runtime install verification failed (found ${installed_version:-unknown})." >&2
      return 1
    fi
    opencodex_apply_hk_gui || return 1
    if (( restart_after_patch == 1 )); then
      opencodex_start >/dev/null
    fi
    echo "Installed bundled OpenCodex Lab $installed_version (offline seed)."
    return 0
  fi

  echo "Bundled OpenCodex runtime is unavailable for $OPENCODEX_RUNTIME_ARCH; falling back to npm." >&2
  if [[ "$installed_version" == "$OPENCODEX_VERSION" ]]; then
    if ! opencodex_hk_gui_is_current; then
      running_url="$(opencodex_running_url 2>/dev/null || true)"
      if [[ -n "$running_url" ]]; then
        restart_after_patch=1
        opencodex_stop >/dev/null
      fi
      opencodex_apply_hk_gui || return 1
      if (( restart_after_patch == 1 )); then
        opencodex_start >/dev/null
      fi
    fi
    echo "OpenCodex Lab $OPENCODEX_VERSION is already installed."
    return 0
  fi

  npm_bin="$(resolve_npm_bin 2>/dev/null || true)"
  node_bin="$(resolve_node_bin 2>/dev/null || true)"
  if [[ -z "$npm_bin" || -z "$node_bin" ]]; then
    echo "node and npm are required to install OpenCodex Lab." >&2
    return 1
  fi
  managed_path="$OPENCODEX_NPM_PREFIX/node_modules/.bin:${node_bin:h}:${npm_bin:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  /usr/bin/env \
    HOME="$OPENCODEX_FAKE_HOME" \
    CODEX_HOME="$OPENCODEX_LAB_CODEX_HOME" \
    OPENCODEX_HOME="$OPENCODEX_STATE_DIR" \
    NPM_CONFIG_PREFIX="$OPENCODEX_NPM_PREFIX" \
    npm_config_prefix="$OPENCODEX_NPM_PREFIX" \
    npm_config_cache="$OPENCODEX_ROOT/npm-cache" \
    npm_config_update_notifier=false \
    PATH="$managed_path" \
    "$npm_bin" install \
      --prefix "$OPENCODEX_NPM_PREFIX" \
      --no-save \
      --package-lock=false \
      --include=optional \
      --no-audit \
      --no-fund \
      "$OPENCODEX_PACKAGE@$OPENCODEX_VERSION"

  installed_version="$(opencodex_installed_version 2>/dev/null || true)"
  if [[ "$installed_version" != "$OPENCODEX_VERSION" ]]; then
    echo "OpenCodex Lab install verification failed (found ${installed_version:-unknown})." >&2
    return 1
  fi
  opencodex_apply_hk_gui || return 1
  echo "Installed OpenCodex Lab $installed_version."
}

opencodex_start() {
  local managed_path log_file launcher_pid url waited=0
  prepare_opencodex_lab || return 1
  load_aliyun_coding_plan_key
  if ! require_opencodex_lab_install >/dev/null 2>&1; then
    if ! opencodex_install >/dev/null; then
      remove_all_opencodex_profile_routes >/dev/null 2>&1 || true
      return 1
    fi
  fi
  require_opencodex_lab_install || return 1
  managed_path="$(opencodex_managed_path)" || return 1
  log_file="$OPENCODEX_LOG_DIR/opencodex.log"

  url="$(opencodex_running_url 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    opencodex_hk_gui_is_current || {
      echo "OpenCodex Hong Kong Chinese interface needs repair. Stop the proxy and run opencodex-install." >&2
      return 1
    }
    if ! opencodex_sync_and_verify_lab "$url"; then
      run_opencodex_lab "$OPENCODEX_BIN" stop >>"$log_file" 2>&1 || true
      remove_all_opencodex_profile_routes >/dev/null 2>&1 || true
      return 1
    fi
    printf '%s\n' "$url"
    return 0
  fi

  opencodex_apply_hk_gui || return 1

  /usr/bin/nohup /usr/bin/env \
    HOME="$OPENCODEX_FAKE_HOME" \
    CODEX_HOME="$OPENCODEX_LAB_CODEX_HOME" \
    OPENCODEX_HOME="$OPENCODEX_STATE_DIR" \
    NPM_CONFIG_PREFIX="$OPENCODEX_NPM_PREFIX" \
    npm_config_prefix="$OPENCODEX_NPM_PREFIX" \
    npm_config_cache="$OPENCODEX_ROOT/npm-cache" \
    PATH="$managed_path" \
    "$OPENCODEX_BIN" start >>"$log_file" 2>&1 </dev/null &
  launcher_pid=$!
  disown "$launcher_pid" >/dev/null 2>&1 || true

  while (( waited < OPENCODEX_START_MAX_WAITS )); do
    url="$(opencodex_running_url 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
      if opencodex_sync_and_verify_lab "$url"; then
        printf '%s\n' "$url"
        return 0
      fi
      break
    fi
    sleep "$OPENCODEX_START_WAIT_SECONDS"
    waited=$(( waited + 1 ))
  done

  kill "$launcher_pid" >/dev/null 2>&1 || true
  wait "$launcher_pid" >/dev/null 2>&1 || true
  run_opencodex_lab "$OPENCODEX_BIN" stop >>"$log_file" 2>&1 || true
  remove_all_opencodex_profile_routes >/dev/null 2>&1 || true
  echo "OpenCodex Lab did not become healthy and synchronized; see $log_file" >&2
  return 1
}

opencodex_stop() {
  local stop_status=0
  if [[ ! -x "$OPENCODEX_BIN" ]]; then
    remove_all_opencodex_profile_routes
    echo "OpenCodex Lab is not installed."
    return 0
  fi
  run_opencodex_lab "$OPENCODEX_BIN" stop || stop_status=$?
  remove_all_opencodex_profile_routes || stop_status=$?
  return "$stop_status"
}

opencodex_restore() {
  require_opencodex_lab_install
  run_opencodex_lab "$OPENCODEX_BIN" restore
}

opencodex_dashboard() {
  local url
  url="$(opencodex_running_url 2>/dev/null || true)"
  if [[ ! "$url" =~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/$' ]]; then
    echo "OpenCodex Lab is not running on a verified loopback URL." >&2
    return 1
  fi
  [[ -x "$OPENCODEX_OPEN_BIN" ]] || {
    echo "open command was not found." >&2
    return 1
  }
  "$OPENCODEX_OPEN_BIN" "$url"
}

opencodex_launch() {
  opencodex_start >/dev/null
  OPENCODEX_LAB_LAUNCH_VERIFIED=1 \
  CODEX_PRELAUNCH_SYNC=0 \
  CODEX_SHARED_SESSIONS=0 \
  CODEX_SYNC_THREAD_HISTORY=0 \
    launch_account "$OPENCODEX_LAB_ACCOUNT" "OpenCodex Lab"
}

is_primary_codex_home() {
  local home_dir="$1"
  [[ "$home_dir" == "$PRIMARY_CODEX_HOME" ]]
}

write_top_level_model_config() {
  local config_file="$1"
  local model="$2"
  local provider="$3"
  local reasoning_effort="${4:-}"
  [[ -f "$config_file" ]] || return 0

  MODEL_VALUE="$model" PROVIDER_VALUE="$provider" REASONING_EFFORT_VALUE="$reasoning_effort" CONFIG_FILE="$config_file" python3 - <<'PY'
from pathlib import Path
import os

path = Path(os.environ["CONFIG_FILE"])
model = os.environ["MODEL_VALUE"]
provider = os.environ["PROVIDER_VALUE"]
reasoning_effort = os.environ["REASONING_EFFORT_VALUE"]
lines = path.read_text(errors="replace").splitlines()
out = []
in_table = False
seen_model = False
seen_provider = False
seen_reasoning_effort = False
inserted = False

def insert_missing():
    global inserted, seen_model, seen_provider, seen_reasoning_effort
    if inserted:
        return
    if not seen_model:
        out.append(f'model = "{model}"')
        seen_model = True
    if not seen_provider:
        out.append(f'model_provider = "{provider}"')
        seen_provider = True
    if reasoning_effort and not seen_reasoning_effort:
        out.append(f'model_reasoning_effort = "{reasoning_effort}"')
        seen_reasoning_effort = True
    inserted = True

for line in lines:
    stripped = line.strip()
    if not in_table and stripped.startswith("["):
        insert_missing()
        in_table = True

    if not in_table and stripped.startswith("model ") or (not in_table and stripped.startswith("model=")):
        if not seen_model:
            out.append(f'model = "{model}"')
            seen_model = True
        continue
    if not in_table and stripped.startswith("model_provider"):
        if not seen_provider:
            out.append(f'model_provider = "{provider}"')
            seen_provider = True
        continue
    if not in_table and stripped.startswith("model_reasoning_effort"):
        if reasoning_effort:
            if not seen_reasoning_effort:
                out.append(f'model_reasoning_effort = "{reasoning_effort}"')
                seen_reasoning_effort = True
        else:
            out.append(line)
        continue
    out.append(line)

if not inserted:
    insert_missing()

path.write_text("\n".join(out) + "\n")
PY
}

ensure_ai_proxy_provider_config() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0

  AI_PROXY_BASE_URL="http://${ALIYUN_CODING_PLAN_BRIDGE_HOST}:${ALIYUN_CODING_PLAN_BRIDGE_PORT}" CONFIG_FILE="$config_file" python3 - <<'PY'
from pathlib import Path
import os

path = Path(os.environ["CONFIG_FILE"])
base_url = os.environ["AI_PROXY_BASE_URL"]
lines = path.read_text(errors="replace").splitlines()
table_header = "[model_providers.ai_proxy]"
block = [
    table_header,
    'name = "Coding Plan Dashscope via local proxy"',
    f'base_url = "{base_url}"',
    'env_key = "AI_API_KEY"',
    'wire_api = "responses"',
    'supports_websockets = false',
    'stream_idle_timeout_ms = 3000000',
]

out = []
i = 0
replaced = False
while i < len(lines):
    if lines[i].strip() == table_header:
        out.extend(block)
        replaced = True
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith("["):
            i += 1
        continue
    out.append(lines[i])
    i += 1

if not replaced:
    if out and out[-1].strip():
        out.append("")
    out.extend(block)

path.write_text("\n".join(out) + "\n")
PY
}

ensure_account1_model_catalog_for_home() {
  local home_dir="$1"
  is_primary_codex_home "$home_dir" || return 0
  [[ -d "$home_dir" ]] || return 0

  ACCOUNT1_HOME="$home_dir" python3 - <<'PY'
from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path

home = Path(os.environ["ACCOUNT1_HOME"]).expanduser()
config_path = home / "config.toml"
catalog_path = home / "qwen-model-catalog.json"
cache_path = home / "models_cache.json"
provider = "ai_proxy"
default_model = "qwen3.7-plus"

specs = [
    ("qwen3.7-plus", "Qwen 3.7 Plus", "high", ["low", "medium", "high", "xhigh"], ["text", "image"], "Recommended Aliyun Coding Plan model with image understanding."),
    ("qwen3.6-plus", "Qwen 3.6 Plus", "medium", ["low", "medium", "high"], ["text", "image"], "Recommended Aliyun Coding Plan model with image understanding."),
    ("kimi-k2.5", "Kimi K2.5", "medium", ["low", "medium", "high"], ["text"], "Recommended Aliyun Coding Plan model."),
    ("glm-5", "GLM 5", "medium", ["low", "medium", "high"], ["text"], "Recommended Aliyun Coding Plan model."),
    ("MiniMax-M2.5", "MiniMax M2.5", "medium", ["low", "medium", "high"], ["text"], "Recommended Aliyun Coding Plan model."),
    ("qwen3.5-plus", "Qwen 3.5 Plus", "medium", ["low", "medium", "high"], ["text", "image"], "Aliyun Coding Plan model with image understanding."),
    ("qwen3-max-2026-01-23", "Qwen 3 Max 2026-01-23", "high", ["low", "medium", "high", "xhigh"], ["text"], "Aliyun Coding Plan model."),
    ("qwen3-coder-next", "Qwen 3 Coder Next", "high", ["low", "medium", "high", "xhigh"], ["text"], "Aliyun Coding Plan coding model."),
    ("qwen3-coder-plus", "Qwen 3 Coder Plus", "high", ["low", "medium", "high", "xhigh"], ["text"], "Aliyun Coding Plan coding model."),
    ("glm-4.7", "GLM 4.7", "medium", ["low", "medium", "high"], ["text"], "Aliyun Coding Plan model."),
]

reasoning_descriptions = {
    "low": "Fast responses with lighter reasoning",
    "medium": "Balanced speed and reasoning",
    "high": "Deeper reasoning for coding tasks",
    "xhigh": "Extra reasoning depth",
}


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(errors="replace"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def existing_models_by_slug() -> dict[str, dict]:
    by_slug: dict[str, dict] = {}
    for path in (catalog_path, cache_path):
        for item in read_json(path).get("models", []):
            if isinstance(item, dict) and isinstance(item.get("slug"), str):
                by_slug[item["slug"]] = item
    return by_slug


def normalize_model(existing: dict, slug: str, display: str, default_reasoning: str, levels: list[str], modalities: list[str], description: str) -> dict:
    model = dict(existing)
    model.update(
        {
            "slug": slug,
            "display_name": display,
            "displayName": display,
            "description": description,
            "base_instructions": model.get("base_instructions")
            or "You are Codex, a coding agent. Work pragmatically, verify changes, and be concise.",
            "supports_reasoning_summaries": False,
            "support_verbosity": False,
            "provider": provider,
            "model_provider": provider,
            "hidden": False,
            "visibility": "list",
            "supported_in_api": True,
            "default_reasoning_level": default_reasoning,
            "supported_reasoning_levels": [
                {"effort": effort, "description": reasoning_descriptions.get(effort, effort)}
                for effort in levels
            ],
            "shell_type": "shell_command",
            "priority": next(i for i, item in enumerate(specs) if item[0] == slug),
            "additional_speed_tiers": [],
            "service_tiers": [],
            "availability_nux": None,
            "upgrade": None,
            "model_messages": {
                "instructions_template": "You are Codex, a coding agent. Work pragmatically, verify changes, and be concise.\n\n{{ personality }}",
                "default_personality": "You are pragmatic, direct, and careful.",
            },
            "default_reasoning_summary": "none",
            "default_verbosity": "low",
            "apply_patch_tool_type": "freeform",
            "web_search_tool_type": "text_and_image",
            "truncation_policy": {"mode": "tokens", "limit": 10000},
            "supports_parallel_tool_calls": True,
            "supports_image_detail_original": True,
            "context_window": 131000,
            "max_context_window": 131000,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": modalities,
            "supports_search_tool": False,
            "use_responses_lite": False,
        }
    )
    return model


def set_top_level_catalog_line(text: str) -> str:
    if not text:
        return f'model = "{default_model}"\nmodel_provider = "{provider}"\nmodel_catalog_json = "{catalog_path}"\n'
    lines = text.splitlines()
    out: list[str] = []
    in_table = False
    seen = False
    inserted = False
    catalog_line = f'model_catalog_json = "{catalog_path}"'
    for line in lines:
        stripped = line.strip()
        if not in_table and stripped.startswith("[") and not inserted:
            if not seen:
                out.append(catalog_line)
                seen = True
            inserted = True
            in_table = True
        if not in_table and stripped.startswith("model_catalog_json"):
            if not seen:
                out.append(catalog_line)
                seen = True
            continue
        out.append(line)
        if not in_table and stripped.startswith("model_provider") and not seen:
            out.append(catalog_line)
            seen = True
            inserted = True
    if not seen:
        out.append(catalog_line)
    return "\n".join(out) + "\n"


existing = existing_models_by_slug()
models = [normalize_model(existing.get(slug, {}), slug, display, default_reasoning, levels, modalities, description) for slug, display, default_reasoning, levels, modalities, description in specs]
catalog = {"models": models}
old_cache = read_json(cache_path)
cache = {
    "fetched_at": old_cache.get("fetched_at") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "etag": "local-qwen-ai-proxy",
    "client_version": "local-qwen-ai-proxy",
    "models": models,
}

new_texts: dict[Path, str] = {
    catalog_path: json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
    cache_path: json.dumps(cache, ensure_ascii=False, indent=2) + "\n",
}
if config_path.exists():
    new_texts[config_path] = set_top_level_catalog_line(config_path.read_text(errors="replace"))

changed = []
for path, new_text in new_texts.items():
    try:
        old_text = path.read_text(errors="replace")
    except OSError:
        old_text = ""
    if old_text != new_text:
        changed.append((path, old_text, new_text))

if changed:
    backup_dir = home / "recovery-backups" / f"account1-model-catalog-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    backup_dir.mkdir(parents=True, exist_ok=True)
    for path, old_text, _ in changed:
        if path.exists():
            shutil.copy2(path, backup_dir / path.name)
        elif old_text:
            (backup_dir / path.name).write_text(old_text)
    for path, _, new_text in changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new_text)
PY
}

backup_config_once() {
  local home_dir="$1"
  local reason="$2"
  local config_file="$home_dir/config.toml"
  [[ -f "$config_file" ]] || return 0
  local backup_dir="$home_dir/recovery-backups/$reason-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp -p "$config_file" "$backup_dir/config.toml" 2>/dev/null || true
}

preferred_openai_model_for_home() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  local cache_file="$home_dir/models_cache.json"
  local codex_bin="$CODEX_APP/Contents/Resources/codex"
  local current_model current_provider selected

  if [[ -f "$config_file" ]]; then
    current_model="$(awk '
      BEGIN { in_table = 0 }
      /^\[/ { in_table = 1 }
      in_table == 0 && /^model[[:space:]]*=/ {
        value = $0
        sub(/^[^=]*=[[:space:]]*"/, "", value)
        sub(/"[[:space:]]*$/, "", value)
        print value
        exit
      }
    ' "$config_file" 2>/dev/null || true)"
    current_provider="$(awk '
      BEGIN { in_table = 0 }
      /^\[/ { in_table = 1 }
      in_table == 0 && /^model_provider[[:space:]]*=/ {
        value = $0
        sub(/^[^=]*=[[:space:]]*"/, "", value)
        sub(/"[[:space:]]*$/, "", value)
        print value
        exit
      }
    ' "$config_file" 2>/dev/null || true)"
    if [[ "$current_provider" == "openai" && "$current_model" =~ '^gpt-[A-Za-z0-9._:-]+$' ]]; then
      printf '%s\n' "$current_model"
      return 0
    fi
  fi

  if command -v jq >/dev/null 2>&1 && [[ -f "$cache_file" ]]; then
    selected="$(jq -r '
      [.models[]?
        | select((.visibility // "list") != "hide")
        | select((.slug // "") | startswith("gpt-"))]
      | sort_by(.priority // 9999)
      | (.[0].slug // empty)
    ' "$cache_file" 2>/dev/null || true)"
    if [[ "$selected" =~ '^[A-Za-z0-9._:-]+$' ]]; then
      printf '%s\n' "$selected"
      return 0
    fi
  fi

  if command -v jq >/dev/null 2>&1 && [[ -x "$codex_bin" ]]; then
    selected="$(CODEX_HOME="$home_dir" "$codex_bin" debug models --bundled 2>/dev/null | jq -r '
      [.models[]?
        | select((.visibility // "list") != "hide")
        | select((.slug // "") | startswith("gpt-"))]
      | sort_by(.priority // 9999)
      | (.[0].slug // empty)
    ' 2>/dev/null || true)"
    if [[ "$selected" =~ '^[A-Za-z0-9._:-]+$' ]]; then
      printf '%s\n' "$selected"
      return 0
    fi
  fi

  return 1
}

preferred_openai_reasoning_effort_for_home() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  local effort

  [[ -f "$config_file" ]] || return 1
  effort="$(awk '
    BEGIN { in_table = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && /^model_reasoning_effort[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/"[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$config_file" 2>/dev/null || true)"

  if [[ "$effort" =~ '^(none|minimal|low|medium|high|xhigh|max|ultra)$' ]]; then
    printf '%s\n' "$effort"
    return 0
  fi
  return 1
}

clear_top_level_model_config() {
  local config_file="$1"
  local tmp_file="$config_file.codex-accounts.$$"

  awk '
    BEGIN { in_table = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && /^(model|model_provider|model_catalog_json)[[:space:]]*=/ { next }
    { print }
  ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
  rm -f "$tmp_file" 2>/dev/null || true
}

configure_account1_aliyun_proxy_for_home() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  is_primary_codex_home "$home_dir" || return 0
  [[ -f "$config_file" ]] || return 0

  if ! awk '
    BEGIN { in_table = 0; ok_model = 0; ok_provider = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && $0 == "model = \"qwen3.7-plus\"" { ok_model = 1 }
    in_table == 0 && $0 == "model_provider = \"ai_proxy\"" { ok_provider = 1 }
    END { exit (ok_model && ok_provider) ? 0 : 1 }
  ' "$config_file" >/dev/null 2>&1; then
    backup_config_once "$home_dir" "account1-ai-proxy-config"
  fi
  write_top_level_model_config "$config_file" "qwen3.7-plus" "ai_proxy"
  ensure_ai_proxy_provider_config "$config_file"
  ensure_account1_model_catalog_for_home "$home_dir"
}

restore_non_account1_openai_config_for_home() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  is_primary_codex_home "$home_dir" && return 0
  [[ -f "$config_file" ]] || return 0

  if ! awk -v wanted_model="$CODEX_DEFAULT_OPENAI_MODEL" -v wanted_effort="$CODEX_DEFAULT_OPENAI_REASONING_EFFORT" '
    BEGIN { in_table = 0; ok_model = 0; ok_provider = 0; ok_effort = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && $0 == "model = \"" wanted_model "\"" { ok_model = 1 }
    in_table == 0 && $0 == "model_provider = \"openai\"" { ok_provider = 1 }
    in_table == 0 && $0 == "model_reasoning_effort = \"" wanted_effort "\"" { ok_effort = 1 }
    END { exit (ok_model && ok_provider && ok_effort) ? 0 : 1 }
  ' "$config_file" >/dev/null 2>&1; then
    backup_config_once "$home_dir" "openai-default-model"
  fi
  write_top_level_model_config "$config_file" "$CODEX_DEFAULT_OPENAI_MODEL" "openai" "$CODEX_DEFAULT_OPENAI_REASONING_EFFORT"
}

home_uses_account1_ai_proxy() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  is_primary_codex_home "$home_dir" || return 1
  [[ -f "$config_file" ]] || return 1
  awk '
    BEGIN { in_table = 0; found = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && $0 == "model_provider = \"ai_proxy\"" { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$config_file" >/dev/null 2>&1
}

home_uses_opencodex_proxy() {
  local home_dir="$1"
  [[ "${home_dir:A}" == "${OPENCODEX_LAB_CODEX_HOME:A}" ]]
}

# This is deliberately separate from home_uses_opencodex_proxy(): ordinary
# managed profiles only route model requests through the shared loopback proxy.
# They keep their own auth and their existing private/shared history mode.
profile_uses_opencodex_routing() {
  local home_dir="$1"
  is_primary_codex_home "$home_dir" && return 1
  home_uses_opencodex_proxy "$home_dir" && return 1

  OPENCODEX_ROUTE_HOME="$home_dir" \
  OPENCODEX_ROUTE_ACCOUNTS_ROOT="$ACCOUNTS_ROOT" \
  OPENCODEX_ROUTE_SECOND_HOME="$SECOND_CODEX_HOME" \
  python3 - <<'PY' >/dev/null 2>&1
import os
from pathlib import Path

home = Path(os.environ["OPENCODEX_ROUTE_HOME"]).expanduser()
accounts_root = Path(os.environ["OPENCODEX_ROUTE_ACCOUNTS_ROOT"]).expanduser()
second_home = Path(os.environ["OPENCODEX_ROUTE_SECOND_HOME"]).expanduser()
if home.is_symlink():
    raise SystemExit(1)
resolved = home.resolve(strict=False)
if resolved == second_home.resolve(strict=False):
    raise SystemExit(0)
try:
    relative = resolved.relative_to(accounts_root.resolve(strict=False))
except ValueError:
    raise SystemExit(1)
if len(relative.parts) != 1 or relative.name.startswith(".") or relative.name == "opencodex-lab":
    raise SystemExit(1)
PY
}

profile_has_user_owned_model_routing() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  local marker_file="$home_dir/$OPENCODEX_PROFILE_ROUTE_MARKER"

  OPENCODEX_ROUTE_CONFIG="$config_file" \
  OPENCODEX_ROUTE_MARKER="$marker_file" \
  OPENCODEX_ROUTE_OWNER="$OPENCODEX_PROFILE_ROUTE_OWNER" \
  python3 - <<'PY' >/dev/null 2>&1
import ast
import json
import os
import re
from pathlib import Path

config_path = Path(os.environ["OPENCODEX_ROUTE_CONFIG"])
marker_path = Path(os.environ["OPENCODEX_ROUTE_MARKER"])
owner = os.environ["OPENCODEX_ROUTE_OWNER"]

# Fail preserve: an invalid or linked file must never be treated as safe for an
# automatic model/provider rewrite.
if config_path.is_symlink() or marker_path.is_symlink():
    raise SystemExit(0)

lines = config_path.read_text(encoding="utf-8-sig", errors="strict").splitlines() if config_path.exists() else []
assignments = {"openai_base_url": [], "model_catalog_json": [], "model_provider": []}
for line in lines:
    stripped = line.strip()
    if stripped.startswith("["):
        break
    match = re.match(r"^(openai_base_url|model_catalog_json|model_provider)\s*=\s*(.+?)\s*$", stripped)
    if not match:
        continue
    try:
        value = ast.literal_eval(match.group(2))
    except (SyntaxError, ValueError):
        raise SystemExit(0)
    assignments[match.group(1)].append(value)

provider_values = assignments["model_provider"]
custom_provider = bool(provider_values) and (len(provider_values) != 1 or provider_values[0] != "openai")

if not marker_path.exists():
    user_owned = bool(assignments["openai_base_url"] or assignments["model_catalog_json"] or custom_provider)
    raise SystemExit(0 if user_owned else 1)
if not marker_path.is_file():
    raise SystemExit(0)
try:
    marker = json.loads(marker_path.read_text(encoding="utf-8-sig"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
if (
    not isinstance(marker, dict)
    or marker.get("owner") != owner
    or not isinstance(marker.get("openai_base_url"), str)
    or not isinstance(marker.get("model_catalog_json"), str)
):
    raise SystemExit(0)

managed_route_matches = all(
    len(assignments[key]) == 1 and assignments[key][0] == marker[key]
    for key in ("openai_base_url", "model_catalog_json")
)
raise SystemExit(1 if managed_route_matches and not custom_provider else 0)
PY
}

configure_opencodex_routing_for_home() {
  local home_dir="$1"
  local url base_url
  profile_uses_opencodex_routing "$home_dir" || {
    echo "Refusing OpenCodex routing for an unmanaged profile: $home_dir" >&2
    return 1
  }
  [[ -d "$home_dir" && ! -L "$home_dir" ]] || {
    echo "Refusing missing or linked Codex profile: $home_dir" >&2
    return 1
  }
  url="$(opencodex_running_url 2>/dev/null || true)"
  [[ "$url" =~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/$' ]] || {
    echo "OpenCodex is not running on a verified loopback URL." >&2
    return 1
  }
  base_url="${url%/}/v1"

  OPENCODEX_ROUTE_HOME="$home_dir" \
  OPENCODEX_ROUTE_CONFIG="$home_dir/config.toml" \
  OPENCODEX_ROUTE_MARKER="$home_dir/$OPENCODEX_PROFILE_ROUTE_MARKER" \
  OPENCODEX_ROUTE_OWNER="$OPENCODEX_PROFILE_ROUTE_OWNER" \
  OPENCODEX_ROUTE_BASE_URL="$base_url" \
  OPENCODEX_ROUTE_CATALOG="$OPENCODEX_SHARED_CATALOG" \
  python3 - <<'PY'
import ast
import json
import os
import re
import stat
import tempfile
from pathlib import Path

home = Path(os.environ["OPENCODEX_ROUTE_HOME"])
config_path = Path(os.environ["OPENCODEX_ROUTE_CONFIG"])
marker_path = Path(os.environ["OPENCODEX_ROUTE_MARKER"])
owner = os.environ["OPENCODEX_ROUTE_OWNER"]
base_url = os.environ["OPENCODEX_ROUTE_BASE_URL"]
catalog_path = Path(os.environ["OPENCODEX_ROUTE_CATALOG"])

for path, label in ((config_path, "config"), (marker_path, "route marker"), (catalog_path, "catalog")):
    if path.is_symlink():
        raise SystemExit(f"Refusing OpenCodex {label} symlink: {path}")
if not catalog_path.is_absolute() or not catalog_path.is_file():
    raise SystemExit(f"OpenCodex shared catalog is unavailable: {catalog_path}")

def parse_value(raw: str, key: str) -> str:
    try:
        value = ast.literal_eval(raw)
    except (SyntaxError, ValueError):
        raise SystemExit(f"Invalid top-level {key} in {config_path}")
    if not isinstance(value, str):
        raise SystemExit(f"Top-level {key} must be a string in {config_path}")
    return value

lines = config_path.read_text(encoding="utf-8-sig", errors="strict").splitlines() if config_path.exists() else []
assignments: dict[str, list[tuple[int, str]]] = {
    "openai_base_url": [],
    "model_catalog_json": [],
    "model_provider": [],
}
for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("["):
        break
    match = re.match(r"^(openai_base_url|model_catalog_json|model_provider)\s*=\s*(.+?)\s*$", stripped)
    if match:
        assignments[match.group(1)].append((index, parse_value(match.group(2), match.group(1))))

old_route = None
if marker_path.exists():
    try:
        candidate = json.loads(marker_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Invalid OpenCodex route marker; refusing to overwrite profile config: {exc}")
    if (
        not isinstance(candidate, dict)
        or candidate.get("owner") != owner
        or not isinstance(candidate.get("openai_base_url"), str)
        or not isinstance(candidate.get("model_catalog_json"), str)
    ):
        raise SystemExit("Unrecognized OpenCodex route marker; refusing to overwrite profile config")
    old_route = candidate

provider_values = assignments["model_provider"]
custom_provider = bool(provider_values) and (
    len(provider_values) != 1 or provider_values[0][1] != "openai"
)

if old_route is None:
    if assignments["openai_base_url"] or assignments["model_catalog_json"] or custom_provider:
        print(f"Keeping user-owned OpenCodex routing in {home}", file=os.sys.stderr)
        raise SystemExit(0)
else:
    expected_old = {
        "openai_base_url": old_route["openai_base_url"],
        "model_catalog_json": old_route["model_catalog_json"],
    }
    if custom_provider or any(
        len(assignments[key]) != 1 or assignments[key][0][1] != expected_old[key]
        for key in ("openai_base_url", "model_catalog_json")
    ):
        print(f"Keeping user-modified OpenCodex routing in {home}", file=os.sys.stderr)
        raise SystemExit(0)

new_values = {"openai_base_url": base_url, "model_catalog_json": str(catalog_path)}
if old_route is None:
    insertion = next((i for i, line in enumerate(lines) if line.strip().startswith("[")), len(lines))
    route_lines = [
        f'openai_base_url = {json.dumps(base_url)}',
        f'model_catalog_json = {json.dumps(str(catalog_path))}',
    ]
    if insertion > 0 and lines[insertion - 1].strip():
        route_lines.append("")
    lines[insertion:insertion] = route_lines
else:
    for key, value in new_values.items():
        index = assignments[key][0][0]
        lines[index] = f'{key} = {json.dumps(value)}'

config_text = "\n".join(lines) + "\n"
config_mode = stat.S_IMODE(config_path.stat().st_mode) if config_path.exists() else 0o600
fd, tmp_name = tempfile.mkstemp(prefix=".config.toml.", suffix=".tmp", dir=home)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(config_text)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, config_mode)
    os.replace(tmp_name, config_path)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass

marker = {"owner": owner, **new_values}
fd, tmp_name = tempfile.mkstemp(prefix=f".{marker_path.name}.", suffix=".tmp", dir=home)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(marker, handle, ensure_ascii=False, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, marker_path)
    dir_fd = os.open(home, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
PY
}

prepare_opencodex_cli_wrapper() {
  local url base_url real_codex

  validate_opencodex_lab_paths || return 1
  selected_codex_app_is_usable || {
    report_missing_codex_app
    return 1
  }
  url="$(opencodex_running_url 2>/dev/null || true)"
  [[ "$url" =~ '^http://(127[.]0[.]0[.]1|localhost):[0-9]+/$' ]] || {
    echo "OpenCodex is not running on a verified loopback URL." >&2
    return 1
  }
  base_url="${url%/}/v1"
  real_codex="$CODEX_APP/Contents/Resources/codex"

  OPENCODEX_WRAPPER_ROOT="$OPENCODEX_ROOT" \
  OPENCODEX_WRAPPER_ROOT_MARKER="$OPENCODEX_ROOT/$OPENCODEX_OWNERSHIP_MARKER" \
  OPENCODEX_WRAPPER_ROOT_OWNER="$OPENCODEX_OWNERSHIP_VALUE" \
  OPENCODEX_WRAPPER_DIR="$OPENCODEX_CLI_WRAPPER_DIR" \
  OPENCODEX_WRAPPER_PATH="$OPENCODEX_CLI_WRAPPER" \
  OPENCODEX_WRAPPER_OWNER="$OPENCODEX_CLI_WRAPPER_OWNER" \
  OPENCODEX_WRAPPER_LAB_HOME="$OPENCODEX_LAB_CODEX_HOME" \
  OPENCODEX_WRAPPER_CATALOG="$OPENCODEX_SHARED_CATALOG" \
  OPENCODEX_WRAPPER_CODEX_APP="$CODEX_APP" \
  OPENCODEX_WRAPPER_REAL_CODEX="$real_codex" \
  OPENCODEX_WRAPPER_BASE_URL="$base_url" \
  OPENCODEX_WRAPPER_MODEL="$CODEX_DEFAULT_OPENAI_MODEL" \
  OPENCODEX_WRAPPER_EFFORT="$CODEX_DEFAULT_OPENAI_REASONING_EFFORT" \
  python3 - <<'PY'
import json
import os
import shlex
import stat
import tempfile
from pathlib import Path

root = Path(os.environ["OPENCODEX_WRAPPER_ROOT"]).expanduser()
root_marker = Path(os.environ["OPENCODEX_WRAPPER_ROOT_MARKER"]).expanduser()
root_owner = os.environ["OPENCODEX_WRAPPER_ROOT_OWNER"]
wrapper_dir = Path(os.environ["OPENCODEX_WRAPPER_DIR"]).expanduser()
wrapper = Path(os.environ["OPENCODEX_WRAPPER_PATH"]).expanduser()
owner = os.environ["OPENCODEX_WRAPPER_OWNER"]
lab_home = Path(os.environ["OPENCODEX_WRAPPER_LAB_HOME"]).expanduser()
catalog = Path(os.environ["OPENCODEX_WRAPPER_CATALOG"]).expanduser()
codex_app = Path(os.environ["OPENCODEX_WRAPPER_CODEX_APP"]).expanduser()
real_codex = Path(os.environ["OPENCODEX_WRAPPER_REAL_CODEX"]).expanduser()
base_url = os.environ["OPENCODEX_WRAPPER_BASE_URL"]
model = os.environ["OPENCODEX_WRAPPER_MODEL"]
effort = os.environ["OPENCODEX_WRAPPER_EFFORT"]

for path, label in (
    (root, "managed root"),
    (root_marker, "ownership marker"),
    (lab_home, "Lab home"),
    (catalog, "catalog"),
    (codex_app, "Codex app"),
    (codex_app / "Contents", "Codex Contents"),
    (codex_app / "Contents" / "Resources", "Codex Resources"),
    (real_codex, "Codex CLI"),
):
    if path.is_symlink():
        raise SystemExit(f"Refusing OpenCodex wrapper {label} symlink: {path}")

if not root.is_absolute() or not root.is_dir():
    raise SystemExit(f"OpenCodex managed root is unavailable: {root}")
if not root_marker.is_file() or root_marker.read_text(encoding="utf-8").strip() != root_owner:
    raise SystemExit("OpenCodex managed root ownership verification failed")
if not lab_home.is_absolute() or not lab_home.is_dir():
    raise SystemExit(f"OpenCodex Lab home is unavailable: {lab_home}")
if not catalog.is_absolute() or not catalog.is_file():
    raise SystemExit(f"OpenCodex shared catalog is unavailable: {catalog}")
try:
    catalog.resolve(strict=True).relative_to(lab_home.resolve(strict=True))
except ValueError:
    raise SystemExit(f"Refusing OpenCodex catalog outside Lab home: {catalog}")

if not codex_app.is_absolute() or not codex_app.is_dir():
    raise SystemExit(f"Codex app is unavailable: {codex_app}")
expected_real_codex = codex_app / "Contents" / "Resources" / "codex"
if os.path.abspath(real_codex) != os.path.abspath(expected_real_codex):
    raise SystemExit(f"Refusing unexpected Codex CLI path: {real_codex}")
if not real_codex.is_file() or not os.access(real_codex, os.X_OK):
    raise SystemExit(f"Codex CLI is unavailable: {real_codex}")
if real_codex.resolve(strict=True) != expected_real_codex.resolve(strict=True):
    raise SystemExit(f"Refusing Codex CLI path escape: {real_codex}")

expected_wrapper_dir = root / "bin"
expected_wrapper = expected_wrapper_dir / "codex-opencodex-router"
if os.path.abspath(wrapper_dir) != os.path.abspath(expected_wrapper_dir):
    raise SystemExit(f"Refusing unexpected OpenCodex wrapper directory: {wrapper_dir}")
if os.path.abspath(wrapper) != os.path.abspath(expected_wrapper):
    raise SystemExit(f"Refusing unexpected OpenCodex wrapper path: {wrapper}")
if wrapper_dir.is_symlink() or wrapper.is_symlink():
    raise SystemExit("Refusing OpenCodex wrapper symlink path")
if wrapper_dir.exists() and not wrapper_dir.is_dir():
    raise SystemExit(f"OpenCodex wrapper directory is not a directory: {wrapper_dir}")
if wrapper.exists():
    if not wrapper.is_file():
        raise SystemExit(f"OpenCodex wrapper target is not a regular file: {wrapper}")
    with wrapper.open("r", encoding="utf-8", errors="strict") as handle:
        if f"# {owner}" not in handle.read(4096):
            raise SystemExit(f"Refusing to overwrite an unrecognized OpenCodex wrapper: {wrapper}")

wrapper_dir.mkdir(mode=0o700, parents=False, exist_ok=True)
if wrapper_dir.is_symlink() or wrapper_dir.resolve(strict=True).parent != root.resolve(strict=True):
    raise SystemExit(f"Refusing OpenCodex wrapper directory path escape: {wrapper_dir}")
os.chmod(wrapper_dir, 0o700)

def toml_override(key: str, value: str) -> str:
    return f"{key}={json.dumps(value, ensure_ascii=True)}"

overrides = [
    toml_override("model", model),
    toml_override("model_provider", "openai"),
    toml_override("model_reasoning_effort", effort),
    toml_override("openai_base_url", base_url),
    toml_override("model_catalog_json", str(catalog)),
]
script_lines = [
    "#!/bin/zsh",
    f"# {owner}",
    "set -eu",
    f"codex_app={shlex.quote(str(codex_app))}",
    f"real_codex={shlex.quote(str(real_codex))}",
    f"lab_home={shlex.quote(str(lab_home))}",
    f"catalog={shlex.quote(str(catalog))}",
    f"base_url={shlex.quote(base_url)}",
    '[[ -d "$codex_app" && ! -L "$codex_app" ]] || exit 126',
    '[[ ! -L "$codex_app/Contents" && ! -L "$codex_app/Contents/Resources" ]] || exit 126',
    '[[ -f "$real_codex" && -x "$real_codex" && ! -L "$real_codex" ]] || exit 126',
    '[[ "$real_codex" == /*/Contents/Resources/codex ]] || exit 126',
    '[[ "${real_codex:A}" == "${codex_app:A}/Contents/Resources/codex" ]] || exit 126',
    '[[ -d "$lab_home" && ! -L "$lab_home" ]] || exit 126',
    '[[ -f "$catalog" && ! -L "$catalog" ]] || exit 126',
    '[[ "${catalog:A}" == "${lab_home:A}/"* ]] || exit 126',
    '[[ "$base_url" =~ \'^http://(127[.]0[.]0[.]1|localhost):[0-9]+/v1$\' ]] || exit 126',
    'exec "$real_codex" \\',
]
script_lines.extend(f"  -c {shlex.quote(value)} \\" for value in overrides)
script_lines.append('  "$@"')
script = "\n".join(script_lines) + "\n"

fd, tmp_name = tempfile.mkstemp(prefix=f".{wrapper.name}.", suffix=".tmp", dir=wrapper_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(script)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o700)
    os.replace(tmp_name, wrapper)
    dir_fd = os.open(wrapper_dir, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass

if wrapper.is_symlink() or not wrapper.is_file() or stat.S_IMODE(wrapper.stat().st_mode) != 0o700:
    raise SystemExit("OpenCodex wrapper verification failed")
print(wrapper)
PY
}

remove_opencodex_routing_for_home() {
  local home_dir="$1"
  profile_uses_opencodex_routing "$home_dir" || return 0
  [[ -d "$home_dir" && ! -L "$home_dir" ]] || return 0

  OPENCODEX_ROUTE_HOME="$home_dir" \
  OPENCODEX_ROUTE_CONFIG="$home_dir/config.toml" \
  OPENCODEX_ROUTE_MARKER="$home_dir/$OPENCODEX_PROFILE_ROUTE_MARKER" \
  OPENCODEX_ROUTE_OWNER="$OPENCODEX_PROFILE_ROUTE_OWNER" \
  python3 - <<'PY'
import ast
import json
import os
import re
import stat
import tempfile
from pathlib import Path

home = Path(os.environ["OPENCODEX_ROUTE_HOME"])
config_path = Path(os.environ["OPENCODEX_ROUTE_CONFIG"])
marker_path = Path(os.environ["OPENCODEX_ROUTE_MARKER"])
owner = os.environ["OPENCODEX_ROUTE_OWNER"]
if not marker_path.exists():
    raise SystemExit(0)
if marker_path.is_symlink() or config_path.is_symlink():
    raise SystemExit(f"Refusing linked OpenCodex route files in {home}")
try:
    marker = json.loads(marker_path.read_text(encoding="utf-8-sig"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Invalid OpenCodex route marker; leaving profile unchanged: {exc}")
if (
    not isinstance(marker, dict)
    or marker.get("owner") != owner
    or not isinstance(marker.get("openai_base_url"), str)
    or not isinstance(marker.get("model_catalog_json"), str)
):
    raise SystemExit("Unrecognized OpenCodex route marker; leaving profile unchanged")

if config_path.exists():
    lines = config_path.read_text(encoding="utf-8-sig", errors="strict").splitlines()
    assignments: dict[str, list[tuple[int, object]]] = {"openai_base_url": [], "model_catalog_json": []}
    in_table = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("["):
            in_table = True
        match = None if in_table else re.match(r"^(openai_base_url|model_catalog_json)\s*=\s*(.+?)\s*$", stripped)
        if match:
            try:
                value = ast.literal_eval(match.group(2))
            except (SyntaxError, ValueError):
                value = None
            assignments[match.group(1)].append((index, value))
    owned_indices = {
        entries[0][0]
        for key, entries in assignments.items()
        if len(entries) == 1 and isinstance(entries[0][1], str) and entries[0][1] == marker.get(key)
    }
    changed = bool(owned_indices)
    if changed:
        out = [line for index, line in enumerate(lines) if index not in owned_indices]
        text = "\n".join(out) + "\n"
        mode = stat.S_IMODE(config_path.stat().st_mode)
        fd, tmp_name = tempfile.mkstemp(prefix=".config.toml.", suffix=".tmp", dir=home)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_name, mode)
            os.replace(tmp_name, config_path)
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
marker_path.unlink()
PY
}

remove_all_opencodex_profile_routes() {
  local raw_name raw_home raw_app_data name home_dir route_status=0
  while IFS='|' read -r raw_name raw_home raw_app_data; do
    name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    home_dir="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$name" && -n "$home_dir" ]] || continue
    profile_uses_opencodex_routing "$home_dir" || continue
    remove_opencodex_routing_for_home "$home_dir" || route_status=$?
  done < <(list_accounts)
  return "$route_status"
}

ensure_opencodex_available_for_profiles() {
  local installed_version
  installed_version="$(opencodex_installed_version 2>/dev/null || true)"
  if [[ "$installed_version" != "$OPENCODEX_VERSION" ]]; then
    if ! opencodex_install >/dev/null; then
      remove_all_opencodex_profile_routes >/dev/null 2>&1 || true
      return 1
    fi
  fi
  if ! opencodex_start >/dev/null; then
    remove_all_opencodex_profile_routes >/dev/null 2>&1 || true
    return 1
  fi
}

opencodex_enable_all_profiles() {
  local raw_name raw_home raw_app_data name home_dir configured=0 failed=0
  ensure_dirs
  ensure_opencodex_available_for_profiles || return 1
  prepare_opencodex_cli_wrapper >/dev/null || return 1
  while IFS='|' read -r raw_name raw_home raw_app_data; do
    name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    home_dir="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$name" && -d "$home_dir" ]] || continue
    profile_uses_opencodex_routing "$home_dir" || continue
    if configure_opencodex_routing_for_home "$home_dir"; then
      if [[ -f "$home_dir/$OPENCODEX_PROFILE_ROUTE_MARKER" ]] \
        && ! profile_has_user_owned_model_routing "$home_dir"; then
        configured=$(( configured + 1 ))
      fi
    else
      failed=$(( failed + 1 ))
    fi
  done < <(list_accounts)
  if (( failed > 0 )); then
    echo "OpenCodex routing failed for $failed managed profile(s)." >&2
    return 1
  fi
  echo "OpenCodex routing is enabled for $configured managed profile(s)."
}

ensure_aliyun_coding_plan_bridge_running() {
  local health_url="http://${ALIYUN_CODING_PLAN_BRIDGE_HOST}:${ALIYUN_CODING_PLAN_BRIDGE_PORT}/health"
  local server_js="$ALIYUN_CODING_PLAN_BRIDGE_ROOT/node_modules/aliyun-codex-bridge/src/server.js"
  local log_dir="$APP_DATA_ROOT/.logs"
  local log_file="$log_dir/aliyun-codex-bridge.log"
  local node_bin npm_bin tool_path bridge_pid

  curl -fsS "$health_url" >/dev/null 2>&1 && return 0
  load_aliyun_coding_plan_key
  if [[ -z "${AI_API_KEY:-}" ]]; then
    echo "Missing Aliyun Coding Plan key: AI_API_KEY/DASHSCOPE_API_KEY is not set." >&2
    return 1
  fi
  node_bin="$(resolve_node_bin 2>/dev/null || true)"
  if [[ -z "$node_bin" ]]; then
    echo "node is required to start aliyun-codex-bridge." >&2
    return 1
  fi
  if [[ ! -f "$server_js" ]]; then
    npm_bin="$(resolve_npm_bin 2>/dev/null || true)"
    if [[ -z "$npm_bin" ]]; then
      echo "npm is required to install aliyun-codex-bridge." >&2
      return 1
    fi
    mkdir -p "$ALIYUN_CODING_PLAN_BRIDGE_ROOT"
    tool_path="$(dirname "$node_bin"):$(dirname "$npm_bin"):${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
    PATH="$tool_path" "$npm_bin" install --prefix "$ALIYUN_CODING_PLAN_BRIDGE_ROOT" "aliyun-codex-bridge@$ALIYUN_CODING_PLAN_BRIDGE_VERSION" >/dev/null
  fi
  if [[ ! -f "$server_js" ]]; then
    echo "aliyun-codex-bridge server.js was not found after install." >&2
    return 1
  fi
  mkdir -p "$log_dir"
  nohup env \
    AI_API_KEY="$AI_API_KEY" \
    AI_API_BASE="$ALIYUN_CODING_PLAN_BASE_URL" \
    HOST="$ALIYUN_CODING_PLAN_BRIDGE_HOST" \
    PORT="$ALIYUN_CODING_PLAN_BRIDGE_PORT" \
    LOG_LEVEL="${ALIYUN_CODING_PLAN_BRIDGE_LOG_LEVEL:-warn}" \
    ALLOW_TOOLS=1 \
    SUPPRESS_REASONING_TEXT=1 \
    "$node_bin" "$server_js" >>"$log_file" 2>&1 &
  bridge_pid="$!"
  disown "$bridge_pid" >/dev/null 2>&1 || true
  sleep 0.6
  curl -fsS "$health_url" >/dev/null 2>&1
}

ensure_owl_auth_features_enabled() {
  local app_data="$1"
  local cache_file="$app_data/owl-feature-bootstrap-cache.json"
  local backup_dir backup_file timestamp

  mkdir -p "$app_data"
  [[ -f "$cache_file" ]] || return 0
  if ! grep -q '"disabledOwlFeatureNames"' "$cache_file" && ! grep -q '"OwlAuth"' "$cache_file"; then
    return 0
  fi

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="$app_data/Codex Accounts Backups/owl-feature-cache"
  mkdir -p "$backup_dir"
  backup_file="$backup_dir/owl-feature-bootstrap-cache.$timestamp.json"
  cp -p "$cache_file" "$backup_file" 2>/dev/null || cp "$cache_file" "$backup_file" 2>/dev/null || true
  printf '%s\n' '{"enabledOwlFeatureNames":[]}' > "$cache_file"
}

normalize_thread_sources_for_home() {
  local home_dir="$1"
  local db count timestamp backup_dir

  command -v sqlite3 >/dev/null 2>&1 || return 0
  timestamp="$(date '+%Y%m%d-%H%M%S')"

  for db in "$home_dir/state_5.sqlite" "$home_dir/sqlite/state_5.sqlite"; do
    [[ -f "$db" ]] || continue
    sqlite3 "$db" "
      PRAGMA busy_timeout = 5000;
      DROP TRIGGER IF EXISTS codex_accounts_thread_source_ai;
      DROP TRIGGER IF EXISTS codex_accounts_thread_source_au;
    " >/dev/null 2>&1 || true
    count="$(sqlite3 "$db" "SELECT count(*) FROM threads WHERE archived = 0 AND source = 'vscode' AND (thread_source IS NULL OR thread_source = '');" 2>/dev/null || echo 0)"
    [[ "$count" == <-> ]] || count=0
    (( count > 0 )) || continue

    backup_dir="$home_dir/recovery-backups/thread-source-$timestamp"
    mkdir -p "$backup_dir"
    cp -p "$db" "$backup_dir/$(basename "$db")" 2>/dev/null || true
    [[ -f "$db-wal" ]] && cp -p "$db-wal" "$backup_dir/$(basename "$db")-wal" 2>/dev/null || true
    [[ -f "$db-shm" ]] && cp -p "$db-shm" "$backup_dir/$(basename "$db")-shm" 2>/dev/null || true
    sqlite3 "$db" "UPDATE threads SET thread_source = 'user' WHERE archived = 0 AND source = 'vscode' AND (thread_source IS NULL OR thread_source = '');" >/dev/null 2>&1 || true
  done
}

restore_default_thread_model_providers_for_home() {
  local home_dir="$1"
  local backup_mode="${2:-backup}"
  local db count timestamp backup_dir preferred_model preferred_effort
  local legacy_model_condition reasoning_column_count reasoning_update

  [[ "${CODEX_PRESERVE_TOP_LEVEL_OPENAI_HTTP_PROVIDER:-0}" == "1" ]] && return 0
  is_primary_codex_home "$home_dir" && return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  preferred_model="$(preferred_openai_model_for_home "$home_dir" 2>/dev/null || true)"
  preferred_effort="$(preferred_openai_reasoning_effort_for_home "$home_dir" 2>/dev/null || true)"
  legacy_model_condition=""
  if [[ "$preferred_model" != "gpt-5.5" ]]; then
    legacy_model_condition=" OR COALESCE(model, '') IN ('', 'gpt-5.5')"
  fi

  for db in "$home_dir/state_5.sqlite" "$home_dir/sqlite/state_5.sqlite"; do
    [[ -f "$db" ]] || continue
    sqlite3 "$db" "
      PRAGMA busy_timeout = 5000;
      DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_au;
      DROP TRIGGER IF EXISTS codex_accounts_account1_thread_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_account1_thread_provider_au;
      DROP TRIGGER IF EXISTS codex_accounts_openai_thread_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_openai_thread_provider_au;
    " >/dev/null 2>&1 || true
    [[ "$preferred_model" =~ '^[A-Za-z0-9._:-]+$' ]] || continue
    count="$(sqlite3 "$db" "SELECT count(*) FROM threads WHERE archived = 0 AND (COALESCE(model_provider, '') NOT IN ('', 'openai') OR COALESCE(model, '') LIKE 'qwen%' OR COALESCE(model, '') LIKE 'glm-%' OR COALESCE(model, '') LIKE 'kimi-%' OR COALESCE(model, '') LIKE 'MiniMax-%'$legacy_model_condition);" 2>/dev/null || echo 0)"
    [[ "$count" == <-> ]] || count=0
    (( count > 0 )) || continue

    if [[ "$backup_mode" != "no-backup" ]]; then
      backup_dir="$home_dir/recovery-backups/model-provider-restore-$timestamp"
      mkdir -p "$backup_dir"
      cp -p "$db" "$backup_dir/$(basename "$db")" 2>/dev/null || true
      [[ -f "$db-wal" ]] && cp -p "$db-wal" "$backup_dir/$(basename "$db")-wal" 2>/dev/null || true
      [[ -f "$db-shm" ]] && cp -p "$db-shm" "$backup_dir/$(basename "$db")-shm" 2>/dev/null || true
    fi
    reasoning_column_count="$(sqlite3 "$db" "SELECT count(*) FROM pragma_table_info('threads') WHERE name = 'reasoning_effort';" 2>/dev/null || echo 0)"
    reasoning_update=""
    if [[ "$reasoning_column_count" == "1" && -n "$preferred_effort" ]]; then
      reasoning_update=", reasoning_effort = '$preferred_effort'"
    fi
    sqlite3 "$db" "UPDATE threads SET model_provider = 'openai', model = '$preferred_model'$reasoning_update WHERE archived = 0 AND (COALESCE(model_provider, '') NOT IN ('', 'openai') OR COALESCE(model, '') LIKE 'qwen%' OR COALESCE(model, '') LIKE 'glm-%' OR COALESCE(model, '') LIKE 'kimi-%' OR COALESCE(model, '') LIKE 'MiniMax-%'$legacy_model_condition);" >/dev/null 2>&1 || true
  done
}

restore_account1_visible_thread_model_providers_for_home() {
  local home_dir="$1"
  is_primary_codex_home "$home_dir" || return 0
  [[ -d "$home_dir" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  local db
  for db in "$home_dir/state_5.sqlite" "$home_dir/sqlite/state_5.sqlite"; do
    [[ -f "$db" ]] || continue
    sqlite3 "$db" "
      PRAGMA busy_timeout = 5000;
      DROP TRIGGER IF EXISTS codex_accounts_account1_thread_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_account1_thread_provider_au;
      DROP TRIGGER IF EXISTS codex_accounts_openai_thread_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_openai_thread_provider_au;
    " >/dev/null 2>&1 || true
  done
}

normalize_top_level_model_provider_for_home() {
  local home_dir="$1"
  local config_file="$home_dir/config.toml"
  local timestamp backup_dir tmp_file

  [[ "${CODEX_PRESERVE_TOP_LEVEL_OPENAI_HTTP_PROVIDER:-0}" == "1" ]] && return 0
  [[ -f "$config_file" ]] || return 0
  awk '
    BEGIN { in_table = 0; found = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && $0 == "model_provider = \"openai_http\"" { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$config_file" >/dev/null 2>&1 || return 0

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="$home_dir/recovery-backups/model-provider-config-$timestamp"
  mkdir -p "$backup_dir"
  cp -p "$config_file" "$backup_dir/config.toml" 2>/dev/null || true

  tmp_file="$config_file.codex-accounts.$$"
  awk '
    BEGIN { in_table = 0 }
    /^\[/ { in_table = 1 }
    in_table == 0 && $0 == "model_provider = \"openai_http\"" { next }
    { print }
  ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
  rm -f "$tmp_file" 2>/dev/null || true
}

sync_lock_is_stale() {
  local lock_pid lock_command lock_mtime now lock_age

  lock_pid="$(cat "$SYNC_LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    lock_command="$(ps -p "$lock_pid" -o command= 2>/dev/null || true)"
    if [[ "$lock_command" == *"codex_multi_account.zsh"* ]]; then
      return 1
    fi
  fi

  lock_mtime="$(stat -f '%m' "$SYNC_LOCK_DIR" 2>/dev/null || echo 0)"
  now="$(date '+%s')"
  lock_age=$(( now - lock_mtime ))
  (( lock_age >= ${CODEX_SYNC_STALE_LOCK_SECONDS:-15} ))
}

with_sync_lock() {
  local waited=0
  local max_waits="${CODEX_SYNC_LOCK_MAX_WAITS:-20}"
  local wait_interval="${CODEX_SYNC_LOCK_WAIT_SECONDS:-0.25}"
  while ! mkdir "$SYNC_LOCK_DIR" 2>/dev/null; do
    if sync_lock_is_stale; then
      rm -rf "$SYNC_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if (( waited >= max_waits )); then
      if [[ "${CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT:-0}" == "1" ]]; then
        echo "Sync is still running; refusing to launch until the current sync finishes." >&2
        return 75
      fi
      echo "Sync is already running; continuing with existing synced state." >&2
      return 0
    fi
    sleep "$wait_interval"
    waited=$(( waited + 1 ))
  done
  printf '%s\n' "$$" > "$SYNC_LOCK_DIR/pid" 2>/dev/null || true
  printf '%s\n' "$*" > "$SYNC_LOCK_DIR/command" 2>/dev/null || true

  trap 'rm -rf "$SYNC_LOCK_DIR" 2>/dev/null || true' EXIT
  trap 'rm -rf "$SYNC_LOCK_DIR" 2>/dev/null || true; exit 143' TERM HUP
  trap 'rm -rf "$SYNC_LOCK_DIR" 2>/dev/null || true; exit 130' INT

  local command_status=0
  "$@" || command_status=$?

  rm -rf "$SYNC_LOCK_DIR" 2>/dev/null || true
  trap - EXIT TERM HUP INT
  return "$command_status"
}

sanitize_account_name() {
  local raw="$1"
  local clean=""
  clean="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$clean" ]]; then
    echo "Invalid account name: $raw" >&2
    exit 2
  fi
  printf '%s' "$clean"
}

account_home_for() {
  local name=""
  name="$(sanitize_account_name "$1")"
  if [[ "$name" == "account1" || "$name" == "primary" || "$name" == "default" ]]; then
    printf '%s' "$PRIMARY_CODEX_HOME"
  elif [[ "$name" == "account2" ]]; then
    printf '%s' "$SECOND_CODEX_HOME"
  else
    printf '%s/%s' "$ACCOUNTS_ROOT" "$name"
  fi
}

account_app_data_for() {
  local name=""
  name="$(sanitize_account_name "$1")"
  if [[ "$name" == "account1" || "$name" == "primary" || "$name" == "default" ]]; then
    printf '%s' "$HOME/Library/Application Support/Codex"
  elif [[ "$name" == "account2" ]]; then
    printf '%s' "$SECOND_APP_DATA"
  else
    printf '%s/%s' "$APP_DATA_ROOT" "$name"
  fi
}

history_mode_marker_for_home() {
  local account_home="$1"
  printf '%s/%s\n' "$account_home" "$CODEX_HISTORY_MODE_MARKER_NAME"
}

is_history_anchor_home() {
  local account_home="$1"
  same_resolved_path "$account_home" "$CODEX_HISTORY_ANCHOR_HOME"
}

portable_history_links_point_to_shared() {
  local account_home="$1"
  local item target source

  for item in session_index.jsonl sessions shell_snapshots; do
    target="$account_home/$item"
    source="$(shared_history_source_for_item "$item")"
    [[ -L "$target" ]] || return 1
    same_resolved_path "$target" "$source" || return 1
  done
  return 0
}

# Markerless legacy profiles are only treated as shared when every portable
# history path already points at the shared store. Anything else is private by
# default so an old or partially detached profile is never silently re-linked.
history_mode_for_home() {
  local account_home="$1"
  local marker mode

  if home_uses_opencodex_proxy "$account_home"; then
    printf '%s\n' "private"
    return 0
  fi

  if is_history_anchor_home "$account_home"; then
    printf '%s\n' "shared"
    return 0
  fi

  marker="$(history_mode_marker_for_home "$account_home")"
  if [[ -r "$marker" ]]; then
    IFS= read -r mode < "$marker" || true
    mode="${mode//[[:space:]]/}"
    if [[ "$mode" == "shared" || "$mode" == "private" ]]; then
      printf '%s\n' "$mode"
      return 0
    fi
  fi

  if portable_history_links_point_to_shared "$account_home"; then
    printf '%s\n' "shared"
  else
    printf '%s\n' "private"
  fi
}

set_history_mode_for_home() {
  local account_home="$1" mode="$2"
  local marker tmp_marker

  case "$mode" in
    shared|private) ;;
    *)
      echo "Invalid history mode: $mode" >&2
      return 2
      ;;
  esac

  if home_uses_opencodex_proxy "$account_home" && [[ "$mode" != "private" ]]; then
    echo "OpenCodex Lab history is permanently private." >&2
    return 2
  fi

  mkdir -p "$account_home"
  marker="$(history_mode_marker_for_home "$account_home")"
  if is_history_anchor_home "$account_home"; then
    rm -f "$marker"
    return 0
  fi

  tmp_marker="${marker}.tmp.$$"
  printf '%s\n' "$mode" > "$tmp_marker"
  mv "$tmp_marker" "$marker"
}

history_mode_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "history-mode requires an account name." >&2
    exit 2
  fi
  history_mode_for_home "$(account_home_for "$name")"
}

shared_history_homes() {
  local account_home mode
  for account_home in "$@"; do
    [[ -n "$account_home" ]] || continue
    mode="$(history_mode_for_home "$account_home")"
    [[ "$mode" == "shared" ]] && printf '%s\n' "$account_home"
  done
}

profile_window_is_running() {
  local name="$1"
  local app_data
  app_data="$(account_app_data_for "$name")"
  [[ -n "$(matching_codex_window_pids_for_app_data "$app_data")" ]]
}

copy_initial_profile() {
  require_rsync
  ensure_dirs

  rsync -a \
    --exclude 'auth.json' \
    --exclude '.codex-global-state.json' \
    --exclude '.codex-global-state.json.bak' \
    --exclude '*.sqlite' \
    --exclude '*.sqlite-*' \
    --exclude 'logs_*.sqlite*' \
    --exclude 'state_*.sqlite*' \
    --exclude 'session_index.jsonl' \
    --exclude 'sessions/' \
    --exclude 'shell_snapshots/' \
    --exclude 'cache/' \
    --exclude '.tmp/' \
    --exclude 'tmp/' \
    "$PRIMARY_CODEX_HOME/" "$SECOND_CODEX_HOME/"

  echo "Initialized second Codex home:"
  echo "  $SECOND_CODEX_HOME"
  echo
  echo "Second Electron profile:"
  echo "  $SECOND_APP_DATA"
}

copy_initial_profile_to() {
  local target_home="$1"
  require_rsync
  ensure_dirs
  mkdir -p "$target_home"

  rsync -a \
    --exclude 'auth.json' \
    --exclude '*.sqlite' \
    --exclude '*.sqlite-*' \
    --exclude 'logs_*.sqlite*' \
    --exclude 'state_*.sqlite*' \
    --exclude 'session_index.jsonl' \
    --exclude 'sessions/' \
    --exclude 'shell_snapshots/' \
    --exclude 'cache/' \
    --exclude '.tmp/' \
    --exclude 'tmp/' \
    "$PRIMARY_CODEX_HOME/" "$target_home/"
}

remove_shared_history_links_for_blank_account() {
  local account_home="$1"
  local item target

  for item in "session_index.jsonl" "sessions" "shell_snapshots"; do
    target="$account_home/$item"
    if [[ -L "$target" ]]; then
      rm "$target"
    fi
  done
}

init_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "init-account requires an account name." >&2
    exit 2
  fi

  local home_dir app_data
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"
  if home_uses_opencodex_proxy "$home_dir"; then
    echo "The opencodex-lab profile name is reserved for the managed OpenCodex Lab." >&2
    return 2
  fi
  rm -f "$ACCOUNTS_ROOT/.deleted-$(sanitize_account_name "$name")"

  if [[ "$home_dir" == "$PRIMARY_CODEX_HOME" ]]; then
    echo "Account 1 already exists: $PRIMARY_CODEX_HOME"
    return 0
  fi

  mkdir -p "$home_dir" "$app_data"
  remove_shared_history_links_for_blank_account "$home_dir"
  rm -f "$home_dir/.codex-global-state.json" "$home_dir/.codex-global-state.json.bak"
  mkdir -p "$home_dir/sessions" "$home_dir/shell_snapshots"
  [[ -e "$home_dir/session_index.jsonl" || -L "$home_dir/session_index.jsonl" ]] || : > "$home_dir/session_index.jsonl"
  set_history_mode_for_home "$home_dir" private
  local history_mode="private"

  echo "Initialized blank account:"
  echo "  name: $(sanitize_account_name "$name")"
  echo "  CODEX_HOME: $home_dir"
  echo "  app data: $app_data"
  echo "  history: $history_mode"
}

init_shared_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "init-shared-account requires an account name." >&2
    exit 2
  fi

  local home_dir app_data
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"
  if home_uses_opencodex_proxy "$home_dir"; then
    echo "OpenCodex Lab cannot use shared local history." >&2
    return 2
  fi
  rm -f "$ACCOUNTS_ROOT/.deleted-$(sanitize_account_name "$name")"

  if [[ "$home_dir" == "$PRIMARY_CODEX_HOME" ]]; then
    echo "Account 1 already exists: $PRIMARY_CODEX_HOME"
    return 0
  fi

  copy_initial_profile_to "$home_dir"
  mkdir -p "$app_data"
  link_history_for "$name" >/dev/null

  echo "Initialized shared account:"
  echo "  name: $(sanitize_account_name "$name")"
  echo "  CODEX_HOME: $home_dir"
  echo "  app data: $app_data"
  echo "  history: shared with account1"
}

list_accounts() {
  ensure_dirs
  echo "account1 | $PRIMARY_CODEX_HOME | $HOME/Library/Application Support/Codex"
  if [[ ! -f "$ACCOUNTS_ROOT/.deleted-account2" ]]; then
    echo "account2 | $SECOND_CODEX_HOME | $SECOND_APP_DATA"
  fi
  find "$ACCOUNTS_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | while read -r dir; do
    local name=""
    name="$(basename "$dir")"
    [[ "$name" == .* || "$name" == .deleted-* ]] && continue
    echo "$name | $dir | $(account_app_data_for "$name")"
  done
}

delete_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "delete-account requires an account name." >&2
    exit 2
  fi

  name="$(sanitize_account_name "$name")"
  if [[ "$name" == "account1" || "$name" == "primary" || "$name" == "default" ]]; then
    echo "Refusing to delete account1." >&2
    exit 2
  fi
  if [[ "$name" == "$OPENCODEX_LAB_ACCOUNT" ]]; then
    echo "OpenCodex Lab is managed by Codex Accounts and cannot be deleted as a normal profile." >&2
    return 2
  fi

  ensure_dirs
  local home_dir app_data archive_root stamp archive_dir
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  archive_root="$HOME/.codex-accounts-archive"
  archive_dir="$archive_root/$name-$stamp"
  mkdir -p "$archive_dir"

  if [[ -e "$home_dir" || -L "$home_dir" ]]; then
    mv "$home_dir" "$archive_dir/CODEX_HOME"
    echo "Archived CODEX_HOME -> $archive_dir/CODEX_HOME"
  fi
  if [[ -e "$app_data" || -L "$app_data" ]]; then
    mv "$app_data" "$archive_dir/AppData"
    echo "Archived app data -> $archive_dir/AppData"
  fi

  touch "$ACCOUNTS_ROOT/.deleted-$name"
  echo "Deleted profile '$name' by archiving it under:"
  echo "  $archive_dir"
}

usage_cache_file_for() {
  local name=""
  name="$(sanitize_account_name "$1")"
  printf '%s/%s.status' "$USAGE_CACHE_ROOT" "$name"
}

read_cached_usage() {
  local cache_file="$1"
  local max_age="${2:-$USAGE_CACHE_SECONDS}"
  [[ -f "$cache_file" ]] || return 1

  # Older cache files may contain a fabricated 5h window for free accounts.
  if ! grep -Fq $'\t' "$cache_file" 2>/dev/null; then
    return 1
  fi
  if grep -Fq '5h unknown' "$cache_file" 2>/dev/null; then
    return 1
  fi

  local mtime now age
  mtime="$(stat -f '%m' "$cache_file" 2>/dev/null || echo 0)"
  now="$(date '+%s')"
  age=$(( now - mtime ))
  if (( age < 0 || age > max_age )); then
    return 1
  fi

  cat "$cache_file"
}

trim_usage_text() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

reset_epoch_from_text() {
  local value
  value="$(printf '%s' "${1:-}" | trim_usage_text)"
  if [[ "$value" == "unknown" || "$value" == "none" || -z "$value" ]]; then
    return 1
  fi

  if [[ "$value" =~ '^[0-9][0-9]:[0-9][0-9]$' ]]; then
    date -j -f '%Y-%m-%d %H:%M' "$(date '+%Y-%m-%d') $value" '+%s' 2>/dev/null || return 1
    return 0
  fi

  if [[ "$value" =~ '^[0-9][0-9]/[0-9][0-9][[:space:]][0-9][0-9]:[0-9][0-9]$' ]]; then
    date -j -f '%Y/%m/%d %H:%M' "$(date '+%Y')/$value" '+%s' 2>/dev/null || return 1
    return 0
  fi

  if [[ "$value" =~ '^[0-9][0-9]/[0-9][0-9]$' ]]; then
    date -j -f '%Y/%m/%d %H:%M' "$(date '+%Y')/$value 23:59" '+%s' 2>/dev/null || return 1
    return 0
  fi

  return 1
}

cached_reset_part_for_label() {
  local reset="$1"
  local label="$2"
  local part reset_label

  for part in ${(s: / :)reset}; do
    part="$(printf '%s' "$part" | trim_usage_text)"
    reset_label="${part%% *}"
    if [[ "$reset_label" == "$label" ]]; then
      printf '%s' "$part"
      return 0
    fi
  done

  return 1
}

cached_reset_has_elapsed() {
  local reset="$1"
  local label="$2"
  local part reset_label reset_value reset_epoch now

  now="$(date '+%s')"
  for part in ${(s: / :)reset}; do
    part="$(printf '%s' "$part" | trim_usage_text)"
    reset_label="${part%% *}"
    [[ "$reset_label" == "$label" ]] || continue

    reset_value="${part#* }"
    reset_epoch="$(reset_epoch_from_text "$reset_value" 2>/dev/null || true)"
    [[ -n "$reset_epoch" ]] || return 1
    (( reset_epoch <= now )) && return 0
    return 1
  done

  return 1
}

cached_usage_window_age_has_elapsed() {
  local cache_file="$1"
  local label="$2"
  local amount unit window_seconds mtime now age

  if [[ "$label" =~ '^([0-9]+)([mhd])$' ]]; then
    amount="${match[1]}"
    unit="${match[2]}"
  else
    return 1
  fi

  case "$unit" in
    m) window_seconds=$(( amount * 60 )) ;;
    h) window_seconds=$(( amount * 3600 )) ;;
    d) window_seconds=$(( amount * 86400 )) ;;
    *) return 1 ;;
  esac

  mtime="$(stat -f '%m' "$cache_file" 2>/dev/null || echo 0)"
  now="$(date '+%s')"
  age=$(( now - mtime ))
  (( mtime > 0 && age >= window_seconds ))
}

cached_usage_has_elapsed_reset() {
  local cache_file="$1"
  local cached="$2"
  local quota="${cached%%$'\t'*}"
  local rest="${cached#*$'\t'}"
  local reset="${rest%%$'\t'*}"
  local part label

  for part in ${(s: / :)quota}; do
    part="$(printf '%s' "$part" | trim_usage_text)"
    [[ -n "$part" ]] || continue
    label="${part%% *}"
    if cached_usage_window_age_has_elapsed "$cache_file" "$label" \
        || cached_reset_has_elapsed "$reset" "$label"; then
      return 0
    fi
  done

  return 1
}

cached_usage_lacks_reset_credit_expiries() {
  local cached="$1"
  local first_rest second_rest reset_credits

  [[ "$cached" == *$'\t'*$'\t'* ]] || return 1
  first_rest="${cached#*$'\t'}"
  second_rest="${first_rest#*$'\t'}"
  reset_credits="$(printf '%s' "$second_rest" | trim_usage_text)"

  if [[ "$reset_credits" =~ '^[1-9][0-9]*$' ]]; then
    return 0
  fi
  return 1
}

read_cached_usage_if_still_current() {
  local cache_file="$1"
  local max_age="$2"
  local cached raw_cached

  if [[ -f "$cache_file" ]]; then
    raw_cached="$(cat "$cache_file" 2>/dev/null || true)"
    if [[ "$raw_cached" == '__auth_invalid__'$'\t'* ]]; then
      # A live 401 plus a rejected OAuth refresh is durable evidence that the
      # profile must sign in again. Keep that verdict until a later live probe
      # or successful token refresh replaces it.
      printf '%s\n' "$raw_cached"
      return 0
    fi
    if [[ -n "$raw_cached" ]] && cached_usage_has_elapsed_reset "$cache_file" "$raw_cached"; then
      # Remove the whole snapshot when any advertised window has expired.
      # Otherwise Swift's local fallback can resurrect the stale sub-window.
      invalidate_cached_usage "$cache_file"
      return 1
    fi
  fi

  cached="$(read_cached_usage "$cache_file" "$max_age" 2>/dev/null || true)"
  [[ -n "$cached" ]] || return 1
  printf '%s\n' "$cached"
}

write_cached_usage() {
  local cache_file="$1"
  local quota="$2"
  local reset="$3"
  local reset_credits="${4:-unknown}"
  local tmp_file

  mkdir -p "$USAGE_CACHE_ROOT"
  tmp_file="${cache_file}.$$"
  printf '%s\t%s\t%s\n' "$quota" "$reset" "$reset_credits" > "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

write_auth_invalid_usage_marker() {
  local cache_file="$1"
  write_cached_usage "$cache_file" "__auth_invalid__" "unknown" "unknown"
}

invalidate_cached_usage() {
  local cache_file="$1"
  [[ -n "$cache_file" ]] || return 0
  rm -f "$cache_file" 2>/dev/null || true
}

cleanup_app_server_process() {
  local server_pid="${1:-}"
  [[ -n "$server_pid" ]] || return 0
  pkill -TERM -P "$server_pid" 2>/dev/null || true
  kill -TERM "$server_pid" 2>/dev/null || true
  sleep 0.12
  pkill -KILL -P "$server_pid" 2>/dev/null || true
  kill -KILL "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}

secure_auth_file_permissions() {
  local auth_file="$1"
  [[ -f "$auth_file" ]] || return 1
  # Never follow, read, or replace a user-supplied symlink. Regular auth files
  # are private credentials and must not remain group/world-readable.
  [[ ! -L "$auth_file" ]] || return 1
  chmod 600 "$auth_file" 2>/dev/null
}

make_private_curl_headers_for_auth() {
  local auth_file="$1"
  local include_content_type="${2:-0}"
  local token account_id header_file

  secure_auth_file_permissions "$auth_file" || return 1
  token="$(jq -r '.tokens.access_token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || return 1
  account_id="$(jq -r '.tokens.account_id // empty' "$auth_file" 2>/dev/null || true)"
  [[ "$account_id" != *$'\n'* && "$account_id" != *$'\r'* ]] || return 1

  header_file="$(mktemp)" || return 1
  chmod 600 "$header_file" 2>/dev/null || {
    rm -f "$header_file"
    return 1
  }
  {
    printf 'Authorization: Bearer %s\n' "$token"
    printf 'Accept: application/json\n'
    if [[ "$include_content_type" == "1" ]]; then
      printf 'Content-Type: application/json\n'
    else
      printf 'originator: Codex Desktop\n'
      printf 'OAI-Product-Sku: CODEX\n'
    fi
    if [[ -n "$account_id" && "$account_id" != "null" ]]; then
      printf 'ChatGPT-Account-Id: %s\n' "$account_id"
    fi
  } > "$header_file"
  chmod 600 "$header_file" 2>/dev/null || {
    rm -f "$header_file"
    return 1
  }
  printf '%s\n' "$header_file"
}

refresh_chatgpt_tokens_for() {
  local auth_file="$1"
  local refresh_token current_refresh_token refresh_body tmp_file tmp_auth http_status refresh_error now
  local attempt=1
  local max_attempts=2

  secure_auth_file_permissions "$auth_file" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  refresh_token="$(jq -r '.tokens.refresh_token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$refresh_token" ]] || return 1

  while (( attempt <= max_attempts )); do
    # Build the JSON from stdin so neither credential is exposed in jq argv.
    refresh_body="$(printf '%s\0%s' "$CHATGPT_CLIENT_ID" "$refresh_token" | jq -Rsc '
      split("\u0000") as $values
      | {client_id: $values[0], grant_type: "refresh_token", refresh_token: $values[1]}
    ' 2>/dev/null || true)"
    [[ -n "$refresh_body" ]] || return 1

    tmp_file="$(mktemp)"
    chmod 600 "$tmp_file" 2>/dev/null || {
      rm -f "$tmp_file"
      return 1
    }
    # Keep the refresh token out of argv/process listings. The JSON request is
    # passed through stdin and the response is kept in a mode-0600 temp file.
    http_status="$(printf '%s' "$refresh_body" | curl -sS --connect-timeout "$TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS" --max-time "$TOKEN_REFRESH_TIMEOUT_SECONDS" -o "$tmp_file" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data-binary @- \
      "$TOKEN_REFRESH_URL" 2>/dev/null || true)"

    if [[ "$http_status" != "200" ]]; then
      refresh_error="$(jq -r '
        if (.error? | type) == "string" then .error
        elif (.error? | type) == "object" then (.error.code // empty)
        else empty
        end
      ' "$tmp_file" 2>/dev/null || true)"
      rm -f "$tmp_file"
      # Only an explicit OAuth invalidation is a durable login verdict. Before
      # returning it, re-read auth.json: another process may already have
      # rotated the refresh token. Retry that newer token once, and if it moves
      # again at the bound, preserve the signed-in/cache state instead.
      if [[ ( "$http_status" == "400" || "$http_status" == "401" ) \
            && ( "$refresh_error" == "invalid_grant" \
              || "$refresh_error" == "invalid_token" \
              || "$refresh_error" == "invalid_refresh_token" \
              || "$refresh_error" == "refresh_token_reused" ) ]]; then
        current_refresh_token="$(jq -r '.tokens.refresh_token // empty' "$auth_file" 2>/dev/null || true)"
        if [[ -n "$current_refresh_token" && "$current_refresh_token" != "$refresh_token" ]]; then
          if (( attempt < max_attempts )); then
            refresh_token="$current_refresh_token"
            attempt=$(( attempt + 1 ))
            continue
          fi
          return 3
        fi
        return 2
      fi
      return 1
    fi

    if ! jq -e '.access_token? and (.access_token | type == "string")' "$tmp_file" >/dev/null 2>&1; then
      rm -f "$tmp_file"
      return 1
    fi

    # Do not overwrite a newer auth.json produced concurrently while this
    # request was in flight. Its credentials will be probed by the caller.
    current_refresh_token="$(jq -r '.tokens.refresh_token // empty' "$auth_file" 2>/dev/null || true)"
    if [[ -n "$current_refresh_token" && "$current_refresh_token" != "$refresh_token" ]]; then
      chmod 600 "$auth_file" 2>/dev/null || true
      rm -f "$tmp_file"
      return 0
    fi

    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    tmp_auth="$(mktemp "${auth_file}.tmp.XXXXXX")" || {
      rm -f "$tmp_file"
      return 1
    }
    chmod 600 "$tmp_auth" 2>/dev/null || {
      rm -f "$tmp_file" "$tmp_auth"
      return 1
    }
    if jq --slurpfile refreshed "$tmp_file" --arg now "$now" '
      .tokens.access_token = $refreshed[0].access_token
      | .tokens.refresh_token = ($refreshed[0].refresh_token // .tokens.refresh_token)
      | .tokens.id_token = ($refreshed[0].id_token // .tokens.id_token)
      | .tokens.account_id = ($refreshed[0].account_id // .tokens.account_id)
      | .last_refresh = $now
    ' "$auth_file" > "$tmp_auth" 2>/dev/null; then
      chmod 600 "$tmp_auth" 2>/dev/null || {
        rm -f "$tmp_file" "$tmp_auth"
        return 1
      }
      mv "$tmp_auth" "$auth_file"
      chmod 600 "$auth_file" 2>/dev/null || return 1
      rm -f "$tmp_file"
      return 0
    fi

    rm -f "$tmp_file" "$tmp_auth"
    return 1
  done

  return 1
}

fetch_usage_http_status() {
  local auth_file="$1"
  local tmp_file="$2"
  local header_file http_status

  header_file="$(make_private_curl_headers_for_auth "$auth_file" 1)" || return 1
  http_status="$(curl -sS --connect-timeout "$USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS" --max-time "$USAGE_DIRECT_TIMEOUT_SECONDS" -o "$tmp_file" -w '%{http_code}' \
    --header "@$header_file" \
    "$USAGE_API_URL" 2>/dev/null || true)"
  rm -f "$header_file"
  printf '%s\n' "$http_status"
}

fetch_reset_credits_http_status() {
  local auth_file="$1"
  local tmp_file="$2"
  local header_file http_status

  header_file="$(make_private_curl_headers_for_auth "$auth_file" 0)" || return 1
  http_status="$(curl -sS --connect-timeout "$USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS" --max-time "$USAGE_DIRECT_TIMEOUT_SECONDS" -o "$tmp_file" -w '%{http_code}' \
    --header "@$header_file" \
    "$RESET_CREDITS_API_URL" 2>/dev/null || true)"
  rm -f "$header_file"
  printf '%s\n' "$http_status"
}

parse_reset_credits_detail_file() {
  local json_file="$1"

  jq -r '
    def reset_credit_expiry($x):
      ($x.expires_at // $x.expiresAt // $x.expiry_at // $x.expiryAt // $x.expires // $x.expiry // $x.expiration // null);
    def is_available($x):
      (($x.status // "available") | tostring | ascii_downcase) == "available";
    def reset_credits($c):
      if $c == null then "unknown"
      else
        (($c.available_count // $c.availableCount // $c.count // $c.balance // 0) | tostring) as $count |
        ([($c.credits // $c.items // $c.reset_credits // $c.resetCredits // [])[]? | select(is_available(.)) | reset_credit_expiry(.) | select(. != null) | tostring] | join(",")) as $expiries |
        if $expiries != "" then ($count + "@" + $expiries) else $count end
      end;
    reset_credits(.)
  ' "$json_file" 2>/dev/null || true
}

fetch_reset_credits_detail_for() {
  local auth_file="$1"
  local tmp_file http_status detail

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$auth_file" ]] || return 1

  tmp_file="$(mktemp)"
  http_status="$(fetch_reset_credits_http_status "$auth_file" "$tmp_file")"
  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    if refresh_chatgpt_tokens_for "$auth_file"; then
      tmp_file="$(mktemp)"
      http_status="$(fetch_reset_credits_http_status "$auth_file" "$tmp_file")"
    fi
  fi

  if [[ "$http_status" != "200" ]]; then
    rm -f "$tmp_file"
    return 1
  fi

  detail="$(parse_reset_credits_detail_file "$tmp_file")"
  rm -f "$tmp_file"
  [[ -n "$detail" && "$detail" != "unknown" ]] || return 1
  printf '%s\n' "$detail"
}

merge_reset_credits_detail_into_raw_summary() {
  local auth_file="$1"
  local raw_summary="$2"
  local cache_file="${3:-}"
  local detail raw_detail cached_line cached_detail
  local -a parts

  parts=("${(@ps:\t:)raw_summary}")
  raw_detail="${parts[3]:-unknown}"

  # Quota percentages are the time-sensitive part. Avoid a second HTTP call
  # when the usage response already has enough reset-credit information.
  if [[ "$raw_detail" == "0" || "$raw_detail" == *"@"* ]]; then
    printf '%s\n' "$raw_summary"
    return 0
  fi

  # Reuse a matching cached expiry instead of delaying every account refresh.
  if [[ "$raw_detail" =~ '^[1-9][0-9]*$' && -n "$cache_file" && -f "$cache_file" ]]; then
    cached_line="$(awk 'NR == 1 { print; exit }' "$cache_file" 2>/dev/null || true)"
    cached_detail="${cached_line##*$'\t'}"
    if [[ "$cached_detail" == "$raw_detail@"* ]]; then
      printf '%s\t%s\t%s\n' "${parts[1]:-}" "${parts[2]:-}" "$cached_detail"
      return 0
    fi
  fi

  detail="$(fetch_reset_credits_detail_for "$auth_file" 2>/dev/null || true)"
  [[ -n "$detail" ]] || {
    printf '%s\n' "$raw_summary"
    return 0
  }
  printf '%s\t%s\t%s\n' "${parts[1]:-}" "${parts[2]:-}" "$detail"
}

format_reset_epoch() {
  local epoch="${1:-}"
  if [[ -z "$epoch" || "$epoch" == "unknown" || "$epoch" == "null" ]]; then
    printf 'unknown'
    return 0
  fi
  if [[ ! "$epoch" =~ '^[0-9]+$' ]]; then
    printf 'unknown'
    return 0
  fi

  local today reset_day
  today="$(date '+%Y%m%d')"
  reset_day="$(date -r "$epoch" '+%Y%m%d' 2>/dev/null || echo '')"
  if [[ "$reset_day" == "$today" ]]; then
    date -r "$epoch" '+%H:%M' 2>/dev/null || printf 'unknown'
  else
    date -r "$epoch" '+%m/%d %H:%M' 2>/dev/null || printf 'unknown'
  fi
}

emit_usage_summary_from_raw() {
  local cache_file="$1"
  local raw_summary="$2"
  local quota reset_epochs reset reset_credits
  local -a summary_parts

  summary_parts=("${(@ps:\t:)raw_summary}")
  quota="${summary_parts[1]:-}"
  reset_epochs="${summary_parts[2]:-}"
  reset_credits="${summary_parts[3]:-unknown}"
  [[ -n "$quota" ]] || return 1
  if [[ "$quota" == "unlimited" ]]; then
    write_cached_usage "$cache_file" "$quota" "none" "$reset_credits"
    printf '%s\t%s\t%s\n' "$quota" "none" "$reset_credits"
    return 0
  fi

  reset=""
  for part in ${(s: / :)reset_epochs}; do
    local reset_label reset_epoch formatted_reset
    reset_label="${part%% *}"
    reset_epoch="${part#* }"
    formatted_reset="$(format_reset_epoch "$reset_epoch")"
    if [[ -n "$reset" ]]; then
      reset="$reset / "
    fi
    reset="$reset$reset_label $formatted_reset"
  done
  [[ -n "$reset" ]] || reset="unknown"

  write_cached_usage "$cache_file" "$quota" "$reset" "$reset_credits"
  printf '%s\t%s\t%s\n' "$quota" "$reset" "$reset_credits"
}

fetch_usage_summary_via_app_server() {
  local home_dir="$1"
  local cache_file="$2"
  local auth_file="$home_dir/auth.json"
  local codex_bin="$CODEX_APP/Contents/Resources/codex"
  local timeout_seconds="$APP_SERVER_USAGE_TIMEOUT_SECONDS"
  local init_request initialized_notification rate_request line raw_summary error_message server_pid
  local -a app_server_env

  # The direct ChatGPT usage endpoint can return 403 for local Codex tokens.
  # Keep the app-server fallback available, but parse its window duration
  # exactly so free monthly quotas are not mislabeled as Plus 5H quotas.
  [[ "$CODEX_USAGE_APP_SERVER_FALLBACK" == "1" ]] || return 1
  [[ -x "$codex_bin" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  init_request='{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-accounts","title":"Codex Accounts","version":"2.7.2"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}'
  initialized_notification='{"method":"initialized"}'
  rate_request='{"method":"account/rateLimits/read","id":2}'

  app_server_env=(CODEX_HOME="$home_dir")
  if proxy_injection_enabled; then
    app_server_env+=(
      HTTP_PROXY="$CODEX_PROXY_URL"
      HTTPS_PROXY="$CODEX_PROXY_URL"
      ALL_PROXY="$CODEX_PROXY_URL"
      NO_PROXY="$CODEX_NO_PROXY"
      http_proxy="$CODEX_PROXY_URL"
      https_proxy="$CODEX_PROXY_URL"
      all_proxy="$CODEX_PROXY_URL"
      no_proxy="$CODEX_NO_PROXY"
    )
  fi

  coproc env "${app_server_env[@]}" "$codex_bin" -c 'mcp_servers={}' -c 'plugins={}' app-server --listen stdio:// 2>/dev/null
  server_pid=$!

  print -p -- "$init_request" 2>/dev/null || true
  print -p -- "$initialized_notification" 2>/dev/null || true
  print -p -- "$rate_request" 2>/dev/null || true

  while read -t "$timeout_seconds" -p line; do
    raw_summary="$(printf '%s\n' "$line" | jq -r '
      def clamp: if . < 0 then 0 elif . > 100 then 100 else . end;
      def has_usage($w): $w != null and ($w.usedPercent != null);
      def left($w): (((100 - ($w.usedPercent | tonumber)) | clamp | floor) | tostring) + "%";
      def epoch($w):
        if $w == null then "unknown"
        elif ($w.resetsAt != null) then ($w.resetsAt | tostring)
        elif ($w.resetAt != null) then ($w.resetAt | tostring)
        else "unknown"
        end;
      def duration_label($fallback; $mins):
        if $mins == null then $fallback
        else
          ($mins | tonumber?) as $m |
          if $m == null then $fallback
          elif $m == 300 then "5h"
          elif $m == 10080 then "7d"
          elif $m == 43200 then "30d"
          elif (($m % 1440) == 0) then (($m / 1440 | floor | tostring) + "d")
          elif (($m % 60) == 0) then (($m / 60 | floor | tostring) + "h")
          else (($m | floor | tostring) + "m")
          end
        end;
      def window_minutes($w):
        ($w.windowDurationMins // $w.window_minutes //
          (if (($w.limitWindowSeconds // $w.limit_window_seconds) != null) then
            (($w.limitWindowSeconds // $w.limit_window_seconds) / 60)
          else null end));
      def quota_label($fallback; $w):
        if $w == null then $fallback
        else duration_label($fallback; window_minutes($w))
        end;
      def reset_credit_expiry($x):
        ($x.expiresAt // $x.expires_at // $x.expiryAt // $x.expiry_at // $x.expires // $x.expiry // $x.expiration // null);
      def reset_credits($c):
        if $c == null then "unknown"
        else
          (($c.availableCount // $c.available_count // $c.count // $c.balance // 0) | tostring) as $count |
          ([($c.credits // $c.items // $c.resetCredits // $c.reset_credits // [])[]? | reset_credit_expiry(.) | select(. != null) | tostring] | join(",")) as $expiries |
          if $expiries != "" then ($count + "@" + $expiries) else $count end
        end;
      select(.id? == 2 and .result?.rateLimits?) |
      .result.rateLimits as $l |
      (.result.rateLimitResetCredits // .result.rate_limit_reset_credits) as $rc |
      if (($l.credits.unlimited // false) == true) then
        ["unlimited", "none", reset_credits($rc)]
      else
        [
          ([
            if has_usage($l.primary) then quota_label("usage"; $l.primary) + " " + left($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + left($l.secondary) else empty end
          ] | join(" / ")),
          ([
            if has_usage($l.primary) then quota_label("usage"; $l.primary) + " " + epoch($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + epoch($l.secondary) else empty end
          ] | join(" / ")),
          reset_credits($rc)
        ]
      end | @tsv
    ' 2>/dev/null || true)"
    if [[ -n "$raw_summary" ]]; then
      cleanup_app_server_process "$server_pid"
      raw_summary="$(merge_reset_credits_detail_into_raw_summary "$auth_file" "$raw_summary" "$cache_file")"
      emit_usage_summary_from_raw "$cache_file" "$raw_summary"
      return 0
    fi

    error_message="$(printf '%s\n' "$line" | jq -r 'select(.id? == 2 and .error?.message?) | .error.message' 2>/dev/null || true)"
    if [[ -n "$error_message" ]]; then
      cleanup_app_server_process "$server_pid"
      if [[ "$error_message" == *"token has been invalidated"* \
            || "$error_message" == *"401 Unauthorized"* \
            || "$error_message" == *"authentication token is invalid"* \
            || "$error_message" == *"Authentication token is invalid"* ]]; then
        write_auth_invalid_usage_marker "$cache_file"
        printf '%s\t%s\n' "__auth_invalid__" "unknown"
        return 0
      fi
      return 1
    fi
  done

  cleanup_app_server_process "$server_pid"
  return 1
}

fetch_usage_summary_for() {
  local name="$1"
  local home_dir="$2"
  local auth_file="$home_dir/auth.json"
  local cache_file
  cache_file="$(usage_cache_file_for "$name")"

  if [[ "$CODEX_USAGE_LIVE_LOOKUP" != "1" ]]; then
    if read_cached_usage_if_still_current "$cache_file" "$USAGE_CACHE_SECONDS"; then
      return 0
    fi
    read_cached_usage_if_still_current "$cache_file" "$USAGE_CACHE_STALE_SECONDS" 2>/dev/null || return 1
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$auth_file" ]] || return 1

  local tmp_file http_status refresh_status raw_summary quota reset_epochs primary_epoch secondary_epoch

  tmp_file="$(mktemp)"
  http_status="$(fetch_usage_http_status "$auth_file" "$tmp_file")"

  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    if refresh_chatgpt_tokens_for "$auth_file"; then
      if [[ -f "$cache_file" ]] && head -n 1 "$cache_file" 2>/dev/null | grep -q '^__auth_invalid__'; then
        invalidate_cached_usage "$cache_file"
      fi
      tmp_file="$(mktemp)"
      http_status="$(fetch_usage_http_status "$auth_file" "$tmp_file")"
    else
      refresh_status=$?
      if [[ "$refresh_status" == "2" ]]; then
        write_auth_invalid_usage_marker "$cache_file"
        printf '%s\t%s\n' "__auth_invalid__" "unknown"
        return 0
      fi
      fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
      # Refresh can fail because the network or identity endpoint is unavailable.
      # Preserve the signed-in state unless a live endpoint explicitly rejects it.
      read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null || return 1
      return 0
    fi
  fi

  if [[ "$http_status" == "403" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    # 403 can mean the quota endpoint is unavailable for this account or route;
    # it does not prove that the local Codex login is invalid.
    read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null || return 1
    return 0
  fi

  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    write_auth_invalid_usage_marker "$cache_file"
    printf '%s\t%s\n' "__auth_invalid__" "unknown"
    return 0
  fi

  if [[ "$http_status" != "200" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    # Keep a short stale fallback when the network/API is temporarily unavailable.
    read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null || return 1
    return 0
  fi

  raw_summary="$(jq -r '
    def clamp: if . < 0 then 0 elif . > 100 then 100 else . end;
    def limits:
      if .rate_limits then
        .rate_limits
      elif .rate_limit then
        {
          unlimited: .rate_limit.unlimited,
          primary: .rate_limit.primary_window,
          secondary: .rate_limit.secondary_window
        }
      else
        {}
      end;
    def has_usage($w): $w != null and ($w.used_percent != null);
    def left($w): (((100 - ($w.used_percent | tonumber)) | clamp | floor) | tostring) + "%";
    def epoch($w):
      if $w == null then "unknown"
      elif ($w.resets_at != null) then ($w.resets_at | tostring)
      elif ($w.reset_at != null) then ($w.reset_at | tostring)
      else "unknown"
      end;
    def duration_label($fallback; $mins):
      if $mins == null then $fallback
      else
        ($mins | tonumber?) as $m |
        if $m == null then $fallback
        elif $m == 300 then "5h"
        elif $m == 10080 then "7d"
        elif $m == 43200 then "30d"
        elif (($m % 1440) == 0) then (($m / 1440 | floor | tostring) + "d")
        elif (($m % 60) == 0) then (($m / 60 | floor | tostring) + "h")
        else (($m | floor | tostring) + "m")
        end
      end;
    def window_minutes($w):
      ($w.window_minutes // $w.windowDurationMins //
        (if (($w.limit_window_seconds // $w.limitWindowSeconds) != null) then
          (($w.limit_window_seconds // $w.limitWindowSeconds) / 60)
        else null end));
    def quota_label($fallback; $w):
      if $w == null then $fallback
      else duration_label($fallback; window_minutes($w))
      end;
    def reset_credit_expiry($x):
      ($x.expires_at // $x.expiresAt // $x.expiry_at // $x.expiryAt // $x.expires // $x.expiry // $x.expiration // null);
    def reset_credits($c):
      if $c == null then "unknown"
      else
        (($c.available_count // $c.availableCount // $c.count // $c.balance // 0) | tostring) as $count |
        ([($c.credits // $c.items // $c.reset_credits // $c.resetCredits // [])[]? | reset_credit_expiry(.) | select(. != null) | tostring] | join(",")) as $expiries |
        if $expiries != "" then ($count + "@" + $expiries) else $count end
      end;
    def primary_label($l):
      quota_label("usage"; $l.primary);
    (limits) as $l |
    if ($l.unlimited == true) then
      ["unlimited", "none", reset_credits(.rate_limit_reset_credits // .rateLimitResetCredits)]
    else
      [
        ([
          if has_usage($l.primary) then primary_label($l) + " " + left($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + left($l.secondary) else empty end
        ] | join(" / ")),
        ([
          if has_usage($l.primary) then primary_label($l) + " " + epoch($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + epoch($l.secondary) else empty end
        ] | join(" / ")),
        reset_credits(.rate_limit_reset_credits // .rateLimitResetCredits)
      ]
    end | @tsv
  ' "$tmp_file" 2>/dev/null || true)"
  rm -f "$tmp_file"
  [[ -n "$raw_summary" ]] || return 1

  raw_summary="$(merge_reset_credits_detail_into_raw_summary "$auth_file" "$raw_summary" "$cache_file")"
  emit_usage_summary_from_raw "$cache_file" "$raw_summary"
}

account_status_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "account-status requires an account name." >&2
    exit 2
  fi

  local home_dir auth_file auth_mode last_refresh auth_status quota reset reset_credits usage_summary
  local -a usage_parts
  home_dir="$(account_home_for "$name")"
  auth_file="$home_dir/auth.json"
  auth_mode="unknown"
  last_refresh="never"
  auth_status="login_needed"
  quota="unknown"
  reset="unknown"
  reset_credits="unknown"

  if home_uses_opencodex_proxy "$home_dir"; then
    echo "$(sanitize_account_name "$name") | signed_in_local | external | local-proxy | external | opencodex:$OPENCODEX_VERSION | none"
    return 0
  fi

  if home_uses_account1_ai_proxy "$home_dir"; then
    echo "$(sanitize_account_name "$name") | signed_in_local | external | api-key | external | aliyun:qwen3.7-plus | none"
    return 0
  fi

  if [[ -f "$auth_file" ]] && secure_auth_file_permissions "$auth_file"; then
    auth_mode="$(jq -r '.auth_mode // "unknown"' "$auth_file" 2>/dev/null || echo "unknown")"
    last_refresh="$(jq -r '.last_refresh // "unknown"' "$auth_file" 2>/dev/null || echo "unknown")"
    if jq -e '.tokens.access_token? and .tokens.refresh_token?' "$auth_file" >/dev/null 2>&1; then
      auth_status="signed_in_local"
      usage_summary="$(fetch_usage_summary_for "$name" "$home_dir" 2>/dev/null || true)"
      if [[ -n "$usage_summary" ]]; then
        usage_parts=("${(@ps:\t:)usage_summary}")
        quota="${usage_parts[1]:-unknown}"
        reset="${usage_parts[2]:-unknown}"
        reset_credits="${usage_parts[3]:-unknown}"
        if [[ "$quota" == "__auth_invalid__" ]]; then
          # The app-server confirmed Codex itself cannot use this token.
          # Treat it as an expired login instead of showing stale quota.
          auth_status="auth_invalid"
          quota="unknown"
          reset="unknown"
          reset_credits="unknown"
        fi
      fi
    else
      auth_status="auth_incomplete"
    fi
  fi

  echo "$(sanitize_account_name "$name") | $auth_status | $auth_mode | $last_refresh | $quota | $reset | $reset_credits"
}

list_accounts_status() {
  local tmp_dir index name status_parallelism live_min_parallelism
  local -a pids
  tmp_dir="$(mktemp -d)"
  index=0
  status_parallelism="${STATUS_PARALLELISM:-2}"
  live_min_parallelism="$CODEX_USAGE_LIVE_MIN_PARALLELISM"
  [[ "$status_parallelism" =~ '^[1-9][0-9]*$' ]] || status_parallelism=2
  [[ "$live_min_parallelism" =~ '^[1-9][0-9]*$' ]] || live_min_parallelism=10
  if [[ "$CODEX_USAGE_LIVE_LOOKUP" == "1" && status_parallelism -lt live_min_parallelism ]]; then
    status_parallelism="$live_min_parallelism"
  fi
  pids=()

  while read -r name; do
    [[ -n "$name" ]] || continue
    index=$((index + 1))
    (
      account_status_for "$name" > "$tmp_dir/$index.status" 2>/dev/null || true
    ) &
    pids+=("$!")
    if (( ${#pids[@]} >= status_parallelism )); then
      for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      pids=()
    fi
  done < <(list_accounts | cut -d '|' -f 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  for status_file in "$tmp_dir"/*.status(N); do
    cat "$status_file"
  done
  rm -rf "$tmp_dir"
}

rsync_item_to_shared() {
  local profile_home="$1"
  local item="$2"
  local src="$profile_home/$item"
  local dst="$SHARED_MEMORY_DIR/$item"

  [[ -e "$src" ]] || return 0

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync_quick -a --update "$src/" "$dst/" || sync_debug "Skipped slow rsync to shared: $src"
  else
    mkdir -p "$(dirname "$dst")"
    rsync_quick -a --update "$src" "$dst" || sync_debug "Skipped slow rsync to shared: $src"
  fi
}

rsync_item_from_shared() {
  local profile_home="$1"
  local item="$2"
  local src="$SHARED_MEMORY_DIR/$item"
  local dst="$profile_home/$item"

  [[ -e "$src" ]] || return 0

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync_quick -a --update "$src/" "$dst/" || sync_debug "Skipped slow rsync from shared: $src"
  else
    mkdir -p "$(dirname "$dst")"
    rsync_quick -a --update "$src" "$dst" || sync_debug "Skipped slow rsync from shared: $src"
  fi
}

collect_enabled_plugins_from_config() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0

  awk '
    /^\[plugins\."/ {
      if (in_plugin && enabled && plugin != "") {
        print plugin
      }
      plugin = $0
      sub(/^\[plugins\."/,"",plugin)
      sub(/"\]$/,"",plugin)
      in_plugin = 1
      enabled = 0
      next
    }
    /^\[/ {
      if (in_plugin && enabled && plugin != "") {
        print plugin
      }
      in_plugin = 0
      plugin = ""
      enabled = 0
      next
    }
    in_plugin && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
      enabled = 1
    }
    END {
      if (in_plugin && enabled && plugin != "") {
        print plugin
      }
    }
  ' "$config_file"
}

write_config_with_synced_plugins() {
  local config_file="$1"
  local plugins_file="$2"
  local tmp_file

  mkdir -p "$(dirname "$config_file")"
  tmp_file="${config_file}.$$"

  if [[ -f "$config_file" ]]; then
    awk '
      /^\[plugins\."/ { skip = 1; next }
      /^\[/ { skip = 0 }
      !skip { print }
    ' "$config_file" > "$tmp_file"
  else
    : > "$tmp_file"
  fi

  {
    printf '\n'
    while read -r plugin_name; do
      [[ -n "$plugin_name" ]] || continue
      printf '[plugins."%s"]\n' "$plugin_name"
      printf 'enabled = true\n\n'
    done < "$plugins_file"
  } >> "$tmp_file"

  if [[ -f "$config_file" ]] && cmp -s "$tmp_file" "$config_file"; then
    rm -f "$tmp_file"
    return 0
  fi

  chmod 600 "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$config_file"
}

sync_plugin_config_entries() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local plugins_file home_dir
  plugins_file="$(mktemp)"

  for home_dir in "${homes[@]}"; do
    collect_enabled_plugins_from_config "$home_dir/config.toml"
  done | sort -u > "$plugins_file"

  if [[ ! -s "$plugins_file" ]]; then
    rm -f "$plugins_file"
    return 0
  fi

  for home_dir in "${homes[@]}"; do
    write_config_with_synced_plugins "$home_dir/config.toml" "$plugins_file"
  done

  rm -f "$plugins_file"
}

sync_plugin_config_entries_to_selected_homes() {
  local dest_count="$1"
  shift || true

  local -a dest_homes source_homes
  local i home_dir plugins_file
  dest_homes=()
  for (( i = 1; i <= dest_count; i++ )); do
    [[ $# -gt 0 ]] || break
    dest_homes+=("$1")
    shift
  done
  source_homes=("$@")
  (( ${#dest_homes[@]} > 0 && ${#source_homes[@]} > 0 )) || return 0

  plugins_file="$(mktemp)"

  for home_dir in "${source_homes[@]}"; do
    collect_enabled_plugins_from_config "$home_dir/config.toml"
  done | sort -u > "$plugins_file"

  if [[ ! -s "$plugins_file" ]]; then
    rm -f "$plugins_file"
    return 0
  fi

  for home_dir in "${dest_homes[@]}"; do
    write_config_with_synced_plugins "$home_dir/config.toml" "$plugins_file"
  done

  rm -f "$plugins_file"
}

rsync_shared_payload_direct() {
  local source_home="$1"
  local target_home="$2"
  local item="$3"
  local src="$source_home/$item"
  local dst="$target_home/$item"

  [[ "$source_home" != "$target_home" ]] || return 0
  [[ -e "$src" ]] || return 0

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync_quick -a --update \
      --exclude '.DS_Store' \
      --exclude 'plugin-install-*' \
      --exclude 'plugin-backup-*' \
      "$src/" "$dst/" || sync_debug "Skipped slow plugin rsync: $src"
  else
    mkdir -p "$(dirname "$dst")"
    rsync_quick -a --update "$src" "$dst" || sync_debug "Skipped slow plugin rsync: $src"
  fi
}

sync_plugin_payloads_direct() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local hub_home item home_dir
  hub_home="$PRIMARY_CODEX_HOME"
  if [[ ! -d "$hub_home" ]]; then
    hub_home="${homes[1]}"
  fi
  [[ -n "$hub_home" ]] || return 0

  for item in "${PLUGIN_SYNC_ITEMS[@]}"; do
    for home_dir in "${homes[@]}"; do
      rsync_shared_payload_direct "$home_dir" "$hub_home" "$item"
    done
    for home_dir in "${homes[@]}"; do
      rsync_shared_payload_direct "$hub_home" "$home_dir" "$item"
    done
  done
}

rsync_fast_plugin_payload_direct() {
  local source_home="$1"
  local target_home="$2"
  local item="$3"
  local src="$source_home/$item"
  local dst="$target_home/$item"

  [[ "$source_home" != "$target_home" ]] || return 0
  [[ -e "$src" ]] || return 0

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync_quick -a --update \
      --exclude '.DS_Store' \
      --exclude 'plugin-install-*' \
      --exclude 'plugin-backup-*' \
      "$src/" "$dst/" || sync_debug "Skipped slow fast-plugin rsync: $src"
  else
    mkdir -p "$(dirname "$dst")"
    rsync_quick -a --update "$src" "$dst" || sync_debug "Skipped slow fast-plugin rsync: $src"
  fi
}

sync_fast_plugin_payloads_direct() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local hub_home item home_dir
  local -a fast_items
  hub_home="$PRIMARY_CODEX_HOME"
  if [[ ! -d "$hub_home" ]]; then
    hub_home="${homes[1]}"
  fi
  [[ -n "$hub_home" ]] || return 0

  fast_items=(
    "skills"
    "vendor_imports"
    "plugins"
  )

  for item in "${fast_items[@]}"; do
    for home_dir in "${homes[@]}"; do
      rsync_fast_plugin_payload_direct "$home_dir" "$hub_home" "$item"
    done
    for home_dir in "${homes[@]}"; do
      rsync_fast_plugin_payload_direct "$hub_home" "$home_dir" "$item"
    done
  done
}

sync_memory_and_config_for_homes() {
  local -a homes history_homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local home_dir
  for item in "${SYNC_ITEMS[@]}"; do
    for home_dir in "${homes[@]}"; do
      [[ "$item" != "memories" || "$(history_mode_for_home "$home_dir")" != "private" ]] || continue
      rsync_item_to_shared "$home_dir" "$item"
    done
    for home_dir in "${homes[@]}"; do
      [[ "$item" != "memories" || "$(history_mode_for_home "$home_dir")" != "private" ]] || continue
      rsync_item_from_shared "$home_dir" "$item"
    done
  done
  if [[ "$CODEX_SYNC_PLUGIN_CONFIG" == "1" ]]; then
    sync_plugin_config_entries "${homes[@]}"
  fi
  history_homes=("${(@f)$(shared_history_homes "${homes[@]}")}")
  if (( ${#history_homes[@]} > 0 )) && [[ -n "${history_homes[1]:-}" ]]; then
    sync_global_state_for_homes "${history_homes[@]}"
  fi
}

sync_memory_and_config_to_selected_homes() {
  local dest_count="$1"
  shift || true

  local -a dest_homes source_homes
  local i home_dir item
  dest_homes=()
  for (( i = 1; i <= dest_count; i++ )); do
    [[ $# -gt 0 ]] || break
    dest_homes+=("$1")
    shift
  done
  source_homes=("$@")
  (( ${#dest_homes[@]} > 0 && ${#source_homes[@]} > 0 )) || return 0

  for item in "${SYNC_ITEMS[@]}"; do
    for home_dir in "${source_homes[@]}"; do
      [[ "$item" != "memories" || "$(history_mode_for_home "$home_dir")" != "private" ]] || continue
      rsync_item_to_shared "$home_dir" "$item"
    done
    for home_dir in "${dest_homes[@]}"; do
      [[ "$item" != "memories" || "$(history_mode_for_home "$home_dir")" != "private" ]] || continue
      rsync_item_from_shared "$home_dir" "$item"
    done
  done
  if [[ "$CODEX_SYNC_PLUGIN_CONFIG" == "1" ]]; then
    sync_plugin_config_entries_to_selected_homes "$dest_count" "${dest_homes[@]}" "${source_homes[@]}"
  fi
}

sync_plugin_payloads_for_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  if [[ "$CODEX_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    sync_plugin_payloads_direct "${homes[@]}"
  elif [[ "$CODEX_FAST_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    sync_fast_plugin_payloads_direct "${homes[@]}"
  fi
}

sync_goal_state_for_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local homes_payload
  homes_payload="$(printf '%s\n' "${homes[@]}")"
  local dest_payload
  dest_payload="${CODEX_GOAL_STATE_DEST_HOMES:-}"
  local active_db_payload
  active_db_payload=""
  if [[ "$CODEX_SKIP_ACTIVE_STATE_DB_WRITES" == "1" ]]; then
    local -a active_probe_homes
    if [[ -n "$dest_payload" ]]; then
      active_probe_homes=("${(@f)dest_payload}")
    else
      active_probe_homes=("${homes[@]}")
    fi
    active_db_payload="$(active_sqlite_homes_payload "${active_probe_homes[@]}")"
  fi

  CODEX_GOAL_STATE_HOMES="$homes_payload" CODEX_GOAL_STATE_DEST_HOMES="$dest_payload" CODEX_ACTIVE_DB_HOMES="$active_db_payload" python3 - <<'PY'
import os
import sqlite3
from pathlib import Path

def parse_home_lines(raw):
    parsed = []
    seen = set()
    for line in raw.splitlines():
        home = Path(line).expanduser()
        key = str(home)
        if key and key not in seen:
            seen.add(key)
            parsed.append(home)
    return parsed

raw_homes = os.environ.get("CODEX_GOAL_STATE_HOMES", "")
homes = parse_home_lines(raw_homes)
dest_homes = parse_home_lines(os.environ.get("CODEX_GOAL_STATE_DEST_HOMES", ""))
if not dest_homes:
    dest_homes = homes
active_db_homes = {str(home) for home in parse_home_lines(os.environ.get("CODEX_ACTIVE_DB_HOMES", ""))}

def table_columns(con, table):
    try:
        rows = con.execute(f"PRAGMA table_info({table})").fetchall()
    except sqlite3.Error:
        return []
    return [row[1] for row in rows]

def bootstrap_goal_db(template_db, target_db):
    if target_db.exists() or not template_db.exists():
        return
    target_db.parent.mkdir(parents=True, exist_ok=True)
    source = None
    dest = None
    try:
        source = sqlite3.connect(f"file:{template_db}?mode=ro", uri=True, timeout=3)
        dest = sqlite3.connect(target_db, timeout=6)
        source.execute("PRAGMA busy_timeout=3000")
        dest.execute("PRAGMA busy_timeout=6000")

        schema_rows = source.execute(
            """
            SELECT type, name, sql
            FROM sqlite_master
            WHERE sql IS NOT NULL
              AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type
              WHEN 'table' THEN 0
              WHEN 'index' THEN 1
              WHEN 'trigger' THEN 2
              ELSE 3
            END, name
            """
        ).fetchall()
        for _, _, sql in schema_rows:
            dest.execute(sql)

        if table_columns(source, "_sqlx_migrations") and table_columns(dest, "_sqlx_migrations"):
            cols = table_columns(source, "_sqlx_migrations")
            query_cols = ", ".join(f'"{col}"' for col in cols)
            placeholders = ", ".join("?" for _ in cols)
            for values in source.execute(f'SELECT {query_cols} FROM "_sqlx_migrations"'):
                dest.execute(
                    f'INSERT OR IGNORE INTO "_sqlx_migrations" ({query_cols}) VALUES ({placeholders})',
                    values,
                )
        dest.commit()
    except sqlite3.Error:
        try:
            if dest is not None:
                dest.rollback()
        except Exception:
            pass
        try:
            target_db.unlink()
        except Exception:
            pass
    finally:
        try:
            if source is not None:
                source.close()
        except Exception:
            pass
        try:
            if dest is not None:
                dest.close()
        except Exception:
            pass

def goal_marker(row):
    try:
        return int(row.get("updated_at_ms") or 0)
    except (TypeError, ValueError):
        return 0

template_db = next((home / "goals_1.sqlite" for home in homes if (home / "goals_1.sqlite").exists()), None)
if template_db is None:
    raise SystemExit(0)

for home in dest_homes:
    if str(home) in active_db_homes:
        continue
    bootstrap_goal_db(template_db, home / "goals_1.sqlite")

catalog = {}
for home in homes:
    db_path = home / "goals_1.sqlite"
    if not db_path.exists():
        continue
    con = None
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
        con.execute("PRAGMA busy_timeout=3000")
        cols = table_columns(con, "thread_goals")
        if not cols or "thread_id" not in cols:
            con.close()
            continue
        query_cols = ", ".join(f'"{col}"' for col in cols)
        for values in con.execute(f'SELECT {query_cols} FROM "thread_goals"'):
            row = dict(zip(cols, values))
            thread_id = row.get("thread_id")
            if not thread_id:
                continue
            existing = catalog.get(thread_id)
            if existing is None or goal_marker(row) >= goal_marker(existing):
                catalog[thread_id] = row
    except sqlite3.Error:
        pass
    finally:
        try:
            if con is not None:
                con.close()
        except Exception:
            pass

if not catalog:
    raise SystemExit(0)

for home in dest_homes:
    if str(home) in active_db_homes:
        continue
    db_path = home / "goals_1.sqlite"
    if not db_path.exists() or db_path.is_symlink():
        continue
    con = None
    try:
        con = sqlite3.connect(db_path, timeout=6)
        con.execute("PRAGMA busy_timeout=6000")
        dest_cols = table_columns(con, "thread_goals")
        if not dest_cols or "thread_id" not in dest_cols:
            con.close()
            continue

        for row in catalog.values():
            cols = [col for col in dest_cols if col in row]
            if "thread_id" not in cols:
                continue
            quoted_cols = ", ".join(f'"{col}"' for col in cols)
            placeholders = ", ".join("?" for _ in cols)
            update_cols = [col for col in cols if col != "thread_id"]
            updates = ", ".join(f'"{col}" = excluded."{col}"' for col in update_cols)
            sql = (
                f'INSERT INTO "thread_goals" ({quoted_cols}) VALUES ({placeholders}) '
                f'ON CONFLICT("thread_id") DO UPDATE SET {updates}'
            )
            con.execute(sql, [row.get(col) for col in cols])
        con.commit()
    except sqlite3.Error:
        try:
            con.rollback()
        except Exception:
            pass
    finally:
        try:
            if con is not None:
                con.close()
        except Exception:
            pass
PY
}

sync_global_state_for_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local homes_payload
  homes_payload="$(printf '%s\n' "${homes[@]}")"
  local dest_payload
  dest_payload="${CODEX_GLOBAL_STATE_DEST_HOMES:-}"
  local active_home_payload
  active_home_payload=""
  if [[ "$CODEX_SKIP_ACTIVE_STATE_DB_WRITES" == "1" ]]; then
    local -a active_probe_homes
    if [[ -n "$dest_payload" ]]; then
      active_probe_homes=("${(@f)dest_payload}")
    else
      active_probe_homes=("${homes[@]}")
    fi
    active_home_payload="$(active_sqlite_homes_payload "${active_probe_homes[@]}")"
  fi

  CODEX_GLOBAL_STATE_HOMES="$homes_payload" CODEX_GLOBAL_STATE_DEST_HOMES="$dest_payload" CODEX_ACTIVE_DB_HOMES="$active_home_payload" python3 - <<'PY'
import json
import os
import re
import shutil
import sqlite3
from pathlib import Path

def parse_home_lines(raw):
    parsed = []
    seen_homes = set()
    for line in raw.splitlines():
        home = Path(line).expanduser()
        key = str(home)
        if key and key not in seen_homes:
            seen_homes.add(key)
            parsed.append(home)
    return parsed

raw_homes = os.environ.get("CODEX_GLOBAL_STATE_HOMES", "")
homes = parse_home_lines(raw_homes)
dest_homes = parse_home_lines(os.environ.get("CODEX_GLOBAL_STATE_DEST_HOMES", ""))
if not dest_homes:
    dest_homes = homes
dest_home_keys = {str(home) for home in dest_homes}
active_home_keys = {str(home) for home in parse_home_lines(os.environ.get("CODEX_ACTIVE_DB_HOMES", ""))}

STATE_NAME = ".codex-global-state.json"
ROOT_LIST_KEYS = (
    "electron-saved-workspace-roots",
    "project-order",
)
SOURCE_ROOT_LIST_KEYS = ROOT_LIST_KEYS + (
    "active-workspace-roots",
)
DICT_KEYS = (
    "electron-workspace-root-labels",
    "thread-workspace-root-hints",
    "thread-project-assignments",
    "sidebar-project-thread-orders",
    "sidebar-thread-metadata",
    "thread-writable-roots",
    "thread-projectless-output-directories",
)

def normalized_path(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None

def load_state(path):
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else {}

def write_state(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(f"{path.name}.bak")
        if not backup.exists():
            try:
                shutil.copy2(path, backup)
            except OSError:
                pass
    tmp_path = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with tmp_path.open("w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(tmp_path, path)
    except OSError:
        try:
            tmp_path.unlink()
        except OSError:
            pass

def thread_marker(row):
    updated_ms, updated = row
    if updated_ms is not None:
        try:
            return int(updated_ms)
        except (TypeError, ValueError):
            pass
    if updated is not None:
        try:
            return int(updated) * 1000
        except (TypeError, ValueError):
            pass
    return 0

def state_db_paths(home):
    return (home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite")

def normalized_text(value):
    return str(value or "").strip()

def rollout_exists(value):
    path = normalized_text(value)
    if not path:
        return False
    try:
        return Path(path).exists()
    except OSError:
        return False

def list_ids(value):
    return set(str(item) for item in value if item) if isinstance(value, list) else set()

def dict_keys(value):
    return set(str(key) for key in value.keys() if key) if isinstance(value, dict) else set()

def root_is_present(value):
    root = normalized_path(value)
    if not root or not root.startswith("/"):
        return bool(root)
    try:
        return Path(root).exists()
    except OSError:
        return False

PROJECT_MARKER_FILES = (
    ".git",
    "package.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "pyproject.toml",
    "requirements.txt",
    "Package.swift",
    "Cargo.toml",
    "pom.xml",
    "build.gradle",
    "settings.gradle",
    "go.mod",
    "composer.json",
)

PROJECT_MARKER_GLOBS = (
    "*.xcodeproj",
    "*.xcworkspace",
    "*.sln",
    "*.csproj",
)

KEEP_GENERATED_CODEX_PROJECTS = os.environ.get("CODEX_KEEP_GENERATED_CODEX_PROJECTS") == "1"

def has_project_marker(root):
    try:
        path = Path(root)
    except OSError:
        return False
    if not path.exists() or not path.is_dir():
        return False
    for marker in PROJECT_MARKER_FILES:
        if (path / marker).exists():
            return True
    for pattern in PROJECT_MARKER_GLOBS:
        try:
            if next(path.glob(pattern), None) is not None:
                return True
        except OSError:
            pass
    return False

def is_generated_codex_workspace(root):
    return bool(
        re.search(r"/Documents/Codex/\d{4}-\d{2}-\d{2}/[^/]+/?$", root)
        or re.search(r"/MacOffload/\d{4}-\d{2}-\d{2}/Documents/[^/]+/?$", root)
    )

def root_is_real_project(value):
    root = normalized_path(value)
    if not root:
        return False
    if not root.startswith("/"):
        return True
    try:
        path = Path(root)
    except OSError:
        return False
    if not path.exists():
        return False
    if is_generated_codex_workspace(root):
        return KEEP_GENERATED_CODEX_PROJECTS and has_project_marker(root)
    return True

states = []
for home in homes:
    path = home / STATE_NAME
    data = load_state(path)
    if data is None:
        continue
    states.append((home, path, data))

if not states:
    raise SystemExit(0)

pinned_thread_ids = set()
projectless_thread_ids = set()
for _, _, data in states:
    pinned_thread_ids.update(list_ids(data.get("pinned-thread-ids")))
    projectless_thread_ids.update(list_ids(data.get("projectless-thread-ids")))
    projectless_thread_ids.update(dict_keys(data.get("thread-projectless-output-directories")))

root_order = []
root_seen = set()
valid_project_roots = set()
live_thread_ids = set()
merged_dicts = {key: {} for key in DICT_KEYS}

def add_root(value):
    root = normalized_path(value)
    if root and root not in root_seen:
        root_seen.add(root)
        root_order.append(root)

for _, _, data in states:
    for key in SOURCE_ROOT_LIST_KEYS:
        values = data.get(key)
        if isinstance(values, list):
            for value in values:
                add_root(value)
    labels = data.get("electron-workspace-root-labels")
    if isinstance(labels, dict):
        for root in labels.keys():
            add_root(root)
    for key in DICT_KEYS:
        value = data.get(key)
        if not isinstance(value, dict):
            continue
        for item_key, item_value in value.items():
            if isinstance(item_key, str) and item_key and item_key not in merged_dicts[key]:
                merged_dicts[key][item_key] = item_value

root_recency = {}
thread_cwds = {}
project_thread_ids = set()
for home in homes:
    for db_path in state_db_paths(home):
        if not db_path.exists():
            continue
        con = None
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
            con.execute("PRAGMA busy_timeout=2000")
            cols = {row[1] for row in con.execute("PRAGMA table_info(threads)").fetchall()}
            required = {"id", "cwd", "updated_at", "archived", "rollout_path"}
            if not required.issubset(cols):
                continue
            updated_ms_expr = "updated_at_ms" if "updated_at_ms" in cols else "NULL"
            preview_expr = "preview" if "preview" in cols else "title"
            title_expr = "title" if "title" in cols else "''"
            rows = con.execute(
                f"""
                SELECT id, cwd, {updated_ms_expr}, updated_at, archived,
                       {preview_expr}, {title_expr}, rollout_path
                FROM threads
                WHERE cwd IS NOT NULL AND cwd <> ''
                """
            )
            for thread_id, cwd, updated_ms, updated, archived, preview, title, rollout_path in rows:
                root = normalized_path(cwd)
                if not root:
                    continue
                live_thread = (
                    int(archived or 0) == 0
                    and bool(normalized_text(preview) or normalized_text(title))
                    and rollout_exists(rollout_path)
                )
                if not live_thread:
                    continue
                add_root(root)
                thread_key = str(thread_id) if thread_id else ""
                if thread_key:
                    live_thread_ids.add(thread_key)
                if not root_is_real_project(root):
                    if thread_key:
                        projectless_thread_ids.add(thread_key)
                    continue
                add_root(root)
                if thread_key and (thread_key in pinned_thread_ids or thread_key in projectless_thread_ids):
                    continue
                if thread_key:
                    thread_cwds[thread_key] = root
                    project_thread_ids.add(thread_key)
                valid_project_roots.add(root)
                marker = thread_marker((updated_ms, updated))
                if marker > root_recency.get(root, 0):
                    root_recency[root] = marker
        except sqlite3.Error:
            pass
        finally:
            try:
                if con is not None:
                    con.close()
            except Exception:
                pass

root_position = {root: index for index, root in enumerate(root_order)}
merged_roots = sorted(
    [root for root in root_order if root in valid_project_roots],
    key=lambda root: (-root_recency.get(root, 0), root_position.get(root, 0)),
)
merged_root_set = set(merged_roots)
if thread_cwds:
    merged_dicts["thread-workspace-root-hints"].update(thread_cwds)

for home, path, data in states:
    if str(home) not in dest_home_keys or str(home) in active_home_keys:
        continue
    next_data = dict(data)
    for key in ROOT_LIST_KEYS:
        next_data[key] = merged_roots
    for key in DICT_KEYS:
        current = next_data.get(key)
        merged = dict(merged_dicts[key])
        if isinstance(current, dict):
            merged.update(current)
        if key == "thread-workspace-root-hints" and thread_cwds:
            merged.update(thread_cwds)
        if key == "electron-workspace-root-labels":
            merged = {root: value for root, value in merged.items() if root in merged_root_set}
        elif key == "sidebar-project-thread-orders":
            pruned = {}
            for root, value in merged.items():
                if root not in merged_root_set:
                    continue
                if isinstance(value, list):
                    kept = [thread_id for thread_id in value if str(thread_id) in project_thread_ids and str(thread_id) not in pinned_thread_ids]
                    if kept:
                        pruned[root] = kept
                else:
                    pruned[root] = value
            merged = pruned
        elif key in {
            "thread-workspace-root-hints",
            "thread-project-assignments",
            "thread-writable-roots",
        }:
            merged = {thread_id: value for thread_id, value in merged.items() if str(thread_id) in project_thread_ids}
        elif key in {
            "sidebar-thread-metadata",
            "thread-projectless-output-directories",
        }:
            merged = {thread_id: value for thread_id, value in merged.items() if str(thread_id) in live_thread_ids}
        if merged:
            next_data[key] = merged
        elif key in next_data:
            next_data.pop(key, None)

    projectless = next_data.get("projectless-thread-ids")
    if isinstance(projectless, list):
        ordered_projectless = []
        seen_projectless = set()
        for thread_id in projectless:
            thread_key = str(thread_id)
            if thread_key in projectless_thread_ids and thread_key in live_thread_ids and thread_key not in seen_projectless:
                seen_projectless.add(thread_key)
                ordered_projectless.append(thread_id)
        for thread_id in sorted(projectless_thread_ids - seen_projectless):
            if thread_id in live_thread_ids:
                ordered_projectless.append(thread_id)
        next_data["projectless-thread-ids"] = ordered_projectless
    elif projectless_thread_ids:
        next_data["projectless-thread-ids"] = sorted(thread_id for thread_id in projectless_thread_ids if thread_id in live_thread_ids)

    if next_data != data:
        write_state(path, next_data)
PY
}

sync_thread_index_for_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local homes_payload
  homes_payload="$(printf '%s\n' "${homes[@]}")"
  local dest_payload
  dest_payload="${CODEX_THREAD_INDEX_DEST_HOMES:-}"
  local active_db_payload
  active_db_payload=""
  if [[ "$CODEX_SKIP_ACTIVE_STATE_DB_WRITES" == "1" ]]; then
    local -a active_probe_homes
    if [[ -n "$dest_payload" ]]; then
      active_probe_homes=("${(@f)dest_payload}")
    else
      active_probe_homes=("${homes[@]}")
    fi
    active_db_payload="$(active_sqlite_homes_payload "${active_probe_homes[@]}")"
  fi

  CODEX_THREAD_INDEX_HOMES="$homes_payload" CODEX_THREAD_INDEX_DEST_HOMES="$dest_payload" CODEX_ACTIVE_DB_HOMES="$active_db_payload" python3 - <<'PY'
import os
import json
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

def parse_home_lines(raw):
    parsed = []
    seen = set()
    for line in raw.splitlines():
        home = Path(line).expanduser()
        key = str(home)
        if key and key not in seen:
            seen.add(key)
            parsed.append(home)
    return parsed

raw_homes = os.environ.get("CODEX_THREAD_INDEX_HOMES", "")
homes = parse_home_lines(raw_homes)
dest_homes = parse_home_lines(os.environ.get("CODEX_THREAD_INDEX_DEST_HOMES", ""))
if not dest_homes:
    dest_homes = homes
active_db_homes = {str(home) for home in parse_home_lines(os.environ.get("CODEX_ACTIVE_DB_HOMES", ""))}

table_specs = [
    ("threads", ("id",), ("updated_at_ms", "updated_at")),
    ("thread_dynamic_tools", ("thread_id", "position"), ()),
    ("thread_spawn_edges", ("child_thread_id",), ()),
    ("stage1_outputs", ("thread_id",), ("source_updated_at",)),
]

def state_db_paths(home):
    return (home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite")

def session_relative_path(rollout_path):
    if not rollout_path:
        return None
    path = str(rollout_path)
    marker = "/sessions/"
    if marker not in path:
        return None
    return path.split(marker, 1)[1].lstrip("/")

def normalize_thread_rollout_path(row, home):
    rel = row.get("__session_rel")
    if not rel:
        rel = session_relative_path(row.get("rollout_path"))
    if not rel:
        return row.get("rollout_path")
    return str(home / "sessions" / rel)

def thread_updated_at_iso(row):
    raw_ms = row.get("updated_at_ms")
    raw_seconds = row.get("updated_at")
    timestamp = None
    if raw_ms is not None:
        try:
            timestamp = int(raw_ms) / 1000
        except (TypeError, ValueError):
            timestamp = None
    if timestamp is None and raw_seconds is not None:
        try:
            timestamp = int(raw_seconds)
        except (TypeError, ValueError):
            timestamp = None
    if timestamp is None:
        timestamp = 0
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")

def thread_index_name(row):
    best_name = None
    best_score = -1
    for key in ("title", "preview"):
        value = str(row.get(key) or "").strip()
        if not value:
            continue
        for line in value.splitlines():
            name = " ".join(line.split())
            if not name:
                continue
            score = title_text_score(name, row, key)
            if score > best_score:
                best_name = name
                best_score = score
                if score >= 100:
                    break
        if best_score >= 100:
            break
    if best_name:
        if len(best_name) > 80:
            return best_name[:77].rstrip() + "..."
        return best_name
    return "Untitled"

def first_nonempty_line(value):
    for line in str(value or "").splitlines():
        candidate = " ".join(line.split())
        if candidate:
            return candidate
    return ""

def compact_text(value):
    return " ".join(str(value or "").split())

def looks_like_filesystem_path(value, row=None):
    text = first_nonempty_line(value)
    if not text:
        return False
    cwd = ""
    if row is not None:
        cwd = str(row.get("cwd") or "").strip()
    path_prefixes = (
        "/Users/",
        "/Volumes/",
        "/private/",
        "/tmp/",
        "/var/",
        "~/",
    )
    if cwd and (text == cwd or text.startswith(cwd + " ") or text.startswith(cwd + "\t")):
        return True
    if any(text.startswith(prefix) for prefix in path_prefixes):
        return True
    return False

def title_text_score(value, row=None, field="title"):
    raw = str(value or "")
    text = first_nonempty_line(raw)
    if not text or text == "Untitled":
        return 0
    if looks_like_filesystem_path(text, row):
        return 1

    same_as_preview = False
    if field == "title" and row is not None:
        preview = compact_text(row.get("preview"))
        same_as_preview = bool(preview and compact_text(raw) == preview)

    if "\n" in raw:
        return 30 if same_as_preview else 40
    if same_as_preview and len(text) > 48:
        return 35
    if row is None and len(text) > 48 and any(mark in text for mark in ("?", "？", "!", "！", "。", "，", ",")):
        return 55
    if len(text) > 120:
        return 45
    if len(text) > 80:
        return 60
    if same_as_preview:
        return 75
    return 100

def best_thread_text(left, right, field):
    left_value = str(left.get(field) or "")
    right_value = str(right.get(field) or "")
    left_score = title_text_score(left_value, left, field)
    right_score = title_text_score(right_value, right, field)
    if right_score > left_score:
        return right.get(field)
    if left_score > right_score:
        return left.get(field)
    if row_marker(right, ("updated_at_ms", "updated_at")) > row_marker(left, ("updated_at_ms", "updated_at")):
        return right.get(field)
    return left.get(field)

def merge_thread_rows(existing, incoming):
    if existing is None:
        return dict(incoming)
    if row_marker(incoming, ("updated_at_ms", "updated_at")) >= row_marker(existing, ("updated_at_ms", "updated_at")):
        merged = dict(incoming)
        other = existing
    else:
        merged = dict(existing)
        other = incoming
    for field in ("title", "preview"):
        if field in merged and field in other:
            merged[field] = best_thread_text(merged, other, field)
    return merged

def thread_has_live_rollout(row):
    rollout_path = str(row.get("rollout_path") or "").strip()
    if not rollout_path:
        return False
    try:
        return Path(rollout_path).exists()
    except OSError:
        return False

def thread_is_indexable(row):
    try:
        if int(row.get("archived") or 0) != 0:
            return False
    except (TypeError, ValueError):
        return False
    if not (str(row.get("preview") or "").strip() or str(row.get("title") or "").strip()):
        return False
    return thread_has_live_rollout(row)

def session_index_records():
    records = {}
    for row in catalog.get("threads", {}).values():
        thread_id = row.get("id")
        if not thread_id:
            continue
        if not thread_is_indexable(row):
            continue
        records[str(thread_id)] = {
            "id": str(thread_id),
            "thread_name": thread_index_name(row),
            "updated_at": thread_updated_at_iso(row),
        }
    return records

def session_index_paths_for_homes(homes):
    paths = []
    seen_paths = set()
    for home in homes:
        path = home / "session_index.jsonl"
        try:
            resolved = path.resolve(strict=False) if path.is_symlink() else path
        except OSError:
            resolved = path
        key = str(resolved)
        if key not in seen_paths:
            seen_paths.add(key)
            paths.append(resolved)
    return paths

def repair_session_index_files(homes):
    thread_records = session_index_records()
    if not thread_records:
        return

    for index_path in session_index_paths_for_homes(homes):
        existing_lines = []
        seen_ids = set()
        changed = False
        if index_path.exists():
            try:
                with index_path.open("r", encoding="utf-8") as handle:
                    for line in handle:
                        raw_line = line.rstrip("\n")
                        if not raw_line:
                            continue
                        try:
                            record = json.loads(raw_line)
                        except json.JSONDecodeError:
                            existing_lines.append(raw_line)
                            continue

                        thread_id = str(record.get("id") or "")
                        if thread_id:
                            if thread_id in seen_ids:
                                changed = True
                                continue
                            fresh = thread_records.get(thread_id)
                            if not fresh:
                                changed = True
                                continue
                            seen_ids.add(thread_id)
                            existing_updated = str(record.get("updated_at") or "")
                            if fresh["updated_at"] > existing_updated:
                                record["updated_at"] = fresh["updated_at"]
                                changed = True
                            existing_name = str(record.get("thread_name") or "").strip()
                            fresh_name = str(fresh.get("thread_name") or "").strip()
                            if (
                                not existing_name
                                or title_text_score(fresh_name) > title_text_score(existing_name)
                                or (
                                    fresh_name != existing_name
                                    and title_text_score(fresh_name) >= title_text_score(existing_name)
                                    and len(fresh_name) + 12 < len(existing_name)
                                )
                                or (len(existing_name) > 80 and len(fresh_name) < len(existing_name))
                            ):
                                record["thread_name"] = fresh["thread_name"]
                                changed = True
                        existing_lines.append(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
            except OSError:
                continue

        missing_records = [record for thread_id, record in thread_records.items() if thread_id not in seen_ids]
        if missing_records:
            missing_records.sort(key=lambda record: record.get("updated_at", ""))
            existing_lines.extend(json.dumps(record, ensure_ascii=False, separators=(",", ":")) for record in missing_records)
            changed = True

        if not changed:
            continue

        try:
            index_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = index_path.with_name(f".{index_path.name}.tmp-{os.getpid()}")
            with tmp_path.open("w", encoding="utf-8") as handle:
                if existing_lines:
                    handle.write("\n".join(existing_lines))
                    handle.write("\n")
            os.replace(tmp_path, index_path)
        except OSError:
            try:
                tmp_path.unlink()
            except Exception:
                pass

def bootstrap_state_db(template_db, target_db):
    if target_db.exists() or not template_db.exists():
        return
    target_db.parent.mkdir(parents=True, exist_ok=True)
    try:
        source = sqlite3.connect(f"file:{template_db}?mode=ro", uri=True, timeout=3)
        dest = sqlite3.connect(target_db, timeout=6)
        source.execute("PRAGMA busy_timeout=3000")
        dest.execute("PRAGMA busy_timeout=6000")

        schema_rows = source.execute(
            """
            SELECT type, name, sql
            FROM sqlite_master
            WHERE sql IS NOT NULL
              AND name NOT LIKE 'sqlite_%'
            ORDER BY CASE type
              WHEN 'table' THEN 0
              WHEN 'index' THEN 1
              WHEN 'trigger' THEN 2
              ELSE 3
            END, name
            """
        ).fetchall()
        for _, _, sql in schema_rows:
            dest.execute(sql)

        if table_columns(source, "_sqlx_migrations") and table_columns(dest, "_sqlx_migrations"):
            cols = table_columns(source, "_sqlx_migrations")
            query_cols = ", ".join(f'"{col}"' for col in cols)
            placeholders = ", ".join("?" for _ in cols)
            for values in source.execute(f'SELECT {query_cols} FROM "_sqlx_migrations"'):
                dest.execute(
                    f'INSERT OR IGNORE INTO "_sqlx_migrations" ({query_cols}) VALUES ({placeholders})',
                    values,
                )
        dest.commit()
    except sqlite3.Error:
        try:
            dest.rollback()
        except Exception:
            pass
        try:
            target_db.unlink()
        except Exception:
            pass
    finally:
        try:
            source.close()
        except Exception:
            pass
        try:
            dest.close()
        except Exception:
            pass

def table_columns(con, table):
    try:
        rows = con.execute(f"PRAGMA table_info({table})").fetchall()
    except sqlite3.Error:
        return []
    return [row[1] for row in rows]

def row_marker(row, marker_cols):
    for col in marker_cols:
        value = row.get(col)
        if value is not None:
            try:
                return int(value)
            except (TypeError, ValueError):
                return 0
    return 0

def mark_backfill_complete(con):
    if not table_columns(con, "backfill_state"):
        return
    now = int(time.time())
    con.execute(
        """
        INSERT INTO backfill_state(id, status, last_watermark, last_success_at, updated_at)
        VALUES (1, 'complete', NULL, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          status = 'complete',
          last_success_at = ?,
          updated_at = ?
        """,
        (now, now, now, now),
    )

catalog = {name: {} for name, _, _ in table_specs}

template_db = next((db_path for home in homes for db_path in state_db_paths(home) if db_path.exists()), None)
if template_db is not None:
    for home in dest_homes:
        if str(home) in active_db_homes:
            continue
        bootstrap_state_db(template_db, home / "state_5.sqlite")

for home in homes:
    for db_path in state_db_paths(home):
        if not db_path.exists():
            continue
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
            con.execute("PRAGMA busy_timeout=3000")
        except sqlite3.Error:
            continue

        try:
            for table, key_cols, marker_cols in table_specs:
                cols = table_columns(con, table)
                if not cols or any(key not in cols for key in key_cols):
                    continue
                query_cols = ", ".join(f'"{col}"' for col in cols)
                for values in con.execute(f'SELECT {query_cols} FROM "{table}"'):
                    row = dict(zip(cols, values))
                    key = tuple(row.get(col) for col in key_cols)
                    if any(part is None for part in key):
                        continue
                    if table == "threads":
                        rel = session_relative_path(row.get("rollout_path"))
                        if rel:
                            row["__session_rel"] = rel
                        if not thread_is_indexable(row):
                            continue
                    existing = catalog[table].get(key)
                    if table == "threads":
                        catalog[table][key] = merge_thread_rows(existing, row)
                    elif existing is None:
                        catalog[table][key] = row
                    elif marker_cols and row_marker(row, marker_cols) >= row_marker(existing, marker_cols):
                        catalog[table][key] = row
        except sqlite3.Error:
            pass
        finally:
            con.close()

for home in dest_homes:
    if str(home) in active_db_homes:
        continue
    for db_path in state_db_paths(home):
        if not db_path.exists() or db_path.is_symlink():
            continue
        try:
            con = sqlite3.connect(db_path, timeout=6)
            con.execute("PRAGMA busy_timeout=6000")
            con.execute("PRAGMA foreign_keys=OFF")
        except sqlite3.Error:
            continue

        try:
            for table, key_cols, _ in table_specs:
                dest_cols = table_columns(con, table)
                if not dest_cols or any(key not in dest_cols for key in key_cols):
                    continue
                for row in catalog[table].values():
                    write_row = dict(row)
                    if table == "threads" and "rollout_path" in dest_cols:
                        write_row["rollout_path"] = normalize_thread_rollout_path(write_row, home)
                    cols = [col for col in dest_cols if col in write_row]
                    if any(key not in cols for key in key_cols):
                        continue
                    placeholders = ", ".join("?" for _ in cols)
                    quoted_cols = ", ".join(f'"{col}"' for col in cols)
                    conflict_cols = ", ".join(f'"{col}"' for col in key_cols)
                    update_cols = [col for col in cols if col not in key_cols]
                    if update_cols:
                        updates = ", ".join(f'"{col}" = excluded."{col}"' for col in update_cols)
                        sql = (
                            f'INSERT INTO "{table}" ({quoted_cols}) VALUES ({placeholders}) '
                            f'ON CONFLICT({conflict_cols}) DO UPDATE SET {updates}'
                        )
                    else:
                        sql = (
                            f'INSERT OR IGNORE INTO "{table}" ({quoted_cols}) '
                            f'VALUES ({placeholders})'
                        )
                    con.execute(sql, [write_row.get(col) for col in cols])
            mark_backfill_complete(con)
            con.commit()
        except sqlite3.Error:
            con.rollback()
        finally:
            con.close()

repair_session_index_files(dest_homes)
PY
}

sync_message() {
  if [[ "$CODEX_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    echo "Synced local Codex memory, plugin payloads, skills, and config at $(date '+%Y-%m-%d %H:%M:%S')."
  elif [[ "$CODEX_FAST_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    echo "Synced local Codex memory, current plugin payloads, skills, and config at $(date '+%Y-%m-%d %H:%M:%S')."
  elif [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" && "$CODEX_SYNC_PLUGIN_CONFIG" == "1" ]]; then
    echo "Synced local Codex memory, workspace state, conversation indexes, goal state, and plugin config at $(date '+%Y-%m-%d %H:%M:%S')."
  elif [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    echo "Synced local Codex memory, workspace state, conversation indexes, and goal state at $(date '+%Y-%m-%d %H:%M:%S')."
  elif [[ "$CODEX_SYNC_PLUGIN_CONFIG" == "1" ]]; then
    echo "Synced local Codex memory, config, and plugin config at $(date '+%Y-%m-%d %H:%M:%S')."
  else
    echo "Synced local Codex memory and config at $(date '+%Y-%m-%d %H:%M:%S')."
  fi
}

cleanup_thread_indexes_for_homes() {
  local home_dir
  for home_dir in "$@"; do
    if [[ "$CODEX_DELETE_STALE_THREAD_ROWS" == "1" ]]; then
      cleanup_thread_index_for_home "$home_dir" >/dev/null 2>&1 || true
    fi
    if [[ "$CODEX_PRUNE_GLOBAL_STATE_ON_SYNC" == "1" ]]; then
      prune_global_state_for_home "$home_dir" >/dev/null 2>&1 || true
    fi
  done
}

sync_selected_homes() {
  local -a homes
  local -a history_homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  sync_memory_and_config_for_homes "${homes[@]}"
  sync_plugin_payloads_for_homes "${homes[@]}"
  history_homes=("${(@f)$(shared_history_homes "${homes[@]}")}")
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    if (( ${#history_homes[@]} > 0 )) && [[ -n "${history_homes[1]:-}" ]]; then
      sync_thread_index_for_homes "${history_homes[@]}"
      sync_global_state_for_homes "${history_homes[@]}"
      sync_goal_state_for_homes "${history_homes[@]}"
    fi
  fi
  cleanup_thread_indexes_for_homes "${history_homes[@]}"
  sync_message
}

sync_history_selected_homes() {
  local -a homes
  local -a history_homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  history_homes=("${(@f)$(shared_history_homes "${homes[@]}")}")
  if (( ${#history_homes[@]} == 0 )) || [[ -z "${history_homes[1]:-}" ]]; then
    echo "No shared Codex history profiles selected."
    return 0
  fi

  local home_dir
  for home_dir in "${history_homes[@]}"; do
    seed_shared_history_from_home "$home_dir"
  done
  CODEX_SYNC_THREAD_HISTORY=1
  sync_thread_index_for_homes "${history_homes[@]}"
  sync_global_state_for_homes "${history_homes[@]}"
  sync_goal_state_for_homes "${history_homes[@]}"
  cleanup_thread_indexes_for_homes "${history_homes[@]}"
  echo "Synced shared Codex history for inactive profiles at $(date '+%Y-%m-%d %H:%M:%S'). Active profiles finish syncing before their next launch."
}

dedupe_homes() {
  local -A seen
  local home_dir
  for home_dir in "$@"; do
    [[ -n "$home_dir" ]] || continue
    if [[ -z "${seen[$home_dir]:-}" ]]; then
      seen[$home_dir]=1
      printf '%s\n' "$home_dir"
    fi
  done
}

sync_thread_index_to_selected_homes() {
  local dest_count="$1"
  shift || true
  local -a dest_homes source_homes
  local i
  for (( i = 1; i <= dest_count; i++ )); do
    [[ $# -gt 0 ]] || break
    dest_homes+=("$1")
    shift
  done
  source_homes=("$@")
  local dest_payload
  dest_payload="$(printf '%s\n' "${dest_homes[@]}")"
  CODEX_THREAD_INDEX_DEST_HOMES="$dest_payload" sync_thread_index_for_homes "${source_homes[@]}"
}

sync_goal_state_to_selected_homes() {
  local dest_count="$1"
  shift || true
  local -a dest_homes source_homes
  local i
  for (( i = 1; i <= dest_count; i++ )); do
    [[ $# -gt 0 ]] || break
    dest_homes+=("$1")
    shift
  done
  source_homes=("$@")
  local dest_payload
  dest_payload="$(printf '%s\n' "${dest_homes[@]}")"
  CODEX_GOAL_STATE_DEST_HOMES="$dest_payload" sync_goal_state_for_homes "${source_homes[@]}"
}

sync_global_state_to_selected_homes() {
  local dest_count="$1"
  shift || true
  local -a dest_homes source_homes
  local i
  for (( i = 1; i <= dest_count; i++ )); do
    [[ $# -gt 0 ]] || break
    dest_homes+=("$1")
    shift
  done
  source_homes=("$@")
  local dest_payload
  dest_payload="$(printf '%s\n' "${dest_homes[@]}")"
  CODEX_GLOBAL_STATE_DEST_HOMES="$dest_payload" sync_global_state_for_homes "${source_homes[@]}"
}

collect_account_homes() {
  local home_dir raw_home
  while IFS='|' read -r _ raw_home _; do
    home_dir="$(echo "$raw_home" | xargs)"
    [[ -n "$home_dir" ]] || continue
    printf '%s\n' "$home_dir"
  done < <(list_accounts)
}

refresh_shared_history_for_home() {
  local target_home="$1"
  [[ "$CODEX_SHARED_SESSIONS" == "1" ]] || return 0
  [[ -n "$target_home" ]] || return 0
  [[ "$(history_mode_for_home "$target_home")" == "shared" ]] || return 0

  local home_dir
  local -a homes
  homes=()
  while read -r home_dir; do
    [[ -n "$home_dir" ]] || continue
    homes+=("$home_dir")
  done < <(collect_account_homes)
  homes+=("$CODEX_HISTORY_ANCHOR_HOME" "$target_home")
  homes=("${(@f)$(dedupe_homes "${homes[@]}")}")
  homes=("${(@f)$(shared_history_homes "${homes[@]}")}")

  seed_shared_history_from_home "$CODEX_HISTORY_ANCHOR_HOME"
  seed_shared_history_from_home "$target_home"
  local previous_skip_active
  previous_skip_active="$CODEX_SKIP_ACTIVE_STATE_DB_WRITES"
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES=0
  sync_thread_index_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  sync_global_state_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  sync_goal_state_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES="$previous_skip_active"
  restore_account1_visible_thread_model_providers_for_home "$target_home" >/dev/null 2>&1 || true
}

repair_account1() {
  require_rsync
  ensure_dirs
  configure_account1_aliyun_proxy_for_home "$PRIMARY_CODEX_HOME"
  refresh_shared_history_for_home "$PRIMARY_CODEX_HOME"
  normalize_thread_sources_for_home "$PRIMARY_CODEX_HOME"
  restore_account1_visible_thread_model_providers_for_home "$PRIMARY_CODEX_HOME"
  CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH=1 \
    repair_compacted_image_payloads_for_home "$PRIMARY_CODEX_HOME" || return $?
  prune_global_state_for_home "$PRIMARY_CODEX_HOME" >/dev/null 2>&1 || true
}

repair_compactions_for_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "repair-compactions requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"
  CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH=1 \
    repair_compacted_image_payloads_for_home "$account_home"
}

sync_once() {
  require_rsync
  ensure_dirs

  local homes=()
  local home_dir
  while read -r home_dir; do
    homes+=("$home_dir")
  done < <(collect_account_homes)

  CODEX_SYNC_LOCK_MAX_WAITS="$CODEX_AUTO_SYNC_LOCK_MAX_WAITS" with_sync_lock sync_selected_homes "${homes[@]}"
}

sync_history_once() {
  require_rsync
  ensure_dirs

  local homes=()
  local home_dir
  while read -r home_dir; do
    homes+=("$home_dir")
  done < <(collect_account_homes)

  CODEX_SYNC_LOCK_MAX_WAITS="$CODEX_AUTO_SYNC_LOCK_MAX_WAITS" with_sync_lock sync_history_selected_homes "${homes[@]}"
}

sync_history_loop() {
  ensure_dirs
  while true; do
    sync_history_once || true
    sleep "$SYNC_INTERVAL_SECONDS"
  done
}

sync_account_unlocked() {
  local name="$1"
  local target_home home_dir
  local -a all_homes payload_homes history_homes
  target_home="$(account_home_for "$name")"
  mkdir -p "$target_home"

  all_homes=()
  while read -r home_dir; do
    all_homes+=("$home_dir")
  done < <(collect_account_homes)

  payload_homes=("$PRIMARY_CODEX_HOME")
  if [[ "$target_home" != "$PRIMARY_CODEX_HOME" ]]; then
    payload_homes+=("$target_home")
  fi

  sync_memory_and_config_for_homes "${all_homes[@]}"
  sync_plugin_payloads_for_homes "${payload_homes[@]}"
  history_homes=("${(@f)$(shared_history_homes "${all_homes[@]}")}")
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    if (( ${#history_homes[@]} > 0 )) && [[ -n "${history_homes[1]:-}" ]]; then
      sync_thread_index_for_homes "${history_homes[@]}"
      sync_global_state_for_homes "${history_homes[@]}"
      sync_goal_state_for_homes "${history_homes[@]}"
    fi
  fi
  cleanup_thread_indexes_for_homes "${history_homes[@]}"
  sync_message
}

sync_account_prelaunch_unlocked() {
  local name="$1"
  local target_home home_dir
  local -a all_homes dest_homes payload_homes history_homes
  target_home="$(account_home_for "$name")"
  mkdir -p "$target_home"

  all_homes=()
  while read -r home_dir; do
    all_homes+=("$home_dir")
  done < <(collect_account_homes)

  dest_homes=("${(@f)$(dedupe_homes "$PRIMARY_CODEX_HOME" "$target_home")}")
  payload_homes=("${dest_homes[@]}")

  sync_debug "prelaunch memory account=$name"
  sync_memory_and_config_to_selected_homes "${#dest_homes[@]}" "${dest_homes[@]}" "${all_homes[@]}"
  if [[ "$CODEX_PRELAUNCH_PLUGIN_PAYLOADS" == "1" ]]; then
    sync_debug "prelaunch plugin-payloads account=$name"
    sync_plugin_payloads_for_homes "${payload_homes[@]}"
  fi
  history_homes=("${(@f)$(shared_history_homes "${all_homes[@]}")}")
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    if [[ "$(history_mode_for_home "$target_home")" == "shared" && ${#history_homes[@]} -gt 0 && -n "${history_homes[1]:-}" ]]; then
      sync_debug "prelaunch global-state account=$name"
      sync_global_state_to_selected_homes 1 "$target_home" "${history_homes[@]}"
      sync_debug "prelaunch thread-index account=$name"
      sync_thread_index_to_selected_homes 1 "$target_home" "${history_homes[@]}"
      sync_debug "prelaunch global-state-prune account=$name"
      sync_global_state_to_selected_homes 1 "$target_home" "${history_homes[@]}"
      sync_debug "prelaunch goal-state account=$name"
      sync_goal_state_to_selected_homes 1 "$target_home" "${history_homes[@]}"
    fi
  fi
  sync_debug "prelaunch thread-index-cleanup account=$name"
  cleanup_thread_indexes_for_homes "${history_homes[@]}"
  sync_debug "prelaunch complete account=$name"
  sync_message
}

sync_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "sync-account requires an account name." >&2
    exit 2
  fi

  require_rsync
  ensure_dirs

  with_sync_lock sync_account_unlocked "$name"
}

sync_account_for_launch() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "sync-account-for-launch requires an account name." >&2
    exit 2
  fi

  require_rsync
  ensure_dirs

  CODEX_SYNC_LOCK_MAX_WAITS="$CODEX_PRELAUNCH_SYNC_LOCK_MAX_WAITS" CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock sync_account_prelaunch_unlocked "$name"
}

sync_loop() {
  echo "Syncing every $SYNC_INTERVAL_SECONDS seconds. Press Ctrl-C to stop."
  while true; do
    sync_once
    sleep "$SYNC_INTERVAL_SECONDS"
  done
}

launch_account2() {
  launch_account "account2"
}

stop_pids() {
  local label="$1"
  shift || true
  local pids=("$@")

  if (( ${#pids[@]} == 0 )); then
    return 0
  fi

  echo "$label: ${pids[*]}"
  if [[ "${CODEX_CLOSE_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  kill -TERM "${pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  for pid in "${pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

process_has_active_agent_descendant() {
  local root_pid="$1"
  local current_pid child_pid args seen_count
  local -a queue children
  queue=("$root_pid")
  seen_count=0

  while (( ${#queue[@]} > 0 && seen_count < 300 )); do
    current_pid="${queue[1]}"
    queue=("${queue[@]:1}")
    seen_count=$(( seen_count + 1 ))
    children=("${(@f)$(pgrep -P "$current_pid" 2>/dev/null || true)}")
    for child_pid in "${children[@]}"; do
      [[ -n "$child_pid" ]] || continue
      args="$(ps -p "$child_pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *"codex app-server --listen stdio://"* \
            || "$args" == *"app-server proxy"* \
            || "$args" == *"node_repl"* \
            || "$args" == *"SkyComputerUseClient"* ]]; then
        return 0
      fi
      queue+=("$child_pid")
    done
  done

  return 1
}

is_codex_gui_process_args() {
  local args="$1"
  local app_path

  for app_path in "${CODEX_GUI_APP_PATHS[@]}"; do
    if [[ "$args" == "$app_path/Contents/MacOS/ChatGPT"* \
      || "$args" == "$app_path/Contents/MacOS/Codex"* ]]; then
      return 0
    fi
  done
  return 1
}

stop_codex_windows_for_app_data() {
  local app_data="$1"
  local pids=()
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    is_codex_gui_process_args "$args" || continue
    if args_has_user_data_dir "$args" "$app_data"; then
      pids+=("$pid")
      continue
    fi
    if [[ "$app_data" == "$HOME/Library/Application Support/Codex" && "$args" != *"--user-data-dir="* ]]; then
      pids+=("$pid")
    fi
  done < <(ps axww -o pid= -o args=)

  if [[ "${CODEX_SKIP_ACTIVE_AGENT_WINDOWS:-0}" == "1" && ${#pids[@]} -gt 0 ]]; then
    local kept_pids=()
    local close_pids=()
    for pid in "${pids[@]}"; do
      if process_has_active_agent_descendant "$pid"; then
        kept_pids+=("$pid")
      else
        close_pids+=("$pid")
      fi
    done
    if (( ${#kept_pids[@]} > 0 )); then
      echo "Keeping active Codex window(s): ${kept_pids[*]}"
    fi
    pids=("${close_pids[@]}")
  fi

  stop_pids "Closing existing Codex window(s) for this profile" "${pids[@]}"
}

process_env_contains() {
  local pid="$1"
  local needle="$2"
  ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$needle"
}

args_has_user_data_dir() {
  local args="$1"
  local app_data="$2"
  [[ "$args" == *"--user-data-dir=$app_data" || "$args" == *"--user-data-dir=$app_data --"* ]]
}

stop_codex_servers_for_home() {
  local home_dir="$1"
  local pids=()
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    [[ "$args" == *"codex app-server"* ]] || continue
    [[ "$args" == *"--listen stdio://"* ]] && continue
    [[ "$args" == *"app-server proxy"* ]] && continue
    if [[ "$args" == *"--codex-home $home_dir"* || "$args" == *"--codex-home=$home_dir"* ]] || process_env_contains "$pid" "CODEX_HOME=$home_dir"; then
      if [[ "${CODEX_SKIP_ACTIVE_AGENT_WINDOWS:-0}" == "1" ]] && process_has_active_agent_descendant "$pid"; then
        echo "Keeping active Codex app-server: $pid"
        continue
      fi
      pids+=("$pid")
    fi
  done < <(ps axww -o pid= -o args=)

  stop_pids "Closing stale Codex app-server(s) for this profile" "${pids[@]}"
}

matching_codex_window_pids_for_app_data() {
  local app_data="$1"
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    is_codex_gui_process_args "$args" || continue
    if args_has_user_data_dir "$args" "$app_data"; then
      printf '%s\n' "$pid"
      continue
    fi
    if [[ "$app_data" == "$HOME/Library/Application Support/Codex" && "$args" != *"--user-data-dir="* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(ps axww -o pid= -o args=)
}

wait_for_codex_window_exit() {
  local app_data="$1"
  local max_waits="${CODEX_LAUNCH_EXIT_MAX_WAITS:-20}"
  local wait_seconds="${CODEX_LAUNCH_EXIT_WAIT_SECONDS:-0.1}"
  local waited=0

  while [[ -n "$(matching_codex_window_pids_for_app_data "$app_data")" ]]; do
    (( waited >= max_waits )) && return 1
    sleep "$wait_seconds"
    waited=$(( waited + 1 ))
  done
  return 0
}

wait_for_codex_window_start() {
  local app_data="$1"
  local max_waits="${CODEX_LAUNCH_VERIFY_MAX_WAITS:-40}"
  local wait_seconds="${CODEX_LAUNCH_VERIFY_WAIT_SECONDS:-0.2}"
  local waited=0

  while (( waited < max_waits )); do
    [[ -n "$(matching_codex_window_pids_for_app_data "$app_data")" ]] && return 0
    sleep "$wait_seconds"
    waited=$(( waited + 1 ))
  done
  return 1
}

process_args_match_app_data_snapshot() {
  local args="$1"
  local app_data="$2"
  args_has_user_data_dir "$args" "$app_data"
}

close_all_accounts_fast() {
  local process_snapshot
  process_snapshot="$(mktemp)"
  ps axww -o pid= -o ppid= -o args= > "$process_snapshot"

  local -A parent_by_pid args_by_pid active_ancestor close_window_seen close_server_seen
  local line pid ppid args
  while read -r pid ppid args; do
    [[ -n "${pid:-}" && -n "${ppid:-}" && -n "${args:-}" ]] || continue
    parent_by_pid[$pid]="$ppid"
    args_by_pid[$pid]="$args"
  done < "$process_snapshot"

  for pid in "${(@k)args_by_pid}"; do
    args="${args_by_pid[$pid]}"
    if [[ "$args" == *"codex app-server --listen stdio://"* \
          || "$args" == *"app-server proxy"* \
          || "$args" == *"node_repl"* \
          || "$args" == *"SkyComputerUseClient"* ]]; then
      local current="$pid"
      local hops=0
      while [[ -n "$current" && "$current" != "0" && "$current" != "1" && $hops -lt 80 ]]; do
        active_ancestor[$current]=1
        current="${parent_by_pid[$current]:-}"
        hops=$((hops + 1))
      done
    fi
  done

  local -a close_window_pids kept_window_pids close_server_pids kept_server_pids managed_homes
  local previous_skip_active="${CODEX_SKIP_ACTIVE_AGENT_WINDOWS:-0}"
  CODEX_SKIP_ACTIVE_AGENT_WINDOWS=1

  while IFS='|' read -r raw_name _; do
    local name
    name="$(echo "$raw_name" | xargs)"
    [[ -n "$name" ]] || continue
    if [[ "$name" == "account1" || "$name" == "primary" || "$name" == "default" ]]; then
      echo "Keeping primary Codex window open: $name"
      continue
    fi

    local home_dir app_data
    home_dir="$(account_home_for "$name")"
    app_data="$(account_app_data_for "$name")"
    managed_homes+=("$home_dir")

    for pid in "${(@k)args_by_pid}"; do
      args="${args_by_pid[$pid]}"
      is_codex_gui_process_args "$args" || continue
      process_args_match_app_data_snapshot "$args" "$app_data" || continue
      if [[ -n "${active_ancestor[$pid]:-}" ]]; then
        kept_window_pids+=("$pid")
      elif [[ -z "${close_window_seen[$pid]:-}" ]]; then
        close_window_seen[$pid]=1
        close_window_pids+=("$pid")
      fi
    done
  done < <(list_accounts)

  local candidate_env
  for pid in "${(@k)args_by_pid}"; do
    args="${args_by_pid[$pid]}"
    [[ "$args" == *"codex app-server"* ]] || continue
    [[ "$args" == *"--listen stdio://"* ]] && continue
    [[ "$args" == *"app-server proxy"* ]] && continue
    candidate_env="$(ps eww -p "$pid" 2>/dev/null || true)"
    for home_dir in "${managed_homes[@]}"; do
      if [[ "$args" == *"--codex-home $home_dir"* \
            || "$args" == *"--codex-home=$home_dir"* \
            || "$candidate_env" == *"CODEX_HOME=$home_dir"* ]]; then
        if [[ -n "${active_ancestor[$pid]:-}" ]]; then
          kept_server_pids+=("$pid")
        elif [[ -z "${close_server_seen[$pid]:-}" ]]; then
          close_server_seen[$pid]=1
          close_server_pids+=("$pid")
        fi
        break
      fi
    done
  done

  if (( ${#kept_window_pids[@]} > 0 )); then
    echo "Keeping active Codex window(s): ${kept_window_pids[*]}"
  fi
  if (( ${#kept_server_pids[@]} > 0 )); then
    echo "Keeping active Codex app-server(s): ${kept_server_pids[*]}"
  fi

  stop_pids "Closing existing Codex window(s) for managed profiles" "${close_window_pids[@]}"
  stop_pids "Closing stale Codex app-server(s) for managed profiles" "${close_server_pids[@]}"

  CODEX_SKIP_ACTIVE_AGENT_WINDOWS="$previous_skip_active"
  rm -f "$process_snapshot"
}

launch_account() {
  local name="${1:-}" display_name="${2:-}"
  if [[ -z "$name" ]]; then
    echo "launch-account requires an account name." >&2
    exit 2
  fi

  ensure_dirs

  if ! selected_codex_app_is_usable; then
    report_missing_codex_app
    exit 1
  fi

  local home_dir app_data history_mode opencodex_cli_wrapper="" preserve_user_model_route=0
  local -a launch_env launch_args
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"

  if home_uses_opencodex_proxy "$home_dir" && [[ "${OPENCODEX_LAB_LAUNCH_VERIFIED:-0}" != "1" ]]; then
    opencodex_launch
    return $?
  fi
  if home_uses_opencodex_proxy "$home_dir"; then
    validate_opencodex_lab_paths || return 1
    set_history_mode_for_home "$home_dir" private || return 1
    CODEX_SHARED_SESSIONS=0
    CODEX_SYNC_THREAD_HISTORY=0
  fi
  mkdir -p "$home_dir" "$app_data"

  # The persisted per-profile mode is authoritative. In particular, a private
  # profile must stay local even when an older UI or menu process supplies the
  # historical global CODEX_SHARED_SESSIONS=1 environment.
  history_mode="$(history_mode_for_home "$home_dir")"
  if [[ "$history_mode" == "private" ]]; then
    CODEX_SHARED_SESSIONS=0
    CODEX_SYNC_THREAD_HISTORY=0
  else
    CODEX_SHARED_SESSIONS=1
    CODEX_SYNC_THREAD_HISTORY=1
  fi

  if [[ "$CODEX_CLONE_PRIMARY_ON_LAUNCH" == "1" && "$home_dir" != "$PRIMARY_CODEX_HOME" && ! -e "$home_dir/config.toml" ]]; then
    copy_initial_profile_to "$home_dir"
  fi
  if [[ "$CODEX_PRELAUNCH_SYNC" == "1" ]]; then
    if ! sync_account_for_launch "$name" >/dev/null; then
      echo "Prelaunch sync did not finish; not launching Codex profile to avoid SQLite startup conflicts." >&2
      exit 1
    fi
  fi
  prepare_profile_login_storage_for_launch "$home_dir"
  if is_primary_codex_home "$home_dir"; then
    configure_account1_aliyun_proxy_for_home "$home_dir"
    ensure_aliyun_coding_plan_bridge_running
  elif home_uses_opencodex_proxy "$home_dir"; then
    # OpenCodex owns this dedicated lab config while its proxy is running.
    # Never rewrite it to the normal OpenAI defaults during an account launch.
    opencodex_cli_wrapper="$(prepare_opencodex_cli_wrapper)" || {
      echo "OpenCodex CLI routing could not be prepared safely; profile was not launched." >&2
      return 1
    }
  else
    if profile_has_user_owned_model_routing "$home_dir"; then
      preserve_user_model_route=1
    elif profile_uses_opencodex_routing "$home_dir"; then
      if ! ensure_opencodex_available_for_profiles; then
        remove_opencodex_routing_for_home "$home_dir" >/dev/null 2>&1 || true
        echo "OpenCodex could not be prepared; refusing to launch with a dead loopback route." >&2
        return 1
      fi
      if ! configure_opencodex_routing_for_home "$home_dir"; then
        remove_opencodex_routing_for_home "$home_dir" >/dev/null 2>&1 || true
        echo "OpenCodex routing could not be configured safely; profile was not launched." >&2
        return 1
      fi
      if profile_has_user_owned_model_routing "$home_dir" \
        || [[ ! -f "$home_dir/$OPENCODEX_PROFILE_ROUTE_MARKER" ]]; then
        # The config may have changed between the first read and the atomic
        # route update. Preserve it instead of forcing defaults or a CLI shim.
        preserve_user_model_route=1
      else
        restore_non_account1_openai_config_for_home "$home_dir"
        opencodex_cli_wrapper="$(prepare_opencodex_cli_wrapper)" || {
          remove_opencodex_routing_for_home "$home_dir" >/dev/null 2>&1 || true
          echo "OpenCodex CLI routing could not be prepared safely; profile was not launched." >&2
          return 1
        }
      fi
    fi
  fi
  if ! home_uses_opencodex_proxy "$home_dir" && (( preserve_user_model_route == 0 )); then
    normalize_top_level_model_provider_for_home "$home_dir"
  fi
  if [[ "$CODEX_HEAVY_STATE_REPAIR_ON_LAUNCH" == "1" ]] && ! home_uses_opencodex_proxy "$home_dir"; then
    refresh_shared_history_for_home "$home_dir"
    repair_compacted_image_payloads_for_home "$home_dir" >/dev/null 2>&1 || true
    if [[ "$CODEX_DELETE_STALE_THREAD_ROWS" == "1" ]]; then
      cleanup_thread_index_for_home "$home_dir" >/dev/null 2>&1 || true
    fi
    normalize_thread_sources_for_home "$home_dir"
    if (( preserve_user_model_route == 0 )); then
      restore_default_thread_model_providers_for_home "$home_dir"
    fi
    restore_account1_visible_thread_model_providers_for_home "$home_dir"
  fi

  echo "Launching Codex profile..."
  echo "  account=$(sanitize_account_name "$name")"
  echo "  app=$CODEX_APP"
  echo "  CODEX_HOME=$home_dir"
  echo "  user-data-dir=$app_data"
  if proxy_injection_enabled; then
    echo "  proxy=$CODEX_PROXY_URL"
  fi

  stop_codex_windows_for_app_data "$app_data"
  stop_codex_servers_for_home "$home_dir"
  if ! wait_for_codex_window_exit "$app_data"; then
    echo "Existing Codex window for this profile did not exit in time." >&2
    return 1
  fi
  ensure_owl_auth_features_enabled "$app_data"

  # Keep the account env scoped to this launch. `launchctl setenv` is global
  # and can make later Codex windows inherit the wrong CODEX_HOME.
  launchctl unsetenv CODEX_HOME >/dev/null 2>&1 || true
  launch_env=(--env "CODEX_HOME=$home_dir")
  if [[ -n "$opencodex_cli_wrapper" ]]; then
    launch_env+=(
      --env "CODEX_CLI_PATH=$opencodex_cli_wrapper"
      --env "CODEX_APP_SERVER_FORCE_CLI=1"
    )
  fi
  if is_primary_codex_home "$home_dir"; then
    load_aliyun_coding_plan_key
    if [[ -n "${AI_API_KEY:-}" ]]; then
      launch_env+=(--env "AI_API_KEY=$AI_API_KEY")
    fi
    if [[ -n "${DASHSCOPE_API_KEY:-}" ]]; then
      launch_env+=(--env "DASHSCOPE_API_KEY=$DASHSCOPE_API_KEY")
    fi
  fi
  if proxy_injection_enabled; then
    launch_env+=(
      --env "HTTP_PROXY=$CODEX_PROXY_URL"
      --env "HTTPS_PROXY=$CODEX_PROXY_URL"
      --env "ALL_PROXY=$CODEX_PROXY_URL"
      --env "NO_PROXY=$CODEX_NO_PROXY"
      --env "http_proxy=$CODEX_PROXY_URL"
      --env "https_proxy=$CODEX_PROXY_URL"
      --env "all_proxy=$CODEX_PROXY_URL"
      --env "no_proxy=$CODEX_NO_PROXY"
    )
  fi
  launch_args=(--user-data-dir="$app_data")
  if proxy_injection_enabled; then
    # Chromium/Electron does not reliably honor HTTP_PROXY on macOS. Pass the
    # same per-profile proxy explicitly so account, usage, and profile requests
    # do not bypass Clash and get challenged by Cloudflare.
    launch_args+=(--proxy-server="$CODEX_PROXY_URL")
  fi
  open -na "$CODEX_APP" \
    "${launch_env[@]}" \
    --args "${launch_args[@]}"

  if ! wait_for_codex_window_start "$app_data"; then
    echo "Codex did not start a matching profile process within 8 seconds." >&2
    return 1
  fi

  echo "Started Codex profile."
}

print_codex_app_path() {
  if ! selected_codex_app_is_usable; then
    report_missing_codex_app
    return 1
  fi
  printf '%s\n' "$CODEX_APP"
}

close_account() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "close-account requires an account name." >&2
    exit 2
  fi

  ensure_dirs

  local home_dir app_data
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"

  echo "Closing Codex profile..."
  echo "  account=$(sanitize_account_name "$name")"
  echo "  CODEX_HOME=$home_dir"
  echo "  user-data-dir=$app_data"

  stop_codex_windows_for_app_data "$app_data"
  stop_codex_servers_for_home "$home_dir"

  echo "Closed matching profile window(s)."
}

close_all_accounts() {
  ensure_dirs

  echo "Closing all Codex profile window(s)..."
  close_all_accounts_fast
  echo "Closed all matching Codex profile window(s)."
}

backup_path_for_account() {
  local account_home="$1"
  local item_name="$2"
  local backup_dir="$account_home/backups/history-link-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  echo "$backup_dir/$item_name"
}

replace_with_symlink() {
  local account_home="$1"
  local item="$2"
  local source
  source="$(shared_history_source_for_item "$item")"
  local target="$account_home/$item"

  seed_shared_history_item_from_home "$account_home" "$item"

  [[ -e "$source" || -L "$source" ]] || return 0

  if [[ -L "$target" ]]; then
    rm "$target"
  elif [[ -e "$target" ]]; then
    local backup_target
    backup_target="$(backup_path_for_account "$account_home" "$(basename "$item")")"
    mv "$target" "$backup_target"
    echo "Backed up $target -> $backup_target"
  fi

  mkdir -p "$(dirname "$target")"
  ln -s "$source" "$target"
  echo "Linked $target -> $source"
}

shared_history_source_for_item() {
  local item="$1"
  case "$item" in
    session_index.jsonl) printf '%s\n' "$SHARED_SESSION_INDEX_FILE" ;;
    sessions) printf '%s\n' "$SHARED_SESSIONS_DIR" ;;
    shell_snapshots) printf '%s\n' "$SHARED_SHELL_SNAPSHOTS_DIR" ;;
    *) printf '%s\n' "$CODEX_HISTORY_ANCHOR_HOME/$item" ;;
  esac
}

same_resolved_path() {
  local left="$1" right="$2"
  local resolved_left resolved_right
  resolved_left="$(realpath "$left" 2>/dev/null || printf '%s' "$left")"
  resolved_right="$(realpath "$right" 2>/dev/null || printf '%s' "$right")"
  [[ "$resolved_left" == "$resolved_right" ]]
}

seed_shared_history_item_from_home() {
  local account_home="$1"
  local item="$2"
  local src="$account_home/$item"
  local dst
  dst="$(shared_history_source_for_item "$item")"

  [[ -e "$src" || -L "$src" ]] || {
    if [[ "$item" == "session_index.jsonl" ]]; then
      mkdir -p "$(dirname "$dst")"
      [[ -e "$dst" ]] || : > "$dst"
    else
      mkdir -p "$dst"
    fi
    return 0
  }
  same_resolved_path "$src" "$dst" && return 0

  if [[ "$item" == "session_index.jsonl" ]]; then
    mkdir -p "$(dirname "$dst")"
    rsync_quick -a --update "$src" "$dst" || sync_debug "Skipped slow shared history seed: $src"
  elif [[ -d "$src" || ( -L "$src" && -d "$src" ) ]]; then
    mkdir -p "$dst"
    CODEX_RSYNC_MAX_WAITS="${CODEX_HISTORY_RSYNC_MAX_WAITS:-600}" rsync_quick -a --update "$src/" "$dst/" || sync_debug "Skipped slow shared history seed: $src"
  fi
}

recover_shared_history_backups_from_home() {
  local account_home="$1"
  local backup_root="$account_home/backups"

  [[ "${CODEX_RECOVER_HISTORY_BACKUPS:-1}" == "1" ]] || return 0
  [[ -d "$backup_root" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  CODEX_RECOVER_HOME="$account_home" \
  CODEX_SHARED_SESSIONS_DIR="$SHARED_SESSIONS_DIR" \
  CODEX_SHARED_SHELL_SNAPSHOTS_DIR="$SHARED_SHELL_SNAPSHOTS_DIR" \
  python3 - <<'PY'
import os
import shutil
from pathlib import Path

home = Path(os.environ["CODEX_RECOVER_HOME"])
backup_root = home / "backups"
targets = {
    "sessions": Path(os.environ["CODEX_SHARED_SESSIONS_DIR"]),
    "shell_snapshots": Path(os.environ["CODEX_SHARED_SHELL_SNAPSHOTS_DIR"]),
}

def copy_missing_tree(source_root, target_root):
    if not source_root.is_dir():
        return
    for source in source_root.rglob("*"):
        if not source.is_file():
            continue
        try:
            rel = source.relative_to(source_root)
        except ValueError:
            continue
        target = target_root / rel
        if target.exists():
            continue
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_name(f".{target.name}.tmp-{os.getpid()}")
            shutil.copy2(source, tmp)
            os.replace(tmp, target)
        except OSError:
            try:
                tmp.unlink()
            except Exception:
                pass

for backup_dir in sorted(backup_root.glob("history-link-*")):
    if not backup_dir.is_dir():
        continue
    for item, target_root in targets.items():
        copy_missing_tree(backup_dir / item, target_root)
PY
}

seed_shared_history_from_home() {
  local account_home="$1"
  mkdir -p "$SHARED_HISTORY_ROOT" "$SHARED_SESSIONS_DIR" "$SHARED_SHELL_SNAPSHOTS_DIR"
  : > "${SHARED_SESSION_INDEX_FILE}.touch"
  rm -f "${SHARED_SESSION_INDEX_FILE}.touch"
  recover_shared_history_backups_from_home "$account_home"
  portable_history_items | while read -r item; do
    seed_shared_history_item_from_home "$account_home" "$item"
  done
  [[ -e "$SHARED_SESSION_INDEX_FILE" ]] || : > "$SHARED_SESSION_INDEX_FILE"
}

history_items() {
  printf '%s\n' \
    "logs_2.sqlite" \
    "logs_2.sqlite-shm" \
    "logs_2.sqlite-wal" \
    "session_index.jsonl" \
    "sessions" \
    "shell_snapshots"
}

portable_history_items() {
  printf '%s\n' \
    "session_index.jsonl" \
    "sessions" \
    "shell_snapshots"
}

state_items() {
  printf '%s\n' \
    "state_5.sqlite" \
    "state_5.sqlite-shm" \
    "state_5.sqlite-wal"
}

remove_legacy_shared_state_links() {
  local account_home="$1"
  local item target source

  [[ "$account_home" != "$PRIMARY_CODEX_HOME" ]] || return 0

  state_items | while read -r item; do
    target="$account_home/$item"
    source="$PRIMARY_CODEX_HOME/$item"
    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
      rm "$target"
      echo "Removed legacy shared state link: $target"
    fi
  done
}

remove_legacy_log_links() {
  local account_home="$1"
  local item target source

  [[ "$account_home" != "$PRIMARY_CODEX_HOME" ]] || return 0

  printf '%s\n' "logs_2.sqlite" "logs_2.sqlite-shm" "logs_2.sqlite-wal" | while read -r item; do
    target="$account_home/$item"
    source="$PRIMARY_CODEX_HOME/$item"
    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
      rm "$target"
      echo "Removed legacy shared log link: $target"
    fi
  done
}

materialize_legacy_history_links() {
  local account_home="$1"
  local item target source shared_source

  [[ "$account_home" != "$PRIMARY_CODEX_HOME" ]] || return 0

  portable_history_items | while read -r item; do
    target="$account_home/$item"
    [[ -L "$target" ]] || continue
    source="$(readlink "$target")"
    if [[ "$CODEX_SHARED_SESSIONS" == "1" ]]; then
      shared_source="$(shared_history_source_for_item "$item")"
      if [[ "$source" == "$shared_source" ]] || same_resolved_path "$source" "$shared_source"; then
        continue
      fi
    fi
    [[ -e "$source" || -L "$source" ]] || continue

    rm "$target"
    if [[ -d "$source" ]]; then
      mkdir -p "$target"
      if [[ "$item" == "sessions" ]]; then
        CODEX_RSYNC_MAX_WAITS="${CODEX_HISTORY_RSYNC_MAX_WAITS:-600}" rsync_quick -a --update "$source/" "$target/" || sync_debug "Skipped slow history materialize: $source"
      else
        rsync_quick -a --update "$source/" "$target/" || sync_debug "Skipped slow history materialize: $source"
      fi
    else
      mkdir -p "$(dirname "$target")"
      rsync_quick -a --update "$source" "$target" || sync_debug "Skipped slow history materialize: $source"
    fi
    echo "Materialized legacy shared history link: $target"
  done
}

ensure_shared_history_links() {
  local account_home="$1"
  local item
  mkdir -p "$account_home" "$SHARED_HISTORY_ROOT" "$SHARED_SESSIONS_DIR" "$SHARED_SHELL_SNAPSHOTS_DIR"
  [[ -e "$SHARED_SESSION_INDEX_FILE" ]] || : > "$SHARED_SESSION_INDEX_FILE"
  seed_shared_history_from_home "$CODEX_HISTORY_ANCHOR_HOME"
  seed_shared_history_from_home "$account_home"
  portable_history_items | while read -r item; do
    replace_with_symlink "$account_home" "$item"
  done
}

# Constant-size readiness probe for the three portable shared-history links.
# A normal launch can skip backup recovery and rsync seeding when these links
# already point at the shared store.
shared_history_links_ready() {
  local account_home="$1"
  local item target source

  [[ "$CODEX_SHARED_SESSIONS" == "1" ]] || return 1
  for item in session_index.jsonl sessions shell_snapshots; do
    target="$account_home/$item"
    source="$(shared_history_source_for_item "$item")"
    [[ -L "$target" ]] || return 1
    same_resolved_path "$target" "$source" || return 1
  done
  return 0
}

prepare_profile_login_storage_for_launch() {
  local account_home="$1"
  shared_history_links_ready "$account_home" && return 0
  prepare_profile_login_storage "$account_home"
}

ensure_shared_sessions_link() {
  local account_home="$1"
  local target="$account_home/sessions"
  local source resolved_source resolved_shared

  [[ "$CODEX_SHARED_SESSIONS" == "1" ]] || return 0
  mkdir -p "$SHARED_SESSIONS_DIR" "$account_home"
  if [[ -L "$target" && "$(readlink "$target")" == "$SHARED_SESSIONS_DIR" ]]; then
    return 0
  fi
  if [[ -L "$target" ]]; then
    source="$(readlink "$target")"
    resolved_source="$(realpath "$source" 2>/dev/null || printf '%s' "$source")"
    resolved_shared="$(realpath "$SHARED_SESSIONS_DIR" 2>/dev/null || printf '%s' "$SHARED_SESSIONS_DIR")"
    if [[ "$resolved_source" == "$resolved_shared" ]]; then
      rm "$target"
      ln -s "$SHARED_SESSIONS_DIR" "$target"
      return 0
    fi
  fi
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    ln -s "$SHARED_SESSIONS_DIR" "$target"
    echo "Linked shared sessions: $target -> $SHARED_SESSIONS_DIR"
  fi
}

detach_shared_sessions_link() {
  local account_home="$1"
  local target="$account_home/sessions"
  local source resolved_source resolved_shared

  [[ "$account_home" != "$PRIMARY_CODEX_HOME" ]] || return 0
  [[ "$account_home" != "$CODEX_HISTORY_ANCHOR_HOME" ]] || return 0
  mkdir -p "$account_home"

  if [[ -L "$target" ]]; then
    source="$(readlink "$target")"
    resolved_source="$(realpath "$source" 2>/dev/null || printf '%s' "$source")"
    resolved_shared="$(realpath "$SHARED_SESSIONS_DIR" 2>/dev/null || printf '%s' "$SHARED_SESSIONS_DIR")"
    if [[ "$source" == "$SHARED_SESSIONS_DIR" || "$resolved_source" == "$resolved_shared" ]]; then
      rm "$target"
      mkdir -p "$target"
      echo "Detached shared sessions: $target"
      return 0
    fi
  fi

  [[ -e "$target" || -L "$target" ]] || mkdir -p "$target"
}

detach_shared_history_links() {
  local account_home="$1"
  local item target source shared_source

  [[ "$account_home" != "$PRIMARY_CODEX_HOME" ]] || return 0
  [[ "$account_home" != "$CODEX_HISTORY_ANCHOR_HOME" ]] || return 0
  mkdir -p "$account_home"

  portable_history_items | while read -r item; do
    target="$account_home/$item"
    [[ -L "$target" ]] || continue
    source="$(readlink "$target")"
    shared_source="$(shared_history_source_for_item "$item")"
    if [[ "$source" == "$shared_source" ]] || same_resolved_path "$source" "$shared_source"; then
      rm "$target"
      if [[ "$item" == "session_index.jsonl" ]]; then
        : > "$target"
      else
        mkdir -p "$target"
      fi
      echo "Detached shared history: $target"
    fi
  done
}

prepare_profile_login_storage() {
  local account_home="$1"
  mkdir -p "$account_home"
  remove_legacy_shared_state_links "$account_home"
  remove_legacy_log_links "$account_home"
  if [[ "$CODEX_SHARED_SESSIONS" == "1" ]]; then
    materialize_legacy_history_links "$account_home"
    ensure_shared_history_links "$account_home"
  else
    detach_shared_sessions_link "$account_home"
    detach_shared_history_links "$account_home"
  fi
}

link_history_for_unlocked() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "link-history requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  CODEX_SHARED_SESSIONS=1
  local account_home current_mode
  account_home="$(account_home_for "$name")"

  if home_uses_opencodex_proxy "$account_home"; then
    echo "OpenCodex Lab cannot use shared local history." >&2
    return 2
  fi

  if profile_transition_is_busy "$name" "$account_home"; then
    echo "Close this Codex profile and wait for its app-server/database writes before sharing local history." >&2
    return 1
  fi
  current_mode="$(history_mode_for_home "$account_home")"
  if [[ "${CODEX_LINK_HISTORY_SKIP_PRIVATE:-0}" == "1" && "$current_mode" == "private" ]]; then
    echo "Skipping private history profile: $(sanitize_account_name "$name")"
    return 0
  fi
  if [[ "$current_mode" == "shared" ]] && portable_history_links_point_to_shared "$account_home"; then
    echo "$(sanitize_account_name "$name") history is already shared."
    return 0
  fi

  mkdir -p "$account_home"
  seed_shared_history_from_home "$CODEX_HISTORY_ANCHOR_HOME"
  seed_shared_history_from_home "$account_home"
  prepare_profile_login_storage "$account_home"
  echo "Linking $(sanitize_account_name "$name") to shared pro Codex history."
  echo "Keep auth separate:"
  echo "  Pro history anchor: $CODEX_HISTORY_ANCHOR_HOME"
  echo "  Shared index: $SHARED_SESSION_INDEX_FILE"
  echo "  Shared sessions: $SHARED_SESSIONS_DIR"
  echo "  $(sanitize_account_name "$name"): $account_home/auth.json"
  echo

  portable_history_items | while read -r item; do
    replace_with_symlink "$account_home" "$item"
  done

  sync_thread_index_for_homes "$CODEX_HISTORY_ANCHOR_HOME" "$account_home"
  sync_global_state_for_homes "$CODEX_HISTORY_ANCHOR_HOME" "$account_home"
  sync_goal_state_for_homes "$CODEX_HISTORY_ANCHOR_HOME" "$account_home"
  set_history_mode_for_home "$account_home" shared
}

link_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "link-history requires an account name." >&2
    exit 2
  fi
  ensure_dirs
  CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
    CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock link_history_for_unlocked "$name"
}

unlink_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "unlink-history requires an account name." >&2
    exit 2
  fi

  separate_history_for "$name"
}

cleanup_thread_index_for_home() {
  local account_home="$1"
  local index_file="$account_home/session_index.jsonl"

  [[ -d "$account_home" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local backup_dir
  backup_dir="$account_home/backups/thread-index-cleanup-$(date '+%Y%m%d-%H%M%S')"

  CODEX_CLEANUP_ACCOUNT_HOME="$account_home" CODEX_CLEANUP_BACKUP_DIR="$backup_dir" python3 - <<'PY'
import json
import os
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

home = Path(os.environ["CODEX_CLEANUP_ACCOUNT_HOME"]).expanduser()
backup_dir = Path(os.environ["CODEX_CLEANUP_BACKUP_DIR"]).expanduser()
private_history_cleanup = os.environ.get("CODEX_CLEANUP_PRIVATE_HISTORY", "0") == "1"
shared_sessions_root = Path(os.environ.get("CODEX_SHARED_SESSIONS_DIR", "")).expanduser()
state_paths = [home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite"]
state_paths = [path for path in state_paths if path.exists()]
index_path = home / "session_index.jsonl"
global_state_path = home / ".codex-global-state.json"

def table_columns(con, table):
    try:
        return [row[1] for row in con.execute(f"PRAGMA table_info({table})").fetchall()]
    except sqlite3.Error:
        return []

def marker(row):
    for key in ("updated_at_ms", "updated_at"):
        value = row.get(key)
        if value is None:
            continue
        try:
            return int(value) if key == "updated_at_ms" else int(value) * 1000
        except (TypeError, ValueError):
            pass
    return 0

def text(row, key):
    return str(row.get(key) or "").strip()

def compact_text(value):
    return " ".join(str(value or "").split())

def first_nonempty_line(value):
    for line in str(value or "").splitlines():
        candidate = " ".join(line.split())
        if candidate:
            return candidate
    return ""

def looks_like_filesystem_path(value, row=None):
    first_line = first_nonempty_line(value)
    if not first_line:
        return False
    cwd = text(row, "cwd") if row is not None else ""
    if cwd and (first_line == cwd or first_line.startswith(cwd + " ") or first_line.startswith(cwd + "\t")):
        return True
    return first_line.startswith(("/Users/", "/Volumes/", "/private/", "/tmp/", "/var/", "~/"))

def title_text_score(value, row=None, field="title"):
    raw = str(value or "")
    first_line = first_nonempty_line(raw)
    if not first_line or first_line == "Untitled":
        return 0
    if looks_like_filesystem_path(first_line, row):
        return 1

    same_as_preview = False
    if field == "title" and row is not None:
        preview = compact_text(row.get("preview"))
        same_as_preview = bool(preview and compact_text(raw) == preview)

    if "\n" in raw:
        return 30 if same_as_preview else 40
    if same_as_preview and len(first_line) > 48:
        return 35
    if row is None and len(first_line) > 48 and any(mark in first_line for mark in ("?", "？", "!", "！", "。", "，", ",")):
        return 55
    if len(first_line) > 120:
        return 45
    if len(first_line) > 80:
        return 60
    if same_as_preview:
        return 75
    return 100

def rollout_exists(row):
    rollout_path = text(row, "rollout_path")
    if not rollout_path:
        return False
    if private_history_cleanup and rollout_is_shared_source(rollout_path):
        return False
    try:
        return Path(rollout_path).exists()
    except OSError:
        return False

def rollout_is_shared_source(value):
    raw = str(value or "").strip()
    if not raw or not str(shared_sessions_root):
        return False
    path = Path(raw).expanduser()
    try:
        path.relative_to(shared_sessions_root)
        return True
    except ValueError:
        pass
    try:
        path.resolve().relative_to(shared_sessions_root.resolve())
        return True
    except (OSError, ValueError):
        return False

def is_live(row):
    try:
        archived = int(row.get("archived") or 0)
    except (TypeError, ValueError):
        archived = 1
    return archived == 0 and bool(text(row, "preview") or text(row, "title")) and rollout_exists(row)

def best_text_row(rows, field):
    best = None
    best_score = -1
    best_marker = -1
    for row in rows:
        score = title_text_score(text(row, field), row, field)
        row_time = marker(row)
        if score > best_score or (score == best_score and row_time > best_marker):
            best = row
            best_score = score
            best_marker = row_time
    return best

def merged_live_row(rows):
    base = dict(max(rows, key=marker))
    for field in ("title", "preview"):
        row = best_text_row(rows, field)
        if row is not None:
            base[field] = row.get(field)
    return base

def backup_file(path, relative_name):
    if not path.exists():
        return
    target = backup_dir / relative_name
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copy2(path, target)
    except OSError:
        pass

def backup_sqlite(path):
    target = backup_dir / "sqlite-backups" / path.relative_to(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        source = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=3)
        dest = sqlite3.connect(target, timeout=3)
        source.backup(dest)
        dest.close()
        source.close()
    except sqlite3.Error:
        try:
            shutil.copy2(path, target)
        except OSError:
            pass

def safe_rollout_target(path, thread_id):
    raw = str(path)
    for marker_name in ("/sessions/", "/archived_sessions/"):
        marker_index = raw.find(marker_name)
        if marker_index != -1:
            rel = raw[marker_index + 1:].lstrip("/")
            return backup_dir / "rollouts" / rel
    return backup_dir / "rollouts" / f"{thread_id}-{path.name}"

def move_rollout(path, thread_id):
    if not path.exists():
        return False
    target = safe_rollout_target(path, thread_id)
    if target.exists():
        target = target.with_name(f"{target.stem}-{thread_id}{target.suffix}")
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(path), str(target))
        return True
    except OSError:
        try:
            shutil.copy2(path, target)
            path.unlink()
            return True
        except OSError:
            return False

rows_by_id = {}
for db_path in state_paths:
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
        con.execute("PRAGMA busy_timeout=3000")
        cols = table_columns(con, "threads")
        if not cols or "id" not in cols:
            con.close()
            continue
        query_cols = ", ".join(f'"{col}"' for col in cols)
        for values in con.execute(f'SELECT {query_cols} FROM threads'):
            row = dict(zip(cols, values))
            thread_id = text(row, "id")
            if not thread_id:
                continue
            row["__db_path"] = str(db_path)
            rows_by_id.setdefault(thread_id, []).append(row)
        con.close()
    except sqlite3.Error:
        pass

live_rows = {}
delete_ids = set()
rollouts_to_move = []
for thread_id, rows in rows_by_id.items():
    live = [row for row in rows if is_live(row)]
    if live:
        live_rows[thread_id] = merged_live_row(live)
        continue
    delete_ids.add(thread_id)
    for row in rows:
        rollout_path = text(row, "rollout_path")
        if rollout_path and not (private_history_cleanup and rollout_is_shared_source(rollout_path)):
            rollouts_to_move.append((thread_id, Path(rollout_path)))

changed = bool(delete_ids)
if changed:
    backup_dir.mkdir(parents=True, exist_ok=True)
    for path in state_paths:
        backup_sqlite(path)
    backup_file(index_path, "session_index.jsonl")
    backup_file(global_state_path, ".codex-global-state.json")

moved_count = 0
if delete_ids:
    seen_rollouts = set()
    for thread_id, rollout_path in rollouts_to_move:
        key = str(rollout_path)
        if key in seen_rollouts:
            continue
        seen_rollouts.add(key)
        if move_rollout(rollout_path, thread_id):
            moved_count += 1

for db_path in state_paths:
    if not delete_ids:
        continue
    con = None
    try:
        con = sqlite3.connect(db_path, timeout=6)
        con.execute("PRAGMA busy_timeout=6000")
        placeholders = ",".join("?" for _ in delete_ids)
        ids = tuple(delete_ids)

        for table in ("thread_dynamic_tools", "thread_spawn_edges", "agent_job_items", "agent_jobs"):
            cols = table_columns(con, table)
            if not cols:
                continue
            for col in ("thread_id", "parent_thread_id", "child_thread_id", "assigned_thread_id"):
                if col in cols:
                    try:
                        con.execute(f'DELETE FROM "{table}" WHERE "{col}" IN ({placeholders})', ids)
                    except sqlite3.Error:
                        pass

        if table_columns(con, "threads"):
            con.execute(f"DELETE FROM threads WHERE id IN ({placeholders})", ids)
        con.commit()
        try:
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error:
            pass
        con.close()
    except sqlite3.Error:
        try:
            if con is not None:
                con.rollback()
                con.close()
        except Exception:
            pass

def thread_index_name(row):
    best_name = None
    best_score = -1
    for key in ("title", "preview"):
        value = text(row, key)
        if not value:
            continue
        for line in value.splitlines():
            name = " ".join(line.split())
            if not name:
                continue
            score = title_text_score(name, row, key)
            if score > best_score:
                best_name = name
                best_score = score
                if score >= 100:
                    break
        if best_score >= 100:
            break
    if best_name:
        return best_name[:77].rstrip() + "..." if len(best_name) > 80 else best_name
    return "Untitled"

def thread_updated_at_iso(row):
    timestamp_ms = marker(row)
    return datetime.fromtimestamp(timestamp_ms / 1000, timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")

if index_path.exists() or live_rows:
    index_records = []
    for thread_id, row in live_rows.items():
        index_records.append({
            "id": thread_id,
            "thread_name": thread_index_name(row),
            "updated_at": thread_updated_at_iso(row),
        })
    index_records.sort(key=lambda item: item["updated_at"], reverse=True)
    if changed or index_records:
        if not backup_dir.exists():
            backup_dir.mkdir(parents=True, exist_ok=True)
            backup_file(index_path, "session_index.jsonl")
        tmp = index_path.with_name(f".{index_path.name}.tmp-{os.getpid()}")
        with tmp.open("w", encoding="utf-8") as handle:
            for record in index_records:
                handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
                handle.write("\n")
        os.replace(tmp, index_path)

def load_global_state():
    if not global_state_path.exists():
        return {}
    try:
        data = json.loads(global_state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}

def ids_from_list(value):
    return set(str(item) for item in value if item) if isinstance(value, list) else set()

def keys_from_dict(value):
    return set(str(key) for key in value.keys() if key) if isinstance(value, dict) else set()

def root_is_present(root):
    if not root or not root.startswith("/"):
        return bool(root)
    try:
        return Path(root).exists()
    except OSError:
        return False

state = load_global_state()
if state:
    pinned_ids = ids_from_list(state.get("pinned-thread-ids"))
    projectless_ids = ids_from_list(state.get("projectless-thread-ids"))
    projectless_ids.update(keys_from_dict(state.get("thread-projectless-output-directories")))
    live_thread_ids = set(live_rows)
    project_thread_ids = live_thread_ids - pinned_ids - projectless_ids
    live_roots = {
        root
        for thread_id in project_thread_ids
        for root in (text(live_rows[thread_id], "cwd"),)
        if root and root_is_present(root)
    }

    next_state = dict(state)
    for key in ("electron-saved-workspace-roots", "project-order"):
        value = next_state.get(key)
        if isinstance(value, list):
            filtered = []
            seen = set()
            for root in value:
                root = str(root)
                if root in live_roots and root not in seen:
                    seen.add(root)
                    filtered.append(root)
            next_state[key] = filtered

    for key in (
        "thread-workspace-root-hints",
        "thread-project-assignments",
        "sidebar-thread-metadata",
        "thread-writable-roots",
        "thread-projectless-output-directories",
    ):
        value = next_state.get(key)
        if isinstance(value, dict):
            next_state[key] = {thread_id: item for thread_id, item in value.items() if str(thread_id) in live_thread_ids}

    value = next_state.get("electron-workspace-root-labels")
    if isinstance(value, dict):
        next_state["electron-workspace-root-labels"] = {root: item for root, item in value.items() if root in live_roots}

    value = next_state.get("sidebar-project-thread-orders")
    if isinstance(value, dict):
        filtered_orders = {}
        for root, thread_ids in value.items():
            if root not in live_roots:
                continue
            if isinstance(thread_ids, list):
                kept = [thread_id for thread_id in thread_ids if str(thread_id) in project_thread_ids]
                if kept:
                    filtered_orders[root] = kept
        next_state["sidebar-project-thread-orders"] = filtered_orders

    value = next_state.get("projectless-thread-ids")
    if isinstance(value, list):
        next_state["projectless-thread-ids"] = [thread_id for thread_id in value if str(thread_id) in live_thread_ids]

    value = next_state.get("pinned-thread-ids")
    if isinstance(value, list):
        next_state["pinned-thread-ids"] = [thread_id for thread_id in value if str(thread_id) in live_thread_ids]

    if next_state != state:
        if not backup_dir.exists():
            backup_dir.mkdir(parents=True, exist_ok=True)
            backup_file(global_state_path, ".codex-global-state.json")
        tmp = global_state_path.with_name(f".{global_state_path.name}.tmp-{os.getpid()}")
        with tmp.open("w", encoding="utf-8") as handle:
            json.dump(next_state, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(tmp, global_state_path)
        changed = True

if changed:
    print(f"Cleaned {len(delete_ids)} stale thread row(s): {home}")
    if moved_count:
        print(f"Moved {moved_count} stale rollout file(s).")
    print(f"Backup: {backup_dir}")
else:
    try:
        backup_dir.rmdir()
    except OSError:
        pass
PY
}

repair_compacted_image_payloads_for_home() {
  local account_home="$1"
  local sessions_root="" lsof_output="" lsof_status=0 lsof_has_pid=0 lsof_line=""

  [[ "$CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH" == "1" ]] || return 0
  [[ -d "$account_home" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -d "$account_home/sessions" ]] || return 0

  sessions_root="$(cd "$account_home/sessions" 2>/dev/null && pwd -P)" || {
    echo "session-payload-repair sessions_resolve_failed=$account_home/sessions" >&2
    return 1
  }
  if [[ ! -x /usr/sbin/lsof ]]; then
    echo "session-payload-repair lsof_unavailable=/usr/sbin/lsof" >&2
    return 1
  fi
  if lsof_output="$(/usr/sbin/lsof -t +D "$sessions_root" 2>&1)"; then
    lsof_status=0
  else
    lsof_status=$?
  fi
  for lsof_line in "${(@f)lsof_output}"; do
    if [[ "$lsof_line" =~ '^[0-9]+$' ]]; then
      lsof_has_pid=1
      break
    fi
  done
  if (( lsof_has_pid == 1 )); then
    echo "session-payload-repair busy sessions_open=$sessions_root; close Codex before repair." >&2
    return 75
  fi
  if (( lsof_status != 1 )) || [[ -n "$lsof_output" ]]; then
    echo "session-payload-repair lsof_failed=$sessions_root status=$lsof_status detail=$lsof_output" >&2
    return 1
  fi

  CODEX_REPAIR_ACCOUNT_HOME="$account_home" \
  CODEX_REPAIR_MIN_BYTES="$CODEX_COMPACTED_IMAGE_REPAIR_MIN_BYTES" \
  CODEX_REPAIR_IMAGE_MIN_CHARS="$CODEX_SESSION_PAYLOAD_IMAGE_MIN_CHARS" \
  CODEX_REPAIR_STRING_MAX_CHARS="$CODEX_SESSION_PAYLOAD_STRING_MAX_CHARS" \
  python3 - <<'PY'
import errno
import fcntl
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

home = Path(os.environ["CODEX_REPAIR_ACCOUNT_HOME"]).expanduser()
sessions_dir = home / "sessions"
try:
    min_bytes = int(os.environ.get("CODEX_REPAIR_MIN_BYTES", "67108864"))
except ValueError:
    min_bytes = 67108864
try:
    image_min_chars = int(os.environ.get("CODEX_REPAIR_IMAGE_MIN_CHARS", "65536"))
except ValueError:
    image_min_chars = 65536
try:
    string_max_chars = int(os.environ.get("CODEX_REPAIR_STRING_MAX_CHARS", "200000"))
except ValueError:
    string_max_chars = 200000
try:
    min_free_reserve = max(0, int(os.environ.get("CODEX_REPAIR_MIN_FREE_BYTES", str(2 * 1024 * 1024 * 1024))))
except ValueError:
    min_free_reserve = 2 * 1024 * 1024 * 1024
try:
    stale_tmp_min_age = max(0, int(os.environ.get("CODEX_REPAIR_STALE_TMP_MIN_AGE_SECONDS", "1800")))
except ValueError:
    stale_tmp_min_age = 1800

if not sessions_dir.is_dir():
    raise SystemExit(0)

try:
    sessions_dir = sessions_dir.resolve()
except OSError as exc:
    print(f"session-payload-repair sessions_resolve_failed={sessions_dir}: {exc}", file=sys.stderr)
    raise SystemExit(1)

# All profiles may point at one shared sessions directory.  A nonblocking lock
# prevents two repair runs from creating large temporary copies at once.
lock_path = sessions_dir.parent / ".session-payload-repair.lock"
try:
    lock_handle = lock_path.open("a+", encoding="utf-8")
except OSError as exc:
    print(f"session-payload-repair lock_failed={lock_path}: {exc}", file=sys.stderr)
    raise SystemExit(1)
try:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as exc:
    if isinstance(exc, BlockingIOError) or exc.errno in {errno.EACCES, errno.EAGAIN}:
        print(f"session-payload-repair busy lock={lock_path}: {exc}", file=sys.stderr)
        raise SystemExit(75)
    print(f"session-payload-repair lock_failed={lock_path}: {exc}", file=sys.stderr)
    raise SystemExit(1)

stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
backup_root = home / "recovery-backups"
backup_dir = backup_root / f"session-payload-repair-{stamp}"
files_changed = 0
images_omitted = 0
image_chars_omitted = 0
strings_omitted = 0
string_chars_omitted = 0
had_error = False
saw_low_space = False
active_tmp = None
active_backup_tmp = None
active_backup_target = None
active_source_path = None
active_source_identity = None

def is_open(path: Path) -> bool:
    global had_error
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-t", "--", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair lsof_exec_failed={path}: {exc}", file=sys.stderr)
        return True
    stderr_text = result.stderr.strip()
    if stderr_text:
        had_error = True
        print(
            f"session-payload-repair lsof_error={path} status={result.returncode} detail={stderr_text}",
            file=sys.stderr,
        )
        return True
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    had_error = True
    print(f"session-payload-repair lsof_error={path} status={result.returncode}", file=sys.stderr)
    return True

def prune_empty_backup_parents(path: Path):
    current = path.parent
    while current != backup_root:
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent

def remove_uncommitted_backup():
    global active_backup_target, active_source_identity, active_source_path, had_error
    backup_target = active_backup_target
    source_path = active_source_path
    initial_identity = active_source_identity
    active_backup_target = None
    active_source_path = None
    active_source_identity = None
    if backup_target is None or source_path is None or initial_identity is None:
        return
    try:
        backup_target.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair retained_backup_check_failed={backup_target}: {exc}", file=sys.stderr)
        return
    try:
        current_identity = source_identity(source_path.stat())
    except OSError as exc:
        had_error = True
        print(
            f"session-payload-repair retained_backup_stat_failed={backup_target} source={source_path}: {exc}",
            file=sys.stderr,
        )
        return
    if current_identity != initial_identity:
        print(
            f"session-payload-repair retained_committed_backup={backup_target} source_identity={current_identity}",
            file=sys.stderr,
        )
        return
    try:
        backup_target.unlink()
        print(f"session-payload-repair removed_uncommitted_backup={backup_target}", file=sys.stderr)
        prune_empty_backup_parents(backup_target)
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair backup_rollback_failed={backup_target}: {exc}", file=sys.stderr)

def remove_active_artifacts():
    global active_backup_tmp, active_tmp, had_error
    artifacts = (
        ("repair_tmp", active_tmp, False),
        ("backup_tmp", active_backup_tmp, True),
    )
    active_tmp = None
    active_backup_tmp = None
    for label, artifact, prune_backup_dirs in artifacts:
        if artifact is None:
            continue
        try:
            artifact.unlink()
            print(f"session-payload-repair removed_{label}={artifact}", file=sys.stderr)
        except FileNotFoundError:
            pass
        except OSError as exc:
            had_error = True
            print(f"session-payload-repair {label}_cleanup_failed={artifact}: {exc}", file=sys.stderr)
        if prune_backup_dirs:
            prune_empty_backup_parents(artifact)
    remove_uncommitted_backup()

def stop_and_cleanup(signum, _frame):
    remove_active_artifacts()
    print(f"session-payload-repair interrupted signal={signum}", file=sys.stderr)
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, stop_and_cleanup)
signal.signal(signal.SIGINT, stop_and_cleanup)

def cleanup_stale_tmp_files():
    global had_error
    removed_count = 0
    removed_bytes = 0
    now = time.time()
    for candidate in sessions_dir.rglob(".*.tmp-session-payload-repair-*"):
        if not candidate.is_file():
            continue
        try:
            stat = candidate.stat()
        except OSError:
            continue
        if now - stat.st_mtime < stale_tmp_min_age:
            continue
        if is_open(candidate):
            print(f"session-payload-repair stale_tmp_skip_open={candidate}", file=sys.stderr)
            continue
        try:
            candidate.unlink()
            removed_count += 1
            removed_bytes += stat.st_size
            print(f"session-payload-repair stale_tmp_removed={candidate} bytes={stat.st_size}", file=sys.stderr)
        except OSError as exc:
            had_error = True
            print(f"session-payload-repair stale_tmp_cleanup_failed={candidate}: {exc}", file=sys.stderr)
    if removed_count:
        print(
            f"session-payload-repair stale_tmp_summary files={removed_count} bytes={removed_bytes}",
            file=sys.stderr,
        )

def cleanup_stale_backup_tmp_files():
    global had_error
    if not backup_root.is_dir():
        return
    removed_count = 0
    removed_bytes = 0
    now = time.time()
    for candidate in backup_root.rglob(".*.tmp-session-backup-*"):
        if not candidate.is_file():
            continue
        try:
            stat = candidate.stat()
        except OSError:
            continue
        if now - stat.st_mtime < stale_tmp_min_age:
            continue
        if is_open(candidate):
            print(f"session-payload-repair stale_backup_tmp_skip_open={candidate}", file=sys.stderr)
            continue
        try:
            candidate.unlink()
            removed_count += 1
            removed_bytes += stat.st_size
            print(
                f"session-payload-repair stale_backup_tmp_removed={candidate} bytes={stat.st_size}",
                file=sys.stderr,
            )
            prune_empty_backup_parents(candidate)
        except OSError as exc:
            had_error = True
            print(f"session-payload-repair stale_backup_tmp_cleanup_failed={candidate}: {exc}", file=sys.stderr)
    if removed_count:
        print(
            f"session-payload-repair stale_backup_tmp_summary files={removed_count} bytes={removed_bytes}",
            file=sys.stderr,
        )

cleanup_stale_tmp_files()
cleanup_stale_backup_tmp_files()

def existing_parent(path: Path):
    candidate = path
    while True:
        try:
            return candidate, candidate.stat()
        except FileNotFoundError:
            parent = candidate.parent
            if parent == candidate:
                raise
            candidate = parent

def source_identity(stat):
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)

def source_is_unchanged(path: Path, initial_identity, stage: str) -> bool:
    global had_error
    if is_open(path):
        had_error = True
        print(f"session-payload-repair abort_open stage={stage} path={path}", file=sys.stderr)
        return False
    try:
        current_identity = source_identity(path.stat())
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair abort_stat_failed stage={stage} path={path}: {exc}", file=sys.stderr)
        return False
    if current_identity != initial_identity:
        had_error = True
        print(
            "session-payload-repair abort_source_changed="
            f"{path} stage={stage} initial={initial_identity} current={current_identity}",
            file=sys.stderr,
        )
        return False
    return True

def prepare_backup(path: Path):
    global active_backup_tmp
    try:
        rel = path.relative_to(sessions_dir)
    except ValueError:
        rel = Path(path.name)
    target = backup_dir / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise FileExistsError(f"backup target already exists: {target}")
    backup_tmp = target.with_name(f".{target.name}.tmp-session-backup-{os.getpid()}")
    active_backup_tmp = backup_tmp
    for args in (
        ["/bin/cp", "-c", "-p", str(path), str(backup_tmp)],
        ["/bin/cp", "-p", str(path), str(backup_tmp)],
    ):
        try:
            subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            return target
        except (OSError, subprocess.CalledProcessError):
            try:
                backup_tmp.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                raise
    shutil.copy2(path, backup_tmp)
    return target

def digest_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:16]

def omitted_image_text(stats, detail=None):
    suffix = f"; detail={detail}" if detail else ""
    return (
        f"[screenshot omitted from local history #{stats['images']}; "
        f"large inline image payload removed; original payload remains in the repair backup{suffix}]"
    )

def should_trim_string(key, value):
    if not isinstance(value, str) or len(value) <= string_max_chars:
        return False
    if key in {"encrypted_content", "arguments"}:
        return False
    if key in {"output", "result"}:
        return True
    if "data:image/" in value:
        return True
    return len(value) > max(string_max_chars * 4, 1000000)

def trim_large_string(value, stats):
    stats["strings"] += 1
    stats["string_chars"] += len(value)
    prefix = value[:2000].rstrip()
    marker = (
        f"[large local history payload omitted; original_chars={len(value)}; "
        f"sha256={digest_text(value)}; full payload is in the repair backup]"
    )
    if prefix:
        return f"{prefix}\n\n{marker}"
    return marker

def trim_large_mcp_result(value, stats):
    try:
        serialized = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        return value
    if len(serialized) <= string_max_chars:
        return value
    stats["strings"] += 1
    stats["string_chars"] += len(serialized)
    return {
        "omitted": (
            f"[large MCP tool result omitted; original_chars={len(serialized)}; "
            f"sha256={digest_text(serialized)}; full payload is in the repair backup]"
        )
    }

def scrub_session_payload(obj, stats, key=None):
    if isinstance(obj, dict):
        if obj.get("type") == "mcp_tool_call_end" and "result" in obj:
            repaired = {child_key: scrub_session_payload(value, stats, child_key) for child_key, value in obj.items()}
            repaired["result"] = trim_large_mcp_result(repaired.get("result"), stats)
            return repaired
        image_url = obj.get("image_url")
        if (
            obj.get("type") == "input_image"
            and isinstance(image_url, str)
            and image_url.startswith("data:image/")
            and len(image_url) >= image_min_chars
        ):
            stats["images"] += 1
            stats["chars"] += len(image_url)
            detail = obj.get("detail")
            return {
                "type": "input_text",
                "text": omitted_image_text(stats, detail),
            }
        return {child_key: scrub_session_payload(value, stats, child_key) for child_key, value in obj.items()}
    if isinstance(obj, list):
        return [scrub_session_payload(value, stats, key) for value in obj]
    if should_trim_string(key, obj):
        return trim_large_string(obj, stats)
    return obj

def repair_rollout(path: Path):
    global active_backup_target, active_backup_tmp, active_source_identity, active_source_path, active_tmp
    global files_changed, had_error
    global image_chars_omitted, images_omitted, saw_low_space, string_chars_omitted, strings_omitted

    try:
        initial_stat = path.stat()
        initial_identity = source_identity(initial_stat)
        source_size = initial_stat.st_size
        if source_size < min_bytes:
            return
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair source_stat_failed={path}: {exc}", file=sys.stderr)
        return

    if is_open(path):
        print(f"session-payload-repair skip_open={path}", file=sys.stderr)
        return

    # Check the real filesystem for each destination without creating a backup
    # directory first.  APFS clone is cheap, but the safe fallback is a full copy.
    try:
        backup_parent, backup_parent_stat = existing_parent(backup_root)
        sessions_free = shutil.disk_usage(path.parent).free
        backup_free = shutil.disk_usage(backup_parent).free
    except OSError as exc:
        had_error = True
        print(f"session-payload-repair skip_disk_check_failed={path}: {exc}", file=sys.stderr)
        return

    if initial_stat.st_dev == backup_parent_stat.st_dev:
        sessions_required = min_free_reserve + (source_size * 2)
        backup_required = sessions_required
        enough_space = sessions_free >= sessions_required
    else:
        sessions_required = min_free_reserve + source_size
        backup_required = min_free_reserve + source_size
        enough_space = sessions_free >= sessions_required and backup_free >= backup_required
    if not enough_space:
        saw_low_space = True
        print(
            "session-payload-repair skip_low_space="
            f"{path} sessions_dev={initial_stat.st_dev} backup_dev={backup_parent_stat.st_dev} "
            f"sessions_free={sessions_free} sessions_required={sessions_required} "
            f"backup_free={backup_free} backup_required={backup_required} "
            f"reserve_bytes={min_free_reserve} source_bytes={source_size}",
            file=sys.stderr,
        )
        return

    tmp = path.with_name(f".{path.name}.tmp-session-payload-repair-{os.getpid()}")
    active_tmp = tmp
    active_backup_target = None
    active_source_path = path
    active_source_identity = initial_identity
    changed = False
    file_images = 0
    file_chars = 0
    file_strings = 0
    file_string_chars = 0

    try:
        with path.open("r", encoding="utf-8") as src, tmp.open("w", encoding="utf-8") as dst:
            for line in src:
                if "data:image/" not in line and len(line) <= string_max_chars:
                    dst.write(line)
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    dst.write(line)
                    continue
                stats = {"images": 0, "chars": 0, "strings": 0, "string_chars": 0}
                repaired = scrub_session_payload(record, stats)
                if stats["images"] or stats["strings"]:
                    changed = True
                    file_images += stats["images"]
                    file_chars += stats["chars"]
                    file_strings += stats["strings"]
                    file_string_chars += stats["string_chars"]
                    dst.write(json.dumps(repaired, ensure_ascii=False, separators=(",", ":")))
                    dst.write("\n")
                else:
                    dst.write(line)
    except Exception as exc:
        had_error = True
        remove_active_artifacts()
        print(f"session-payload-repair failed={path}: {exc}", file=sys.stderr)
        return

    if not changed:
        remove_active_artifacts()
        return

    if not source_is_unchanged(path, initial_identity, "pre_backup"):
        remove_active_artifacts()
        return

    try:
        backup_target = prepare_backup(path)
        if not source_is_unchanged(path, initial_identity, "pre_replace"):
            remove_active_artifacts()
            return
        active_backup_target = backup_target
        os.replace(active_backup_tmp, backup_target)
        active_backup_tmp = None
        os.replace(tmp, path)
    except Exception as exc:
        had_error = True
        remove_active_artifacts()
        print(f"session-payload-repair replace_failed={path}: {exc}", file=sys.stderr)
        return

    active_tmp = None
    active_backup_target = None
    active_source_path = None
    active_source_identity = None

    files_changed += 1
    images_omitted += file_images
    image_chars_omitted += file_chars
    strings_omitted += file_strings
    string_chars_omitted += file_string_chars
    print(
        "session-payload-repair repaired="
        f"{path} images={file_images} image_chars={file_chars} "
        f"strings={file_strings} string_chars={file_string_chars}",
        file=sys.stderr,
    )

for rollout_path in sessions_dir.rglob("rollout-*.jsonl"):
    repair_rollout(rollout_path)

if files_changed:
    print(
        "session-payload-repair summary "
        f"files={files_changed} images={images_omitted} image_chars={image_chars_omitted} "
        f"strings={strings_omitted} string_chars={string_chars_omitted} backup={backup_dir}",
        file=sys.stderr,
    )
else:
    try:
        backup_dir.rmdir()
    except OSError:
        pass

if had_error:
    raise SystemExit(1)
if saw_low_space:
    raise SystemExit(28)
PY
}

prune_global_state_for_home() {
  local account_home="$1"

  [[ -d "$account_home" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  CODEX_PRUNE_ACCOUNT_HOME="$account_home" python3 - <<'PY'
import json
import os
import re
import sqlite3
from pathlib import Path

home = Path(os.environ["CODEX_PRUNE_ACCOUNT_HOME"]).expanduser()
state_paths = [path for path in (home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite") if path.exists()]
global_state_path = home / ".codex-global-state.json"

if not state_paths or not global_state_path.exists():
    raise SystemExit(0)

def table_columns(con, table):
    try:
        return [row[1] for row in con.execute(f"PRAGMA table_info({table})").fetchall()]
    except sqlite3.Error:
        return []

def text(row, key):
    return str(row.get(key) or "").strip()

def marker(row):
    for key in ("updated_at_ms", "updated_at"):
        value = row.get(key)
        if value is None:
            continue
        try:
            return int(value) if key == "updated_at_ms" else int(value) * 1000
        except (TypeError, ValueError):
            pass
    return 0

def rollout_exists(row):
    rollout_path = text(row, "rollout_path")
    if not rollout_path:
        return False
    try:
        return Path(rollout_path).exists()
    except OSError:
        return False

def is_live(row):
    try:
        archived = int(row.get("archived") or 0)
    except (TypeError, ValueError):
        archived = 1
    return archived == 0 and bool(text(row, "preview") or text(row, "title")) and rollout_exists(row)

rows_by_id = {}
for db_path in state_paths:
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
        con.execute("PRAGMA busy_timeout=3000")
        cols = table_columns(con, "threads")
        if not cols or "id" not in cols:
            con.close()
            continue
        query_cols = ", ".join(f'"{col}"' for col in cols)
        for values in con.execute(f"SELECT {query_cols} FROM threads"):
            row = dict(zip(cols, values))
            thread_id = text(row, "id")
            if thread_id:
                rows_by_id.setdefault(thread_id, []).append(row)
        con.close()
    except sqlite3.Error:
        pass

live_rows = {}
for thread_id, rows in rows_by_id.items():
    live = [row for row in rows if is_live(row)]
    if live:
        live_rows[thread_id] = max(live, key=marker)

try:
    state = json.loads(global_state_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
if not isinstance(state, dict):
    raise SystemExit(0)

def ids_from_list(value):
    return set(str(item) for item in value if item) if isinstance(value, list) else set()

def keys_from_dict(value):
    return set(str(key) for key in value.keys() if key) if isinstance(value, dict) else set()

PROJECT_MARKER_FILES = (
    ".git",
    "package.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "pyproject.toml",
    "requirements.txt",
    "Package.swift",
    "Cargo.toml",
    "pom.xml",
    "build.gradle",
    "settings.gradle",
    "go.mod",
    "composer.json",
)

PROJECT_MARKER_GLOBS = (
    "*.xcodeproj",
    "*.xcworkspace",
    "*.sln",
    "*.csproj",
)

KEEP_GENERATED_CODEX_PROJECTS = os.environ.get("CODEX_KEEP_GENERATED_CODEX_PROJECTS") == "1"

def root_path(root):
    if not root or not root.startswith("/"):
        return None
    try:
        return Path(root)
    except OSError:
        return None

def has_project_marker(root):
    path = root_path(root)
    if path is None or not path.exists() or not path.is_dir():
        return False
    for marker in PROJECT_MARKER_FILES:
        if (path / marker).exists():
            return True
    for pattern in PROJECT_MARKER_GLOBS:
        try:
            if next(path.glob(pattern), None) is not None:
                return True
        except OSError:
            pass
    return False

def is_generated_codex_workspace(root):
    return bool(
        re.search(r"/Documents/Codex/\d{4}-\d{2}-\d{2}/[^/]+/?$", root)
        or re.search(r"/MacOffload/\d{4}-\d{2}-\d{2}/Documents/[^/]+/?$", root)
    )

def root_is_real_project(root):
    if not root:
        return False
    if not root.startswith("/"):
        return True
    path = root_path(root)
    if path is None or not path.exists():
        return False
    if is_generated_codex_workspace(root):
        return KEEP_GENERATED_CODEX_PROJECTS and has_project_marker(root)
    return True

pinned_ids = ids_from_list(state.get("pinned-thread-ids"))
existing_projectless_ids = ids_from_list(state.get("projectless-thread-ids"))
output_projectless_ids = keys_from_dict(state.get("thread-projectless-output-directories"))
live_thread_ids = set(live_rows)
project_thread_ids = set()
projectless_ids = set()
root_recency = {}
for thread_id, row in live_rows.items():
    root = text(row, "cwd")
    if not root:
        continue
    if thread_id in output_projectless_ids or thread_id in existing_projectless_ids:
        projectless_ids.add(thread_id)
        continue
    if thread_id in pinned_ids:
        continue
    if root_is_real_project(root):
        project_thread_ids.add(thread_id)
        root_recency[root] = max(root_recency.get(root, 0), marker(row))
    else:
        projectless_ids.add(thread_id)

live_roots = {text(live_rows[thread_id], "cwd") for thread_id in project_thread_ids if text(live_rows[thread_id], "cwd")}

next_state = dict(state)
for key in ("electron-saved-workspace-roots", "project-order"):
    value = next_state.get(key)
    if isinstance(value, list):
        filtered = []
        seen = set()
        for root in value:
            root = str(root)
            if root in live_roots and root not in seen:
                seen.add(root)
                filtered.append(root)
        for root in sorted(live_roots - seen, key=lambda item: (-root_recency.get(item, 0), item)):
            seen.add(root)
            filtered.append(root)
        next_state[key] = filtered

for key in ("thread-workspace-root-hints", "thread-project-assignments", "thread-writable-roots"):
    value = next_state.get(key)
    if isinstance(value, dict):
        next_state[key] = {thread_id: item for thread_id, item in value.items() if str(thread_id) in project_thread_ids}

for key in ("sidebar-thread-metadata", "thread-projectless-output-directories"):
    value = next_state.get(key)
    if isinstance(value, dict):
        next_state[key] = {thread_id: item for thread_id, item in value.items() if str(thread_id) in live_thread_ids}

value = next_state.get("electron-workspace-root-labels")
if isinstance(value, dict):
    next_state["electron-workspace-root-labels"] = {root: item for root, item in value.items() if root in live_roots}

value = next_state.get("sidebar-project-thread-orders")
if isinstance(value, dict):
    filtered_orders = {}
    for root, thread_ids in value.items():
        if root not in live_roots:
            continue
        if isinstance(thread_ids, list):
            kept = [thread_id for thread_id in thread_ids if str(thread_id) in project_thread_ids]
            if kept:
                filtered_orders[root] = kept
    next_state["sidebar-project-thread-orders"] = filtered_orders

value = next_state.get("projectless-thread-ids")
if isinstance(value, list):
    ordered_projectless = []
    seen_projectless = set()
    for thread_id in value:
        thread_key = str(thread_id)
        if thread_key in projectless_ids and thread_key not in seen_projectless:
            seen_projectless.add(thread_key)
            ordered_projectless.append(thread_id)
    for thread_id in sorted(projectless_ids - seen_projectless):
        ordered_projectless.append(thread_id)
    next_state["projectless-thread-ids"] = ordered_projectless
elif projectless_ids:
    next_state["projectless-thread-ids"] = sorted(projectless_ids)

if next_state != state:
    tmp = global_state_path.with_name(f".{global_state_path.name}.tmp-{os.getpid()}")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(next_state, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(tmp, global_state_path)
PY
}

prune_local_thread_catalog_for_home() {
  local account_home="$1"

  [[ "${CODEX_PRUNE_LOCAL_THREAD_CATALOG:-1}" == "1" ]] || return 0
  [[ -d "$account_home" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  CODEX_PRUNE_ACCOUNT_HOME="$account_home" CODEX_CATALOG_ORPHAN_GRACE_SECONDS="${CODEX_CATALOG_ORPHAN_GRACE_SECONDS:-120}" python3 - <<'PY'
import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path

home = Path(os.environ["CODEX_PRUNE_ACCOUNT_HOME"]).expanduser()
catalog_db = home / "sqlite" / "codex-dev.db"
state_paths = [path for path in (home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite") if path.exists()]

private_history = os.environ.get("CODEX_PRUNE_PRIVATE_HISTORY", "0") == "1"
try:
    configured_grace = int(float(os.environ.get("CODEX_CATALOG_ORPHAN_GRACE_SECONDS", "120")))
    grace_seconds = max(0 if private_history else 30, configured_grace)
except ValueError:
    grace_seconds = 0 if private_history else 120

if not catalog_db.exists() or not state_paths:
    raise SystemExit(0)

def table_columns(con, table):
    try:
        return [row[1] for row in con.execute(f"PRAGMA table_info({table})").fetchall()]
    except sqlite3.Error:
        return []

def has_table(con, table):
    try:
        row = con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
        return row is not None
    except sqlite3.Error:
        return False

def good_state_thread_ids():
    ids = set()
    for db_path in state_paths:
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1)
            con.execute("PRAGMA busy_timeout=1000")
            cols = table_columns(con, "threads")
            if not cols or "id" not in cols:
                con.close()
                continue
            rollout_expr = "rollout_path" if "rollout_path" in cols else "''"
            archived_expr = "archived" if "archived" in cols else "0"
            for thread_id, rollout_path, archived in con.execute(f"SELECT id, {rollout_expr}, {archived_expr} FROM threads"):
                if not thread_id:
                    continue
                rollout_text = str(rollout_path or "").strip()
                if rollout_text:
                    try:
                        if Path(rollout_text).exists():
                            ids.add(str(thread_id))
                            continue
                    except OSError:
                        pass
                try:
                    if int(archived or 0) == 0:
                        ids.add(str(thread_id))
                except (TypeError, ValueError):
                    ids.add(str(thread_id))
            con.close()
        except sqlite3.Error:
            pass
    return ids

def maybe_session_dirs():
    seen = set()
    candidates = [home / "sessions"]
    if not private_history:
        candidates.extend([
            Path.home() / ".codex-shared-history" / "sessions",
            Path.home() / ".codex" / "sessions",
        ])
    for path in candidates:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        key = str(resolved)
        if key in seen or not path.exists() or not path.is_dir():
            continue
        seen.add(key)
        yield path

def rollout_file_exists(thread_id):
    needle = str(thread_id)
    for root in maybe_session_dirs():
        try:
            if next(root.rglob(f"*{needle}*.jsonl"), None) is not None:
                return True
        except OSError:
            pass
    return False

def row_age_seconds(row):
    now = time.time()
    for key in ("source_updated_at", "source_created_at"):
        value = row.get(key)
        if value is None:
            continue
        try:
            timestamp = float(value)
        except (TypeError, ValueError):
            continue
        if timestamp > 10_000_000_000:
            timestamp = timestamp / 1000
        return now - timestamp
    return 0

try:
    con = sqlite3.connect(catalog_db, timeout=1)
    con.execute("PRAGMA busy_timeout=1000")
except sqlite3.Error:
    raise SystemExit(0)

try:
    if not has_table(con, "local_thread_catalog"):
        raise SystemExit(0)
    cols = table_columns(con, "local_thread_catalog")
    required = {"thread_id", "host_id", "source_kind", "source_created_at", "source_updated_at"}
    if not required.issubset(set(cols)):
        raise SystemExit(0)
    query_cols = ", ".join(f'"{col}"' for col in cols)
    catalog_rows = [dict(zip(cols, values)) for values in con.execute(f"SELECT {query_cols} FROM local_thread_catalog")]
    keep_ids = good_state_thread_ids()
    delete_ids = []
    for row in catalog_rows:
        thread_id = str(row.get("thread_id") or "").strip()
        if not thread_id or thread_id in keep_ids:
            continue
        if str(row.get("host_id") or "") != "local":
            continue
        if str(row.get("source_kind") or "") != "vscode":
            continue
        if row_age_seconds(row) < grace_seconds:
            continue
        if rollout_file_exists(thread_id):
            continue
        delete_ids.append(thread_id)

    if not delete_ids:
        raise SystemExit(0)

    backup_root = home / "recovery-backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    backup_dir = backup_root / f"codex-dev-auto-prune-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_con = sqlite3.connect(backup_dir / "codex-dev.db")
    con.backup(backup_con)
    backup_con.close()

    placeholders = ",".join("?" for _ in delete_ids)
    con.execute("BEGIN IMMEDIATE")
    con.execute(f"DELETE FROM local_thread_catalog WHERE thread_id IN ({placeholders})", delete_ids)
    if has_table(con, "local_thread_catalog_metadata") and "catalog_revision" in table_columns(con, "local_thread_catalog_metadata"):
        con.execute("UPDATE local_thread_catalog_metadata SET catalog_revision = catalog_revision + 1 WHERE id = 1")
    con.commit()
finally:
    con.close()
PY
}

cleanup_empty_projects() {
  list_accounts | while IFS='|' read -r raw_name raw_home _; do
    local name home
    name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    home="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$name" && -n "$home" ]] || continue
    if [[ "$CODEX_DELETE_STALE_THREAD_ROWS" == "1" ]]; then
      cleanup_thread_index_for_home "$home"
    fi
    prune_local_thread_catalog_for_home "$home" >/dev/null 2>&1 || true
    prune_global_state_for_home "$home" >/dev/null 2>&1 || true
  done
}

prune_global_state_loop() {
  while true; do
    cleanup_empty_projects >/dev/null 2>&1 || true
    sleep "$CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS"
  done
}

quarantine_memories_for_private_history() {
  local account_home="$1"
  local source="$account_home/memories"
  local backup_dir="${2:-}"

  [[ "${CODEX_PRIVATE_HISTORY_QUARANTINE_FORCE_FAIL:-0}" != "1" ]] || return 1
  if [[ -e "$source" || -L "$source" ]]; then
    [[ -n "$backup_dir" ]] || backup_dir="$account_home/backups/history-private-$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$backup_dir" || return 1
    mv "$source" "$backup_dir/memories" || return 1
    echo "Quarantined previous memories: $backup_dir/memories"
  fi
  mkdir -p "$source" || return 1
}

restore_quarantined_memories_after_private_failure() {
  local account_home="$1" backup_dir="${2:-}"
  [[ -n "$backup_dir" && -e "$backup_dir/memories" ]] || return 0
  [[ ! -e "$account_home/memories" && ! -L "$account_home/memories" ]] || rmdir "$account_home/memories"
  mv "$backup_dir/memories" "$account_home/memories"
}

capture_shared_thread_ids_for_private_history() {
  local account_home="$1" ids_file="$2"
  CODEX_PRIVATE_HOME="$account_home" CODEX_PRIVATE_SHARED_SESSIONS="$SHARED_SESSIONS_DIR" CODEX_PRIVATE_IDS_FILE="$ids_file" python3 - <<'PY'
import json, os, sqlite3
from pathlib import Path
home = Path(os.environ['CODEX_PRIVATE_HOME'])
shared = Path(os.environ['CODEX_PRIVATE_SHARED_SESSIONS'])
ids = set()
def is_shared(value):
    if not value: return False
    path = Path(str(value)).expanduser()
    try:
        path.relative_to(shared); return True
    except ValueError: pass
    try:
        path.resolve().relative_to(shared.resolve()); return True
    except (OSError, ValueError): return False
for db in (home / 'state_5.sqlite', home / 'sqlite' / 'state_5.sqlite'):
    if not db.exists() or db.is_symlink(): continue
    try:
        con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=2)
        cols = [row[1] for row in con.execute('PRAGMA table_info(threads)')]
        if 'id' in cols and 'rollout_path' in cols:
            for thread_id, rollout_path in con.execute('SELECT id, rollout_path FROM threads'):
                if thread_id and is_shared(rollout_path): ids.add(str(thread_id))
        con.close()
    except sqlite3.Error: pass
index = home / 'session_index.jsonl'
if index.exists():
    for line in index.read_text(encoding='utf-8', errors='replace').splitlines():
        try:
            thread_id = json.loads(line).get('id')
            if thread_id: ids.add(str(thread_id))
        except (json.JSONDecodeError, AttributeError): pass
catalog = home / 'sqlite' / 'codex-dev.db'
if catalog.exists() and not catalog.is_symlink():
    try:
        con = sqlite3.connect(f'file:{catalog}?mode=ro', uri=True, timeout=2)
        ids.update(str(row[0]) for row in con.execute('SELECT thread_id FROM local_thread_catalog') if row[0])
        con.close()
    except sqlite3.Error: pass
Path(os.environ['CODEX_PRIVATE_IDS_FILE']).write_text('\n'.join(sorted(ids)) + ('\n' if ids else ''), encoding='utf-8')
PY
}

verify_private_history_detached() {
  local account_home="$1" ids_file="$2"
  CODEX_PRIVATE_HOME="$account_home" CODEX_PRIVATE_SHARED_SESSIONS="$SHARED_SESSIONS_DIR" CODEX_PRIVATE_IDS_FILE="$ids_file" python3 - <<'PY'
import json, os, sqlite3, sys
from pathlib import Path
home = Path(os.environ['CODEX_PRIVATE_HOME'])
shared = Path(os.environ['CODEX_PRIVATE_SHARED_SESSIONS'])
ids = {line.strip() for line in Path(os.environ['CODEX_PRIVATE_IDS_FILE']).read_text(encoding='utf-8').splitlines() if line.strip()}
for item in ('session_index.jsonl', 'sessions', 'shell_snapshots'):
    path = home / item
    if path.is_symlink(): raise SystemExit(f'private history link remains: {path}')
def is_shared(value):
    if not value: return False
    path = Path(str(value)).expanduser()
    try:
        path.relative_to(shared); return True
    except ValueError: pass
    try:
        path.resolve().relative_to(shared.resolve()); return True
    except (OSError, ValueError): return False
for db in (home / 'state_5.sqlite', home / 'sqlite' / 'state_5.sqlite'):
    if not db.exists() or db.is_symlink(): continue
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=2)
    cols = [row[1] for row in con.execute('PRAGMA table_info(threads)')]
    if 'rollout_path' in cols:
        if any(is_shared(row[0]) for row in con.execute('SELECT rollout_path FROM threads')):
            raise SystemExit(f'shared thread metadata remains: {db}')
    con.close()
catalog = home / 'sqlite' / 'codex-dev.db'
if ids and catalog.exists() and not catalog.is_symlink():
    con = sqlite3.connect(f'file:{catalog}?mode=ro', uri=True, timeout=2)
    if any(row[0] in ids for row in con.execute('SELECT thread_id FROM local_thread_catalog')):
        raise SystemExit('shared catalog metadata remains')
    con.close()
index = home / 'session_index.jsonl'
if ids and index.exists():
    for line in index.read_text(encoding='utf-8', errors='replace').splitlines():
        try:
            if str(json.loads(line).get('id', '')) in ids: raise SystemExit('shared session index metadata remains')
        except json.JSONDecodeError: continue
PY
}

remove_captured_private_history_metadata() {
  local account_home="$1" ids_file="$2"
  CODEX_PRIVATE_HOME="$account_home" CODEX_PRIVATE_IDS_FILE="$ids_file" python3 - <<'PY'
import json, os, sqlite3
from pathlib import Path

home = Path(os.environ['CODEX_PRIVATE_HOME'])
ids = {line.strip() for line in Path(os.environ['CODEX_PRIVATE_IDS_FILE']).read_text(encoding='utf-8').splitlines() if line.strip()}
if not ids:
    raise SystemExit(0)

def columns(con, table):
    try:
        return {row[1] for row in con.execute(f'PRAGMA table_info("{table}")')}
    except sqlite3.Error:
        return set()

def remove_from_database(path):
    if not path.exists() or path.is_symlink():
        return
    con = sqlite3.connect(path, timeout=3)
    try:
        for table, field in (("threads", "id"), ("local_thread_catalog", "thread_id")):
            if field not in columns(con, table):
                continue
            placeholders = ','.join('?' for _ in ids)
            con.execute(f'DELETE FROM "{table}" WHERE "{field}" IN ({placeholders})', tuple(ids))
        con.commit()
    finally:
        con.close()

for path in (home / 'state_5.sqlite', home / 'sqlite' / 'state_5.sqlite', home / 'sqlite' / 'codex-dev.db'):
    remove_from_database(path)

index = home / 'session_index.jsonl'
if index.exists() and not index.is_symlink():
    kept = []
    for line in index.read_text(encoding='utf-8', errors='replace').splitlines():
        try:
            if str(json.loads(line).get('id', '')) in ids:
                continue
        except (json.JSONDecodeError, AttributeError):
            pass
        kept.append(line)
    index.write_text(('\n'.join(kept) + '\n') if kept else '', encoding='utf-8')

state_path = home / '.codex-global-state.json'
if state_path.exists():
    try:
        state = json.loads(state_path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        state = None
    if isinstance(state, dict):
        def strip_ids(value):
            if isinstance(value, list):
                return [strip_ids(item) for item in value if str(item) not in ids]
            if isinstance(value, dict):
                return {key: strip_ids(item) for key, item in value.items() if str(key) not in ids}
            return value
        state_path.write_text(json.dumps(strip_ids(state), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
PY
}

backup_private_history_transaction_metadata() {
  local account_home="$1" backup_dir="$2"
  CODEX_TX_HOME="$account_home" CODEX_TX_BACKUP="$backup_dir" python3 - <<'PY'
import os, shutil, sqlite3
from pathlib import Path
home, backup = Path(os.environ['CODEX_TX_HOME']), Path(os.environ['CODEX_TX_BACKUP'])
backup.mkdir(parents=True, exist_ok=True)
for rel in ('state_5.sqlite', 'sqlite/state_5.sqlite', 'sqlite/codex-dev.db'):
    source = home / rel
    if not source.exists() or source.is_symlink(): continue
    target = backup / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    src = dst = None
    try:
        src = sqlite3.connect(f'file:{source}?mode=ro', uri=True, timeout=2)
        dst = sqlite3.connect(target)
        src.backup(dst)
    finally:
        if dst is not None:
            dst.close()
        if src is not None:
            src.close()
for rel in ('.codex-global-state.json', 'session_index.jsonl'):
    source = home / rel
    if source.exists():
        target = backup / rel; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
PY
}

restore_private_history_transaction_metadata() {
  local account_home="$1" backup_dir="$2"
  CODEX_TX_HOME="$account_home" CODEX_TX_BACKUP="$backup_dir" python3 - <<'PY'
import os, shutil
from pathlib import Path
home, backup = Path(os.environ['CODEX_TX_HOME']), Path(os.environ['CODEX_TX_BACKUP'])
for rel in ('state_5.sqlite', 'sqlite/state_5.sqlite', 'sqlite/codex-dev.db', '.codex-global-state.json'):
    source, target = backup / rel, home / rel
    if source.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.suffix in ('.sqlite', '.db'):
            for sidecar in (target.with_name(target.name + '-wal'), target.with_name(target.name + '-shm')):
                try: sidecar.unlink()
                except FileNotFoundError: pass
        shutil.copy2(source, target)
PY
}

restore_shared_history_after_private_failure() {
  local account_home="$1" backup_dir="${2:-}"
  [[ -z "$backup_dir" ]] || restore_private_history_transaction_metadata "$account_home" "$backup_dir" || return 1
  CODEX_SHARED_SESSIONS=1 ensure_shared_history_links "$account_home" || return 1
  set_history_mode_for_home "$account_home" shared
}

profile_transition_is_busy() {
  local name="$1" home_dir="$2" pid args active_homes
  profile_window_is_running "$name" && return 0
  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    [[ "$args" == *"codex app-server"* ]] || continue
    [[ "$args" == *"--codex-home $home_dir"* || "$args" == *"--codex-home=$home_dir"* ]] && return 0
    process_env_contains "$pid" "CODEX_HOME=$home_dir" && return 0
  done < <(ps axww -o pid= -o args=)
  active_homes="$(active_sqlite_homes_payload "$home_dir" 2>/dev/null || true)"
  [[ "$active_homes" == *"$home_dir"* ]]
}

separate_history_for_unlocked() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "separate-history requires an account name." >&2
    exit 2
  fi

  local account_home current_mode
  account_home="$(account_home_for "$name")"
  if is_history_anchor_home "$account_home"; then
    echo "The history anchor must remain shared." >&2
    return 1
  fi
  if profile_transition_is_busy "$name" "$account_home"; then
    echo "Close this Codex profile and wait for its app-server/database writes before switching history." >&2
    return 1
  fi
  current_mode="$(history_mode_for_home "$account_home")"
  if [[ "$current_mode" == "private" ]]; then
    echo "$(sanitize_account_name "$name") history is already private."
    return 0
  fi

  local ids_file transaction_backup_dir memory_backup_dir
  ids_file="$(mktemp "$account_home/.private-history-ids.XXXXXX")"
  capture_shared_thread_ids_for_private_history "$account_home" "$ids_file" || { rm -f "$ids_file"; return 1; }
  transaction_backup_dir="$account_home/backups/private-history-transaction-$(date '+%Y%m%d-%H%M%S')"
  backup_private_history_transaction_metadata "$account_home" "$transaction_backup_dir" || { rm -f "$ids_file"; return 1; }

  # Do not copy from, move, or rewrite the shared source. These calls only
  # replace this profile's three symlinks with blank local paths.
  detach_shared_history_links "$account_home"
  # The rollout paths were resolved through this profile's former symlink. Now
  # that it is detached, cleanup backs up local metadata and removes only rows
  # whose local rollout path is absent; it never moves the shared source.
  if [[ "${CODEX_PRIVATE_HISTORY_CLEANUP_FORCE_FAIL:-0}" == "1" ]] || ! CODEX_CLEANUP_PRIVATE_HISTORY=1 CODEX_SHARED_SESSIONS_DIR="$SHARED_SESSIONS_DIR" \
    cleanup_thread_index_for_home "$account_home" >/dev/null 2>&1; then
    restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir" || true
    rm -f "$ids_file"
    return 1
  fi
  # Private mode intentionally does not inspect the global shared sessions
  # directory, so stale catalog rows cannot keep shared titles visible.
  if ! CODEX_PRUNE_PRIVATE_HISTORY=1 CODEX_CATALOG_ORPHAN_GRACE_SECONDS=0 \
    prune_local_thread_catalog_for_home "$account_home" >/dev/null 2>&1 \
    || ! remove_captured_private_history_metadata "$account_home" "$ids_file" \
    || ! verify_private_history_detached "$account_home" "$ids_file"; then
    restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir" || true
    rm -f "$ids_file"
    return 1
  fi
  if [[ "${CODEX_PRIVATE_HISTORY_POST_CLEANUP_FORCE_FAIL:-0}" == "1" ]]; then
    restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir" || true
    rm -f "$ids_file"
    return 1
  fi
  # Existing memories may already contain synchronized summaries. Preserve a
  # reversible backup, then start this profile with a local empty directory.
  memory_backup_dir="$account_home/backups/history-private-$(date '+%Y%m%d-%H%M%S')"
  if ! quarantine_memories_for_private_history "$account_home" "$memory_backup_dir"; then
    restore_quarantined_memories_after_private_failure "$account_home" "$memory_backup_dir" || true
    restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir" || true
    rm -f "$ids_file"
    return 1
  fi
  if ! set_history_mode_for_home "$account_home" private; then
    restore_quarantined_memories_after_private_failure "$account_home" "$memory_backup_dir" || true
    restore_shared_history_after_private_failure "$account_home" "$transaction_backup_dir" || true
    rm -f "$ids_file"
    return 1
  fi
  rm -f "$ids_file"
  echo "Separated $(sanitize_account_name "$name") history: future local conversations stay private."
}

separate_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "separate-history requires an account name." >&2
    exit 2
  fi
  ensure_dirs
  CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
    CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock separate_history_for_unlocked "$name"
}

separate_all_history() {
  list_accounts | cut -d '|' -f 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | while read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(account_home_for "$name")" == "$PRIMARY_CODEX_HOME" ]] && continue
    [[ "$(account_home_for "$name")" == "$CODEX_HISTORY_ANCHOR_HOME" ]] && continue
    separate_history_for "$name"
  done
}

link_all_history() {
  local raw_name name home_dir
  CODEX_SHARED_SESSIONS=1
  while IFS='|' read -r raw_name _; do
    name="$(printf '%s' "$raw_name" | sed 's/[[:space:]]//g')"
    [[ -n "$name" ]] || continue
    home_dir="$(account_home_for "$name")"
    if [[ "$(history_mode_for_home "$home_dir")" == "private" ]]; then
      echo "Skipping private history profile: $(sanitize_account_name "$name")"
      continue
    fi
    CODEX_LINK_HISTORY_SKIP_PRIVATE=1 link_history_for "$name"
  done < <(list_accounts)
}

link_account2_history() {
  link_history_for "account2"
}

unlink_account2_history() {
  unlink_history_for "account2"
}

run_codex_share_helper() {
  if [[ ! -f "$CODEX_SHARE_HELPER" ]]; then
    echo "Codex share helper not found: $CODEX_SHARE_HELPER" >&2
    exit 1
  fi
  python3 "$CODEX_SHARE_HELPER" "$@"
}

list_exportable_threads() {
  local name="${1:-account1}" limit="${2:-30}" account_home
  account_home="$(account_home_for "$name")"
  run_codex_share_helper list \
    --account-name "$name" \
    --account-home "$account_home" \
    --limit "$limit"
}

export_thread_package() {
  local name="${1:-}" thread_id="${2:-}" output_path="${3:-}" account_home
  shift $(( $# < 3 ? $# : 3 ))
  if [[ -z "$name" || -z "$thread_id" || -z "$output_path" ]]; then
    echo "export-thread-package requires: <account-name> <thread-id> <output.codexshare>" >&2
    exit 2
  fi
  account_home="$(account_home_for "$name")"
  run_codex_share_helper export \
    --account-name "$name" \
    --account-home "$account_home" \
    --thread-id "$thread_id" \
    --output "$output_path" \
    "$@"
}

inspect_thread_package() {
  local package_path="${1:-}"
  if [[ -z "$package_path" ]]; then
    echo "inspect-thread-package requires: <package.codexshare>" >&2
    exit 2
  fi
  run_codex_share_helper inspect --package "$package_path"
}

import_thread_package_unlocked() {
  local package_path="${1:-}" target="${2:-all}" mark_latest_arg="${3:---mark-latest}"
  local -a target_args
  local raw_name raw_home name home
  if [[ -z "$package_path" ]]; then
    echo "import-thread-package requires: <package.codexshare> <account-name|all>" >&2
    exit 2
  fi

  target_args=()
  if [[ "$target" == "all" || "$target" == "--all" || "$target" == "all-profiles" ]]; then
    while IFS='|' read -r raw_name raw_home _; do
      name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      home="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "$name" && -n "$home" ]] || continue
      if [[ "$(history_mode_for_home "$home")" == "private" ]]; then
        echo "Skipping private history profile during import-all: $(sanitize_account_name "$name")" >&2
        continue
      fi
      target_args+=(--target "$name=$home")
    done < <(list_accounts)
  else
    name="$(sanitize_account_name "$target")"
    home="$(account_home_for "$name")"
    target_args+=(--target "$name=$home")
  fi

  if (( ${#target_args[@]} == 0 )); then
    echo "No Codex profiles found for import." >&2
    exit 1
  fi

  if [[ "$mark_latest_arg" == "--no-mark-latest" ]]; then
    run_codex_share_helper import --package "$package_path" "${target_args[@]}"
  else
    run_codex_share_helper import --package "$package_path" "${target_args[@]}" --mark-latest
  fi
}

import_thread_package() {
  local package_path="${1:-}" target="${2:-all}" mark_latest_arg="${3:---mark-latest}"
  ensure_dirs
  CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
    CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock \
      import_thread_package_unlocked "$package_path" "$target" "$mark_latest_arg"
}

tiered_storage_assert_external_root() {
  local archive_root="$1"
  if [[ "$archive_root" != /Volumes/* ]]; then
    echo "Cold storage must be on a mounted external volume under /Volumes." >&2
    return 69
  fi

  local volume_name="${archive_root#/Volumes/}"
  volume_name="${volume_name%%/*}"
  local volume_root="/Volumes/$volume_name"
  if [[ ! -d "$volume_root" || ! -w "$volume_root" ]]; then
    echo "External cold-storage volume is offline or not writable: $volume_root" >&2
    return 69
  fi
  if [[ "$(stat -f '%d' "$volume_root" 2>/dev/null || true)" == "$(stat -f '%d' / 2>/dev/null || true)" ]]; then
    echo "Refusing cold storage because $volume_root is not a separately mounted volume." >&2
    return 69
  fi
  mkdir -p "$archive_root"
}

tiered_storage_assert_idle() {
  local spec name home
  for spec in "$@"; do
    name="${spec%%=*}"
    home="${spec#*=}"
    if profile_transition_is_busy "$name" "$home"; then
      echo "Close all Codex profile windows before archiving or restoring cold storage." >&2
      return 75
    fi
  done
}

shared_cold_storage_targets() {
  local raw_name raw_home name home
  while IFS='|' read -r raw_name raw_home _; do
    name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    home="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$name" && -n "$home" ]] || continue
    home_uses_opencodex_proxy "$home" && continue
    [[ "$(history_mode_for_home "$home")" != "private" ]] || continue
    printf '%s=%s\n' "$name" "$home"
  done < <(list_accounts)
}

archive_thread_cold() {
  local name="${1:-}" thread_id="${2:-}" archive_root="${3:-}"
  if [[ -z "$name" || -z "$thread_id" || -z "$archive_root" ]]; then
    echo "archive-thread-cold requires: <account-name> <thread-id> <external-root>" >&2
    return 2
  fi
  shift 3
  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"
  if [[ "$(history_mode_for_home "$account_home")" != "shared" ]]; then
    echo "Cold storage v1 only archives shared-history tasks; private profile data was not changed." >&2
    return 2
  fi
  tiered_storage_assert_external_root "$archive_root" || return $?

  local -a target_specs target_args
  local spec
  target_specs=()
  target_args=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target_specs+=("$spec")
    target_args+=(--target "$spec")
  done < <(shared_cold_storage_targets)
  (( ${#target_specs[@]} > 0 )) || {
    echo "No shared-history Codex profiles were found." >&2
    return 1
  }
  tiered_storage_assert_idle "${target_specs[@]}" || return $?

  CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
    CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock \
      run_codex_share_helper cold-archive \
        --account-name "$name" \
        --account-home "$account_home" \
        --thread-id "$thread_id" \
        --archive-root "$archive_root" \
        --index "$COLD_STORAGE_INDEX_FILE" \
        "${target_args[@]}" \
        "$@"
}

list_cold_archives() {
  run_codex_share_helper cold-list --index "$COLD_STORAGE_INDEX_FILE"
}

restore_thread_cold() {
  local thread_id="${1:-}"
  if [[ -z "$thread_id" ]]; then
    echo "restore-thread-cold requires: <thread-id>" >&2
    return 2
  fi
  ensure_dirs
  local -a target_specs target_args
  local spec
  target_specs=()
  target_args=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target_specs+=("$spec")
    target_args+=(--target "$spec")
  done < <(shared_cold_storage_targets)
  (( ${#target_specs[@]} > 0 )) || {
    echo "No shared-history Codex profiles were found." >&2
    return 1
  }
  tiered_storage_assert_idle "${target_specs[@]}" || return $?

  CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
    CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock \
      run_codex_share_helper cold-restore \
        --thread-id "$thread_id" \
        --index "$COLD_STORAGE_INDEX_FILE" \
        "${target_args[@]}"
}

archive_threads_cold() {
  local name="${1:-}" archive_root="${2:-}"
  if [[ -z "$name" || -z "$archive_root" || $# -lt 3 ]]; then
    echo "archive-threads-cold requires: <account-name> <external-root> <thread-id>..." >&2
    return 2
  fi
  shift 2
  local -a thread_ids
  thread_ids=("$@")
  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"
  if [[ "$(history_mode_for_home "$account_home")" != "shared" ]]; then
    echo "Cold storage v1 only archives shared-history tasks; private profile data was not changed." >&2
    return 2
  fi
  tiered_storage_assert_external_root "$archive_root" || return $?

  local -a target_specs target_args thread_args
  local spec thread_id
  target_specs=()
  target_args=()
  thread_args=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target_specs+=("$spec")
    target_args+=(--target "$spec")
  done < <(shared_cold_storage_targets)
  (( ${#target_specs[@]} > 0 )) || {
    echo "No shared-history Codex profiles were found." >&2
    return 1
  }
  local archived_count=0 failed_count=0 rc
  for thread_id in "${thread_ids[@]}"; do
    [[ -n "$thread_id" ]] || continue
    tiered_storage_assert_idle "${target_specs[@]}" || {
      rc=$?
      echo "Batch cold storage paused before $thread_id; completed items remain archived." >&2
      return "$rc"
    }
    if CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
      CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock \
        run_codex_share_helper cold-archive \
          --account-name "$name" \
          --account-home "$account_home" \
          --thread-id "$thread_id" \
          --archive-root "$archive_root" \
          --index "$COLD_STORAGE_INDEX_FILE" \
          --include-generated-images \
          --include-local-assets \
          "${target_args[@]}"; then
      (( archived_count += 1 ))
      echo "archived=$thread_id"
    else
      rc=$?
      if [[ "$rc" == "75" || "$rc" == "69" ]]; then
        echo "Batch cold storage paused before $thread_id; completed items remain archived." >&2
        return "$rc"
      fi
      (( failed_count += 1 ))
      echo "failed=$thread_id" >&2
    fi
  done
  echo "batch_archived=$archived_count"
  echo "batch_failed=$failed_count"
  (( failed_count == 0 ))
}

archive_cold_older_than() {
  local name="${1:-}" archive_root="${2:-}" days="${3:-7}"
  if [[ -z "$name" || -z "$archive_root" ]]; then
    echo "archive-cold-older-than requires: <account-name> <external-root> <days>" >&2
    return 2
  fi
  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"
  local -a target_args ids
  local spec candidates
  target_args=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target_args+=(--target "$spec")
  done < <(shared_cold_storage_targets)
  candidates="$(run_codex_share_helper cold-candidates \
    --account-home "$account_home" \
    --older-than-days "$days" \
    --ids-only \
    "${target_args[@]}")"
  ids=("${(@f)candidates}")
  if (( ${#ids[@]} == 0 )); then
    echo "No safe cold-storage candidates older than $days day(s)."
    return 0
  fi
  archive_threads_cold "$name" "$archive_root" "${ids[@]}"
}

restore_threads_cold() {
  if (( $# == 0 )); then
    echo "restore-threads-cold requires: <thread-id>..." >&2
    return 2
  fi
  ensure_dirs
  local -a target_specs target_args thread_args
  local spec thread_id
  target_specs=()
  target_args=()
  thread_args=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target_specs+=("$spec")
    target_args+=(--target "$spec")
  done < <(shared_cold_storage_targets)
  (( ${#target_specs[@]} > 0 )) || {
    echo "No shared-history Codex profiles were found." >&2
    return 1
  }
  local restored_count=0 failed_count=0 rc
  for thread_id in "$@"; do
    [[ -n "$thread_id" ]] || continue
    tiered_storage_assert_idle "${target_specs[@]}" || {
      rc=$?
      echo "Batch restore paused before $thread_id; completed items remain restored." >&2
      return "$rc"
    }
    if CODEX_SYNC_LOCK_MAX_WAITS="${CODEX_HISTORY_MODE_LOCK_MAX_WAITS:-20}" \
      CODEX_SYNC_LOCK_FAIL_ON_TIMEOUT=1 with_sync_lock \
        run_codex_share_helper cold-restore \
          --thread-id "$thread_id" \
          --index "$COLD_STORAGE_INDEX_FILE" \
          "${target_args[@]}"; then
      (( restored_count += 1 ))
      echo "restored=$thread_id"
    else
      rc=$?
      if [[ "$rc" == "75" || "$rc" == "69" ]]; then
        echo "Batch restore paused before $thread_id; completed items remain restored." >&2
        return "$rc"
      fi
      (( failed_count += 1 ))
      echo "failed=$thread_id" >&2
    fi
  done
  echo "batch_restored=$restored_count"
  echo "batch_failed=$failed_count"
  (( failed_count == 0 ))
}

main() {
  local command="${1:-}"
  case "$command" in
    init) copy_initial_profile ;;
    launch-account2) launch_account2 ;;
    sync-once) sync_once ;;
    sync-history-once) sync_history_once ;;
    sync-account) sync_account "${2:-}" ;;
    sync-account-for-launch) sync_account_for_launch "${2:-}" ;;
    repair-account1) repair_account1 ;;
    restore-openai-config-home) restore_non_account1_openai_config_for_home "${2:-}" ;;
    ensure-aliyun-bridge) ensure_aliyun_coding_plan_bridge_running ;;
    repair-compactions) repair_compactions_for_account "${2:-}" ;;
    restore-thread-models-home) restore_default_thread_model_providers_for_home "${2:-}" "no-backup" ;;
    sync-loop) sync_loop ;;
    sync-history-loop) sync_history_loop ;;
    init-account) init_account "${2:-}" ;;
    init-shared-account) init_shared_account "${2:-}" ;;
    launch-account) launch_account "${2:-}" "${3:-}" ;;
    launch-account-nosync) CODEX_PRELAUNCH_SYNC=0 launch_account "${2:-}" "${3:-}" ;;
    codex-app-path) print_codex_app_path ;;
    close-account) close_account "${2:-}" ;;
    close-all-accounts) close_all_accounts ;;
    list-accounts) list_accounts ;;
    account-status) account_status_for "${2:-}" ;;
    list-accounts-status) list_accounts_status ;;
    opencodex-status) opencodex_status ;;
    opencodex-install) opencodex_install ;;
    opencodex-start) opencodex_start ;;
    opencodex-stop) opencodex_stop ;;
    opencodex-restore) opencodex_restore ;;
    opencodex-dashboard) opencodex_dashboard ;;
    opencodex-launch) opencodex_launch ;;
    opencodex-enable-all-profiles) opencodex_enable_all_profiles ;;
    delete-account) delete_account "${2:-}" ;;
    link-history) link_history_for "${2:-}" ;;
    unlink-history) unlink_history_for "${2:-}" ;;
    separate-history) separate_history_for "${2:-}" ;;
    history-mode) history_mode_for "${2:-}" ;;
    separate-all-history) separate_all_history ;;
    cleanup-empty-projects) cleanup_empty_projects ;;
    list-exportable-threads) list_exportable_threads "${2:-account1}" "${3:-30}" ;;
    export-thread-package) export_thread_package "${@:2}" ;;
    inspect-thread-package) inspect_thread_package "${2:-}" ;;
    import-thread-package) import_thread_package "${2:-}" "${3:-all}" "${4:---mark-latest}" ;;
    archive-thread-cold) archive_thread_cold "${@:2}" ;;
    archive-threads-cold) archive_threads_cold "${@:2}" ;;
    archive-cold-older-than) archive_cold_older_than "${2:-}" "${3:-}" "${4:-7}" ;;
    list-cold-archives) list_cold_archives ;;
    restore-thread-cold) restore_thread_cold "${2:-}" ;;
    restore-threads-cold) restore_threads_cold "${@:2}" ;;
    prune-global-state-home) prune_global_state_for_home "${2:-}" ;;
    prune-loop) prune_global_state_loop ;;
    link-all-history) link_all_history ;;
    link-account2-history) link_account2_history ;;
    unlink-account2-history) unlink_account2_history ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $command" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
