#!/usr/bin/env python3
"""
devterm-gate — loopback service that fronts the ttyd PTY backend for Airlock.

Placement in the request path:

    browser --https--> tailscale serve --(identity)--> nginx owner-gate
            --(owner only / else 403)--> devterm-gate 127.0.0.1:PORT --> ttyd

The nginx owner-gate (identity) is the primary access control; this gate binds
loopback-only and re-checks the identity header as defense-in-depth. It:
  (a) serves the custom xterm.js client from DEVTERM_WEB,
  (b) proxies /ws + /token straight to ttyd (WS upgrade + frame splice),
  (c) implements the client API (sessions, tab prefs, uploads, pane ops, ...).

So ttyd is used only as the PTY backend; the UI is our own modern client
(seamless reconnect, on-screen keys, touch scroll, CJK width). ttyd's own
bundled client is never served.

Why per-request auth is airtight: non-WebSocket requests are forwarded/answered
with `Connection: close` (one request per connection = one identity check); a
WebSocket upgrade dedicates its connection.

Everything site-specific comes from the environment (set by the installer from
airlock.toml). Optional features (Claude account pool, Codex login, the fileview
file-open, the Orca worktree sidebar) are gated on config + tool presence and
degrade to a clean "disabled" response when their dependencies are absent.

Env:
  AIRLOCK_IDENTITY_HEADER  identity header name (e.g. Tailscale-User-Login)
  AIRLOCK_OWNER            comma-separated allow-list of logins (owner)
  DEVTERM_LISTEN_HOST/PORT this gate's loopback bind (default 127.0.0.1:19913)
  DEVTERM_TTYD_HOST/PORT   ttyd backend (default 127.0.0.1:19912)
  DEVTERM_WEB              web root to serve (the custom client)
  DEVTERM_FILEVIEW         "true" to enable the terminal file-path -> fileview link
  DEVTERM_ACCOUNTS         "true" to enable the Claude account pool UI
  DEVTERM_ACCOUNTS_BIN     platform account CLI (credential lifecycle/generation)
  DEVTERM_SECRET_BIN       platform secret-drop CLI (store/lifetime/metadata)
  DEVTERM_CLAUDE_SWITCH    path to the platform airlock-accounts CLI
  DEVTERM_CLAUDE_STATUS    path to the platform airlock-accounts-status probe
  DEVTERM_FLEET_STORE      path to a shared usage store file (optional)
  DEVTERM_FLEET_STORE_URL  URL of a shared usage store (optional, no default host)
  DEVTERM_ORCA_SHIM        path to the Orca CLI shim (optional; worktree sidebar)
  DEVTERM_REMOTE_HOSTS     comma-separated ssh hosts to also list tmux from (optional)
  DEVTERM_UPLOADS          uploads dir (default ~/uploads)
"""
import asyncio
import base64
import json
import math
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# The shared binary-discovery module, vendored byte-identically next to this file
# (bin_discovery.py + bin-discovery-cases.json + test_bin_discovery.py). Imported by
# path, not as a package: this file is started as a bare script by the unit AND loaded
# by absolute path from the offline suites, so neither run has backend/ on sys.path by
# construction.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bin_discovery  # noqa: E402


def _account_tool(env_name):
    """Return the platform tool path handed in through the rendered unit.

    Account features are optional, but their platform dependency is not optional once
    enabled. Falling back to an app sibling or PATH would let a stale pre-move copy run
    after ownership changed. Refuse the broken unit at import time instead, with the
    missing ABI bridge named explicitly.
    """
    configured = os.environ.get(env_name, "").strip()
    if not configured:
        raise RuntimeError(f"{env_name} is required when its devterm account feature is enabled")
    return os.path.expanduser(configured)


ALLOW = {s.strip().lower() for s in os.environ.get("AIRLOCK_OWNER", "").split(",") if s.strip()}
# ssh hosts whose tmux sessions are also surfaced as tabs (comma-separated).
# Empty = local sessions only. Fully inert when unset.
REMOTE_HOSTS = [h.strip() for h in os.environ.get("DEVTERM_REMOTE_HOSTS", "").split(",") if h.strip()]
LISTEN_HOST = os.environ.get("DEVTERM_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("DEVTERM_LISTEN_PORT", "19913"))
TTYD_HOST = os.environ.get("DEVTERM_TTYD_HOST", "127.0.0.1")
TTYD_PORT = int(os.environ.get("DEVTERM_TTYD_PORT", "19912"))
WEB_ROOT = os.path.realpath(os.environ.get("DEVTERM_WEB", os.path.expanduser("~/.local/share/airlock-devterm/web")))

# ---- optional feature config (all degrade to disabled when unset/absent) ----
FILEVIEW = os.environ.get("DEVTERM_FILEVIEW", "false").lower() == "true"
ACCOUNTS = os.environ.get("DEVTERM_ACCOUNTS", "false").lower() == "true"
XAI = os.environ.get("DEVTERM_XAI", "false").lower() == "true"
CLAUDE_SWITCH = _account_tool("DEVTERM_CLAUDE_SWITCH") if ACCOUNTS else ""
CLAUDE_STATUS = _account_tool("DEVTERM_CLAUDE_STATUS") \
    if (ACCOUNTS or XAI) else ""
# Credential lifecycle must bypass the deprecated claude_switch compatibility
# override: an operator-supplied legacy tool is allowed to implement the old account
# verbs, but it cannot be assumed to implement the platform-only Codex preservation
# verb added in P2b. The installer therefore hands the platform binary in separately.
PLATFORM_ACCOUNTS = os.environ.get("DEVTERM_ACCOUNTS_BIN", "").strip()
# No sibling/PATH fallback: after the ownership move either the D5 hand-in is present or
# the relay fails visibly. Finding a stale app copy would be a silent split-brain store.
PLATFORM_SECRET = os.environ.get("DEVTERM_SECRET_BIN", "").strip()
# A shared usage store used to annotate the account pool with utilization. Both are
# optional; no host is hardcoded. Left empty => the account list still works, just
# without usage numbers.
FLEET_STORE = os.path.expanduser(os.environ["DEVTERM_FLEET_STORE"]) if os.environ.get("DEVTERM_FLEET_STORE") else ""
FLEET_STORE_URL = os.environ.get("DEVTERM_FLEET_STORE_URL", "")
ORCA_SHIM = os.path.expanduser(os.environ.get("DEVTERM_ORCA_SHIM", ""))

# ---- subscription warning thresholds (the single source of truth) ----
# These numbers live here and nowhere else. /accounts ships them to the frontend as
# `thresholds` and /acct-alert ships the *verdict*; if a frontend kept its own copy,
# the row colour and the widget ring would disagree the moment one of them changed.
#   warn5/crit5 = 5h window %, warn7/crit7 = 7d window %,
#   rtWarnDays  = warn when the refresh token expires within this many days.
# There is deliberately no "spent" threshold above crit5. One existed (lock5 = 100) and
# both graders read it as "stop looking at the 5h axis", so a window at 100% scored
# healthy — the exhausted account rendered green while a 95% one rendered red. 100 is
# already >= crit5; a separate number for it only bought a way to exempt it.
USAGE_TH = {"warn5": 78, "crit5": 88, "warn7": 88, "crit7": 93, "rtWarnDays": 5}
ACCT_ALERT_TTL = 30          # /acct-alert response cache (s): N tabs polling every 30s
                             # still costs one claude-switch call per window.
LIVE_USAGE_TTL = 60          # cache for the live account's own usage probe (s) — used
                             # when no shared store is configured (the common case for a
                             # single box). Long enough that a ring poll never bursts.
CODEX_USAGE_TTL = 300        # 5 min. The weekly window moves a couple of % per day, so
                             # this resolution is plenty and one app-server spawn is not.
CODEX_USAGE_WAIT = 20        # how long a /codex-usage request waits for a fresh reading
CODEX_USAGE_RETRY = 30       # retry backoff after a failure — a failure must not buy
                             # itself a full TTL of silence
# Must be comfortably larger than claude-status's own CODEX_REAP_GRACE (0.5s): that
# script promotes SIGTERM to SIGKILL itself, and we only step in if it never got there.
PROBE_KILL_GRACE = 3.0
XAI_LOGOUT_WAIT = 20
_acct_alert_cache = {"at": 0.0, "payload": None}
_live_usage_cache = {"at": 0.0, "payload": None}
_acct_cache_generation = 0
_codex_usage_cache = {"valueAt": 0.0, "lastTryAt": 0.0,
                      "payload": None, "authMtime": None, "task": None}
_CODEX_AUTH_GENERATION_UNAVAILABLE = object()

# Claude Code session logs (used to reconstruct conversation text for the copy
# modal when the pane is running `claude`; degrades to screen capture otherwise).
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")

MAX_HEAD = 64 * 1024
MAX_BODY = 210 * 1024 * 1024         # inbound body cap — accommodates a 200MB raw file upload plus headroom
LOGIN_CODE_BODY_MAX = 1024            # one <=400-byte code plus small JSON framing
IDENT_HEADER = os.environ.get("AIRLOCK_IDENTITY_HEADER", "").strip().lower().encode("latin1")
TTYD_PATHS = (b"/ws", b"/token")
DEVTERM_STATE_DIR = os.path.expanduser("~/.local/share/airlock-devterm/state")
XAI_LOGIN_OUT = os.path.join(DEVTERM_STATE_DIR, "xai-login.out")
_xai_login_process = None
_xai_operation_lock = asyncio.Lock()
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# ---- clipboard image / file uploads — shared ~/uploads drop (24h TTL) ----
UPLOADS = os.path.expanduser(os.environ.get("DEVTERM_UPLOADS", "~/uploads"))
_RE_UPLOAD = re.compile(r"^image([0-9]{3,})-[0-9]{8}-[0-9]{6}\.jpg\Z")   # auto-saved images only (protects manual files)
_RE_UPLOAD_FILE = re.compile(r"^file([0-9]{3,})-[0-9]{8}-[0-9]{6}\.")   # uploaded-file seq (any extension)
UPLOAD_TTL_SEC = 24 * 3600
UPLOAD_MAX_BYTES = 12 * 1024 * 1024           # image save cap (paste/annotate — canvas-encoded, so far smaller in practice)
FILE_MAX_BYTES = 200 * 1024 * 1024            # file upload save cap (arbitrary binary). ~/uploads has a 24h TTL so no disk creep

# ---- secret drop HTTP relay -------------------------------------------------
# The platform CLI owns the store, validation, modes, atomicity, cap and lifetime. This
# app still owns the HTTP boundary: Content-Type, body size and same-origin refusal are
# meaningful only here. A divergent guard refuses visibly; a divergent store silently
# leaves a value alive or world-readable, which is why only the latter consolidates.
SECRET_BODY_MAX = 96 * 1024
_SECRET_ERRORS = {
    "invalid name", "value required", "value not encodable", "value too large",
    "secret limit reached", "secret storage failed", "secret deletion failed",
    "secret configuration failed", "secret operation failed", "usage",
}

# ---- tab prefs (order / hidden / color / theme) stored server-side so any device
#      or browser sees the same layout. Owner is singular, so one file. ----
PREFS_DIR = os.path.expanduser("~/.config/airlock-devterm")
PREFS_PATH = os.path.join(PREFS_DIR, "tabs.json")
PREFS_MAX = 256 * 1024

# ---- last known Codex usage, kept across restarts ----
# The in-memory cache dies with the process, and the reading costs an app-server spawn
# that takes up to CODEX_USAGE_WAIT seconds. So every gate restart used to open the panel
# on a blank Codex row and hold it there while the probe ran. The number is a few minutes
# old at worst and the row already has a vocabulary for that ("(last value)"), so showing
# the remembered one immediately and correcting it when the probe lands beats showing
# nothing. State, not config — it is derived and disposable.
# This app-owned directory is covered by devterm's declared share artifact. The
# platform's ~/.local/state/airlock directory owns the install ledger and lock, so an
# app package must not claim a child of it for lifecycle cleanup.
CODEX_USAGE_STATE_DIR = DEVTERM_STATE_DIR
CODEX_USAGE_STATE = os.path.join(CODEX_USAGE_STATE_DIR, "codex-usage.json")
LEGACY_CODEX_USAGE_STATE = os.path.expanduser(
    "~/.local/state/airlock/devterm/codex-usage.json")
# The Claude account pool has a separate Airlock-owned display cache. It deliberately
# shares the directory with Codex state, but never writes the fleet store (whose owner
# is the out-of-process collector).
CLAUDE_USAGE_STATE_DIR = CODEX_USAGE_STATE_DIR
CLAUDE_USAGE_STATE = os.path.join(CLAUDE_USAGE_STATE_DIR, "claude-usage.json")
CLAUDE_USAGE_MAX_AGE = 30 * 86400
CLAUDE_USAGE_FUTURE_SKEW = 5 * 60
_claude_usage_write_logged = False

_CTYPES = {
    ".html": b"text/html; charset=utf-8", ".js": b"text/javascript; charset=utf-8",
    ".css": b"text/css; charset=utf-8", ".json": b"application/json; charset=utf-8",
    ".svg": b"image/svg+xml", ".png": b"image/png", ".ico": b"image/x-icon",
    ".map": b"application/json; charset=utf-8", ".woff2": b"font/woff2",
}
_FORBIDDEN = (
    b"<!doctype html><meta charset=utf-8><title>403</title>"
    b"<body style='font:16px system-ui;padding:2rem;color:#333'>"
    b"<h1>403 Forbidden</h1><p>This web terminal is restricted to its owner.</p>"
)


def _resp(status, body, ctype=b"text/html; charset=utf-8", cache=b"no-store, must-revalidate",
          extra=b""):
    # no-store default: html/js change often, so no stale caching. Only big static
    # assets (fonts) opt into caching. `extra` carries already-formatted header lines
    # (each CRLF-terminated) — used for the ACAO echo on cross-origin reads.
    return (b"HTTP/1.1 " + status + b"\r\nContent-Type: " + ctype +
            b"\r\nContent-Length: " + str(len(body)).encode() +
            b"\r\nCache-Control: " + cache + b"\r\n" + extra +
            b"Connection: close\r\n\r\n" + body)


async def _read_head(reader):
    buf = b""
    while b"\r\n\r\n" not in buf:
        if len(buf) > MAX_HEAD:
            return None, b""
        chunk = await reader.read(4096)
        if not chunk:
            return None, b""
        buf += chunk
    head, _, leftover = buf.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", leftover


def _parse_headers(head):
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        if line and b":" in line:
            k, _, v = line.partition(b":")
            headers[k.strip().lower()] = v.strip()
    return headers


def _request_path(head):
    try:
        target = head.split(b"\r\n", 1)[0].split(b" ")[1]
    except IndexError:
        return b"/"
    return target.split(b"?", 1)[0]


def _request_query(head):
    """Query string (bytes) after '?' — _request_path strips it, so extract separately."""
    try:
        target = head.split(b"\r\n", 1)[0].split(b" ")[1]
    except IndexError:
        return b""
    parts = target.split(b"?", 1)
    return parts[1] if len(parts) > 1 else b""


def _is_websocket(headers):
    return b"websocket" in headers.get(b"upgrade", b"").lower()


def _rewrite_connection_close(head):
    lines = head.split(b"\r\n")
    out = [lines[0]]
    for line in lines[1:]:
        if line == b"":
            break
        if line.split(b":", 1)[0].strip().lower() in (b"connection", b"keep-alive"):
            continue
        out.append(line)
    out.append(b"Connection: close")
    return b"\r\n".join(out) + b"\r\n\r\n"


def _resolve_static(path):
    """Map URL path to a file under WEB_ROOT; None if traversal/missing."""
    rel = path.decode("latin1", "replace").lstrip("/")
    if rel in ("", "/"):
        rel = "index.html"
    full = os.path.realpath(os.path.join(WEB_ROOT, rel))
    if full != WEB_ROOT and not full.startswith(WEB_ROOT + os.sep):
        return None
    if not os.path.isfile(full):
        return None
    return full


async def _pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError, asyncio.CancelledError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except OSError:
            pass


async def _splice(cr, cw, br, bw):
    tasks = {asyncio.create_task(_pipe(cr, bw)), asyncio.create_task(_pipe(br, cw))}
    _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    for t in pending:
        try:
            await t
        except asyncio.CancelledError:
            pass


async def _proxy_ttyd(head, leftover, headers, cr, cw):
    try:
        br, bw = await asyncio.open_connection(TTYD_HOST, TTYD_PORT)
    except OSError:
        cw.write(_resp(b"502 Bad Gateway", b"ttyd backend unreachable", b"text/plain; charset=utf-8"))
        await cw.drain()
        return
    try:
        if _is_websocket(headers):
            bw.write(head + leftover)
        else:
            bw.write(_rewrite_connection_close(head) + leftover)
        await bw.drain()
        await _splice(cr, cw, br, bw)
    finally:
        try:
            bw.close()
        except OSError:
            pass


_SESS_FMT = "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}"


def _parse_sessions(out, host=None):
    """tmux list-sessions -F _SESS_FMT output -> list of session dicts. When host is
    given, entries are remote (encoded name + display label)."""
    sessions = []
    for line in out.splitlines():
        p = line.split("\t")
        if not p or not p[0]:
            continue
        s = {
            "windows": int(p[1]) if len(p) > 1 and p[1].isdigit() else None,
            "attached": len(p) > 2 and p[2] == "1",
            "activity": int(p[3]) if len(p) > 3 and p[3].isdigit() else 0,   # last-activity unix ts (most-recent detection)
        }
        if host:
            s["name"] = "RMT__" + host + "__" + p[0]   # tab identifier (won't collide with local) — devterm-shell parses it to ssh attach
            s["host"] = host
            s["label"] = p[0]                          # display label (app.js prefixes '*')
        else:
            s["name"] = p[0]
        sessions.append(s)
    return sessions


_remote_cache = {}   # host -> (expiry_ts, sessions) — avoids flooding ssh under frequent polling (4s TTL, failures cached too)


async def _list_remote_sessions(host):
    now = time.time()
    c = _remote_cache.get(host)
    if c and c[0] > now:
        return c[1]
    result = []
    try:
        proc = await asyncio.create_subprocess_exec(
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host,
            "tmux list-sessions -F '" + _SESS_FMT + "'",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
        result = _parse_sessions(out.decode("utf-8", "replace"), host=host)
    except (OSError, asyncio.TimeoutError):
        result = []
    _remote_cache[host] = (now + 4, result)
    return result


# ---- upload mirror (only active when DEVTERM_REMOTE_HOSTS is set) — push ~/uploads
#      to the attached remote session's host so pasted-image / uploaded-file tokens
#      (~/uploads/...) resolve for the agent running in that remote session. Direction
#      is always outward (local -> remote). New files only (--ignore-existing),
#      minimum 45s between pushes. Fully inert when REMOTE_HOSTS is empty.
_MIRROR_MIN_INTERVAL = 45
_last_mirror = {}   # host -> last mirror time


async def _mirror_uploads(host):
    now = time.time()
    if now - _last_mirror.get(host, 0) < _MIRROR_MIN_INTERVAL:
        return
    if not os.path.isdir(UPLOADS):
        return
    _last_mirror[host] = now   # spin guard — no retry until the next interval even on failure
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            "rsync", "-rt", "--ignore-existing", "--timeout=20",
            "--include=image*", "--include=file*", "--exclude=*",
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new",
            UPLOADS + "/", host + ":uploads/",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await asyncio.wait_for(proc.wait(), timeout=30)
    except (OSError, asyncio.TimeoutError):
        if proc is not None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass


async def _serve_sessions(cw):
    """Live tmux sessions (local + any DEVTERM_REMOTE_HOSTS). Remote is inert unless configured."""
    sessions = []
    try:
        proc = await asyncio.create_subprocess_exec(
            "tmux", "list-sessions", "-F", _SESS_FMT,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await proc.communicate()
        sessions = _parse_sessions(out.decode("utf-8", "replace"))
    except (OSError, ValueError):
        pass
    for host in REMOTE_HOSTS:
        rs = await _list_remote_sessions(host)
        sessions.extend(rs)
        if any(s.get("attached") for s in rs):
            asyncio.ensure_future(_mirror_uploads(host))   # only while attached — fire-and-forget mirror (non-blocking)
    await _send_json(cw, b"200 OK", {"sessions": sessions})


async def _serve_static(path, cw):
    full = _resolve_static(path)
    if full is None:
        cw.write(_resp(b"404 Not Found", b"not found", b"text/plain; charset=utf-8"))
        await cw.drain()
        return
    ext = os.path.splitext(full)[1].lower()
    ctype = _CTYPES.get(ext, b"application/octet-stream")
    cache = (b"public, max-age=604800" if ext in (".woff2", ".woff", ".ttf")
             else b"no-store, must-revalidate")
    try:
        with open(full, "rb") as f:
            body = f.read()
    except OSError:
        cw.write(_resp(b"404 Not Found", b"not found", b"text/plain; charset=utf-8"))
        await cw.drain()
        return
    cw.write(_resp(b"200 OK", body, ctype, cache))
    await cw.drain()


def _secret_origin_ok(headers):
    """Same-origin guard for the secret endpoints.

    Unlike the read-only alert, these WRITE. The identity header cannot be forged from
    the tailnet (this gate is loopback-only), but a page on another origin could still
    make the browser POST here, so a cross-origin request is refused outright rather
    than answered. No Origin header at all (curl, the terminal itself) is fine."""
    origin = headers.get(b"origin", b"")
    if not origin:
        return True
    host = headers.get(b"host", b"").decode("latin1").lower()
    try:
        parsed = urllib.parse.urlsplit(origin.decode("latin1"))
        same = parsed.scheme in ("http", "https") and parsed.netloc.lower() == host
    except (UnicodeError, ValueError):
        return False
    return bool(host) and same


def _secret_payload(command, payload, expected_name=None):
    """Validate and rebuild CLI output before it crosses the HTTP boundary.

    stdout is a platform contract, not a response body to reflect blindly. Rebuilding
    the bounded metadata shape means a future CLI regression cannot add a value field
    and turn this relay into an exfiltration path.
    """
    if not isinstance(payload, dict) or type(payload.get("ok")) is not bool:
        return None
    if payload["ok"] is False:
        error = payload.get("error")
        if error not in _SECRET_ERRORS:
            error = "secret operation failed"
        return {"ok": False, "error": error}
    if command == "put":
        if payload.get("name") != expected_name or not isinstance(payload.get("path"), str) \
                or type(payload.get("ttl_sec")) is not int \
                or type(payload.get("remain_sec")) is not int:
            return None
        return {key: payload[key] for key in ("ok", "name", "path", "ttl_sec", "remain_sec")}
    if command == "del":
        if payload.get("name") != expected_name:
            return None
        return {"ok": True, "name": expected_name}
    if command == "list":
        if type(payload.get("ttl_sec")) is not int or not isinstance(payload.get("secrets"), list):
            return None
        items = []
        for item in payload["secrets"]:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str) \
                    or not isinstance(item.get("path"), str) \
                    or type(item.get("bytes")) is not int \
                    or type(item.get("remain_sec")) is not int:
                return None
            items.append({key: item[key] for key in ("name", "path", "bytes", "remain_sec")})
        return {"ok": True, "secrets": items, "ttl_sec": payload["ttl_sec"]}
    return None


async def _secret_cli(command, name=None, raw=None):
    """Run one platform secret operation; the value is the subprocess stdin only."""
    if not PLATFORM_SECRET:
        return {"ok": False, "error": "secret operation failed"}
    argv = [PLATFORM_SECRET, command]
    if name is not None:
        argv.extend(("--", name))
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE if raw is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(raw), timeout=10)
    except asyncio.TimeoutError:
        if proc is not None:
            proc.kill()
            await proc.wait()
        return {"ok": False, "error": "secret operation failed"}
    except (FileNotFoundError, OSError):
        return {"ok": False, "error": "secret operation failed"}
    try:
        decoded = json.loads((out or b"").decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return {"ok": False, "error": "secret operation failed"}
    payload = _secret_payload(command, decoded, expected_name=name)
    if payload is None or (proc.returncode == 0) != payload.get("ok"):
        return {"ok": False, "error": "secret operation failed"}
    return payload


def _secret_status(payload):
    if payload.get("ok"):
        return b"200 OK"
    if payload.get("error") == "value too large":
        return b"413 Payload Too Large"
    if payload.get("error") in {
            "invalid name", "value required", "value not encodable", "secret limit reached"}:
        return b"400 Bad Request"
    return b"500 Internal Server Error"


async def _serve_secret_put(cr, headers, leftover, cw):
    """HTTP guard + stdin-only relay. Storage and value normalization are platform-owned."""
    if headers.get(b"content-type", b"").split(b";", 1)[0].strip().lower() != b"application/json":
        await _send_json(cw, b"415 Unsupported Media Type",
                         {"ok": False, "error": "Content-Type must be application/json"})
        return
    if not _secret_origin_ok(headers):
        await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "origin not allowed"})
        return
    try:
        declared = int(headers.get(b"content-length", b"0"))
    except ValueError:
        declared = 0
    if declared > SECRET_BODY_MAX:
        await _send_json(cw, b"413 Payload Too Large", {"ok": False, "error": "secret body too large"})
        return
    d = await _read_json_body(cr, headers, leftover, limit=SECRET_BODY_MAX)
    name = d.get("name") if d is not None else None
    value = d.get("value") if d is not None else None
    if not isinstance(name, str):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid name"})
        return
    if not isinstance(value, str):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "value required"})
        return
    try:
        raw = value.encode("utf-8")
    except UnicodeEncodeError:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "value not encodable"})
        return
    payload = await _secret_cli("put", name=name, raw=raw)
    await _send_json(cw, _secret_status(payload), payload)


