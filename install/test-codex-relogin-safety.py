#!/usr/bin/env python3
"""SAFETY gate, Codex path: an abandoned re-login must never cost the old credential.

Contract (docs/tasks/active/20260922-subscription-accounts-SAFETY.task.md):
  - `codex login --device-auth` wipes auth.json the moment it starts, so the CLI must
    verify the backup landed BEFORE the new flow starts, and refuse to start when it
    did not.
  - When the attempt is abandoned (browser/popup closed, no explicit cancel), the
    server recovers the previous login on its own after a 15-minute TTL.
  - After recovery a real authenticated request succeeds, with zero human steps.

Offline and self-contained: an isolated HOME + CODEX_HOME, a fake `codex` binary
(found via the CODEX_BIN override, like every other non-interactive context), and a
fake clock. No network, no installer, no unit, nothing on the box is read or written.

Usage:
  install/test-codex-relogin-safety.py --fake-clock +16m --scenario abandoned [--emit-ac]
  install/test-codex-relogin-safety.py --scenario backup-fails [--emit-ac]

  --emit-ac prints one AC row per acceptance claim, in the board's acceptance
  format (AC-id | expected | observed | verdict | signal | evidence).
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ACCOUNTS = os.path.join(ROOT, "bin", "airlock-accounts")
STATUS = os.path.join(ROOT, "bin", "airlock-accounts-status")
API = os.path.join(ROOT, "bin", "airlock-accounts-api")

FAKE_CODEX = r"""#!/usr/bin/env python3
""" + '"""Fake codex for the relogin-safety gate. login --device-auth wipes auth.json ' + \
"""first (like the real one), prints the pairing URL + code, then waits to be killed.
app-server answers one account/rateLimits/read with a fixed reading.""" + '"""' + r"""
import json, os, sys, time

AUTH = os.path.join(os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex")), "auth.json")

def cmd_login():
    try:
        os.unlink(AUTH)  # the real device-auth wipes the login the moment it starts
    except OSError:
        pass
    print("To authenticate, open https://auth.openai.com/codex/device in your browser")
    print("and enter the code ABCD-1234")
    sys.stdout.flush()
    open(os.environ["FAKE_CODEX_INVOKED"], "w").write("login\n")
    time.sleep(300)

def cmd_app_server():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == 2:
            print(json.dumps({"id": 2, "result": {"rateLimits": {
                "limitId": "codex", "planType": "pro",
                "primary": {"windowDurationMins": 300, "usedPercent": 12,
                            "resetsAt": 1900000000},
                "secondary": {"windowDurationMins": 10080, "usedPercent": 34,
                              "resetsAt": 1900000000}}}}))
            sys.stdout.flush()
            return

if "--device-auth" in sys.argv:
    cmd_login()
elif len(sys.argv) > 1 and sys.argv[1] == "app-server":
    cmd_app_server()
elif len(sys.argv) > 1 and sys.argv[1] == "logout":
    try:
        os.unlink(AUTH)
    except OSError:
        pass
"""

FAKE_STATUS = """#!/usr/bin/env python3
import json, sys
print(json.dumps({"state": "ok", "mode": "chatgpt", "email": "codex@example.test",
                  "plan": "pro", "accountId": "acct-1"}))
"""

fails = 0


def ok(msg):
    print("ok: %s" % msg)


def bad(msg):
    global fails
    fails += 1
    print("FAIL: %s" % msg)


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def parse_clock(spec):
    """+16m -> seconds. The gate's TTL is judged instantly with this, not by waiting."""
    unit = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    if not spec.startswith("+") or spec[-1] not in unit:
        raise ValueError("fake clock must look like +16m (got %r)" % spec)
    return float(spec[1:-1]) * unit[spec[-1]]


def run(args, env, stdin_closed=True):
    return subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        stdin=subprocess.DEVNULL if stdin_closed else None, env=env, check=False)


