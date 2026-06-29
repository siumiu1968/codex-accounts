#!/usr/bin/env zsh
set -euo pipefail
setopt typesetsilent

# Launch a second Codex profile and sync local memory files between profiles.
# This intentionally does not copy auth.json, cookies, or SQLite logs.

CODEX_APP="${CODEX_APP:-/Applications/Codex.app}"
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
CODEX_HISTORY_ANCHOR_HOME="${CODEX_HISTORY_ANCHOR_HOME:-$ACCOUNTS_ROOT/250345400}"
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-20}"
CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS="${CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS:-5}"
USAGE_API_URL="${USAGE_API_URL:-https://chatgpt.com/backend-api/wham/usage}"
TOKEN_REFRESH_URL="${TOKEN_REFRESH_URL:-https://auth.openai.com/oauth/token}"
CHATGPT_CLIENT_ID="${CHATGPT_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
USAGE_CACHE_SECONDS="${USAGE_CACHE_SECONDS:-120}"
USAGE_CACHE_ROOT="${USAGE_CACHE_ROOT:-$APP_DATA_ROOT/.usage-cache-v5}"
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
CODEX_ACTIVE_DB_LSOF_MAX_WAITS="${CODEX_ACTIVE_DB_LSOF_MAX_WAITS:-4}"
CODEX_ACTIVE_DB_LSOF_WAIT_SECONDS="${CODEX_ACTIVE_DB_LSOF_WAIT_SECONDS:-0.05}"
CODEX_RSYNC_MAX_WAITS="${CODEX_RSYNC_MAX_WAITS:-80}"
CODEX_RSYNC_WAIT_SECONDS="${CODEX_RSYNC_WAIT_SECONDS:-0.1}"
CODEX_USAGE_LIVE_LOOKUP="${CODEX_USAGE_LIVE_LOOKUP:-0}"
USAGE_CACHE_STALE_SECONDS="${USAGE_CACHE_STALE_SECONDS:-86400}"
SYNC_LOCK_DIR="${SYNC_LOCK_DIR:-$APP_DATA_ROOT/.sync.lock}"
CODEX_INJECT_PROXY_ENV="${CODEX_INJECT_PROXY_ENV:-1}"
CODEX_PROXY_URL="${CODEX_PROXY_URL:-http://127.0.0.1:7897}"
CODEX_NO_PROXY="${CODEX_NO_PROXY:-localhost,127.0.0.1,::1}"
DASHSCOPE_SECRET_ENV_FILE="${DASHSCOPE_SECRET_ENV_FILE:-$ACCOUNTS_ROOT/.secrets/dashscope.env}"

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
  scripts/codex_multi_account.zsh sync-loop
  scripts/codex_multi_account.zsh init-account <account-name>
  scripts/codex_multi_account.zsh init-shared-account <account-name>
  scripts/codex_multi_account.zsh launch-account <account-name> [display-name]
  scripts/codex_multi_account.zsh launch-account-nosync <account-name> [display-name]
  scripts/codex_multi_account.zsh close-account <account-name>
  scripts/codex_multi_account.zsh close-all-accounts
  scripts/codex_multi_account.zsh list-accounts
  scripts/codex_multi_account.zsh account-status <account-name>
  scripts/codex_multi_account.zsh list-accounts-status
  scripts/codex_multi_account.zsh delete-account <account-name>
  scripts/codex_multi_account.zsh link-history <account-name>
  scripts/codex_multi_account.zsh unlink-history <account-name>
  scripts/codex_multi_account.zsh separate-history <account-name>
  scripts/codex_multi_account.zsh separate-all-history
  scripts/codex_multi_account.zsh cleanup-empty-projects
  scripts/codex_multi_account.zsh link-all-history
  CODEX_SYNC_PLUGIN_PAYLOADS=1 scripts/codex_multi_account.zsh sync-once
  scripts/codex_multi_account.zsh link-account2-history
  scripts/codex_multi_account.zsh unlink-account2-history

Environment overrides:
  CODEX_APP=/Applications/Codex.app
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
  - Codex profile launches inject HTTP_PROXY/HTTPS_PROXY/ALL_PROXY by default
    so WSS and HTTPS traffic use the same local proxy. Set
    CODEX_INJECT_PROXY_ENV=0 to disable this.
