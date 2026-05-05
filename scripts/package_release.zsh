#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Codex Accounts.app"
ZIP_PATH="$DIST_DIR/Codex-Accounts-macOS.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/build_codex_accounts_app.zsh"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Release package:"
echo "  $ZIP_PATH"

