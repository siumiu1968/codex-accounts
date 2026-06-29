#!/usr/bin/env python3
import argparse
import base64
import glob
import hashlib
import hmac
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_SUPPORT = Path.home() / "Library/Application Support/Codex Accounts"
USERS_PATH = APP_SUPPORT / "remote-users.json"
SESSIONS_PATH = APP_SUPPORT / "remote-sessions.json"
PID_PATH = APP_SUPPORT / "remote-bridge.pid"
DEFAULT_PORT = 47621
SESSION_SECONDS = 60 * 60 * 24 * 30
PBKDF2_ROUNDS = 240_000
DEFAULT_CODEX_TIMEOUT = 1800
DEFAULT_MAX_CODEX_CHARS = 9000
DEFAULT_REMOTE_ATTACHMENT_MAX_BYTES = 15 * 1024 * 1024
DEFAULT_REMOTE_ATTACHMENT_TTL_SECONDS = 60 * 60 * 24 * 14
DEFAULT_VPS_HOST = os.environ.get("CODEX_REMOTE_VPS_HOST", "armjp")
DEFAULT_VPS_HOME = os.environ.get("CODEX_REMOTE_VPS_HOME", "/home/ubuntu")
DEFAULT_VPS_CODEX_ACCOUNTS_DIR = os.environ.get("CODEX_REMOTE_VPS_CODEX_ACCOUNTS_DIR", f"{DEFAULT_VPS_HOME}/.codex-accounts")
DEFAULT_VPS_DEFAULT_CODEX_HOME = os.environ.get("CODEX_REMOTE_VPS_DEFAULT_CODEX_HOME", f"{DEFAULT_VPS_HOME}/.codex")
DEFAULT_VPS_SSH_TIMEOUT = int(os.environ.get("CODEX_REMOTE_VPS_SSH_TIMEOUT", "8"))
DEFAULT_VPS_LIST_TIMEOUT = int(os.environ.get("CODEX_REMOTE_VPS_LIST_TIMEOUT", "4"))
DEFAULT_PROFILES_CACHE_SECONDS = float(os.environ.get("CODEX_REMOTE_PROFILES_CACHE_SECONDS", "8"))
DEFAULT_ACCOUNT_HOME_CACHE_SECONDS = float(os.environ.get("CODEX_REMOTE_ACCOUNT_HOME_CACHE_SECONDS", "60"))
LOGIN_FAILURES = {}
LOGIN_WINDOW_SECONDS = 10 * 60
MAX_LOGIN_FAILURES = 8
MAX_REQUEST_BYTES = 24 * 1024 * 1024
REMOTE_ATTACHMENTS_DIR = APP_SUPPORT / "remote-attachments"
SYNC_INCLUDE_NAMES = {
    ".codex-global-state.json",
    "AGENTS.md",
    "auth.json",
    "config.toml",
    "goals_1.sqlite",
    "goals_1.sqlite-shm",
    "goals_1.sqlite-wal",
    "installation_id",
    "keybindings.json",
    "logs_2.sqlite",
    "logs_2.sqlite-shm",
    "logs_2.sqlite-wal",
    "memories_1.sqlite",
    "memories_1.sqlite-shm",
    "memories_1.sqlite-wal",
    "models_cache.json",
    "session_index.jsonl",
    "state_5.sqlite",
    "state_5.sqlite-shm",
    "state_5.sqlite-wal",
}
SYNC_INCLUDE_DIRS = {
    "bin",
    "computer-use",
    "memories",
    "rules",
    "sessions",
    "shell_snapshots",
    "sqlite",
}


class PayloadTooLarge(ValueError):
    pass


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def ensure_private_app_support_dir():
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(APP_SUPPORT, 0o700)
    except OSError:
        pass


def find_codex_script():
    env_path = os.environ.get("CODEX_ACCOUNTS_SCRIPT")
    if env_path and Path(env_path).exists():
        return env_path

    candidates = [
        Path.home() / "Documents/Codex/2026-05-05/codex-gpt-account-codex-code-account/scripts/codex_multi_account.zsh",
        Path.cwd() / "scripts/codex_multi_account.zsh",
        Path.cwd().parent / "scripts/codex_multi_account.zsh",
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)

    matches = glob.glob(str(Path.home() / "Documents/Codex/**/scripts/codex_multi_account.zsh"), recursive=True)
    if matches:
        matches.sort(key=lambda p: Path(p).stat().st_mtime, reverse=True)
        return matches[0]
    raise FileNotFoundError("Could not find codex_multi_account.zsh. Set CODEX_ACCOUNTS_SCRIPT=/path/to/scripts/codex_multi_account.zsh")


def find_codex_cli():
    env_path = os.environ.get("CODEX_CLI_PATH")
    if env_path and Path(env_path).exists():
        return env_path

    candidates = [
        Path("/Applications/Codex.app/Contents/Resources/codex"),
        Path("/opt/homebrew/bin/codex"),
        Path("/usr/local/bin/codex"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)

    resolved = shutil.which("codex")
    if resolved:
        return resolved
    raise FileNotFoundError("Codex CLI was not found on the MacBook.")


def load_json(path, fallback):
    if not path.exists():
        return fallback
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback


def save_json(path, value):
    ensure_private_app_support_dir()
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def password_hash(password, salt=None):
    if salt is None:
        salt = secrets.token_bytes(24)
    else:
        salt = base64.b64decode(salt)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ROUNDS)
    return {
        "algorithm": "pbkdf2_sha256",
        "rounds": PBKDF2_ROUNDS,
        "salt": base64.b64encode(salt).decode("ascii"),
        "hash": base64.b64encode(digest).decode("ascii"),
    }


