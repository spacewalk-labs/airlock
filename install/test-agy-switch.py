#!/usr/bin/env python3
"""agy saved-login switch: backup -> verify in a throwaway HOME -> commit.

Fixture only: fake token files (an id_token whose email claim names the account)
and a fake usage probe that answers a reading for the login it finds in $HOME,
or refuses when the account name says so. No real agy, no real credential.
"""
import base64, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "bin", "airlock-accounts")
failures = []


def check(name, cond, observed=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else " — %r" % (observed,)))
    if not cond:
        failures.append(name)


def token(email, secret):
    claims = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
    return json.dumps({"token": {"access_token": secret, "refresh_token": secret},
                       "auth_method": "consumer", "id_token": "h." + claims + ".s"}).encode()


PROBE = r'''import base64, json, os
p = os.path.join(os.environ["HOME"], ".gemini", "antigravity-cli", "antigravity-oauth-token")
d = json.load(open(p))
c = d["id_token"].split(".")[1]
email = json.loads(base64.urlsafe_b64decode(c + "=" * (-len(c) % 4)))["email"]
if "reject" in email:
    print(json.dumps({"ok": False, "error": "not logged in"}))
else:
    print(json.dumps({"ok": True, "account": email, "observedAt": 1,
                      "groups": [{"name": "GEMINI MODELS", "weeklyRemaining": 50.0,
                                  "fiveHourRemaining": 50.0, "weeklyResetAt": 2,
                                  "fiveHourResetAt": 2}]}))
'''


def box():
    home = tempfile.mkdtemp(prefix="agy-switch-test-")
    agy_dir = os.path.join(home, ".gemini", "antigravity-cli")
    os.makedirs(os.path.join(agy_dir, "saved-credentials"), mode=0o700)
    with open(os.path.join(agy_dir, "antigravity-oauth-token"), "wb") as f:
        f.write(token("a@example.test", "LIVE-A"))
    for email, secret in (("b@example.test", "SAVED-B"), ("reject@example.test", "SAVED-R")):
        with open(os.path.join(agy_dir, "saved-credentials", email + ".json"), "wb") as f:
            f.write(token(email, secret))
    probe = os.path.join(home, "probe.py")
    with open(probe, "w") as f:
        f.write(PROBE)
    os.chmod(probe, 0o644)
    env = dict(os.environ, HOME=home, AIRLOCK_AGY_DIR=agy_dir, AIRLOCK_AGY_USAGE_BIN=probe,
               AIRLOCK_AGY_BIN="/bin/true", PYTHONDONTWRITEBYTECODE="1")
    for key in ("AIRLOCK_PASEO_HOST", "AIRLOCK_PASEO_BIN", "AIRLOCK_PASEO_AGENTS_DIR"):
        env.pop(key, None)
    return agy_dir, env