async def _serve_secret_list(headers, cw):
    """Metadata for the unexpired secrets — names, sizes, time left. Never a value."""
    if not _secret_origin_ok(headers):
        await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "origin not allowed"})
        return
    payload = await _secret_cli("list")
    await _send_json(cw, _secret_status(payload), payload)


async def _serve_secret_del(cr, headers, leftover, cw):
    """Delete by name. A valid name that is already gone is still a success (the caller
    wanted it gone, and it is)."""
    if headers.get(b"content-type", b"").split(b";", 1)[0].strip().lower() != b"application/json":
        await _send_json(cw, b"415 Unsupported Media Type",
                         {"ok": False, "error": "Content-Type must be application/json"})
        return
    if not _secret_origin_ok(headers):
        await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "origin not allowed"})
        return
    try:
        declared = int(headers.get(b"content-length", b"0"))
    except ValueError:
        declared = 0
    if declared > SECRET_BODY_MAX:
        await _send_json(cw, b"413 Payload Too Large", {"ok": False, "error": "secret body too large"})
        return
    d = await _read_json_body(cr, headers, leftover, limit=SECRET_BODY_MAX)
    name = d.get("name") if d is not None else None
    if not isinstance(name, str):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid name"})
        return
    payload = await _secret_cli("del", name=name)
    await _send_json(cw, _secret_status(payload), payload)


def _cleanup_old_uploads():
    """Remove regular files in ~/uploads past the TTL (protects dirs/symlinks)."""
    if not os.path.isdir(UPLOADS):
        return 0
    cutoff = time.time() - UPLOAD_TTL_SEC
    removed = 0
    for name in os.listdir(UPLOADS):
        full = os.path.join(UPLOADS, name)
        try:
            if os.path.isfile(full) and not os.path.islink(full) and os.path.getmtime(full) < cutoff:
                os.unlink(full)
                removed += 1
        except OSError:
            pass
    return removed


def _next_seq(pattern):
    """Max seq + 1 among files in UPLOADS matching pattern (capture group 1 = seq)."""
    mx = 0
    if os.path.isdir(UPLOADS):
        for name in os.listdir(UPLOADS):
            m = pattern.match(name)
            if m and os.path.isfile(os.path.join(UPLOADS, name)):
                mx = max(mx, int(m.group(1)))
    return mx + 1