def verify_password(password, stored):
    if stored.get("algorithm") != "pbkdf2_sha256":
        return False
    salt = stored.get("salt", "")
    expected = stored.get("hash", "")
    rounds = int(stored.get("rounds", PBKDF2_ROUNDS))
    try:
        salt_bytes = base64.b64decode(salt)
        expected_bytes = base64.b64decode(expected)
    except Exception:
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt_bytes, rounds)
    return hmac.compare_digest(actual, expected_bytes)


def clean_expired_sessions():
    sessions = load_json(SESSIONS_PATH, {})
    now = int(time.time())
    fresh = {token: data for token, data in sessions.items() if int(data.get("expiresAt", 0)) > now}
    if fresh != sessions:
        save_json(SESSIONS_PATH, fresh)
    return fresh


def login_rate_key(handler):
    remote_address = handler.client_address[0] if handler.client_address else "unknown"
    forwarded = ""
    if should_trust_forwarded_headers(remote_address):
        forwarded = handler.headers.get("CF-Connecting-IP") or handler.headers.get("X-Forwarded-For") or ""
    if forwarded:
        return forwarded.split(",")[0].strip()
    return remote_address


def should_trust_forwarded_headers(remote_address):
    if os.environ.get("CODEX_REMOTE_TRUST_FORWARDED_HEADERS") == "1":
        return True
    try:
        return ipaddress.ip_address(remote_address).is_loopback
    except ValueError:
        return False


def assert_login_allowed(key):
    now = int(time.time())
    failures = [stamp for stamp in LOGIN_FAILURES.get(key, []) if now - stamp < LOGIN_WINDOW_SECONDS]
    LOGIN_FAILURES[key] = failures
    if len(failures) >= MAX_LOGIN_FAILURES:
        raise PermissionError("Too many failed login attempts. Try again later.")


def record_login_failure(key):
    now = int(time.time())
    failures = [stamp for stamp in LOGIN_FAILURES.get(key, []) if now - stamp < LOGIN_WINDOW_SECONDS]
    failures.append(now)
    LOGIN_FAILURES[key] = failures


def clear_login_failures(key):
    LOGIN_FAILURES.pop(key, None)


def normalized_username(username):
    username = str(username or "").strip().lower()
    if not username:
        raise ValueError("Missing username")
    if len(username) < 3 or len(username) > 32:
        raise ValueError("Username must be 3-32 characters")
    if not all(ch.isalnum() or ch in "._-" for ch in username):
        raise ValueError("Username can only contain letters, numbers, dot, dash, and underscore")
    return username


def create_local_user(username, password):
    username = normalized_username(username)
    if len(str(password or "")) < 10:
        raise ValueError("Password must be at least 10 characters")

    data = load_json(USERS_PATH, {"users": {}})
    users = data.setdefault("users", {})
    if username in users:
        raise ValueError("User already exists")
    users[username] = {
        "username": username,
        "createdAt": int(time.time()),
        "password": password_hash(password),
    }
    save_json(USERS_PATH, data)
    return username


def delete_local_user(username):
    username = normalized_username(username)
    data = load_json(USERS_PATH, {"users": {}})
    users = data.setdefault("users", {})
    if username not in users:
        raise ValueError("User does not exist")
    del users[username]
    save_json(USERS_PATH, data)
    sessions = clean_expired_sessions()
    sessions = {token: session for token, session in sessions.items() if session.get("username") != username}
    save_json(SESSIONS_PATH, sessions)
    return username


def list_local_users():
    users = load_json(USERS_PATH, {"users": {}}).get("users", {})
    return sorted(users.keys())


def write_pid_file(path):
    ensure_private_app_support_dir()
    path.write_text(str(os.getpid()) + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def run_script(script_path, args, timeout=45):
    completed = subprocess.run(
        [script_path] + args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    output = completed.stdout.strip()
    if completed.returncode != 0:
        raise RuntimeError(output or f"codex script failed: {args}")
    return output


def parse_pipe_lines(text):
    rows = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split("|")]
        if parts and parts[0]:
            rows.append(parts)
    return rows


def shell_join(args):
    return " ".join(shlex.quote(str(arg)) for arg in args)


def run_ssh(host, remote_script, timeout=DEFAULT_VPS_SSH_TIMEOUT, input_text=None):
    completed = subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            host,
            "sh -lc " + shlex.quote(remote_script),
        ],
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    output = completed.stdout.strip()
    if completed.returncode != 0:
        raise RuntimeError(output or f"ssh command failed on {host}")
    return output


def safe_remote_profile_id(profile_id):
    value = str(profile_id or "").strip()
    if not value:
        raise ValueError("Missing profile id")
    if not all(ch.isalnum() or ch in "._-" for ch in value):
        raise ValueError("Invalid profile id")
    return value


def remote_codex_home(profile_id=""):
    if profile_id:
        return f"{DEFAULT_VPS_CODEX_ACCOUNTS_DIR.rstrip('/')}/{safe_remote_profile_id(profile_id)}"
    return DEFAULT_VPS_DEFAULT_CODEX_HOME


