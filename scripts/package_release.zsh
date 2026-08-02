#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/Codex Accounts.app"
ZIP_PATH="$DIST_DIR/Codex-Accounts-macOS.zip"
RUNTIME_SEED_DIR="$APP_PATH/Contents/Resources/opencodex-runtime/2.7.33/arm64"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/build_codex_accounts_app.zsh"

[[ -f "$RUNTIME_SEED_DIR/manifest.json" ]] || {
  echo "Bundled OpenCodex runtime manifest is missing." >&2
  exit 1
}
RUNTIME_ARCHIVE="$(python3 - "$RUNTIME_SEED_DIR/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
archive = manifest.get("archive")
if not isinstance(archive, str) or not archive or "/" in archive or "\\" in archive:
    raise SystemExit("Invalid OpenCodex runtime archive name")
print(archive)
PY
)"
RUNTIME_SHA="$(python3 - "$RUNTIME_SEED_DIR/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("archive_sha256")
if not isinstance(value, str) or len(value) != 64:
    raise SystemExit("Invalid OpenCodex runtime archive hash")
print(value)
PY
)"
[[ -f "$RUNTIME_SEED_DIR/$RUNTIME_ARCHIVE" ]] || {
  echo "Bundled OpenCodex runtime archive is missing." >&2
  exit 1
}
[[ "$(shasum -a 256 "$RUNTIME_SEED_DIR/$RUNTIME_ARCHIVE" | awk '{print $1}')" == "$RUNTIME_SHA" ]] || {
  echo "Bundled OpenCodex runtime archive hash mismatch." >&2
  exit 1
}

codesign --verify --deep --strict "$APP_PATH"

# Keep the downloadable archive free of Finder resource-fork sidecars such as
# __MACOSX/._*. The app's real CodeResources signature remains inside the bundle.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if zipinfo -1 "$ZIP_PATH" | grep -Eq '(^|/)__MACOSX/|(^|/)\._'; then
  echo "Release archive contains Finder sidecar files." >&2
  exit 1
fi

VERIFY_DIR="$(mktemp -d /tmp/codex-accounts-release.XXXXXX)"
cleanup() { rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Codex Accounts.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERIFY_DIR/Codex Accounts.app/Contents/Info.plist")" == "2.7.1" ]]
[[ -f "$VERIFY_DIR/Codex Accounts.app/Contents/Resources/opencodex-runtime/2.7.33/arm64/manifest.json" ]]

echo "Release package:"
echo "  $ZIP_PATH"
echo "  SHA-256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