USAGE
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
      CREATE TRIGGER IF NOT EXISTS codex_accounts_thread_source_ai
      AFTER INSERT ON threads
      WHEN NEW.archived = 0 AND NEW.source = 'vscode' AND (NEW.thread_source IS NULL OR NEW.thread_source = '')
      BEGIN
        UPDATE threads SET thread_source = 'user' WHERE id = NEW.id;
      END;
      CREATE TRIGGER IF NOT EXISTS codex_accounts_thread_source_au
      AFTER UPDATE OF source, thread_source, archived ON threads
      WHEN NEW.archived = 0 AND NEW.source = 'vscode' AND (NEW.thread_source IS NULL OR NEW.thread_source = '')
      BEGIN
        UPDATE threads SET thread_source = 'user' WHERE id = NEW.id;
      END;
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
  local db count timestamp backup_dir

  [[ "${CODEX_PRESERVE_TOP_LEVEL_OPENAI_HTTP_PROVIDER:-0}" == "1" ]] && return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  timestamp="$(date '+%Y%m%d-%H%M%S')"

  for db in "$home_dir/state_5.sqlite" "$home_dir/sqlite/state_5.sqlite"; do
    [[ -f "$db" ]] || continue
    sqlite3 "$db" "
      PRAGMA busy_timeout = 5000;
      DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_ai;
      DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_au;
    " >/dev/null 2>&1 || true
    count="$(sqlite3 "$db" "SELECT count(*) FROM threads WHERE archived = 0 AND source = 'vscode' AND model_provider = 'openai_http';" 2>/dev/null || echo 0)"
    [[ "$count" == <-> ]] || count=0
    (( count > 0 )) || continue

    if [[ "$backup_mode" != "no-backup" ]]; then
      backup_dir="$home_dir/recovery-backups/model-provider-restore-$timestamp"
      mkdir -p "$backup_dir"
      cp -p "$db" "$backup_dir/$(basename "$db")" 2>/dev/null || true
      [[ -f "$db-wal" ]] && cp -p "$db-wal" "$backup_dir/$(basename "$db")-wal" 2>/dev/null || true
      [[ -f "$db-shm" ]] && cp -p "$db-shm" "$backup_dir/$(basename "$db")-shm" 2>/dev/null || true
    fi
    sqlite3 "$db" "UPDATE threads SET model_provider = 'openai' WHERE archived = 0 AND source = 'vscode' AND model_provider = 'openai_http';" >/dev/null 2>&1 || true
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

