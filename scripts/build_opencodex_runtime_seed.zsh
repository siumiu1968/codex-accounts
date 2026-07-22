#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${OPENCODEX_VERSION:-2.7.33}"
ARCH="${OPENCODEX_SEED_ARCH:-$(uname -m)}"
RUNTIME_PREFIX="${OPENCODEX_SOURCE_RUNTIME:-$HOME/Library/Application Support/Codex Accounts/OpenCodex/runtime}"
NODE_MODULES="$RUNTIME_PREFIX/node_modules"
OUTPUT_DIR="${OPENCODEX_SEED_OUTPUT_DIR:-$ROOT_DIR/resources/opencodex-runtime/$VERSION/$ARCH}"
ARCHIVE_NAME="opencodex-node_modules-$VERSION-$ARCH.tar.gz"
SEED_HELPER="$ROOT_DIR/scripts/opencodex_runtime_seed.py"

[[ "$ARCH" == "arm64" ]] || {
  echo "Only the verified arm64 OpenCodex runtime can be packaged." >&2
  exit 2
}
[[ -d "$NODE_MODULES" && ! -L "$NODE_MODULES" ]] || {
  echo "OpenCodex node_modules was not found: $NODE_MODULES" >&2
  exit 1
}
[[ -f "$SEED_HELPER" && ! -L "$SEED_HELPER" ]] || {
  echo "OpenCodex runtime seed helper was not found: $SEED_HELPER" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$OUTPUT_DIR" \
NODE_MODULES="$NODE_MODULES" \
VERSION="$VERSION" \
ARCH="$ARCH" \
ARCHIVE_NAME="$ARCHIVE_NAME" \
SEED_HELPER="$SEED_HELPER" \
python3 - <<'PY'
import gzip
import hashlib
import importlib.util
import json
import os
import tarfile
import tempfile
from pathlib import Path

node_modules = Path(os.environ["NODE_MODULES"]).resolve()
output_dir = Path(os.environ["OUTPUT_DIR"]).resolve()
version = os.environ["VERSION"]
arch = os.environ["ARCH"]
archive_name = os.environ["ARCHIVE_NAME"]
seed_helper_path = Path(os.environ["SEED_HELPER"]).resolve()
package_root = node_modules / "@bitkyc08" / "opencodex"
package_json_path = package_root / "package.json"

helper_spec = importlib.util.spec_from_file_location("opencodex_runtime_seed", seed_helper_path)
if helper_spec is None or helper_spec.loader is None:
    raise SystemExit("The OpenCodex runtime seed helper cannot be loaded")
seed_helper = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(seed_helper)

with package_json_path.open("r", encoding="utf-8") as handle:
    source_package = json.load(handle)
if source_package.get("name") != "@bitkyc08/opencodex" or source_package.get("version") != version:
    raise SystemExit("The source OpenCodex package does not match the pinned version")

bun_path = node_modules / "bun" / "bin" / "bun.exe"
if not bun_path.is_file() or bun_path.is_symlink():
    raise SystemExit("The arm64 Bun runtime is missing")
header = bun_path.read_bytes()[:32]
if len(header) < 8 or header[:4] not in {
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"
}:
    raise SystemExit("The bundled Bun executable is not a Mach-O binary")

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

critical_paths = [
    "node_modules/@bitkyc08/opencodex/package.json",
    "node_modules/@bitkyc08/opencodex/bin/ocx.mjs",
    "node_modules/bun/bin/bun.exe",
    "node_modules/@bitkyc08/opencodex/gui/dist/index.html",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-Cgt7VoIY.js",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-D6Fcl4yM.css",
]
for relative in critical_paths:
    candidate = node_modules.parent / relative
    if not candidate.is_file() or candidate.is_symlink():
        raise SystemExit(f"Missing critical runtime file: {relative}")

package_rows = []
for metadata_path in sorted(node_modules.rglob("package.json")):
    if metadata_path.is_symlink():
        continue
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        continue
    name = metadata.get("name")
    package_version = metadata.get("version")
    license_value = metadata.get("license")
    if not all(isinstance(value, str) and value.strip() for value in (name, package_version, license_value)):
        continue
    package_dir = metadata_path.parent
    license_files = sorted(
        item.name
        for item in package_dir.iterdir()
        if item.is_file() and item.name.lower().startswith(("license", "copying", "notice"))
    )
    package_rows.append({
        "name": name.strip(),
        "version": package_version.strip(),
        "license": license_value.strip(),
        "path": str(package_dir.relative_to(node_modules)),
        "license_files": license_files,
    })

notices_lines = [
    f"Codex Accounts bundled OpenCodex runtime {version} ({arch})",
    "",
    "This offline runtime contains third-party npm packages. Their original package",
    "metadata and license files are preserved inside the bundled node_modules tree.",
    "The inventory below is generated from the packaged package.json files.",
    "",
    "PACKAGE INVENTORY",
    "=================",
]
for row in package_rows:
    license_files = ", ".join(row["license_files"]) or "see package metadata"
    notices_lines.append(
        f"{row['name']} {row['version']} | {row['license']} | {row['path']} | {license_files}"
    )
notices_text = "\n".join(notices_lines) + "\n"

output_dir.mkdir(parents=True, exist_ok=True)
archive_path = output_dir / archive_name
manifest_path = output_dir / "manifest.json"
notices_path = output_dir / "THIRD_PARTY_NOTICES.txt"

fd, archive_tmp_name = tempfile.mkstemp(prefix=f".{archive_name}.", suffix=".tmp", dir=output_dir)
os.close(fd)
archive_tmp = Path(archive_tmp_name)
try:
    with archive_tmp.open("wb") as raw_handle:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_handle, mtime=0, compresslevel=9) as gzip_handle:
            with tarfile.open(fileobj=gzip_handle, mode="w", format=tarfile.PAX_FORMAT, dereference=False) as archive:
                def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "wheel"
                    info.mtime = 0
                    info.pax_headers = {}
                    return info

                archive.add(node_modules, arcname="node_modules", recursive=True, filter=normalize)
        if archive_tmp.stat().st_size >= 100 * 1024 * 1024:
            raise SystemExit("The OpenCodex seed archive must remain below 100 MB")
        os.replace(archive_tmp, archive_path)
        os.chmod(archive_path, 0o644)
    notices_path.write_text(notices_text, encoding="utf-8")
    os.chmod(notices_path, 0o644)
    with tarfile.open(archive_path, mode="r:gz") as packaged_archive:
        archive_uncompressed_size = sum(member.size for member in packaged_archive.getmembers() if member.isfile())

    repository = source_package.get("repository")
    if isinstance(repository, dict):
        repository = repository.get("url")
    manifest = {
        "schema_version": 1,
        "package": "@bitkyc08/opencodex",
        "version": version,
        "arch": arch,
        "archive": archive_name,
        "archive_sha256": sha256(archive_path),
        "archive_size_bytes": archive_path.stat().st_size,
        "archive_uncompressed_size_bytes": archive_uncompressed_size,
        "runtime_tree_sha256": seed_helper.runtime_tree_sha256(node_modules.parent),
        "critical_files": {
            relative: sha256(node_modules.parent / relative)
            for relative in critical_paths
        },
        "third_party_notices": "THIRD_PARTY_NOTICES.txt",
        "third_party_notices_sha256": sha256(notices_path),
        "package_inventory_count": len(package_rows),
        "source_package": {
            "name": source_package.get("name"),
            "version": source_package.get("version"),
            "description": source_package.get("description"),
            "license": source_package.get("license"),
            "repository": repository,
            "homepage": source_package.get("homepage"),
            "dependencies": source_package.get("dependencies", {}),
            "package_json_sha256": sha256(package_json_path),
        },
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(manifest_path, 0o644)
finally:
    try:
        archive_tmp.unlink()
    except FileNotFoundError:
        pass

print(archive_path)
print(manifest_path)
print(notices_path)
PY