def truncate_text(text, max_chars=DEFAULT_MAX_CODEX_CHARS):
    text = (text or "").strip()
    if len(text) <= max_chars:
        return text
    keep = max_chars - 120
    return text[:keep].rstrip() + "\n\n[Output truncated by Codex Remote bridge.]"


def short_error(exc, max_chars=220):
    if isinstance(exc, subprocess.TimeoutExpired):
        return f"timeout after {exc.timeout}s"
    return truncate_text(str(exc).replace("\n", " "), max_chars)


def _attachment_max_bytes():
    try:
        return int(os.environ.get("CODEX_REMOTE_ATTACHMENT_MAX_BYTES", DEFAULT_REMOTE_ATTACHMENT_MAX_BYTES))
    except ValueError:
        return DEFAULT_REMOTE_ATTACHMENT_MAX_BYTES


def _safe_attachment_name(name, mime_type, index):
    raw = Path(str(name or f"attachment-{index}")).name
    raw = re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip(".-")
    if not raw:
        raw = f"attachment-{index}"
    if not Path(raw).suffix:
        guessed = mimetypes.guess_extension(str(mime_type or "").split(";", 1)[0].strip())
        if guessed:
            raw += guessed
    return raw[:96]


def materialize_remote_attachments(attachments):
    if not isinstance(attachments, list) or not attachments:
        return []
    max_bytes = _attachment_max_bytes()
    batch_dir = REMOTE_ATTACHMENTS_DIR / (time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(4))
    batch_dir.mkdir(parents=True, exist_ok=True)
    materialized = []
    for index, item in enumerate(attachments[:8], start=1):
        if not isinstance(item, dict):
            continue
        data_b64 = str(item.get("dataBase64") or "").strip()
        if not data_b64:
            continue
        try:
            data = base64.b64decode(data_b64, validate=True)
        except Exception as exc:
            raise ValueError(f"Attachment {index} is not valid base64") from exc
        if len(data) > max_bytes:
            raise ValueError(f"Attachment {index} is too large ({len(data)} bytes)")
        mime_type = str(item.get("mimeType") or item.get("mime_type") or "application/octet-stream")
        filename = _safe_attachment_name(item.get("name"), mime_type, index)
        path = batch_dir / filename
        path.write_bytes(data)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        materialized.append({"path": str(path), "name": filename, "mimeType": mime_type})
    return materialized


def prune_remote_attachments():
    try:
        ttl = int(os.environ.get("CODEX_REMOTE_ATTACHMENT_TTL_SECONDS", DEFAULT_REMOTE_ATTACHMENT_TTL_SECONDS))
    except ValueError:
        ttl = DEFAULT_REMOTE_ATTACHMENT_TTL_SECONDS
    if ttl <= 0 or not REMOTE_ATTACHMENTS_DIR.exists():
        return
    cutoff = time.time() - ttl
    for path in REMOTE_ATTACHMENTS_DIR.iterdir():
        try:
            if path.stat().st_mtime >= cutoff:
                continue
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        except OSError:
            pass


def build_codex_prompt_with_attachments(text, attachments):
    text = str(text or "").strip()
    if not attachments:
        return text
    lines = [
        text or "請分析我上傳嘅附件。",
        "",
        "Codex Remote 已經將手機附件同步到呢部 Mac；請直接檢視以下本機路徑。",
    ]
    for index, item in enumerate(attachments, start=1):
        mime_type = str(item.get("mimeType") or "")
        kind = "圖片" if mime_type.startswith("image/") else "附件"
        lines.append(f"{index}. {kind}: {item.get('path')} ({mime_type or 'unknown'})")
    return "\n".join(lines).strip()


def parse_quota_score(quota):
    quota = str(quota or "").strip().lower()
    if not quota or quota == "unknown":
        return 1
    if quota == "unlimited":
        return 10_000
    values = []
    current = ""
    for ch in quota:
        if ch.isdigit():
            current += ch
            continue
        if ch == "%" and current:
            try:
                values.append(int(current))
            except ValueError:
                pass
            current = ""
        elif not ch.isdigit():
            current = ""
    if not values:
        return 1
    return max(0, min(values))


def codex_env_for(home):
    env = os.environ.copy()
    env["CODEX_HOME"] = str(home)
    env.setdefault("NO_COLOR", "1")
    env.setdefault("TERM", "xterm-256color")
    return env


def local_ip_hint():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