def _store_upload(raw, prefix, ext, seq_re):
    """Store validated raw bytes as ~/uploads/{prefix}NNN-date-time.{ext} atomically.
    Returns (ok, result|error). prefix and seq_re are two views of one naming rule —
    change them together. asyncio is single-threaded, so cleanup->seq->O_EXCL write
    has no await between = atomic (no lock)."""
    _cleanup_old_uploads()
    os.makedirs(UPLOADS, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    n = _next_seq(seq_re)
    for _ in range(100):
        fname = f"{prefix}{n:03d}-{ts}.{ext}"
        fpath = os.path.join(UPLOADS, fname)
        try:
            fd = os.open(fpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            n += 1
            continue
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        return True, {"name": fname, "path": f"~/uploads/{fname}", "n": n, "bytes": len(raw)}
    return False, "sequence exhausted"


def _save_uploaded_image(image_b64):
    """base64 JPEG -> ~/uploads/imageNNN-date-time.jpg. (ok, result|error). Server-
    generated filename = no traversal."""
    if not image_b64 or not isinstance(image_b64, str):
        return False, "no image"
    if image_b64.startswith("data:"):
        comma = image_b64.find(",")
        if comma != -1:
            image_b64 = image_b64[comma + 1:]
    try:
        raw = base64.b64decode(image_b64, validate=True)
    except Exception:
        return False, "invalid base64"
    if not raw:
        return False, "empty image"
    if len(raw) > UPLOAD_MAX_BYTES:
        return False, f"image too large (>{UPLOAD_MAX_BYTES // (1024 * 1024)}MB)"
    if raw[:3] != b"\xff\xd8\xff":                 # JPEG magic (the front-end canvas encodes to jpeg)
        return False, "not a jpeg"
    return _store_upload(raw, "image", "jpg", _RE_UPLOAD)


def _safe_ext(orig_name):
    """Take just the extension from the original name and sanitize it
    ([A-Za-z0-9] lowercase <=8). Empty -> bin. (Filename is server-generated.)"""
    base = (orig_name or "").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    dot = base.rfind(".")
    ext = base[dot + 1:] if 0 <= dot < len(base) - 1 else ""
    ext = re.sub(r"[^A-Za-z0-9]", "", ext).lower()[:8]
    return ext or "bin"


def _save_uploaded_file(raw, orig_name):
    """raw bytes -> ~/uploads/fileNNN-date-time.ext. (ok, result|error). Arbitrary
    binary (extension safely extracted from the original name)."""
    if not raw:
        return False, "empty file"
    if len(raw) > FILE_MAX_BYTES:
        return False, f"file too large (>{FILE_MAX_BYTES // (1024 * 1024)}MB)"
    return _store_upload(raw, "file", _safe_ext(orig_name), _RE_UPLOAD_FILE)


async def _read_body(reader, headers, leftover, limit=MAX_BODY):
    """Read Content-Length bytes of body (incl. leftover). None if over cap / short."""
    try:
        clen = int(headers.get(b"content-length", b"0"))
    except ValueError:
        return None
    if clen <= 0 or clen > limit:
        return None
    buf = bytearray(leftover)
    while len(buf) < clen:
        chunk = await reader.read(min(65536, clen - len(buf)))
        if not chunk:
            break
        buf += chunk
    if len(buf) < clen:
        return None          # early close = truncated body -> refuse to save a partial file (caller returns 413)
    return bytes(buf[:clen])


async def _read_json_body(cr, headers, leftover, limit=MAX_BODY):
    """body -> JSON dict. None on missing/short/over-cap/non-JSON/non-dict (caller decides meaning)."""
    body = await _read_body(cr, headers, leftover, limit=limit)
    if body is None or len(body) > limit:
        return None
    try:
        obj = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def _finite_number(value):
    """The value if it is a real finite number, else None. Guards every threshold
    comparison: a NaN would silently compare False and mute a warning."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            if math.isfinite(value):
                return value
        except (OverflowError, ValueError):
            pass
    return None


def _cors_origin(headers):
    """The request Origin if it is *this box on another port*, else None.

    Why: the Airlock return widget is injected into upstream bundles that run on their
    own ports (a browser IDE, an agent runner, ...), so it reads /acct-alert
    cross-origin. Identity comes from the ingress header, not a cookie, so a simple
    credential-less GET needs nothing but an echoed ACAO (no preflight, no ACAC).

    Never '*' and never an arbitrary origin: tailnet domains are public suffixes, so a
    *different node* would also be same-site. Echo only when the origin's first
    hostname label equals this host's — same box, any port.
    """
    origin = headers.get(b"origin", b"")
    if not origin:
        return None
    try:
        h = urllib.parse.urlsplit(origin.decode("latin1")).hostname or ""
    except (UnicodeError, ValueError):
        return None
    if h and h.split(".")[0] == socket.gethostname().split(".")[0]:
        return origin
    return None


async def _send_json(cw, status, payload, cors=None):
    extra = b""
    if cors:
        extra = b"Access-Control-Allow-Origin: " + cors + b"\r\nVary: Origin\r\n"
    cw.write(_resp(status, json.dumps(payload).encode(),
                   b"application/json; charset=utf-8", extra=extra))
    await cw.drain()


async def _tmux(*args):
    """Run tmux <args> -> (ok, stderr_text). stdout ignored, stderr captured."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "tmux", *args,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _, serr = await proc.communicate()
        if proc.returncode == 0:
            return True, ""
        return False, serr.decode("utf-8", "replace").strip()
    except OSError as e:
        return False, str(e)


async def _tmux_out(*args):
    """Run tmux <args> -> (ok, stdout_text). For value queries (display-message etc)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "tmux", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        sout, _ = await proc.communicate()
        if proc.returncode == 0:
            return True, sout.decode("utf-8", "replace").strip()
        return False, ""
    except OSError:
        return False, ""


def _parse_remote_session(raw):
    """Session id -> (host, session, valid).
    Local = (None, name, True). RMT__<host>__<sess> with host in REMOTE_HOSTS =
    (host, sess, True). Unknown remote (host not allowed / malformed) =
    (None, None, False) — blocks pointing ssh at an arbitrary target."""
    if isinstance(raw, str) and raw.startswith("RMT__"):
        host, sep, sess = raw[len("RMT__"):].partition("__")
        if sep and host in REMOTE_HOSTS and sess:
            return host, sess, True
        return None, None, False
    return None, raw, True


def _ssh_tmux_cmd(host, args):
    """Assemble a remote tmux command as a single ssh argument — the remote shell
    re-parses it, so each arg is shlex-quoted (e.g. so '#{...}' isn't treated as a
    comment by the remote shell)."""
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host,
            "tmux " + " ".join(shlex.quote(a) for a in args)]


async def _tmux_r(host, *args):
    """Local (host=None) or remote (ssh host) tmux -> (ok, stderr_text)."""
    if not host:
        return await _tmux(*args)
    try:
        proc = await asyncio.create_subprocess_exec(
            *_ssh_tmux_cmd(host, args),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _, serr = await asyncio.wait_for(proc.communicate(), timeout=10)
        if proc.returncode == 0:
            return True, ""
        return False, serr.decode("utf-8", "replace").strip()
    except (OSError, asyncio.TimeoutError) as e:
        return False, str(e)


async def _tmux_out_r(host, *args):
    """Local/remote tmux -> (ok, stdout_text)."""
    if not host:
        return await _tmux_out(*args)
    try:
        proc = await asyncio.create_subprocess_exec(
            *_ssh_tmux_cmd(host, args),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        sout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        if proc.returncode == 0:
            return True, sout.decode("utf-8", "replace").strip()
        return False, ""
    except (OSError, asyncio.TimeoutError):
        return False, ""


def _safe_name(s):
    """Sanitize a tmux session name: non-allowed chars -> _, cut to 64
    (with exec args, not a shell, this blocks injection)."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", s)[:64] if s else ""


# ---- Orca ADE integration (worktree source of truth) — optional; enabled only when
# DEVTERM_ORCA_SHIM points at a present Orca CLI shim. devterm does not manage its
# own worktrees; it shares Orca's real worktrees and launches agents (tmux) in the
# worktree cwd. When the shim is absent or the runtime is down, _orca returns None
# and the front-end falls back to the top-tabs layout.


async def _orca(*args, timeout=45):
    """Run the Orca CLI '<args> --json' -> parsed dict. Not-installed / timeout /
    non-JSON -> None. exec args (not a shell) so no injection."""
    if not ORCA_SHIM or not os.path.isfile(ORCA_SHIM):
        return None
    try:
        proc = await asyncio.create_subprocess_exec(
            ORCA_SHIM, *args, "--json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except (OSError, asyncio.TimeoutError):
        try:
            proc.kill()
        except (OSError, UnboundLocalError, NameError):
            pass
        return None
    try:
        return json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return None


def _short_branch(ref):
    return ref[len("refs/heads/"):] if isinstance(ref, str) and ref.startswith("refs/heads/") else (ref or "")


def _orca_err(d, default):
    e = (d or {}).get("error")
    return (e.get("message") if isinstance(e, dict) else None) or default


async def _serve_orca_status(cw):
    if not ORCA_SHIM:
        await _send_json(cw, b"200 OK", {"ok": False, "ready": False, "installed": False})
        return
    d = await _orca("status", timeout=20)
    ready = bool(d and d.get("ok") and d.get("result", {}).get("runtime", {}).get("reachable"))
    await _send_json(cw, b"200 OK", {"ok": bool(d and d.get("ok")), "ready": ready,
                                     "installed": os.path.isfile(ORCA_SHIM)})


async def _serve_orca_tree(cw):
    """Project (repo) -> worktree tree (Orca's real worktrees = same source as the Orca app)."""
    repos_d = await _orca("repo", "list")
    wts_d = await _orca("worktree", "list")
    if not (repos_d and repos_d.get("ok") and wts_d and wts_d.get("ok")):
        await _send_json(cw, b"200 OK", {"ok": False, "repos": []})
        return
    by_repo = {}
    for w in wts_d["result"].get("worktrees", []):
        by_repo.setdefault(w.get("repoId"), []).append({
            "id": w.get("id"), "path": w.get("path"),
            "branch": _short_branch(w.get("branch")),
            "displayName": w.get("displayName") or os.path.basename(w.get("path", "")),
            "isMain": bool(w.get("isMainWorktree")),
            "status": w.get("workspaceStatus") or "",
        })
    out = []
    for r in repos_d["result"].get("repos", []):
        wl = by_repo.pop(r.get("id"), [])
        wl.sort(key=lambda x: (not x["isMain"], x["displayName"].lower()))
        out.append({"id": r.get("id"), "name": r.get("displayName") or os.path.basename(r.get("path", "")),
                    "path": r.get("path"), "worktrees": wl})
    await _send_json(cw, b"200 OK", {"ok": True, "repos": out})


async def _serve_orca_worktree_create(cr, headers, leftover, cw):
    body = await _read_json_body(cr, headers, leftover, limit=PREFS_MAX) or {}
    repo_id = str(body.get("repoId", "")).strip()
    name = str(body.get("name", "")).strip()
    base = str(body.get("baseBranch", "")).strip()
    if not repo_id or not name:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "repoId and name required"})
        return
    args = ["worktree", "create", "--repo", "id:" + repo_id, "--name", name]
    if base:
        args += ["--base-branch", base]
    d = await _orca(*args, timeout=150)   # checkout can take a while
    if not (d and d.get("ok")):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": _orca_err(d, "worktree create failed")})
        return
    await _send_json(cw, b"200 OK", {"ok": True, "worktree": d.get("result", {})})


async def _serve_orca_worktree_rm(cr, headers, leftover, cw):
    body = await _read_json_body(cr, headers, leftover, limit=PREFS_MAX) or {}
    path = str(body.get("path", "")).strip()
    if not path:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "path required"})
        return
    d = await _orca("worktree", "rm", "--worktree", "path:" + path, "--force", timeout=90)
    if not (d and d.get("ok")):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": _orca_err(d, "worktree remove failed")})
        return
    await _send_json(cw, b"200 OK", {"ok": True})


async def _serve_orca_worktree_set(cr, headers, leftover, cw):
    """Change a worktree's Orca metadata — currently only displayName. git path/branch
    are immutable (keeps session names stable)."""
    body = await _read_json_body(cr, headers, leftover, limit=PREFS_MAX) or {}
    path = str(body.get("path", "")).strip()
    dn = str(body.get("displayName", "")).strip()
    if not path or not dn:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "path and displayName required"})
        return
    d = await _orca("worktree", "set", "--worktree", "path:" + path, "--display-name", dn, timeout=60)
    if not (d and d.get("ok")):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": _orca_err(d, "rename failed")})
        return
    await _send_json(cw, b"200 OK", {"ok": True})


async def _serve_orca_repo_add(cr, headers, leftover, cw):
    """Add a project (repo) — register a filesystem path with Orca (orca repo add)."""
    body = await _read_json_body(cr, headers, leftover, limit=PREFS_MAX) or {}
    path = str(body.get("path", "")).strip()
    if not path:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "path required"})
        return
    d = await _orca("repo", "add", "--path", path, timeout=60)
    if not (d and d.get("ok")):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": _orca_err(d, "add project failed (is it a git repo?)")})
        return
    await _send_json(cw, b"200 OK", {"ok": True, "repo": d.get("result", {})})


async def _serve_upload_image(cr, headers, leftover, cw):
    body = await _read_body(cr, headers, leftover)
    if body is None:
        await _send_json(cw, b"413 Payload Too Large", {"ok": False, "error": "body missing/too large"})
        return
    try:
        obj = json.loads(body.decode("utf-8"))
        image_b64 = obj.get("image", "") if isinstance(obj, dict) else ""   # valid-JSON non-dict -> avoid AttributeError hanging the response
    except (ValueError, UnicodeDecodeError):
        image_b64 = ""
    ok, res = _save_uploaded_image(image_b64)
    payload = {"ok": True, **res} if ok else {"ok": False, "error": res}
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request", payload)


async def _serve_list_dir(cr, headers, leftover, cw):
    """Directory listing for the folder-picker GUI. Read-only (the owner has shell
    access anyway)."""
    d = await _read_json_body(cr, headers, leftover)
    req = (d or {}).get("path", "")
    base = os.path.expanduser(req) if req else os.path.expanduser("~")
    try:
        real = os.path.realpath(base)
        if not os.path.isdir(real):
            real = os.path.expanduser("~")
        dirs = []
        for name in os.listdir(real):
            if name.startswith("."):
                continue                                  # hide dotfolders (reduce clutter)
            try:
                if os.path.isdir(os.path.join(real, name)):
                    dirs.append(name)
            except OSError:
                pass
        dirs.sort(key=str.lower)
        parent = os.path.dirname(real) if real != "/" else "/"
        payload = {"ok": True, "path": real, "parent": parent, "dirs": dirs}
    except OSError as e:
        payload = {"ok": False, "error": str(e)}
    await _send_json(cw, b"200 OK", payload)


# ---- terminal file-path click -> open in fileview — optional ----
def _map_to_viewer(realpath):
    """absolute realpath -> the same path, if it is a file. None otherwise.

    This used to walk code_root's entries to express the file as a path relative to
    whichever symlink contained it, and returned None for anything outside. fileview
    serves the filesystem now (filebrowser --root /), so a file's absolute path IS
    its address and "outside" no longer names anything.
    """
    if not realpath or not os.path.isfile(realpath):
        return None
    return realpath


async def _pane_prop(session, fmt):
    """Active-pane property (display-message -p <fmt>). '' on bad name / query fail."""
    name = _safe_name(session)
    if not name:
        return ""
    ok, out = await _tmux_out("display-message", "-p", "-t", name, fmt)
    return out if ok else ""


async def _pane_cwd(session):
    """Active pane cwd (basis for relative-path resolution). None if not a real dir."""
    cwd = await _pane_prop(session, "#{pane_current_path}")
    return cwd if cwd and os.path.isdir(cwd) else None


async def _pane_current_cmd(session):
    """Active pane foreground command (#{pane_current_command}). '' if none."""
    return await _pane_prop(session, "#{pane_current_command}")


