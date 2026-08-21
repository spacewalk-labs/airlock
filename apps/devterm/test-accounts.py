"""Offline contract checks for devterm's account line — no HTTP, no box, no network.

Run: python3 apps/devterm/test-accounts.py   (exit 0 = pass)

What it pins down, because these are the parts that fail quietly:
  - the warning grade per axis, and which reason wins at equal severity;
  - that a spent 5h window does not mute a critical 7d window;
  - that /acct-alert still works with NO shared usage store (a single box has no
    collector) by falling back to this box probing its own live account, and that with
    no source at all it reports level="none" instead of inventing one;
  - that the cross-origin echo is limited to this same box (tailnet domains are public
    suffixes, so "same-site" is not a boundary);
  - that a revoked Codex credential (auth.json still present, refresh token dead) is
    graded crit instead of passing for a healthy login;
  - that no identity ever appears in the alert payload.
"""
import asyncio, contextlib, copy, importlib.machinery, importlib.util, inspect, io, json, os, shutil, stat, subprocess, sys, tempfile, time, types
os.environ.setdefault("AIRLOCK_OWNER", "owner@example.com")
spec = importlib.util.spec_from_file_location("gate", "apps/devterm/backend/devterm-gate.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
# claude-status has no .py extension (it is a command on PATH), so it needs an explicit
# source loader. Importing it runs no side effects — main() is behind __main__.
cs_loader = importlib.machinery.SourceFileLoader("claude_status", "apps/devterm/bin/claude-status")
cs_spec = importlib.util.spec_from_loader("claude_status", cs_loader)
cs = importlib.util.module_from_spec(cs_spec); cs_loader.exec_module(cs)

fails = []
def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

TH = g.USAGE_TH
# level grading
check("no data -> none", g._acct_alert_level(None, None, None) == ("none", None))
check("5h warn", g._acct_alert_level(TH["warn5"], 0, None) == ("warn", "usage"))
check("5h crit", g._acct_alert_level(TH["crit5"], 0, None) == ("crit", "usage"))
check("5h spent does not mute 7d crit",
      g._acct_alert_level(100, TH["crit7"], None) == ("crit", "usage"))
# The case the old grader got wrong: it skipped the 5h axis entirely once the window was
# spent, so a fully exhausted account with a quiet 7d window graded "none" — healthy.
# 100 is worse than crit5, never exempt from it.
check("5h spent alone is crit", g._acct_alert_level(100, 0, None) == ("crit", "usage"))
check("5h spent is crit even with 7d at zero and no login warning",
      g._acct_alert_level(100, 0, 30) == ("crit", "usage"))
check("login warn beats usage warn at equal severity",
      g._acct_alert_level(TH["warn5"], 0, 3) == ("warn", "login"))
check("usage crit beats login warn",
      g._acct_alert_level(TH["crit5"], 0, 3) == ("crit", "usage"))
check("codex axis grades", g._acct_alert_level(0, 0, None, TH["crit7"]) == ("crit", "codex"))
check("codex never displaces claude at equal severity",
      g._acct_alert_level(TH["warn5"], 0, None, TH["warn7"]) == ("warn", "usage"))
# A revoked Codex credential: auth.json is still there, so nothing else in the account
# line looks wrong. It has to raise the level on its own.
check("revoked codex login is crit",
      g._acct_alert_level(0, 0, None, None, "auth") == ("crit", "codex-login"))
check("revoked codex login does not displace a claude crit",
      g._acct_alert_level(TH["crit5"], 0, None, None, "auth") == ("crit", "usage"))
check("a retryable codex error is not an alert",
      g._acct_alert_level(0, 0, None, None, "rpc-500") == ("none", None))

# claude-status is the only thing that can tell a revoked credential from a hiccup: it
# is the caller that actually spends the token. Field message from the agent that failed.
check("revoked-token message classifies as auth",
      cs._codex_auth_revoked({"code": -32603, "message":
          "Your access token could not be refreshed because you have since logged out "
          "or signed in to another account. Please sign in again."}))
check("401 classifies as auth", cs._codex_auth_revoked({"code": 401, "message": ""}))
check("an unrelated rpc error is not auth",
      not cs._codex_auth_revoked({"code": -32603, "message": "internal error"}))
check("a non-dict error is not auth", not cs._codex_auth_revoked("boom"))
check("NaN is not a number", g._finite_number(float("nan")) is None)
check("bool is not a number", g._finite_number(True) is None)
check("int passes", g._finite_number(0) == 0)

# xAI status: one auth file, five explicit states, and no credential material in output.
_xai_tmp = tempfile.mkdtemp(prefix="devterm-xai-")
_xai_saved_auth = cs.XAI_AUTH
_xai_access = "ACCESS_DO_NOT_EMIT"
_xai_refresh = "REFRESH_DO_NOT_EMIT"
try:
    cs.XAI_AUTH = os.path.join(_xai_tmp, "auth.json")

    def _write_xai(value):
        with open(cs.XAI_AUTH, "w", encoding="utf-8") as f:
            json.dump(value, f)

    _write_xai({"xai": {"type": "oauth", "access": _xai_access,
                         "refresh": _xai_refresh,
                         "expires": int(time.time() * 1000) + 60_000}})
    _xai_future = cs._xai_status()
    check("xAI valid future credential -> ok", _xai_future["state"] == "ok")
    _write_xai({"xai": {"type": "oauth", "access": _xai_access,
                         "refresh": _xai_refresh, "expires": 1}})
    _xai_past = cs._xai_status()
    check("xAI past access expiry -> refresh-needed state, not signed out",
          _xai_past["state"] == "expired")
    _write_xai({})
    check("xAI key absent -> none", cs._xai_status()["state"] == "none")
    _write_xai({"anthropic": {"type": "oauth"}})
    check("other OpenCode providers without xAI -> none",
          cs._xai_status()["state"] == "none")
    _write_xai({"xai": {"type": "oauth", "access": _xai_access}})
    _xai_bad = cs._xai_status()
    check("xAI wrong-shaped entry -> malformed", _xai_bad["state"] == "malformed")
    os.unlink(cs.XAI_AUTH)
    _xai_missing = cs._xai_status()
    check("xAI missing auth file -> none so first login remains reachable",
          _xai_missing["state"] == "none")
    os.mkdir(cs.XAI_AUTH)
    _xai_err = cs._xai_status()
    check("xAI unreadable path -> typed err", _xai_err["state"] == "err"
          and _xai_err["reason"] == "IsADirectoryError")
    _all_xai_status = json.dumps(
        [_xai_future, _xai_past, _xai_bad, _xai_missing, _xai_err])
    check("xAI status payloads contain no access or refresh token",
          _xai_access not in _all_xai_status and _xai_refresh not in _all_xai_status)
finally:
    cs.XAI_AUTH = _xai_saved_auth
    shutil.rmtree(_xai_tmp, ignore_errors=True)

_device_text = "Open https://accounts.x.ai/device and enter code: ABCD-EFGH"
check("xAI device parser captures the labelled URL and code",
      g._xai_device_values(_device_text)
      == ("https://accounts.x.ai/device", "ABCD-EFGH"))
check("xAI device parser never returns the literal label as a code",
      g._xai_device_values("enter code: CODE") == (None, None))
for _bad_device_url in (
        "https://evil.example/x.ai/approve",
        "https://x.ai.evil.example/device",
        "https://grok.com.evil.example/",
        r"https://evil.example\@x.ai/path",
        "https://evil.example@x.ai/device"):
    check("xAI device parser rejects lookalike host " + _bad_device_url,
          g._xai_device_values(
              "Open " + _bad_device_url + " and enter code: ABCD-EFGH")
          == (None, "ABCD-EFGH"))

_capture_saved = (g.DEVTERM_STATE_DIR, g.XAI_LOGIN_OUT)
_capture_tmp = tempfile.mkdtemp(prefix="devterm-xai-capture-")
try:
    g.DEVTERM_STATE_DIR = os.path.join(_capture_tmp, "state")
    g.XAI_LOGIN_OUT = os.path.join(g.DEVTERM_STATE_DIR, "xai-login.out")
    os.makedirs(g.DEVTERM_STATE_DIR)
    with open(g.XAI_LOGIN_OUT, "w", encoding="utf-8") as f:
        f.write("old")
    os.chmod(g.XAI_LOGIN_OUT, 0o644)
    _capture_fd = g._open_xai_login_capture()
    _capture_mode = stat.S_IMODE(os.fstat(_capture_fd).st_mode)
    os.close(_capture_fd)
    check("xAI capture hardens a pre-existing file to 0600", _capture_mode == 0o600)

    os.unlink(g.XAI_LOGIN_OUT)
    _capture_victim = os.path.join(_capture_tmp, "victim")
    with open(_capture_victim, "w", encoding="utf-8") as f:
        f.write("untouched")
    os.symlink(_capture_victim, g.XAI_LOGIN_OUT)
    try:
        _capture_fd = g._open_xai_login_capture()
    except OSError:
        _capture_symlink_refused = True
    else:
        _capture_symlink_refused = False
        os.close(_capture_fd)
    check("xAI capture refuses a symlink and leaves its target untouched",
          _capture_symlink_refused
          and open(_capture_victim, encoding="utf-8").read() == "untouched")
finally:
    g.DEVTERM_STATE_DIR, g.XAI_LOGIN_OUT = _capture_saved
    shutil.rmtree(_capture_tmp, ignore_errors=True)


async def _xai_gate_cases():
    saved_xai = g.XAI
    saved_status = g.CLAUDE_STATUS
    saved_probe = g._probe_json
    saved_send = g._send_json
    saved_home = os.environ.get("HOME")
    sent = []
    status_file = os.path.join(_xai_tmp, "claude-status")
    os.makedirs(_xai_tmp, exist_ok=True)
    with open(status_file, "w", encoding="utf-8") as f:
        f.write("probe")
    try:
        async def send(_cw, status, payload, **_kwargs):
            sent.append((status, payload))

        g._send_json = send
        g._probe_json = lambda _args: asyncio.sleep(
            0, result={"state": "ok", "expires": 7,
                       "access": "ACCESS_DO_NOT_EMIT", "refresh": "REFRESH_DO_NOT_EMIT"})
        for flag, path in ((False, ""), (False, status_file), (True, "")):
            g.XAI, g.CLAUDE_STATUS = flag, path
            await g._serve_xai_status(None)
        g.XAI, g.CLAUDE_STATUS = True, status_file
        await g._serve_xai_status(None)
        g._probe_json = lambda _args: asyncio.sleep(
            0, result={"state": "err", "reason": "ACCESSDONOTEMIT",
                       "access": "OTHERSECRET"})
        await g._serve_xai_status(None)
        # Reproduce the installed-only failure: the script exists and passes the
        # gate's os.path.isfile guard, but its required staged lib does not. Running
        # the real script exits before argument parsing with empty stdout, so the
        # route must answer 500 rather than pretending the feature is disabled.
        installed_home = os.path.join(_xai_tmp, "home")
        installed_status = os.path.join(installed_home, ".local", "bin", "claude-status")
        os.makedirs(os.path.dirname(installed_status), exist_ok=True)
        shutil.copy2("apps/devterm/bin/claude-status", installed_status)
        os.chmod(installed_status, 0o755)
        os.environ["HOME"] = installed_home
        g.CLAUDE_STATUS = installed_status
        g._probe_json = saved_probe
        await g._serve_xai_status(None)
        return sent
    finally:
        g.XAI = saved_xai
        g.CLAUDE_STATUS = saved_status
        g._probe_json = saved_probe
        g._send_json = saved_send
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home
        shutil.rmtree(_xai_tmp, ignore_errors=True)


_xai_gate_sent = asyncio.run(_xai_gate_cases())
check("xAI flag/binary disabled combinations return clean disabled payloads",
      all(item == (b"200 OK", {"enabled": False}) for item in _xai_gate_sent[:3]))
check("xAI flag on + functional probe returns enabled section",
      _xai_gate_sent[3][0] == b"200 OK" and _xai_gate_sent[3][1]["enabled"] is True
      and _xai_gate_sent[3][1]["state"] == "ok")
check("xAI HTTP allowlist drops token-shaped custom probe fields",
      "ACCESS_DO_NOT_EMIT" not in json.dumps(_xai_gate_sent[3][1])
      and "REFRESH_DO_NOT_EMIT" not in json.dumps(_xai_gate_sent[3][1])
      and "access" not in _xai_gate_sent[3][1]
      and "refresh" not in _xai_gate_sent[3][1])
check("xAI HTTP allowlist never reflects probe error reason",
      _xai_gate_sent[4][1].get("reason") == "credential status unavailable"
      and "ACCESSDONOTEMIT" not in json.dumps(_xai_gate_sent[4][1])
      and "OTHERSECRET" not in json.dumps(_xai_gate_sent[4][1]))
check("xAI present but broken probe is 500, not clean disabled",
      _xai_gate_sent[5][0] == b"500 Internal Server Error"
      and _xai_gate_sent[5][1]["enabled"] is True)


async def _xai_operation_serial_case():
    saved = (g.XAI, g.CLAUDE_STATUS, g._send_json,
             g._serve_xai_login_start_owned, g._cancel_xai_login,
             g._serve_xai_logout_owned, g._xai_operation_lock)
    tmp = tempfile.mkdtemp(prefix="devterm-xai-serial-")
    status_file = os.path.join(tmp, "claude-status")
    with open(status_file, "w", encoding="utf-8") as f:
        f.write("probe")
    sent, owned_calls, cancelled, logout_calls = [], [], [], []
    entered, release = asyncio.Event(), asyncio.Event()
    try:
        g.XAI, g.CLAUDE_STATUS = True, status_file
        g._xai_operation_lock = asyncio.Lock()

        async def send(cw, status, payload, **_kwargs):
            sent.append((cw, status, payload))

        async def owned(cw):
            owned_calls.append(cw)
            entered.set()
            await release.wait()
            await send(cw, b"200 OK", {"ok": True})

        async def cancel():
            cancelled.append(True)
            return True

        async def logout_owned(cw):
            logout_calls.append(cw)

        g._send_json = send
        g._serve_xai_login_start_owned = owned
        g._serve_xai_logout_owned = logout_owned
        json_headers = {b"content-type": b"application/json"}
        cross_headers = {b"content-type": b"application/json",
                         b"origin": b"https://evil.example",
                         b"host": b"box.example"}
        form_headers = {b"content-type": b"application/x-www-form-urlencoded",
                        b"origin": b"https://box.example",
                        b"host": b"box.example"}
        await g._serve_xai_login_start(cross_headers, "cross-start")
        await g._serve_xai_login_cancel(cross_headers, "cross-cancel")
        await g._serve_xai_logout(cross_headers, "cross-logout")
        await g._serve_xai_login_start(form_headers, "form-start")
        first = asyncio.create_task(g._serve_xai_login_start(json_headers, "first"))
        await entered.wait()
        await g._serve_xai_login_start(json_headers, "second")
        release.set()
        await first

        g.XAI, g.CLAUDE_STATUS = False, ""
        g._cancel_xai_login = cancel
        await g._serve_xai_login_cancel(json_headers, "disabled")
        return sent, owned_calls, cancelled, logout_calls
    finally:
        (g.XAI, g.CLAUDE_STATUS, g._send_json,
         g._serve_xai_login_start_owned, g._cancel_xai_login,
         g._serve_xai_logout_owned, g._xai_operation_lock) = saved
        shutil.rmtree(tmp, ignore_errors=True)


(_xai_serial_sent, _xai_owned_calls, _xai_disabled_cancelled,
 _xai_cross_logout_calls) = asyncio.run(_xai_operation_serial_case())
check("cross-origin xAI writes are 403 before any mutation",
      all(any(cw == label and status == b"403 Forbidden"
              for cw, status, _payload in _xai_serial_sent)
          for label in ("cross-start", "cross-cancel", "cross-logout"))
      and _xai_cross_logout_calls == [] and _xai_disabled_cancelled == [])
check("form-encoded xAI writes are refused before login starts",
      any(cw == "form-start" and status == b"415 Unsupported Media Type"
          for cw, status, _payload in _xai_serial_sent))
check("concurrent xAI login starts create only one owned operation",
      _xai_owned_calls == ["first"]
      and any(cw == "second" and status == b"409 Conflict"
              for cw, status, _payload in _xai_serial_sent))
check("xAI cancel obeys the same disabled gate without touching a process",
      not _xai_disabled_cancelled
      and any(cw == "disabled" and status == b"400 Bad Request"
              for cw, status, _payload in _xai_serial_sent))


def _xai_only_installer_case():
    tmp = tempfile.mkdtemp(prefix="devterm-xai-install-")
    try:
        home = os.path.join(tmp, "home")
        render = os.path.join(tmp, "render")
        shims = os.path.join(tmp, "shims")
        os.makedirs(home); os.makedirs(render); os.makedirs(shims)
        cfg = os.path.join(tmp, "airlock.toml")
        with open(cfg, "w", encoding="utf-8") as f:
            f.write('[auth]\nprovider = "tailscale"\nowner = "owner@example.com"\n'
                    '[apps.hub]\n[apps.devterm]\nxai = true\n')
        path = os.environ.get("PATH", "")
        for command in ("tmux", "python3", "curl", "sha256sum",
                        "systemctl", "tailscale", "sudo"):
            if shutil.which(command, path=path):
                continue
            shim = os.path.join(shims, command)
            with open(shim, "w", encoding="utf-8") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(shim, 0o755)
        env = dict(os.environ, HOME=home, AIRLOCK_CONFIG=cfg,
                   AIRLOCK_TS_FQDN="box.example.ts.net", AIRLOCK_DRY_RUN="1",
                   AIRLOCK_RENDER_DIR=render, PATH=shims + os.pathsep + path)
        result = subprocess.run(
            ["bash", "apps/devterm/install.sh"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        unit = os.path.join(render, "units", "airlock-devterm-gate.service")
        unit_text = open(unit, encoding="utf-8").read() if os.path.isfile(unit) else ""
        return result.returncode, result.stdout, unit_text
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


_xai_install_rc, _xai_install_out, _xai_install_unit = _xai_only_installer_case()
check("xAI-only real installer dry-run succeeds", _xai_install_rc == 0)
check("xAI-only installer stages claude-status and bin_discovery together",
      "bin/claude-status" in _xai_install_out
      and "backend/bin_discovery.py" in _xai_install_out
      and "bin/claude-switch" not in _xai_install_out)
check("xAI-only installer wires the flag and status probe, not Claude pool tools",
      "Environment=DEVTERM_XAI=true" in _xai_install_unit
      and "Environment=DEVTERM_CLAUDE_STATUS=" in _xai_install_unit
      and "Environment=DEVTERM_CLAUDE_SWITCH=" not in _xai_install_unit)


async def _xai_logout_timeout_case():
    saved = (g.XAI, g.CLAUDE_STATUS, g._opencode_bin, g._send_json,
             g.asyncio.create_subprocess_exec, g._signal_probe_group,
             g.XAI_LOGOUT_WAIT, g._xai_login_process)
    tmp = tempfile.mkdtemp(prefix="devterm-xai-logout-")
    status_file = os.path.join(tmp, "claude-status")
    with open(status_file, "w", encoding="utf-8") as f:
        f.write("probe")
    signals, sent = [], []

    class SlowProc:
        pid = 424242
        returncode = None
        waits = 0

        async def communicate(self):
            await asyncio.sleep(1)

        async def wait(self):
            self.waits += 1
            return -15

    proc = SlowProc()
    try:
        g.XAI, g.CLAUDE_STATUS = True, status_file
        g._xai_login_process = None
        g._opencode_bin = lambda: "/fake/opencode"
        g.XAI_LOGOUT_WAIT = 0.001

        async def create(*_args, **_kwargs):
            return proc

        async def send(_cw, status, payload, **_kwargs):
            sent.append((status, payload))

        g.asyncio.create_subprocess_exec = create
        g._signal_probe_group = lambda pgid, sig: signals.append((pgid, sig))
        g._send_json = send
        await g._serve_xai_logout({b"content-type": b"application/json"}, None)
        return proc, signals, sent
    finally:
        (g.XAI, g.CLAUDE_STATUS, g._opencode_bin, g._send_json,
         g.asyncio.create_subprocess_exec, g._signal_probe_group,
         g.XAI_LOGOUT_WAIT, g._xai_login_process) = saved
        shutil.rmtree(tmp, ignore_errors=True)


_logout_proc, _logout_signals, _logout_sent = asyncio.run(_xai_logout_timeout_case())
check("xAI logout timeout terminates and reaps its exact process group",
      _logout_proc.waits >= 1
      and (424242, g.signal.SIGTERM) in _logout_signals
      and (424242, g.signal.SIGKILL) not in _logout_signals)
check("xAI logout timeout returns a generic error with no command output",
      _logout_sent == [(b"400 Bad Request",
                        {"ok": False, "error": "OpenCode xAI logout timed out"})])


async def _xai_termination_cases():
    saved_signal = g._signal_probe_group
    saved_group_alive = g._xai_group_alive
    saved_grace = g.PROBE_KILL_GRACE
    signals = []

    class Proc:
        returncode = None

        def __init__(self, pid, ignores_term):
            self.pid = pid
            self.ignores_term = ignores_term
            self.waits = 0

        async def wait(self):
            self.waits += 1
            if self.ignores_term and self.waits == 1:
                await asyncio.sleep(1)
            return -15

    responsive = Proc(1001, False)
    stubborn = Proc(1002, True)
    descendant = Proc(1003, False)
    try:
        g.PROBE_KILL_GRACE = 0.001
        g._signal_probe_group = lambda pgid, sig: signals.append((pgid, sig))
        g._xai_group_alive = lambda pgid: pgid == 1003
        await g._terminate_xai_process(responsive)
        await g._terminate_xai_process(stubborn)
        await g._terminate_xai_process(descendant)
        return responsive, stubborn, descendant, signals
    finally:
        g._signal_probe_group = saved_signal
        g._xai_group_alive = saved_group_alive
        g.PROBE_KILL_GRACE = saved_grace


_term_responsive, _term_stubborn, _term_descendant, _term_signals = asyncio.run(
    _xai_termination_cases())
check("xAI group termination does not KILL after TERM was reaped",
      (1001, g.signal.SIGTERM) in _term_signals
      and (1001, g.signal.SIGKILL) not in _term_signals
      and _term_responsive.waits == 1)
check("xAI group termination promotes TERM to KILL only after timeout",
      (1002, g.signal.SIGTERM) in _term_signals
      and (1002, g.signal.SIGKILL) in _term_signals
      and _term_stubborn.waits == 2)
check("xAI group termination kills descendants left after leader exit",
      (1003, g.signal.SIGTERM) in _term_signals
      and (1003, g.signal.SIGKILL) in _term_signals)

_saved_login_process = g._xai_login_process
try:
    g._xai_login_process = types.SimpleNamespace(returncode=None)
    check("xAI tracked login reports pending", g._xai_login_state() == "pending")
    g._xai_login_process.returncode = 0
    check("xAI tracked login reports succeeded", g._xai_login_state() == "succeeded")
    g._xai_login_process.returncode = 1
    check("xAI tracked login reports failed", g._xai_login_state() == "failed")
finally:
    g._xai_login_process = _saved_login_process

_main_source = inspect.getsource(g.main)
check("gate shutdown serializes and cancels the tracked xAI process",
      "finally:" in _main_source
      and "async with _xai_operation_lock" in _main_source
      and "await _cancel_xai_login()" in _main_source)

# CORS: same first hostname label echoes, anything else does not
import socket
host = socket.gethostname().split(".")[0]
check("same-box origin echoes",
      g._cors_origin({b"origin": f"https://{host}.example.ts.net:8447".encode()})
      == f"https://{host}.example.ts.net:8447".encode())
check("other node does not echo",
      g._cors_origin({b"origin": b"https://someone-else.example.ts.net"}) is None)
check("no origin -> None", g._cors_origin({}) is None)
check("garbage origin -> None", g._cors_origin({b"origin": b"::::"}) is None)

# _resp keeps the ACAO header out unless asked
r = g._resp(b"200 OK", b"{}", b"application/json")
check("no ACAO by default", b"Access-Control-Allow-Origin" not in r)
r2 = g._resp(b"200 OK", b"{}", b"application/json", extra=b"Access-Control-Allow-Origin: x\r\n")
check("ACAO + Connection both present", b"Access-Control-Allow-Origin: x\r\n" in r2 and b"Connection: close" in r2)

# codex cache: pending shape has every key the success shape has
succ = {"use5h": 1, "use7d": 2, "reset5h": None, "reset7d": None, "plan": None,
        "resetCredits": None, "observedAt": None, "err": None}
pend = g._codex_pending_payload()
check("pending payload keeps the success keys", set(succ) <= set(pend))
check("has_usage_value false on empty", not g._codex_has_usage_value({"use5h": None, "use7d": None}))
check("has_usage_value true on one axis", g._codex_has_usage_value({"use5h": 0, "use7d": None}))

# codex usage survives a restart. The in-memory cache dies with the process and the
# reading costs an app-server spawn, so the panel used to open blank and stay blank
# while the probe ran. What must NOT survive: another account's numbers, and the claim
# that a remembered value is a fresh observation.
import tempfile
_codex_state_tmp = tempfile.mkdtemp(prefix="devterm-codex-state-")
g.CODEX_USAGE_STATE_DIR = _codex_state_tmp
g.CODEX_USAGE_STATE = os.path.join(_codex_state_tmp, "codex-usage.json")
g.LEGACY_CODEX_USAGE_STATE = os.path.join(_codex_state_tmp, "legacy-codex-usage.json")


def _codex_state_case(value_age, auth_mtime_at_load, payload=None):
    """Save a reading, wipe the memory cache, then load as a fresh process would."""
    g._codex_usage_state_drop()
    now = time.time()
    g._codex_usage_cache.update(valueAt=now - value_age, lastTryAt=now, task=None,
                                authMtime="login-A",
                                payload=payload or {"use5h": 4, "use7d": 5, "stale": False})
    saved = g._codex_usage_state_save()
    g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                authMtime=None, task=None)
    g._codex_auth_mtime = lambda: auth_mtime_at_load
    return saved, g._codex_usage_state_load(), g._codex_usage_cache.get("payload")


_real_auth_mtime = g._codex_auth_mtime
saved, loaded, payload = _codex_state_case(0, "login-A")
check("a fresh reading is saved and restored", saved and loaded and payload["use7d"] == 5)
check("a reading inside the TTL is restored as fresh", payload.get("stale") is False)

os.replace(g.CODEX_USAGE_STATE, g.LEGACY_CODEX_USAGE_STATE)
g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                            authMtime=None, task=None)
check("legacy Codex state migrates into the app-owned artifact",
      g._codex_usage_state_load()
      and os.path.isfile(g.CODEX_USAGE_STATE)
      and not os.path.exists(g.LEGACY_CODEX_USAGE_STATE))

_, loaded, payload = _codex_state_case(g.CODEX_USAGE_TTL + 60, "login-A")
check("a reading past the TTL is restored as stale (the row says 'last value')",
      loaded and payload.get("stale") is True)

_, loaded, payload = _codex_state_case(0, "login-B")
check("another login's numbers are refused", not loaded and payload is None)
check("and the file holding them is dropped", not os.path.exists(g.CODEX_USAGE_STATE))

saved, _, _ = _codex_state_case(0, "login-A", payload={"use5h": None, "use7d": None})
check("a value-less payload is not saved", not saved)

g._codex_auth_mtime = lambda: "login-A"
g._codex_usage_cache.update(valueAt=time.time(), payload={"use5h": 1, "use7d": 2},
                            authMtime="login-A")
g._codex_usage_state_save()
g._invalidate_codex_usage_cache()
check("login/logout drops the file, so a restart cannot resurrect it",
      not os.path.exists(g.CODEX_USAGE_STATE))

g._codex_auth_mtime = _real_auth_mtime
shutil.rmtree(_codex_state_tmp, ignore_errors=True)

# Verification #3: a valued stale cache is returned while its refresh runs in the
# background; an empty cache still waits so the first paint can get a number.
async def _codex_response_case():
    saved_cache = dict(g._codex_usage_cache)
    saved_auth_mtime = g._codex_auth_mtime
    saved_refresh_start = g._codex_usage_refresh_start
    tasks = []
    try:
        g._codex_auth_mtime = lambda: "login-A"
        release = asyncio.Event()

        async def held_refresh():
            await release.wait()

        def start_held_refresh(_auth_mtime):
            task = asyncio.create_task(held_refresh())
            tasks.append(task)
            g._codex_usage_cache["task"] = task
            return task

        g._codex_usage_refresh_start = start_held_refresh
        now = time.time()
        g._codex_usage_cache.update(
            valueAt=now - g.CODEX_USAGE_TTL - 1,
            lastTryAt=now - g.CODEX_USAGE_TTL - 2,
            payload={"use5h": None, "use7d": 42, "stale": True},
            authMtime="login-A", task=None)
        result = await g._codex_usage_cached(wait=True)
        check("valued stale cache returns before refresh completes",
              result.get("use7d") == 42 and result.get("stale") is True
              and tasks and not tasks[0].done())
        tasks[0].cancel()
        try:
            await tasks[0]
        except asyncio.CancelledError:
            pass

        started = asyncio.Event()
        release = asyncio.Event()

        async def completing_refresh():
            started.set()
            await release.wait()
            refreshed_at = time.time()
            g._codex_usage_cache.update(
                valueAt=refreshed_at, lastTryAt=refreshed_at,
                payload={"use5h": None, "use7d": 43, "stale": False})

        def start_completing_refresh(_auth_mtime):
            task = asyncio.create_task(completing_refresh())
            tasks.append(task)
            g._codex_usage_cache["task"] = task
            return task

        g._codex_usage_refresh_start = start_completing_refresh
        now = time.time()
        g._codex_usage_cache.update(
            valueAt=now - g.CODEX_USAGE_TTL - 1,
            lastTryAt=now - g.CODEX_USAGE_TTL - 2,
            payload={"use5h": None, "use7d": 42, "stale": True},
            authMtime="login-A", task=None)
        waiting = asyncio.create_task(
            g._codex_usage_cached(wait=True, wait_valued=True, force_if_stale=True))
        await started.wait()
        check("explicit revalidation waits for a valued cache refresh", not waiting.done())
        release.set()
        result = await waiting
        check("explicit revalidation returns the refreshed value",
              result.get("use7d") == 43 and result.get("stale") is False)
        task_count = len(tasks)
        result = await g._codex_usage_cached(
            wait=True, wait_valued=True, force_if_stale=True)
        check("explicit revalidation serves an already fresh value without another probe",
              len(tasks) == task_count and result.get("use7d") == 43
              and result.get("stale") is False)

        started = asyncio.Event()
        release = asyncio.Event()
        g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                    authMtime="login-A", task=None)
        waiting = asyncio.create_task(g._codex_usage_cached(wait=True))
        await started.wait()
        check("value-less cache waits for its refresh", not waiting.done())
        release.set()
        result = await waiting
        check("value-less cache returns the completed refresh",
              result.get("use7d") == 43 and result.get("stale") is False)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        for task in tasks:
            if not task.done():
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        g._codex_usage_cache.update(saved_cache)
        g._codex_auth_mtime = saved_auth_mtime
        g._codex_usage_refresh_start = saved_refresh_start


