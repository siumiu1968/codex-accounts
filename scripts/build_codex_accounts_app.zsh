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
cp "$ROOT_DIR/scripts/sync_paginated_history.py" "$RESOURCES/sync_paginated_history.py"
cp "$ROOT_DIR/scripts/storage_review_layout.py" "$RESOURCES/storage_review_layout.py"

find "$RESOURCES" -maxdepth 1 \( -name 'codex_remote_bridge.py*' -o -name 'start_mac_bridge.zsh*' -o -name '__pycache__' \) -exec rm -rf {} +

cp "$ROOT_DIR/scripts/codex_share_package.py" "$RESOURCES/codex_share_package.py"
chmod +x "$RESOURCES/codex_share_package.py"

cp "$ROOT_DIR/scripts/auto_prune_child_tasks.py" "$RESOURCES/auto_prune_child_tasks.py"
chmod +x "$RESOURCES/auto_prune_child_tasks.py"

# OpenCodex mode was removed in 3.3.1: its runtime is no longer bundled, and an older copy is cleared.
rm -rf "$RESOURCES/opencodex-runtime" "$RESOURCES/opencodex_runtime_seed.py"

if [[ -f "$SRC_DIR/AccountsLogo.png" ]]; then
  cp "$SRC_DIR/AccountsLogo.png" "$RESOURCES/AccountsLogo.png"
fi

# The background picture is each user's own file in Application Support; none ships inside the app.
rm -f "$RESOURCES/AppBackdrop.png"

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

# BUILD_ARCH=universal builds for Apple Silicon and Intel. The source is compiled by its path inside the
# repository and the prefix map removes the rest, so the builder's folder and user name never end up in the app.
if [[ "$BUILD_ARCH" == "universal" ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$BUILD_ARCH")
fi
SLICES=()
for arch in "${ARCHS[@]}"; do
  slice="$MACOS/.codex-accounts-$arch"
  (
    cd "$ROOT_DIR"
    swiftc \
      -target "$arch-apple-macos$MACOS_DEPLOYMENT_TARGET" \
      -file-prefix-map "$ROOT_DIR=." \
      "macos/CodexAccounts/Sources/CodexAccounts.swift" \
      -framework AppKit \
      -framework CoreGraphics \
      -framework IOKit \
      -framework SwiftUI \
      -o "$slice"
  )
  SLICES+=("$slice")
done
if (( ${#SLICES[@]} > 1 )); then
  lipo -create "${SLICES[@]}" -output "$MACOS/Codex Accounts"
  rm -f "${SLICES[@]}"
else
  mv -f "${SLICES[1]}" "$MACOS/Codex Accounts"
fi

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
