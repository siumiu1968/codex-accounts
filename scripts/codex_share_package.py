#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

FORMAT_VERSION = 1
PACKAGE_TYPE = "codex_conversation_share"
COLD_INDEX_VERSION = 1
STATE_DB_NAMES = ("state_5.sqlite", "sqlite/state_5.sqlite")

SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|secret|token|authorization|bearer|password|cookie|"
    r"refresh_token|access_token|auth\.json|dashscope|aliyun|sk-[A-Za-z0-9]|sk-sp-)"
)
PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
ABS_PATH_RE = re.compile(r"(?P<path>/(?:Users|Volumes|private|tmp|var)/[^\s\"'<>|)]+)")
SSH_RE = re.compile(r"(?i)(ssh\s+[-A-Za-z0-9_@.:]+|\.ssh/|known_hosts|authorized_keys)")
ENV_RE = re.compile(r"(?i)(^|/)\.env([.\w-]*)?$|config\.toml|credentials|secrets?")
GEN_IMAGE_RE = re.compile(r"(?i)(generated_images|codex-generated-images|image_generation|imagegen)")
FILE_EXT_RE = re.compile(
    r"(?i)\.(png|jpe?g|webp|gif|heic|tiff?|svg|pdf|txt|md|json|csv|xlsx?|docx?|pptx?|zip)$"
)


def utc_now():
    return datetime.now(timezone.utc)


def iso_from_ms(ms):
    if ms is None:
        return ""
    try:
        return datetime.fromtimestamp(int(ms) / 1000, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (TypeError, ValueError, OSError):
        return ""


def iso_from_seconds(seconds):
    if seconds is None:
        return ""
    try:
        return datetime.fromtimestamp(int(seconds), timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (TypeError, ValueError, OSError):
        return ""


def marker_ms(row):
    for key in ("recency_at_ms", "updated_at_ms", "created_at_ms"):
        value = row.get(key)
        if value is not None:
            try:
                return int(value)
            except (TypeError, ValueError):
                pass
    for key in ("recency_at", "updated_at", "created_at"):
        value = row.get(key)
        if value is not None:
            try:
                return int(value) * 1000
            except (TypeError, ValueError):
                pass
    return 0


def compact_text(value):
    return " ".join(str(value or "").split())


def best_thread_title(row):
    for key in ("title", "preview", "first_user_message"):
        value = compact_text(row.get(key))
        if value and value.lower() != "untitled":
            return value[:120]
    return "Untitled"


def state_db_path(home):
    for name in STATE_DB_NAMES:
        path = home / name
        if path.exists():
            return path
    return home / "state_5.sqlite"


def connect_ro(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)


def table_columns(con, table):
    try:
        return [row[1] for row in con.execute(f'PRAGMA table_info("{table}")')]
    except sqlite3.Error:
        return []


def table_exists(con, table):
    try:
        row = con.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            (table,),
        ).fetchone()
        return row is not None
    except sqlite3.Error:
        return False


def read_row(con, table, where, params):
    cols = table_columns(con, table)
    if not cols:
        return None, []
    query_cols = ", ".join(f'"{col}"' for col in cols)
    row = con.execute(f'SELECT {query_cols} FROM "{table}" WHERE {where}', params).fetchone()
    if row is None:
        return None, cols
    return dict(zip(cols, row)), cols


def read_rows(con, table, where, params):
    cols = table_columns(con, table)
    if not cols:
        return [], []
    query_cols = ", ".join(f'"{col}"' for col in cols)
    rows = con.execute(f'SELECT {query_cols} FROM "{table}" WHERE {where}', params).fetchall()
    return [dict(zip(cols, row)) for row in rows], cols


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rollout_relative_path(path):
    raw = str(path)
    for marker in ("/sessions/", "/archived_sessions/"):
        idx = raw.find(marker)
        if idx != -1:
            return raw[idx + len(marker):].lstrip("/")
    return path.name


def scan_rollout(path, collect_paths=False):
    counts = {
        "secret_like_lines": 0,
        "private_key_lines": 0,
        "absolute_path_lines": 0,
        "ssh_or_host_lines": 0,
        "env_or_config_lines": 0,
        "generated_image_lines": 0,
        "total_lines": 0,
    }
    paths = set()
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                counts["total_lines"] += 1
                if SECRET_RE.search(line):
                    counts["secret_like_lines"] += 1
                if PRIVATE_KEY_RE.search(line):
                    counts["private_key_lines"] += 1
                if SSH_RE.search(line):
                    counts["ssh_or_host_lines"] += 1
                if ENV_RE.search(line):
                    counts["env_or_config_lines"] += 1
                if GEN_IMAGE_RE.search(line):
                    counts["generated_image_lines"] += 1
                found = ABS_PATH_RE.findall(line)
                if found:
                    counts["absolute_path_lines"] += 1
                    if collect_paths:
                        for item in found:
                            paths.add(item.rstrip(".,;:"))
    except OSError as exc:
        raise SystemExit(f"Could not read rollout: {exc}")

    warnings = []
    if counts["secret_like_lines"]:
        warnings.append("Conversation log contains secret/token-like text. Review before sharing outside your team.")
    if counts["private_key_lines"]:
        warnings.append("Conversation log appears to contain a private key block.")
    if counts["absolute_path_lines"]:
        warnings.append("Conversation log contains local absolute paths.")
    if counts["ssh_or_host_lines"]:
        warnings.append("Conversation log contains SSH/host related text.")
    if counts["env_or_config_lines"]:
        warnings.append("Conversation log mentions env/config/credential files.")
    if not warnings:
        warnings.append("No obvious high-risk pattern was detected, but manual review is still recommended.")
    return counts, warnings, sorted(paths)


def candidate_attachment_paths(paths, cwd, include_local_assets, include_generated_images, max_total_bytes):
    allowed = []
    total = 0
    cwd_path = Path(cwd).expanduser() if cwd else None
    for raw in paths:
        path = Path(raw).expanduser()
        if not path.exists() or not path.is_file():
            continue
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size <= 0 or size > max_total_bytes:
            continue
        raw_lower = str(path).lower()
        is_generated = "generated_images" in raw_lower or "codex-generated-images" in raw_lower
        is_cwd_file = False
        if cwd_path is not None:
            try:
                path.resolve().relative_to(cwd_path.resolve())
                is_cwd_file = True
            except (OSError, ValueError):
                is_cwd_file = False
        if include_generated_images and is_generated:
            pass
        elif include_local_assets and is_cwd_file and FILE_EXT_RE.search(path.name):
            pass
        else:
            continue
        if total + size > max_total_bytes:
            continue
        total += size
        allowed.append(path)
    return allowed


def json_dumps(data):
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True)


