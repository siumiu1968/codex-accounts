#!/usr/bin/env python3
"""Validate and atomically install a bundled OpenCodex node_modules seed."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Iterable, Optional


PACKAGE_NAME = "@bitkyc08/opencodex"
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
MAX_EXTRACTED_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 100_000
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_CRITICAL_FILES = {
    "node_modules/@bitkyc08/opencodex/package.json",
    "node_modules/@bitkyc08/opencodex/bin/ocx.mjs",
    "node_modules/bun/bin/bun.exe",
    "node_modules/@bitkyc08/opencodex/gui/dist/index.html",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-Cgt7VoIY.js",
    "node_modules/@bitkyc08/opencodex/gui/dist/assets/index-D6Fcl4yM.css",
}


class SeedError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _tree_entries(root: Path) -> Iterable[tuple[Path, Path, os.stat_result]]:
    """Yield a deterministic, non-symlink-following view of a runtime tree."""
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as scan:
                children = sorted(scan, key=lambda item: os.fsencode(item.name))
        except OSError as exc:
            raise SeedError(f"OpenCodex runtime tree cannot be read: {directory}: {exc}") from exc
        child_directories: list[Path] = []
        for child in children:
            candidate = Path(child.path)
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as exc:
                raise SeedError(f"OpenCodex runtime tree entry cannot be read: {candidate}: {exc}") from exc
            relative = candidate.relative_to(root)
            yield candidate, relative, metadata
            if stat.S_ISDIR(metadata.st_mode):
                child_directories.append(candidate)
        pending.extend(reversed(child_directories))


def _digest_field(digest: "hashlib._Hash", value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def runtime_tree_sha256(runtime: Path) -> str:
    """Hash paths, types, modes, file bytes and symlink targets deterministically."""
    if runtime.is_symlink() or not runtime.is_dir():
        raise SeedError(f"OpenCodex runtime directory is invalid: {runtime}")
    runtime_root = runtime.resolve(strict=True)
    digest = hashlib.sha256(b"opencodex-runtime-tree-v1\0")
    for candidate, relative, metadata in _tree_entries(runtime_root):
        if stat.S_ISREG(metadata.st_mode):
            entry_type = b"file"
        elif stat.S_ISDIR(metadata.st_mode):
            entry_type = b"directory"
        elif stat.S_ISLNK(metadata.st_mode):
            entry_type = b"symlink"
        else:
            raise SeedError(f"OpenCodex runtime contains a special file: {candidate}")

        digest.update(b"entry\0")
        _digest_field(digest, entry_type)
        _digest_field(digest, os.fsencode(relative.as_posix()))
        _digest_field(digest, f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"))
        if entry_type == b"file":
            digest.update(metadata.st_size.to_bytes(8, "big"))
            try:
                with candidate.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(block)
            except OSError as exc:
                raise SeedError(f"OpenCodex runtime file cannot be hashed: {candidate}: {exc}") from exc
        elif entry_type == b"symlink":
            try:
                target = os.readlink(candidate)
            except OSError as exc:
                raise SeedError(f"OpenCodex runtime symlink cannot be read: {candidate}: {exc}") from exc
            _digest_field(digest, os.fsencode(target))
    return digest.hexdigest()


def require_plain_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise SeedError(f"{label} is missing or is a symlink: {path}")


def path_is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def load_seed(seed_dir: Path, version: str, arch: str, *, verify_archive: bool) -> tuple[dict, Path]:
    if seed_dir.is_symlink() or not seed_dir.is_dir():
        raise SeedError(f"OpenCodex runtime seed directory is invalid: {seed_dir}")
    seed_root = seed_dir.resolve(strict=True)
    manifest_path = seed_root / "manifest.json"
    require_plain_file(manifest_path, "OpenCodex seed manifest")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SeedError(f"OpenCodex seed manifest is invalid: {exc}") from exc
    if not isinstance(manifest, dict):
        raise SeedError("OpenCodex seed manifest must be a JSON object")
    expected_values = {
        "schema_version": 1,
        "package": PACKAGE_NAME,
        "version": version,
        "arch": arch,
    }
    for key, expected in expected_values.items():
        if manifest.get(key) != expected:
            raise SeedError(f"OpenCodex seed {key} mismatch")

    archive_name = manifest.get("archive")
    if not isinstance(archive_name, str):
        raise SeedError("OpenCodex seed archive name is missing")
    archive_relative = PurePosixPath(archive_name)
    if archive_relative.is_absolute() or len(archive_relative.parts) != 1 or archive_relative.name != archive_name:
        raise SeedError("OpenCodex seed archive name must be a plain file name")
    archive_path = seed_root / archive_name
    require_plain_file(archive_path, "OpenCodex seed archive")
    if archive_path.stat().st_size >= MAX_ARCHIVE_BYTES:
        raise SeedError("OpenCodex seed archive exceeds the 100 MB limit")
    expected_size = manifest.get("archive_size_bytes")
    if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size != archive_path.stat().st_size:
        raise SeedError("OpenCodex seed archive size verification failed")
    expected_archive_hash = manifest.get("archive_sha256")
    if not isinstance(expected_archive_hash, str) or not HEX_SHA256.fullmatch(expected_archive_hash):
        raise SeedError("OpenCodex seed archive hash is invalid")
    if verify_archive and sha256(archive_path) != expected_archive_hash:
        raise SeedError("OpenCodex seed archive hash verification failed")

    expected_tree_hash = manifest.get("runtime_tree_sha256")
    if not isinstance(expected_tree_hash, str) or not HEX_SHA256.fullmatch(expected_tree_hash):
        raise SeedError("OpenCodex seed runtime tree hash is invalid")

    notices_name = manifest.get("third_party_notices")
    if not isinstance(notices_name, str) or PurePosixPath(notices_name).name != notices_name:
        raise SeedError("OpenCodex third-party notice name is invalid")
    notices_path = seed_root / notices_name
    require_plain_file(notices_path, "OpenCodex third-party notices")
    notices_hash = manifest.get("third_party_notices_sha256")
    if not isinstance(notices_hash, str) or not HEX_SHA256.fullmatch(notices_hash):
        raise SeedError("OpenCodex third-party notice hash is invalid")
    if sha256(notices_path) != notices_hash:
        raise SeedError("OpenCodex third-party notice verification failed")

    critical = manifest.get("critical_files")
    if not isinstance(critical, dict) or not REQUIRED_CRITICAL_FILES.issubset(critical):
        raise SeedError("OpenCodex seed critical file list is incomplete")
    for relative, expected_hash in critical.items():
        if not isinstance(relative, str) or not isinstance(expected_hash, str) or not HEX_SHA256.fullmatch(expected_hash):
            raise SeedError("OpenCodex seed critical file entry is invalid")
        validate_member_name(relative)

    source_package = manifest.get("source_package")
    if not isinstance(source_package, dict):
        raise SeedError("OpenCodex source package metadata is missing")
    if source_package.get("name") != PACKAGE_NAME or source_package.get("version") != version:
        raise SeedError("OpenCodex source package metadata does not match the pinned package")
    if source_package.get("package_json_sha256") != critical["node_modules/@bitkyc08/opencodex/package.json"]:
        raise SeedError("OpenCodex source package metadata hash mismatch")
    return manifest, archive_path


def validate_member_name(raw_name: str) -> PurePosixPath:
    if not raw_name or "\x00" in raw_name or "\\" in raw_name:
        raise SeedError("OpenCodex seed contains an invalid archive entry")
    path = PurePosixPath(raw_name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise SeedError(f"OpenCodex seed contains an unsafe archive entry: {raw_name}")
    normalized = posixpath.normpath(raw_name)
    if normalized != raw_name or not path.parts or path.parts[0] != "node_modules":
        raise SeedError(f"OpenCodex seed entry is outside node_modules: {raw_name}")
    return path


def validate_symlink_target(member_path: PurePosixPath, link_name: str) -> None:
    if not link_name or "\x00" in link_name or "\\" in link_name or PurePosixPath(link_name).is_absolute():
        raise SeedError(f"OpenCodex seed contains an unsafe symlink: {member_path}")
    resolved = PurePosixPath(posixpath.normpath(posixpath.join(str(member_path.parent), link_name)))
    if not resolved.parts or resolved.parts[0] != "node_modules" or ".." in resolved.parts:
        raise SeedError(f"OpenCodex seed symlink escapes node_modules: {member_path}")


def inspect_archive(archive_path: Path, manifest: dict) -> list[tarfile.TarInfo]:
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members = archive.getmembers()
    except (OSError, tarfile.TarError) as exc:
        raise SeedError(f"OpenCodex seed archive cannot be read: {exc}") from exc
    if not members or len(members) > MAX_ARCHIVE_ENTRIES:
        raise SeedError("OpenCodex seed archive entry count is invalid")

    by_name: dict[str, tarfile.TarInfo] = {}
    symlink_names: set[PurePosixPath] = set()
    total_size = 0
    for member in members:
        member_path = validate_member_name(member.name)
        if member.name in by_name:
            raise SeedError(f"OpenCodex seed contains a duplicate archive entry: {member.name}")
        by_name[member.name] = member
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise SeedError(f"OpenCodex seed contains a special archive entry: {member.name}")
        if member.isfile():
            total_size += member.size
            if total_size > MAX_EXTRACTED_BYTES:
                raise SeedError("OpenCodex seed expands beyond the safety limit")
        if member.issym():
            validate_symlink_target(member_path, member.linkname)
            symlink_names.add(member_path)

    for member in members:
        member_path = PurePosixPath(member.name)
        for parent in member_path.parents:
            if parent in symlink_names:
                raise SeedError(f"OpenCodex seed writes through a symlink: {member.name}")
        if member.islnk():
            target_path = validate_member_name(member.linkname)
            target = by_name.get(str(target_path))
            if target is None or not target.isfile():
                raise SeedError(f"OpenCodex seed hard link target is invalid: {member.name}")

    expected_uncompressed = manifest.get("archive_uncompressed_size_bytes")
    if expected_uncompressed is not None and expected_uncompressed != total_size:
        raise SeedError("OpenCodex seed expanded size verification failed")
    for relative in manifest["critical_files"]:
        member = by_name.get(relative)
        if member is None or not member.isfile():
            raise SeedError(f"OpenCodex seed critical file is not a regular archive member: {relative}")
    return members


def validate_runtime(runtime: Path, manifest: dict, version: str, arch: str) -> None:
    if runtime.is_symlink() or not runtime.is_dir():
        raise SeedError(f"OpenCodex runtime directory is invalid: {runtime}")
    runtime_root = runtime.resolve(strict=True)
    for candidate in runtime_root.rglob("*"):
        if not candidate.is_symlink():
            continue
        try:
            target = candidate.resolve(strict=False)
        except RuntimeError as exc:
            raise SeedError(f"OpenCodex runtime contains a symlink loop: {candidate}") from exc
        if not path_is_within(target, runtime_root):
            raise SeedError(f"OpenCodex runtime symlink escapes the managed runtime: {candidate}")

    actual_tree_hash = runtime_tree_sha256(runtime_root)
    if actual_tree_hash != manifest["runtime_tree_sha256"]:
        raise SeedError(
            "OpenCodex runtime tree verification failed "
            f"(expected {manifest['runtime_tree_sha256']}, found {actual_tree_hash})"
        )

    for relative, expected_hash in manifest["critical_files"].items():
        relative_path = validate_member_name(relative)
        candidate = runtime_root.joinpath(*relative_path.parts)
        if candidate.is_symlink() or not candidate.is_file() or sha256(candidate) != expected_hash:
            raise SeedError(f"OpenCodex runtime critical file verification failed: {relative}")

    package_json_path = runtime_root / "node_modules" / "@bitkyc08" / "opencodex" / "package.json"
    try:
        package = json.loads(package_json_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SeedError(f"OpenCodex runtime package metadata is invalid: {exc}") from exc
    if package.get("name") != PACKAGE_NAME or package.get("version") != version:
        raise SeedError("OpenCodex runtime package version verification failed")

    ocx_path = runtime_root / "node_modules" / "@bitkyc08" / "opencodex" / "bin" / "ocx.mjs"
    bun_path = runtime_root / "node_modules" / "bun" / "bin" / "bun.exe"
    launcher_path = runtime_root / "node_modules" / ".bin" / "ocx"
    for executable in (ocx_path, bun_path, launcher_path):
        if not executable.exists() or not os.access(executable, os.X_OK):
            raise SeedError(f"OpenCodex runtime executable is invalid: {executable}")
    if arch == "arm64" and bun_path.read_bytes()[:8] != b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01":
        raise SeedError("OpenCodex bundled Bun executable is not arm64")


def validate_current(seed_dir: Path, runtime: Path, version: str, arch: str) -> None:
    manifest, _ = load_seed(seed_dir, version, arch, verify_archive=True)
    validate_runtime(runtime, manifest, version, arch)


def cleanup_stale_runtime_dirs(root: Path) -> None:
    """Remove marker-owned temporary directories without following symlinks."""
    try:
        candidates = list(os.scandir(root))
    except OSError as exc:
        raise SeedError(f"OpenCodex managed root cannot be scanned: {root}: {exc}") from exc
    for entry in candidates:
        if not entry.name.startswith((".runtime-backup-", ".runtime-seed-")):
            continue
        try:
            if not entry.is_dir(follow_symlinks=False):
                continue
            shutil.rmtree(entry.path)
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise SeedError(f"OpenCodex stale runtime directory cannot be removed: {entry.path}: {exc}") from exc


def install(seed_dir: Path, runtime: Path, managed_root: Path, version: str, arch: str) -> str:
    if managed_root.is_symlink() or not managed_root.is_dir():
        raise SeedError(f"OpenCodex managed root is invalid: {managed_root}")
    root = managed_root.resolve(strict=True)
    if runtime.parent.resolve(strict=True) != root or runtime.name != "runtime" or runtime.is_symlink():
        raise SeedError(f"Refusing unexpected OpenCodex runtime destination: {runtime}")

    lock_path = root / ".runtime-seed.lock"
    if lock_path.is_symlink():
        raise SeedError(f"Refusing OpenCodex runtime seed lock symlink: {lock_path}")
    with lock_path.open("a+") as lock_handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        manifest, archive_path = load_seed(seed_dir, version, arch, verify_archive=True)
        try:
            validate_runtime(runtime, manifest, version, arch)
        except SeedError:
            pass
        else:
            cleanup_stale_runtime_dirs(root)
            return "already-current"

        members = inspect_archive(archive_path, manifest)
        staging = Path(tempfile.mkdtemp(prefix=".runtime-seed-", dir=root))
        backup: Optional[Path] = None
        try:
            try:
                with tarfile.open(archive_path, mode="r:gz") as archive:
                    archive.extractall(staging, members=members)
            except (OSError, tarfile.TarError) as exc:
                raise SeedError(f"OpenCodex seed extraction failed: {exc}") from exc
            validate_runtime(staging, manifest, version, arch)

            if runtime.exists():
                backup = Path(tempfile.mkdtemp(prefix=".runtime-backup-", dir=root))
                backup.rmdir()
                os.replace(runtime, backup)
            try:
                os.replace(staging, runtime)
            except BaseException:
                if backup is not None and backup.exists() and not runtime.exists():
                    os.replace(backup, runtime)
                    backup = None
                raise
            root_fd = os.open(root, os.O_RDONLY)
            try:
                os.fsync(root_fd)
            finally:
                os.close(root_fd)
            if backup is not None:
                shutil.rmtree(backup)
                backup = None
            cleanup_stale_runtime_dirs(root)
            return "installed"
        finally:
            if staging.exists():
                shutil.rmtree(staging)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("validate-current", "install"))
    parser.add_argument("--seed-dir", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--managed-root", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.mode == "validate-current":
            validate_current(args.seed_dir, args.runtime, args.version, args.arch)
            print("current")
        else:
            if args.managed_root is None:
                raise SeedError("--managed-root is required for installation")
            print(install(args.seed_dir, args.runtime, args.managed_root, args.version, args.arch))
    except SeedError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