def run(env, *args):
    proc = subprocess.run([sys.executable, "-B", CLI, *args], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    try:
        return proc.returncode, json.loads(proc.stdout or b"{}")
    except ValueError:
        return proc.returncode, {"raw": proc.stdout.decode()[:200]}


def live(agy_dir):
    with open(os.path.join(agy_dir, "antigravity-oauth-token"), "rb") as f:
        return f.read()


# list: live + saved, active marked
agy_dir, env = box()
rc, doc = run(env, "agy-list", "--json")
check("list: live and saved logins, live is active",
      rc == 0 and doc.get("active") == "a@example.test"
      and [a["email"] for a in doc.get("accounts", [])]
      == ["a@example.test", "b@example.test", "reject@example.test"], doc)
check("list: the live login is kept in the pool (a terminal sign-in cannot lose it)",
      os.path.isfile(os.path.join(agy_dir, "saved-credentials", "a@example.test.json")))

# success: order, live replaced, previous kept, 0600
rc, doc = run(env, "agy-switch", "b@example.test", "--json")
check("switch: backup, verify, commit in order",
      rc == 0 and doc.get("ok") is True and doc.get("steps") == ["backup", "verify", "commit"], doc)
check("switch: live now names the new account", b"SAVED-B" in live(agy_dir))
with open(os.path.join(agy_dir, "saved-credentials", "a@example.test.json"), "rb") as f:
    check("switch: the previous login was saved back", b"LIVE-A" in f.read())
mode = os.stat(os.path.join(agy_dir, "antigravity-oauth-token")).st_mode & 0o777
check("switch: live file stays 0600", mode == 0o600, oct(mode))
check("switch: no token value in the JSON", b"SAVED" not in json.dumps(doc).encode(), doc)

# refused candidate: live byte-identical, commit never runs
agy_dir, env = box()
before = live(agy_dir)
rc, doc = run(env, "agy-switch", "reject@example.test", "--json")
check("refused: verify fails, commit never runs",
      rc != 0 and doc.get("ok") is False and doc.get("steps") == ["backup", "verify"], doc)
check("refused: live login byte-identical", live(agy_dir) == before)

# unknown account: refused before anything is written
rc, doc = run(env, "agy-switch", "nobody@example.test", "--json")
check("unknown: an account not saved here is refused",
      rc != 0 and doc.get("error") == "that account is not saved on this box", doc)
check("unknown: live login byte-identical", live(agy_dir) == before)

# New login: agy runs in an isolated HOME under tmux, exposes only the Google URL,
# receives the one-time code on stdin, and saves the resulting account without
# replacing the live account. The fake process writes a fixture token only after input.
agy_dir, env = box()
fake_agy = os.path.join(env["HOME"], "fake-agy")
new_token = token("new@example.test", "NEW-LOGIN").decode()
with open(fake_agy, "w") as f:
    f.write("#!%s\nimport json, os, sys\n"
            "print('Approve at https://accounts.google.com/o/oauth2/auth?fixture=1', flush=True)\n"
            "code = input().strip()\n"
            "p = os.path.join(os.environ['HOME'], '.gemini', 'antigravity-cli', 'antigravity-oauth-token')\n"
            "os.makedirs(os.path.dirname(p), exist_ok=True)\n"
            "open(p, 'w').write(%r) if code == 'one-time-code' else None\n" %
            (sys.executable, new_token))
os.chmod(fake_agy, 0o755)
env["AIRLOCK_AGY_BIN"] = fake_agy
rc, started = run(env, "agy-login-start", "--json")
check("login: isolated agy returns a Google URL only",
      rc == 0 and started.get("url", "").startswith("https://accounts.google.com/")
      and "NEW-LOGIN" not in json.dumps(started), started)
proc = subprocess.run([sys.executable, "-B", CLI, "agy-login-code", "--json"], env=env,
                      input=b"one-time-code", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                      timeout=90)
finished = json.loads(proc.stdout or b"{}")
check("login: result is saved and active login stays unchanged",
      proc.returncode == 0 and finished.get("email") == "new@example.test"
      and b"LIVE-A" in live(agy_dir)
      and os.path.isfile(os.path.join(agy_dir, "saved-credentials", "new@example.test.json")),
      finished)
check("login: one-time code is absent from output", b"one-time-code" not in proc.stdout + proc.stderr)

# reseat (default): the Paseo seats holding the old login are restarted — an idle
# seat's agy just ends (the adapter respawns it on the next prompt), a busy seat also
# gets one continue message. An agy no Paseo seat owns is left alone. Only processes
# whose conversation is a seat in THIS fixture's records are ever signalled, so real
# agy seats on the box running this test are never touched.
import signal, time
agy_dir, env = box()
home = env["HOME"]
fake_bin = os.path.join(home, "fakebin")
os.makedirs(fake_bin)
sends = os.path.join(home, "sends.log")
paseo = os.path.join(fake_bin, "paseo")
with open(paseo, "w") as f:
    f.write("#!%s\nimport json, sys\na = sys.argv[1:]\n"
            "a = a[2:] if a[:1] == ['--host'] else a\n"
            "if a[:1] == ['ls']:\n"
            "    print(json.dumps([{'id': 'seat-idle', 'status': 'idle', 'provider': 'agy/x', 'cwd': %r},"
            " {'id': 'seat-busy', 'status': 'running', 'provider': 'agy/x', 'cwd': %r},"
            " {'id': 'seat-resumed', 'status': 'idle', 'provider': 'agy/x', 'cwd': %r}]))\n"
            "elif a[:1] == ['send']:\n"
            "    open(%r, 'a').write(a[1] + '\\n')\n"
            % (sys.executable, os.path.join(home, "w-idle"), os.path.join(home, "w-busy"),
               os.path.join(home, "w-resumed"), sends))
for w in ("w-idle", "w-busy", "w-resumed"):
    os.makedirs(os.path.join(home, w))
os.chmod(paseo, 0o755)
for agent, conv in (("seat-idle", "conv-idle"), ("seat-busy", "conv-busy")):
    d = os.path.join(home, ".paseo", "agents", "fixture")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, agent + ".json"), "w") as f:
        json.dump({"id": agent, "persistence": {"provider": "agy", "sessionId": conv,
                                                "metadata": {"cwd": home}}}, f)
procs = {}
# conv-resumed is not any seat's recorded session; its directory is seat-resumed's.
for conv, extra in (("conv-idle", ""), ("conv-busy", ""), ("conv-stranger", ""),
                    ("conv-resumed", " --add-dir=" + os.path.join(home, "w-resumed"))):
    procs[conv] = subprocess.Popen(
        ["bash", "-c", 'exec -a agy "$0" -c "import time; time.sleep(120)" --conversation='
         + conv + extra, sys.executable], start_new_session=True)
time.sleep(0.5)
env.update(AIRLOCK_PASEO_HOST="127.0.0.1:1", AIRLOCK_PASEO_BIN=paseo)
rc, doc = run(env, "agy-switch", "b@example.test", "--json")
for p in procs.values():
    p.poll()
reseat = doc.get("reseat") or {}
check("reseat: the switch still commits", rc == 0 and doc.get("steps") == ["backup", "verify", "commit"], doc)
check("reseat: the idle seats' agy ended, no message (session id or same directory)",
      procs["conv-idle"].returncode is not None and procs["conv-resumed"].returncode is not None
      and reseat.get("restarted") == 2, reseat)