class BridgeState:
    def __init__(self, script_path):
        self.script_path = script_path
        self._profiles_cache_at = 0.0
        self._profiles_cache = []
        self._account_homes_cache_at = 0.0
        self._account_homes_cache = {}

    def has_users(self):
        return bool(load_json(USERS_PATH, {}).get("users", {}))

    def login(self, username, password):
        username = normalized_username(username)
        users = load_json(USERS_PATH, {}).get("users", {})
        user = users.get(username)
        if not user or not verify_password(password, user.get("password", {})):
            raise PermissionError("Invalid username or password")

        token = secrets.token_urlsafe(40)
        sessions = clean_expired_sessions()
        sessions[token] = {
            "username": username,
            "createdAt": int(time.time()),
            "expiresAt": int(time.time()) + SESSION_SECONDS,
        }
        save_json(SESSIONS_PATH, sessions)
        return {
            "sessionToken": token,
            "username": username,
            "expiresAt": sessions[token]["expiresAt"],
        }

    def authenticate_session(self, token):
        if not token:
            return None
        sessions = clean_expired_sessions()
        session = sessions.get(token)
        if not session:
            return None
        return session

    def logout(self, token):
        sessions = clean_expired_sessions()
        sessions.pop(token, None)
        save_json(SESSIONS_PATH, sessions)
        return "Logged out"

    def account_homes(self, force=False):
        now = time.time()
        if (
            not force
            and self._account_homes_cache
            and now - self._account_homes_cache_at < DEFAULT_ACCOUNT_HOME_CACHE_SECONDS
        ):
            return dict(self._account_homes_cache)

        accounts_output = run_script(self.script_path, ["list-accounts"], timeout=12)
        homes = {}
        for row in parse_pipe_lines(accounts_output):
            if len(row) >= 2:
                homes[row[0]] = row[1]
        self._account_homes_cache_at = time.time()
        self._account_homes_cache = dict(homes)
        return homes

    def profiles(self, force=False):
        now = time.time()
        if (
            not force
            and self._profiles_cache
            and now - self._profiles_cache_at < DEFAULT_PROFILES_CACHE_SECONDS
        ):
            return [dict(profile) for profile in self._profiles_cache]

        homes = self.account_homes(force=force)

        status_output = run_script(self.script_path, ["list-accounts-status"], timeout=45)
        statuses = {}
        for row in parse_pipe_lines(status_output):
            if row:
                statuses[row[0]] = row

        profiles = []
        for profile_id, home in homes.items():
            status = statuses.get(profile_id, [])
            display_name = self.display_name_for(profile_id)
            profiles.append({
                "id": profile_id,
                "displayName": display_name,
                "home": home,
                "authStatus": status[1] if len(status) > 1 else "unknown",
                "authMode": status[2] if len(status) > 2 else "unknown",
                "lastRefresh": status[3] if len(status) > 3 else "unknown",
                "quota": status[4] if len(status) > 4 else "unknown",
                "reset": status[5] if len(status) > 5 else "unknown",
            })
        self._profiles_cache_at = time.time()
        self._profiles_cache = [dict(profile) for profile in profiles]
        return profiles

    def targets(self):
        return [
            {
                "id": "mac",
                "name": "MacBook Codex",
                "kind": "desktop",
                "ready": True,
                "detail": local_ip_hint(),
            },
            self.vps_status(raise_on_error=False, timeout=3),
        ]

    def best_profile(self):
        signed = []
        fallback = None
        for profile in self.profiles():
            if fallback is None:
                fallback = profile
            if profile.get("authStatus") != "signed_in_local":
                continue
            score = parse_quota_score(profile.get("quota"))
            signed.append((score, profile))
        if signed:
            signed.sort(key=lambda item: item[0], reverse=True)
            return signed[0][1]
        return fallback

    def cached_best_profile(self):
        if not self._profiles_cache:
            return None
        signed = []
        fallback = self._profiles_cache[0] if self._profiles_cache else None
        for profile in self._profiles_cache:
            if profile.get("authStatus") == "signed_in_local":
                signed.append((parse_quota_score(profile.get("quota")), profile))
        if signed:
            signed.sort(key=lambda item: item[0], reverse=True)
            return dict(signed[0][1])
        return dict(fallback) if fallback else None

    def light_profile_by_id(self, profile_id):
        wanted = str(profile_id or "").strip()
        homes = self.account_homes()
        if wanted and wanted in homes:
            return {
                "id": wanted,
                "displayName": self.display_name_for(wanted),
                "home": homes[wanted],
                "authStatus": "unknown",
                "authMode": "unknown",
                "lastRefresh": "unknown",
                "quota": "unknown",
                "reset": "unknown",
            }
        if homes:
            profile_id, home = next(iter(homes.items()))
            return {
                "id": profile_id,
                "displayName": self.display_name_for(profile_id),
                "home": home,
                "authStatus": "unknown",
                "authMode": "unknown",
                "lastRefresh": "unknown",
                "quota": "unknown",
                "reset": "unknown",
            }
        return None

    def conversation_profile(self, profile_id=""):
        if profile_id:
            return self.light_profile_by_id(profile_id)
        return self.cached_best_profile() or self.light_profile_by_id("")

    def display_name_for(self, profile_id):
        if profile_id == "account1":
            return "Account 1"
        if profile_id == "account2":
            return "Account 2"
        return profile_id

    def open_profile(self, profile_id):
        run_script(self.script_path, ["sync-once"], timeout=45)
        run_script(self.script_path, ["link-all-history"], timeout=45)
        run_script(self.script_path, ["launch-account", profile_id, self.display_name_for(profile_id)], timeout=45)
        return f"Opened {profile_id}"

    def close_profile(self, profile_id):
        run_script(self.script_path, ["close-account", profile_id], timeout=25)
        return f"Closed {profile_id}"

    def sync(self):
        run_script(self.script_path, ["sync-once"], timeout=45)
        return "Synced local memory"

    def sync_vps(self, direction="push"):
        direction = str(direction or "push").strip().lower()
        if direction not in {"push", "pull", "two-way"}:
            raise ValueError("direction must be push, pull, or two-way")
        profiles = self.profiles()
        run_ssh(
            DEFAULT_VPS_HOST,
            "mkdir -p "
            + shlex.quote(DEFAULT_VPS_CODEX_ACCOUNTS_DIR)
            + " "
            + shlex.quote(DEFAULT_VPS_DEFAULT_CODEX_HOME),
            timeout=DEFAULT_VPS_SSH_TIMEOUT,
        )

        copied = 0
        if direction in {"pull", "two-way"}:
            self._rsync_vps_home(DEFAULT_VPS_DEFAULT_CODEX_HOME + "/", str(Path.home() / ".codex") + "/", pull=True)
            copied += 1
            for profile in profiles:
                profile_id = safe_remote_profile_id(profile.get("id"))
                local_home = str(Path(str(profile.get("home") or "")).expanduser()) + "/"
                self._rsync_vps_home(remote_codex_home(profile_id) + "/", local_home, pull=True)
                copied += 1

        if direction in {"push", "two-way"}:
            self._rsync_vps_home(str(Path.home() / ".codex") + "/", DEFAULT_VPS_DEFAULT_CODEX_HOME + "/", pull=False)
            copied += 1
            for profile in profiles:
                profile_id = safe_remote_profile_id(profile.get("id"))
                local_home = str(Path(str(profile.get("home") or "")).expanduser()) + "/"
                self._rsync_vps_home(local_home, remote_codex_home(profile_id) + "/", pull=False)
                copied += 1
        return {
            "ok": True,
            "target": "vps",
            "host": DEFAULT_VPS_HOST,
            "direction": direction,
            "items": copied,
            "message": f"Synced Codex homes with VPS ({direction})",
        }

    def _rsync_vps_home(self, source, destination, pull):
        include_args = []
        for name in sorted(SYNC_INCLUDE_NAMES):
            include_args += ["--include", f"/{name}"]
        for name in sorted(SYNC_INCLUDE_DIRS):
            include_args += ["--include", f"/{name}/***"]
        include_args += ["--exclude", "*"]
        base_args = [
            "rsync",
            "-a",
            "--update",
            "-e",
            "ssh -o BatchMode=yes -o ConnectTimeout=10",
        ] + include_args
        if pull:
            args = base_args + [f"{DEFAULT_VPS_HOST}:{source}", destination]
        else:
            run_ssh(DEFAULT_VPS_HOST, "mkdir -p " + shlex.quote(destination.rstrip("/")), timeout=DEFAULT_VPS_SSH_TIMEOUT)
            args = base_args + [source, f"{DEFAULT_VPS_HOST}:{destination}"]
        completed = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
        if completed.returncode != 0:
            raise RuntimeError(completed.stdout.strip() or "rsync failed")

    def vps_status(self, raise_on_error=True, timeout=DEFAULT_VPS_SSH_TIMEOUT):
        payload = {
            "id": "vps",
            "name": "Japan VPS Codex CLI",
            "kind": "cli",
            "host": DEFAULT_VPS_HOST,
            "ready": False,
            "detail": "Not checked",
            "message": "VPS not checked",
        }
        try:
            output = run_ssh(
                DEFAULT_VPS_HOST,
                "printf 'host='; hostname; printf 'codex='; command -v codex || true; printf 'version='; codex --version 2>/dev/null || true",
                timeout=timeout,
            )
            payload["ready"] = "codex=" in output and not output.rstrip().endswith("codex=")
            payload["detail"] = output
            payload["message"] = "VPS Codex CLI reachable" if payload["ready"] else "VPS reachable, Codex CLI not found"
            return payload
        except Exception as exc:
            payload["detail"] = str(exc)
            payload["message"] = "VPS offline or VPN not connected"
            if raise_on_error:
                raise
            return payload

    def share_all(self):
        run_script(self.script_path, ["link-all-history"], timeout=45)
        return "Shared local history with all profiles"

    def close_all(self):
        run_script(self.script_path, ["close-all-accounts"], timeout=35)
        return "Closed all Codex profile windows"

    def send(self, profile_id, text, submit):
        if profile_id:
            self.open_profile(profile_id)
            time.sleep(1.1)
        paste_to_codex(text, submit)
        return "Sent prompt" if submit else "Pasted prompt"

    def codex_conversations(self, profile_id="", limit=10, target="mac"):
        target = str(target or "mac").strip().lower()
        if target == "vps":
            return self.vps_conversations(profile_id=profile_id, limit=limit)
        profile = self.conversation_profile(profile_id)
        if not profile:
            return {"profile": None, "conversations": []}
        home = Path(str(profile.get("home") or "")).expanduser()
        rows = self._session_index_rows(home)
        if not rows:
            rows = self._session_file_rows(home)
        rows.sort(key=lambda row: row.get("updatedAt") or row.get("timestamp") or "", reverse=True)
        return {
            "profile": profile,
            "conversations": rows[: max(1, int(limit or 10))],
        }

    def vps_conversations(self, profile_id="", limit=10):
        selected_profile = self.conversation_profile(profile_id)
        profile_id = str((selected_profile or {}).get("id") or profile_id or "").strip()
        home = remote_codex_home(profile_id) if profile_id else DEFAULT_VPS_DEFAULT_CODEX_HOME
        script = r'''
python3 - "$1" "$2" <<'PY'
import json, os, sqlite3, sys, time
home = os.path.expanduser(sys.argv[1])
limit = int(sys.argv[2] or "20")
rows = []
db = os.path.join(home, "state_5.sqlite")
if os.path.exists(db):
    try:
        conn = sqlite3.connect("file:" + db + "?mode=ro", uri=True, timeout=2)
        cur = conn.execute("""
            SELECT id,
                   COALESCE(NULLIF(title, ''), NULLIF(first_user_message, ''), 'Untitled') AS title,
                   COALESCE(cwd, '') AS cwd,
                   COALESCE(updated_at_ms, updated_at * 1000, created_at_ms, created_at * 1000, 0) AS updated_ms
            FROM threads
            WHERE COALESCE(archived, 0) = 0
            ORDER BY updated_ms DESC, id DESC
            LIMIT ?
        """, (limit,))
        for sid, title, cwd, updated_ms in cur.fetchall():
            updated = ""
            if updated_ms:
                try:
                    updated = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(updated_ms) / 1000))
                except Exception:
                    updated = ""
            rows.append({"id": str(sid), "title": str(title), "cwd": str(cwd or ""), "projectLabel": os.path.basename(cwd) if cwd else "", "updatedAt": updated, "source": "vps_threads_sqlite"})
        conn.close()
    except Exception:
        rows = []
idx = os.path.join(home, "session_index.jsonl")
if not rows and os.path.exists(idx):
    try:
        for line in open(idx, encoding="utf-8", errors="replace"):
            try:
                item = json.loads(line)
            except Exception:
                continue
            sid = str(item.get("id") or "")
            if sid:
                rows.append({"id": sid, "title": str(item.get("thread_name") or sid), "updatedAt": str(item.get("updated_at") or ""), "cwd": "", "projectLabel": "", "source": "vps_session_index"})
            if len(rows) >= limit:
                break
    except Exception:
        pass
print(json.dumps({"conversations": rows[:limit]}, ensure_ascii=False))
PY
'''
        try:
            output = run_ssh(
                DEFAULT_VPS_HOST,
                "set -- " + shlex.quote(home) + " " + shlex.quote(str(max(1, int(limit or 10)))) + "; " + script,
                timeout=max(1, min(DEFAULT_VPS_SSH_TIMEOUT, DEFAULT_VPS_LIST_TIMEOUT)),
            )
        except Exception as exc:
            raise RuntimeError(f"VPS offline or VPN not connected ({short_error(exc)})")
        data = json.loads(output or "{}")
        return {
            "target": "vps",
            "profile": selected_profile,
            "conversations": data.get("conversations", []),
        }

    def codex_ask(self, profile_id, session_id, text, timeout=DEFAULT_CODEX_TIMEOUT, target="mac", attachments=None):
        text = str(text or "").strip()
        if str(target or "mac").strip().lower() == "vps":
            if attachments:
                raise ValueError("Attachments are currently supported on the MacBook target only.")
            return self.vps_ask(profile_id, session_id, text, timeout=timeout)
        materialized_attachments = materialize_remote_attachments(attachments)
        if not text and materialized_attachments:
            text = "請分析我上傳嘅附件。"
        if not text:
            raise ValueError("Missing prompt text")
        profile = self.conversation_profile(profile_id)
        if not profile:
            raise ValueError("No Codex profile found")
        home = Path(str(profile.get("home") or "")).expanduser()
        if not session_id:
            raise ValueError("Missing Codex session id")

        prune_remote_attachments()
        prompt = build_codex_prompt_with_attachments(text, materialized_attachments)
        image_paths = [
            str(item.get("path"))
            for item in materialized_attachments
            if str(item.get("mimeType") or "").startswith("image/") and item.get("path")
        ]

        with tempfile.NamedTemporaryFile("w+", prefix="codex-remote-last-", suffix=".txt", delete=False) as tmp:
            last_path = tmp.name

        cmd = [
            find_codex_cli(),
            "--ask-for-approval",
            "never",
            "exec",
            "resume",
            "--all",
            "--skip-git-repo-check",
        ]
        for image_path in image_paths:
            cmd.extend(["--image", image_path])
        cmd.extend([
            "--output-last-message",
            last_path,
            str(session_id),
            prompt,
        ])
        try:
            proc = subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=int(timeout or DEFAULT_CODEX_TIMEOUT),
                env=codex_env_for(home),
            )
        except subprocess.TimeoutExpired:
            return {
                "ok": False,
                "profile": profile,
                "sessionId": session_id,
                "exitCode": 124,
                "output": f"Codex timed out after {int(timeout or DEFAULT_CODEX_TIMEOUT)}s.",
            }
        except FileNotFoundError:
            return {
                "ok": False,
                "profile": profile,
                "sessionId": session_id,
                "exitCode": 127,
                "output": "Codex CLI was not found on the MacBook.",
            }

        try:
            output = Path(last_path).read_text(encoding="utf-8", errors="replace").strip()
        except Exception:
            output = ""
        try:
            Path(last_path).unlink(missing_ok=True)
        except Exception:
            pass
        if not output:
            output = (proc.stdout or "").strip()
        return {
            "ok": proc.returncode == 0,
            "profile": profile,
            "sessionId": session_id,
            "exitCode": proc.returncode,
            "output": truncate_text(output or "Codex returned no final message."),
        }

    def vps_ask(self, profile_id, session_id, text, timeout=DEFAULT_CODEX_TIMEOUT):
        selected_profile = self.conversation_profile(profile_id)
        if not selected_profile and not profile_id:
            raise ValueError("No Codex profile found")
        profile_id = str((selected_profile or {}).get("id") or profile_id or "").strip()
        if not session_id:
            raise ValueError("Missing Codex session id")
        home = remote_codex_home(profile_id) if profile_id else DEFAULT_VPS_DEFAULT_CODEX_HOME
        remote_last = f"/tmp/codex-remote-last-{secrets.token_hex(8)}.txt"
        cmd = [
            "env",
            f"CODEX_HOME={home}",
            "codex",
            "--ask-for-approval",
            "never",
            "exec",
            "resume",
            "--all",
            "--skip-git-repo-check",
            "--output-last-message",
            remote_last,
            str(session_id),
            text,
        ]
        remote_script = shell_join(cmd) + "; code=$?; cat " + shlex.quote(remote_last) + " 2>/dev/null || true; rm -f " + shlex.quote(remote_last) + "; exit $code"
        try:
            output = run_ssh(DEFAULT_VPS_HOST, remote_script, timeout=int(timeout or DEFAULT_CODEX_TIMEOUT))
            ok = True
            exit_code = 0
        except subprocess.TimeoutExpired:
            return {
                "ok": False,
                "target": "vps",
                "profile": selected_profile,
                "sessionId": session_id,
                "exitCode": 124,
                "output": f"VPS Codex timed out after {int(timeout or DEFAULT_CODEX_TIMEOUT)}s.",
            }
        except Exception as exc:
            ok = False
            exit_code = 1
            output = f"VPS offline or VPN not connected ({short_error(exc)})"
        return {
            "ok": ok,
            "target": "vps",
            "profile": selected_profile,
            "sessionId": session_id,
            "exitCode": exit_code,
            "output": truncate_text(output or "VPS Codex returned no final message."),
        }

    def profile_by_id(self, profile_id):
        wanted = str(profile_id or "").strip()
        if not wanted:
            return None
        for profile in self.profiles():
            if profile.get("id") == wanted:
                return profile
        return None

    def _session_index_rows(self, home):
        path = home / "session_index.jsonl"
        rows = []
        if not path.exists():
            return rows
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                item = json.loads(line)
            except Exception:
                continue
            session_id = str(item.get("id") or "").strip()
            if not session_id:
                continue
            rows.append({
                "id": session_id,
                "title": str(item.get("thread_name") or session_id),
                "updatedAt": str(item.get("updated_at") or ""),
            })
        return rows

    def _session_file_rows(self, home):
        rows = []
        sessions_dir = home / "sessions"
        if not sessions_dir.exists():
            return rows
        for path in sessions_dir.glob("**/rollout-*.jsonl"):
            session_id = ""
            title = ""
            updated = ""
            try:
                for line in path.open("r", encoding="utf-8", errors="replace"):
                    item = json.loads(line)
                    if item.get("type") != "session_meta":
                        continue
                    payload = item.get("payload") or {}
                    session_id = str(payload.get("id") or "")
                    title = session_id
                    updated = str(item.get("timestamp") or "")
                    break
            except Exception:
                continue
            if not session_id:
                continue
            rows.append({
                "id": session_id,
                "title": title,
                "updatedAt": updated,
            })
        return rows


