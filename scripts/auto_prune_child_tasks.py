#!/usr/bin/env python3
"""Emergency low-disk cleanup for completed or stale Codex child tasks."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TERMINAL_EVENT_TYPES = {"task_complete", "task_completed", "turn_complete", "turn_completed"}
TERMINAL_EDGE_STATUSES = {"complete", "completed", "closed", "done", "failed", "cancelled", "canceled", "interrupted"}


def env_int(name: str, default: int, minimum: int = 0) -> int:
    try:
        return max(minimum, int(os.environ.get(name, str(default))))
    except (TypeError, ValueError):
        return default


THRESHOLD_BYTES = env_int("CODEX_AUTO_PRUNE_THRESHOLD_BYTES", 10_000_000_000, 1)
TARGET_BYTES = max(THRESHOLD_BYTES, env_int("CODEX_AUTO_PRUNE_TARGET_BYTES", 20_000_000_000, 1))
MIN_AGE_SECONDS = env_int("CODEX_AUTO_PRUNE_MIN_AGE_SECONDS", 3_600, 900)
MAX_DELETE_COUNT = env_int("CODEX_AUTO_PRUNE_MAX_DELETE_COUNT", 32, 1)
DRY_RUN = os.environ.get("CODEX_AUTO_PRUNE_DRY_RUN", "0") == "1"

HOME = Path.home()
ACCOUNTS_ROOT = Path(os.environ.get("CODEX_AUTO_PRUNE_ACCOUNTS_ROOT", HOME / ".codex-accounts")).expanduser()
SHARED_ROOT = Path(os.environ.get("SHARED_HISTORY_ROOT", HOME / ".codex-shared-history")).expanduser()
SESSIONS_ROOT = Path(os.environ.get("SHARED_SESSIONS_DIR", SHARED_ROOT / "sessions")).expanduser()
INDEX_PATH = Path(os.environ.get("SHARED_SESSION_INDEX_FILE", SHARED_ROOT / "session_index.jsonl")).expanduser()
APP_DATA_ROOT = Path(os.environ.get("CODEX_AUTO_PRUNE_APP_DATA_ROOT", HOME / "Library/Application Support/Codex Accounts")).expanduser()
LOG_PATH = APP_DATA_ROOT / "Logs" / "auto-child-task-cleanup.log"
LOCK_PATH = APP_DATA_ROOT / ".auto-child-task-cleanup.lock"


@dataclass(frozen=True)
class Rollout:
    thread_id: str
    parent_id: str | None
    path: Path
    size: int
    mtime: float
    is_subagent: bool


def available_bytes(path: Path) -> int:
    stat = os.statvfs(path)
    return stat.f_bavail * stat.f_frsize


def rotate_log() -> None:
    try:
        if LOG_PATH.stat().st_size <= 1_000_000:
            return
        rotated = LOG_PATH.with_suffix(LOG_PATH.suffix + ".1")
        rotated.unlink(missing_ok=True)
        LOG_PATH.replace(rotated)
    except OSError:
        pass


def log(message: str) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        rotate_log()
        stamp = time.strftime("%Y-%m-%d %H:%M:%S%z")
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(f"{stamp} {message}\n")
    except OSError:
        pass


def acquire_lock() -> int | None:
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        return os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        try:
            if time.time() - LOCK_PATH.stat().st_mtime > 1_800:
                LOCK_PATH.unlink()
                return os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except OSError:
            pass
    return None


def release_lock(fd: int) -> None:
    try:
        os.close(fd)
    finally:
        try:
            LOCK_PATH.unlink()
        except OSError:
            pass


def read_rollout(path: Path) -> Rollout | None:
    if path.is_symlink() or not path.is_file():
        return None
    try:
        stat = path.stat()
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            first_line = handle.readline(4_194_304)
        record = json.loads(first_line)
        if record.get("type") != "session_meta":
            return None
        payload = record.get("payload") or {}
        thread_id = str(payload.get("id") or "")
        if not UUID_RE.fullmatch(thread_id):
            return None
        source = payload.get("source")
        subagent = source.get("subagent") if isinstance(source, dict) else None
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        parent_id = str(spawn.get("parent_thread_id") or "") if isinstance(spawn, dict) else ""
        is_subagent = bool(parent_id and UUID_RE.fullmatch(parent_id))
        return Rollout(thread_id, parent_id or None, path, stat.st_size, stat.st_mtime, is_subagent)
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None


def scan_rollouts() -> dict[str, Rollout]:
    records: dict[str, Rollout] = {}
    if not SESSIONS_ROOT.is_dir():
        return records
    for path in SESSIONS_ROOT.rglob("rollout-*.jsonl"):
        record = read_rollout(path)
        if record is None:
            continue
        previous = records.get(record.thread_id)
        if previous is None or record.size > previous.size:
            records[record.thread_id] = record
    return records


def state_database_paths() -> list[Path]:
    paths = [HOME / ".codex/state_5.sqlite", HOME / ".codex/sqlite/state_5.sqlite"]
    if ACCOUNTS_ROOT.is_dir():
        paths.extend(ACCOUNTS_ROOT.glob("*/state_5.sqlite"))
        paths.extend(ACCOUNTS_ROOT.glob("*/sqlite/state_5.sqlite"))
    unique: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        if not path.is_file():
            continue
        key = str(path.resolve(strict=False))
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def table_exists(connection: sqlite3.Connection, table: str) -> bool:
    return connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone() is not None


def state_markers(database_paths: list[Path]) -> tuple[set[str], dict[str, str]]:
    archived: set[str] = set()
    edge_status: dict[str, str] = {}
    for path in database_paths:
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
            connection.execute("PRAGMA busy_timeout=1000")
            if table_exists(connection, "threads"):
                archived.update(str(row[0]) for row in connection.execute("SELECT id FROM threads WHERE archived=1"))
            if table_exists(connection, "thread_spawn_edges"):
                for thread_id, status in connection.execute("SELECT child_thread_id,status FROM thread_spawn_edges"):
                    normalized = str(status or "").lower()
                    if normalized in TERMINAL_EDGE_STATUSES:
                        edge_status[str(thread_id)] = normalized
        except sqlite3.Error:
            pass
        finally:
            if connection is not None:
                connection.close()
    return archived, edge_status


def has_terminal_event(path: Path) -> bool:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            start = max(0, size - 8_388_608)
            handle.seek(start)
            payload = handle.read()
        if start:
            _, _, payload = payload.partition(b"\n")
        last_started = -1
        last_terminal = -1
        for position, raw_line in enumerate(payload.splitlines()):
            try:
                record = json.loads(raw_line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if record.get("type") != "event_msg":
                continue
            event_type = str((record.get("payload") or {}).get("type") or "")
            if event_type == "task_started":
                last_started = position
            elif event_type in TERMINAL_EVENT_TYPES:
                last_terminal = position
        return last_terminal > last_started
    except OSError:
        return False


def open_paths(paths: list[Path]) -> set[Path]:
    if not paths:
        return set()
    lsof = Path("/usr/sbin/lsof")
    if not lsof.exists():
        return set(paths)
    opened: set[Path] = set()
    for offset in range(0, len(paths), 40):
        batch = paths[offset : offset + 40]
        try:
            result = subprocess.run(
                [str(lsof), "-Fn", "--", *(str(path) for path in batch)],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            opened.update(batch)
            continue
        if result.returncode not in (0, 1):
            opened.update(batch)
            continue
        names = {line[1:] for line in result.stdout.splitlines() if line.startswith("n")}
        opened.update(path for path in batch if str(path) in names)
    return opened


def safe_candidates(records: dict[str, Rollout], archived: set[str], edge_status: dict[str, str]) -> list[tuple[int, Rollout, str]]:
    now = time.time()
    children_by_parent: dict[str, list[Rollout]] = defaultdict(list)
    for record in records.values():
        if record.is_subagent and record.parent_id:
            children_by_parent[record.parent_id].append(record)
    terminal_ids = {
        record.thread_id
        for record in records.values()
        if record.is_subagent and now - record.mtime >= 900 and has_terminal_event(record.path)
    }
    candidates: list[tuple[int, Rollout, str]] = []
    for parent_id, children in children_by_parent.items():
        newest = max(children, key=lambda item: item.mtime)
        parent = records.get(parent_id)
        for child in children:
            age = now - child.mtime
            if age < 900:
                continue
            if child.thread_id in archived:
                candidates.append((0, child, "archived"))
            elif child.thread_id in edge_status or child.thread_id in terminal_ids:
                candidates.append((0, child, "completed"))
            elif (
                age >= MIN_AGE_SECONDS
                and parent is not None
                and parent.mtime > child.mtime
                and len(children) > 1
                and child.thread_id != newest.thread_id
            ):
                candidates.append((1, child, "stale-sibling"))
    opened = open_paths([item[1].path for item in candidates])
    return sorted(
        (item for item in candidates if item[1].path not in opened),
        key=lambda item: (item[0], -item[1].size, item[1].mtime),
    )


def choose_for_target(candidates: list[tuple[int, Rollout, str]], free_before: int) -> list[tuple[int, Rollout, str]]:
    selected: list[tuple[int, Rollout, str]] = []
    estimated = free_before
    for candidate in candidates:
        if estimated >= TARGET_BYTES or len(selected) >= MAX_DELETE_COUNT:
            break
        selected.append(candidate)
        estimated += candidate[1].size
    return selected


def rewrite_index(deleted_ids: set[str]) -> int:
    if not INDEX_PATH.exists() or not deleted_ids:
        return 0
    try:
        original_mode = INDEX_PATH.stat().st_mode & 0o777
        kept: list[str] = []
        removed = 0
        with INDEX_PATH.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                    thread_id = str(record.get("id") or record.get("thread_id") or "")
                except json.JSONDecodeError:
                    thread_id = ""
                if thread_id in deleted_ids:
                    removed += 1
                else:
                    kept.append(line)
        temporary = INDEX_PATH.with_name(f".{INDEX_PATH.name}.auto-prune-{os.getpid()}")
        with temporary.open("w", encoding="utf-8") as handle:
            handle.writelines(kept)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, original_mode)
        os.replace(temporary, INDEX_PATH)
        return removed
    except OSError as error:
        log(f"index-update-failed error={error}")
        return 0


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    try:
        return {str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')}
    except sqlite3.Error:
        return set()


def clean_database_rows(database_paths: list[Path], deleted_ids: set[str]) -> int:
    if not deleted_ids:
        return 0
    placeholders = ",".join("?" for _ in deleted_ids)
    ids = tuple(deleted_ids)
    cleaned = 0
    for path in database_paths:
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(path, timeout=1)
            connection.execute("PRAGMA busy_timeout=1000")
            connection.execute("BEGIN IMMEDIATE")
            for table in ("thread_dynamic_tools", "thread_spawn_edges", "agent_job_items", "agent_jobs"):
                columns = table_columns(connection, table)
                if not columns:
                    continue
                for column in ("thread_id", "parent_thread_id", "child_thread_id", "assigned_thread_id"):
                    if column in columns:
                        connection.execute(f'DELETE FROM "{table}" WHERE "{column}" IN ({placeholders})', ids)
            if table_columns(connection, "threads"):
                connection.execute(f"DELETE FROM threads WHERE id IN ({placeholders})", ids)
            connection.commit()
            cleaned += 1
        except sqlite3.Error as error:
            if connection is not None:
                try:
                    connection.rollback()
                except sqlite3.Error:
                    pass
            log(f"database-skip path={path} error={error}")
        finally:
            if connection is not None:
                connection.close()
    return cleaned


def delete_selected(selected: list[tuple[int, Rollout, str]], database_paths: list[Path]) -> tuple[int, int, int, int]:
    opened = open_paths([item[1].path for item in selected])
    deleted_ids: set[str] = set()
    deleted_bytes = 0
    for _, record, reason in selected:
        if record.path in opened:
            log(f"skip-open id={record.thread_id}")
            continue
        try:
            resolved = record.path.resolve(strict=True)
            resolved.relative_to(SESSIONS_ROOT.resolve(strict=True))
            if resolved.is_symlink() or not resolved.is_file():
                continue
            size = resolved.stat().st_size
            resolved.unlink()
            deleted_ids.add(record.thread_id)
            deleted_bytes += size
            log(f"deleted id={record.thread_id} parent={record.parent_id} bytes={size} reason={reason}")
        except (OSError, ValueError) as error:
            log(f"delete-failed id={record.thread_id} error={error}")
    index_rows = rewrite_index(deleted_ids)
    databases = clean_database_rows(database_paths, deleted_ids)
    return len(deleted_ids), deleted_bytes, index_rows, databases


def main() -> int:
    try:
        free_before = available_bytes(HOME)
    except OSError as error:
        print(f"status=error message=free-space-check-failed error={error}")
        return 1
    if free_before >= THRESHOLD_BYTES and not DRY_RUN:
        print(f"status=not-needed free_bytes={free_before}")
        return 0
    lock_fd = acquire_lock()
    if lock_fd is None:
        print("status=busy")
        return 75
    try:
        records = scan_rollouts()
        database_paths = state_database_paths()
        archived, edge_status = state_markers(database_paths)
        candidates = safe_candidates(records, archived, edge_status)
        selected = choose_for_target(candidates, free_before)
        if not selected:
            log(f"no-safe-candidates free_bytes={free_before}")
            print(f"status=no-safe-candidates free_bytes={free_before}")
            return 0
        selected_bytes = sum(item[1].size for item in selected)
        if DRY_RUN:
            ids = ",".join(item[1].thread_id for item in selected)
            print(f"status=dry-run candidate_count={len(selected)} candidate_bytes={selected_bytes} free_bytes={free_before} ids={ids}")
            return 0
        count, deleted_bytes, index_rows, databases = delete_selected(selected, database_paths)
        free_after = available_bytes(HOME)
        log(f"complete deleted_count={count} deleted_bytes={deleted_bytes} free_before={free_before} free_after={free_after}")
        print(
            f"status=deleted deleted_count={count} deleted_bytes={deleted_bytes} "
            f"index_rows={index_rows} databases={databases} free_before={free_before} free_after={free_after}"
        )
        return 0
    finally:
        release_lock(lock_fd)


if __name__ == "__main__":
    sys.exit(main())
