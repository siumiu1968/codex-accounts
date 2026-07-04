#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/Codex Accounts.app}"
SRC_DIR="$ROOT_DIR/macos/CodexAccounts"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-14.0}"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

cp "$SRC_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/scripts/codex_multi_account.zsh" "$RESOURCES/codex_multi_account.zsh"
chmod +x "$RESOURCES/codex_multi_account.zsh"

find "$RESOURCES" -maxdepth 1 \( -name 'codex_remote_bridge.py*' -o -name 'start_mac_bridge.zsh*' -o -name '__pycache__' \) -exec rm -rf {} +

cp "$ROOT_DIR/scripts/codex_share_package.py" "$RESOURCES/codex_share_package.py"
chmod +x "$RESOURCES/codex_share_package.py"

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
  -target "$BUILD_ARCH-apple-macos$MACOS_DEPLOYMENT_TARGET" \
  "$SRC_DIR/Sources/CodexAccounts.swift" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  -framework SwiftUI \
  -o "$MACOS/Codex Accounts"

chmod +x "$MACOS/Codex Accounts"

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
  if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/"Apple Development:|Developer ID Application:|Mac Developer:/{ print $2; exit }')"
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null
  else
    codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
  fi
fi

echo "Built $APP_PATH"