post_launch_thread_index_repair_for_home() {
  local home_dir="$1"
  local script_path="${0:A}"
  command -v sqlite3 >/dev/null 2>&1 || return 0
  nohup zsh -lc '
    home_dir="$1"
    script_path="$2"
    sleep 3
    for i in {1..60}; do
      for db in "$home_dir/state_5.sqlite" "$home_dir/sqlite/state_5.sqlite"; do
        [[ -f "$db" ]] || continue
        sqlite3 "$db" "
          PRAGMA busy_timeout = 5000;
          UPDATE threads SET thread_source = '\''user'\'' WHERE archived = 0 AND source = '\''vscode'\'' AND (thread_source IS NULL OR thread_source = '\'''\'');
          DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_ai;
          DROP TRIGGER IF EXISTS codex_accounts_thread_model_provider_au;
        " >/dev/null 2>&1 || true
      done
      "$script_path" prune-global-state-home "$home_dir" >/dev/null 2>&1 || true
      sleep 3
    done
  ' _ "$home_dir" "$script_path" >/dev/null 2>&1 &
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
  rm -f "$ACCOUNTS_ROOT/.deleted-$(sanitize_account_name "$name")"

  if [[ "$home_dir" == "$PRIMARY_CODEX_HOME" ]]; then
    echo "Account 1 already exists: $PRIMARY_CODEX_HOME"
    return 0
  fi

  mkdir -p "$home_dir" "$app_data"
  remove_shared_history_links_for_blank_account "$home_dir"
  rm -f "$home_dir/.codex-global-state.json" "$home_dir/.codex-global-state.json.bak"
  local history_mode="isolated"
  if [[ "$CODEX_SHARED_SESSIONS" == "1" ]]; then
    link_history_for "$name" >/dev/null
    history_mode="shared with pro history"
  fi

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

cached_usage_has_elapsed_reset() {
  local cached="$1"
  local quota="${cached%%$'\t'*}"
  local reset="${cached#*$'\t'}"
  local part label

  for part in ${(s: / :)quota}; do
    part="$(printf '%s' "$part" | trim_usage_text)"
    [[ -n "$part" ]] || continue
    label="${part%% *}"
    if cached_reset_has_elapsed "$reset" "$label"; then
      return 0
    fi
  done

  return 1
}

read_cached_usage_if_still_current() {
  local cache_file="$1"
  local max_age="$2"
  local cached

  cached="$(read_cached_usage "$cache_file" "$max_age" 2>/dev/null || true)"
  [[ -n "$cached" ]] || return 1
  cached_usage_has_elapsed_reset "$cached" && return 1
  printf '%s\n' "$cached"
}

write_cached_usage() {
  local cache_file="$1"
  local quota="$2"
  local reset="$3"
  local tmp_file

  mkdir -p "$USAGE_CACHE_ROOT"
  tmp_file="${cache_file}.$$"
  printf '%s\t%s\n' "$quota" "$reset" > "$tmp_file"
  mv "$tmp_file" "$cache_file"
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

refresh_chatgpt_tokens_for() {
  local auth_file="$1"
  local refresh_token refresh_body tmp_file tmp_auth http_status now

  [[ -f "$auth_file" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  refresh_token="$(jq -r '.tokens.refresh_token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$refresh_token" ]] || return 1

  refresh_body="$(jq -nc --arg client_id "$CHATGPT_CLIENT_ID" --arg refresh_token "$refresh_token" \
    '{client_id: $client_id, grant_type: "refresh_token", refresh_token: $refresh_token}' 2>/dev/null || true)"
  [[ -n "$refresh_body" ]] || return 1

  tmp_file="$(mktemp)"
  http_status="$(curl -sS --connect-timeout "$TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS" --max-time "$TOKEN_REFRESH_TIMEOUT_SECONDS" -o "$tmp_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "$refresh_body" \
    "$TOKEN_REFRESH_URL" 2>/dev/null || true)"

  if [[ "$http_status" != "200" ]]; then
    rm -f "$tmp_file"
    return 1
  fi

  if ! jq -e '.access_token? and (.access_token | type == "string")' "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    return 1
  fi

  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp_auth="${auth_file}.$$"
  if jq --slurpfile refreshed "$tmp_file" --arg now "$now" '
    .tokens.access_token = $refreshed[0].access_token
    | .tokens.refresh_token = ($refreshed[0].refresh_token // .tokens.refresh_token)
    | .tokens.id_token = ($refreshed[0].id_token // .tokens.id_token)
    | .tokens.account_id = ($refreshed[0].account_id // .tokens.account_id)
    | .last_refresh = $now
  ' "$auth_file" > "$tmp_auth" 2>/dev/null; then
    mv "$tmp_auth" "$auth_file"
    rm -f "$tmp_file"
    return 0
  fi

  rm -f "$tmp_file" "$tmp_auth"
  return 1
}

fetch_usage_http_status() {
  local auth_file="$1"
  local tmp_file="$2"
  local token account_id
  local -a usage_headers

  token="$(jq -r '.tokens.access_token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1
  account_id="$(jq -r '.tokens.account_id // empty' "$auth_file" 2>/dev/null || true)"

  usage_headers=(
    -H "Authorization: Bearer $token"
    -H 'Accept: application/json'
    -H 'Content-Type: application/json'
  )
  if [[ -n "$account_id" && "$account_id" != "null" ]]; then
    usage_headers+=(-H "ChatGPT-Account-Id: $account_id")
  fi

  curl -sS --connect-timeout "$USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS" --max-time "$USAGE_DIRECT_TIMEOUT_SECONDS" -o "$tmp_file" -w '%{http_code}' \
    "${usage_headers[@]}" \
    "$USAGE_API_URL" 2>/dev/null || true
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
  local quota reset_epochs reset

  quota="${raw_summary%%$'\t'*}"
  reset_epochs="${raw_summary#*$'\t'}"
  [[ -n "$quota" ]] || return 1
  if [[ "$quota" == "unlimited" ]]; then
    write_cached_usage "$cache_file" "$quota" "none"
    printf '%s\t%s\n' "$quota" "none"
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

  write_cached_usage "$cache_file" "$quota" "$reset"
  printf '%s\t%s\n' "$quota" "$reset"
}

fetch_usage_summary_via_app_server() {
  local home_dir="$1"
  local cache_file="$2"
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

  init_request='{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-accounts","title":"Codex Accounts","version":"2.4.3"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}'
  initialized_notification='{"method":"initialized"}'
  rate_request='{"method":"account/rateLimits/read","id":2}'

  app_server_env=(CODEX_HOME="$home_dir")
  if [[ "$CODEX_INJECT_PROXY_ENV" == "1" && -n "$CODEX_PROXY_URL" ]]; then
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

  coproc env "${app_server_env[@]}" "$codex_bin" app-server --listen stdio:// 2>/dev/null
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
      select(.id? == 2 and .result?.rateLimits?) |
      .result.rateLimits as $l |
      if (($l.credits.unlimited // false) == true) then
        ["unlimited", "none"]
      else
        [
          ([
            if has_usage($l.primary) then quota_label("usage"; $l.primary) + " " + left($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + left($l.secondary) else empty end
          ] | join(" / ")),
          ([
            if has_usage($l.primary) then quota_label("usage"; $l.primary) + " " + epoch($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + epoch($l.secondary) else empty end
          ] | join(" / "))
        ]
      end | @tsv
    ' 2>/dev/null || true)"
    if [[ -n "$raw_summary" ]]; then
      cleanup_app_server_process "$server_pid"
      emit_usage_summary_from_raw "$cache_file" "$raw_summary"
      return 0
    fi

    error_message="$(printf '%s\n' "$line" | jq -r 'select(.id? == 2 and .error?.message?) | .error.message' 2>/dev/null || true)"
    if [[ -n "$error_message" ]]; then
      cleanup_app_server_process "$server_pid"
      if [[ "$error_message" == *"token has been invalidated"* \
            || "$error_message" == *"401 Unauthorized"* \
            || "$error_message" == *"authentication"* \
            || "$error_message" == *"Authentication"* ]]; then
        invalidate_cached_usage "$cache_file"
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

  if read_cached_usage_if_still_current "$cache_file" "$USAGE_CACHE_SECONDS"; then
    return 0
  fi
  if [[ "$CODEX_USAGE_LIVE_LOOKUP" != "1" ]]; then
    read_cached_usage_if_still_current "$cache_file" "$USAGE_CACHE_STALE_SECONDS" 2>/dev/null || return 1
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$auth_file" ]] || return 1

  local tmp_file http_status raw_summary quota reset_epochs primary_epoch secondary_epoch

  tmp_file="$(mktemp)"
  http_status="$(fetch_usage_http_status "$auth_file" "$tmp_file")"

  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    if refresh_chatgpt_tokens_for "$auth_file"; then
      tmp_file="$(mktemp)"
      http_status="$(fetch_usage_http_status "$auth_file" "$tmp_file")"
    else
      fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
      invalidate_cached_usage "$cache_file"
      printf '%s\t%s\n' "__auth_invalid__" "unknown"
      return 0
    fi
  fi

  if [[ "$http_status" == "403" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    invalidate_cached_usage "$cache_file"
    printf '%s\t%s\n' "__auth_invalid__" "unknown"
    return 0
  fi

  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    invalidate_cached_usage "$cache_file"
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
    def primary_label($l):
      quota_label("usage"; $l.primary);
    (limits) as $l |
    if ($l.unlimited == true) then
      ["unlimited", "none"]
    else
      [
        ([
          if has_usage($l.primary) then primary_label($l) + " " + left($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + left($l.secondary) else empty end
        ] | join(" / ")),
        ([
          if has_usage($l.primary) then primary_label($l) + " " + epoch($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("usage"; $l.secondary) + " " + epoch($l.secondary) else empty end
        ] | join(" / "))
      ]
    end | @tsv
  ' "$tmp_file" 2>/dev/null || true)"
  rm -f "$tmp_file"
  [[ -n "$raw_summary" ]] || return 1

  emit_usage_summary_from_raw "$cache_file" "$raw_summary"
}

account_status_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "account-status requires an account name." >&2
    exit 2
  fi

  local home_dir auth_file auth_mode last_refresh auth_status quota reset usage_summary
  home_dir="$(account_home_for "$name")"
  auth_file="$home_dir/auth.json"
  auth_mode="unknown"
  last_refresh="never"
  auth_status="login_needed"
  quota="unknown"
  reset="unknown"

  if [[ -f "$auth_file" ]]; then
    auth_mode="$(jq -r '.auth_mode // "unknown"' "$auth_file" 2>/dev/null || echo "unknown")"
    last_refresh="$(jq -r '.last_refresh // "unknown"' "$auth_file" 2>/dev/null || echo "unknown")"
    if jq -e '.tokens.access_token? and .tokens.refresh_token?' "$auth_file" >/dev/null 2>&1; then
      auth_status="signed_in_local"
      usage_summary="$(fetch_usage_summary_for "$name" "$home_dir" 2>/dev/null || true)"
      if [[ -n "$usage_summary" ]]; then
        quota="${usage_summary%%$'\t'*}"
        reset="${usage_summary#*$'\t'}"
        if [[ "$quota" == "__auth_invalid__" ]]; then
          # The app-server confirmed Codex itself cannot use this token.
          # Treat it as an expired login instead of showing stale quota.
          auth_status="auth_invalid"
          quota="unknown"
          reset="unknown"
        fi
      fi
    else
      auth_status="auth_incomplete"
    fi
  fi

  echo "$(sanitize_account_name "$name") | $auth_status | $auth_mode | $last_refresh | $quota | $reset"
}

list_accounts_status() {
  local tmp_dir index name status_parallelism
  local -a pids
  tmp_dir="$(mktemp -d)"
  index=0
  status_parallelism="${STATUS_PARALLELISM:-2}"
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
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local home_dir
  for item in "${SYNC_ITEMS[@]}"; do
    for home_dir in "${homes[@]}"; do
      rsync_item_to_shared "$home_dir" "$item"
    done
    for home_dir in "${homes[@]}"; do
      rsync_item_from_shared "$home_dir" "$item"
    done
  done
  if [[ "$CODEX_SYNC_PLUGIN_CONFIG" == "1" ]]; then
    sync_plugin_config_entries "${homes[@]}"
  fi
  sync_global_state_for_homes "${homes[@]}"
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
      rsync_item_to_shared "$home_dir" "$item"
    done
    for home_dir in "${dest_homes[@]}"; do
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

  CODEX_GLOBAL_STATE_HOMES="$homes_payload" CODEX_GLOBAL_STATE_DEST_HOMES="$dest_payload" python3 - <<'PY'
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
    if str(home) not in dest_home_keys:
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
    for key in ("title", "preview"):
        value = str(row.get(key) or "").strip()
        if not value:
            continue
        for line in value.splitlines():
            name = " ".join(line.split())
            if name:
                if len(name) > 80:
                    return name[:77].rstrip() + "..."
                return name
    return "Untitled"

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
                            if not existing_name or (len(existing_name) > 80 and len(fresh["thread_name"]) < len(existing_name)):
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
                    if existing is None:
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
    prune_global_state_for_home "$home_dir" >/dev/null 2>&1 || true
  done
}

sync_selected_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  sync_memory_and_config_for_homes "${homes[@]}"
  sync_plugin_payloads_for_homes "${homes[@]}"
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    sync_thread_index_for_homes "${homes[@]}"
    sync_global_state_for_homes "${homes[@]}"
    sync_goal_state_for_homes "${homes[@]}"
  fi
  cleanup_thread_indexes_for_homes "${homes[@]}"
  sync_message
}

sync_history_selected_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  local home_dir
  local previous_skip_active
  previous_skip_active="$CODEX_SKIP_ACTIVE_STATE_DB_WRITES"
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES=0
  for home_dir in "${homes[@]}"; do
    seed_shared_history_from_home "$home_dir"
  done
  CODEX_SYNC_THREAD_HISTORY=1
  sync_thread_index_for_homes "${homes[@]}"
  sync_global_state_for_homes "${homes[@]}"
  sync_goal_state_for_homes "${homes[@]}"
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES="$previous_skip_active"
  cleanup_thread_indexes_for_homes "${homes[@]}"
  echo "Synced shared Codex history at $(date '+%Y-%m-%d %H:%M:%S')."
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

  local home_dir
  local -a homes
  homes=()
  while read -r home_dir; do
    [[ -n "$home_dir" ]] || continue
    homes+=("$home_dir")
  done < <(collect_account_homes)
  homes+=("$CODEX_HISTORY_ANCHOR_HOME" "$target_home")
  homes=("${(@f)$(dedupe_homes "${homes[@]}")}")

  seed_shared_history_from_home "$CODEX_HISTORY_ANCHOR_HOME"
  seed_shared_history_from_home "$target_home"
  local previous_skip_active
  previous_skip_active="$CODEX_SKIP_ACTIVE_STATE_DB_WRITES"
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES=0
  sync_thread_index_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  sync_global_state_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  sync_goal_state_to_selected_homes 1 "$target_home" "${homes[@]}" >/dev/null 2>&1 || true
  CODEX_SKIP_ACTIVE_STATE_DB_WRITES="$previous_skip_active"
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
  local -a all_homes payload_homes
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
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    sync_thread_index_for_homes "${all_homes[@]}"
    sync_global_state_for_homes "${all_homes[@]}"
    sync_goal_state_for_homes "${all_homes[@]}"
  fi
  cleanup_thread_indexes_for_homes "${all_homes[@]}"
  sync_message
}

sync_account_prelaunch_unlocked() {
  local name="$1"
  local target_home home_dir
  local -a all_homes dest_homes payload_homes
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
  if [[ "$CODEX_SYNC_THREAD_HISTORY" == "1" ]]; then
    sync_debug "prelaunch global-state account=$name"
    sync_global_state_to_selected_homes "${#dest_homes[@]}" "${dest_homes[@]}" "${all_homes[@]}"
    sync_debug "prelaunch thread-index account=$name"
    sync_thread_index_to_selected_homes "${#dest_homes[@]}" "${dest_homes[@]}" "${all_homes[@]}"
    sync_debug "prelaunch global-state-prune account=$name"
    sync_global_state_to_selected_homes "${#dest_homes[@]}" "${dest_homes[@]}" "${all_homes[@]}"
    sync_debug "prelaunch goal-state account=$name"
    sync_goal_state_to_selected_homes "${#dest_homes[@]}" "${dest_homes[@]}" "${all_homes[@]}"
  fi
  sync_debug "prelaunch thread-index-cleanup account=$name"
  cleanup_thread_indexes_for_homes "${dest_homes[@]}"
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

stop_codex_windows_for_app_data() {
  local app_data="$1"
  local pids=()
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    [[ "$args" == "$CODEX_APP/Contents/MacOS/Codex"* ]] || continue
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
      [[ "$args" == "$CODEX_APP/Contents/MacOS/Codex"* ]] || continue
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

  if [[ ! -d "$CODEX_APP" ]]; then
    echo "Codex app not found at: $CODEX_APP" >&2
    exit 1
  fi

  local home_dir app_data
  local -a launch_env
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"
  mkdir -p "$home_dir" "$app_data"

  if [[ "$CODEX_CLONE_PRIMARY_ON_LAUNCH" == "1" && "$home_dir" != "$PRIMARY_CODEX_HOME" && ! -e "$home_dir/config.toml" ]]; then
    copy_initial_profile_to "$home_dir"
  fi
  stop_codex_windows_for_app_data "$app_data" >/dev/null 2>&1 || true
  stop_codex_servers_for_home "$home_dir" >/dev/null 2>&1 || true
  if [[ "$CODEX_PRELAUNCH_SYNC" == "1" ]]; then
    if ! sync_account_for_launch "$name" >/dev/null; then
      echo "Prelaunch sync did not finish; not launching Codex profile to avoid SQLite startup conflicts." >&2
      exit 1
    fi
  fi
  prepare_profile_login_storage "$home_dir"
  refresh_shared_history_for_home "$home_dir"
  if [[ "$CODEX_DELETE_STALE_THREAD_ROWS" == "1" ]]; then
    cleanup_thread_index_for_home "$home_dir" >/dev/null 2>&1 || true
  fi
  prune_global_state_for_home "$home_dir" >/dev/null 2>&1 || true
  normalize_top_level_model_provider_for_home "$home_dir"
  normalize_thread_sources_for_home "$home_dir"
  restore_default_thread_model_providers_for_home "$home_dir"

  echo "Launching Codex profile..."
  echo "  account=$(sanitize_account_name "$name")"
  echo "  app=$CODEX_APP"
  echo "  CODEX_HOME=$home_dir"
  echo "  user-data-dir=$app_data"
  if [[ "$CODEX_INJECT_PROXY_ENV" == "1" && -n "$CODEX_PROXY_URL" ]]; then
    echo "  proxy=$CODEX_PROXY_URL"
  fi

  stop_codex_windows_for_app_data "$app_data"
  stop_codex_servers_for_home "$home_dir"
  ensure_owl_auth_features_enabled "$app_data"

  # Keep the account env scoped to this launch. `launchctl setenv` is global
  # and can make later Codex windows inherit the wrong CODEX_HOME.
  launchctl unsetenv CODEX_HOME >/dev/null 2>&1 || true
  load_dashscope_api_key
  launch_env=(--env "CODEX_HOME=$home_dir")
  if [[ -n "${DASHSCOPE_API_KEY:-}" ]]; then
    launch_env+=(--env "DASHSCOPE_API_KEY=$DASHSCOPE_API_KEY")
  fi
  if [[ "$CODEX_INJECT_PROXY_ENV" == "1" && -n "$CODEX_PROXY_URL" ]]; then
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
  open -na "$CODEX_APP" \
    "${launch_env[@]}" \
    --args --user-data-dir="$app_data"
  post_launch_thread_index_repair_for_home "$home_dir"

  echo "Started Codex profile."
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

link_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "link-history requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  CODEX_SHARED_SESSIONS=1
  local account_home
  account_home="$(account_home_for "$name")"

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
}

unlink_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "unlink-history requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"

  { history_items; state_items; } | while read -r item; do
    local target="$account_home/$item"
    if [[ -L "$target" ]]; then
      rm "$target"
      echo "Removed symlink: $target"
    fi
  done

  echo "$(sanitize_account_name "$name") history links removed. Previous files, if any, are under:"
  echo "  $account_home/backups/"
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
        live_rows[thread_id] = max(live, key=marker)
        continue
    delete_ids.add(thread_id)
    for row in rows:
        rollout_path = text(row, "rollout_path")
        if rollout_path:
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
    for key in ("title", "preview"):
        value = text(row, key)
        if not value:
            continue
        for line in value.splitlines():
            name = " ".join(line.split())
            if name:
                return name[:77].rstrip() + "..." if len(name) > 80 else name
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

cleanup_empty_projects() {
  list_accounts | while IFS='|' read -r raw_name raw_home _; do
    local name home
    name="$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    home="$(printf '%s' "$raw_home" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$name" && -n "$home" ]] || continue
    if [[ "$CODEX_DELETE_STALE_THREAD_ROWS" == "1" ]]; then
      cleanup_thread_index_for_home "$home"
    fi
    prune_global_state_for_home "$home" >/dev/null 2>&1 || true
  done
}

prune_global_state_loop() {
  while true; do
    cleanup_empty_projects >/dev/null 2>&1 || true
    sleep "$CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS"
  done
}

separate_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "separate-history requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"
  detach_shared_sessions_link "$account_home"
  cleanup_thread_index_for_home "$account_home"
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
  CODEX_SHARED_SESSIONS=1
  collect_account_homes | while read -r home_dir; do
    [[ -n "$home_dir" ]] || continue
    seed_shared_history_from_home "$home_dir"
  done
  list_accounts | cut -d '|' -f 1 | sed 's/[[:space:]]//g' | while read -r name; do
    link_history_for "$name"
  done
}

link_account2_history() {
  link_history_for "account2"
}

unlink_account2_history() {
  unlink_history_for "account2"
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
    sync-loop) sync_loop ;;
    sync-history-loop) sync_history_loop ;;
    init-account) init_account "${2:-}" ;;
    init-shared-account) init_shared_account "${2:-}" ;;
    launch-account) launch_account "${2:-}" "${3:-}" ;;
    launch-account-nosync) CODEX_PRELAUNCH_SYNC=0 launch_account "${2:-}" "${3:-}" ;;
    close-account) close_account "${2:-}" ;;
    close-all-accounts) close_all_accounts ;;
    list-accounts) list_accounts ;;
    account-status) account_status_for "${2:-}" ;;
    list-accounts-status) list_accounts_status ;;
    delete-account) delete_account "${2:-}" ;;
    link-history) link_history_for "${2:-}" ;;
    unlink-history) unlink_history_for "${2:-}" ;;
    separate-history) separate_history_for "${2:-}" ;;
    separate-all-history) separate_all_history ;;
    cleanup-empty-projects) cleanup_empty_projects ;;
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
