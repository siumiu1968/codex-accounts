#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Codex Accounts.app"
ZIP_PATH="$DIST_DIR/Codex-Accounts-macOS.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/build_codex_accounts_app.zsh"

# Keep the downloadable archive free of Finder resource-fork sidecars such as
# __MACOSX/._*. The app's real CodeResources signature remains inside the bundle.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Release package:"
echo "  $ZIP_PATH"
