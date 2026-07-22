#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
HELPER="$ROOT/scripts/codex_multi_account.zsh"
SEED_HELPER="$ROOT/scripts/opencodex_runtime_seed.py"
OVERLAY="$ROOT/resources/opencodex-zh-hk/2.7.33"
TMP_ROOT="$(mktemp -d /tmp/codex-accounts-seed.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_seed() {
  local output_dir="$1"
  local mode="${2:-valid}"
  OUTPUT_DIR="$output_dir" MODE="$mode" OVERLAY="$OVERLAY" SEED_HELPER="$SEED_HELPER" python3 - <<'PY'
import gzip
import hashlib
import importlib.util
import io
import json
import os
import tarfile
from pathlib import Path

output = Path(os.environ["OUTPUT_DIR"])
mode = os.environ["MODE"]
overlay = Path(os.environ["OVERLAY"])
seed_helper_path = Path(os.environ["SEED_HELPER"])
helper_spec = importlib.util.spec_from_file_location("opencodex_runtime_seed", seed_helper_path)
if helper_spec is None or helper_spec.loader is None:
    raise SystemExit("OpenCodex runtime seed helper cannot be loaded")
seed_helper = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(seed_helper)
tree = output / "tree" / "node_modules"
package = tree / "@bitkyc08" / "opencodex"
(package / "bin").mkdir(parents=True)
(package / "src").mkdir(parents=True)
(package / "gui" / "dist" / "assets").mkdir(parents=True)
(tree / "bun" / "bin").mkdir(parents=True)
(tree / ".bin").mkdir(parents=True)
(package / "package.json").write_text(
    json.dumps({
        "name": "@bitkyc08/opencodex",
        "version": "2.7.33",
        "description": "OpenCodex test seed",
        "license": "MIT",
        "repository": {"type": "git", "url": "https://github.com/lidge-jun/opencodex"},
        "homepage": "https://lidge-jun.github.io/opencodex/",
        "dependencies": {},
    }) + "\n",
    encoding="utf-8",
)
ocx = package / "bin" / "ocx.mjs"
ocx.write_text("#!/usr/bin/env node\n", encoding="utf-8")
ocx.chmod(0o755)
(package / "src" / "noncritical.ts").write_text("export const intact = true;\n", encoding="utf-8")
bun = tree / "bun" / "bin" / "bun.exe"
bun.write_bytes(b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01mock-arm64-bun\n")
bun.chmod(0o755)
(tree / ".bin" / "ocx").symlink_to("../@bitkyc08/opencodex/bin/ocx.mjs")
for relative in (
    "index.html",
    "assets/index-Cgt7VoIY.js",
    "assets/index-D6Fcl4yM.css",
):
    target = package / "gui" / "dist" / relative
    target.write_bytes((overlay / relative).read_bytes())

critical_names = [
    "node_modules/@bitkyc08/opencodex/package.json",
    "node_modules/@bitkyc08/opencodex/bin/ocx.mjs",
    "node_modules/bun/bin/bun.exe",
    "node_modules/@bitkyc08/opencodex/gui/dist/index.html",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-Cgt7VoIY.js",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-D6Fcl4yM.css",
]

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

output.mkdir(parents=True, exist_ok=True)
archive_path = output / "mock-seed.tar.gz"
with archive_path.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT, dereference=False) as archive:
            archive.add(tree, arcname="node_modules")
            if mode == "path":
                payload = b"escape\n"
                member = tarfile.TarInfo("../seed-path-escape")
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            elif mode == "symlink":
                member = tarfile.TarInfo("node_modules/escape-link")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../seed-symlink-escape"
                archive.addfile(member)

notices = output / "THIRD_PARTY_NOTICES.txt"
notices.write_text("Mock OpenCodex seed; MIT license files remain in node_modules.\n", encoding="utf-8")
with tarfile.open(archive_path, mode="r:gz") as archive:
    expanded_size = sum(member.size for member in archive.getmembers() if member.isfile())