def paste_to_codex(text, submit):
    submit_flag = "1" if submit else "0"
    script = r'''
on run argv
  set promptText to item 1 of argv
  set shouldSubmit to item 2 of argv
  set the clipboard to promptText
  tell application "Codex" to activate
  delay 0.25
  tell application "System Events"
    keystroke "v" using {command down}
    if shouldSubmit is "1" then
      key code 36
    end if
  end tell
end run
'''
    completed = subprocess.run(
        ["osascript", "-", text, submit_flag],
        input=script,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
    )
    if completed.returncode != 0:
        output = completed.stdout.strip()
        raise RuntimeError(output or "macOS automation failed. Grant Accessibility permission to Terminal/Codex bridge.")


class Handler(BaseHTTPRequestHandler):
    server_version = "CodexRemoteBridge/0.1"

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_common_headers()
        self.end_headers()

    def do_GET(self):
        try:
            path = urllib.parse.urlparse(self.path).path
            if path == "/health":
                self.write_json({
                    "ok": True,
                    "version": "0.1",
                    "hostname": socket.gethostname(),
                    "hasUsers": self.state.has_users(),
                    "authenticated": self.current_session() is not None,
                })
                return
            self.require_auth()
            if path == "/targets":
                self.write_json({"targets": self.state.targets()})
                return
            if path == "/profiles":
                self.write_json({"profiles": self.state.profiles()})
                return
            if path == "/codex/conversations":
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                profile_id = (query.get("profileId") or [""])[0]
                target = (query.get("target") or ["mac"])[0]
                limit = int((query.get("limit") or ["10"])[0] or 10)
                self.write_json(self.state.codex_conversations(profile_id=profile_id, limit=limit, target=target))
                return
            self.not_found()
        except StopIteration:
            return
        except PayloadTooLarge as exc:
            self.write_json({"ok": False, "error": str(exc)}, status=413)
        except PermissionError as exc:
            self.write_json({"ok": False, "error": str(exc)}, status=401)
        except Exception as exc:
            self.error_json(str(exc))

    def do_POST(self):
        try:
            path = urllib.parse.urlparse(self.path).path
            body = self.read_body()
            if path == "/auth/register":
                self.write_json({
                    "ok": False,
                    "error": "Remote users must be created from the Codex Accounts Mac app."
                }, status=403)
                return
            if path == "/auth/login":
                key = login_rate_key(self)
                assert_login_allowed(key)
                try:
                    result = self.state.login(str(body.get("username", "")), str(body.get("password", "")))
                    clear_login_failures(key)
                    self.write_json({"ok": True, **result})
                except Exception:
                    record_login_failure(key)
                    raise
                return

            if path == "/auth/logout":
                token = self.current_session_token()
                self.require_auth()
                self.write_json({"ok": True, "message": self.state.logout(token)})
                return

            self.require_auth()
            if path == "/sync":
                self.write_json({"ok": True, "message": self.state.sync()})
                return
            if path == "/vps/status":
                self.write_json(self.state.vps_status(raise_on_error=False))
                return
            if path == "/vps/sync":
                direction = str(body.get("direction", "push")).strip()
                self.write_json(self.state.sync_vps(direction=direction))
                return
            if path == "/share-all":
                self.write_json({"ok": True, "message": self.state.share_all()})
                return
            if path == "/close-all":
                self.write_json({"ok": True, "message": self.state.close_all()})
                return
            if path == "/send":
                text = str(body.get("text", "")).strip()
                if not text:
                    raise ValueError("Missing prompt text")
                profile_id = str(body.get("profileId", "")).strip()
                submit = bool(body.get("submit", True))
                self.write_json({"ok": True, "message": self.state.send(profile_id, text, submit)})
                return
            if path == "/codex/ask":
                result = self.state.codex_ask(
                    str(body.get("profileId", "")).strip(),
                    str(body.get("sessionId", "")).strip(),
                    str(body.get("text", "")).strip(),
                    timeout=int(body.get("timeout", DEFAULT_CODEX_TIMEOUT) or DEFAULT_CODEX_TIMEOUT),
                    target=str(body.get("target", "mac")).strip(),
                    attachments=body.get("attachments") or [],
                )
                self.write_json(result, status=200 if result.get("ok") else 500)
                return

            parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
            if len(parts) == 3 and parts[0] == "profiles" and parts[2] == "open":
                self.write_json({"ok": True, "message": self.state.open_profile(parts[1])})
                return
            if len(parts) == 3 and parts[0] == "profiles" and parts[2] == "close":
                self.write_json({"ok": True, "message": self.state.close_profile(parts[1])})
                return
            self.not_found()
        except StopIteration:
            return
        except PayloadTooLarge as exc:
            self.write_json({"ok": False, "error": str(exc)}, status=413)
        except PermissionError as exc:
            status = 429 if "Too many failed login attempts" in str(exc) else 401
            self.write_json({"ok": False, "error": str(exc)}, status=status)
        except Exception as exc:
            self.error_json(str(exc))

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        if length > MAX_REQUEST_BYTES:
            raise PayloadTooLarge("Request body is too large")
        data = self.rfile.read(length).decode("utf-8")
        return json.loads(data) if data else {}

    def require_auth(self):
        if self.current_session() is None:
            self.send_response(401)
            self.send_common_headers()
            self.end_headers()
            self.wfile.write(json.dumps({"ok": False, "error": "Unauthorized: sign in first"}).encode("utf-8"))
            raise StopIteration

    def current_session(self):
        token = self.current_session_token()
        return self.state.authenticate_session(token) if token else None

    def current_session_token(self):
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return None

    def write_json(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_common_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error_json(self, message):
        self.write_json({"ok": False, "error": str(message)}, status=500)

    def not_found(self):
        self.write_json({"ok": False, "error": "Not found"}, status=404)

    def send_common_headers(self):
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))


