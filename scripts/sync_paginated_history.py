#!/usr/bin/env python3
"""Synchronize compatible paginated history snapshots for inactive shared homes."""
import os
import fcntl
import hashlib
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

TABLES = (
    "thread_turns", "thread_items", "thread_realtime_items",
    "thread_history_projection_state",
)
DB_NAME = "thread_history_1.sqlite"
# Automatic history snapshots are opt-in; shared originals stay in place.
BACKUPS_ENABLED = os.environ.get("CODEX_HISTORY_BACKUPS", "0") == "1"
BACKUPS = Path.home() / "Library/Application Support/Codex Accounts Backups"


def connect_ro(path):
    return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=3)


def layout(con):
    return tuple((table, tuple(con.execute('PRAGMA table_info("%s")' % table)))
                 for table in TABLES)


def migrations(con):
    return tuple(con.execute(
        "SELECT version, checksum, success FROM _sqlx_migrations ORDER BY version"))


def in_use(home):
    files = [str(home / (name + suffix))
             for name in (DB_NAME, "state_5.sqlite", "sqlite/state_5.sqlite")
             for suffix in ("", "-wal", "-shm")
             if (home / (name + suffix)).exists()]
    if not files:
        return False
    try:
        result = subprocess.run(["/usr/sbin/lsof", "-t", *files],
                                stdout=subprocess.PIPE, text=True,
                                stderr=subprocess.DEVNULL, timeout=3)
        if result.returncode == 1:
            return False
        if result.returncode != 0:
            return True
        pids = result.stdout.split()
        if not pids or any(not pid.isdecimal() for pid in pids):
            return True
        return any(int(pid) != os.getpid() for pid in pids)
    except (OSError, subprocess.TimeoutExpired):
        return True


def paths_for(home):
    for name in ("state_5.sqlite", "sqlite/state_5.sqlite"):
        path = home / name
        if path.exists():
            con = connect_ro(path)
            try:
                columns = {row[1] for row in con.execute("PRAGMA table_info(threads)")}
                if not {"id", "rollout_path", "history_mode"}.issubset(columns):
                    continue
                return dict(con.execute(
                    "SELECT id, rollout_path FROM threads WHERE history_mode='paginated'"))
            except sqlite3.DatabaseError:
                # An unreadable profile index cannot identify compatible
                # messages. Keep it untouched and continue with other homes.
                continue
            finally:
                con.close()
    return {}


def backup_supersedes(new_path, old_path):
    con = connect_ro(new_path)
    try:
        con.execute("ATTACH DATABASE ? AS previous", (old_path.as_uri() + "?mode=ro",))
        previous_migrations = tuple(con.execute(
            "SELECT version, checksum, success FROM previous._sqlx_migrations ORDER BY version"))
        if migrations(con) != previous_migrations:
            return False
        for table, columns in layout(con):
            old_columns = tuple(con.execute('PRAGMA previous.table_info("%s")' % table))
            if not columns or columns != old_columns:
                return False
            keys = [column[1] for column in columns if column[5]]
            if not keys:
                return False
            selected = ",".join('"%s"' % key for key in keys)
            if con.execute('SELECT %s FROM previous."%s" EXCEPT SELECT %s FROM main."%s" LIMIT 1'
                           % (selected, table, selected, table)).fetchone():
                return False
        if con.execute(
            "SELECT 1 FROM previous.thread_history_projection_state p "
            "JOIN main.thread_history_projection_state n USING(thread_id) "
            "WHERE n.next_rollout_byte_offset < p.next_rollout_byte_offset "
            "OR n.next_rollout_ordinal < p.next_rollout_ordinal LIMIT 1").fetchone():
            return False
        if con.execute(
            "SELECT 1 FROM previous.thread_items p JOIN main.thread_items n "
            "USING(thread_id,turn_id,item_id) "
            "WHERE n.updated_at_ordinal < p.updated_at_ordinal "
            "OR (n.updated_at_ordinal = p.updated_at_ordinal AND n.item_json IS NOT p.item_json) "
            "LIMIT 1").fetchone():
            return False
        return True
    finally:
        con.close()


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.digest()


def same_backup(left, right):
    # A main database file alone cannot describe outstanding WAL content.
    for path in (left, right):
        wal = Path(str(path) + "-wal")
        if wal.exists() and wal.stat().st_size:
            return False
    return (right.exists() and left.stat().st_size == right.stat().st_size
            and file_digest(left) == file_digest(right))