manifest = {
    "schema_version": 1,
    "package": "@bitkyc08/opencodex",
    "version": "2.7.33",
    "arch": "arm64",
    "archive": archive_path.name,
    "archive_sha256": sha256(archive_path),
    "archive_size_bytes": archive_path.stat().st_size,
    "archive_uncompressed_size_bytes": expanded_size,
    "runtime_tree_sha256": seed_helper.runtime_tree_sha256(tree.parent),
    "critical_files": {name: sha256(output / "tree" / name) for name in critical_names},
    "third_party_notices": notices.name,
    "third_party_notices_sha256": sha256(notices),
    "source_package": {
        "name": "@bitkyc08/opencodex",
        "version": "2.7.33",
        "description": "OpenCodex test seed",
        "license": "MIT",
        "repository": "https://github.com/lidge-jun/opencodex",
        "homepage": "https://lidge-jun.github.io/opencodex/",
        "dependencies": {},
        "package_json_sha256": sha256(package / "package.json"),
    },
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_install() {
  local case_root="$1"
  local seed_dir="$2"
  mkdir -p "$case_root/primary" "$case_root/accounts" "$case_root/app-data"
  PRIMARY_CODEX_HOME="$case_root/primary" \
  ACCOUNTS_ROOT="$case_root/accounts" \
  APP_DATA_ROOT="$case_root/app-data" \
  SECOND_CODEX_HOME="$case_root/account2" \
  SECOND_APP_DATA="$case_root/account2-data" \
  SHARED_HISTORY_ROOT="$case_root/shared-history" \
  SHARED_MEMORY_DIR="$case_root/shared-memory" \
  OPENCODEX_ROOT="$case_root/app-data/OpenCodex" \
  OPENCODEX_STATE_DIR="$case_root/app-data/OpenCodex/state" \
  OPENCODEX_NPM_PREFIX="$case_root/app-data/OpenCodex/runtime" \
  OPENCODEX_FAKE_HOME="$case_root/app-data/OpenCodex/home" \
  OPENCODEX_LOG_DIR="$case_root/app-data/OpenCodex/logs" \
  OPENCODEX_LAB_CODEX_HOME="$case_root/accounts/opencodex-lab" \
  OPENCODEX_LAB_APP_DATA="$case_root/app-data/opencodex-lab" \
  OPENCODEX_BIN="$case_root/app-data/OpenCodex/runtime/node_modules/.bin/ocx" \
  OPENCODEX_PACKAGE_JSON="$case_root/app-data/OpenCodex/runtime/node_modules/@bitkyc08/opencodex/package.json" \
  OPENCODEX_RUNTIME_SEED_DIR="$seed_dir" \
  OPENCODEX_RUNTIME_SEED_HELPER="$SEED_HELPER" \
  OPENCODEX_RUNTIME_ARCH=arm64 \
  NPM_BIN="$TMP_ROOT/no-network/npm" \
  "$HELPER" opencodex-install
}

mkdir -p "$TMP_ROOT/no-network"
python3 - "$TMP_ROOT/no-network/npm" <<'PY'
import os
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text("#!/bin/zsh\nprintf 'npm-called\\n' >> \"$NPM_CALLED_LOG\"\nexit 98\n", encoding="utf-8")
path.chmod(0o755)
PY
export NPM_CALLED_LOG="$TMP_ROOT/npm-called.log"

VALID_SEED="$TMP_ROOT/valid-seed"
make_seed "$VALID_SEED" valid
VALID_CASE="$TMP_ROOT/valid-case"
install_output="$(run_install "$VALID_CASE" "$VALID_SEED")"
[[ "$install_output" == *"offline seed"* ]]
[[ ! -e "$NPM_CALLED_LOG" ]]
[[ "$(jq -r '.version' "$VALID_CASE/app-data/OpenCodex/runtime/node_modules/@bitkyc08/opencodex/package.json")" == "2.7.33" ]]
[[ -x "$VALID_CASE/app-data/OpenCodex/runtime/node_modules/.bin/ocx" ]]
python3 "$SEED_HELPER" validate-current \
  --seed-dir "$VALID_SEED" \
  --runtime "$VALID_CASE/app-data/OpenCodex/runtime" \
  --version 2.7.33 \
  --arch arm64 >/dev/null

STALE_OUTSIDE="$TMP_ROOT/stale-outside"
mkdir -p "$STALE_OUTSIDE"
printf 'keep\n' > "$STALE_OUTSIDE/keep.txt"
mkdir -p \
  "$VALID_CASE/app-data/OpenCodex/.runtime-seed-stale/nested" \
  "$VALID_CASE/app-data/OpenCodex/.runtime-backup-stale"
ln -s "$STALE_OUTSIDE" "$VALID_CASE/app-data/OpenCodex/.runtime-seed-stale/nested/outside-link"
ln -s "$STALE_OUTSIDE" "$VALID_CASE/app-data/OpenCodex/.runtime-seed-symlink"
printf 'tamper\n' >> "$VALID_CASE/app-data/OpenCodex/runtime/node_modules/@bitkyc08/opencodex/src/noncritical.ts"
noncritical_rc=0
python3 "$SEED_HELPER" validate-current \
  --seed-dir "$VALID_SEED" \
  --runtime "$VALID_CASE/app-data/OpenCodex/runtime" \
  --version 2.7.33 \
  --arch arm64 >/dev/null 2>&1 || noncritical_rc=$?
[[ "$noncritical_rc" != "0" ]]
repair_output="$(run_install "$VALID_CASE" "$VALID_SEED" 2>"$TMP_ROOT/noncritical-repair.log")"
[[ "$repair_output" == *"offline seed"* ]]
grep -q 'runtime tree verification failed' "$TMP_ROOT/noncritical-repair.log"
[[ "$(cat "$VALID_CASE/app-data/OpenCodex/runtime/node_modules/@bitkyc08/opencodex/src/noncritical.ts")" == "export const intact = true;" ]]
[[ ! -e "$VALID_CASE/app-data/OpenCodex/.runtime-seed-stale" ]]
[[ ! -e "$VALID_CASE/app-data/OpenCodex/.runtime-backup-stale" ]]
[[ -L "$VALID_CASE/app-data/OpenCodex/.runtime-seed-symlink" ]]
[[ "$(cat "$STALE_OUTSIDE/keep.txt")" == "keep" ]]

TAMPERED_SEED="$TMP_ROOT/tampered-seed"
cp -R "$VALID_SEED" "$TAMPERED_SEED"
printf 'tamper' >> "$TAMPERED_SEED/mock-seed.tar.gz"
tampered_rc=0
run_install "$TMP_ROOT/tampered-case" "$TAMPERED_SEED" >/dev/null 2>&1 || tampered_rc=$?
[[ "$tampered_rc" != "0" ]]
[[ ! -e "$TMP_ROOT/tampered-case/app-data/OpenCodex/runtime/node_modules" ]]
[[ ! -e "$NPM_CALLED_LOG" ]]

PATH_SEED="$TMP_ROOT/path-seed"
make_seed "$PATH_SEED" path
path_rc=0
run_install "$TMP_ROOT/path-case" "$PATH_SEED" >/dev/null 2>&1 || path_rc=$?
[[ "$path_rc" != "0" ]]
[[ ! -e "$TMP_ROOT/path-case/app-data/OpenCodex/runtime/node_modules" ]]
[[ ! -e "$TMP_ROOT/seed-path-escape" ]]
[[ ! -e "$NPM_CALLED_LOG" ]]

SYMLINK_SEED="$TMP_ROOT/symlink-seed"
make_seed "$SYMLINK_SEED" symlink
symlink_rc=0
run_install "$TMP_ROOT/symlink-case" "$SYMLINK_SEED" >/dev/null 2>&1 || symlink_rc=$?
[[ "$symlink_rc" != "0" ]]
[[ ! -e "$TMP_ROOT/symlink-case/app-data/OpenCodex/runtime/node_modules" ]]
[[ ! -e "$TMP_ROOT/seed-symlink-escape" ]]
[[ ! -e "$NPM_CALLED_LOG" ]]

grep -q 'opencodex_runtime_seed.py' "$ROOT/scripts/build_codex_accounts_app.zsh"
grep -q 'resources/opencodex-runtime' "$ROOT/scripts/build_codex_accounts_app.zsh"
grep -q 'Contents/Resources/cua_node/bin/node' "$HELPER"

echo "✅ OpenCodex offline runtime seed checks passed"