def compact_json_line(data):
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def list_threads(args):
    home = Path(args.account_home).expanduser()
    db_path = state_db_path(home)
    if not db_path.exists():
        return 0
    con = connect_ro(db_path)
    con.row_factory = sqlite3.Row
    cols = table_columns(con, "threads")
    if not cols:
        con.close()
        return 0
    query_cols = ", ".join(f'"{col}"' for col in cols)
    rows = []
    for values in con.execute(f'SELECT {query_cols} FROM threads'):
        row = dict(zip(cols, values))
        rollout = str(row.get("rollout_path") or "")
        if not rollout or not Path(rollout).exists():
            continue
        rows.append(row)
    con.close()
    rows.sort(key=marker_ms, reverse=True)
    for row in rows[: max(args.limit, 1)]:
        rollout = Path(str(row.get("rollout_path") or ""))
        try:
            size = rollout.stat().st_size
        except OSError:
            size = 0
        updated = iso_from_ms(marker_ms(row))
        fields = [
            str(row.get("id") or ""),
            best_thread_title(row).replace("\t", " "),
            updated,
            str(row.get("cwd") or "").replace("\t", " "),
            str(size),
        ]
        print("\t".join(fields))
    return 0


def read_thread_package_state(home, thread_id):
    db_path = state_db_path(home)
    if not db_path.exists():
        raise SystemExit(f"state_5.sqlite not found under {home}")
    con = connect_ro(db_path)
    con.row_factory = sqlite3.Row
    thread_row, thread_cols = read_row(con, "threads", "id = ?", (thread_id,))
    if thread_row is None:
        con.close()
        raise SystemExit(f"Thread not found in {db_path}: {thread_id}")

    related = {}
    related_queries = {
        "thread_dynamic_tools": [("thread_id",)],
        "thread_spawn_edges": [("parent_thread_id",), ("child_thread_id",)],
        "agent_jobs": [("thread_id",), ("assigned_thread_id",)],
        "agent_job_items": [("thread_id",), ("assigned_thread_id",)],
    }
    for table, queries in related_queries.items():
        if not table_exists(con, table):
            continue
        table_rows = []
        seen = set()
        for cols in queries:
            available = table_columns(con, table)
            if not all(col in available for col in cols):
                continue
            where = " OR ".join(f'"{col}" = ?' for col in cols)
            rows, _ = read_rows(con, table, where, tuple(thread_id for _ in cols))
            for row in rows:
                key = compact_json_line(row)
                if key not in seen:
                    seen.add(key)
                    table_rows.append(row)
        if table_rows:
            related[table] = table_rows
    con.close()

    goals = []
    goals_db = home / "goals_1.sqlite"
    if goals_db.exists():
        try:
            gcon = connect_ro(goals_db)
            if table_exists(gcon, "thread_goals"):
                goals, _ = read_rows(gcon, "thread_goals", "thread_id = ?", (thread_id,))
            gcon.close()
        except sqlite3.Error:
            goals = []

    return {
        "thread_columns": thread_cols,
        "thread_row": thread_row,
        "related_rows": related,
        "goals_rows": goals,
    }


def export_package(args):
    home = Path(args.account_home).expanduser()
    thread_id = args.thread_id.strip()
    state = read_thread_package_state(home, thread_id)
    row = state["thread_row"]
    rollout = Path(str(row.get("rollout_path") or "")).expanduser()
    if not rollout.exists():
        raise SystemExit(f"Rollout file not found: {rollout}")

    scan_counts, warnings, paths = scan_rollout(rollout, collect_paths=args.include_local_assets or args.include_generated_images)
    rollout_rel = rollout_relative_path(rollout)
    rollout_hash = sha256_file(rollout)
    attachments = []
    attachment_paths = candidate_attachment_paths(
        paths,
        str(row.get("cwd") or ""),
        args.include_local_assets,
        args.include_generated_images,
        args.max_attachment_bytes,
    )
    for path in attachment_paths:
        digest = sha256_file(path)
        archive_name = f"attachments/files/{digest[:16]}/{path.name}"
        attachments.append({
            "original_path": str(path),
            "archive_path": archive_name,
            "sha256": digest,
            "size_bytes": path.stat().st_size,
        })

    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    exported_at = utc_now().isoformat(timespec="seconds").replace("+00:00", "Z")
    manifest = {
        "format_version": FORMAT_VERSION,
        "package_type": PACKAGE_TYPE,
        "exported_at": exported_at,
        "source": {
            "account_name": args.account_name,
            "account_home_name": home.name,
        },
        "thread": {
            "id": thread_id,
            "title": best_thread_title(row),
            "created_at": iso_from_ms(row.get("created_at_ms")) or iso_from_seconds(row.get("created_at")),
            "updated_at": iso_from_ms(marker_ms(row)),
            "cwd": str(row.get("cwd") or ""),
            "model_provider": str(row.get("model_provider") or ""),
            "model": str(row.get("model") or ""),
            "rollout_relative_path": rollout_rel,
            "rollout_sha256": rollout_hash,
            "rollout_size_bytes": rollout.stat().st_size,
        },
        "included": {
            "conversation_rollout": True,
            "thread_state": True,
            "compacted_context_inside_rollout": True,
            "goals": bool(state["goals_rows"]),
            "generated_images": bool(args.include_generated_images and attachment_paths),
            "referenced_local_assets": bool(args.include_local_assets and attachment_paths),
            "auth_or_cookies": False,
            "codex_config": False,
            "full_workspace_snapshot": False,
            "global_memories": False,
        },
        "privacy_scan": {
            "counts": scan_counts,
            "warnings": warnings,
        },
        "import_recommendation": {
            "target": "all_profiles",
            "mark_as_latest": True,
            "requires_codex_restart": False,
        },
    }
    if attachments:
        manifest["attachments"] = attachments

    compression_level = max(0, min(int(getattr(args, "compression_level", 6)), 9))
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=compression_level) as archive:
        archive.writestr("manifest.json", json_dumps(manifest))
        archive.writestr("state/thread.json", json_dumps(state))
        archive.write(rollout, f"sessions/{rollout_rel}")
        for item, path in zip(attachments, attachment_paths):
            archive.write(path, item["archive_path"])

    print(f"package={output}")
    print(f"thread_id={thread_id}")
    print(f"title={manifest['thread']['title']}")
    print(f"rollout_size_bytes={manifest['thread']['rollout_size_bytes']}")
    print(f"secret_like_lines={scan_counts['secret_like_lines']}")
    print(f"absolute_path_lines={scan_counts['absolute_path_lines']}")
    print(f"attachments={len(attachments)}")
    for warning in warnings:
        print(f"warning={warning}")
    return 0


