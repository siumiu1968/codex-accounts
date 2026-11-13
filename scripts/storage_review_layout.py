#!/usr/bin/env python3
"""Give one closed Codex profile a direct view of the shared sessions directory."""
import ctypes
import os
from pathlib import Path
import re
import subprocess
import sys


def desktop_or_server_uses(home):
    rows = subprocess.check_output(["/bin/ps", "-axww", "-o", "pid,command"], text=True)
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, command = parts
        desktop = bool(re.match(r"^.*/(?:ChatGPT|Codex)\.app/Contents/MacOS/(?:ChatGPT|Codex)(?: |$)", command))
        server = bool(re.match(r"^\S*/codex .*?\bapp-server\b", command))
        if not (desktop or server):
            continue
        result = subprocess.run(["/bin/ps", "eww", "-p", pid, "-o", "command="],
                                text=True, capture_output=True)
        if result.returncode != 0:
            continue
        match = re.search(r"(?:^| )CODEX_HOME=([^ ]+)", result.stdout)
        candidate = Path(match[1]).expanduser() if match else Path.home() / ".codex"
        if candidate.resolve() == home.resolve():
            return True
    return False


def same(first, second):
    try:
        return os.path.samefile(first, second)
    except OSError:
        return False


def layout(primary, shared):
    if (not primary.is_symlink() and primary.is_dir() and shared.is_symlink()
            and same(primary, shared)):
        return "direct"
    if (primary.is_symlink() and not shared.is_symlink() and shared.is_dir()
            and same(primary, shared)):
        return "linked"
    return "unsupported"


def shared_owner(shared, primary, secondary, profiles):
    if not shared.is_symlink():
        if not shared.is_dir():
            raise RuntimeError("The shared sessions directory is unavailable.")
        return None
    direct = shared.resolve(strict=True)
    home = direct.parent
    if (direct.name != "sessions" or not direct.is_dir()
            or not (home in (primary.resolve(), secondary.resolve())
                    or home.parent == profiles.resolve())):
        raise RuntimeError("The shared sessions link does not point to a managed profile.")
    if not os.path.samefile(shared, home / "sessions"):
        raise RuntimeError("The shared sessions directory is inconsistent.")
    return home


def handoff(action, home, shared, primary, secondary, profiles):
    if home.is_symlink() or not home.is_dir():
        raise RuntimeError("The requested profile must be a managed local directory.")
    home = home.resolve()
    if not (home in (primary.resolve(), secondary.resolve()) or home.parent == profiles.resolve()):
        raise RuntimeError("The requested profile must be a managed local directory.")
    shared = shared.parent.resolve() / shared.name
    owner = shared_owner(shared, primary, secondary, profiles)
    target = home / "sessions"
    if action == "status":
        if owner == home:
            print("direct")
        elif same(target, shared):
            print("linked")
        elif target.is_dir() and not target.is_symlink():
            print("local")
        else:
            print("unavailable")
        return False
    if action == "rollback":
        if owner == home:
            return change("rollback", home, shared)
        if same(target, shared):
            print("linked")
            return False
        raise RuntimeError("This profile does not own the shared sessions directory.")
    if action != "enable":
        raise ValueError("unknown storage review action")
    if owner == home:
        return change("enable", home, shared)
    pending = home / ".sessions-storage-review.pending"
    if (owner is None and target.is_symlink() and target.readlink() == target
            and pending.is_symlink() and pending.readlink() == shared):
        return change("enable", home, shared)
    if not same(target, shared) or not target.is_symlink():
        raise RuntimeError("The requested profile does not link to the shared sessions directory.")
    # Both paths temporarily point to themselves during their own exchanges.
    # Every other profile continues to resolve the stable shared path.
    if desktop_or_server_uses(home):
        raise RuntimeError("Close the requested profile before enabling Storage review.")
    if owner and desktop_or_server_uses(owner):
        raise RuntimeError(f"Storage review is in use by {owner.name}. Close that profile to switch.")
    original = shared.stat()
    if owner:
        change("rollback", owner, shared)
    try:
        change("enable", home, shared)
    except (OSError, RuntimeError):
        # The stable shared path remains valid even if a transfer is aborted.
        # Leave it physical if the previous owner has reopened.
        if owner and layout(owner / "sessions", shared) == "linked" and not desktop_or_server_uses(owner):
            change("enable", owner, shared)
        raise
    if not os.path.samestat(original, shared.stat()):
        raise RuntimeError("The shared sessions identity changed.")
    return False


def swap(first, second):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(first), -2, os.fsencode(second), 0x00000002):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def change(action, home, shared):
    primary = home / "sessions"
    pending = home / ".sessions-storage-review.pending"
    current = layout(primary, shared)
    if action == "status":
        print(current)
        return current == "unsupported"
    if action not in ("enable", "rollback"):
        raise ValueError("unknown storage review action")
    expected = "direct" if action == "enable" else "linked"
    if current == expected and not pending.is_symlink():
        print(current)
        return False
    if desktop_or_server_uses(home):
        raise RuntimeError("Close the profile before changing its storage layout.")
    if home.is_symlink() or shared.parent.is_symlink():
        raise RuntimeError("The storage roots must be real local directories.")
    # Recover a process interruption before the exchange; the shared path
    # remains valid throughout, including while primary briefly points to itself.
    if (pending.is_symlink() and primary.is_symlink() and primary.readlink() == primary
            and shared.is_dir() and not shared.is_symlink()):
        if pending.readlink() != shared:
            raise RuntimeError("Unknown pending storage layout.")
        os.replace(pending, primary)
        current = layout(primary, shared)
    elif pending.is_symlink() and pending.readlink() == shared and current in ("direct", "linked"):
        pending.unlink()
    elif os.path.lexists(pending):
        raise RuntimeError("Unknown pending storage layout.")
    if current == expected:
        print(current)
        return False
    if current == "unsupported" or primary.parent.stat().st_dev != shared.parent.stat().st_dev:
        raise RuntimeError("The two paths must share one local filesystem and the same sessions directory.")
    st = shared.stat()
    swaplink = home / ".sessions-storage-review.exchange"
    if os.path.lexists(swaplink):
        raise RuntimeError("Unexpected storage exchange path.")
    pending.symlink_to(shared, target_is_directory=True)
    if action == "enable":
        try:
            swaplink.symlink_to(primary, target_is_directory=True)
            os.replace(swaplink, primary)
            try:
                swap(primary, shared)
            except OSError:
                os.replace(pending, primary)
                raise
        finally:
            if swaplink.is_symlink() and swaplink.readlink() == primary:
                swaplink.unlink()
    else:
        swap(primary, shared)
        os.replace(pending, primary)
    if layout(primary, shared) != expected or not os.path.samestat(st, shared.stat()):
        raise RuntimeError("Storage layout verification failed.")
    if pending.is_symlink():
        pending.unlink()
    print(expected)
    return False


if __name__ == "__main__":
    try:
        action, *paths = sys.argv[1:]
        if len(paths) == 2:
            raise SystemExit(change(action, *map(Path, paths)))
        if len(paths) == 5:
            raise SystemExit(handoff(action, *map(Path, paths)))
        raise ValueError("invalid storage layout arguments")
    except (IndexError, OSError, RuntimeError, ValueError) as e:
        print(str(e), file=sys.stderr)
        raise SystemExit(1)
