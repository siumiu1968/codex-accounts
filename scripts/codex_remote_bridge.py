#!/usr/bin/env python3
import argparse
import base64
import glob
import hashlib
import hmac
import json
import os
import secrets
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
LOGIN_FAILURES = {}
LOGIN_WINDOW_SECONDS = 10 * 60
MAX_LOGIN_FAILURES = 8


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
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
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
    forwarded = handler.headers.get("CF-Connecting-IP") or handler.headers.get("X-Forwarded-For") or ""
    if forwarded:
        return forwarded.split(",")[0].strip()
    return handler.client_address[0] if handler.client_address else "unknown"


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
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
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


def truncate_text(text, max_chars=DEFAULT_MAX_CODEX_CHARS):
    text = (text or "").strip()
    if len(text) <= max_chars:
        return text
    keep = max_chars - 120
    return text[:keep].rstrip() + "\n\n[Output truncated by Codex Remote bridge.]"


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

    def profiles(self):
        accounts_output = run_script(self.script_path, ["list-accounts"], timeout=20)
        homes = {}
        for row in parse_pipe_lines(accounts_output):
            if len(row) >= 2:
                homes[row[0]] = row[1]

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
        return profiles

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

    def codex_conversations(self, profile_id="", limit=10):
        profile = self.profile_by_id(profile_id) if profile_id else self.best_profile()
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

    def codex_ask(self, profile_id, session_id, text, timeout=DEFAULT_CODEX_TIMEOUT):
        text = str(text or "").strip()
        if not text:
            raise ValueError("Missing prompt text")
        profile = self.profile_by_id(profile_id) if profile_id else self.best_profile()
        if not profile:
            raise ValueError("No Codex profile found")
        home = Path(str(profile.get("home") or "")).expanduser()
        if not session_id:
            raise ValueError("Missing Codex session id")

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
            "--output-last-message",
            last_path,
            str(session_id),
            text,
        ]
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
            if path == "/profiles":
                self.write_json({"profiles": self.state.profiles()})
                return
            if path == "/codex/conversations":
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                profile_id = (query.get("profileId") or [""])[0]
                limit = int((query.get("limit") or ["10"])[0] or 10)
                self.write_json(self.state.codex_conversations(profile_id=profile_id, limit=limit))
                return
            self.not_found()
        except StopIteration:
            return
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
        except PermissionError as exc:
            status = 429 if "Too many failed login attempts" in str(exc) else 401
            self.write_json({"ok": False, "error": str(exc)}, status=status)
        except Exception as exc:
            self.error_json(str(exc))

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
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
    server = ThreadingHTTPServer((args.host, args.port), Handler)
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