def backup(con, home):
    if not BACKUPS_ENABLED:
        return
    folder = BACKUPS / "paginated-history-managed" / home.name
    if folder.is_symlink() or folder.parent.is_symlink():
        raise RuntimeError("managed backup directory must not be a symlink")
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Serialise publishers, including callers outside the launcher's sync lock.
    fd = os.open(folder / ".backup.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another history backup is running; defer sync")
        _backup_locked(con, folder)


def _backup_locked(con, folder):
    current = folder / "current.sqlite"
    previous = folder / "previous.sqlite"
    target = folder / ".snapshot-pending.sqlite"
    if any(path.is_symlink() for path in (current, previous, target)):
        raise RuntimeError("managed backup files must not be symlinks")
    if target.exists():
        # An interrupted publication may hold the only recovery copy. Keep it,
        # but do not create another file on each retry.
        raise RuntimeError("pending recovery backup exists; defer sync without allocating another")
    required = con.execute("PRAGMA page_count").fetchone()[0] * con.execute(
        "PRAGMA page_size").fetchone()[0]
    if shutil.disk_usage(folder).free < required + 1024 ** 3:
        raise RuntimeError("insufficient space for history backup and 1 GiB reserve; defer sync")
    deadline = time.monotonic() + 20

    def progress(status, remaining, total):
        if time.monotonic() > deadline:
            raise TimeoutError("history backup timed out; destination unchanged")

    publishing = False
    created = False
    try:
        # Exclusive creation prevents accidental reuse of a recovery snapshot.
        fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        created = True
        dest = sqlite3.connect(target)
        try:
            con.backup(dest, pages=256, progress=progress, sleep=.05)
            # Published snapshots are standalone files, without WAL sidecars.
            dest.execute("PRAGMA journal_mode=DELETE")
        finally:
            dest.close()
        if current.exists() and same_backup(target, current):
            return
        # Never rotate away a named backup with unresolved WAL data.
        if any(Path(str(path) + "-wal").exists()
               and Path(str(path) + "-wal").stat().st_size
               for path in (current, previous)):
            raise RuntimeError("backup slot has outstanding WAL data; retain it and defer sync")
        if previous.exists() and not backup_supersedes(target, previous):
            raise RuntimeError("older backup has unique history; retain it and defer sync")
        publishing = True
        if current.exists():
            os.replace(current, previous)
        os.replace(target, current)
    finally:
        # Until publication starts this is only a copy: the source and both
        # named rollback slots remain intact, even when validation raises.
        if created and not publishing:
            for suffix in ("", "-wal", "-shm", "-journal"):
                Path(str(target) + suffix).unlink(missing_ok=True)


def initialize(home, source):
    path = home / DB_NAME
    temporary = home / (".history-bootstrap-" + uuid.uuid4().hex + ".sqlite")
    con = sqlite3.connect(temporary)
    try:
        con.execute("PRAGMA journal_mode=WAL")
        for (sql,) in source.execute(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL "
            "AND name NOT LIKE 'sqlite_%' "
            "ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END"):
            con.execute(sql)
        rows = source.execute("SELECT * FROM _sqlx_migrations").fetchall()
        if rows:
            con.executemany("INSERT INTO _sqlx_migrations VALUES (" +
                            ",".join("?" for _ in rows[0]) + ")", rows)
        con.commit()
        con.close()
        # A concurrent native startup must never be overwritten.
        os.link(temporary, path)
    finally:
        con.close()
        temporary.unlink(missing_ok=True)


def snapshot(source, thread_id):
    return {table: source.execute('SELECT * FROM "%s" WHERE thread_id=?' % table,
                                  (thread_id,)).fetchall() for table in TABLES}


def compatible_snapshot(dest, signature, rows, thread_id):
    for table, columns in signature[0]:
        if table == "thread_history_projection_state":
            continue
        pk = [i for i, column in enumerate(columns) if column[5]]
        keys = {tuple(row[i] for i in pk) for row in rows[table]}
        local = dest.execute('SELECT * FROM "%s" WHERE thread_id=?' % table, (thread_id,))
        if any(tuple(row[i] for i in pk) not in keys for row in local):
            return False
    return True


