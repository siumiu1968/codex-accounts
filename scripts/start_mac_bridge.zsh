#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${CODEX_ACCOUNTS_SCRIPT:-$ROOT_DIR/codex_multi_account.zsh}"
BRIDGE_PATH="${CODEX_REMOTE_BRIDGE:-$ROOT_DIR/codex_remote_bridge.py}"
APP_SUPPORT="$HOME/Library/Application Support/Codex Accounts"
PID_FILE="${CODEX_REMOTE_PID_FILE:-$APP_SUPPORT/remote-bridge.pid}"
HOST="${CODEX_REMOTE_HOST:-0.0.0.0}"
PORT="${CODEX_REMOTE_PORT:-47621}"

mkdir -p "$APP_SUPPORT"

if [[ "${CODEX_REMOTE_RESTART:-0}" == "1" ]]; then
  pids=()
  if [[ -f "$PID_FILE" ]]; then
    pid="$(tr -dc '0-9' < "$PID_FILE" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      pids+=("$pid")
    fi
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(/usr/sbin/lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)

  seen=" "
  for pid in "${pids[@]}"; do
    [[ "$seen" == *" $pid "* ]] && continue
    seen+=" $pid "
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.25
  for pid in "${pids[@]}"; do
    kill -0 "$pid" 2>/dev/null || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
fi

exec /usr/bin/python3 "$BRIDGE_PATH" \
  --script "$SCRIPT_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  --pid-file "$PID_FILE"
