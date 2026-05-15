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
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-20}"
USAGE_API_URL="${USAGE_API_URL:-https://chatgpt.com/backend-api/wham/usage}"
TOKEN_REFRESH_URL="${TOKEN_REFRESH_URL:-https://auth.openai.com/oauth/token}"
CHATGPT_CLIENT_ID="${CHATGPT_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
USAGE_CACHE_SECONDS="${USAGE_CACHE_SECONDS:-20}"
USAGE_CACHE_ROOT="${USAGE_CACHE_ROOT:-$APP_DATA_ROOT/.usage-cache-v5}"
USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS="${USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS:-1}"
USAGE_DIRECT_TIMEOUT_SECONDS="${USAGE_DIRECT_TIMEOUT_SECONDS:-3}"
TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS="${TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS:-3}"
TOKEN_REFRESH_TIMEOUT_SECONDS="${TOKEN_REFRESH_TIMEOUT_SECONDS:-6}"
APP_SERVER_USAGE_TIMEOUT_SECONDS="${APP_SERVER_USAGE_TIMEOUT_SECONDS:-4}"
CODEX_SYNC_PLUGIN_PAYLOADS="${CODEX_SYNC_PLUGIN_PAYLOADS:-0}"
CODEX_FAST_SYNC_PLUGIN_PAYLOADS="${CODEX_FAST_SYNC_PLUGIN_PAYLOADS:-1}"
CODEX_PRELAUNCH_SYNC="${CODEX_PRELAUNCH_SYNC:-1}"
CODEX_USAGE_LIVE_LOOKUP="${CODEX_USAGE_LIVE_LOOKUP:-0}"
USAGE_CACHE_STALE_SECONDS="${USAGE_CACHE_STALE_SECONDS:-86400}"
SYNC_LOCK_DIR="${SYNC_LOCK_DIR:-$APP_DATA_ROOT/.sync.lock}"

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
  scripts/codex_multi_account.zsh sync-account <account-name>
  scripts/codex_multi_account.zsh sync-loop
  scripts/codex_multi_account.zsh init-account <account-name>
  scripts/codex_multi_account.zsh launch-account <account-name> [display-name]
  scripts/codex_multi_account.zsh close-account <account-name>
  scripts/codex_multi_account.zsh close-all-accounts
  scripts/codex_multi_account.zsh list-accounts
  scripts/codex_multi_account.zsh account-status <account-name>
  scripts/codex_multi_account.zsh list-accounts-status
  scripts/codex_multi_account.zsh delete-account <account-name>
  scripts/codex_multi_account.zsh link-history <account-name>
  scripts/codex_multi_account.zsh unlink-history <account-name>
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

Notes:
  - Login separately inside the second Codex window.
  - This syncs local shared state: AGENTS.md, memories/, rules/,
    enabled plugin config entries, skills/, vendor_imports/, and current
    plugin payloads. It skips plugin backup/install folders so pre-open
    sync stays fast. Set CODEX_SYNC_PLUGIN_PAYLOADS=1 to copy every
    plugins/, skills/, and vendor_imports/ payload.
  - Plugin enablement is merged across accounts from config.toml
    [plugins."..."] sections without copying the full config file.
  - link-account2-history is experimental: it makes Account 2 use Account 1's
    local Codex history files through symlinks, while keeping auth/cookies
    separate. Quit the second Codex profile before running it.
  - It does not sync cloud conversation history, ChatGPT account memory,
    auth.json, cookies, SQLite logs, or per-account app state.
  - Usage status is fetched per profile from Codex's authenticated usage
    endpoint. Tokens are only read for the request and are not cached.
USAGE
}

require_rsync() {
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required but was not found." >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$PRIMARY_CODEX_HOME" "$SECOND_CODEX_HOME" "$SECOND_APP_DATA" "$ACCOUNTS_ROOT" "$APP_DATA_ROOT" "$SHARED_MEMORY_DIR" "$USAGE_CACHE_ROOT"
}