def synchronize(homes, destinations, active):
    # A profile can be both a snapshot source and a destination. Legacy
    # DELETE-journal databases otherwise keep a read lock that blocks our own
    # destination commit. Native Codex uses WAL; prepare inactive homes before
    # opening any source snapshot, without changing history records.
    for home in destinations:
        path = home / DB_NAME
        if not path.exists() or path.is_symlink() or str(home) in active or in_use(home):
            continue
        con = sqlite3.connect(path, timeout=6)
        try:
            con.execute("PRAGMA journal_mode=WAL")
        finally:
            con.close()
    sources = []
    catalog = {}
    try:
        for home in homes:
            path = home / DB_NAME
            if not path.exists() or path.is_symlink():
                continue
            con = connect_ro(path)
            con.execute("BEGIN")
            try:
                signature = (layout(con), migrations(con))
                if any(not columns for _, columns in signature[0]):
                    con.close()
                    continue
                routes = paths_for(home)
                entries = list(con.execute(
                    "SELECT thread_id,next_rollout_byte_offset,next_rollout_ordinal "
                    "FROM thread_history_projection_state"))
            except sqlite3.Error:
                con.close()
                continue
            source = (home, con, signature, routes)
            sources.append(source)
            for thread_id, offset, ordinal in entries:
                if thread_id in routes and offset > 0 and ordinal > 0:
                    catalog.setdefault(thread_id, []).append((offset, ordinal, source))

        if not sources:
            return
        for home in destinations:
            if str(home) in active or in_use(home):
                print("Paginated history deferred for active profile: " + home.name)
                continue
            routes = paths_for(home)
            if not routes:
                continue
            path = home / DB_NAME
            if path.is_symlink():
                continue
            if not path.exists():
                initialize(home, sources[0][1])
            dest = sqlite3.connect(path, timeout=6)
            backed_up = False
            copied = 0
            try:
                signature = (layout(dest), migrations(dest))
                for thread_id, destination_rollout in routes.items():
                    candidates = sorted(catalog.get(thread_id, []),
                                        key=lambda row: (row[0], row[1]), reverse=True)
                    for offset, ordinal, source in candidates:
                        source_home, src, source_signature, source_routes = source
                        if source_home == home or signature != source_signature:
                            continue
                        try:
                            if not os.path.samefile(destination_rollout, source_routes[thread_id]):
                                continue
                            if offset > os.path.getsize(destination_rollout):
                                continue
                        except OSError:
                            continue
                        existing = dest.execute(
                            "SELECT next_rollout_byte_offset,next_rollout_ordinal "
                            "FROM thread_history_projection_state WHERE thread_id=?",
                            (thread_id,)).fetchone()
                        if existing and (existing[0] >= offset or existing[1] > ordinal):
                            continue
                        rows = snapshot(src, thread_id)
                        if not rows["thread_turns"] or not rows["thread_items"]:
                            continue
                        # Do not generate a backup every maintenance run for a
                        # candidate that cannot actually replace this snapshot.
                        if not compatible_snapshot(dest, signature, rows, thread_id):
                            continue
                        if in_use(home):
                            raise RuntimeError("profile opened during sync; remaining history deferred")
                        if not backed_up:
                            backup(dest, home)
                            backed_up = True
                        dest.execute("BEGIN IMMEDIATE")
                        try:
                            current = dest.execute(
                                "SELECT next_rollout_byte_offset,next_rollout_ordinal "
                                "FROM thread_history_projection_state WHERE thread_id=?",
                                (thread_id,)).fetchone()
                            if current != existing:
                                dest.rollback()
                                continue
                            if not compatible_snapshot(dest, signature, rows, thread_id):
                                dest.rollback()
                                continue
                            # Copy all four tables in the same transaction. Never combine
                            # a newer cursor with an older or independently merged item set.
                            for table in TABLES:
                                dest.execute('DELETE FROM "%s" WHERE thread_id=?' % table,
                                             (thread_id,))
                            for table in TABLES:
                                if rows[table]:
                                    marks = ",".join("?" for _ in rows[table][0])
                                    dest.executemany('INSERT INTO "%s" VALUES (%s)' % (table, marks),
                                                     rows[table])
                            dest.commit()
                            copied += 1
                            break
                        except Exception:
                            dest.rollback()
                            raise
                print("Paginated history snapshots copied: %s=%s" % (home.name, copied))
            finally:
                dest.close()
    finally:
        for _, con, _, _ in sources:
            con.close()


if __name__ == "__main__":
    os.umask(0o077)
    homes = list(dict.fromkeys(Path(value).expanduser().absolute() for value in sys.argv[1:]))
    destinations = [Path(value).expanduser().absolute() for value in
                    os.environ.get("CODEX_HISTORY_DEST_HOMES", "").splitlines() if value] or homes
    active = set(os.environ.get("CODEX_ACTIVE_DB_HOMES", "").splitlines())
    try:
        synchronize(homes, destinations, active)
    except (OSError, sqlite3.Error, RuntimeError, TimeoutError) as error:
        print("Paginated history sync stopped safely: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        sys.exit(1)