def read_package(zip_path):
    if not zip_path.exists():
        raise SystemExit(f"Package not found: {zip_path}")
    try:
        archive = zipfile.ZipFile(zip_path, "r")
    except zipfile.BadZipFile as exc:
        raise SystemExit(f"Not a valid .codexshare package: {exc}")
    try:
        manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
        state = json.loads(archive.read("state/thread.json").decode("utf-8"))
    except (KeyError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        archive.close()
        raise SystemExit(f"Package is missing required metadata: {exc}")
    if manifest.get("package_type") != PACKAGE_TYPE or int(manifest.get("format_version") or 0) != FORMAT_VERSION:
        archive.close()
        raise SystemExit("Unsupported package format.")
    return archive, manifest, state


def inspect_package(args):
    zip_path = Path(args.package).expanduser()
    archive, manifest, _ = read_package(zip_path)
    try:
        print(f"package={zip_path}")
        print(f"format_version={manifest.get('format_version')}")
        print(f"thread_id={manifest.get('thread', {}).get('id', '')}")
        print(f"title={manifest.get('thread', {}).get('title', '')}")
        print(f"exported_at={manifest.get('exported_at', '')}")
        print(f"updated_at={manifest.get('thread', {}).get('updated_at', '')}")
        print(f"rollout_size_bytes={manifest.get('thread', {}).get('rollout_size_bytes', 0)}")
        counts = manifest.get("privacy_scan", {}).get("counts", {})
        for key in ("secret_like_lines", "absolute_path_lines", "ssh_or_host_lines", "env_or_config_lines"):
            print(f"{key}={counts.get(key, 0)}")
        included = manifest.get("included", {})
        print(f"generated_images={included.get('generated_images', False)}")
        print(f"referenced_local_assets={included.get('referenced_local_assets', False)}")
        for warning in manifest.get("privacy_scan", {}).get("warnings", []):
            print(f"warning={warning}")
    finally:
        archive.close()
    return 0


def backup_file(path, backup_root, label):
    if not path.exists():
        return
    target = backup_root / label
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        if path.is_file():
            shutil.copy2(path, target)
        elif path.is_dir():
            shutil.copytree(path, target, dirs_exist_ok=True)
    except OSError:
        pass


def backup_sqlite(db_path, backup_root, home):
    if not db_path.exists():
        return
    try:
        rel = db_path.relative_to(home)
    except ValueError:
        rel = Path(db_path.name)
    target = backup_root / "sqlite" / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
        dest = sqlite3.connect(target, timeout=5)
        source.backup(dest)
        dest.close()
        source.close()
    except sqlite3.Error:
        try:
            shutil.copy2(db_path, target)
        except OSError:
            pass


def upsert_row(con, table, row, key_columns):
    cols = table_columns(con, table)
    if not cols:
        return False
    write_cols = [col for col in cols if col in row]
    if not write_cols:
        return False
    where = " AND ".join(f'"{col}" = ?' for col in key_columns)
    params = tuple(row.get(col) for col in key_columns)
    existing = con.execute(f'SELECT 1 FROM "{table}" WHERE {where} LIMIT 1', params).fetchone()
    if existing:
        update_cols = [col for col in write_cols if col not in key_columns]
        if update_cols:
            assignments = ", ".join(f'"{col}" = ?' for col in update_cols)
            values = tuple(row.get(col) for col in update_cols) + params
            con.execute(f'UPDATE "{table}" SET {assignments} WHERE {where}', values)
    else:
        placeholders = ", ".join("?" for _ in write_cols)
        col_sql = ", ".join(f'"{col}"' for col in write_cols)
        values = tuple(row.get(col) for col in write_cols)
        con.execute(f'INSERT INTO "{table}" ({col_sql}) VALUES ({placeholders})', values)
    return True


def delete_related_rows(con, thread_id):
    related_columns = {
        "thread_dynamic_tools": ("thread_id",),
        "thread_spawn_edges": ("parent_thread_id", "child_thread_id"),
        "agent_jobs": ("thread_id", "assigned_thread_id"),
        "agent_job_items": ("thread_id", "assigned_thread_id"),
    }
    for table, candidates in related_columns.items():
        cols = table_columns(con, table)
        if not cols:
            continue
        predicates = []
        params = []
        for col in candidates:
            if col in cols:
                predicates.append(f'"{col}" = ?')
                params.append(thread_id)
        if predicates:
            con.execute(f'DELETE FROM "{table}" WHERE {" OR ".join(predicates)}', tuple(params))


def insert_related_rows(con, related_rows):
    for table, rows in related_rows.items():
        cols = table_columns(con, table)
        if not cols:
            continue
        for row in rows:
            write_cols = [col for col in cols if col in row]
            if not write_cols:
                continue
            placeholders = ", ".join("?" for _ in write_cols)
            col_sql = ", ".join(f'"{col}"' for col in write_cols)
            values = tuple(row.get(col) for col in write_cols)
            con.execute(f'INSERT INTO "{table}" ({col_sql}) VALUES ({placeholders})', values)


def update_session_index(home, thread_id, title, updated_iso):
    index_path = home / "session_index.jsonl"
    if index_path.is_symlink():
        index_path = index_path.resolve()
    records = []
    if index_path.exists():
        try:
            with index_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        records.append(line)
                        continue
                    if str(record.get("id") or "") == thread_id:
                        continue
                    records.append(record)
        except OSError:
            records = []
    fresh = {"id": thread_id, "thread_name": title or "Untitled", "updated_at": updated_iso}
    tmp = index_path.with_name(f".{index_path.name}.tmp-{os.getpid()}")
    with tmp.open("w", encoding="utf-8") as handle:
        handle.write(compact_json_line(fresh) + "\n")
        for record in records:
            if isinstance(record, str):
                handle.write(record + "\n")
            else:
                handle.write(compact_json_line(record) + "\n")
    os.replace(tmp, index_path)


def update_global_state(home, thread_id, title, cwd):
    state_path = home / ".codex-global-state.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
    except (OSError, json.JSONDecodeError):
        state = {}
    if not isinstance(state, dict):
        state = {}
    metadata = state.get("sidebar-thread-metadata")
    if not isinstance(metadata, dict):
        metadata = {}
    metadata[thread_id] = {
        "thread_name": title or "Untitled",
        "imported_by_codex_accounts": True,
        "imported_at_ms": int(time.time() * 1000),
    }
    state["sidebar-thread-metadata"] = metadata
    if not cwd or not Path(str(cwd)).exists():
        ids = state.get("projectless-thread-ids")
        if not isinstance(ids, list):
            ids = []
        ids = [item for item in ids if str(item) != thread_id]
        state["projectless-thread-ids"] = [thread_id] + ids
    tmp = state_path.with_name(f".{state_path.name}.tmp-{os.getpid()}")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(tmp, state_path)


def extract_attachments(archive, manifest, home, thread_id):
    attachments = manifest.get("attachments") or []
    if not attachments:
        return 0
    root = home / "imported_codexshare_assets" / thread_id
    count = 0
    for item in attachments:
        archive_path = item.get("archive_path")
        if not archive_path:
            continue
        target = root / Path(archive_path).name
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            with archive.open(archive_path) as source, target.open("wb") as dest:
                shutil.copyfileobj(source, dest)
            count += 1
        except (KeyError, OSError):
            continue
    return count


def import_into_home(
    archive,
    manifest,
    state,
    home,
    account_name,
    mark_latest,
    backup_base=None,
    restore_attachments=True,
    verified_rollouts=None,
):
    home.mkdir(parents=True, exist_ok=True)
    db_path = state_db_path(home)
    if not db_path.exists():
        return {"account": account_name, "home": str(home), "status": "skipped", "reason": "state_5.sqlite not found"}

    thread = manifest["thread"]
    thread_id = thread["id"]
    title = thread.get("title") or "Untitled"
    backup_name = f"codexshare-import-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{thread_id[:8]}"
    if backup_base:
        safe_account = re.sub(r"[^A-Za-z0-9._-]+", "_", account_name) or "account"
        backup_root = Path(backup_base).expanduser() / safe_account / backup_name
    else:
        backup_root = home / "backups" / backup_name
    backup_sqlite(db_path, backup_root, home)
    backup_file(home / "session_index.jsonl", backup_root, "session_index.jsonl")
    backup_file(home / ".codex-global-state.json", backup_root, ".codex-global-state.json")

    rollout_rel = thread.get("rollout_relative_path") or Path(thread_id).name
    rollout_member = f"sessions/{rollout_rel}"
    target_rollout = home / "sessions" / rollout_rel
    target_rollout.parent.mkdir(parents=True, exist_ok=True)
    expected_hash = thread.get("rollout_sha256")
    rollout_key = str(target_rollout.resolve(strict=False))
    verified_rollouts = verified_rollouts if verified_rollouts is not None else set()
    rollout_ready = rollout_key in verified_rollouts
    if not rollout_ready and target_rollout.exists() and expected_hash:
        rollout_ready = sha256_file(target_rollout) == expected_hash
    if not rollout_ready:
        if target_rollout.exists():
            backup_file(target_rollout, backup_root, f"existing-rollouts/{target_rollout.name}")
        tmp_rollout = target_rollout.with_name(f".{target_rollout.name}.tmp-import-{os.getpid()}")
        try:
            with archive.open(rollout_member) as source, tmp_rollout.open("wb") as dest:
                shutil.copyfileobj(source, dest)
                dest.flush()
                os.fsync(dest.fileno())
            if expected_hash and sha256_file(tmp_rollout) != expected_hash:
                raise SystemExit(f"Checksum failed after extracting rollout for {account_name}")
            os.replace(tmp_rollout, target_rollout)
        finally:
            try:
                tmp_rollout.unlink()
            except FileNotFoundError:
                pass
        rollout_ready = True
    if rollout_ready:
        verified_rollouts.add(rollout_key)

    imported_assets = extract_attachments(archive, manifest, home, thread_id) if restore_attachments else 0
    now = utc_now()
    now_ms = int(now.timestamp() * 1000)
    now_s = now_ms // 1000
    now_iso = now.isoformat(timespec="microseconds").replace("+00:00", "Z")

    row = dict(state["thread_row"])
    row["id"] = thread_id
    row["rollout_path"] = str(target_rollout)
    row["archived"] = 0
    if mark_latest:
        for key in ("updated_at", "recency_at"):
            if key in row:
                row[key] = now_s
        for key in ("updated_at_ms", "recency_at_ms"):
            if key in row:
                row[key] = now_ms
    if "title" in row:
        row["title"] = title

    con = sqlite3.connect(db_path, timeout=8)
    con.execute("PRAGMA busy_timeout=8000")
    try:
        upsert_row(con, "threads", row, ("id",))
        delete_related_rows(con, thread_id)
        insert_related_rows(con, state.get("related_rows") or {})
        con.commit()
        try:
            con.execute("PRAGMA wal_checkpoint(PASSIVE)")
        except sqlite3.Error:
            pass
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise sqlite3.Error(f"integrity_check={integrity}")
    except sqlite3.Error:
        con.rollback()
        raise
    finally:
        con.close()

    goals = state.get("goals_rows") or []
    goals_db = home / "goals_1.sqlite"
    if goals and goals_db.exists():
        gcon = sqlite3.connect(goals_db, timeout=8)
        try:
            if table_exists(gcon, "thread_goals"):
                gcon.execute("DELETE FROM thread_goals WHERE thread_id = ?", (thread_id,))
                insert_related_rows(gcon, {"thread_goals": goals})
                gcon.commit()
        finally:
            gcon.close()

    update_session_index(home, thread_id, title, now_iso if mark_latest else (thread.get("updated_at") or now_iso))
    update_global_state(home, thread_id, title, row.get("cwd"))
    return {
        "account": account_name,
        "home": str(home),
        "status": "imported",
        "backup": str(backup_root),
        "rollout": str(target_rollout),
        "assets": imported_assets,
    }


def import_package(args):
    zip_path = Path(args.package).expanduser()
    archive, manifest, state = read_package(zip_path)
    results = []
    try:
        thread = manifest.get("thread", {})
        rollout_member = f"sessions/{thread.get('rollout_relative_path', '')}"
        expected_hash = thread.get("rollout_sha256")
        digest = hashlib.sha256()
        with archive.open(rollout_member) as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        if expected_hash and digest.hexdigest() != expected_hash:
            raise SystemExit("Package rollout checksum does not match manifest.")

        verified_rollouts = set()
        for target in args.target:
            if "=" not in target:
                raise SystemExit(f"Invalid target argument: {target}")
            name, raw_home = target.split("=", 1)
            result = import_into_home(
                archive,
                manifest,
                state,
                Path(raw_home).expanduser(),
                name,
                args.mark_latest,
                backup_base=getattr(args, "backup_root", None),
                restore_attachments=not getattr(args, "skip_attachments", False),
                verified_rollouts=verified_rollouts,
            )
            results.append(result)
    finally:
        archive.close()

    imported = sum(1 for result in results if result["status"] == "imported")
    print(f"thread_id={manifest['thread']['id']}")
    print(f"title={manifest['thread'].get('title', '')}")
    print(f"imported={imported}")
    for result in results:
        print(compact_json_line(result))
    return 0 if imported else 1


def fsync_directory(path):
    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        pass


def atomic_write_bytes(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    tmp_path = Path(raw_tmp)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        fsync_directory(path.parent)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def atomic_write_json(path, value):
    atomic_write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def load_cold_index(path):
    if not path.exists():
        return {"format_version": COLD_INDEX_VERSION, "entries": {}}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Cold storage index is unreadable; refusing to overwrite it: {exc}")
    if not isinstance(value, dict) or int(value.get("format_version") or 0) != COLD_INDEX_VERSION:
        raise SystemExit("Unsupported cold storage index format.")
    if not isinstance(value.get("entries"), dict):
        raise SystemExit("Cold storage index entries are invalid.")
    return value


def save_cold_index(path, value):
    value["format_version"] = COLD_INDEX_VERSION
    atomic_write_json(path, value)


def parsed_targets(values):
    targets = []
    seen = set()
    for value in values:
        if "=" not in value:
            raise SystemExit(f"Invalid target argument: {value}")
        name, raw_home = value.split("=", 1)
        home = Path(raw_home).expanduser()
        key = str(home.resolve(strict=False))
        if key in seen:
            continue
        seen.add(key)
        targets.append((name, home))
    if not targets:
        raise SystemExit("At least one target profile is required.")
    return targets


def cold_storage_paths_are_open(targets, rollout=None):
    paths = set()
    if rollout is not None:
        paths.add(str(Path(rollout).resolve(strict=False)))
    for _, home in targets:
        db_path = state_db_path(home)
        for path in (
            db_path,
            Path(str(db_path) + "-wal"),
            Path(str(db_path) + "-shm"),
            home / "goals_1.sqlite",
            home / "goals_1.sqlite-wal",
            home / "goals_1.sqlite-shm",
            home / "session_index.jsonl",
            home / ".codex-global-state.json",
        ):
            try:
                resolved = path.resolve() if path.is_symlink() else path
            except OSError:
                resolved = path
            if resolved.exists():
                paths.add(str(resolved))
    if not paths:
        return False
    lsof = Path("/usr/sbin/lsof")
    if not lsof.is_file():
        return True
    try:
        result = subprocess.run(
            [str(lsof), "-t", *sorted(paths)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return True
    if result.stdout.strip():
        return True
    if result.returncode in (0, 1):
        return False
    return True


def require_cold_targets_offline(targets, rollout=None):
    if cold_storage_paths_are_open(targets, rollout):
        print("Codex reopened or a protected history database is in use; cold storage paused before local mutation.", file=sys.stderr)
        raise SystemExit(75)


def resolved_file(path):
    return path.resolve() if path.is_symlink() else path


def required_backup(path, backup_root, label):
    path = resolved_file(path)
    if not path.exists():
        return None
    target = backup_root / label
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    with target.open("rb") as handle:
        os.fsync(handle.fileno())
    return path, target


def restore_required_backup(target, backup):
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp-cold-rollback-{os.getpid()}")
    try:
        shutil.copy2(backup, tmp)
        with tmp.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(tmp, target)
        fsync_directory(target.parent)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def thread_row_optional(home, thread_id):
    db_path = state_db_path(home)
    if not db_path.exists():
        return None
    con = connect_ro(db_path)
    try:
        row, _ = read_row(con, "threads", "id = ?", (thread_id,))
        return row
    finally:
        con.close()


def mark_thread_cold(home, thread_id):
    db_path = state_db_path(home)
    if not db_path.exists():
        return False
    con = sqlite3.connect(db_path, timeout=8)
    con.execute("PRAGMA busy_timeout=8000")
    try:
        columns = table_columns(con, "threads")
        if "archived" not in columns or "rollout_path" not in columns:
            raise sqlite3.Error(f"threads table cannot represent cold storage in {db_path}")
        present = con.execute("SELECT 1 FROM threads WHERE id = ?", (thread_id,)).fetchone()
        if not present:
            return False
        con.execute("UPDATE threads SET archived = 1, rollout_path = '' WHERE id = ?", (thread_id,))
        con.commit()
        return True
    except sqlite3.Error:
        con.rollback()
        raise
    finally:
        con.close()


def mark_thread_hot(home, thread_id):
    db_path = state_db_path(home)
    if not db_path.exists():
        return False
    con = sqlite3.connect(db_path, timeout=8)
    con.execute("PRAGMA busy_timeout=8000")
    try:
        columns = table_columns(con, "threads")
        if "archived" not in columns:
            raise sqlite3.Error(f"threads table cannot restore archived state in {db_path}")
        present = con.execute("SELECT 1 FROM threads WHERE id = ?", (thread_id,)).fetchone()
        if not present:
            return False
        con.execute("UPDATE threads SET archived = 0 WHERE id = ?", (thread_id,))
        con.commit()
        return True
    except sqlite3.Error:
        con.rollback()
        raise
    finally:
        con.close()


def restore_thread_row(home, row):
    if not row:
        return
    db_path = state_db_path(home)
    con = sqlite3.connect(db_path, timeout=8)
    con.execute("PRAGMA busy_timeout=8000")
    try:
        upsert_row(con, "threads", row, ("id",))
        con.commit()
    except sqlite3.Error:
        con.rollback()
        raise
    finally:
        con.close()


def remove_session_index_entry(path, thread_id):
    path = resolved_file(path)
    if not path.exists():
        return False
    output = []
    removed = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            output.append(line)
            continue
        if str(value.get("id") or "") == thread_id:
            removed = True
            continue
        output.append(compact_json_line(value))
    if removed:
        payload = (("\n".join(output) + "\n") if output else "").encode("utf-8")
        atomic_write_bytes(path, payload)
    return removed


def remove_global_state_entry(path, thread_id):
    if not path.exists():
        return False
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Could not safely update {path}: {exc}")
    if not isinstance(state, dict):
        raise RuntimeError(f"Could not safely update {path}: root is not an object")
    changed = False
    metadata = state.get("sidebar-thread-metadata")
    if isinstance(metadata, dict) and thread_id in metadata:
        metadata.pop(thread_id, None)
        changed = True
    ids = state.get("projectless-thread-ids")
    if isinstance(ids, list):
        filtered = [item for item in ids if str(item) != thread_id]
        if len(filtered) != len(ids):
            state["projectless-thread-ids"] = filtered
            changed = True
    if changed:
        atomic_write_json(path, state)
    return changed


def verify_package_rollout(package_path):
    archive, manifest, state = read_package(package_path)
    try:
        thread = manifest.get("thread") or {}
        member = f"sessions/{thread.get('rollout_relative_path', '')}"
        digest = hashlib.sha256()
        with archive.open(member) as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        expected = str(thread.get("rollout_sha256") or "")
        if not expected or digest.hexdigest() != expected:
            raise SystemExit("Cold archive rollout checksum does not match its manifest.")
        return manifest, state
    finally:
        archive.close()


def restore_rollout_from_package(package_path, manifest, target):
    archive, _, _ = read_package(package_path)
    thread = manifest["thread"]
    member = f"sessions/{thread['rollout_relative_path']}"
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp-cold-rollback-{os.getpid()}")
    try:
        with archive.open(member) as source, tmp.open("wb") as dest:
            shutil.copyfileobj(source, dest)
            dest.flush()
            os.fsync(dest.fileno())
        if sha256_file(tmp) != thread["rollout_sha256"]:
            raise RuntimeError("Rollback rollout checksum failed")
        os.replace(tmp, target)
        fsync_directory(target.parent)
    finally:
        archive.close()
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def cold_archive(args):
    source_home = Path(args.account_home).expanduser()
    thread_id = args.thread_id.strip()
    state = read_thread_package_state(source_home, thread_id)
    source_row = state["thread_row"]
    rollout = Path(str(source_row.get("rollout_path") or "")).expanduser()
    if not rollout.exists() or not rollout.is_file():
        raise SystemExit(f"Rollout file not found: {rollout}")
    targets = parsed_targets(args.target)
    require_cold_targets_offline(targets, rollout)

    archive_root = Path(args.archive_root).expanduser()
    archive_root.mkdir(parents=True, exist_ok=True)
    if not os.access(archive_root, os.W_OK):
        raise SystemExit(f"Cold storage is not writable: {archive_root}")
    initial = rollout.stat()
    required = initial.st_size + max(int(args.max_attachment_bytes), 0) + 512 * 1024 * 1024
    free = shutil.disk_usage(archive_root).free
    if free < required:
        raise SystemExit(f"Cold storage needs at least {required} free bytes; only {free} are available.")

    index_path = Path(args.index).expanduser()
    cold_index = load_cold_index(index_path)
    old_entry = cold_index["entries"].get(thread_id)
    if old_entry and old_entry.get("status") == "archived" and old_entry.get("local_removed"):
        raise SystemExit(f"Thread is already in cold storage: {thread_id}")

    timestamp = utc_now().strftime("%Y%m%dT%H%M%S%fZ")
    archive_dir = archive_root / "archives" / thread_id
    staging_dir = archive_root / ".staging"
    archive_dir.mkdir(parents=True, exist_ok=True)
    staging_dir.mkdir(parents=True, exist_ok=True)
    staging_package = staging_dir / f".{thread_id}-{timestamp}-{os.getpid()}.codexshare.part"
    final_package = archive_dir / f"{thread_id}-{timestamp}.codexshare"

    export_args = argparse.Namespace(
        account_name=args.account_name,
        account_home=str(source_home),
        thread_id=thread_id,
        output=str(staging_package),
        include_generated_images=args.include_generated_images,
        include_local_assets=args.include_local_assets,
        max_attachment_bytes=args.max_attachment_bytes,
        compression_level=args.compression_level,
    )
    try:
        export_package(export_args)
        with staging_package.open("rb") as handle:
            os.fsync(handle.fileno())
        manifest, _ = verify_package_rollout(staging_package)
        current = rollout.stat()
        identity = (initial.st_dev, initial.st_ino, initial.st_size, initial.st_mtime_ns)
        current_identity = (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
        if current_identity != identity:
            raise RuntimeError("Rollout changed while the cold archive was being created")
        require_cold_targets_offline(targets, rollout)
        os.replace(staging_package, final_package)
        fsync_directory(final_package.parent)
    finally:
        try:
            staging_package.unlink()
        except FileNotFoundError:
            pass

    package_hash = sha256_file(final_package)
    package_size = final_package.stat().st_size
    try:
        require_cold_targets_offline(targets, rollout)
    except SystemExit:
        try:
            final_package.unlink()
            fsync_directory(final_package.parent)
        except FileNotFoundError:
            pass
        raise
    snapshots = []
    for name, home in targets:
        row = thread_row_optional(home, thread_id)
        if row is not None:
            snapshots.append({"name": name, "home": str(home), "row": row})
    if not snapshots:
        raise SystemExit("Thread was not found in any target profile; local data was not changed.")

    recovery_root = archive_dir / "recovery" / timestamp
    recovery_root.mkdir(parents=True, exist_ok=True)
    file_backups = []
    seen_files = set()
    for snapshot in snapshots:
        home = Path(snapshot["home"])
        for source_path, label in (
            (home / "session_index.jsonl", "session-index"),
            (home / ".codex-global-state.json", f"global-state-{re.sub(r'[^A-Za-z0-9._-]+', '_', snapshot['name'])}"),
        ):
            resolved = resolved_file(source_path)
            key = str(resolved)
            if key in seen_files or not resolved.exists():
                continue
            seen_files.add(key)
            suffix = hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]
            backup = required_backup(resolved, recovery_root, f"files/{label}-{suffix}")
            if backup:
                file_backups.append(backup)

    journal = {
        "format_version": COLD_INDEX_VERSION,
        "thread_id": thread_id,
        "created_at": utc_now().isoformat(timespec="seconds").replace("+00:00", "Z"),
        "rollout_path": str(rollout),
        "rollout_identity": list((initial.st_dev, initial.st_ino, initial.st_size, initial.st_mtime_ns)),
        "package_path": str(final_package),
        "package_sha256": package_hash,
        "targets": snapshots,
        "file_backups": [{"target": str(target), "backup": str(backup)} for target, backup in file_backups],
    }
    atomic_write_json(recovery_root / "archive-journal.json", journal)

    entry = {
        "thread_id": thread_id,
        "title": manifest["thread"].get("title") or "Untitled",
        "updated_at": manifest["thread"].get("updated_at") or "",
        "archived_at": utc_now().isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source_account": args.account_name,
        "package_path": str(final_package),
        "package_sha256": package_hash,
        "package_size_bytes": package_size,
        "rollout_size_bytes": initial.st_size,
        "recovery_path": str(recovery_root),
        "status": "prepared",
        "local_removed": False,
    }
    cold_index["entries"][thread_id] = entry
    save_cold_index(index_path, cold_index)

    try:
        for snapshot in snapshots:
            mark_thread_cold(Path(snapshot["home"]), thread_id)
        for target, _ in file_backups:
            if target.name == "session_index.jsonl":
                remove_session_index_entry(target, thread_id)
        for snapshot in snapshots:
            remove_global_state_entry(Path(snapshot["home"]) / ".codex-global-state.json", thread_id)

        current = rollout.stat()
        current_identity = (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
        if current_identity != tuple(journal["rollout_identity"]):
            raise RuntimeError("Rollout changed before local removal")
        rollout.unlink()
        fsync_directory(rollout.parent)

        entry["status"] = "archived"
        entry["local_removed"] = True
        entry["completed_at"] = utc_now().isoformat(timespec="seconds").replace("+00:00", "Z")
        save_cold_index(index_path, cold_index)
    except Exception as exc:
        rollback_errors = []
        try:
            if not rollout.exists():
                restore_rollout_from_package(final_package, manifest, rollout)
        except Exception as rollback_exc:
            rollback_errors.append(f"rollout={rollback_exc}")
        for snapshot in snapshots:
            try:
                restore_thread_row(Path(snapshot["home"]), snapshot["row"])
            except Exception as rollback_exc:
                rollback_errors.append(f"sqlite:{snapshot['name']}={rollback_exc}")
        for target, backup in file_backups:
            try:
                restore_required_backup(target, backup)
            except Exception as rollback_exc:
                rollback_errors.append(f"file:{target}={rollback_exc}")
        entry["status"] = "failed"
        entry["local_removed"] = not rollout.exists()
        entry["error"] = str(exc)[:500]
        try:
            save_cold_index(index_path, cold_index)
        except Exception as index_exc:
            rollback_errors.append(f"index={index_exc}")
        detail = f"; rollback issues: {', '.join(rollback_errors)}" if rollback_errors else ""
        raise SystemExit(f"Cold archive failed and local state was rolled back: {exc}{detail}")

    print(f"cold_archive={final_package}")
    print(f"thread_id={thread_id}")
    print(f"freed_bytes={initial.st_size}")
    print(f"package_size_bytes={package_size}")
    print(f"package_sha256={package_hash}")
    return 0


def list_cold_archives(args):
    index_path = Path(args.index).expanduser()
    cold_index = load_cold_index(index_path)
    entries = [
        value for value in cold_index["entries"].values()
        if value.get("status") == "archived" and value.get("local_removed")
    ]
    entries.sort(key=lambda value: str(value.get("archived_at") or ""), reverse=True)
    for entry in entries:
        package_path = Path(str(entry.get("package_path") or "")).expanduser()
        fields = [
            str(entry.get("thread_id") or ""),
            compact_text(entry.get("title")).replace("\t", " "),
            str(entry.get("updated_at") or ""),
            str(entry.get("archived_at") or ""),
            str(entry.get("rollout_size_bytes") or 0),
            str(entry.get("package_size_bytes") or 0),
            str(package_path).replace("\t", " "),
            "1" if package_path.is_file() else "0",
            str(entry.get("status") or ""),
        ]
        print("\t".join(fields))
    return 0


def cold_restore(args):
    index_path = Path(args.index).expanduser()
    cold_index = load_cold_index(index_path)
    entry = cold_index["entries"].get(args.thread_id)
    if not entry or entry.get("status") != "archived" or not entry.get("local_removed"):
        raise SystemExit(f"Thread is not currently in cold storage: {args.thread_id}")
    package_path = Path(str(entry.get("package_path") or "")).expanduser()
    if not package_path.is_file():
        raise SystemExit(f"Cold archive is offline or missing: {package_path}")
    actual_hash = sha256_file(package_path)
    if actual_hash != entry.get("package_sha256"):
        raise SystemExit("Cold archive package checksum failed; local state was not changed.")
    manifest, _ = verify_package_rollout(package_path)
    if str(manifest.get("thread", {}).get("id") or "") != args.thread_id:
        raise SystemExit("Cold archive thread ID does not match the index.")

    targets = parsed_targets(args.target)
    require_cold_targets_offline(targets)
    first_home = targets[0][1]
    sessions_parent = first_home / "sessions"
    sessions_parent.mkdir(parents=True, exist_ok=True)
    required = int(manifest["thread"].get("rollout_size_bytes") or 0) + 512 * 1024 * 1024
    free = shutil.disk_usage(sessions_parent.resolve()).free
    if free < required:
        raise SystemExit(f"Restore needs at least {required} free bytes internally; only {free} are available.")

    timestamp = utc_now().strftime("%Y%m%dT%H%M%S%fZ")
    backup_root = package_path.parent / "restore-recovery" / timestamp
    import_args = argparse.Namespace(
        package=str(package_path),
        target=args.target,
        mark_latest=args.mark_latest,
        backup_root=str(backup_root),
        skip_attachments=True,
    )
    require_cold_targets_offline(targets)
    result = import_package(import_args)
    if result != 0:
        return result
    for _, home in targets:
        mark_thread_hot(home, args.thread_id)
    entry["status"] = "restored"
    entry["local_removed"] = False
    entry["restored_at"] = utc_now().isoformat(timespec="seconds").replace("+00:00", "Z")
    entry["restore_recovery_path"] = str(backup_root)
    save_cold_index(index_path, cold_index)
    print(f"cold_restored={package_path}")
    print("external_archive_retained=1")
    return 0


def protected_cold_thread_ids(targets):
    protected = set()
    uuid_re = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
    completed_statuses = {"complete", "completed", "achieved", "cancelled", "canceled"}
    for _, home in targets:
        db_path = state_db_path(home)
        if db_path.exists():
            try:
                con = connect_ro(db_path)
                columns = table_columns(con, "threads")
                if "is_pinned" in columns:
                    protected.update(
                        str(row[0]) for row in con.execute(
                            "SELECT id FROM threads WHERE COALESCE(is_pinned, 0) != 0"
                        )
                    )
                con.close()
            except sqlite3.Error:
                pass

        goals_db = home / "goals_1.sqlite"
        if goals_db.exists():
            try:
                con = connect_ro(goals_db)
                columns = table_columns(con, "thread_goals")
                if "thread_id" in columns:
                    if "status" in columns:
                        for thread_id, status in con.execute("SELECT thread_id, status FROM thread_goals"):
                            if str(status or "").strip().lower() not in completed_statuses:
                                protected.add(str(thread_id))
                    else:
                        protected.update(str(row[0]) for row in con.execute("SELECT thread_id FROM thread_goals"))
                con.close()
            except sqlite3.Error:
                pass

        automation_root = home / "automations"
        if automation_root.is_dir():
            for config_path in automation_root.glob("*/automation.toml"):
                try:
                    text = config_path.read_text(encoding="utf-8")
                except OSError:
                    continue
                status_match = re.search(r'(?mi)^status\s*=\s*"([^"]+)"', text)
                status = status_match.group(1).strip().lower() if status_match else "active"
                if status not in {"disabled", "inactive", "deleted"}:
                    protected.update(uuid_re.findall(text))
    return protected


def cold_candidates(args):
    home = Path(args.account_home).expanduser()
    targets = parsed_targets(args.target)
    protected = protected_cold_thread_ids(targets)
    db_path = state_db_path(home)
    if not db_path.exists():
        return 0
    con = connect_ro(db_path)
    columns = table_columns(con, "threads")
    if not columns:
        con.close()
        return 0
    query_columns = ", ".join(f'"{column}"' for column in columns)
    cutoff_ms = int((time.time() - max(float(args.older_than_days), 0) * 86400) * 1000)
    rows = []
    for values in con.execute(f"SELECT {query_columns} FROM threads"):
        row = dict(zip(columns, values))
        thread_id = str(row.get("id") or "")
        if not thread_id or thread_id in protected:
            continue
        rollout = Path(str(row.get("rollout_path") or "")).expanduser()
        if not rollout.is_file():
            continue
        updated_ms = marker_ms(row)
        try:
            updated_ms = max(updated_ms, int(rollout.stat().st_mtime * 1000))
        except OSError:
            continue
        if updated_ms <= 0 or updated_ms > cutoff_ms:
            continue
        row["_cold_updated_ms"] = updated_ms
        row["_cold_size"] = rollout.stat().st_size
        rows.append(row)
    con.close()
    rows.sort(key=lambda row: int(row.get("_cold_updated_ms") or 0))
    for row in rows:
        thread_id = str(row.get("id") or "")
        if args.ids_only:
            print(thread_id)
            continue
        fields = [
            thread_id,
            best_thread_title(row).replace("\t", " "),
            iso_from_ms(row.get("_cold_updated_ms")),
            str(row.get("cwd") or "").replace("\t", " "),
            str(row.get("_cold_size") or 0),
        ]
        print("\t".join(fields))
    return 0


def cold_archive_many(args):
    archived = []
    failed = []
    for thread_id in args.thread_id:
        child = argparse.Namespace(
            account_name=args.account_name,
            account_home=args.account_home,
            thread_id=thread_id,
            archive_root=args.archive_root,
            index=args.index,
            target=args.target,
            include_generated_images=args.include_generated_images,
            include_local_assets=args.include_local_assets,
            max_attachment_bytes=args.max_attachment_bytes,
            compression_level=args.compression_level,
        )
        details = io.StringIO()
        try:
            with contextlib.redirect_stdout(details):
                cold_archive(child)
            archived.append(thread_id)
            print(f"archived={thread_id}")
        except SystemExit as exc:
            if exc.code == 75:
                print(f"paused={thread_id}\tCodex is open")
                return 75
            failed.append((thread_id, str(exc) or exc.__class__.__name__))
            print(f"failed={thread_id}\t{compact_text(str(exc))}")
        except Exception as exc:
            failed.append((thread_id, str(exc) or exc.__class__.__name__))
            print(f"failed={thread_id}\t{compact_text(str(exc))}")
    print(f"batch_archived={len(archived)}")
    print(f"batch_failed={len(failed)}")
    return 0 if not failed else 1


def cold_restore_many(args):
    restored = []
    failed = []
    for thread_id in args.thread_id:
        child = argparse.Namespace(
            thread_id=thread_id,
            index=args.index,
            target=args.target,
            mark_latest=args.mark_latest,
        )
        details = io.StringIO()
        try:
            with contextlib.redirect_stdout(details):
                result = cold_restore(child)
            if result != 0:
                raise RuntimeError(f"restore returned {result}")
            restored.append(thread_id)
            print(f"restored={thread_id}")
        except SystemExit as exc:
            if exc.code == 75:
                print(f"paused={thread_id}\tCodex is open")
                return 75
            failed.append((thread_id, str(exc) or exc.__class__.__name__))
            print(f"failed={thread_id}\t{compact_text(str(exc))}")
        except Exception as exc:
            failed.append((thread_id, str(exc) or exc.__class__.__name__))
            print(f"failed={thread_id}\t{compact_text(str(exc))}")
    print(f"batch_restored={len(restored)}")
    print(f"batch_failed={len(failed)}")
    return 0 if not failed else 1


def main(argv):
    parser = argparse.ArgumentParser(description="Codex conversation share package helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list")
    p.add_argument("--account-name", required=True)
    p.add_argument("--account-home", required=True)
    p.add_argument("--limit", type=int, default=30)
    p.set_defaults(func=list_threads)

    p = sub.add_parser("export")
    p.add_argument("--account-name", required=True)
    p.add_argument("--account-home", required=True)
    p.add_argument("--thread-id", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--include-generated-images", action="store_true")
    p.add_argument("--include-local-assets", action="store_true")
    p.add_argument("--max-attachment-bytes", type=int, default=50 * 1024 * 1024)
    p.add_argument("--compression-level", type=int, default=6)
    p.set_defaults(func=export_package)

    p = sub.add_parser("inspect")
    p.add_argument("--package", required=True)
    p.set_defaults(func=inspect_package)

    p = sub.add_parser("import")
    p.add_argument("--package", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--mark-latest", action="store_true")
    p.add_argument("--backup-root")
    p.add_argument("--skip-attachments", action="store_true")
    p.set_defaults(func=import_package)

    p = sub.add_parser("cold-archive")
    p.add_argument("--account-name", required=True)
    p.add_argument("--account-home", required=True)
    p.add_argument("--thread-id", required=True)
    p.add_argument("--archive-root", required=True)
    p.add_argument("--index", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--include-generated-images", action="store_true")
    p.add_argument("--include-local-assets", action="store_true")
    p.add_argument("--max-attachment-bytes", type=int, default=2 * 1024 * 1024 * 1024)
    p.add_argument("--compression-level", type=int, default=1)
    p.set_defaults(func=cold_archive)

    p = sub.add_parser("cold-list")
    p.add_argument("--index", required=True)
    p.set_defaults(func=list_cold_archives)

    p = sub.add_parser("cold-restore")
    p.add_argument("--thread-id", required=True)
    p.add_argument("--index", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--mark-latest", action="store_true")
    p.set_defaults(func=cold_restore)

    p = sub.add_parser("cold-candidates")
    p.add_argument("--account-home", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--older-than-days", type=float, default=7)
    p.add_argument("--ids-only", action="store_true")
    p.set_defaults(func=cold_candidates)

    p = sub.add_parser("cold-archive-many")
    p.add_argument("--account-name", required=True)
    p.add_argument("--account-home", required=True)
    p.add_argument("--thread-id", action="append", required=True)
    p.add_argument("--archive-root", required=True)
    p.add_argument("--index", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--include-generated-images", action="store_true")
    p.add_argument("--include-local-assets", action="store_true")
    p.add_argument("--max-attachment-bytes", type=int, default=2 * 1024 * 1024 * 1024)
    p.add_argument("--compression-level", type=int, default=1)
    p.set_defaults(func=cold_archive_many)

    p = sub.add_parser("cold-restore-many")
    p.add_argument("--thread-id", action="append", required=True)
    p.add_argument("--index", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--mark-latest", action="store_true")
    p.set_defaults(func=cold_restore_many)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