def _claude_session_logs(cwd, limit=8):
    """pane cwd -> Claude project slug (non-alnum -> '-') -> that folder's .jsonl list
    (newest mtime first, up to limit). A cwd may host several sessions; the exact
    one is chosen by _claude_log_window via screen-content matching."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd or "")
    d = os.path.join(CLAUDE_PROJECTS, slug)
    if not os.path.isdir(d):
        return []
    ps = []
    try:
        for fn in os.listdir(d):
            if not fn.endswith(".jsonl"):
                continue
            p = os.path.join(d, fn)
            try:
                ps.append((os.path.getmtime(p), p))
            except OSError:
                continue
    except OSError:
        return []
    ps.sort(reverse=True)
    return [p for _, p in ps[:limit]]


def _tail_text(path, max_bytes):
    """Read only the last max_bytes of a file (avoids reading a huge .jsonl whole).
    Returns (text, truncated). ('', False) on failure."""
    truncated = False
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz > max_bytes:
                f.seek(sz - max_bytes)
                truncated = True
            data = f.read()
    except OSError:
        return "", False
    return data.decode("utf-8", "replace"), truncated


def _render_claude_rows(path, max_bytes=3_000_000):
    """Claude session .jsonl tail (~max_bytes) -> rendered conversation lines. Only
    user (>) + assistant text; skips thinking/tool/system/caveat (approximates the
    on-screen TUI render without the noise)."""
    raw, truncated = _tail_text(path, max_bytes)
    rows = []
    lines = raw.split("\n")
    for ln in (lines[1:] if truncated else lines):   # skip the first (partial) line only when seek truncated it
        ln = ln.strip()
        if not ln:
            continue
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if not isinstance(d, dict):     # valid-JSON non-dict line -> avoid AttributeError below
            continue
        t = d.get("type")
        m = d.get("message") if isinstance(d.get("message"), dict) else {}
        c = m.get("content")
        if t == "user":
            if isinstance(c, str):
                s = c.strip()
                if s and not s.startswith(("<local-command", "[SYSTEM", "<command-", "<system-reminder")):
                    rows.append("> " + s)
            elif isinstance(c, list):
                txt = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text").strip()
                if txt:
                    rows.append("> " + txt)
        elif t == "assistant" and isinstance(c, list):
            txt = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text").strip()
            if txt:
                rows.append(txt)
    return "\n\n".join(rows).split("\n")


def _anchor_lines_from_visible(visible):
    """capture-pane frame (the currently visible screen, reflecting Claude's scroll)
    -> anchor candidates for log matching (top to bottom). The bottom of the screen
    is fixed UI chrome (input box, status bar, hints, separators), not conversation
    — so it is excluded, and only conversation lines are kept."""
    cand = []
    for ln in (visible or "").split("\n"):
        s = re.sub(r"^[\s|>*\-│┃●•⏺❯]+", "", ln).strip()
        if len(s) < 14:
            continue
        if re.search(r"Opus [0-9]|Sonnet|Haiku|ctx:|↻|bypass permissions|shift\+tab|⏵⏵|─{6,}|esc to ", s):
            continue   # skip Claude TUI chrome (status bar / input hints / separators)
        cand.append(s)
    return cand


def _norm_for_match(s):
    """The screen render has no markdown (** ## backticks) but the log source does,
    which breaks substring matching. Normalize both sides the same way — strip
    markdown / separators / bullets / whitespace before comparing."""
    return re.sub(r"[*`_~#>|│┃❯⏺●•\-\s]", "", s or "")


def _claude_log_window(cwd, visible, above=150, below=3, fallback=250):
    """Among a cwd's session logs, pick the one that actually contains the visible
    screen (content match — mtime alone would pick the wrong session when a cwd has
    several). Return the conversation window (below..above lines) around the last
    on-screen conversation line. If nothing matches, the newest log's recent lines."""
    logs = _claude_session_logs(cwd)
    if not logs:
        return ""
    anchors = [(_norm_for_match(a), a) for a in _anchor_lines_from_visible(visible)]
    anchors = [na for na in anchors if len(na[0]) >= 10]      # only sufficiently-distinct ones (noise cut)
    for p in logs:
        rows = _render_claude_rows(p)
        if not rows:
            continue
        nrows = [_norm_for_match(r) for r in rows]             # normalize the log too -> markdown-agnostic match
        idx = None
        for na, _disp in reversed(anchors):                   # from the bottom-most on-screen anchor
            for i in range(len(nrows) - 1, -1, -1):           # from the end of the log (last occurrence)
                if na in nrows[i]:
                    idx = i
                    break
            if idx is not None:
                break
        if idx is not None:
            return "\n".join(rows[max(0, idx - above):min(len(rows), idx + 1 + below)])
    rows = _render_claude_rows(logs[0])                        # no match -> newest log's recent lines
    return "\n".join(rows[-fallback:])


def _mw(path):
    # ?path=<urlencoded absolute path> — the viewer's own deep-link shape. Encoded
    # whole (quote with no safe chars) so a name containing '#', '?' or '%' survives.
    return "/fileview/?path=" + urllib.parse.quote(path, safe="")


async def _find_map(root, flag, pat):
    """find -L <root> <flag> <pat> -> [{rel, mtime}] (absolute path + mtime).
    Depth / time / count limited; heavy dirs pruned so broad searches stay fast."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "find", "-L", root, "-maxdepth", "9",
            "(", "-name", "node_modules", "-o", "-name", ".git",
            "-o", "-name", ".venv", "-o", "-name", "__pycache__", ")", "-prune", "-o",
            "-type", "f", flag, pat, "-print",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=4)
    except (OSError, asyncio.TimeoutError):
        return []
    hits, seen = [], set()
    for line in out.decode("utf-8", "replace").splitlines():
        real = os.path.realpath(line)
        rel = _map_to_viewer(real)
        if rel and rel not in seen:
            seen.add(rel)
            try:
                mt = os.path.getmtime(real)
            except OSError:
                mt = 0
            hits.append({"rel": rel, "mtime": mt})
            if len(hits) >= 20:
                break
    return hits


async def _repo_parent(cwd):
    """Parent folder of the current repo root (where sibling repos / worktrees live).
    Not a fixed location — derived from git toplevel's parent, so it works wherever
    repos are placed. Excludes home-direct / root (avoids a home-wide walk)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", "-C", cwd, "rev-parse", "--show-toplevel",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
    except (OSError, asyncio.TimeoutError):
        return None
    top = out.decode("utf-8", "replace").strip()
    if not top:
        return None
    parent = os.path.dirname(os.path.realpath(top))
    home = os.path.realpath(os.path.expanduser("~"))
    if len(parent) <= len(home):        # parent is home-direct (repo at ~/) or root -> too broad, exclude
        return None
    return parent


async def _resolve_to_fileview(p, session):
    """Clicked file path -> fileview URL. absolute / ~ / session-pane-cwd-relative
    resolve directly. Relative paths are searched under the session cwd (the working
    repo). Several matches -> newest-first candidate list (client picks)."""
    if not p:
        return {"ok": False, "reason": "empty"}
    p = p.strip().strip("'\"").rstrip(".,);:")
    cwd = await _pane_cwd(session)
    cands = []
    if p.startswith("~"):
        cands.append(os.path.expanduser(p))
    elif p.startswith("/"):
        cands.append(p)
    elif cwd:
        cands.append(os.path.join(cwd, p))
    for c in cands:
        rel = _map_to_viewer(os.path.realpath(c))
        if rel:
            return {"ok": True, "url": _mw(rel), "rel": rel}
    # search fallback — under cwd (current repo) first (fast); if empty, widen one
    # level to the repo root's parent to cover sibling repos / out-of-tree worktrees.
    hits = []
    if cwd:
        base = p.strip("/")
        flag, pat = ("-path", "*/" + base) if "/" in base else ("-name", base)
        hits = await _find_map(cwd, flag, pat)
        if not hits:
            parent = await _repo_parent(cwd)
            if parent:
                hits = await _find_map(parent, flag, pat)
    if len(hits) == 1:
        return {"ok": True, "url": _mw(hits[0]["rel"]), "rel": hits[0]["rel"]}
    if len(hits) > 1:
        hits.sort(key=lambda h: h["mtime"], reverse=True)                  # newest first
        return {"ok": False, "reason": "ambiguous", "count": len(hits),
                "hits": [{"rel": h["rel"], "url": _mw(h["rel"])} for h in hits[:20]]}
    # subdivide notfound so the client can show 'why'. The old 'outside_code' branch
    # is gone with the boundary it reported: a path that exists is now openable, so
    # a candidate that resolved would already have returned above.
    if not cwd and not (p.startswith("~") or p.startswith("/")):
        return {"ok": False, "reason": "no_cwd", "path": p}                # relative but the session pane cwd was unreadable
    return {"ok": False, "reason": "notfound",
            "base": (os.path.basename(p.rstrip("/")) or p), "cwd": cwd or ""}


async def _serve_resolve(head, cw):
    if not FILEVIEW:
        await _send_json(cw, b"200 OK", {"ok": False, "reason": "disabled"})
        return
    params = urllib.parse.parse_qs(_request_query(head).decode("latin1"))
    p = (params.get("path") or [""])[0]
    session = (params.get("session") or [""])[0]
    await _send_json(cw, b"200 OK", await _resolve_to_fileview(p, session))


# ---- pane layout (equal horizontal width etc) ----
_LAYOUTS = {"even-horizontal", "even-vertical", "tiled", "main-vertical", "main-horizontal"}


async def _serve_layout(cr, headers, leftover, cw):
    """tmux select-layout — arrange the active window's panes. even-horizontal = equal
    widths. Remote (RMT__) sessions supported when host is in REMOTE_HOSTS."""
    d = await _read_json_body(cr, headers, leftover)
    host, sess_raw, valid = _parse_remote_session((d or {}).get("session", ""))
    if not valid:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "unknown remote host"})
        return
    session = _safe_name(sess_raw)
    layout = (d or {}).get("layout", "even-horizontal")
    if not session:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "no session"})
        return
    if layout not in _LAYOUTS:
        layout = "even-horizontal"
    ok, err = await _tmux_r(host, "select-layout", "-t", session, layout)
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request",
                     {"ok": True, "layout": layout} if ok else {"ok": False, "error": err})


async def _pane_status(host, name):
    """(ok, zoomed, panes) for the active window. ok=False if gone/missing.
    Note: `display-message -t <missing>` returns rc=0 with all-empty values ->
    use session_name presence to decide existence."""
    ok, out = await _tmux_out_r(host, "display-message", "-t", name, "-p",
                                "#{window_zoomed_flag} #{window_panes} #{session_name}")
    if not ok:
        return False, False, 0
    parts = out.split()
    if len(parts) < 3:            # no session_name = session gone/absent
        return False, False, 0
    zoomed = parts[0] == "1"
    try:
        panes = int(parts[1])
    except ValueError:
        panes = 0
    return True, zoomed, panes


async def _pane_reply(cw, host, session, ok, err):
    """Standard response after a pane op — on success re-query state, on failure err.
    A failed state re-query is NOT promoted to an action failure (ok=True stays 200)."""
    _, zoomed, panes = await _pane_status(host, session)
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request",
                     {"ok": ok, "zoomed": zoomed, "panes": panes} if ok else {"ok": False, "error": err})


async def _serve_pane(cr, headers, leftover, cw):
    """tmux pane ops for mobile UX (active window's active pane).
    action: zoom / next / split-h / split-v / kill / zoom-next / zoom-prev /
            capture (active pane text -> copy modal) / buffer (paste buffer) / state.
    Remote (RMT__<host>__<sess>) supported via ssh when host is in REMOTE_HOSTS."""
    d = await _read_json_body(cr, headers, leftover) or {}
    raw = d.get("session", "")
    action = d.get("action", "state")
    host, sess_raw, valid = _parse_remote_session(raw)
    if not valid:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "unknown remote host"})
        return
    session = _safe_name(sess_raw)
    if not session:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "no session"})
        return
    if action == "zoom":
        ok, err = await _tmux_r(host, "resize-pane", "-Z", "-t", session)
        await _pane_reply(cw, host, session, ok, err)
    elif action == "next":
        # select the next pane (cyclic). Note: select-pane clears zoom, so next won't keep zoom.
        ok, err = await _tmux_r(host, "select-pane", "-t", session + ":.+")
        await _pane_reply(cw, host, session, ok, err)
    elif action in ("zoom-next", "zoom-prev"):
        # mobile horizontal swipe -> move zoom to the adjacent pane (cyclic). select-pane
        # clears zoom, so re-zoom the target afterwards. No-op with one pane.
        _, _z0, panes = await _pane_status(host, session)
        if panes <= 1:
            await _send_json(cw, b"200 OK", {"ok": True, "zoomed": _z0, "panes": panes})
            return
        tgt = session + (":.+" if action == "zoom-next" else ":.-")
        ok, err = await _tmux_r(host, "select-pane", "-t", tgt)
        if ok:
            _, z1, _ = await _pane_status(host, session)
            if not z1:                       # select-pane cleared zoom -> re-zoom the target pane
                ok, err = await _tmux_r(host, "resize-pane", "-Z", "-t", session)
        await _pane_reply(cw, host, session, ok, err)
    elif action in ("split-h", "split-v"):
        # -h = left/right, -v = top/bottom. New pane runs the session's default shell.
        ok, err = await _tmux_r(host, "split-window", "-h" if action == "split-h" else "-v", "-t", session)
        await _pane_reply(cw, host, session, ok, err)
    elif action == "capture":
        # session text -> copy modal. Claude Code uses the alt-screen, so its
        # conversation above the fold is NOT in tmux scrollback -> for a local Claude
        # pane, render the conversation from the session log (.jsonl). Other panes use
        # capture-pane (-J = wrap into logical lines; with lines, -S -N scrollback).
        lines = d.get("lines")
        want = lines if (isinstance(lines, int) and not isinstance(lines, bool) and lines > 0) else 0
        text, source = None, "screen"
        if not host and want:   # session-log support is local-only (remote falls back to capture)
            cmd = await _pane_current_cmd(session)
            if "claude" in cmd.lower():
                cwd2 = await _pane_cwd(session) or ""
                if _claude_session_logs(cwd2):
                    ok_v, visible = await _tmux_out_r(host, "capture-pane", "-p", "-J", "-t", session)
                    text = _claude_log_window(cwd2, visible if ok_v else "")
                    if text:
                        source = "claude-log"
        if not text:                            # None or "" -> screen-capture fallback
            args = ["capture-pane", "-p", "-J", "-t", session]
            if want:
                args = ["capture-pane", "-p", "-J", "-S", "-" + str(min(want, 1000)), "-t", session]
            ok, out = await _tmux_out_r(host, *args)
            if not ok:
                await _send_json(cw, b"400 Bad Request", {"ok": False, "error": out})
                return
            text = out
            source = "screen"
        await _send_json(cw, b"200 OK", {"ok": True, "text": text, "source": source})
    elif action == "buffer":
        # tmux paste buffer -> copy modal default. No buffer = non-zero (empty clipboard)
        # -> treat as empty string (client falls back to session capture).
        ok, out = await _tmux_out_r(host, "show-buffer")
        await _send_json(cw, b"200 OK", {"ok": True, "text": out if ok else ""})
    elif action == "kill":
        # kill the current pane (destructive — client confirms). Last pane -> tmux tidies the window/session too.
        ok, err = await _tmux_r(host, "kill-pane", "-t", session)
        await _pane_reply(cw, host, session, ok, err)
    else:   # state — surface a lookup failure as ok:false (don't hide session death)
        sok, zoomed, panes = await _pane_status(host, session)
        await _send_json(cw, b"200 OK" if sok else b"404 Not Found",
                         {"ok": True, "zoomed": zoomed, "panes": panes} if sok else {"ok": False, "error": "session not found"})


async def _serve_get_prefs(cw):
    """Read tab prefs ({} if none)."""
    data = b"{}"
    try:
        if os.path.isfile(PREFS_PATH):
            with open(PREFS_PATH, "rb") as f:
                raw = f.read(PREFS_MAX)
            json.loads(raw.decode("utf-8"))          # validity check
            data = raw or b"{}"
    except (OSError, ValueError, UnicodeDecodeError):
        data = b"{}"
    cw.write(_resp(b"200 OK", data, b"application/json; charset=utf-8"))
    await cw.drain()


async def _serve_put_prefs(cr, headers, leftover, cw):
    """Store tab prefs (atomic rename). dict JSON only, size-capped."""
    obj = await _read_json_body(cr, headers, leftover, limit=PREFS_MAX)
    ok = False
    if obj is not None:
        try:
            os.makedirs(PREFS_DIR, exist_ok=True)
            tmp = PREFS_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False)
            os.replace(tmp, PREFS_PATH)
            ok = True
        except OSError:
            ok = False
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request", {"ok": ok})


async def _serve_kill_session(cr, headers, leftover, cw):
    """Kill a tmux session (destructive). Client confirms first. Name is sanitized."""
    d = await _read_json_body(cr, headers, leftover)
    name = _safe_name((d or {}).get("name", ""))       # exec arg (not shell) + sanitize = no injection
    if not name:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "no name"})
        return
    ok, err = await _tmux("kill-session", "-t", name)
    payload = {"ok": True, "name": name} if ok else {"ok": False, "error": err or "kill failed"}
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request", payload)


async def _serve_rename_session(cr, headers, leftover, cw):
    """Rename a tmux session. from/to both sanitized. Re-attach is handled client-side via URL."""
    d = await _read_json_body(cr, headers, leftover) or {}
    frm = _safe_name(d.get("from", ""))
    to = _safe_name(d.get("to", ""))
    if not frm or not to:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "no name"})
        return
    ok, err = await _tmux("rename-session", "-t", frm, to)
    payload = {"ok": True, "from": frm, "to": to} if ok else {"ok": False, "error": err or "rename failed"}
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request", payload)


async def _serve_upload_file(cr, headers, leftover, cw):
    """Arbitrary file raw upload -> ~/uploads/fileNNN.ext. Original name in X-Filename (extension only)."""
    body = await _read_body(cr, headers, leftover)
    if body is None:
        await _send_json(cw, b"413 Payload Too Large", {"ok": False, "error": "body missing/too large"})
        return
    orig = headers.get(b"x-filename", b"").decode("latin1")   # only the extension is extracted -> no decoding needed
    ok, res = _save_uploaded_file(body, orig)
    payload = {"ok": True, **res} if ok else {"ok": False, "error": res}
    await _send_json(cw, b"200 OK" if ok else b"400 Bad Request", payload)