def main():
    parser = argparse.ArgumentParser(description="Codex Remote Android bridge for macOS")
    parser.add_argument("--host", default=os.environ.get("CODEX_REMOTE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CODEX_REMOTE_PORT", DEFAULT_PORT)))
    parser.add_argument("--script", default=None)
    parser.add_argument("--pid-file", default=str(PID_PATH))
    parser.add_argument("--create-user", nargs=2, metavar=("USERNAME", "PASSWORD"))
    parser.add_argument("--create-user-stdin", action="store_true")
    parser.add_argument("--delete-user", metavar="USERNAME")
    parser.add_argument("--list-users", action="store_true")
    args = parser.parse_args()

    ensure_private_app_support_dir()
    script_path = args.script or find_codex_script()

    if args.create_user_stdin:
        payload = json.loads(sys.stdin.read() or "{}")
        username = create_local_user(str(payload.get("username", "")), str(payload.get("password", "")))
        print(json.dumps({"ok": True, "username": username}, ensure_ascii=False))
        return
    if args.create_user:
        username = create_local_user(args.create_user[0], args.create_user[1])
        print(json.dumps({"ok": True, "username": username}, ensure_ascii=False))
        return
    if args.delete_user:
        username = delete_local_user(args.delete_user)
        print(json.dumps({"ok": True, "username": username}, ensure_ascii=False))
        return
    if args.list_users:
        print(json.dumps({"ok": True, "users": list_local_users()}, ensure_ascii=False))
        return

    Handler.state = BridgeState(script_path)
    server = ReusableThreadingHTTPServer((args.host, args.port), Handler)
    pid_file = Path(args.pid_file).expanduser()
    write_pid_file(pid_file)

    print("Codex Remote bridge ready")
    print(f"Script: {script_path}")
    print(f"LAN:    http://{local_ip_hint()}:{args.port}")
    print("Remote: use Tailscale or a Cloudflare Tunnel pointed at this address.")
    print("Security: create remote username/password accounts from the Codex Accounts Mac app.")
    try:
        server.serve_forever()
    finally:
        try:
            if pid_file.exists() and pid_file.read_text(encoding="utf-8").strip() == str(os.getpid()):
                pid_file.unlink()
        except Exception:
            pass


if __name__ == "__main__":
    main()