asyncio.run(_codex_response_case())


async def _codex_revalidate_route_case():
    saved_cached = g._codex_usage_cached
    saved_send_json = g._send_json
    calls = []
    try:
        async def cached(**kwargs):
            calls.append(kwargs)
            return {"use7d": 43}

        async def send_json(*_args, **_kwargs):
            return None

        g._codex_usage_cached = cached
        g._send_json = send_json
        await g._serve_codex_usage({}, None)
        await g._serve_codex_usage({b"x-airlock-revalidate": b"wait"}, None)
        return calls
    finally:
        g._codex_usage_cached = saved_cached
        g._send_json = saved_send_json


revalidate_calls = asyncio.run(_codex_revalidate_route_case())
check("the one re-ask opts into stale refresh + valued-cache waiting",
      revalidate_calls == [
          {"wait": True, "wait_valued": False, "force_if_stale": False},
          {"wait": True, "wait_valued": True, "force_if_stale": True},
      ])

# Verification #7: both the request entry point and the refresh completion guard refuse
# to associate a previous account's numbers with a changed auth identity.
async def _codex_identity_case():
    saved_cache = dict(g._codex_usage_cache)
    saved_auth_mtime = g._codex_auth_mtime
    saved_refresh_start = g._codex_usage_refresh_start
    saved_probe_json = g._probe_json
    pending = None
    try:
        g._codex_auth_mtime = lambda: "login-B"
        release = asyncio.Event()

        async def held_refresh():
            await release.wait()

        def start_held_refresh(_auth_mtime):
            nonlocal pending
            pending = asyncio.create_task(held_refresh())
            g._codex_usage_cache["task"] = pending
            return pending

        g._codex_usage_refresh_start = start_held_refresh
        now = time.time()
        g._codex_usage_cache.update(
            valueAt=now - g.CODEX_USAGE_TTL - 1,
            lastTryAt=now - g.CODEX_USAGE_TTL - 2,
            payload={"use5h": None, "use7d": 88},
            authMtime="login-A", task=None)
        result = await g._codex_usage_cached()
        check("auth identity change drops the old cached value", result.get("use7d") is None)
        pending.cancel()
        try:
            await pending
        except asyncio.CancelledError:
            pass

        async def old_account_probe(_args):
            return {"use5h": None, "use7d": 99}

        g._probe_json = old_account_probe
        g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                    authMtime="login-A", task=None)
        refresh = asyncio.create_task(g._codex_usage_refresh("login-A"))
        g._codex_usage_cache["task"] = refresh
        await refresh
        check("in-flight refresh drops a response after identity change",
              g._codex_usage_cache.get("payload") is None)
    finally:
        if pending is not None and not pending.done():
            pending.cancel()
            try:
                await pending
            except asyncio.CancelledError:
                pass
        g._codex_usage_cache.update(saved_cache)
        g._codex_auth_mtime = saved_auth_mtime
        g._codex_usage_refresh_start = saved_refresh_start
        g._probe_json = saved_probe_json