def emit_ac_rows(rows):
    try:
        revision = subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=15, check=False).stdout.decode().strip() or "unknown"
    except Exception:
        revision = "unknown"
    for ac_id, expected, observed, passed in rows:
        print("%s | expected: %s | observed: %s | verdict: %s | signal: fixture+fake-clock | "
              "evidence: install/test-codex-relogin-safety.py@%s"
              % (ac_id, expected, observed, "PASS" if passed else "FAIL", revision))


def main(argv):
    fake_offset = 0.0
    scenario = None
    emit_ac = "--emit-ac" in argv
    rest = [a for a in argv if a != "--emit-ac"]
    ac = []  # (ac_id, expected, observed, passed)
    while rest:
        arg = rest.pop(0)
        if arg == "--fake-clock":
            fake_offset = parse_clock(rest.pop(0))
        elif arg == "--scenario":
            scenario = rest.pop(0)
        else:
            print("usage: %s [--fake-clock +16m] --scenario abandoned|backup-fails [--emit-ac]"
                  % os.path.basename(__file__), file=sys.stderr)
            return 2
    if scenario not in ("abandoned", "backup-fails"):
        print("usage: %s [--fake-clock +16m] --scenario abandoned|backup-fails [--emit-ac]"
              % os.path.basename(__file__), file=sys.stderr)
        return 2

    tmp = tempfile.mkdtemp(prefix="codex-relogin-safety-")
    home = os.path.join(tmp, "home")
    codex_home = os.path.join(home, ".codex")
    bindir = os.path.join(tmp, "bin")
    os.makedirs(codex_home)
    os.makedirs(bindir)
    with open(os.path.join(bindir, "codex"), "w") as f:
        f.write(FAKE_CODEX)
    os.chmod(os.path.join(bindir, "codex"), 0o755)
    with open(os.path.join(tmp, "fake-status"), "w") as f:
        f.write(FAKE_STATUS)
    os.chmod(os.path.join(tmp, "fake-status"), 0o755)

    env = dict(os.environ, HOME=home, CODEX_HOME=codex_home,
               CODEX_BIN=os.path.join(bindir, "codex"),
               FAKE_CODEX_INVOKED=os.path.join(tmp, "codex-invoked"))
    # The fake clock travels as an absolute epoch the product reads instead of
    # time.time() for the relogin TTL only. Real waiting is not an option: the
    # TTL is 15 minutes and the gate judges it instantly. It is applied from the
    # sweep on — the attempt itself starts on the real clock, like production.
    fake_now = time.time() + fake_offset if fake_offset else None

    import base64

    def _b64(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()
    # A well-formed but fixture-only JWT: the probe parses identity out of it, and
    # nothing here is a real credential (example.test, unsigned, local-only).
    fixture_jwt = "%s.%s.%s" % (
        _b64({"alg": "none"}),
        _b64({"email": "codex@example.test",
              "https://api.openai.com/auth": {
                  "chatgpt_plan_type": "pro", "chatgpt_account_id": "acct-1"}}),
        "fixture-signature")
    original = {"auth_mode": "chatgpt", "tokens": {"id_token": fixture_jwt}}
    auth_path = os.path.join(codex_home, "auth.json")
    with open(auth_path, "w") as f:
        json.dump(original, f)
    original_sha = sha(auth_path)

    if scenario == "backup-fails":
        # The backup target is unwritable, so preservation cannot succeed. The
        # start must be refused BEFORE the new flow runs: no invocation, no wipe.
        os.chmod(codex_home, 0o555)
        try:
            proc = run([ACCOUNTS, "codex-auth", "login-start", "--json"], env)
        finally:
            os.chmod(codex_home, 0o755)
        # --json always exits 0 (the exit status says the TOOL ran; `ok` says
        # whether the OPERATION succeeded), so read the payload, not the rc.
        try:
            refused = json.loads(proc.stdout.decode())
        except ValueError:
            refused = {}
        if refused.get("ok") is True:
            bad("backup-fails: login-start reported ok while the backup could "
                "not be written — the old login is now at risk")
            refused_ok = False
        else:
            ok("backup-fails: login-start refused when preservation failed")
            refused_ok = True
        if os.path.exists(env["FAKE_CODEX_INVOKED"]):
            bad("backup-fails: the codex flow was started even though the "
                "backup failed — verify-then-start is violated")
            never_started = False
        else:
            ok("backup-fails: the codex flow was never started")
            never_started = True
        if os.path.isfile(auth_path) and sha(auth_path) == original_sha:
            ok("backup-fails: auth.json is untouched")
            untouched = True
        else:
            bad("backup-fails: auth.json was touched by a refused start")
            untouched = False
        if emit_ac:
            emit_ac_rows([(
                "AC-SAFETY-C4", "start refused && flow never started && auth untouched",
                "refused=%s,never_started=%s,untouched=%s"
                % (refused_ok, never_started, untouched),
                refused_ok and never_started and untouched)])
        return 1 if fails else 0

    # ---- scenario abandoned ----
    proc = run([ACCOUNTS, "codex-auth", "login-start", "--json"], env)
    try:
        started = json.loads(proc.stdout.decode())
    except ValueError:
        started = {}
    if started.get("ok") is True and started.get("code"):
        ok("abandoned: login-start captured url+code (backedUp=%r)"
           % started.get("backedUp"))
    else:
        bad("abandoned: login-start did not start: %r %r"
            % (proc.returncode, proc.stdout.decode()[:200]))
        return 1
    if started.get("backedUp") is not True:
        bad("abandoned: login-start started without a verified backup")
    if os.path.isfile(auth_path):
        bad("abandoned: device-auth did not wipe auth.json first — the fixture "
            "no longer matches the real CLI this gate is about")
    else:
        ok("abandoned: auth.json is wiped while the attempt is pending "
           "(this is the state the TTL must recover from)")

    # The person closes the browser/popup: no approval, no explicit cancel. The
    # pending device flow is left running; the gate kills it here the way a box
    # reboot would, so recovery cannot depend on that process still existing.
    subprocess.run(["pkill", "-f", "codex login"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

    # The CLI recovers on its own after the TTL, with nobody clicking anything.
    # --fake-clock +16m puts the sweep past the 15-minute TTL.
    sweep_env = dict(env)
    if fake_now is not None:
        # NOW travels only with the TEST gate: without it the product ignores a
        # stray NOW value, so the gate sets both or the clock is real.
        sweep_env["AIRLOCK_CODEX_RELOGIN_TEST"] = "1"
        sweep_env["AIRLOCK_CODEX_RELOGIN_NOW"] = str(fake_now)
    sweep = run([ACCOUNTS, "codex-auth", "login-sweep", "--json"], sweep_env)
    try:
        result = json.loads(sweep.stdout.decode())
    except ValueError:
        result = {}
    if result.get("ok") is True and result.get("restored") is True:
        ok("abandoned: login-sweep past the TTL reports restored:true")
        sweep_ok = True
    else:
        bad("abandoned: no TTL auto-recovery: rc=%r out=%r err=%r"
            % (sweep.returncode, sweep.stdout.decode()[:200],
               sweep.stderr.decode()[:200]))
        sweep_ok = False
    if os.path.isfile(auth_path) and sha(auth_path) == original_sha:
        ok("abandoned: the previous login bytes are back in auth.json")
        bytes_ok = True
    else:
        bad("abandoned: auth.json was not restored to the previous login")
        bytes_ok = False
    if os.path.exists(auth_path + ".pre-relogin"):
        bad("abandoned: the stale backup is still lying around after recovery")
        clean_ok = False
    else:
        ok("abandoned: no stale backup left behind")
        clean_ok = True
    ac.append(("AC-SAFETY-C1", "sweep restored:true && login bytes back && no stale backup",
               "restored=%s,bytes=%s,clean=%s" % (sweep_ok, bytes_ok, clean_ok),
               sweep_ok and bytes_ok and clean_ok))

    # Phase B — the SERVER recovers, not just the CLI. A second attempt starts
    # through the HTTP surface, is abandoned the same way, and the server is
    # restarted (a redeploy) with the clock past the TTL: the next status poll —
    # the panel's first paint after reopening — must put the login back.
    port = 29977
    # The server starts on the real clock, like production: the fake clock only
    # enters with the redeploy past the TTL.
    server_env = dict(env, AIRLOCK_HUB_ACCOUNTS_PORT=str(port),
                      AIRLOCK_ACCOUNTS_BIN=ACCOUNTS,
                      AIRLOCK_ACCOUNTS_STATUS_BIN=os.path.join(tmp, "fake-status"),
                      AIRLOCK_STATE_DIR=os.path.join(tmp, "state"))
    os.makedirs(server_env["AIRLOCK_STATE_DIR"], exist_ok=True)

    def start_server(extra_env):
        proc = subprocess.Popen(
            [sys.executable, API], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, env=extra_env)
        for _ in range(80):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/claude-status"
                                       % port, timeout=2).read()
                return proc
            except Exception:
                time.sleep(0.25)
        return proc

    def stop_server(proc):
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

    def post(path):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                     data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())

    def get(path):
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path),
                                    timeout=30) as r:
            return json.loads(r.read().decode())

    server = start_server(server_env)
    try:
        try:
            started_http = post("/codex-login-start")
        except Exception as exc:
            bad("abandoned: the server could not start a login: %r" % exc)
            return 1
        if started_http.get("ok") is True and started_http.get("code"):
            ok("abandoned: server login-start captured url+code")
        else:
            bad("abandoned: server login-start answered %r" % (started_http,))
            return 1
        subprocess.run(["pkill", "-f", "codex login"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
    finally:
        stop_server(server)
    # Redeploy past the TTL: the new server process never saw the attempt start.
    future_env = dict(server_env)
    if fake_now is not None:
        future_env["AIRLOCK_CODEX_RELOGIN_TEST"] = "1"
        future_env["AIRLOCK_CODEX_RELOGIN_NOW"] = str(fake_now)
    server = start_server(future_env)
    try:
        try:
            get("/codex-status")
        except Exception as exc:
            bad("abandoned: post-redeploy status poll failed: %r" % exc)
            return 1
    finally:
        stop_server(server)
    # The pending device flow outlives the server (its own session, by design);
    # make sure no stray fake survives the gate either way.
    subprocess.run(["pkill", "-f", "codex login"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.isfile(auth_path) and sha(auth_path) == original_sha:
        ok("abandoned: the server restored the previous login on its next "
           "poll past the TTL (browser and popup stayed closed)")
        srv_ok = True
    else:
        bad("abandoned: the server did not recover the login past the TTL")
        srv_ok = False
    if os.path.exists(auth_path + ".pre-relogin"):
        bad("abandoned: the server left a stale backup behind")
        srv_clean = False
    else:
        ok("abandoned: the server left no stale backup behind")
        srv_clean = True
    ac.append(("AC-SAFETY-C2", "server restored login on next poll past TTL && no stale backup",
               "restored=%s,clean=%s" % (srv_ok, srv_clean), srv_ok and srv_clean))

    # AC: a real authenticated request succeeds after recovery — through the
    # real probe path (spawns app-server, speaks JSON-RPC), with the fake only
    # standing in for the provider side. codex-status=ok is NOT this: it only
    # parses id_token and proves nothing about the credential working.
    usage = run([STATUS, "--codex-usage"], env)
    try:
        reading = json.loads(usage.stdout.decode())
    except ValueError:
        reading = {}
    if reading.get("use7d") == 34 and reading.get("err") is None:
        ok("abandoned: post-recovery authenticated request returned a "
           "reading (use7d=34, no err)")
        auth_ok = True
    else:
        bad("abandoned: post-recovery authenticated request failed: %r"
            % (usage.stdout.decode()[:300],))
        auth_ok = False
    ac.append(("AC-SAFETY-C3", "post-recovery authenticated request use7d==34 && err None",
               "use7d=%r,err=%r" % (reading.get("use7d"), reading.get("err")), auth_ok))
    if emit_ac:
        emit_ac_rows(ac)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