# ============================ optional: Claude account pool ============================
# All of the following degrade to a clean "disabled" response unless DEVTERM_ACCOUNTS
# is true and the configured platform account tools are present. A missing configured
# file remains a runtime-disabled dependency; a missing unit variable is a broken ABI
# bridge and fails at import above rather than falling back to stale app code.

def _accounts_enabled():
    return ACCOUNTS and CLAUDE_SWITCH and os.path.isfile(CLAUDE_SWITCH)


def _xai_enabled():
    return XAI and CLAUDE_STATUS and os.path.isfile(CLAUDE_STATUS)


_CLAUDE_KIND_ALIASES = {
    "personal": "personal", "개인": "personal",
    "team": "team", "팀": "team",
}
_CLAUDE_KIND_VARIANTS = {
    "personal": ("personal", "개인"),
    "team": ("team", "팀"),
}


def _claude_kind(kind):
    """Canonicalize the two legacy localized pool labels without guessing unknowns."""
    if not isinstance(kind, str):
        return ""
    value = kind.strip()
    return _CLAUDE_KIND_ALIASES.get(value.casefold(),
                                    _CLAUDE_KIND_ALIASES.get(value, value))


def _claude_store_entry(store, email, kind):
    """Pick the newest canonical/legacy fleet entry for one account identity."""
    if not isinstance(store, dict) or not isinstance(email, str) or not email:
        return {}
    original = kind.strip() if isinstance(kind, str) else kind
    canonical = _claude_kind(original)
    variants = []
    for value in (original, canonical, *_CLAUDE_KIND_VARIANTS.get(canonical, ())):
        if isinstance(value, str) and value and value not in variants:
            variants.append(value)
    best = None
    best_at = None
    best_is_canonical = False
    for value in variants:
        entry = store.get(f"{email}|{value}")
        if not isinstance(entry, dict):
            continue
        observed_at = _finite_number(entry.get("observedAt"))
        is_canonical = value == canonical
        if best is None or (observed_at is not None
                            and (best_at is None or observed_at > best_at)) \
                or (observed_at == best_at and is_canonical
                    and not best_is_canonical):
            best, best_at, best_is_canonical = entry, observed_at, is_canonical
    return best or {}


def _opencode_bin():
    return bin_discovery.find_bin("opencode")[0]


def _opencode_missing_error():
    return bin_discovery.not_found_message(
        "opencode", bin_discovery.find_bin("opencode")[1])


async def _acct_list_with_usage():
    """`claude-switch list --json` + usage merged from the shared store (if any).
    Shared by /accounts and /acct-alert so both see exactly the same account state."""
    data = {"active": None, "accounts": []}
    try:
        proc = await asyncio.create_subprocess_exec(
            CLAUDE_SWITCH, "list", "--json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
        except asyncio.TimeoutError:
            proc.kill(); await proc.wait(); out = b""
        if proc.returncode == 0 and out.strip():
            data = json.loads(out)
    except (FileNotFoundError, ValueError, OSError):
        pass
    store = await asyncio.get_running_loop().run_in_executor(None, _fetch_fleet_store)
    now = time.time()
    # "nothing here yet" and "nothing will ever be here" are different operator states,
    # and only one of them resolves by waiting. With no store configured this gate has no
    # source for any account but the active one, so reporting the transient (which the UI
    # words as "Collecting") promises a collector that does not exist — measured on this
    # box as seven rows that had been "collecting" indefinitely, with a healthy collector
    # running beside an unset fleet_store. Say which state it is; the UI words each.
    no_source = not (FLEET_STORE or FLEET_STORE_URL)
    for a in data.get("accounts", []):
        ent = _claude_store_entry(store, a.get("email"), a.get("kind"))
        a["kind"] = _claude_kind(a.get("kind"))
        if ent.get("usage"):
            # age = how old the reading is. Without it a number cannot be trusted.
            a["usage"] = dict(ent["usage"],
                               age=int(now - (ent.get("observedAt") or now)),
                               observedAt=ent.get("observedAt"))
        else:
            a["usage"] = {"err": "no store" if no_source else "no data"}
        # Which boxes hold this account (identity only, never a secret). Two boxes on
        # one account burn the 5h window twice as fast, so it is worth seeing before a
        # swap. Empty unless a shared store is configured.
        a["holders"] = ent.get("holders") or []
    return data


async def _serve_accounts(cw):
    """Account list + usage + the warning thresholds the frontend colours rows with.

    When accounts are disabled or claude-switch is absent, returns a clean disabled
    payload so the UI can hide itself."""
    if not _accounts_enabled():
        await _send_json(cw, b"200 OK", {"enabled": False, "active": None, "accounts": []})
        return
    data = await _acct_list_with_usage()
    now = time.time()
    local_store = _claude_usage_state_load(now)
    # Keep this merge at the /accounts boundary. /acct-alert deliberately consumes the
    # unmerged list so a human's last panel read cannot replace its live-probe fallback.
    for account in data.get("accounts", []) if isinstance(data, dict) else []:
        if not isinstance(account, dict):
            continue
        account["kind"] = _claude_kind(account.get("kind"))
        email, kind = account.get("email"), account.get("kind")
        key = f"{email}|{kind}" if isinstance(email, str) and email and kind else ""
        local = local_store.get(key) if key else None
        fleet_usage = account.get("usage")
        fleet_at = (_finite_number(fleet_usage.get("observedAt"))
                    if isinstance(fleet_usage, dict) else None)
        if not local or (fleet_at is not None and local["valueAt"] <= fleet_at):
            continue
        merged = dict(local["usage"])
        merged["age"] = max(0, int(now - local["valueAt"]))
        merged["stale"] = True
        merged["observedAt"] = local["valueAt"]
        account["usage"] = merged
    # Ship the thresholds too: if the frontend held its own numbers they would drift
    # from the /acct-alert verdict (USAGE_TH is the only source).
    data["thresholds"] = dict(USAGE_TH)
    data["enabled"] = True
    await _send_json(cw, b"200 OK", data)


async def _live_usage_cached():
    """The active account's own 5h/7d reading, cached for LIVE_USAGE_TTL.

    This is the fallback source for /acct-alert on a box with no shared usage store —
    i.e. the default single-box install. The probe queries with this box's own token, so
    only numbers leave. Returns {} when there is nothing to report."""
    now = time.time()
    payload = _live_usage_cache.get("payload")
    if payload is not None and now - _live_usage_cache.get("at", 0.0) <= LIVE_USAGE_TTL:
        return payload
    generation = _acct_cache_generation
    result = await _probe_json(["--usage", "live"])
    # Same reading /acct-usage-now already persists, taken on a cadence a human does not
    # have to trigger: the widget polls /acct-alert, so an account in actual use keeps a
    # fresh stored value and still reads "(last value)" tomorrow instead of falling back
    # to "no data". Filed under the probe's OWN identity, so a reading that raced a swap
    # lands on the account it actually describes. Display memory only — /acct-alert
    # deliberately grades from the unmerged list, so this cannot feed its own verdict.
    _claude_usage_state_save(result)
    usage = {}
    if isinstance(result, dict):
        u = result.get("usage")
        if isinstance(u, dict):
            usage = dict(u)
        rt_days = _finite_number(result.get("rtDaysLeft"))
        if rt_days is not None:
            usage["rtDaysLeft"] = rt_days
    # A login/swap/remove may have happened while the probe was in flight. Return the
    # result to the caller that started it, but never make it the new account's cache.
    if generation == _acct_cache_generation:
        _live_usage_cache.update(at=now, payload=usage)
    return usage


def _acct_alert_level(u5, u7, rt_days, codex_u7=None, codex_err=None):
    """The active account's warning level — (level, reason). level = none|warn|crit.

    Each axis is graded on its own, then the worst (severity, reason-priority) wins.
    Reason priority is login=3 > usage=2 > codex=1: at equal severity a looming login
    expiry is the more actionable message, and codex is the newest axis so it never
    displaces the two that were there before.
    A spent 5h window mutes nothing, including itself. "5h exhausted" and "7d critical"
    are separate facts and collapsing them hides the one that lasts longer — and a 5h
    window at 100% is not a quiet state, it is the account being unusable right now.
    Grading it as anything but crit reported an exhausted account as healthy.
    codex_err="auth" (claude-status's verdict that the stored Codex credential was
    revoked) is graded as crit on the codex axis: the panel still shows a healthy
    email + plan, so without this the first report is an agent failing mid-run."""
    u5 = _finite_number(u5)
    u7 = _finite_number(u7)
    rt_days = _finite_number(rt_days)
    codex_u7 = _finite_number(codex_u7)
    candidates = []
    if u5 is not None:
        if u5 >= USAGE_TH["crit5"]:
            candidates.append((2, 2, "crit", "usage"))
        elif u5 >= USAGE_TH["warn5"]:
            candidates.append((1, 2, "warn", "usage"))
    if u7 is not None:
        if u7 >= USAGE_TH["crit7"]:
            candidates.append((2, 2, "crit", "usage"))
        elif u7 >= USAGE_TH["warn7"]:
            candidates.append((1, 2, "warn", "usage"))
    if rt_days is not None and rt_days <= USAGE_TH["rtWarnDays"]:
        candidates.append((1, 3, "warn", "login"))
    if codex_u7 is not None:
        if codex_u7 >= USAGE_TH["crit7"]:
            candidates.append((2, 1, "crit", "codex"))
        elif codex_u7 >= USAGE_TH["warn7"]:
            candidates.append((1, 1, "warn", "codex"))
    if codex_err == "auth":
        # Not a usage problem: no Codex agent runs until someone re-logs in. Its own
        # reason so the widget says "re-login" instead of quoting a percentage.
        candidates.append((2, 1, "crit", "codex-login"))
    if not candidates:
        return "none", None
    _, _, level, reason = max(candidates, key=lambda item: (item[0], item[1]))
    return level, reason


async def _serve_acct_alert(headers, cw, _generation_retry=False):
    """`GET /acct-alert` — only the active account's warning level. No email, no token
    (level + numbers + time remaining).

    Who reads it: devterm's own account icon, and the Airlock return widget injected
    into tools that run on other ports. Because the verdict comes from one place
    (USAGE_TH), devterm and the widget change colour at the same instant.

    Where the numbers come from, in order — a single-box install has no collector, so
    this must still work without one:
      1. the shared usage store, when one is configured (a fleet has a collector);
      2. otherwise this box probing its own live account (cached LIVE_USAGE_TTL);
      3. otherwise level="none" — no data is not a warning. Silence beats inventing one.
    """
    now = time.time()
    payload = _acct_alert_cache["payload"]
    if payload is None or now - _acct_alert_cache["at"] > ACCT_ALERT_TTL:
        generation = _acct_cache_generation
        claude_error = None
        u = {}
        rt_days = None
        u5 = u7 = None
        try:
            data = await _acct_list_with_usage()
            if not isinstance(data, dict):
                raise ValueError("accounts payload is not an object")
            accounts = data.get("accounts", [])
            if not isinstance(accounts, list):
                raise ValueError("accounts payload is not a list")
            act = next((a for a in accounts if isinstance(a, dict) and a.get("active")), None)
            u = (act or {}).get("usage") or {}
            if not isinstance(u, dict):
                raise ValueError("usage payload is not an object")
            u5 = _finite_number(u.get("use5h"))
            u7 = _finite_number(u.get("use7d"))
            rt = _finite_number((act or {}).get("rtExpiry"))
            rt_days = _finite_number(((rt / 1000.0) - now) / 86400.0 if rt is not None else None)
            if u5 is None and u7 is None:
                # No shared store (or nothing in it for this account): ask this box.
                live = await _live_usage_cached()
                if isinstance(live, dict) and live:
                    u = dict(live)
                    u5 = _finite_number(live.get("use5h"))
                    u7 = _finite_number(live.get("use7d"))
                    if rt_days is None:
                        rt_days = _finite_number(live.get("rtDaysLeft"))
        except Exception as exc:
            # Isolated from the codex axis. Only the exception type is reported — never
            # a token, a path, or raw response text.
            claude_error = f"accounts-{type(exc).__name__}"
            u = {}
            u5, u7 = None, None
        try:
            codex = await _codex_usage_cached()
        except Exception as exc:
            codex = {"stale": True, "err": f"cache-{type(exc).__name__}"}
        if not isinstance(codex, dict):
            codex = {"stale": True, "err": "cache-invalid"}
        codex_u7 = _finite_number(codex.get("use7d"))
        codex_err = codex.get("lastErr") or codex.get("err")
        level, reason = _acct_alert_level(u5, u7, rt_days, codex_u7, codex_err)
        payload = {"ok": True, "level": level, "reason": reason,
                   "use5h": u5, "use7d": u7,
                   "reset5h": u.get("reset5h"), "reset7d": u.get("reset7d"),
                   "rtDays": (int(rt_days) if rt_days is not None else None),
                   "stale": bool(u.get("stale")), "err": u.get("err") or claude_error,
                   "codexUse7d": codex_u7,
                   "codexReset7d": codex.get("reset7d"),
                   "codexPlan": codex.get("plan"),
                   "codexCredits": codex.get("resetCredits"),
                   "codexStale": bool(codex.get("stale")),
                   "codexErr": codex_err,
                   "thresholds": dict(USAGE_TH)}
        if generation != _acct_cache_generation:
            # A login mutation won the race while the old-account probes were in
            # flight. Recompute once; a second mutation still prevents caching.
            if not _generation_retry:
                return await _serve_acct_alert(headers, cw, _generation_retry=True)
        else:
            _acct_alert_cache.update(at=now, payload=payload)
    await _send_json(cw, b"200 OK", payload, cors=_cors_origin(headers))


async def _serve_acct_switch(cr, headers, leftover, cw):
    """Switch the active Claude account — run `claude-switch swap <name>` server-side.
    Replaces the live credential; a running `claude` picks it up on --continue restart."""
    if not _accounts_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "accounts disabled"})
        return
    d = await _read_json_body(cr, headers, leftover) or {}
    name = (d.get("name") or "").strip()
    if not name or "/" in name or name.startswith("."):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid name"})
        return
    try:
        proc = await asyncio.create_subprocess_exec(
            CLAUDE_SWITCH, "swap", name,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await proc.communicate()
        ok = proc.returncode == 0
        payload = {"ok": ok, "active": name if ok else None}
        if ok:
            _invalidate_acct_caches()
        if not ok:
            payload["error"] = (err or out or b"").decode("utf-8", "replace")[:200]
    except (FileNotFoundError, OSError) as e:
        payload = {"ok": False, "error": str(e)}
    await _send_json(cw, b"200 OK" if payload.get("ok") else b"400 Bad Request", payload)


async def _codex_auth_call(action, timeout):
    """Run one platform-owned Codex credential action and return its JSON payload.

    Every Codex credential operation — preserve, restore, log in, log out — belongs to
    `airlock-accounts codex-auth` (ACCT_OWN, 2026-09-01). devterm is the caller: it owns
    the button, not the decision about what the button does to this box's login.

    Only the platform tool's own JSON crosses back. Its stdout is parsed, never
    forwarded, and codex's stdout/stderr never reaches devterm at all — a future
    regression must not be able to turn arbitrary process output into a credential
    exfiltration path. `ok: false` with an `error` string is an operation that failed
    for a reason a person can act on; a non-zero exit is the tool itself failing.
    """
    if not PLATFORM_ACCOUNTS:
        return None, "platform accounts tool is not wired"
    try:
        proc = await asyncio.create_subprocess_exec(
            PLATFORM_ACCOUNTS, "codex-auth", action, "--json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, _err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except (asyncio.TimeoutError, FileNotFoundError, OSError):
        return None, "platform accounts operation failed"
    if proc.returncode != 0:
        return None, "platform accounts operation failed"
    try:
        payload = json.loads((out or b"").decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None, "platform accounts operation returned invalid JSON"
    if not isinstance(payload, dict):
        return None, "platform accounts operation returned an invalid shape"
    if payload.get("ok") is not True:
        # The platform CLI's own message (no codex on this box, no code captured).
        # Bounded and type-checked here so a malformed payload cannot inject a body.
        detail = payload.get("error")
        return None, detail[:400] if isinstance(detail, str) and detail else \
            "platform accounts operation failed"
    return payload, None


async def _codex_auth_lifecycle(action):
    """backup / restore — the two that answer with a single boolean."""
    payload, error = await _codex_auth_call(action, 10)
    if error:
        return None, error
    key = "backedUp" if action == "backup" else "restored"
    if not isinstance(payload.get(key), bool):
        return None, "platform accounts operation returned an invalid shape"
    return payload[key], None


async def _serve_codex_login_start(cw):
    """Codex re-login 1/2 — ask the platform to start `codex login --device-auth`.

    device-auth needs no port-forward/callback: the user opens the link in any browser
    and enters the code. The backup-before-wipe rule, the capture and the timing all
    live in `airlock-accounts codex-auth login-start`; this endpoint hands its two
    display strings to the panel and nothing else.
    """
    _invalidate_codex_usage_cache()   # login wipes auth.json: cached numbers are void
    # The capture polls for up to ~10s inside the platform CLI, so this wait has to
    # clear that ceiling; too short would report a failure for a login that started.
    payload, error = await _codex_auth_call("login-start", 30)
    if error:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": error})
        return
    url, code = payload.get("url"), payload.get("code")
    if not isinstance(url, str) or not isinstance(code, str) or not code:
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False, "error": "platform accounts operation returned an invalid shape"})
        return
    await _send_json(cw, b"200 OK", {"ok": True, "url": url, "code": code})


async def _serve_codex_login_cancel(cw):
    """Codex re-login cancel — stop the pending device-auth and restore the previous
    login. Re-login logs out immediately, so this undoes an abandoned attempt."""
    payload, error = await _codex_auth_call("login-cancel", 15)
    if error:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": error})
        return
    restored = payload.get("restored")
    if not isinstance(restored, bool):
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False, "error": "platform accounts operation returned an invalid shape"})
        return
    if restored:
        _invalidate_codex_usage_cache()
    await _send_json(cw, b"200 OK", {"ok": True, "restored": restored})