with_sync_lock() {
  local waited=0
  while ! mkdir "$SYNC_LOCK_DIR" 2>/dev/null; do
    local lock_mtime now lock_age
    lock_mtime="$(stat -f '%m' "$SYNC_LOCK_DIR" 2>/dev/null || echo 0)"
    now="$(date '+%s')"
    lock_age=$(( now - lock_mtime ))
    if (( lock_age > 60 )); then
      rmdir "$SYNC_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if (( waited >= 20 )); then
      echo "Sync is already running; continuing with existing synced state." >&2
      return 0
    fi
    sleep 0.25
    waited=$(( waited + 1 ))
  done
  trap 'rmdir "$SYNC_LOCK_DIR" 2>/dev/null || true' EXIT
  "$@"
  local command_status=$?
  rmdir "$SYNC_LOCK_DIR" 2>/dev/null || true
  trap - EXIT
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

  copy_initial_profile_to "$home_dir"
  mkdir -p "$app_data"
  link_history_for "$name" >/dev/null

  echo "Initialized account:"
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
  local init_request initialized_notification rate_request line raw_summary server_pid

  [[ -x "$codex_bin" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  init_request='{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-accounts","title":"Codex Accounts","version":"2.3.5"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}'
  initialized_notification='{"method":"initialized"}'
  rate_request='{"method":"account/rateLimits/read","id":2}'

  coproc env CODEX_HOME="$home_dir" "$codex_bin" app-server --listen stdio:// 2>/dev/null
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
      def quota_label($fallback; $w):
        if ($w.windowDurationMins == 300) then "5h"
        elif ($w.windowDurationMins == 10080) then "7d"
        else $fallback
        end;
      select(.id? == 2 and .result?.rateLimits?) |
      .result.rateLimits as $l |
      if (($l.credits.unlimited // false) == true) then
        ["unlimited", "none"]
      else
        [
          ([
            if has_usage($l.primary) then quota_label("5h"; $l.primary) + " " + left($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("7d"; $l.secondary) + " " + left($l.secondary) else empty end
          ] | join(" / ")),
          ([
            if has_usage($l.primary) then quota_label("5h"; $l.primary) + " " + epoch($l.primary) else empty end,
            if has_usage($l.secondary) then quota_label("7d"; $l.secondary) + " " + epoch($l.secondary) else empty end
          ] | join(" / "))
        ]
      end | @tsv
    ' 2>/dev/null || true)"
    if [[ -n "$raw_summary" ]]; then
      kill "$server_pid" 2>/dev/null || true
      wait "$server_pid" 2>/dev/null || true
      emit_usage_summary_from_raw "$cache_file" "$raw_summary"
      return 0
    fi
  done

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
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
      read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null && return 0
      printf '%s\t%s\n' "__auth_invalid__" "unknown"
      return 0
    fi
  fi

  if [[ "$http_status" == "403" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null && return 0
    printf '%s\t%s\n' "__auth_invalid__" "unknown"
    return 0
  fi

  if [[ "$http_status" == "401" ]]; then
    rm -f "$tmp_file"
    fetch_usage_summary_via_app_server "$home_dir" "$cache_file" 2>/dev/null && return 0
    read_cached_usage_if_still_current "$cache_file" 600 2>/dev/null && return 0
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
    def quota_label($fallback; $w):
      if ($w.window_minutes == 300) then "5h"
      elif ($w.window_minutes == 10080) then "7d"
      else $fallback
      end;
    def primary_label($l):
      if has_usage($l.secondary) then quota_label("5h"; $l.primary)
      else "7d"
      end;
    (limits) as $l |
    if ($l.unlimited == true) then
      ["unlimited", "none"]
    else
      [
        ([
          if has_usage($l.primary) then primary_label($l) + " " + left($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("7d"; $l.secondary) + " " + left($l.secondary) else empty end
        ] | join(" / ")),
        ([
          if has_usage($l.primary) then primary_label($l) + " " + epoch($l.primary) else empty end,
          if has_usage($l.secondary) then quota_label("7d"; $l.secondary) + " " + epoch($l.secondary) else empty end
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
          # A usage endpoint auth failure only proves the usage request failed.
          # Codex can still refresh/use the local login when auth.json contains
          # both tokens, so do not mark the profile as logged out here.
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
  status_parallelism="${STATUS_PARALLELISM:-8}"
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
    rsync -a --update "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    rsync -a --update "$src" "$dst"
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
    rsync -a --update "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    rsync -a --update "$src" "$dst"
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
    rsync -a --update \
      --exclude '.DS_Store' \
      --exclude 'plugin-install-*' \
      --exclude 'plugin-backup-*' \
      "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    rsync -a --update "$src" "$dst"
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
    rsync -a --update \
      --exclude '.DS_Store' \
      --exclude 'plugin-install-*' \
      --exclude 'plugin-backup-*' \
      "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    rsync -a --update "$src" "$dst"
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
  sync_plugin_config_entries "${homes[@]}"
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

sync_message() {
  if [[ "$CODEX_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    echo "Synced local Codex memory, plugin payloads, skills, and config at $(date '+%Y-%m-%d %H:%M:%S')."
  elif [[ "$CODEX_FAST_SYNC_PLUGIN_PAYLOADS" == "1" ]]; then
    echo "Synced local Codex memory, current plugin payloads, skills, and config at $(date '+%Y-%m-%d %H:%M:%S')."
  else
    echo "Synced local Codex memory and plugin config at $(date '+%Y-%m-%d %H:%M:%S')."
  fi
}

sync_selected_homes() {
  local -a homes
  homes=("$@")
  (( ${#homes[@]} > 0 )) || return 0

  sync_memory_and_config_for_homes "${homes[@]}"
  sync_plugin_payloads_for_homes "${homes[@]}"
  sync_message
}

collect_account_homes() {
  local home_dir raw_home
  while IFS='|' read -r _ raw_home _; do
    home_dir="$(echo "$raw_home" | xargs)"
    [[ -n "$home_dir" ]] || continue
    printf '%s\n' "$home_dir"
  done < <(list_accounts)
}

sync_once() {
  require_rsync
  ensure_dirs

  local homes=()
  local home_dir
  while read -r home_dir; do
    homes+=("$home_dir")
  done < <(collect_account_homes)

  with_sync_lock sync_selected_homes "${homes[@]}"
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
  home_dir="$(account_home_for "$name")"
  app_data="$(account_app_data_for "$name")"
  mkdir -p "$home_dir" "$app_data"

  if [[ "$home_dir" != "$PRIMARY_CODEX_HOME" && ! -e "$home_dir/config.toml" ]]; then
    copy_initial_profile_to "$home_dir"
  fi
  if [[ "$CODEX_PRELAUNCH_SYNC" == "1" ]]; then
    sync_account "$name" >/dev/null
  fi

  echo "Launching Codex profile..."
  echo "  account=$(sanitize_account_name "$name")"
  echo "  app=$CODEX_APP"
  echo "  CODEX_HOME=$home_dir"
  echo "  user-data-dir=$app_data"

  stop_codex_windows_for_app_data "$app_data"
  stop_codex_servers_for_home "$home_dir"

  # Keep the account env scoped to this launch. `launchctl setenv` is global
  # and can make later Codex windows inherit the wrong CODEX_HOME.
  launchctl unsetenv CODEX_HOME >/dev/null 2>&1 || true
  open -na "$CODEX_APP" \
    --env "CODEX_HOME=$home_dir" \
    --args --user-data-dir="$app_data"

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
  local source="$PRIMARY_CODEX_HOME/$item"
  local target="$account_home/$item"

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

history_items() {
  printf '%s\n' \
    "logs_2.sqlite" \
    "logs_2.sqlite-shm" \
    "logs_2.sqlite-wal" \
    "state_5.sqlite" \
    "state_5.sqlite-shm" \
    "state_5.sqlite-wal" \
    "session_index.jsonl" \
    "sessions" \
    "shell_snapshots"
}

link_history_for() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "link-history requires an account name." >&2
    exit 2
  fi

  ensure_dirs
  local account_home
  account_home="$(account_home_for "$name")"

  if [[ "$account_home" == "$PRIMARY_CODEX_HOME" ]]; then
    echo "account1 already owns the shared history."
    return 0
  fi

  mkdir -p "$account_home"
  echo "Linking $(sanitize_account_name "$name") to Account 1 local Codex history."
  echo "Keep auth separate:"
  echo "  Account 1: $PRIMARY_CODEX_HOME/auth.json"
  echo "  $(sanitize_account_name "$name"): $account_home/auth.json"
  echo

  history_items | while read -r item; do
    replace_with_symlink "$account_home" "$item"
  done
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

  history_items | while read -r item; do
    local target="$account_home/$item"
    if [[ -L "$target" ]]; then
      rm "$target"
      echo "Removed symlink: $target"
    fi
  done

  echo "$(sanitize_account_name "$name") history links removed. Previous files, if any, are under:"
  echo "  $account_home/backups/"
}

link_all_history() {
  list_accounts | cut -d '|' -f 1 | sed 's/[[:space:]]//g' | while read -r name; do
    [[ "$name" == "account1" ]] && continue
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
    sync-account) sync_account "${2:-}" ;;
    sync-loop) sync_loop ;;
    init-account) init_account "${2:-}" ;;
    launch-account) launch_account "${2:-}" "${3:-}" ;;
    close-account) close_account "${2:-}" ;;
    close-all-accounts) close_all_accounts ;;
    list-accounts) list_accounts ;;
    account-status) account_status_for "${2:-}" ;;
    list-accounts-status) list_accounts_status ;;
    delete-account) delete_account "${2:-}" ;;
    link-history) link_history_for "${2:-}" ;;
    unlink-history) unlink_history_for "${2:-}" ;;
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