asyncio.run(_codex_identity_case())

# Verification #4: a successful account login invalidates both derived account caches
# before the success response is sent.
async def _acct_login_success_case():
    saved_accounts_enabled = g._accounts_enabled
    saved_read_json = g._read_json_body
    saved_claude_switch = g._claude_switch
    saved_send_json = g._send_json
    saved_alert = dict(g._acct_alert_cache)
    saved_live = dict(g._live_usage_cache)
    saved_generation = g._acct_cache_generation
    sent = {}
    try:
        g._accounts_enabled = lambda: True

        async def read_json(_cr, _headers, _leftover):
            return {"code": "one-time-code"}

        async def login_code(_args):
            return True, "registered", ""

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g._read_json_body = read_json
        g._claude_switch = login_code
        g._send_json = send_json
        g._acct_alert_cache.update(at=time.time(), payload={"level": "crit"})
        g._live_usage_cache.update(at=time.time(), payload={"use5h": 99})
        await g._serve_acct_login_code(None, {}, b"", None)
        return sent, (g._acct_alert_cache["at"], g._acct_alert_cache["payload"]), \
            (g._live_usage_cache["at"], g._live_usage_cache["payload"])
    finally:
        g._accounts_enabled = saved_accounts_enabled
        g._read_json_body = saved_read_json
        g._claude_switch = saved_claude_switch
        g._send_json = saved_send_json
        g._acct_alert_cache.update(saved_alert)
        g._live_usage_cache.update(saved_live)
        g._acct_cache_generation = saved_generation