check("reseat: the busy seat's agy ended and it got one continue",
      procs["conv-busy"].returncode is not None and reseat.get("continued") == 1
      and open(sends).read().split() == ["seat-busy"], reseat)
check("reseat: an agy no seat owns is left running",
      procs["conv-stranger"].returncode is None and reseat.get("untouched", 0) >= 1, reseat)
check("reseat: what is left is reported", doc.get("runningAgy", 0) >= 1 and doc.get("needsRestart") is True, doc)
for p in procs.values():
    if p.poll() is None:
        p.kill()

# "Switch only": the person chose to restart seats later — nothing is signalled.
agy_dir, env = box()
keep = subprocess.Popen(["bash", "-c", 'exec -a agy "$0" -c "import time; time.sleep(60)" --conversation=conv-idle',
                         sys.executable], start_new_session=True)
time.sleep(0.5)
env.update(AIRLOCK_PASEO_HOST="127.0.0.1:1", AIRLOCK_PASEO_BIN=paseo)
rc, doc = run(env, "agy-switch", "b@example.test", "--json", "--no-reseat")
check("switch only: commits, restarts nothing, reports what still holds the old login",
      rc == 0 and doc.get("reseat") is None and keep.poll() is None
      and doc.get("runningAgy", 0) >= 1 and doc.get("needsRestart") is True, doc)
keep.kill()

# Muse reseat (opt-in): end the Paseo daemon's opencode server, reload every
# opencode seat, and send one "continue" to a seat that was mid-turn. Only an
# opencode server whose parent is a Paseo daemon is signalled.
home = tempfile.mkdtemp(prefix="muse-reseat-test-")
calls = os.path.join(home, "calls.log")
paseo = os.path.join(home, "paseo")
with open(paseo, "w") as f:
    f.write("#!%s\nimport json, sys\na = sys.argv[1:]\na = a[2:] if a[:1] == ['--host'] else a\n"
            "if a[:1] == ['ls']:\n"
            "    print(json.dumps([{'id': 'muse-idle', 'status': 'idle', 'provider': 'opencode/x', 'cwd': '/tmp'},"
            " {'id': 'muse-busy', 'status': 'running', 'provider': 'opencode/x', 'cwd': '/tmp'},"
            " {'id': 'agy-seat', 'status': 'idle', 'provider': 'agy/x', 'cwd': '/tmp'}]))\n"
            "else:\n    open(%r, 'a').write(' '.join(a[:3]) + '\\n')\n" % (sys.executable, calls))
os.chmod(paseo, 0o755)
daemon = subprocess.Popen(
    ["bash", "-c", 'exec -a "Paseo Daemon" "$0" -c "import subprocess, time; '
     "subprocess.Popen(['bash', '-c', 'exec -a opencode \\\"$0\\\" -c \\\"import time; time.sleep(60)\\\" serve --port 1', '" + sys.executable + "']); time.sleep(60)\"",
     sys.executable], start_new_session=True)
stray = subprocess.Popen(["bash", "-c", 'exec -a opencode "$0" -c "import time; time.sleep(60)" serve --port 2',
                          sys.executable], start_new_session=True)
time.sleep(1.0)
# Scope the server scan to the fake daemon — never this box's real Paseo server.
os.environ["AIRLOCK_PASEO_DAEMON_PID"] = str(daemon.pid)
spec = __import__("importlib.util").util.spec_from_loader(
    "acc", __import__("importlib.machinery").machinery.SourceFileLoader("acc", CLI))
acc = __import__("importlib.util").util.module_from_spec(spec)
os.environ.update(AIRLOCK_PASEO_HOST="127.0.0.1:1", AIRLOCK_PASEO_BIN=paseo)
spec.loader.exec_module(acc)
servers_before = acc._paseo_opencode_servers()
res = acc._muse_reseat("apps")
time.sleep(0.5)
log_lines = open(calls).read().split("\n") if os.path.exists(calls) else []
check("muse reseat: only the scoped daemon's opencode server is found",
      len(servers_before) == 1 and stray.poll() is None, servers_before)
check("muse reseat: that server is ended", not acc._paseo_opencode_servers(), acc._paseo_opencode_servers())
check("muse reseat: every opencode seat reloads, agy seats untouched",
      "agent reload muse-idle" in log_lines and "agent reload muse-busy" in log_lines
      and not any("agy-seat" in x for x in log_lines), log_lines)
check("muse reseat: the busy seat alone gets one continue",
      sum(1 for x in log_lines if x.startswith("send")) == 1
      and any(x.startswith("send muse-busy") for x in log_lines)
      and res == {"restarted": 1, "continued": 1, "failed": 0}, (res, log_lines))
for proc in (daemon, stray):
    try:
        os.killpg(proc.pid, 9)
    except OSError:
        pass

print("agy-switch: %d failed" % len(failures))
sys.exit(1 if failures else 0)
