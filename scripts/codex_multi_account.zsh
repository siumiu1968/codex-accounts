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
USAGE_CACHE_SECONDS="${USAGE_CACHE_SECONDS:-20}"
USAGE_CACHE_ROOT="${USAGE_CACHE_ROOT:-$APP_DATA_ROOT/.usage-cache-v5}"

SYNC_ITEMS=(
  "AGENTS.md"
  "memories"
  "rules"
)

usage() {
  cat <<'USAGE'
Usage:
  scripts/codex_multi_account.zsh init
  scripts/codex_multi_account.zsh launch-account2
  scripts/codex_multi_account.zsh sync-once
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
  - This syncs local memory files only: AGENTS.md, memories/, rules/.
  - link-account2-history is experimental: it makes Account 2 use Account 1's
    local Codex history files through symlinks, while keeping auth/cookies
    separate. Quit the second Codex profile before running it.
  - It does not sync cloud conversation history, ChatGPT account memory,
    auth.json, or cookies.
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

fetch_usage_summary_for() {
  local name="$1"
  local home_dir="$2"
  local auth_file="$home_dir/auth.json"
  local cache_file
  cache_file="$(usage_cache_file_for "$name")"

  if read_cached_usage "$cache_file"; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$auth_file" ]] || return 1

  local token tmp_file http_status raw_summary quota reset_epochs primary_epoch secondary_epoch
  token="$(jq -r '.tokens.access_token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1

  tmp_file="$(mktemp)"
  http_status="$(curl -sS --connect-timeout 2 --max-time 5 -o "$tmp_file" -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    "$USAGE_API_URL" 2>/dev/null || true)"

  if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
    rm -f "$tmp_file"
    # Codex may still be locally signed in even when the usage endpoint rejects
    # one request. Prefer the last known usage value so 0% accounts stay visible.
    read_cached_usage "$cache_file" 86400 2>/dev/null && return 0
    printf '%s\t%s\n' "__auth_invalid__" "unknown"
    return 0
  fi

  if [[ "$http_status" != "200" ]]; then
    rm -f "$tmp_file"
    # Keep a short stale fallback when the network/API is temporarily unavailable.
    read_cached_usage "$cache_file" 600 2>/dev/null || return 1
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
  local tmp_dir index name
  tmp_dir="$(mktemp -d)"
  index=0

  while read -r name; do
    [[ -n "$name" ]] || continue
    index=$((index + 1))
    (
      account_status_for "$name" > "$tmp_dir/$index.status" 2>/dev/null || true
    ) &
  done < <(list_accounts | cut -d '|' -f 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  wait
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

sync_once() {
  require_rsync
  ensure_dirs

  local homes=()
  local home_dir
  while IFS='|' read -r _ raw_home _; do
    home_dir="$(echo "$raw_home" | xargs)"
    [[ -n "$home_dir" ]] || continue
    homes+=("$home_dir")
  done < <(list_accounts)

  for item in "${SYNC_ITEMS[@]}"; do
    for home_dir in "${homes[@]}"; do
      rsync_item_to_shared "$home_dir" "$item"
    done
    for home_dir in "${homes[@]}"; do
      rsync_item_from_shared "$home_dir" "$item"
    done
  done

  echo "Synced local Codex memory files at $(date '+%Y-%m-%d %H:%M:%S')."
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

stop_codex_windows_for_app_data() {
  local app_data="$1"
  local pids=()
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    [[ "$args" == *"$CODEX_APP/Contents/MacOS/Codex"* ]] || continue
    [[ "$args" == *"--user-data-dir=$app_data"* ]] || continue
    pids+=("$pid")
  done < <(ps axww -o pid= -o args=)

  if (( ${#pids[@]} == 0 )); then
    return 0
  fi

  echo "Closing existing Codex window(s) for this profile: ${pids[*]}"
  kill -TERM "${pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  for pid in "${pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

process_env_contains() {
  local pid="$1"
  local needle="$2"
  ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -Fq "$needle"
}

stop_codex_servers_for_home() {
  local home_dir="$1"
  local pids=()
  local pid args

  while read -r pid args; do
    [[ -n "${pid:-}" && -n "${args:-}" ]] || continue
    [[ "$args" == *"codex app-server"* ]] || continue
    if [[ "$args" == *"--codex-home $home_dir"* || "$args" == *"--codex-home=$home_dir"* ]] || process_env_contains "$pid" "CODEX_HOME=$home_dir"; then
      pids+=("$pid")
    fi
  done < <(ps axww -o pid= -o args=)

  if (( ${#pids[@]} == 0 )); then
    return 0
  fi

  echo "Closing stale Codex app-server(s) for this profile: ${pids[*]}"
  kill -TERM "${pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  for pid in "${pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
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
  list_accounts | while IFS='|' read -r raw_name _; do
    local name
    name="$(echo "$raw_name" | xargs)"
    [[ -n "$name" ]] || continue

    local home_dir app_data
    home_dir="$(account_home_for "$name")"
    app_data="$(account_app_data_for "$name")"
    stop_codex_windows_for_app_data "$app_data"
    stop_codex_servers_for_home "$home_dir"
  done

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