login_sent, login_alert_cache, login_live_cache = asyncio.run(_acct_login_success_case())
check("successful account login invalidates derived caches",
      login_sent.get("payload", {}).get("ok") is True
      and login_alert_cache == (0.0, None)
      and login_live_cache == (0.0, None))


async def _acct_login_inflight_case():
    """An old alert must not repopulate either cache after login wins the race."""
    saved_accounts_enabled = g._accounts_enabled
    saved_read_json = g._read_json_body
    saved_claude_switch = g._claude_switch
    saved_list = g._acct_list_with_usage
    saved_codex = g._codex_usage_cached
    saved_send_json = g._send_json
    saved_alert = dict(g._acct_alert_cache)
    saved_live = dict(g._live_usage_cache)
    saved_generation = g._acct_cache_generation
    first_started = asyncio.Event()
    release_first = asyncio.Event()
    sent = []
    calls = 0
    try:
        g._accounts_enabled = lambda: True

        async def read_json(_cr, _headers, _leftover):
            return {"code": "one-time-code"}

        async def login_code(_args):
            return True, "registered", ""

        async def account_list():
            nonlocal calls
            calls += 1
            if calls == 1:
                first_started.set()
                await release_first.wait()
                use5h = 99
            else:
                use5h = 1
            return {"accounts": [{"active": True, "usage": {"use5h": use5h,
                                                               "use7d": 1}}]}

        async def codex_usage(*_args, **_kwargs):
            return {}

        async def send_json(_cw, _status, payload, **_kwargs):
            sent.append(payload)

        g._read_json_body = read_json
        g._claude_switch = login_code
        g._acct_list_with_usage = account_list
        g._codex_usage_cached = codex_usage
        g._send_json = send_json
        g._acct_alert_cache.update(at=0.0, payload=None)
        g._live_usage_cache.update(at=0.0, payload=None)

        alert_task = asyncio.create_task(g._serve_acct_alert({}, None))
        await first_started.wait()
        await g._serve_acct_login_code(None, {}, b"", None)
        release_first.set()
        await alert_task
        payload = sent[-1]
        cached = g._acct_alert_cache.get("payload")
        return calls, payload, cached
    finally:
        g._accounts_enabled = saved_accounts_enabled
        g._read_json_body = saved_read_json
        g._claude_switch = saved_claude_switch
        g._acct_list_with_usage = saved_list
        g._codex_usage_cached = saved_codex
        g._send_json = saved_send_json
        g._acct_alert_cache.update(saved_alert)
        g._live_usage_cache.update(saved_live)
        g._acct_cache_generation = saved_generation


