#!/usr/bin/env zsh
set -euo pipefail

# Builds the downloadable app: universal (Apple Silicon and Intel), with checks that nothing personal is inside.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Codex Accounts.app"
ZIP_PATH="$DIST_DIR/Codex-Accounts-macOS.zip"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/macos/CodexAccounts/Info.plist")"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

BUILD_ARCH=universal APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/build_codex_accounts_app.zsh"

BINARY="$APP_PATH/Contents/MacOS/Codex Accounts"
[[ "$(lipo -archs "$BINARY" | tr ' ' '\n' | sort | tr '\n' ' ')" == "arm64 x86_64 " ]] || {
  echo "The app is not a universal build." >&2
  exit 1
}

# Nothing from the machine that built it: no user name, no home folder, no account data, no pictures of ours.
if grep -R -a -l -e "$(id -un)" -e "$HOME" "$APP_PATH" >/dev/null 2>&1; then
  echo "The app contains this machine's user name or home folder:" >&2
  grep -R -a -l -e "$(id -un)" -e "$HOME" "$APP_PATH" >&2
  exit 1
fi
if find "$APP_PATH" \( -name 'auth.json' -o -name '*.sqlite' -o -name '*.jsonl' -o -name 'AppBackdrop*' -o -name '.DS_Store' \) | grep -q .; then
  echo "The app contains a file that must not ship." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

# Keep the downloadable archive free of Finder resource-fork sidecars such as
# __MACOSX/._*. The app's real CodeResources signature remains inside the bundle.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if zipinfo -1 "$ZIP_PATH" | grep -Eq '(^|/)__MACOSX/|(^|/)\._'; then
  echo "Release archive contains Finder sidecar files." >&2
  exit 1
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-accounts-release.XXXXXX")"
cleanup() { rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Codex Accounts.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERIFY_DIR/Codex Accounts.app/Contents/Info.plist")" == "$VERSION" ]]

echo "Release package $VERSION:"
echo "  $ZIP_PATH"
echo "  SHA-256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
