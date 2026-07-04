#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/Codex Quota Pool.app}"
SRC_DIR="$ROOT_DIR/macos/CodexQuotaPool"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

cp "$SRC_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/scripts/codex_multi_account.zsh" "$RESOURCES/codex_multi_account.zsh"
chmod +x "$RESOURCES/codex_multi_account.zsh"

find "$RESOURCES" -maxdepth 1 \( -name 'codex_remote_bridge.py*' -o -name 'start_mac_bridge.zsh*' -o -name '__pycache__' \) -exec rm -rf {} +

if [[ -f "$SRC_DIR/AppIcon.icns" ]]; then
  cp "$SRC_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

if [[ -f "$ROOT_DIR/scripts/make_profile_letter_icons.swift" ]]; then
  swift "$ROOT_DIR/scripts/make_profile_letter_icons.swift" "$SRC_DIR/ProfileLetterIcons"
fi

if [[ -d "$SRC_DIR/ProfileLetterIcons" ]]; then
  rm -rf "$RESOURCES/ProfileLetterIcons"
  cp -R "$SRC_DIR/ProfileLetterIcons" "$RESOURCES/ProfileLetterIcons"
fi

swiftc \
  "$SRC_DIR/Sources/CodexAccounts.swift" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  -framework SwiftUI \
  -o "$MACOS/Codex Quota Pool"

chmod +x "$MACOS/Codex Quota Pool"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Built $APP_PATH"
