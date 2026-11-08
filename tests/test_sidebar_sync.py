"""Exercise the real prelaunch command using disposable shared profiles."""
import json
import os
import re
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "codex_multi_account.zsh"
STATE = """
create table threads(id text primary key, rollout_path text, title text, preview text, name text,
 updated_at integer, updated_at_ms integer, history_mode text, archived integer default 0,
 archived_at integer, is_pinned integer not null default 0, thread_section_id text,
 section_position integer, section_entered_at_ms integer, project_id text);
create table projects(id text primary key, name text, updated_at_ms integer);
create table project_roots(project_id text, position integer, path text, primary key(project_id, position));
create table thread_sections(id text primary key, name text);
"""
HISTORY = """
create table _sqlx_migrations(version integer primary key, checksum blob, success bool);
create table thread_turns(thread_id text, turn_id text, primary key(thread_id,turn_id));
create table thread_items(thread_id text, item_id text, payload text, primary key(thread_id,item_id));
create table thread_realtime_items(thread_id text, item_id text, primary key(thread_id,item_id));
create table thread_history_projection_state(thread_id text primary key,
 next_rollout_byte_offset integer, next_rollout_ordinal integer);
"""

def query(path, sql):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as c:
        return c.execute(sql).fetchall()

with tempfile.TemporaryDirectory(prefix="codex-sidebar-fixture-") as td:
    home = Path(td)
    script = home/SCRIPT.name
    script.write_bytes(SCRIPT.read_bytes())
    # The fixture is private to this process. Skip only the macOS lsof scan;
    # all snapshot validation and copying run through the real helper.
    helper = SCRIPT.with_name("sync_paginated_history.py")
    helper_text, replacements = re.subn(r"def in_use\(home\):.*?(?=\ndef paths_for)",
        "def in_use(home):\n    return False\n\n", helper.read_text(), count=1, flags=re.S)
    assert replacements == 1
    (home/helper.name).write_text(helper_text)
    shared = home/".codex-shared-history"
    sessions = shared/"sessions"
    sessions.mkdir(parents=True)
    (shared/"shell_snapshots").mkdir()
    shared_index = shared/"session_index.jsonl"
    shared_index.write_text('{"id":"pin","thread_name":"shared legacy name"}\n')
    source, target, linked, private = (home/".codex-accounts"/n for n in ("source","target","linked","private"))
    unreadable = source.parent/"unreadable"
    unreadable.mkdir(parents=True)
    (unreadable/".codex-accounts-history-mode").write_text("shared\n")
    (unreadable/"state_5.sqlite").write_bytes(b"not a database")
    local_global = b'{"project-order":["keep"],"pinned-thread-ids":["pin"],"sidebar-thread-metadata":{"pin":{"custom":"local"}}}'
    for p in (source, target, linked, private):
        p.mkdir(parents=True)
        (p/".codex-accounts-history-mode").write_text("private\n" if p == private else "shared\n")
        (p/"sessions").symlink_to(sessions, target_is_directory=True)
        (p/".codex-global-state.json").write_bytes(local_global if p != source else b'{"project-order":["foreign"],"pinned-thread-ids":["unpin"]}')
        with sqlite3.connect(p/"state_5.sqlite") as c:
            c.executescript(STATE)
            c.execute("insert into projects values (?,?,?)", ("keep", "Old project" if p==source else "Local project", 2000 if p==source else 1000))
            c.execute("insert into project_roots values (?,?,?)", ("keep", 0, "source-root" if p==source else "target-root"))
            c.execute("insert into thread_sections values (?,?)", ("foreign" if p==source else "local", p.name))
            for tid in (("pin","unpin","archived","new") if p==source else ("pin","unpin","archived")):
                r = sessions/(tid+".jsonl")
                r.write_text(json.dumps({"type":"session_meta","payload":{"id":tid,"history_mode":"paginated"}}) + "\n" + "latest fixture transcript\n")
                local = p != source
                c.execute("insert into threads values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          (tid, str(p/"sessions"/r.name), ("Local title " if local else "Old title ")+tid,
                           "local preview" if local else "new incoming preview", ("Local name " if local else "Old name ")+tid,
                           1 if local else 2, 1000 if local else 2000, "paginated",
                           int(local and tid=="archived"), 8 if local and tid=="archived" else None,
                           int(tid=="pin" if local else True), "local" if local and tid=="pin" else (None if local else "foreign"),
                           9 if local and tid=="pin" else (None if local else 2),
                           99 if local and tid=="pin" else (None if local else 20), "keep" if tid=="pin" or not local else None))
        c.close()
    with sqlite3.connect(source/"thread_history_1.sqlite") as c:
        c.executescript(HISTORY)
        for tid in ("pin","unpin","archived","new"):
            c.execute("insert into thread_turns values (?,?)", (tid,"turn"))
            c.execute("insert into thread_items values (?,?,?)", (tid,"message","new paginated answer"))
            c.execute("insert into thread_history_projection_state values (?,?,?)", (tid, (sessions/(tid+".jsonl")).stat().st_size, 5))
    c.close()
    target_index = target/"session_index.jsonl"
    target_index.write_text('{"id":"pin","thread_name":"Local index title","updated_at":"1970-01-01T00:00:01Z"}\n')
    (linked/"session_index.jsonl").symlink_to(shared_index)
    env = dict(HOME=str(home), PATH=os.environ["PATH"], CODEX_HISTORY_ANCHOR_HOME=str(source),
               CODEX_SYNC_THREAD_HISTORY="1", CODEX_SKIP_ACTIVE_STATE_DB_WRITES="0", CODEX_PRUNE_GLOBAL_STATE_ON_SYNC="1",
               CODEX_DELETE_STALE_THREAD_ROWS="1")
    def run(path, *args):
        proc = subprocess.run(["/bin/zsh", str(path), *args], env=env,
                              capture_output=True, text=True, timeout=40)
        assert proc.returncode == 0, (proc.stdout, proc.stderr)
        return proc
    for p in (target, linked, private):
        result = run(script, "sync-account-for-launch", p.name)
        if p != private:
            assert f"Paginated history snapshots copied: {p.name}=4" in result.stdout, (result.stdout,result.stderr)
    cols = "id,name,title,is_pinned,thread_section_id,section_position,section_entered_at_ms,project_id,archived,archived_at,preview,updated_at"
    db = target/"state_5.sqlite"
    rows = {r[0]:r[1:] for r in query(db, "select "+cols+" from threads")}
    assert rows["pin"] == ("Local name pin","Local title pin",1,"local",9,99,"keep",0,None,"new incoming preview",2), rows
    assert rows["unpin"][:7] == ("Local name unpin","Local title unpin",0,None,None,None,None)
    assert rows["archived"][7:9] == (1,8)
    assert rows["new"][:7] == ("Old name new","Old title new",0,None,None,None,None)
    assert query(db, "select * from projects")==[("keep","Local project",1000)]
    assert query(db, "select * from project_roots")==[("keep",0,"target-root")]
    assert query(db, "select * from thread_sections")==[("local","target")]
    assert (target/".codex-global-state.json").read_bytes()==local_global
    assert query(target/"thread_history_1.sqlite","select payload from thread_items where thread_id='new'")==[("new paginated answer",)]
    assert query(target/"thread_history_1.sqlite","select payload from thread_items where thread_id='pin'")==[("new paginated answer",)]
    index = {r["id"]:r["thread_name"] for r in map(json.loads,target_index.read_text().splitlines())}
    assert index=={"pin":"Local index title", "unpin":"Local name unpin","new":"Old name new"}, index
    assert query(linked/"state_5.sqlite","select name from threads where id='new'")==[("Old name new",)]
    assert (linked/"session_index.jsonl").is_symlink() and shared_index.read_text()=='{"id":"pin","thread_name":"shared legacy name"}\n'
    assert not query(private/"state_5.sqlite","select id from threads where id='new'")
    assert (unreadable/"state_5.sqlite").read_bytes()==b"not a database"
    assert not query(source/"state_5.sqlite","select id from threads where thread_section_id='local'")
    before = target_index.read_bytes()
    # Exercise the exact storage preparation called after prelaunch sync, without
    # launching a GUI or opening any real account.
    launch_storage = home/"launch-storage.zsh"
    launcher_source = SCRIPT.read_text()
    assert launcher_source.endswith('main "$@"\n')
    launch_storage.write_text(launcher_source.removesuffix('main "$@"\n') +
        'CODEX_SHARED_SESSIONS=1 CODEX_PRESERVE_DEST_SIDEBAR=1 prepare_profile_login_storage_for_launch "$1"\n')
    run(launch_storage,str(target))
    assert target_index.is_file() and not target_index.is_symlink() and target_index.read_bytes()==before
    assert (target/"shell_snapshots").is_symlink() and (target/"shell_snapshots").resolve() == (shared/"shell_snapshots").resolve()
    run(script,"sync-account-for-launch","target")
    assert query(db,"select "+cols+" from threads")==[(key,*row) for key,row in rows.items()]
    assert target_index.read_bytes()==before
    run(script,"sync-history-once")
    assert query(db,"select "+cols+" from threads")==[(key,*row) for key,row in rows.items()]
    assert (target/".codex-global-state.json").read_bytes()==local_global
    assert target_index.read_bytes()==before
    assert shared_index.read_text()=='{"id":"pin","thread_name":"shared legacy name"}\n'
    assert not query(private/"state_5.sqlite","select id from threads where id='new'")
    print("PASS: both index layouts, local titles/project/sections/pins/archive, fresh paginated messages, private profile isolation, launch storage, repeat sync and background sync")