race_calls, race_payload, race_cached = asyncio.run(_acct_login_inflight_case())
check("successful login rejects an in-flight old-account alert result",
      race_calls == 2 and race_payload.get("use5h") == 1
      and race_cached is not None and race_cached.get("use5h") == 1)


async def _live_usage_inflight_case():
    saved_probe = g._probe_json
    saved_live = dict(g._live_usage_cache)
    saved_alert = dict(g._acct_alert_cache)
    saved_generation = g._acct_cache_generation
    started = asyncio.Event()
    release = asyncio.Event()
    try:
        async def probe(_args):
            started.set()
            await release.wait()
            return {"usage": {"use5h": 99, "use7d": 99}}

        g._probe_json = probe
        g._live_usage_cache.update(at=0.0, payload=None)
        task = asyncio.create_task(g._live_usage_cached())
        await started.wait()
        g._invalidate_acct_caches()
        release.set()
        result = await task
        return result, g._live_usage_cache.get("payload")
    finally:
        g._probe_json = saved_probe
        g._live_usage_cache.update(saved_live)
        g._acct_alert_cache.update(saved_alert)
        g._acct_cache_generation = saved_generation


old_live_result, live_cache_after_login = asyncio.run(_live_usage_inflight_case())
check("successful login prevents an in-flight old live probe from refilling the cache",
      old_live_result.get("use5h") == 99 and live_cache_after_login is None)