async def _serve_codex_logout(cw):
    """Codex logout — removes auth.json. Codex is single-account, so this is
    'remove account'; the re-login button reconnects."""
    _payload, error = await _codex_auth_call("logout", 30)
    if error:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": error})
        return
    _invalidate_codex_usage_cache()
    await _send_json(cw, b"200 OK", {"ok": True})


async def _serve_xai_status(cw):
    """OpenCode xAI credential metadata only; access/refresh tokens never cross HTTP."""
    if not _xai_enabled():
        await _send_json(cw, b"200 OK", {"enabled": False})
        return
    result = await _probe_json(["--xai"])
    if not isinstance(result, dict) or result.get("state") not in {
            "none", "ok", "expired", "malformed", "err"}:
        await _send_json(cw, b"500 Internal Server Error",
                         {"enabled": True, "state": "err",
                          "reason": "xAI status probe failed",
                          "loginState": _xai_login_state()})
        return
    # The platform probe is outside this app's HTTP trust boundary, so keep the response
    # an allowlist: a custom/older probe must never smuggle credential fields through.
    payload = {"enabled": True, "state": result["state"],
               "loginState": _xai_login_state()}
    if (result["state"] in {"ok", "expired"}
            and isinstance(result.get("expires"), int)
            and not isinstance(result.get("expires"), bool)):
        payload["expires"] = result["expires"]
    if result["state"] == "none":
        payload["reason"] = "no OpenCode xAI credential"
    elif result["state"] == "malformed":
        payload["reason"] = "expected OAuth access, refresh and non-negative expires fields"
    elif result["state"] == "err":
        # Probe error text is diagnostic, not display data. Do not reflect it: an
        # older/custom probe could otherwise put a token-shaped value in ``reason``.
        payload["reason"] = "credential status unavailable"
    await _send_json(cw, b"200 OK", payload)


def _xai_login_state():
    proc = _xai_login_process
    if proc is None:
        return "idle"
    if proc.returncode is None:
        return "pending"
    return "succeeded" if proc.returncode == 0 else "failed"


async def _cancel_xai_login():
    """Stop only the login process group Airlock started, promoting TERM to KILL.

    OpenCode 1.18.18 ignores SIGINT in this flow. A broad pkill could hit a person's
    terminal login, so the exact new-session group is retained and reaped here.
    """
    global _xai_login_process
    proc = _xai_login_process
    _xai_login_process = None
    stopped = bool(proc is not None and proc.returncode is None)
    if proc is not None:
        await _terminate_xai_process(proc)
    try:
        os.unlink(XAI_LOGIN_OUT)
    except OSError:
        pass
    return stopped


def _xai_group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


async def _terminate_xai_process(proc):
    """TERM one tracked group and reap descendants that outlive their leader."""
    if proc is None or proc.returncode is not None:
        return
    pgid = proc.pid
    _signal_probe_group(pgid, signal.SIGTERM)
    try:
        await asyncio.wait_for(proc.wait(), timeout=PROBE_KILL_GRACE)
    except asyncio.TimeoutError:
        _signal_probe_group(pgid, signal.SIGKILL)
        try:
            await proc.wait()
        except (OSError, ChildProcessError):
            pass
        return
    except asyncio.CancelledError:
        _signal_probe_group(pgid, signal.SIGKILL)
        try:
            await asyncio.shield(proc.wait())
        except (OSError, ChildProcessError, asyncio.CancelledError):
            pass
        raise
    except (OSError, ChildProcessError):
        return
    # TERM may reap the leader while a child in the same group keeps polling. Only
    # signal again when that exact group still exists; this avoids a blind post-reap
    # kill while still cleaning descendants.
    if _xai_group_alive(pgid):
        _signal_probe_group(pgid, signal.SIGKILL)


def _xai_device_values(text):
    """Extract only OpenCode's documented device-flow URL/code labels."""
    text = _ANSI_RE.sub("", text)
    urls = re.findall(r"https://[^\s\x1b]+", text)
    url = None
    for item in urls:
        candidate = item.rstrip("),.;")
        # Browsers apply WHATWG backslash normalization while urlsplit follows RFC
        # syntax. Reject that ambiguity (and userinfo) before trusting the hostname.
        if "\\" in candidate:
            continue
        try:
            parsed = urllib.parse.urlsplit(candidate)
            host = (parsed.hostname or "").lower()
        except ValueError:
            continue
        if (parsed.scheme == "https" and parsed.username is None
                and parsed.password is None
                and (host == "x.ai" or host.endswith(".x.ai")
                or host == "grok.com" or host.endswith(".grok.com"))):
            url = candidate
            break
    # OpenCode 1.18.18 emits "enter code: XXXX-XXXX". Keep this anchored to
    # that label: a loose search once returned the literal word "CODE".
    match = re.search(
        r"\benter\s+code\s*:\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})*)\b", text)
    code = match.group(1) if match and match.group(1) != "CODE" else None
    return url, code


def _open_xai_login_capture():
    """Open the capture as 0600 without following a pre-planted symlink."""
    os.makedirs(DEVTERM_STATE_DIR, mode=0o700, exist_ok=True)
    dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    dir_fd = os.open(DEVTERM_STATE_DIR, dir_flags)
    try:
        os.fchmod(dir_fd, 0o700)
        flags = (os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                 | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
        fd = os.open(os.path.basename(XAI_LOGIN_OUT), flags, 0o600, dir_fd=dir_fd)
        try:
            os.fchmod(fd, 0o600)
        except BaseException:
            os.close(fd)
            raise
        return fd
    finally:
        os.close(dir_fd)


async def _serve_xai_login_start_owned(cw):
    """Start OpenCode's headless SuperGrok device flow and return its URL + code."""
    global _xai_login_process
    if not _xai_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "xAI disabled"})
        return
    binary = _opencode_bin()
    if binary is None:
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False, "error": _opencode_missing_error()})
        return
    await _cancel_xai_login()
    try:
        fd = _open_xai_login_capture()
        outf = os.fdopen(fd, "wb")
        try:
            proc = await asyncio.create_subprocess_exec(
                binary, "auth", "login", "--provider", "xai", "--method",
                "SuperGrok Subscription",
                stdout=outf, stderr=asyncio.subprocess.STDOUT,
                stdin=asyncio.subprocess.DEVNULL, start_new_session=True,
                env={**os.environ, "BROWSER": "true"})
        finally:
            outf.close()
        _xai_login_process = proc
    except (FileNotFoundError, OSError) as exc:
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False,
                          "error": "OpenCode xAI login launch failed (" +
                                   type(exc).__name__ + ")"})
        return

    url = code = None
    for _ in range(20):
        await asyncio.sleep(0.5)
        try:
            with open(XAI_LOGIN_OUT, encoding="utf-8", errors="replace") as f:
                txt = _ANSI_RE.sub("", f.read())
        except OSError:
            txt = ""
        url, code = _xai_device_values(txt)
        if url and code:
            break
        if proc.returncode is not None:
            break
    if url and code:
        # The response is the only place these short-lived device values go. Unlink the
        # capture while the child still owns its fd so they cannot linger on disk.
        try:
            os.unlink(XAI_LOGIN_OUT)
        except OSError:
            pass
        await _send_json(cw, b"200 OK", {"ok": True, "url": url, "code": code})
        return
    await _cancel_xai_login()
    await _send_json(cw, b"400 Bad Request",
                     {"ok": False, "error": "failed to capture OpenCode xAI device flow"})


async def _xai_write_request_ok(headers, cw):
    """Refuse cross-origin/form writes before any xAI process or credential mutation."""
    if not _secret_origin_ok(headers):
        await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "forbidden origin"})
        return False
    content_type = headers.get(b"content-type", b"").split(b";", 1)[0].strip().lower()
    if content_type != b"application/json":
        await _send_json(cw, b"415 Unsupported Media Type",
                         {"ok": False, "error": "application/json required"})
        return False
    return True


async def _serve_xai_login_start(headers, cw):
    if not await _xai_write_request_ok(headers, cw):
        return
    if not _xai_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "xAI disabled"})
        return
    if _xai_operation_lock.locked():
        await _send_json(cw, b"409 Conflict",
                         {"ok": False, "error": "xAI operation already in progress"})
        return
    async with _xai_operation_lock:
        await _serve_xai_login_start_owned(cw)


async def _serve_xai_login_cancel(headers, cw):
    if not await _xai_write_request_ok(headers, cw):
        return
    if not _xai_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "xAI disabled"})
        return
    if _xai_operation_lock.locked():
        await _send_json(cw, b"409 Conflict",
                         {"ok": False, "error": "xAI operation already in progress"})
        return
    async with _xai_operation_lock:
        stopped = await _cancel_xai_login()
        await _send_json(cw, b"200 OK", {"ok": True, "stopped": stopped})


async def _serve_xai_logout_owned(cw):
    if not _xai_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "xAI disabled"})
        return
    binary = _opencode_bin()
    if binary is None:
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False, "error": _opencode_missing_error()})
        return
    await _cancel_xai_login()
    try:
        proc = await asyncio.create_subprocess_exec(
            binary, "auth", "logout", "xai",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True)
        try:
            await asyncio.wait_for(proc.communicate(), timeout=XAI_LOGOUT_WAIT)
        except asyncio.TimeoutError:
            await _terminate_xai_process(proc)
            raise
        payload = ({"ok": True} if proc.returncode == 0 else
                   {"ok": False, "error": "OpenCode xAI logout failed"})
    except asyncio.TimeoutError:
        payload = {"ok": False, "error": "OpenCode xAI logout timed out"}
    except (FileNotFoundError, OSError) as exc:
        payload = {"ok": False, "error": "OpenCode xAI logout failed (" +
                                           type(exc).__name__ + ")"}
    await _send_json(cw, b"200 OK" if payload.get("ok") else b"400 Bad Request", payload)


async def _serve_xai_logout(headers, cw):
    if not await _xai_write_request_ok(headers, cw):
        return
    if not _xai_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "xAI disabled"})
        return
    if _xai_operation_lock.locked():
        await _send_json(cw, b"409 Conflict",
                         {"ok": False, "error": "xAI operation already in progress"})
        return
    async with _xai_operation_lock:
        await _serve_xai_logout_owned(cw)


