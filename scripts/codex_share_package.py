#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

FORMAT_VERSION = 1
PACKAGE_TYPE = "codex_conversation_share"
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
        try:
            if int(row.get("archived") or 0) != 0:
                continue
        except (TypeError, ValueError):
            continue
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

    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
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


def import_into_home(archive, manifest, state, home, account_name, mark_latest):
    home.mkdir(parents=True, exist_ok=True)
    db_path = state_db_path(home)
    if not db_path.exists():
        return {"account": account_name, "home": str(home), "status": "skipped", "reason": "state_5.sqlite not found"}

    thread = manifest["thread"]
    thread_id = thread["id"]
    title = thread.get("title") or "Untitled"
    backup_root = home / "backups" / f"codexshare-import-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{thread_id[:8]}"
    backup_sqlite(db_path, backup_root, home)
    backup_file(home / "session_index.jsonl", backup_root, "session_index.jsonl")
    backup_file(home / ".codex-global-state.json", backup_root, ".codex-global-state.json")

    rollout_rel = thread.get("rollout_relative_path") or Path(thread_id).name
    rollout_member = f"sessions/{rollout_rel}"
    target_rollout = home / "sessions" / rollout_rel
    target_rollout.parent.mkdir(parents=True, exist_ok=True)
    if target_rollout.exists():
        backup_file(target_rollout, backup_root, f"existing-rollouts/{target_rollout.name}")
    with archive.open(rollout_member) as source, target_rollout.open("wb") as dest:
        shutil.copyfileobj(source, dest)
    expected_hash = thread.get("rollout_sha256")
    if expected_hash and sha256_file(target_rollout) != expected_hash:
        raise SystemExit(f"Checksum failed after extracting rollout for {account_name}")

    imported_assets = extract_attachments(archive, manifest, home, thread_id)
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
        tmp_path = None
        try:
            with archive.open(rollout_member) as source, tempfile.NamedTemporaryFile(delete=False) as tmp:
                shutil.copyfileobj(source, tmp)
                tmp_path = Path(tmp.name)
            expected_hash = thread.get("rollout_sha256")
            if expected_hash and sha256_file(tmp_path) != expected_hash:
                raise SystemExit("Package rollout checksum does not match manifest.")
        finally:
            if tmp_path is not None:
                try:
                    tmp_path.unlink()
                except Exception:
                    pass
            else:
                pass

        for target in args.target:
            if "=" not in target:
                raise SystemExit(f"Invalid target argument: {target}")
            name, raw_home = target.split("=", 1)
            result = import_into_home(archive, manifest, state, Path(raw_home).expanduser(), name, args.mark_latest)
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
    p.set_defaults(func=export_package)

    p = sub.add_parser("inspect")
    p.add_argument("--package", required=True)
    p.set_defaults(func=inspect_package)

    p = sub.add_parser("import")
    p.add_argument("--package", required=True)
    p.add_argument("--target", action="append", required=True, help="account=home")
    p.add_argument("--mark-latest", action="store_true")
    p.set_defaults(func=import_package)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
