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
import asyncio, contextlib, copy, importlib.machinery, importlib.util, inspect, io, json, os, shutil, stat, subprocess, sys, tempfile, time, types, urllib.error
os.environ.setdefault("AIRLOCK_OWNER", "owner@example.com")
spec = importlib.util.spec_from_file_location("gate", "apps/devterm/backend/devterm-gate.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
# airlock-accounts-status has no .py extension, so it needs an explicit source loader.
# Importing it runs no side effects — main() is behind __main__.
cs_loader = importlib.machinery.SourceFileLoader("claude_status", "bin/airlock-accounts-status")
cs_spec = importlib.util.spec_from_loader("claude_status", cs_loader)
cs = importlib.util.module_from_spec(cs_spec); cs_loader.exec_module(cs)
# The platform account writer is extensionless for the same reason.
ac_loader = importlib.machinery.SourceFileLoader("airlock_accounts", "bin/airlock-accounts")
ac_spec = importlib.util.spec_from_loader("airlock_accounts", ac_loader)
ac = importlib.util.module_from_spec(ac_spec); ac_loader.exec_module(ac)

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

# P2b: Codex preservation is platform-owned and its machine output is boolean-only.
_codex_auth_tmp = tempfile.mkdtemp(prefix="platform-codex-auth-")
_saved_ac_paths = ac.CODEX_AUTH, ac.CODEX_AUTH_BAK
try:
    ac.CODEX_AUTH = os.path.join(_codex_auth_tmp, "auth.json")
    ac.CODEX_AUTH_BAK = ac.CODEX_AUTH + ".pre-relogin"
    marker = b'{"fixture":"previous-login-no-secret"}\n'
    with open(ac.CODEX_AUTH, "wb") as f:
        f.write(marker)
    backup_out = io.StringIO()
    with contextlib.redirect_stdout(backup_out):
        backup_rc = ac.cmd_codex_auth("backup", as_json=True)
    with open(ac.CODEX_AUTH, "wb") as f:
        f.write(b'{"fixture":"replacement"}\n')
    restore_out = io.StringIO()
    with contextlib.redirect_stdout(restore_out):
        restore_rc = ac.cmd_codex_auth("restore", as_json=True)
    with open(ac.CODEX_AUTH, "rb") as f:
        restored_bytes = f.read()
    backup_json, restore_json = json.loads(backup_out.getvalue()), json.loads(restore_out.getvalue())
    check("platform Codex backup reports booleans only",
          backup_rc == 0 and backup_json == {"ok": True, "backedUp": True}
          and "previous-login" not in backup_out.getvalue())
    check("platform Codex restore puts the exact previous file back",
          restore_rc == 0 and restore_json == {"ok": True, "restored": True}
          and restored_bytes == marker and not os.path.exists(ac.CODEX_AUTH_BAK))
    os.unlink(ac.CODEX_AUTH)
    missing_out = io.StringIO()
    with contextlib.redirect_stdout(missing_out):
        missing_rc = ac.cmd_codex_auth("backup", as_json=True)
    check("platform Codex backup reports an absent login without inventing one",
          missing_rc == 0
          and json.loads(missing_out.getvalue()) == {"ok": True, "backedUp": False})
    with open(ac.CODEX_AUTH, "wb") as f:
        f.write(marker)
    generation_out = io.StringIO()
    with contextlib.redirect_stdout(generation_out):
        generation_rc = ac.cmd_codex_auth("generation", as_json=True)
    generation_json = json.loads(generation_out.getvalue())
    check("platform Codex generation returns metadata only",
          generation_rc == 0 and generation_json.get("ok") is True
          and generation_json.get("present") is True
          and type(generation_json.get("generation")) is int
          and set(generation_json) == {"ok", "present", "generation"})
finally:
    ac.CODEX_AUTH, ac.CODEX_AUTH_BAK = _saved_ac_paths
    shutil.rmtree(_codex_auth_tmp, ignore_errors=True)

# Codex itself honors CODEX_HOME, so the platform lifecycle must follow the same
# environment or it can preserve the wrong login while device-auth erases the real one.
_codex_override_tmp = tempfile.mkdtemp(prefix="platform-codex-home-")
try:
    override_auth = os.path.join(_codex_override_tmp, "auth.json")
    override_marker = b'{"fixture":"override-login"}\n'
    with open(override_auth, "wb") as f:
        f.write(override_marker)
    override_env = dict(os.environ, HOME=_codex_override_tmp,
                        CODEX_HOME=_codex_override_tmp)
    platform_script = os.path.abspath("bin/airlock-accounts")
    backup = subprocess.run(
        [sys.executable, platform_script, "codex-auth", "backup", "--json"],
        env=override_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    with open(override_auth, "wb") as f:
        f.write(b'{"fixture":"replacement"}\n')
    restore = subprocess.run(
        [sys.executable, platform_script, "codex-auth", "restore", "--json"],
        env=override_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    with open(override_auth, "rb") as f:
        override_restored = f.read()
    check("platform Codex lifecycle follows CODEX_HOME",
          backup.returncode == 0 and restore.returncode == 0
          and override_restored == override_marker
          and override_marker not in backup.stdout + restore.stdout)
finally:
    shutil.rmtree(_codex_override_tmp, ignore_errors=True)


# ACCT_OWN: the device-auth driver itself is platform-owned now. The ordering rule the
# gate used to carry — back the old login up BEFORE codex is allowed to erase it — is
# asserted here, against the platform CLI, with a real spawn: a recorded call order can
# stay green while the two steps race, and this cannot.
_relogin_tmp = tempfile.mkdtemp(prefix="platform-codex-relogin-")
_saved_relogin = (ac.CODEX_AUTH, ac.CODEX_AUTH_BAK, ac.CODEX_LOGIN_OUT,
                  ac.CODEX_CAPTURE_INTERVAL, ac._codex_bin, ac.shutil.copy2)
try:
    ac.CODEX_AUTH = os.path.join(_relogin_tmp, "auth.json")
    ac.CODEX_AUTH_BAK = ac.CODEX_AUTH + ".pre-relogin"
    ac.CODEX_LOGIN_OUT = os.path.join(_relogin_tmp, "capture.out")
    ac.CODEX_CAPTURE_INTERVAL = 0.02
    _fake_codex = os.path.join(_relogin_tmp, "codex")
    # The fake reports what it can SEE at the moment it runs. If the backup had not
    # happened yet, it says so in the capture and the assertion below fails.
    with open(_fake_codex, "w") as f:
        f.write("#!/bin/sh\n"
                'test -f "$BAK" && echo BACKUP_PRESENT || echo BACKUP_MISSING\n'
                'touch "$SPAWNED"\n'
                "printf 'open \\033[1mhttps://auth.openai.com/codex/device?f=1\\033[0m\\n'\n"
                "printf 'code: WXYZ-98765\\n'\n")
    os.chmod(_fake_codex, 0o755)
    _spawn_marker = os.path.join(_relogin_tmp, "spawned")
    os.environ["BAK"], os.environ["SPAWNED"] = ac.CODEX_AUTH_BAK, _spawn_marker
    ac._codex_bin = lambda: _fake_codex
    _relogin_marker = b'{"fixture":"previous-login-no-secret"}\n'
    with open(ac.CODEX_AUTH, "wb") as f:
        f.write(_relogin_marker)
    _start = ac._codex_login_start()
    _capture = open(ac.CODEX_LOGIN_OUT, encoding="utf-8", errors="replace").read()
    check("platform device-auth captures the pairing URL and code",
          _start.get("ok") is True and _start.get("code") == "WXYZ-98765"
          and _start.get("url") == "https://auth.openai.com/codex/device?f=1")
    check("platform device-auth backs the old login up before codex can erase it",
          "BACKUP_PRESENT" in _capture and "BACKUP_MISSING" not in _capture)
    # Cancel must recover the exact previous bytes, and must not need the executable:
    # codex can be uninstalled between starting a login and abandoning it.
    with open(ac.CODEX_AUTH, "wb") as f:
        f.write(b'{"fixture":"replacement"}\n')
    ac._codex_bin = lambda: None
    _cancel = ac._codex_login_cancel()
    with open(ac.CODEX_AUTH, "rb") as f:
        _cancelled_bytes = f.read()
    check("platform cancel restores the previous login without the executable",
          _cancel == {"ok": True, "restored": True} and _cancelled_bytes == _relogin_marker)

    # Fail closed: a backup that cannot be written must stop the flow before codex runs,
    # because codex wipes auth.json first and there would be nothing to come back to.
    os.unlink(_spawn_marker)
    ac._codex_bin = lambda: _fake_codex
    def _refuse_copy(*_a, **_k):
        raise OSError(13, "Permission denied")
    ac.shutil.copy2 = _refuse_copy
    _failed_start = ac._codex_login_start()
    check("platform device-auth fails closed before spawn when the backup fails",
          _failed_start.get("ok") is False and not os.path.exists(_spawn_marker)
          and "Permission denied" in _failed_start.get("error", ""))
finally:
    (ac.CODEX_AUTH, ac.CODEX_AUTH_BAK, ac.CODEX_LOGIN_OUT,
     ac.CODEX_CAPTURE_INTERVAL, ac._codex_bin, ac.shutil.copy2) = _saved_relogin
    os.environ.pop("BAK", None); os.environ.pop("SPAWNED", None)
    shutil.rmtree(_relogin_tmp, ignore_errors=True)

# No codex on the box is a readable answer, not a crash — and `--json` still exits 0 so a
# caller can tell "the operation could not run" from "the tool itself broke".
_saved_missing_bin = ac._codex_bin
try:
    ac._codex_bin = lambda: None
    _missing_out = io.StringIO()
    with contextlib.redirect_stdout(_missing_out):
        _missing_rc = ac.cmd_codex_auth("logout", as_json=True)
    _missing_json = json.loads(_missing_out.getvalue())
    check("a missing codex is a reason, not a non-zero exit",
          _missing_rc == 0 and _missing_json.get("ok") is False
          and "codex not found" in _missing_json.get("error", ""))
finally:
    ac._codex_bin = _saved_missing_bin


async def _codex_relogin_handler_contract():
    """devterm is the CALLER now: every Codex credential verb goes to the platform
    tool, and codex itself is never spawned from this process."""
    saved = (g._codex_auth_call, g._send_json, g._invalidate_codex_usage_cache,
             g.asyncio.create_subprocess_exec)
    events, sent = [], []

    async def call(action, _timeout):
        events.append(action)
        if action == "login-start":
            return {"ok": True, "url": "https://auth.openai.com/codex/device",
                    "code": "ABCD-1234"}, None
        return {"ok": True, "restored": True}, None

    async def send(_cw, status, payload, **_kwargs):
        sent.append((status, payload))

    async def spawn(*args, **_kwargs):
        raise AssertionError("devterm must not spawn codex itself: " + repr(args))

    try:
        g._codex_auth_call = call
        g._send_json = send
        g._invalidate_codex_usage_cache = lambda: events.append("invalidate")
        g.asyncio.create_subprocess_exec = spawn
        await g._serve_codex_login_start(None)
        start = (list(events), list(sent))
        events.clear(); sent.clear()
        await g._serve_codex_login_cancel(None)
        cancel = (list(events), list(sent))
        events.clear(); sent.clear()
        await g._serve_codex_logout(None)
        return start, cancel, (list(events), list(sent))
    finally:
        (g._codex_auth_call, g._send_json, g._invalidate_codex_usage_cache,
         g.asyncio.create_subprocess_exec) = saved


_relogin_start, _relogin_cancel, _relogin_logout = asyncio.run(_codex_relogin_handler_contract())
check("Codex re-login start delegates to the platform and returns only URL + code",
      _relogin_start[0] == ["invalidate", "login-start"]
      and _relogin_start[1] == [(b"200 OK", {"ok": True, "code": "ABCD-1234",
                                             "url": "https://auth.openai.com/codex/device"})])
check("Codex cancel delegates to the platform and invalidates the old usage cache",
      _relogin_cancel[0] == ["login-cancel", "invalidate"]
      and _relogin_cancel[1] == [(b"200 OK", {"ok": True, "restored": True})])
check("Codex logout delegates to the platform and invalidates the old usage cache",
      _relogin_logout[0] == ["logout", "invalidate"]
      and _relogin_logout[1] == [(b"200 OK", {"ok": True})])


async def _codex_platform_failure_contract():
    """A platform-side failure reaches the panel as its own message, not as a blank
    400 and not as codex's raw output."""
    saved = (g._codex_auth_call, g._send_json, g._invalidate_codex_usage_cache)
    sent = []

    async def call(_action, _timeout):
        return None, "codex not found (not installed, or installed outside ...)"

    async def send(_cw, status, payload, **_kwargs):
        sent.append((status, payload))

    try:
        g._codex_auth_call = call
        g._send_json = send
        g._invalidate_codex_usage_cache = lambda: None
        await g._serve_codex_login_start(None)
        await g._serve_codex_logout(None)
        return list(sent)
    finally:
        (g._codex_auth_call, g._send_json, g._invalidate_codex_usage_cache) = saved


_platform_failures = asyncio.run(_codex_platform_failure_contract())
check("a platform Codex failure is reported with its own reason",
      _platform_failures == [
          (b"400 Bad Request", {"ok": False,
                                "error": "codex not found (not installed, or installed outside ...)"}),
          (b"400 Bad Request", {"ok": False,
                                "error": "codex not found (not installed, or installed outside ...)"})])

# End to end across the ownership boundary, with no fakes between the two halves:
# devterm's endpoint spawns the REAL bin/airlock-accounts, which spawns a fake codex,
# and the pairing code comes back out of the HTTP payload. The unit tests above pin the
# two sides separately; only this one fails if the ABI between them drifts — a renamed
# verb, a changed JSON key, a --json exit status that stops meaning "the tool ran".
async def _codex_relogin_end_to_end():
    tmp = tempfile.mkdtemp(prefix="codex-relogin-e2e-")
    saved_env = dict(os.environ)
    saved = (g.PLATFORM_ACCOUNTS, g._send_json, g._invalidate_codex_usage_cache)
    sent = []

    async def send(_cw, status, payload, **_kwargs):
        sent.append((status, payload))

    try:
        os.makedirs(os.path.join(tmp, "bin"))
        os.makedirs(os.path.join(tmp, "codex"))
        fake = os.path.join(tmp, "bin", "codex")
        with open(fake, "w") as f:
            # Real codex removes the live login the moment device-auth starts, before
            # the user has approved a replacement. The fixture has to do that too, or
            # the recovery assertion below would pass without recovering anything.
            f.write("#!/bin/sh\n"
                    'rm -f "$CODEX_HOME/auth.json"\n'
                    "printf 'Sign in: https://auth.openai.com/codex/device?e=1\\n'\n"
                    "printf 'Code: QRST-5678\\n'\n"
                    "exec sleep 30\n")
        os.chmod(fake, 0o755)
        auth = os.path.join(tmp, "codex", "auth.json")
        marker = b'{"fixture":"e2e-previous-login"}\n'
        with open(auth, "wb") as f:
            f.write(marker)
        os.environ.update(HOME=os.path.join(tmp, "home"),
                          CODEX_HOME=os.path.join(tmp, "codex"),
                          PATH=os.path.join(tmp, "bin") + ":/usr/bin:/bin")
        g.PLATFORM_ACCOUNTS = os.path.abspath("bin/airlock-accounts")
        g._send_json = send
        g._invalidate_codex_usage_cache = lambda: None
        await g._serve_codex_login_start(None)
        started = os.path.exists(auth)
        await g._serve_codex_login_cancel(None)
        with open(auth, "rb") as f:
            recovered = f.read()
        return list(sent), started, recovered == marker
    finally:
        (g.PLATFORM_ACCOUNTS, g._send_json, g._invalidate_codex_usage_cache) = saved
        os.environ.clear(); os.environ.update(saved_env)
        subprocess.run(["pkill", "-f", os.path.join(tmp, "bin", "codex")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        shutil.rmtree(tmp, ignore_errors=True)


_e2e_sent, _e2e_wiped, _e2e_recovered = asyncio.run(_codex_relogin_end_to_end())
check("start -> cancel completes through the platform path and hands back the code",
      len(_e2e_sent) == 2
      and _e2e_sent[0] == (b"200 OK", {"ok": True, "code": "QRST-5678",
                                       "url": "https://auth.openai.com/codex/device?e=1"})
      and _e2e_sent[1] == (b"200 OK", {"ok": True, "restored": True}))
# The reason the backup exists at all: codex removes the live login as it starts, and
# cancel is the only thing that puts it back. If the fixture ever stopped wiping it,
# the recovery assertion below would pass without recovering anything.
check("the fixture really did leave the box logged out mid-flow", not _e2e_wiped)
check("cancel puts the exact previous login back", _e2e_recovered)

# A rendered/manual unit may carry the feature flag but omit the platform path. After
# the ownership move there is deliberately no app sibling or PATH fallback: starting
# an enabled feature with no ABI bridge must fail loudly instead of running stale code.
_saved_status_env = os.environ.pop("DEVTERM_CLAUDE_STATUS", None)
try:
    try:
        g._account_tool("DEVTERM_CLAUDE_STATUS")
        missing_status_error = ""
    except RuntimeError as exc:
        missing_status_error = str(exc)
finally:
    if _saved_status_env is not None:
        os.environ["DEVTERM_CLAUDE_STATUS"] = _saved_status_env
check("enabled account feature without a status env fails loudly",
      "DEVTERM_CLAUDE_STATUS is required" in missing_status_error)

# Platform wiring is required only for enabled account features, not a reason to turn
# those features on. Import a fresh gate with both flags disabled and no explicit tool
# paths so this cannot be masked by the globals used by the route tests below.
_disabled_env = dict(os.environ, DEVTERM_ACCOUNTS="false", DEVTERM_XAI="false",
                     PYTHONDONTWRITEBYTECODE="1")
_disabled_env.pop("DEVTERM_CLAUDE_SWITCH", None)
_disabled_env.pop("DEVTERM_CLAUDE_STATUS", None)
_disabled_probe = subprocess.run(
    [sys.executable, "-c", """
import importlib.util, json
spec = importlib.util.spec_from_file_location(
    'disabled_gate', 'apps/devterm/backend/devterm-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
print(json.dumps([gate.CLAUDE_SWITCH, gate.CLAUDE_STATUS]))
"""], env=_disabled_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, timeout=30)
check("disabled account features do not require platform tools",
      _disabled_probe.returncode == 0 and _disabled_probe.stdout.strip() == '["", ""]')


def _run_probe_script(source):
    saved_status = g.CLAUDE_STATUS
    tmp = tempfile.mkdtemp(prefix="devterm-probe-contract-")
    try:
        path = os.path.join(tmp, "probe.py")
        with open(path, "w", encoding="utf-8") as f:
            f.write(source)
        g.CLAUDE_STATUS = path
        return asyncio.run(g._run_probe_result())
    finally:
        g.CLAUDE_STATUS = saved_status
        shutil.rmtree(tmp, ignore_errors=True)


check("probe rejects a non-object JSON payload",
      _run_probe_script('print("[]")\n')[0] == b"500 Internal Server Error")
check("probe rejects a nonzero helper even when it prints JSON",
      _run_probe_script('print("{}")\nraise SystemExit(1)\n')[0]
      == b"500 Internal Server Error")
check("probe accepts an object from a successful helper",
      _run_probe_script('print("{}")\n') == (b"200 OK", {}))
_smoke_source = open("apps/devterm/smoke.sh", encoding="utf-8").read()
check("smoke allows the backend probe timeout and validates the full-status shape",
      "--max-time 30" in _smoke_source
      and 'isinstance(j.get("live"), dict)' in _smoke_source
      and 'isinstance(j.get("pool"), list)' in _smoke_source)

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
        # Reproduce a broken configured platform copy: the script exists and passes
        # the gate's os.path.isfile guard, but its required sibling module does not.
        # It exits before argument parsing with empty stdout, so the route must answer
        # 500 rather than pretending the feature is disabled.
        installed_home = os.path.join(_xai_tmp, "home")
        installed_status = os.path.join(installed_home, ".local", "bin", "claude-status")
        os.makedirs(os.path.dirname(installed_status), exist_ok=True)
        shutil.copy2("bin/airlock-accounts-status", installed_status)
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

async def _unavailable_generation_case():
    saved_cache = dict(g._codex_usage_cache)
    saved_auth_mtime = g._codex_auth_mtime
    try:
        g._codex_auth_mtime = lambda: g._CODEX_AUTH_GENERATION_UNAVAILABLE
        g._codex_usage_cache.update(
            valueAt=time.time(), lastTryAt=time.time(), authMtime="login-A",
            payload={"use5h": 1, "use7d": 2, "stale": False}, task=None)
        return await g._codex_usage_cached()
    finally:
        g._codex_usage_cache.clear(); g._codex_usage_cache.update(saved_cache)
        g._codex_auth_mtime = saved_auth_mtime

_unavailable_generation = asyncio.run(_unavailable_generation_case())
check("unavailable auth generation never serves or commits cached usage",
      _unavailable_generation.get("err") == "auth-generation-unavailable"
      and not g._codex_has_usage_value(_unavailable_generation))

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


# OAuth approval codes are one-time credentials. The browser sends one in an HTTP body;
# from that point to the platform CLI it must stay off argv and cross only protected stdin.
async def _login_code_transport_case():
    saved_create = g.asyncio.create_subprocess_exec
    captured = {}

    class Proc:
        returncode = 0

        async def communicate(self, input_bytes=None):
            captured["input"] = input_bytes
            return b"registered\n", b""

    async def create(*argv, **kwargs):
        captured["argv"] = list(argv)
        captured["stdin"] = kwargs.get("stdin")
        return Proc()

    try:
        g.asyncio.create_subprocess_exec = create
        try:
            result = await g._claude_switch(
                ["login-code"], stdin_bytes=b"oauth-transport-sentinel")
        except TypeError as exc:
            return {"error": str(exc)}
        captured["result"] = result
        return captured
    finally:
        g.asyncio.create_subprocess_exec = saved_create


login_transport = asyncio.run(_login_code_transport_case())
check("OAuth code crosses the subprocess boundary only through stdin",
      login_transport.get("argv") == [g.CLAUDE_SWITCH, "login-code"]
      and login_transport.get("stdin") is asyncio.subprocess.PIPE
      and login_transport.get("input") == b"oauth-transport-sentinel"
      and "oauth-transport-sentinel" not in " ".join(login_transport.get("argv", [])))


class _ProtectedLoginInput:
    def __init__(self, raw):
        self.buffer = io.BytesIO(raw)

    def isatty(self):
        return False


_saved_login_handler, _saved_login_stdin = ac.cmd_login_code, ac.sys.stdin
_login_dispatch = []
try:
    ac.cmd_login_code = lambda code: _login_dispatch.append(code)
    ac.sys.stdin = _ProtectedLoginInput(b"oauth-stdin-sentinel#state")
    safe_login_rc = ac.main(["login-code"])
    argv_err = io.StringIO()
    with contextlib.redirect_stderr(argv_err):
        argv_login_rcs = (
            ac.main(["login-code", "oauth-argv-sentinel"]),
            ac.main(["login-code", "oauth sentinel"]),
            ac.main(["login-code", "x" * (ac.LOGIN_CODE_MAX_BYTES + 1)]),
            ac.main(["login-code", "one", "two"]),
        )
    transport_out = io.StringIO()
    with contextlib.redirect_stdout(transport_out):
        transport_rc = ac.main(["login-code-transport"])
finally:
    ac.cmd_login_code, ac.sys.stdin = _saved_login_handler, _saved_login_stdin

check("platform login-code reads protected stdin with no secret argv",
      safe_login_rc == 0 and _login_dispatch[0] == "oauth-stdin-sentinel#state")
check("platform login-code rejects every argv form without dispatch",
      argv_login_rcs == (2, 2, 2, 2) and len(_login_dispatch) == 1
      and "protected stdin only" in argv_err.getvalue()
      and "oauth-argv-sentinel" not in argv_err.getvalue()
      and "oauth sentinel" not in argv_err.getvalue())
check("platform advertises the side-effect-free stdin transport capability",
      transport_rc == 0 and transport_out.getvalue().strip() == "stdin-v1")


# Materialize the committed DevTerm golden exactly as the installer does: substitute
# its ROOT placeholder and chmod the result. This is the real fleet path
# claude-switch -> platform CLI, not another hand-written wrapper fixture.
_shim_tmp = tempfile.mkdtemp(prefix="devterm-claude-switch-shim-")
try:
    _golden = open(
        "install/golden/render/devterm/accounts-on/shim-claude-switch",
        encoding="utf-8").read()
    _shim = os.path.join(_shim_tmp, "claude-switch")
    with open(_shim, "w", encoding="utf-8") as f:
        f.write(_golden.replace("ROOT", os.path.abspath(".")))
    os.chmod(_shim, 0o755)
    _shim_env = dict(os.environ, HOME=_shim_tmp, PYTHONDONTWRITEBYTECODE="1")
    _shim_cap = subprocess.run(
        [_shim, "login-code-transport"], env=_shim_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    _shim_stdin_code = "oauth-shim-stdin-sentinel#state"
    _shim_stdin = subprocess.run(
        [_shim, "login-code"], input=_shim_stdin_code, env=_shim_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    _shim_argv_code = "oauth-shim-argv-sentinel#state"
    _shim_legacy = subprocess.run(
        [_shim, "login-code", _shim_argv_code], input="", env=_shim_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)

    # The same committed shim with a capture callee proves the shell boundary itself
    # leaves the secret in stdin. The real-parser cases above prove the other half.
    _capture_root = os.path.join(_shim_tmp, "capture-root")
    os.makedirs(os.path.join(_capture_root, "bin"))
    _capture_callee = os.path.join(_capture_root, "bin", "airlock-accounts")
    with open(_capture_callee, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\nprintf '%s\\n' \"$#\" \"$1\"\nIFS= read -r code\nprintf '%s\\n' \"$code\"\n")
    os.chmod(_capture_callee, 0o755)
    _capture_shim = os.path.join(_shim_tmp, "claude-switch-capture")
    with open(_capture_shim, "w", encoding="utf-8") as f:
        f.write(_golden.replace("ROOT", _capture_root))
    os.chmod(_capture_shim, 0o755)
    _captured_shim = subprocess.run(
        [_capture_shim, "login-code"], input=_shim_stdin_code + "\n", env=_shim_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
finally:
    shutil.rmtree(_shim_tmp, ignore_errors=True)

check("rendered claude-switch shim preserves the stdin-v1 capability",
      _shim_cap.returncode == 0 and _shim_cap.stdout.strip() == "stdin-v1"
      and not _shim_cap.stderr)
check("rendered claude-switch shim carries stdin into the real platform parser",
      _shim_stdin.returncode == 1 and "no login is pending" in _shim_stdin.stderr
      and _shim_stdin_code not in _shim_stdin.stdout + _shim_stdin.stderr)
check("rendered claude-switch shim keeps the code out of the callee argv boundary",
      _captured_shim.returncode == 0
      and _captured_shim.stdout.splitlines() == ["1", "login-code", _shim_stdin_code])
check("rendered claude-switch shim rejects argv before login processing",
      _shim_legacy.returncode == 2 and "protected stdin only" in _shim_legacy.stderr
      and _shim_argv_code not in _shim_legacy.stdout + _shim_legacy.stderr)


# Claim the old PKCE flow before exchange. A new login-url arriving after that atomic
# rename must survive; the old flow must no longer be replayable from PENDING.
_claim_tmp = tempfile.mkdtemp(prefix="accounts-pkce-claim-")
_saved_pending, _saved_replace = ac.PENDING, ac.os.replace
try:
    ac.PENDING = os.path.join(_claim_tmp, ".login-pending.json")
    _old_flow = {"verifier": "old", "state": "old", "ts": time.time()}
    _new_flow = {"verifier": "new", "state": "new", "ts": time.time()}
    ac._save_atomic(ac.PENDING, _old_flow)

    def _replace_then_new(src, dst):
        _saved_replace(src, dst)
        ac.os.replace = _saved_replace
        try:
            ac._save_atomic(ac.PENDING, _new_flow)
        finally:
            ac.os.replace = _replace_then_new

    ac.os.replace = _replace_then_new
    _claimed_old = ac._claim_pending_login()
    ac.os.replace = _saved_replace
    _claimed_new = ac._claim_pending_login()
finally:
    ac.PENDING, ac.os.replace = _saved_pending, _saved_replace
    shutil.rmtree(_claim_tmp, ignore_errors=True)

check("PKCE pending flow is atomically claimed without deleting a newer flow",
      _claimed_old == _old_flow and _claimed_new == _new_flow)


# A token endpoint is outside this trust boundary. Even if it reflects the submitted
# code in an HTTP body or exception string, neither the CLI nor the browser response may
# carry that one-time credential back out.
_saved_login_exchange = ac._ensure_pool, ac._claim_pending_login, ac.urllib.request.urlopen
_exchange_code = "oauth-reflection-sentinel#state"
_exchange_errors = []
try:
    ac._ensure_pool = lambda: None
    ac._claim_pending_login = lambda: {
        "verifier": "verifier", "state": "state", "ts": time.time()}
    for exchange_error in (
        urllib.error.HTTPError("https://token.invalid", 400, "bad", {},
                               io.BytesIO(_exchange_code.encode("utf-8"))),
        RuntimeError("transport reflected " + _exchange_code),
    ):
        ac.urllib.request.urlopen = lambda *_args, _error=exchange_error, **_kwargs: (
            _ for _ in ()).throw(_error)
        exchange_stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(exchange_stderr):
                ac.cmd_login_code(_exchange_code)
        except SystemExit as exc:
            _exchange_errors.append((exc.code, exchange_stderr.getvalue()))
finally:
    ac._ensure_pool, ac._claim_pending_login, ac.urllib.request.urlopen = _saved_login_exchange

check("token exchange failures cannot reflect the OAuth code to CLI stderr",
      len(_exchange_errors) == 2
      and all(rc == 1 and _exchange_code not in stderr
              for rc, stderr in _exchange_errors))


async def _acct_login_reflection_case():
    saved_accounts_enabled = g._accounts_enabled
    saved_read_json = g._read_json_body
    saved_claude_switch = g._claude_switch
    saved_send_json = g._send_json
    sent = {}
    try:
        g._accounts_enabled = lambda: True

        async def read_json(_cr, _headers, _leftover, limit=None):
            return {"code": _exchange_code}

        async def login_code(_args, stdin_bytes=None):
            return True, "upstream reflected " + _exchange_code, ""

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g._read_json_body = read_json
        g._claude_switch = login_code
        g._send_json = send_json
        await g._serve_acct_login_code(
            None, {b"content-type": b"application/json"}, b"", None)
        return sent
    finally:
        g._accounts_enabled = saved_accounts_enabled
        g._read_json_body = saved_read_json
        g._claude_switch = saved_claude_switch
        g._send_json = saved_send_json


login_reflection = asyncio.run(_acct_login_reflection_case())
check("DevTerm never returns reflected OAuth code output to the browser",
      login_reflection.get("status") == b"200 OK"
      and _exchange_code not in json.dumps(login_reflection.get("payload", {})))


async def _acct_login_http_boundary_case(headers, code):
    saved_accounts_enabled = g._accounts_enabled
    saved_read_json = g._read_json_body
    saved_claude_switch = g._claude_switch
    saved_send_json = g._send_json
    sent, child = {}, []
    try:
        g._accounts_enabled = lambda: True

        async def read_json(_cr, _headers, _leftover, limit=None):
            sent["limit"] = limit
            return {"code": code}

        async def login_code(_args, stdin_bytes=None):
            child.append(stdin_bytes)
            return True, "ok", ""

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g._read_json_body = read_json
        g._claude_switch = login_code
        g._send_json = send_json
        await g._serve_acct_login_code(None, headers, b"", None)
        return sent, child
    finally:
        g._accounts_enabled = saved_accounts_enabled
        g._read_json_body = saved_read_json
        g._claude_switch = saved_claude_switch
        g._send_json = saved_send_json


_cross_origin, _cross_child = asyncio.run(_acct_login_http_boundary_case(
    {b"content-type": b"application/json", b"host": b"box.test",
     b"origin": b"https://evil.test"}, "safe-code"))
_wrong_type, _type_child = asyncio.run(_acct_login_http_boundary_case(
    {b"content-type": b"text/plain"}, "safe-code"))
_wide_code, _wide_child = asyncio.run(_acct_login_http_boundary_case(
    {b"content-type": b"application/json"}, "é" * 400))
check("DevTerm login-code refuses cross-origin and form-compatible writes before dispatch",
      _cross_origin.get("status") == b"403 Forbidden" and not _cross_child
      and _wrong_type.get("status") == b"415 Unsupported Media Type" and not _type_child)
check("DevTerm login-code applies a narrow body cap and a 400-byte UTF-8 code cap",
      _wide_code.get("limit") == g.LOGIN_CODE_BODY_MAX
      and _wide_code.get("status") == b"400 Bad Request" and not _wide_child)


async def _narrow_reader_cap_case():
    class Reader:
        called = False

        async def read(self, _size):
            self.called = True
            raise AssertionError("oversized credential body must be rejected before reading")

    reader = Reader()
    body = await g._read_json_body(
        reader, {b"content-length": str(g.LOGIN_CODE_BODY_MAX + 1).encode()}, b"",
        limit=g.LOGIN_CODE_BODY_MAX)
    return body, reader.called


_oversized_body, _oversized_read = asyncio.run(_narrow_reader_cap_case())
check("DevTerm login-code rejects an oversized Content-Length before buffering its body",
      _oversized_body is None and not _oversized_read)


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
    login_call = {}
    try:
        g._accounts_enabled = lambda: True

        async def read_json(_cr, _headers, _leftover, limit=None):
            return {"code": "one-time-code"}

        async def login_code(args, stdin_bytes=None):
            login_call.update(args=args, stdin_bytes=stdin_bytes)
            return True, "registered", ""

        async def send_json(_cw, status, payload, **_kwargs):
            sent.update(status=status, payload=payload)

        g._read_json_body = read_json
        g._claude_switch = login_code
        g._send_json = send_json
        g._acct_alert_cache.update(at=time.time(), payload={"level": "crit"})
        g._live_usage_cache.update(at=time.time(), payload={"use5h": 99})
        await g._serve_acct_login_code(
            None, {b"content-type": b"application/json"}, b"", None)
        return sent, (g._acct_alert_cache["at"], g._acct_alert_cache["payload"]), \
            (g._live_usage_cache["at"], g._live_usage_cache["payload"]), login_call
    finally:
        g._accounts_enabled = saved_accounts_enabled
        g._read_json_body = saved_read_json
        g._claude_switch = saved_claude_switch
        g._send_json = saved_send_json
        g._acct_alert_cache.update(saved_alert)
        g._live_usage_cache.update(saved_live)
        g._acct_cache_generation = saved_generation


login_sent, login_alert_cache, login_live_cache, login_call = asyncio.run(_acct_login_success_case())
check("successful account login invalidates derived caches",
      login_sent.get("payload", {}).get("ok") is True
      and login_alert_cache == (0.0, None)
      and login_live_cache == (0.0, None))
check("account login handler keeps the OAuth code out of subprocess argv",
      login_call == {"args": ["login-code"],
                     "stdin_bytes": b"one-time-code"})


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

        async def read_json(_cr, _headers, _leftover, limit=None):
            return {"code": "one-time-code"}

        async def login_code(_args, stdin_bytes=None):
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
        await g._serve_acct_login_code(
            None, {b"content-type": b"application/json"}, b"", None)
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
                "kind": "개인", "holders": ["box-a"],
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
      and route_reads[2][1]["accounts"][0]["usage"]["use5h"] == 71
      and route_reads[2][1]["accounts"][0]["kind"] == "personal")
check("P1 live reading is available with no fleet store",
      route_reads[3][1]["accounts"][0]["usage"]["use7d"] == 62)

loaded_after_route = g._claude_usage_state_load()
stored_mode = stat.S_IMODE(os.stat(g.CLAUDE_USAGE_STATE).st_mode)
check("P1 store survives a simulated restart and is mode 0600",
      loaded_after_route["claude@example.com|personal"]["usage"]["use5h"] == 71
      and stored_mode == 0o600)

# The legacy pool used localized kinds. A fresh probe always emits personal/team, so
# both aliases must converge on one stored identity or a close/reopen loses the value.
_legacy_alias_now = time.time()
_write_claude_store({"version": 1, "accounts": {
    "team@example.com|팀": {
        "usage": {"use5h": 31, "use7d": 41, "reset5h": None, "reset7d": None},
        "valueAt": _legacy_alias_now,
    },
    "team@example.com|team": {
        "usage": {"use5h": 51, "use7d": 61, "reset5h": None, "reset7d": None},
        "valueAt": _legacy_alias_now + 1,
    },
}})
legacy_team = asyncio.run(_serve_accounts_fixture({
    "name": "slot-team", "active": True, "email": "team@example.com",
    "kind": "팀", "usage": {"err": "no data"},
}))["payload"]["accounts"][0]
check("P1 legacy team kind reopens from the newest canonicalized saved value",
      legacy_team["kind"] == "team"
      and legacy_team["usage"]["use5h"] == 51
      and legacy_team["usage"]["stale"] is True)

_fleet_alias_store = {
    "same@example.com|개인": {"observedAt": _legacy_alias_now + 2,
                               "usage": {"use5h": 22}},
    "same@example.com|personal": {"observedAt": _legacy_alias_now + 1,
                                   "usage": {"use5h": 11}},
}
check("P1 newest fleet alias wins when legacy and canonical keys coexist",
      g._claude_store_entry(_fleet_alias_store, "same@example.com", "personal")
      ["usage"]["use5h"] == 22)

_fleet_alias_tie = {
    "same@example.com|개인": {"observedAt": _legacy_alias_now,
                               "holders": ["legacy-only"]},
    "same@example.com|personal": {"observedAt": _legacy_alias_now,
                                   "usage": {"use5h": 11}},
}
check("P1 canonical fleet alias wins a timestamp tie for every input spelling",
      g._claude_store_entry(_fleet_alias_tie, "same@example.com", "personal")
      ["usage"]["use5h"] == 11
      and g._claude_store_entry(_fleet_alias_tie, "same@example.com", "개인")
      ["usage"]["use5h"] == 11)

_local_alias_entry = {
    "usage": {"use5h": 11, "use7d": 21, "reset5h": None, "reset7d": None},
    "valueAt": _legacy_alias_now,
}
_local_legacy_entry = {
    "usage": {"use5h": 22, "use7d": 32, "reset5h": None, "reset7d": None},
    "valueAt": _legacy_alias_now,
}
_canonical_first = g._claude_usage_records({"version": 1, "accounts": {
    "same@example.com|personal": _local_alias_entry,
    "same@example.com|개인": _local_legacy_entry,
}}, _legacy_alias_now + 1)
_legacy_first = g._claude_usage_records({"version": 1, "accounts": {
    "same@example.com|개인": _local_legacy_entry,
    "same@example.com|personal": _local_alias_entry,
}}, _legacy_alias_now + 1)
check("P1 canonical local alias wins a valueAt tie regardless of JSON order",
      _canonical_first["same@example.com|personal"]["usage"]["use5h"] == 11
      and _legacy_first["same@example.com|personal"]["usage"]["use5h"] == 11)

_write_claude_store({"version": 1, "accounts": {
    "same@example.com|0": _local_alias_entry,
}})
_invalid_kind_rows = [asyncio.run(_serve_accounts_fixture({
    "name": "bad-kind", "active": True, "email": "same@example.com",
    "kind": bad_kind, "usage": {"err": "no data"},
}))["payload"]["accounts"][0] for bad_kind in (0, [], {})]
check("P1 non-string kinds neither crash the list nor collide with string store keys",
      all(row["kind"] == "" and row["usage"].get("err") == "no data"
          for row in _invalid_kind_rows))

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
                "kind": "개인", "sub": "Claude",
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
            "claude@example.com|개인": {
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
      and real_recency[0]["accounts"][0]["kind"] == "personal"
      and real_recency[1]["accounts"][0]["usage"]["use5h"] == 80)


async def _usage_source_case(fleet_store, fleet_store_url):
    """An account with no stored reading, with and without a store configured.

    "no data" says wait; "no store" says nothing is coming. A box whose fleet_store is
    unset can never fill a non-active row, and reporting the transient there is how a
    misprovisioned box looked identical to a correctly configured one.
    """
    saved_create = g.asyncio.create_subprocess_exec
    saved_fetch = g._fetch_fleet_store
    saved_store, saved_url = g.FLEET_STORE, g.FLEET_STORE_URL

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

        g.asyncio.create_subprocess_exec = create_proc
        g._fetch_fleet_store = lambda: {}
        g.FLEET_STORE, g.FLEET_STORE_URL = fleet_store, fleet_store_url
        data = await g._acct_list_with_usage()
        return data["accounts"][0]["usage"]
    finally:
        g.asyncio.create_subprocess_exec = saved_create
        g._fetch_fleet_store = saved_fetch
        g.FLEET_STORE, g.FLEET_STORE_URL = saved_store, saved_url


check("P1 no usage source configured is reported as 'no store', not as collecting",
      asyncio.run(_usage_source_case("", "")) == {"err": "no store"})
check("P1 a configured file store with no entry yet still reports 'no data'",
      asyncio.run(_usage_source_case("/tmp/does-not-matter", "")) == {"err": "no data"})
check("P1 a configured URL store alone is enough to mean 'no data'",
      asyncio.run(_usage_source_case("", "http://example.invalid/store")) == {"err": "no data"})

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


async def _alert_probe_persists_case():
    """The /acct-alert live fallback must persist what it already read.

    Opening the panel is not the only time this box learns the active account's usage:
    the return widget polls /acct-alert on its own. Throwing that reading away is why an
    account in daily use could still show "no data" — the legacy box kept it.
    """
    saved_probe = g._probe_json
    saved_cache = dict(g._live_usage_cache)
    try:
        async def probe(_args, **_kwargs):
            return _claude_result(use5h=44, use7d=33, email="alertpath@example.com")

        g._probe_json = probe
        g._live_usage_cache.update(at=0.0, payload=None)
        await g._live_usage_cached()
    finally:
        g._probe_json = saved_probe
        g._live_usage_cache.clear()
        g._live_usage_cache.update(saved_cache)
    with open(g.CLAUDE_USAGE_STATE, encoding="utf-8") as f:
        return json.load(f)["accounts"]


_write_claude_store({"version": 1, "accounts": {}})
alert_persisted = asyncio.run(_alert_probe_persists_case())
check("P1 the alert path's live probe is persisted, not discarded",
      alert_persisted.get("alertpath@example.com|personal", {}).get("usage", {}).get("use5h") == 44)
check("P1 ...and it is filed under the probe's own identity",
      set(alert_persisted) == {"alertpath@example.com|personal"})

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
    # The resolver moved with the driver (ACCT_OWN): the platform CLI is what has to
    # find codex now, and the gate no longer looks for it at all.
    check("no codex anywhere -> None, never a path that was not verified",
          ac._codex_bin() is None)
    check("...and the gate has stopped resolving codex itself",
          not hasattr(g, "_codex_bin"))
    _msg = ac._codex_missing_error()
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
          ac._codex_bin() == _fnm)
    check("...and what is returned is really executable", os.access(ac._codex_bin(), os.X_OK))
    check("platform status resolves the same binary as the account CLI (one module)",
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


# ---- the death verdict: recorded where it is observed, honoured where it is listed ----
# The bug these pin: `health` was computed from refreshTokenExpiresAt alone, so a lineage
# the server had already revoked listed as "ok" until that stored date passed. Measured
# on a migrated box: four accounts "ok", every switch to them HTTP 400 invalid_grant.
ah = importlib.import_module("account_health") if "account_health" in sys.modules else None
if ah is None:
    ah_loader = importlib.machinery.SourceFileLoader("account_health", "bin/account_health.py")
    ah_spec = importlib.util.spec_from_loader("account_health", ah_loader)
    ah = importlib.util.module_from_spec(ah_spec); ah_loader.exec_module(ah)

FUTURE_RT = int((time.time() + 20 * 86400) * 1000)


def _slot_creds(rt_expiry=FUTURE_RT, at_expiry=None, meta=None):
    at = at_expiry if at_expiry is not None else int((time.time() + 3600) * 1000)
    creds = {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt",
                               "expiresAt": at, "refreshTokenExpiresAt": rt_expiry,
                               "subscriptionType": "max"}}
    creds["_meta"] = dict(meta or {"email": "slot@example.com", "kind": "personal"})
    return creds


@contextlib.contextmanager
def _pool(slots):
    """A throwaway pool directory; _account_infos reads whatever is in it."""
    root = tempfile.mkdtemp()
    saved_pool, saved_active = ac.POOL, ac.ACTIVE
    try:
        ac.POOL = root
        ac.ACTIVE = os.path.join(root, ".active")
        for name, creds in slots.items():
            with open(os.path.join(root, name + ".json"), "w", encoding="utf-8") as f:
                json.dump(creds, f)
        yield root
    finally:
        ac.POOL, ac.ACTIVE = saved_pool, saved_active
        shutil.rmtree(root, ignore_errors=True)


def _health_of(creds, name="slot-a"):
    with _pool({name: creds}):
        return {i["name"]: i["health"] for i in ac._account_infos()}[name]


marked = _slot_creds()
marked["_meta"]["dead"] = ah.build_marker(marked)
check("a recorded server rejection lists as dead even with a future rtExpiry",
      _health_of(marked)["state"] == "dead"
      and "400" in _health_of(marked)["reason"])
check("no marker and a future rtExpiry still lists as ok",
      _health_of(_slot_creds())["state"] == "ok")
check("an expired rtExpiry still lists as dead without any marker",
      _health_of(_slot_creds(rt_expiry=1))["state"] == "dead")

# The discriminator: a lineage that rotated after the verdict is not the one that was
# rejected. Without this, one bad marker would outlive every later successful refresh.
rotated = _slot_creds()
rotated["_meta"]["dead"] = ah.build_marker(rotated)
rotated["claudeAiOauth"]["refreshTokenExpiresAt"] = FUTURE_RT + 86400000
check("a marker whose lineage has since rotated is ignored",
      _health_of(rotated)["state"] == "ok")
check("a malformed marker is ignored rather than believed",
      _health_of(_slot_creds(meta={"email": "e", "kind": "personal", "dead": "yes"}))["state"] == "ok")

# _account_infos must stay a pure reader: it runs where the pool is mounted read-only.
infos_source = inspect.getsource(ac._account_infos)
check("listing accounts never writes the pool",
      not any(w in infos_source for w in ("_save_atomic", "mark_dead", "open(", "os.remove")))

# A wrong marker must not be able to delete a credential. prune deletes; only arithmetic
# on a stored date may feed it, never a remote judgement.
prune_source = inspect.getsource(ac.cmd_prune)
check("prune deletes only expiry-dead slots, not server-verdict ones",
      'i["health"]["state"] == "dead"' in prune_source and 'not i["rtValid"]' in prune_source)

# save-back's unidentified branch writes live into a slot it could not confirm; carrying
# _meta across would transplant one account's death onto another's file.
saveback_source = inspect.getsource(ac._saveback)
check("unidentified save-back strips the death marker before writing",
      "clear_dead_marker" in saveback_source)

# The status probe already had the verdict in hand and returned a bare False, after which
# its caller announced the opposite ("may be transient") about a permanent rejection.
refresh_source = inspect.getsource(cs._refresh_pool)
describe_source = inspect.getsource(cs._describe)
check("the pool refresh reports auth separately from transient",
      'return False, ("auth" if e.code in (400, 401) else "transient")' in refresh_source
      and 'return False, "transient"' in refresh_source)
check("a rejected pool refresh is described as dead, not as maybe-transient",
      'if kind == "auth":' in describe_source
      and 'out.update(state="dead", reason=_DEAD_REASON)' in describe_source)
check("a successful refresh clears the marker before it persists the rotation",
      refresh_source.index("_clear_dead_marker") < refresh_source.index("os.replace"))

# The switch is the last cheap moment to refuse: installing a rejected lineage "succeeds"
# and then dies mid-session once the still-valid accessToken runs out.
switch_source = inspect.getsource(ac._switch_core)
check("a switch refuses an auth-rejected account even while its accessToken is valid",
      'elif kind == "auth":' in switch_source
      and switch_source.index('elif kind == "auth":') < switch_source.index("elif not _at_valid(o)"))
check("...and records the verdict so the list stops calling it healthy",
      "account_health.mark_dead(target, creds)" in switch_source)
check("a successful refresh during a switch clears any stale verdict",
      "account_health.clear_dead_marker(creds)" in switch_source)

# Round-trip through the real writer, on a real file.
with _pool({"slot-a": _slot_creds()}) as pool_root:
    slot_file = os.path.join(pool_root, "slot-a.json")
    ah.mark_dead(slot_file, _slot_creds())
    with open(slot_file, encoding="utf-8") as f:
        written = json.load(f)
    check("the writer persists a marker that survives a reload",
          ah.dead_marker(written) is not None
          and written["_meta"]["email"] == "slot@example.com")
    check("...at owner-only permissions",
          stat.S_IMODE(os.stat(slot_file).st_mode) == 0o600)
    first_since = ah.dead_marker(written)["since"]
    ah.mark_dead(slot_file, written)
    with open(slot_file, encoding="utf-8") as f:
        rewritten = json.load(f)
    check("re-recording the same verdict does not push 'since' forward",
          ah.dead_marker(rewritten)["since"] == first_since)
    ah.clear_dead_marker(written)
    check("clearing removes it without touching the rest of _meta",
          ah.dead_marker(written) is None and written["_meta"]["kind"] == "personal")

check("a re-login replaces _meta wholesale, so a marker cannot survive one",
      'creds["_meta"] = {"email": ident["email"]' in inspect.getsource(ac._store_account))

print(("\nFAILED: " + ", ".join(fails)) if fails else "\nall contract checks passed")
sys.exit(1 if fails else 0)
