#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/Codex Accounts.app}"
SRC_DIR="$ROOT_DIR/macos/CodexAccounts"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

cp "$SRC_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/scripts/codex_multi_account.zsh" "$RESOURCES/codex_multi_account.zsh"
chmod +x "$RESOURCES/codex_multi_account.zsh"

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
  -framework SwiftUI \
  -o "$MACOS/Codex Accounts"

chmod +x "$MACOS/Codex Accounts"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Built $APP_PATH"