# P1: the panel's successful live Claude reading is persisted by Airlock and merged at
# /accounts only. Keep these checks above alert_with: that older helper intentionally
# installs process-wide stubs and does not restore them.
_claude_state_tmp = tempfile.mkdtemp(prefix="devterm-claude-state-")
_real_claude_state_dir = g.CLAUDE_USAGE_STATE_DIR
_real_claude_state = g.CLAUDE_USAGE_STATE
g.CLAUDE_USAGE_STATE_DIR = _claude_state_tmp
g.CLAUDE_USAGE_STATE = os.path.join(_claude_state_tmp, "claude-usage.json")


def _claude_result(use5h=71, use7d=62, email="claude@example.com", kind="personal"):
    return {"state": "ok", "email": email, "kind": kind,
            "usage": {"use5h": use5h, "use7d": use7d,
                      "reset5h": None, "reset7d": "tomorrow"}}


def _write_claude_store(raw):
    with open(g.CLAUDE_USAGE_STATE, "w", encoding="utf-8") as f:
        json.dump(raw, f)


async def _serve_accounts_fixture(account):
    saved_enabled = g._accounts_enabled
    saved_list = g._acct_list_with_usage
    saved_send = g._send_json
    sent = {}
    try:
        g._accounts_enabled = lambda: True

        async def account_list():
            return {"active": account.get("name"), "accounts": [copy.deepcopy(account)]}

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g._acct_list_with_usage = account_list
        g._send_json = send_json
        await g._serve_accounts(None)
        return sent
    finally:
        g._accounts_enabled = saved_enabled
        g._acct_list_with_usage = saved_list
        g._send_json = saved_send


async def _claude_usage_route_case():
    saved_enabled = g._accounts_enabled
    saved_list = g._acct_list_with_usage
    saved_probe = g._run_probe_result
    saved_send = g._send_json
    fleet_usage = {"use5h": 12, "use7d": 13, "reset5h": None,
                   "reset7d": None, "observedAt": time.time() - 120}
    sent = []
    try:
        g._accounts_enabled = lambda: True

        async def account_list():
            return {"active": "slot-a", "accounts": [{
                "name": "slot-a", "active": True, "email": "claude@example.com",
                "kind": "personal", "holders": ["box-a"],
                "usage": copy.deepcopy(fleet_usage),
            }]}

        async def probe(_args):
            return b"200 OK", _claude_result()

        async def send_json(_cw, status, payload, **_kwargs):
            sent.append((status, copy.deepcopy(payload)))

        g._acct_list_with_usage = account_list
        g._run_probe_result = probe
        g._send_json = send_json
        await g._serve_accounts(None)
        await g._serve_acct_usage_now(None)
        await g._serve_accounts(None)
        fleet_usage.clear()
        fleet_usage.update({"err": "no data"})
        await g._serve_accounts(None)
        return sent
    finally:
        g._accounts_enabled = saved_enabled
        g._acct_list_with_usage = saved_list
        g._run_probe_result = saved_probe
        g._send_json = saved_send


route_reads = asyncio.run(_claude_usage_route_case())
check("P1 live route returns its probe payload unchanged",
      route_reads[1] == (b"200 OK", _claude_result()))
check("P1 newer live reading replaces the older fleet value on the next account list",
      route_reads[0][1]["accounts"][0]["usage"]["use5h"] == 12
      and route_reads[2][1]["accounts"][0]["usage"]["use5h"] == 71)
check("P1 live reading is available with no fleet store",
      route_reads[3][1]["accounts"][0]["usage"]["use7d"] == 62)

loaded_after_route = g._claude_usage_state_load()
stored_mode = stat.S_IMODE(os.stat(g.CLAUDE_USAGE_STATE).st_mode)
check("P1 store survives a simulated restart and is mode 0600",
      loaded_after_route["claude@example.com|personal"]["usage"]["use5h"] == 71
      and stored_mode == 0o600)

# Recency and complete-field replacement. Ties belong to the fleet entry.
_merge_now = time.time()
_fleet_account = {
    "name": "slot-a", "active": True, "email": "claude@example.com",
    "kind": "personal", "holders": ["box-a"],
    "usage": {"use5h": 20, "use7d": 21, "reset5h": "fleet-5",
              "reset7d": "fleet-7", "observedAt": _merge_now - 10, "age": 10},
}


def _set_local(value_at, use5h=80):
    _write_claude_store({"version": 1, "accounts": {
        "claude@example.com|personal": {
            "usage": {"use5h": use5h, "use7d": 81,
                      "reset5h": "local-5", "reset7d": "local-7"},
            "valueAt": value_at,
        }}})


_set_local(_merge_now - 20)
fleet_newer = asyncio.run(_serve_accounts_fixture(_fleet_account))["payload"]["accounts"][0]
_set_local(_merge_now - 10)
tie = asyncio.run(_serve_accounts_fixture(_fleet_account))["payload"]["accounts"][0]
_set_local(_merge_now - 5)
local_newer = asyncio.run(_serve_accounts_fixture(_fleet_account))["payload"]["accounts"][0]
no_fleet_account = copy.deepcopy(_fleet_account)
no_fleet_account["usage"] = {"err": "no data"}
local_without_fleet = asyncio.run(_serve_accounts_fixture(no_fleet_account))["payload"]["accounts"][0]
check("P1 merge recency keeps fleet-newer and tie values",
      fleet_newer["usage"]["use5h"] == 20 and tie["usage"]["use5h"] == 20)
check("P1 merge recency takes local-newer and no-fleet values",
      local_newer["usage"]["use5h"] == 80
      and local_without_fleet["usage"]["use5h"] == 80)
local_usage = local_newer["usage"]
check("P1 local merge moves freshness fields together and preserves holders",
      local_usage["stale"] is True and 0 <= local_usage["age"] <= 10
      and local_usage["observedAt"] == _merge_now - 5
      and local_usage["reset5h"] == "local-5"
      and local_newer["holders"] == ["box-a"])


async def _real_list_recency_case():
    """Exercise observedAt through the real fleet reader, not a prepared list stub."""
    saved_create = g.asyncio.create_subprocess_exec
    saved_fetch = g._fetch_fleet_store
    saved_enabled = g._accounts_enabled
    saved_send = g._send_json
    fleet_at = time.time() - 10
    sent = []

    class FakeProc:
        returncode = 0

        async def communicate(self):
            payload = {"active": "slot-a", "accounts": [{
                "name": "slot-a", "active": True, "email": "claude@example.com",
                "kind": "personal", "sub": "Claude",
            }]}
            return json.dumps(payload).encode(), b""

        def kill(self):
            self.returncode = -9

        async def wait(self):
            return self.returncode

    try:
        async def create_proc(*_args, **_kwargs):
            return FakeProc()

        async def send_json(_cw, _status, payload, **_kwargs):
            sent.append(copy.deepcopy(payload))

        g.asyncio.create_subprocess_exec = create_proc
        g._fetch_fleet_store = lambda: {
            "claude@example.com|personal": {
                "usage": {"use5h": 20, "use7d": 21,
                          "reset5h": "fleet-5", "reset7d": "fleet-7"},
                "observedAt": fleet_at, "holders": ["box-a"],
            }}
        g._accounts_enabled = lambda: True
        g._send_json = send_json
        _set_local(fleet_at)
        await g._serve_accounts(None)
        _set_local(fleet_at + 1)
        await g._serve_accounts(None)
        return fleet_at, sent
    finally:
        g.asyncio.create_subprocess_exec = saved_create
        g._fetch_fleet_store = saved_fetch
        g._accounts_enabled = saved_enabled
        g._send_json = saved_send