async def _serve_acct_remove(cr, headers, leftover, cw):
    """Remove an account slot — `claude-switch remove <name> --yes` server-side.
    Not reversible, but name = id, so re-login revives the same slot."""
    if not _accounts_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "accounts disabled"})
        return
    d = await _read_json_body(cr, headers, leftover) or {}
    name = (d.get("name") or "").strip()
    if not name or "/" in name or name.startswith("."):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid name"})
        return
    try:
        proc = await asyncio.create_subprocess_exec(
            CLAUDE_SWITCH, "remove", name, "--yes",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await proc.communicate()
        ok = proc.returncode == 0
        if ok:
            _invalidate_acct_caches()
        payload = {"ok": ok}
        if not ok:
            payload["error"] = (err or out or b"").decode("utf-8", "replace")[:200]
    except (FileNotFoundError, OSError) as e:
        payload = {"ok": False, "error": str(e)}
    await _send_json(cw, b"200 OK" if payload.get("ok") else b"400 Bad Request", payload)


async def _claude_switch(args, timeout=40, stdin_bytes=None):
    """Run a claude-switch subcommand -> (ok, stdout, stderr). Secrets never appear in
    stdout (login-url = URL / login-code = a status string only). A login code crosses
    this process boundary only through stdin, never argv or the environment."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *([CLAUDE_SWITCH] + args),
            stdin=(asyncio.subprocess.PIPE if stdin_bytes is not None
                   else asyncio.subprocess.DEVNULL),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except (FileNotFoundError, OSError) as e:
        return False, "", str(e)
    try:
        communicate = proc.communicate() if stdin_bytes is None else proc.communicate(stdin_bytes)
        out, err = await asyncio.wait_for(communicate, timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill(); await proc.wait()
        return False, "", "timed out"
    return (proc.returncode == 0,
            (out or b"").decode("utf-8", "replace").strip(),
            (err or b"").decode("utf-8", "replace").strip())


def _signal_probe_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError, OSError):
        pass


async def _kill_probe_group(proc, pgid):
    """Reap a probe that was started in its own session, group and all.

    The codex probe spawns an `app-server` child; if the probe dies without running its
    own cleanup, that child outlives us. Killing the group takes it too."""
    if proc is None or pgid is None:
        return
    if proc.returncode == 0:
        # Clean exit: the probe already reaped its app-server group in its own finally,
        # and communicate() has reaped the probe, so this pgid may already be recycled.
        # Signalling now could only kill an unrelated process group.
        return
    _signal_probe_group(pgid, signal.SIGTERM)
    try:
        try:
            await asyncio.wait_for(proc.wait(), timeout=PROBE_KILL_GRACE)
        except asyncio.TimeoutError:
            pass
        except (OSError, ChildProcessError):
            pass
    finally:
        # A re-cancel must not let us skip the SIGKILL promotion.
        _signal_probe_group(pgid, signal.SIGKILL)
        try:
            await proc.wait()
        except asyncio.CancelledError:
            current = asyncio.current_task()
            while current is not None and current.cancelling():
                current.uncancel()
            try:
                await proc.wait()
            except (OSError, ChildProcessError):
                pass
        except (OSError, ChildProcessError):
            pass


async def _probe_json(args, timeout=25):
    """Run claude-status with args and return its parsed JSON (None on any failure).
    Same probe as _run_probe, but for internal callers instead of an HTTP response."""
    if not (CLAUDE_STATUS and os.path.isfile(CLAUDE_STATUS)):
        return None
    proc = None
    probe_pgid = None
    out = None
    try:
        proc = await asyncio.create_subprocess_exec(
            sys.executable, CLAUDE_STATUS, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True)
        # A child of a new session is its own group leader, so we do not need to call
        # getpgid() again at reap time (by then the pid may be gone).
        probe_pgid = proc.pid
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            return None
    except (FileNotFoundError, OSError):
        return None
    except asyncio.TimeoutError:
        return None
    except asyncio.CancelledError:
        raise
    finally:
        await _kill_probe_group(proc, probe_pgid)
    try:
        result = json.loads((out or b"").decode().strip().splitlines()[-1])
    except (ValueError, IndexError, UnicodeDecodeError):
        return None
    return result if isinstance(result, dict) else None


# ---- persisted Claude usage -------------------------------------------------
# This is display memory for /accounts, not an alerting source. The store contains
# account addresses, so every accepted record is normalized before it is retained.

def _claude_usage_key_parts(key):
    if not isinstance(key, str):
        return None
    parts = key.split("|")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return None
    kind = _claude_kind(parts[1])
    return (parts[0], kind) if kind else None


def _claude_usage_normalize_usage(raw):
    if not isinstance(raw, dict):
        return None
    usage = {}
    has_value = False
    for key in ("use5h", "use7d"):
        value = raw.get(key)
        if value is None:
            usage[key] = None
            continue
        value = _finite_number(value)
        if value is None or not 0 <= value <= 100:
            return None
        usage[key] = value
        has_value = True
    if not has_value:
        return None
    for key in ("reset5h", "reset7d"):
        value = raw.get(key)
        if value is not None and not isinstance(value, str):
            return None
        usage[key] = value
    return usage


def _claude_usage_validate_entry(raw, now):
    if not isinstance(raw, dict):
        return None
    value_at = _finite_number(raw.get("valueAt"))
    if (value_at is None or value_at <= 0
            or value_at > now + CLAUDE_USAGE_FUTURE_SKEW):
        return None
    usage = _claude_usage_normalize_usage(raw.get("usage"))
    if usage is None:
        return None
    return {"usage": usage, "valueAt": value_at}


def _claude_usage_records(raw, now):
    """Return only validated records from one versioned store object."""
    if not isinstance(raw, dict) or isinstance(raw.get("version"), bool) \
            or raw.get("version") != 1 or not isinstance(raw.get("accounts"), dict):
        return {}
    records = {}
    for key, raw_entry in raw["accounts"].items():
        parts = _claude_usage_key_parts(key)
        if parts is None:
            continue
        entry = _claude_usage_validate_entry(raw_entry, now)
        canonical_key = f"{parts[0]}|{parts[1]}"
        current = records.get(canonical_key)
        source_is_canonical = key == canonical_key
        if entry is not None and (current is None
                                  or entry["valueAt"] > current["valueAt"]
                                  or (entry["valueAt"] == current["valueAt"]
                                      and source_is_canonical)):
            records[canonical_key] = entry
    return records


def _claude_usage_state_load(now=None):
    """Load a cold/partially valid cache; malformed records are simply not usable."""
    now = time.time() if now is None else now
    try:
        with open(CLAUDE_USAGE_STATE, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError, UnicodeError, RecursionError):
        return {}
    return _claude_usage_records(raw, now)


def _claude_usage_candidate(result, now):
    if not isinstance(result, dict) or result.get("state") != "ok":
        return None
    email = result.get("email")
    kind = result.get("kind")
    if not isinstance(email, str) or not email or not isinstance(kind, str) or not kind:
        return None
    key = f"{email}|{_claude_kind(kind)}"
    if _claude_usage_key_parts(key) is None:
        return None
    usage = _claude_usage_normalize_usage(result.get("usage"))
    if usage is None:
        return None
    return key, {"usage": usage, "valueAt": now}


def _claude_usage_state_save(result):
    """Persist one good live probe without ever making the probe request fail.

    This deliberately stays a plain synchronous function. The gate has one asyncio
    loop, so its read-modify-prune-write sequence cannot interleave with another handler.
    """
    global _claude_usage_write_logged
    now = time.time()
    candidate = _claude_usage_candidate(result, now)
    if candidate is None:
        return False
    key, entry = candidate
    tmp = None
    fd = None
    try:
        # Keep the load in this same synchronous call as merge, prune and replace. Moving
        # only the load to run_in_executor would reintroduce a lost-update window.
        try:
            with open(CLAUDE_USAGE_STATE, encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError, UnicodeError, RecursionError):
            raw = None
        records = _claude_usage_records(raw, now)
        cutoff = now - CLAUDE_USAGE_MAX_AGE
        records = {k: v for k, v in records.items() if v["valueAt"] >= cutoff}
        records[key] = entry
        payload = {"version": 1, "accounts": records}

        os.makedirs(CLAUDE_USAGE_STATE_DIR, mode=0o700, exist_ok=True)
        tmp = f"{CLAUDE_USAGE_STATE}.tmp.{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_TRUNC, 0o600)
        stream = os.fdopen(fd, "w", encoding="utf-8")
        fd = None
        with stream:
            json.dump(payload, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, CLAUDE_USAGE_STATE)
        return True
    except (OSError, TypeError, ValueError, UnicodeError, RecursionError) as exc:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp:
            try:
                os.remove(tmp)
            except OSError:
                pass
        if not _claude_usage_write_logged:
            _claude_usage_write_logged = True
            print("devterm-gate: warning: Claude usage state write failed "
                  f"({type(exc).__name__})", file=sys.stderr, flush=True)
        return False


# ---- Codex usage cache ------------------------------------------------------
# Reading Codex utilization costs an `app-server` spawn, so it is cached with a TTL and
# refreshed in a single background task. Callers never block on more than one refresh,
# and a login/logout invalidates the cache so a previous account's numbers cannot be
# served under the new identity.

def _codex_auth_mtime():
    """Return login generation, absence, or a distinct unavailable sentinel.

    Absence is a valid generation (`None`). Transport failure is not: treating two
    failures as the same generation could let an in-flight result cross a login change.
    """
    if not PLATFORM_ACCOUNTS:
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    try:
        proc = subprocess.run(
            [PLATFORM_ACCOUNTS, "codex-auth", "generation", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    if proc.returncode != 0 or len(proc.stdout) > 4096:
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    try:
        payload = json.loads(proc.stdout.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    if (not isinstance(payload, dict) or payload.get("ok") is not True
            or not isinstance(payload.get("present"), bool)):
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    generation = payload.get("generation")
    if not payload["present"]:
        return None
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 0:
        return _CODEX_AUTH_GENERATION_UNAVAILABLE
    return generation


def _codex_observed_at(value_at):
    if value_at <= 0:
        return None
    return datetime.fromtimestamp(value_at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _codex_cache_value_at():
    return _codex_usage_cache.get("valueAt", 0.0)


def _codex_has_usage_value(result):
    return (isinstance(result, dict)
            and any(_finite_number(result.get(key)) is not None
                    for key in ("use5h", "use7d")))


def _codex_usage_state_save():
    """Remember the last good reading. Best effort — this is a cache, and failing to
    write one must never disturb the request that produced it."""
    payload = _codex_usage_cache.get("payload")
    value_at = _codex_usage_cache.get("valueAt", 0.0)
    if not _codex_has_usage_value(payload) or value_at <= 0:
        return False
    auth_mtime = _codex_usage_cache.get("authMtime")
    if auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE:
        return False
    record = {"payload": payload, "valueAt": value_at, "authMtime": auth_mtime}
    try:
        os.makedirs(CODEX_USAGE_STATE_DIR, exist_ok=True)
        tmp = CODEX_USAGE_STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(record, f)
        os.replace(tmp, CODEX_USAGE_STATE)
        return True
    except OSError:
        return False


def _codex_usage_state_drop():
    try:
        os.remove(CODEX_USAGE_STATE)
    except OSError:
        pass


def _codex_usage_state_load():
    """Seed the cache from the remembered reading. Called once, before serving.

    Refused when it belongs to a different login: auth.json's mtime is stored with the
    numbers, and after a login or logout the previous account's usage is not this
    account's — the same rule the live cache already applies, applied to the file.
    Restored as stale when it is older than the value TTL, so the row says
    '(last value)' instead of presenting a remembered number as a fresh observation."""
    source = CODEX_USAGE_STATE
    if not os.path.isfile(source) and os.path.isfile(LEGACY_CODEX_USAGE_STATE):
        source = LEGACY_CODEX_USAGE_STATE
    try:
        with open(source, encoding="utf-8") as f:
            record = json.load(f)
    except (OSError, ValueError):
        return False
    if not isinstance(record, dict):
        return False
    payload = record.get("payload")
    value_at = _finite_number(record.get("valueAt"))
    if not _codex_has_usage_value(payload) or value_at is None or value_at <= 0:
        return False
    auth_mtime = _codex_auth_mtime()
    if auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE:
        return False
    if record.get("authMtime") != auth_mtime:
        try:
            os.remove(source)          # a different login wrote it; its numbers are void
        except OSError:
            pass
        return False
    payload = dict(payload)
    payload["stale"] = time.time() - value_at > CODEX_USAGE_TTL
    # lastTryAt stays 0 so a value past its TTL is refreshed on the first request rather
    # than riding the retry backoff of a probe this process never made.
    _codex_usage_cache.update(valueAt=value_at, lastTryAt=0.0, payload=payload,
                              authMtime=auth_mtime, task=None)
    if source == LEGACY_CODEX_USAGE_STATE and _codex_usage_state_save():
        try:
            os.remove(LEGACY_CODEX_USAGE_STATE)
        except OSError:
            pass
    return True


def _invalidate_codex_usage_cache():
    task = _codex_usage_cache.get("task")
    if task is not None and not task.done():
        task.cancel()
    _acct_alert_cache.update(at=0.0, payload=None)
    _codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                              authMtime=_codex_auth_mtime(), task=None)
    # The file outlives the process, so leaving it here would resurrect the numbers of
    # the account we just invalidated at the next restart.
    _codex_usage_state_drop()


def _invalidate_acct_caches():
    """Drop the derived account caches after a mutation (swap / remove / login).
    The alert verdict and the live-usage reading both describe "the account in use", so
    a swap makes both wrong at once."""
    global _acct_cache_generation
    _acct_cache_generation += 1
    _acct_alert_cache.update(at=0.0, payload=None)
    _live_usage_cache.update(at=0.0, payload=None)


def _codex_pending_payload(err="pending"):
    return {"use5h": None, "use7d": None, "reset5h": None, "reset7d": None,
            "plan": None, "resetCredits": None, "observedAt": None,
            "err": err, "stale": True}


async def _codex_usage_refresh(auth_mtime):
    current_task = asyncio.current_task()
    try_at = time.time()
    _codex_usage_cache["lastTryAt"] = try_at
    try:
        probe_error = None
        try:
            result = await _probe_json(["--codex-usage"])
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            result = None
            probe_error = f"probe-{type(exc).__name__}"

        # A login/logout (or a newer refresh) invalidated this task: do not attribute
        # the previous account's numbers to the current one.
        current_auth_mtime = _codex_auth_mtime()
        if (auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE
                or current_auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE
                or _codex_usage_cache.get("task") is not current_task
                or _codex_usage_cache.get("authMtime") != auth_mtime
                or current_auth_mtime != auth_mtime):
            return
        now = time.time()
        result_error = result.get("err") if isinstance(result, dict) else None
        last_err = result_error or probe_error or "probe-failed"
        if _codex_has_usage_value(result):
            payload = dict(result)
            payload["observedAt"] = _codex_observed_at(now)
            # The numbers are a fresh observation, so not stale; a partial parse error
            # is kept as side information only.
            payload["stale"] = False
            if result_error:
                payload["lastErr"] = last_err
            else:
                payload.pop("lastErr", None)
            _codex_usage_cache.update(valueAt=now, lastTryAt=now, payload=payload)
            _codex_usage_state_save()   # so the next restart opens on this, not on blank
            _acct_alert_cache.update(at=0.0, payload=None)
        elif _codex_usage_cache.get("payload") is not None:
            # Keep the last good value, marked stale — better than blanking the UI.
            payload = dict(_codex_usage_cache["payload"], stale=True, lastErr=last_err)
            _codex_usage_cache.update(lastTryAt=now, payload=payload)
        elif isinstance(result, dict):
            payload = dict(result, stale=True, lastErr=last_err)
            payload["observedAt"] = None
            _codex_usage_cache.update(lastTryAt=now, valueAt=0.0, payload=payload)
        else:
            payload = _codex_pending_payload(last_err)
            payload["lastErr"] = last_err
            _codex_usage_cache.update(lastTryAt=now, valueAt=0.0, payload=payload)
    finally:
        if _codex_usage_cache.get("task") is current_task:
            _codex_usage_cache["task"] = None


def _codex_usage_refresh_start(auth_mtime):
    task = _codex_usage_cache.get("task")
    if task is None or task.done():
        task = asyncio.create_task(_codex_usage_refresh(auth_mtime))
        _codex_usage_cache["task"] = task
    return task


def _codex_usage_refresh_due(now, force=False):
    if force:
        return True
    last_try = _codex_usage_cache.get("lastTryAt", 0.0)
    if _codex_usage_cache.get("payload") is None:
        return now - last_try >= CODEX_USAGE_RETRY
    payload = _codex_usage_cache["payload"]
    # Only a value-less failure (initial, or a preserved last-good) retries quickly. A
    # partial reading is stale=False + lastErr, so it rides the normal value TTL.
    if isinstance(payload, dict) and payload.get("stale") and payload.get("lastErr"):
        return now - last_try >= CODEX_USAGE_RETRY
    if not _codex_has_usage_value(payload):
        return now - last_try >= CODEX_USAGE_RETRY
    value_at = _codex_cache_value_at()
    if value_at > 0 and now - value_at <= CODEX_USAGE_TTL:
        return False
    if value_at > 0 and last_try <= value_at:
        return True
    return now - last_try >= CODEX_USAGE_RETRY


def _codex_timeout_payload():
    payload = _codex_usage_cache.get("payload")
    if payload is not None:
        return dict(payload, stale=True, lastErr="timeout")
    result = _codex_pending_payload("timeout")
    result["lastErr"] = "timeout"
    return result


async def _codex_usage_cached(force=False, wait=False, wait_valued=False,
                              force_if_stale=False):
    retried_after_cancel = False
    while True:
        auth_mtime = _codex_auth_mtime()
        if auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE:
            task = _codex_usage_cache.get("task")
            if task is not None and not task.done():
                task.cancel()
            _codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                      authMtime=auth_mtime, task=None)
            return _codex_pending_payload("auth-generation-unavailable")
        if auth_mtime != _codex_usage_cache.get("authMtime"):
            _invalidate_codex_usage_cache()
            auth_mtime = _codex_usage_cache["authMtime"]

        now = time.time()
        task = _codex_usage_cache.get("task")
        if task is None or task.done():
            task = None
        payload = _codex_usage_cache.get("payload")
        force_refresh = force or (force_if_stale and isinstance(payload, dict)
                                  and payload.get("stale"))
        if task is None and _codex_usage_refresh_due(now, force=force_refresh):
            task = _codex_usage_refresh_start(auth_mtime)

        # A remembered value is useful immediately; only a value-less cache needs
        # the bounded wait that keeps the first paint from being blank.
        if (wait and task is not None
                and (wait_valued or not _codex_has_usage_value(_codex_usage_cache.get("payload")))):
            try:
                await asyncio.wait_for(asyncio.shield(task), timeout=CODEX_USAGE_WAIT)
            except asyncio.TimeoutError:
                return _codex_timeout_payload()
            except asyncio.CancelledError:
                if not task.cancelled():
                    raise
                # A login/logout cancelled the refresh we were waiting on: restart once
                # against the new auth state, then give up rather than loop.
                if retried_after_cancel:
                    return _codex_pending_payload()
                retried_after_cancel = True
                if _codex_usage_cache.get("task") is task:
                    _invalidate_codex_usage_cache()
                auth_mtime = _codex_auth_mtime()
                if auth_mtime is _CODEX_AUTH_GENERATION_UNAVAILABLE:
                    return _codex_pending_payload("auth-generation-unavailable")
                if auth_mtime != _codex_usage_cache.get("authMtime"):
                    _invalidate_codex_usage_cache()
                    auth_mtime = _codex_usage_cache["authMtime"]
                _codex_usage_refresh_start(auth_mtime)
                continue
            task = _codex_usage_cache.get("task")
            if task is None or task.done():
                task = None
        payload = _codex_usage_cache.get("payload")
        if payload is None:
            return _codex_pending_payload()
        if task is None and not _codex_usage_refresh_due(time.time(), force=force):
            return dict(payload)
        return dict(payload, stale=True) if task is not None else dict(payload)


async def _serve_codex_usage(headers, cw):
    # The first panel read returns a remembered value immediately. Its one follow-up
    # opts into waiting for the shared refresh task, so it cannot race the 12 s probe
    # and get the same stale value merely because it asked after 3 s.
    revalidate = headers.get(b"x-airlock-revalidate") == b"wait"
    payload = await _codex_usage_cached(
        wait=True, wait_valued=revalidate, force_if_stale=revalidate)
    await _send_json(cw, b"200 OK", payload, cors=_cors_origin(headers))


async def _run_probe_result(args=()):
    if not (CLAUDE_STATUS and os.path.isfile(CLAUDE_STATUS)):
        return b"200 OK", {"enabled": False}
    try:
        proc = await asyncio.create_subprocess_exec(
            sys.executable, CLAUDE_STATUS, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=25)
    except (FileNotFoundError, OSError) as e:
        return b"500 Internal Server Error", {"error": str(e)}
    except asyncio.TimeoutError:
        proc.kill(); await proc.wait()
        return b"504 Gateway Timeout", {"error": "probe timeout"}
    if proc.returncode != 0:
        return b"500 Internal Server Error", {"error": "probe failed"}
    try:
        payload = json.loads(out.decode().strip().splitlines()[-1])
    except (ValueError, IndexError, UnicodeDecodeError):
        return b"500 Internal Server Error", {"error": "probe output invalid"}
    if not isinstance(payload, dict):
        return b"500 Internal Server Error", {"error": "probe output invalid"}
    return b"200 OK", payload


async def _run_probe(cw, args=()):
    status, payload = await _run_probe_result(args)
    await _send_json(cw, status, payload)


async def _serve_usage_store(cw):
    """Emit the shared usage store verbatim (present only where DEVTERM_FLEET_STORE is
    set). No secrets — logins, %, observation times."""
    if not FLEET_STORE:
        await _send_json(cw, b"200 OK", {})
        return
    try:
        with open(FLEET_STORE) as f:
            await _send_json(cw, b"200 OK", json.load(f))
    except (OSError, ValueError):
        await _send_json(cw, b"200 OK", {})


def _fetch_fleet_store():
    """Fetch the shared usage store: from the local file if present, else over HTTP if
    a URL is configured. Failures are non-fatal — the account list still renders."""
    if FLEET_STORE:
        try:
            with open(FLEET_STORE) as f:
                return json.load(f)
        except (OSError, ValueError):
            pass
    if FLEET_STORE_URL:
        try:
            with urllib.request.urlopen(FLEET_STORE_URL, timeout=6) as r:
                return json.load(r)
        except Exception:
            pass
    return {}


async def _serve_claude_usage(head, cw):
    """`GET /claude-usage?slot=<account|live>` — query just the one asked-for account.
    (Querying all accounts at once risks 429 when several boxes poll together.)"""
    q = urllib.parse.parse_qs(_request_query(head).decode("utf-8", "replace"))
    slot = (q.get("slot") or ["live"])[0]
    await _run_probe(cw, ["--usage", slot])


async def _serve_claude_status(cw):
    """`GET /claude-status` — which account this box is logged in as + health. No
    secrets. Usage is NOT queried here (per-account API call risks 429)."""
    await _run_probe(cw)


async def _serve_acct_usage_now(cw):
    """Query the live (active) account's usage right now — the popup wants the value
    as of the moment it opened, while the collector runs on its own slower cadence.
    Only the active account (querying all would risk 429)."""
    status, payload = await _run_probe_result(["--usage", "live"])
    # Keep the read-modify-prune-write inline on the single gate loop; the response is
    # still the probe payload verbatim, and a cache failure must not fail this reading.
    _claude_usage_state_save(payload)
    await _send_json(cw, status, payload)


async def _serve_acct_login_url(cw):
    """Add account 1/2 — issue a login link (PKCE). The verifier stays server-side."""
    if not _accounts_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "accounts disabled"})
        return
    ok, out, err = await _claude_switch(["login-url"])
    if ok and out.startswith("https://"):
        await _send_json(cw, b"200 OK", {"ok": True, "url": out.splitlines()[0]})
    else:
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": (err or out or "failed to issue link")[:300]})


async def _serve_acct_login_code(cr, headers, leftover, cw):
    """Add account 2/2 — exchange the approval code for tokens -> saved to the pool
    (name = the logged-in id). The code is a one-time short-lived secret — never logged/echoed."""
    if not _accounts_enabled():
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "accounts disabled"})
        return
    if not _secret_origin_ok(headers):
        await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "forbidden origin"})
        return
    content_type = headers.get(b"content-type", b"").split(b";", 1)[0].strip().lower()
    if content_type != b"application/json":
        await _send_json(cw, b"415 Unsupported Media Type",
                         {"ok": False, "error": "application/json required"})
        return
    d = await _read_json_body(cr, headers, leftover, limit=LOGIN_CODE_BODY_MAX) or {}
    code = (d.get("code") or "").strip()
    try:
        code_bytes = code.encode("utf-8")
    except (AttributeError, UnicodeEncodeError):
        code_bytes = b""
    if (not code_bytes or len(code_bytes) > 400
            or any(c.isspace() for c in code)):
        await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "not a code"})
        return
    ok, out, err = await _claude_switch(
        ["login-code"], stdin_bytes=code_bytes)
    if ok:
        _invalidate_acct_caches()
        # The target is a credential processor, not a trusted response formatter. It
        # may reflect the submitted code even on rc=0, so return only a fixed message.
        await _send_json(cw, b"200 OK", {"ok": True, "msg": "registered"})
    else:
        # The token endpoint is untrusted and may reflect the submitted one-time code in
        # its error body. Keep all subprocess output behind this credential boundary.
        await _send_json(cw, b"400 Bad Request",
                         {"ok": False, "error": "registration failed — request a new login link"})


async def handle(cr, cw):
    try:
        head, leftover = await _read_head(cr)
        if head is None:
            return
        headers = _parse_headers(head)
        login = headers.get(IDENT_HEADER, b"").decode("latin1").strip().lower()
        path = _request_path(head)
        method = head.split(b" ", 1)[0]
        # Defense-in-depth: the nginx owner-gate already gated identity, but re-check
        # here (this gate binds loopback-only, so the injected header cannot be spoofed
        # from the tailnet). Fail-closed: no owner match -> 403.
        if login not in ALLOW:
            cw.write(_resp(b"403 Forbidden", _FORBIDDEN))
            await cw.drain()
            return
        if path in TTYD_PATHS:
            await _proxy_ttyd(head, leftover, headers, cr, cw)
        elif path == b"/sessions":
            await _serve_sessions(cw)
        elif path == b"/upload-image" and method == b"POST":
            await _serve_upload_image(cr, headers, leftover, cw)
        elif path == b"/upload-file" and method == b"POST":
            await _serve_upload_file(cr, headers, leftover, cw)
        elif path == b"/kill-session" and method == b"POST":
            await _serve_kill_session(cr, headers, leftover, cw)
        elif path == b"/list-dir" and method == b"POST":
            await _serve_list_dir(cr, headers, leftover, cw)
        elif path == b"/rename-session" and method == b"POST":
            await _serve_rename_session(cr, headers, leftover, cw)
        elif path == b"/tab-prefs" and method == b"GET":
            await _serve_get_prefs(cw)
        elif path == b"/tab-prefs" and method == b"POST":
            await _serve_put_prefs(cr, headers, leftover, cw)
        elif path == b"/recent-images" and method == b"GET":
            await _serve_recent_images(cw)
        elif path == b"/recent-image" and method == b"GET":
            await _serve_recent_image(head, cw)
        elif path == b"/resolve" and method == b"GET":
            await _serve_resolve(head, cw)
        elif path == b"/layout" and method == b"POST":
            await _serve_layout(cr, headers, leftover, cw)
        elif path == b"/pane" and method == b"POST":
            await _serve_pane(cr, headers, leftover, cw)
        elif path == b"/accounts" and method == b"GET":
            await _serve_accounts(cw)
        elif path == b"/claude-status" and method == b"GET":
            await _serve_claude_status(cw)
        elif path == b"/claude-usage-store" and method == b"GET":
            await _serve_usage_store(cw)
        elif path == b"/claude-usage" and method == b"GET":
            await _serve_claude_usage(head, cw)
        elif path == b"/acct-usage-now" and method == b"POST":
            await _serve_acct_usage_now(cw)
        elif path == b"/codex-usage" and method == b"GET":
            await _serve_codex_usage(headers, cw)
        elif path == b"/acct-alert" and method == b"GET":
            await _serve_acct_alert(headers, cw)
        elif path == b"/secret-put" and method == b"POST":
            await _serve_secret_put(cr, headers, leftover, cw)
        elif path == b"/secret-list" and method == b"GET":
            await _serve_secret_list(headers, cw)
        elif path == b"/secret-del" and method == b"POST":
            await _serve_secret_del(cr, headers, leftover, cw)
        elif path == b"/acct-login-url" and method == b"POST":
            await _serve_acct_login_url(cw)
        elif path == b"/acct-login-code" and method == b"POST":
            await _serve_acct_login_code(cr, headers, leftover, cw)
        elif path == b"/acct-switch" and method == b"POST":
            await _serve_acct_switch(cr, headers, leftover, cw)
        elif path == b"/acct-remove" and method == b"POST":
            await _serve_acct_remove(cr, headers, leftover, cw)
        elif path == b"/codex-login-start" and method == b"POST":
            await _serve_codex_login_start(cw)
        elif path == b"/codex-login-cancel" and method == b"POST":
            await _serve_codex_login_cancel(cw)
        elif path == b"/codex-logout" and method == b"POST":
            await _serve_codex_logout(cw)
        elif path == b"/xai-status" and method == b"GET":
            await _serve_xai_status(cw)
        elif path == b"/xai-login-start" and method == b"POST":
            await _serve_xai_login_start(headers, cw)
        elif path == b"/xai-login-cancel" and method == b"POST":
            await _serve_xai_login_cancel(headers, cw)
        elif path == b"/xai-logout" and method == b"POST":
            await _serve_xai_logout(headers, cw)
        elif path == b"/orca/status" and method == b"GET":
            await _serve_orca_status(cw)
        elif path == b"/orca/tree" and method == b"GET":
            await _serve_orca_tree(cw)
        elif path == b"/orca/worktree-create" and method == b"POST":
            await _serve_orca_worktree_create(cr, headers, leftover, cw)
        elif path == b"/orca/worktree-rm" and method == b"POST":
            await _serve_orca_worktree_rm(cr, headers, leftover, cw)
        elif path == b"/orca/worktree-set" and method == b"POST":
            await _serve_orca_worktree_set(cr, headers, leftover, cw)
        elif path == b"/orca/repo-add" and method == b"POST":
            await _serve_orca_repo_add(cr, headers, leftover, cw)
        else:
            await _serve_static(path, cw)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            cw.close()
        except OSError:
            pass


def _list_recent_images(limit=6):
    """Newest auto-saved images (imageNNN-*.jpg) in ~/uploads, up to limit. (mtime, name, n)."""
    out = []
    if os.path.isdir(UPLOADS):
        for name in os.listdir(UPLOADS):
            m = _RE_UPLOAD.match(name)
            if not m:
                continue
            full = os.path.join(UPLOADS, name)
            try:
                if not os.path.isfile(full):
                    continue
                mt = os.path.getmtime(full)
            except OSError:
                continue
            out.append((mt, name, int(m.group(1))))
    out.sort(reverse=True)
    return out[:limit]


async def _serve_recent_images(cw):
    """Annotate candidates — recent uploaded images (with thumbnail URLs)."""
    items = [{"name": nm, "n": n, "path": f"~/uploads/{nm}",
              "url": "recent-image?name=" + urllib.parse.quote(nm)}
             for (_mt, nm, n) in _list_recent_images(6)]
    await _send_json(cw, b"200 OK", {"ok": True, "images": items})


async def _serve_recent_image(head, cw):
    """Serve image bytes (thumbnail / canvas load). name must match the auto-save rule (traversal block)."""
    q = _request_query(head).decode("utf-8", "ignore")
    name = (urllib.parse.parse_qs(q).get("name") or [""])[0]
    full = os.path.join(UPLOADS, name)
    if not name or not _RE_UPLOAD.match(name) or not os.path.isfile(full):
        cw.write(_resp(b"404 Not Found", b"not found", b"text/plain; charset=utf-8"))
        await cw.drain()
        return
    try:
        with open(full, "rb") as f:
            body = f.read()
    except OSError:
        cw.write(_resp(b"404 Not Found", b"not found", b"text/plain; charset=utf-8"))
        await cw.drain()
        return
    cw.write(_resp(b"200 OK", body, b"image/jpeg", b"no-store, must-revalidate"))
    await cw.drain()


async def main():
    if not IDENT_HEADER:
        sys.stderr.write("devterm-gate: warning: AIRLOCK_IDENTITY_HEADER unset — "
                         "no identity will match, all requests 403 (fail-closed)\n")
    if not ALLOW:
        sys.stderr.write("devterm-gate: warning: AIRLOCK_OWNER unset — no owner "
                         "allowed, all requests 403 (fail-closed)\n")
    # Before the first request, so the first panel opened after a restart shows the last
    # known Codex numbers instead of waiting out a probe on a blank row.
    if _codex_usage_state_load():
        print("devterm-gate: restored last known Codex usage "
              f"({'stale' if _codex_usage_cache['payload'].get('stale') else 'fresh'})",
              flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    signal_wait = True
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
    except (NotImplementedError, RuntimeError):
        signal_wait = False
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    where = ", ".join(str(s.getsockname()) for s in server.sockets)
    print(f"devterm-gate on {where} -> ttyd {TTYD_HOST}:{TTYD_PORT}; web={WEB_ROOT}; "
          f"accounts={_accounts_enabled()}; xai={_xai_enabled()}; "
          f"fileview={FILEVIEW}; orca={bool(ORCA_SHIM)}; "
          f"secret_cli={bool(PLATFORM_SECRET)}", flush=True)
    try:
        async with server:
            if signal_wait:
                await stop.wait()
            else:
                await server.serve_forever()
    finally:
        # The unit intentionally uses KillMode=process so Codex device auth survives a
        # redeploy. xAI keeps the old credential during re-login, so its detached poller
        # has the opposite contract: stop the exact tracked group before this gate exits.
        async with _xai_operation_lock:
            await _cancel_xai_login()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
