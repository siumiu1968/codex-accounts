#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${CODEX_ACCOUNTS_SCRIPT:-$ROOT_DIR/codex_multi_account.zsh}"
BRIDGE_PATH="${CODEX_REMOTE_BRIDGE:-$ROOT_DIR/codex_remote_bridge.py}"
APP_SUPPORT="$HOME/Library/Application Support/Codex Accounts"
PID_FILE="${CODEX_REMOTE_PID_FILE:-$APP_SUPPORT/remote-bridge.pid}"

mkdir -p "$APP_SUPPORT"

exec /usr/bin/python3 "$BRIDGE_PATH" \
  --script "$SCRIPT_PATH" \
  --port "${CODEX_REMOTE_PORT:-47621}" \
  --pid-file "$PID_FILE"