real_fleet_at, real_recency = asyncio.run(_real_list_recency_case())
check("P1 real fleet reader carries observedAt into tie and newer comparisons",
      real_recency[0]["accounts"][0]["usage"]["observedAt"] == real_fleet_at
      and real_recency[0]["accounts"][0]["usage"]["use5h"] == 20
      and real_recency[1]["accounts"][0]["usage"]["use5h"] == 80)

# Every malformed store shape quietly falls back to the fleet reading.
_valid_entry = {"usage": {"use5h": 90, "use7d": 91,
                           "reset5h": None, "reset7d": None},
                "valueAt": time.time()}
_bad_stores = [
    ("unsupported version", {"version": 2, "accounts": {
        "claude@example.com|personal": _valid_entry}}),
    ("future timestamp", {"version": 1, "accounts": {
        "claude@example.com|personal": dict(_valid_entry,
            valueAt=time.time() + g.CLAUDE_USAGE_FUTURE_SKEW + 60)}}),
    ("non-finite utilization", {"version": 1, "accounts": {
        "claude@example.com|personal": dict(_valid_entry,
            usage=dict(_valid_entry["usage"], use5h=float("nan")))}}),
    ("out-of-range utilization", {"version": 1, "accounts": {
        "claude@example.com|personal": dict(_valid_entry,
            usage=dict(_valid_entry["usage"], use5h=101))}}),
    ("unparseable account key", {"version": 1, "accounts": {
        "not-a-composite-key": _valid_entry}}),
]
for bad_name, bad_store in _bad_stores:
    _write_claude_store(bad_store)
    bad_result = asyncio.run(_serve_accounts_fixture(_fleet_account))["payload"]
    check("P1 rejects " + bad_name + " and keeps fleet", bad_result["accounts"][0]["usage"]["use5h"] == 20)
with open(g.CLAUDE_USAGE_STATE, "w", encoding="utf-8") as f:
    f.write("{not json")
corrupt_result = asyncio.run(_serve_accounts_fixture(_fleet_account))["payload"]
check("P1 rejects corrupt store and keeps fleet",
      corrupt_result["accounts"][0]["usage"]["use5h"] == 20)


async def _deep_corrupt_live_case():
    saved_probe = g._run_probe_result
    saved_send = g._send_json
    sent = []
    try:
        async def probe(_args):
            return b"200 OK", _claude_result()

        async def send_json(_cw, status, payload, **_kwargs):
            sent.append((status, payload))

        g._run_probe_result = probe
        g._send_json = send_json
        with open(g.CLAUDE_USAGE_STATE, "w", encoding="utf-8") as f:
            f.write("[" * 10000 + "0" + "]" * 10000)
        fixture_recurses = False
        try:
            with open(g.CLAUDE_USAGE_STATE, encoding="utf-8") as f:
                json.load(f)
        except RecursionError:
            fixture_recurses = True
        await g._serve_acct_usage_now(None)
        return fixture_recurses, sent
    finally:
        g._run_probe_result = saved_probe
        g._send_json = saved_send


deep_fixture_recurses, deep_corrupt_sent = asyncio.run(_deep_corrupt_live_case())
check("P1 deep-corrupt fixture reaches the RecursionError path", deep_fixture_recurses)
check("P1 deeply nested corrupt store cannot suppress the live response",
      deep_corrupt_sent == [(b"200 OK", _claude_result())]
      and g._claude_usage_state_load()["claude@example.com|personal"]
          ["usage"]["use5h"] == 71)

# A stale/identity-less probe is not a usable observation and must not touch the file.
_set_local(time.time() - 5)
with open(g.CLAUDE_USAGE_STATE, "rb") as f:
    before_stale = f.read()
stale_saved = g._claude_usage_state_save({"state": "stale", "usage": {"use5h": 99}})
with open(g.CLAUDE_USAGE_STATE, "rb") as f:
    after_stale = f.read()
check("P1 stale probe without identity writes nothing and does not raise",
      stale_saved is False and before_stale == after_stale)

# A write failure is diagnostic once, but the HTTP reading still succeeds every time.
async def _claude_unwritable_case():
    saved_dir = g.CLAUDE_USAGE_STATE_DIR
    saved_path = g.CLAUDE_USAGE_STATE
    saved_probe = g._run_probe_result
    saved_send = g._send_json
    sent = []
    try:
        g.CLAUDE_USAGE_STATE_DIR = "/proc/airlock-devterm-unwritable"
        g.CLAUDE_USAGE_STATE = g.CLAUDE_USAGE_STATE_DIR + "/claude-usage.json"
        g._claude_usage_write_logged = False

        async def probe(_args):
            return b"200 OK", _claude_result()

        async def send_json(_cw, status, payload, **_kwargs):
            sent.append((status, payload))

        g._run_probe_result = probe
        g._send_json = send_json
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            await g._serve_acct_usage_now(None)
            await g._serve_acct_usage_now(None)
        return sent, stderr.getvalue()
    finally:
        g.CLAUDE_USAGE_STATE_DIR = saved_dir
        g.CLAUDE_USAGE_STATE = saved_path
        g._run_probe_result = saved_probe
        g._send_json = saved_send


unwritable_sent, unwritable_log = asyncio.run(_claude_unwritable_case())
check("P1 unwritable store does not fail the live requests",
      len(unwritable_sent) == 2
      and all(status == b"200 OK" and payload == _claude_result()
              for status, payload in unwritable_sent))
check("P1 unwritable store logs once per process",
      unwritable_log.count("Claude usage state write failed") == 1)

# Account churn cannot grow the file forever: old entries disappear on the next write.
_prune_now = time.time()
_write_claude_store({"version": 1, "accounts": {
    "old@example.com|personal": dict(_valid_entry,
        valueAt=_prune_now - g.CLAUDE_USAGE_MAX_AGE - 1),
    "keep@example.com|team": dict(_valid_entry, valueAt=_prune_now - 30),
}})
g._claude_usage_state_save(_claude_result(email="new@example.com"))
with open(g.CLAUDE_USAGE_STATE, encoding="utf-8") as f:
    pruned_keys = set(json.load(f)["accounts"])
check("P1 writer prunes entries older than 30 days",
      pruned_keys == {"keep@example.com|team", "new@example.com|personal"})

# The serialization guarantee is structural: load/merge/prune/replace stay in one plain
# synchronous call, and the request handler invokes it inline on the gate loop.
writer_source = inspect.getsource(g._claude_usage_state_save)
handler_source = inspect.getsource(g._serve_acct_usage_now)
list_source = inspect.getsource(g._acct_list_with_usage)
check("P1 store writer is synchronous and owns the full update sequence",
      not inspect.iscoroutinefunction(g._claude_usage_state_save)
      and "with open(CLAUDE_USAGE_STATE" in writer_source
      and "cutoff =" in writer_source and "os.replace(" in writer_source
      and "await " not in writer_source)
check("P1 live handler writes inline, unlike the fleet-store reader",
      "_claude_usage_state_save(payload)" in handler_source
      and "run_in_executor" not in handler_source
      and "run_in_executor" in list_source)

# Most importantly, the local display store must never become an /acct-alert input. Use
# the real list function here (not alert_with's stub), preload an alarming local 99%, and
# prove the alert still calls its fresh live fallback and preserves rtDays fallback.
async def _real_list_alert_case():
    saved_create = g.asyncio.create_subprocess_exec
    saved_fetch = g._fetch_fleet_store
    saved_live_fn = g._live_usage_cached
    saved_codex = g._codex_usage_cached
    saved_send = g._send_json
    saved_alert = dict(g._acct_alert_cache)
    live_calls = 0
    sent = {}

    class FakeProc:
        returncode = 0

        async def communicate(self):
            payload = {"active": "slot-a", "accounts": [{
                "name": "slot-a", "active": True, "email": "claude@example.com",
                "kind": "personal", "sub": "Claude", "rtExpiry": None,
            }]}
            return json.dumps(payload).encode(), b""

        def kill(self):
            self.returncode = -9

        async def wait(self):
            return self.returncode

    try:
        async def create_proc(*_args, **_kwargs):
            return FakeProc()

        async def live_usage():
            nonlocal live_calls
            live_calls += 1
            return {"use5h": 1, "use7d": 1, "rtDaysLeft": 1}

        async def codex_usage(*_args, **_kwargs):
            return {}

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g.asyncio.create_subprocess_exec = create_proc
        g._fetch_fleet_store = lambda: {}
        g._live_usage_cached = live_usage
        g._codex_usage_cached = codex_usage
        g._send_json = send_json
        g._acct_alert_cache.update(at=0.0, payload=None)
        await g._serve_acct_alert({}, None)
        return live_calls, sent
    finally:
        g.asyncio.create_subprocess_exec = saved_create
        g._fetch_fleet_store = saved_fetch
        g._live_usage_cached = saved_live_fn
        g._codex_usage_cached = saved_codex
        g._send_json = saved_send
        g._acct_alert_cache.update(saved_alert)


_set_local(time.time(), use5h=99)
real_live_calls, real_alert = asyncio.run(_real_list_alert_case())
check("P1 real account list keeps /acct-alert on its live fallback",
      real_live_calls == 1 and real_alert["payload"]["use5h"] == 1
      and real_alert["payload"]["level"] == "warn")
check("P1 rtDays fallback still grades the live login horizon",
      real_alert["payload"]["reason"] == "login")

g.CLAUDE_USAGE_STATE_DIR = _real_claude_state_dir
g.CLAUDE_USAGE_STATE = _real_claude_state
shutil.rmtree(_claude_state_tmp, ignore_errors=True)

# --- codex binary discovery (the whole Codex line went dark on version-manager boxes) --
# _codex_bin() was `which("codex") or ~/.npm-global/bin/codex`. A systemd --user unit
# and a remote `su - <user> -c` both get a PATH with none of the directories a node CLI
# installs into, so `which` came back empty on a box where codex ran fine from a shell;
# the hardcoded fallback then put one innocent path into the error message. Everything
# below runs with an EMPTY PATH, because that is the shape of the environment the gate
# is actually started in. The candidate list itself is pinned by the shared corpus
# (backend/test_bin_discovery.py); these checks pin the two call sites onto it.
def _mkbin(path, mode=0o755):
    """Create an executable at `path`, pinning every directory made to 0755. Without
    that, a permissive umask makes the FIXTURE world-writable and bin_discovery's trust
    rules reject it — a red test for a reason that has nothing to do with discovery."""
    parts = os.path.dirname(path)
    os.makedirs(parts, exist_ok=True)
    while len(parts) > len(_disc_home):
        os.chmod(parts, 0o755)
        parts = os.path.dirname(parts)
    with open(path, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(path, mode)


_disc_home = tempfile.mkdtemp(prefix="devterm-bindisc-")
os.chmod(_disc_home, 0o755)
_disc_saved = dict(os.environ)
try:
    os.environ.update(HOME=_disc_home, PATH="")
    os.environ.pop("CODEX_BIN", None)
    os.environ.pop("CODEX_EXTRA_BIN_DIRS", None)
    check("no codex anywhere -> None, never a path that was not verified",
          g._codex_bin() is None)
    check("...so the feature reports itself unavailable", g._codex_available() is False)
    _msg = g._codex_missing_error()
    check("the refusal names the command", "codex" in _msg)
    check("the refusal says where it looked", "searched" in _msg and "PATH(" in _msg)
    # The old text was the bare string "codex not available", which sent every
    # investigation to the box. A path may still appear now, but only in the rejected
    # list with the reason attached — never as a verdict about where codex should be.
    check("the refusal replaces the opaque wording",
          "not available" not in _msg and "not found" in _msg)
    check("the refusal says what to do next", "fix:" in _msg)
    # The outage shape: installed, working, and invisible to `which`.
    _fnm = os.path.join(_disc_home, ".local/share/fnm/aliases/default/bin/codex")
    _mkbin(_fnm)
    check("codex under a node version manager is found with an empty PATH",
          g._codex_bin() == _fnm)
    check("...and what is returned is really executable", os.access(g._codex_bin(), os.X_OK))
    check("...so the endpoints stop refusing", g._codex_available() is True)
    check("claude-status resolves the same binary as the gate (one contract, one module)",
          cs._codex_bin() == _fnm)
finally:
    os.environ.clear(); os.environ.update(_disc_saved)
    shutil.rmtree(_disc_home, ignore_errors=True)

# /acct-alert falls back to the live probe when the shared store has nothing,
# and never invents a level out of nothing.
async def alert_with(list_payload, live_payload, codex_payload):
    g._acct_alert_cache.update(at=0.0, payload=None)
    g._live_usage_cache.update(at=0.0, payload=None)
    g._acct_list_with_usage = lambda: asyncio.sleep(0, result=list_payload)
    g._live_usage_cached = lambda: asyncio.sleep(0, result=live_payload)
    g._codex_usage_cached = lambda *a, **k: asyncio.sleep(0, result=codex_payload)
    sent = {}
    async def fake_send(cw, status, payload, cors=None):
        sent.update(status=status, payload=payload, cors=cors)
    g._send_json = fake_send
    await g._serve_acct_alert({}, None)
    return sent["payload"]

store_empty = {"accounts": [{"active": True, "usage": {"err": "no data"}, "rtExpiry": None}]}
p = asyncio.run(alert_with(store_empty, {"use5h": 90, "use7d": 10}, {}))
check("falls back to live probe", (p["level"], p["use5h"]) == ("crit", 90))
p = asyncio.run(alert_with(store_empty, {}, {}))
check("no source anywhere -> none, no invented numbers",
      (p["level"], p["reason"], p["use5h"], p["use7d"]) == ("none", None, None, None))
p = asyncio.run(alert_with(
    {"accounts": [{"active": True, "usage": {"use5h": 5, "use7d": 5}, "rtExpiry": None}]},
    {"use5h": 99, "use7d": 99}, {}))
check("shared store wins over the probe", (p["use5h"], p["level"]) == (5, "none"))
p = asyncio.run(alert_with(store_empty, {}, {"use7d": 95}))
check("codex alone can raise the level", (p["level"], p["reason"]) == ("crit", "codex"))
p = asyncio.run(alert_with(store_empty, {}, {"use7d": 5, "stale": True, "lastErr": "auth"}))
check("a revoked codex login reaches the alert, numbers or not",
      (p["level"], p["reason"], p["codexErr"]) == ("crit", "codex-login", "auth"))
check("thresholds are shipped with the verdict", p["thresholds"] == TH)
check("no identity in the payload",
      not any(k in p for k in ("email", "accounts", "token", "accessToken")))
p = asyncio.run(alert_with("not-a-dict", {}, {}))
check("broken account data degrades to none + typed err",
      p["level"] == "none" and str(p["err"]).startswith("accounts-"))

print(("\nFAILED: " + ", ".join(fails)) if fails else "\nall contract checks passed")
sys.exit(1 if fails else 0)
