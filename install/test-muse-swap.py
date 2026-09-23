#!/usr/bin/env python3
"""MUSE_ROTATE gate: a human-picked Muse key swaps backup -> verify -> commit.

Contract (docs/tasks/active/20260923-subscription-accounts-MUSE_ROTATE.task.md):
  - NEVER auto-rotate: one key per person, the human picks on screen. This gate
    covers only the manual swap the picker drives.
  - Keep -> verify candidate -> commit, never discard the existing key first.
    A candidate the provider rejects (non-200) changes nothing: the old key
    stays byte-identical and no backup debris is left behind.
  - A successful swap reads 200 on the NEW key before the commit lands.

Modes (each prints its AC rows in the board's acceptance format):
  --trace-order               the CLI reports steps == backup,verify,commit on
                              success and backup,verify on a refused candidate
  --scenario manual-success   full stack: candidates list, POST swap, 200 on the
                              new key, old provider entries preserved
  --scenario manual-rollback  full stack: POST swap of a 401 candidate refuses,
                              the old key is byte-identical, no debris

Self-contained: an isolated HOME (fixture auth.json holding KEY-OLD), a fixture
vault helper, a fixture zen endpoint and a fixture assignment sheet. Loopback
only; live credentials are never read (every value carries a SENTINEL marker so
the leak controls prove absence by name). New files ship 100644, so run with:
  python3 install/test-muse-swap.py --trace-order
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACCOUNTS = os.path.join(ROOT, "bin", "airlock-accounts")
API_SOURCE = os.environ.get("AIRLOCK_ACCOUNTS_API_SOURCE",
                            os.path.join(ROOT, "bin", "airlock-accounts-api"))

OLD_ITEM = "OPENCODE_APPS_API_KEY"
NEW_ITEM = "OPENCODE_FINANCE_API_KEY"
DEAD_ITEM = "OPENCODE_DEAD_API_KEY"
HELD_ITEM = "OPENCODE_FIELD_API_KEY"
CHO_ITEM = "OPENCODE_CHO_API_KEY"
SPENT_ITEM = "OPENCODE_SPENT_API_KEY"
# An op://-shaped helper key: the sheet join and the display name both run
# through the item segment, so this lands on account "op", unheld, eligible.
OP_ITEM = "op://fixture-vault/OPENCODE_OP_API_KEY/password"

failures = []
ac_rows = []  # (ac_id, expected, observed, passed)


def check(name, cond, observed=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else " — %s" % (observed,)))
    if not cond:
        failures.append(name)


def ac(ac_id, expected, observed, passed):
    ac_rows.append((ac_id, expected, observed, bool(passed)))


def sha_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def write_helper(path):
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\nimport json\nprint(json.dumps({\n"
                '    "%s": "SENTINEL-OLD-KEY-VALUE",\n'
                '    "%s": "SENTINEL-NEW-KEY-VALUE",\n'
                '    "%s": "SENTINEL-DEAD-KEY-VALUE",\n'
                '    "%s": "SENTINEL-HELD-KEY-VALUE",\n'
                '    "%s": "SENTINEL-CHO-KEY-VALUE",\n'
                '    "%s": "SENTINEL-SPENT-KEY-VALUE",\n'
                '    "%s": "SENTINEL-OP-KEY-VALUE",\n'
                "}))\n" % (OLD_ITEM, NEW_ITEM, DEAD_ITEM, HELD_ITEM, CHO_ITEM, SPENT_ITEM, OP_ITEM))
    os.chmod(path, 0o755)


ZEN_PY = """#!/usr/bin/env python3
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
GOOD = {"status": "mu_ok", "percent": 12, "resetsAt": "2026-09-28T00:00:00.000Z"}
SPENT = {"status": "mu_ok", "percent": 100, "resetsAt": "2026-09-23T05:00:00.000Z"}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/zen/go/v1/usage":
            self.send_response(404); self.end_headers(); return
        auth = self.headers.get("Authorization", "")
        if auth == "Bearer SENTINEL-NEW-KEY-VALUE":
            # A slow provider opens the race window the CAS check must close:
            # the swap below edits the key file mid-verify and must be refused.
            time.sleep(2)
            body = json.dumps({"usage": {"rolling": dict(GOOD),
                                          "weekly": dict(GOOD),
                                          "monthly": dict(GOOD)}}).encode()
        elif auth == "Bearer SENTINEL-SPENT-KEY-VALUE":
            body = json.dumps({"usage": {"rolling": dict(SPENT),
                                          "weekly": dict(GOOD),
                                          "monthly": dict(GOOD)}}).encode()
        elif auth in ("Bearer SENTINEL-OLD-KEY-VALUE",
                    "Bearer SENTINEL-HELD-KEY-VALUE",
                    "Bearer SENTINEL-CHO-KEY-VALUE",
                    "Bearer SENTINEL-OP-KEY-VALUE"):
            body = json.dumps({"usage": {"rolling": dict(GOOD),
                                          "weekly": dict(GOOD),
                                          "monthly": dict(GOOD)}}).encode()
        else:
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers(); self.wfile.write(b'{"error":"bad key"}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body); return
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
"""


class World:
    """One isolated box: HOME with a fixture auth.json, helper, zen, sheet."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="muse-swap-")
        # Free ports per run: a harness-timeout kill orphans fixture servers that
        # keep squatting fixed ports (measured 2026-09-23 — a stale fake-zen ate
        # the SPENT branch and failed the suite for the wrong reason).
        import socket as _socket

        def _free_port():
            sock = _socket.socket()
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            sock.close()
            return port

        self.zen_port = _free_port()
        self.api_port = _free_port()
        self.home = os.path.join(self.tmp, "home")
        auth_dir = os.path.join(self.home, ".local", "share", "opencode")
        os.makedirs(auth_dir)
        self.auth_path = os.path.join(auth_dir, "auth.json")
        with open(self.auth_path, "w") as f:
            json.dump({"catcher": {"type": "api", "key": "UNCHANGED"},
                       "opencode-go": {"type": "api", "key": "SENTINEL-OLD-KEY-VALUE"}}, f)
        os.chmod(self.auth_path, 0o600)
        self.helper = os.path.join(self.tmp, "fake-muse-keys")
        write_helper(self.helper)
        with open(os.path.join(self.tmp, "fake-zen.py"), "w") as f:
            f.write(ZEN_PY)
        self.sheet = os.path.join(self.tmp, "sheet.json")
        with open(self.sheet, "w") as f:
            json.dump({HELD_ITEM: "peer-box", OLD_ITEM: "test-box"}, f)
        self.zen_pid = None
        self.srv_pid = None

    def env(self, extra=None):
        env = dict(os.environ, HOME=self.home,
                   AIRLOCK_MUSE_KEYS_BIN=self.helper,
                   AIRLOCK_MUSE_USAGE_URL="http://127.0.0.1:%d" % self.zen_port,
                   AIRLOCK_OPENCODE_AUTH_JSON=self.auth_path,
                   AIRLOCK_BOX_NAME="test-box",
                   AIRLOCK_MUSE_REGISTRY=self.sheet)
        if extra:
            env.update(extra)
        return env

    def start_zen(self):
        self.zen_pid = subprocess.Popen(
            [sys.executable, os.path.join(self.tmp, "fake-zen.py"), str(self.zen_port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid

    def stop_zen(self):
        if self.zen_pid:
            try:
                os.kill(self.zen_pid, 15)
            except OSError:
                pass
            self.zen_pid = None

    def cli(self, *args, extra=None):
        return subprocess.run(
            [ACCOUNTS, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60, stdin=subprocess.DEVNULL, env=self.env(extra), check=False)


def wait_up(url, tries=40):
    import urllib.request
    import urllib.error
    for _ in range(tries):
        try:
            urllib.request.urlopen(url, timeout=2).read()
            return True
        except urllib.error.HTTPError:
            return True  # the fixture answered (even a 401 is "up")
        except Exception:
            time.sleep(0.25)
    return False


def start_api(world, extra=None):
    import urllib.request
    env = world.env(extra)
    env["AIRLOCK_HUB_ACCOUNTS_PORT"] = str(world.api_port)
    env["AIRLOCK_STATE_DIR"] = os.path.join(world.tmp, "state")
    env["AIRLOCK_ACCOUNTS_STATUS_BIN"] = os.path.join(world.tmp, "does-not-exist")
    env["AIRLOCK_ACCOUNTS_BIN"] = ACCOUNTS
    log = os.path.join(world.tmp, "srv.log")
    with open(log, "w") as lf:
        proc = subprocess.Popen([sys.executable, API_SOURCE], stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, env=env)
    world.srv_pid = proc.pid
    ok = wait_up("http://127.0.0.1:%d/claude-status" % world.api_port)
    return ok, log


def stop_api(world):
    if world.srv_pid:
        try:
            os.kill(world.srv_pid, 15)
        except OSError:
            pass
        world.srv_pid = None


def api_get(world, path):
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:%d%s" % (world.api_port, path),
                                timeout=60) as r:
        return r.status, json.loads(r.read().decode())


def api_post(world, path, payload):
    import urllib.request
    body = json.dumps(payload).encode()
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (world.api_port, path),
                                 data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def mode_trace_order():
    world = World()
    world.start_zen()
    assert wait_up("http://127.0.0.1:%d/zen/go/v1/usage" % world.zen_port), "fixture zen did not come up"
    try:
        proc = world.cli("muse-swap", NEW_ITEM, "--json")
        try:
            result = json.loads(proc.stdout.decode())
        except ValueError:
            result = {}
        steps = result.get("steps") if isinstance(result, dict) else None
        check("trace-order: success swaps backup,verify,commit in order",
              proc.returncode == 0 and steps == ["backup", "verify", "commit"],
              "rc=%d steps=%r out=%r err=%r" % (proc.returncode, steps,
                                                proc.stdout[:200], proc.stderr[:200]))
        proc = world.cli("muse-swap", DEAD_ITEM, "--json")
        try:
            result = json.loads(proc.stdout.decode())
        except ValueError:
            result = {}
        steps = result.get("steps") if isinstance(result, dict) else None
        check("trace-order: a refused candidate stops after verify, commit never runs",
              proc.returncode != 0 and steps == ["backup", "verify"],
              "rc=%d steps=%r" % (proc.returncode, steps))
        world.stop_zen()
    finally:
        pass

    # A concurrent edit to another entry mid-verify must abort, not clobber.
    # The fixture zen stalls the NEW verify by 2s; the edit lands inside it.
    import threading as _threading
    raced = World()
    raced.start_zen()
    assert wait_up("http://127.0.0.1:%d/zen/go/v1/usage" % raced.zen_port), "fixture zen did not come up"
    raced_out = {}
    try:
        def _swap():
            raced_out["proc"] = raced.cli("muse-swap", NEW_ITEM, "--json")
        thread = _threading.Thread(target=_swap)
        thread.start()
        time.sleep(0.5)
        # A null-valued addition ONLY: presence counts, so this must abort. (A
        # .get() compare reads a missing key and an explicit null identically
        # and would commit over it — the regression this pins.)
        with open(raced.auth_path, "rb") as f:
            raced_before = f.read()
        concurrent = json.loads(raced_before.decode("utf-8"))
        concurrent["nullprobe"] = None
        with open(raced.auth_path, "w") as f:
            json.dump(concurrent, f)
        thread.join(timeout=60)
        proc = raced_out.get("proc")
        try:
            result = json.loads(proc.stdout.decode()) if proc is not None else {}
        except ValueError:
            result = {}
        live = json.load(open(raced.auth_path))
        check("trace-order: a mid-verify edit aborts the commit, live keeps the edit",
              proc is not None and proc.returncode != 0
              and result.get("steps") == ["backup", "verify", "commit", "rollback"]
              and "changed during verification" in (result.get("error") or "")
              and live == concurrent,
              (proc.returncode if proc else None, result, live))
    finally:
        raced.stop_zen()

    # A commit that cannot write must roll back with an honest message. A
    # read-only key dir with no live file fails the tmp write deterministically
    # (non-root runners; root ignores permission bits, so skip there loudly).
    import stat as _stat
    ro = World()
    os.remove(ro.auth_path)
    os.chmod(os.path.dirname(ro.auth_path), 0o555)
    try:
        if os.geteuid() == 0:
            print("SKIP trace-order: commit-failure needs permission bits (running as root)")
        else:
            ro.start_zen()
            assert wait_up("http://127.0.0.1:%d/zen/go/v1/usage" % ro.zen_port), "fixture zen did not come up"
            proc = ro.cli("muse-swap", NEW_ITEM, "--json")
            try:
                result = json.loads(proc.stdout.decode())
            except ValueError:
                result = {}
            leftovers = sorted(os.listdir(os.path.dirname(ro.auth_path)))
            check("trace-order: a failed commit rolls back, stages nothing",
                  proc.returncode != 0
                  and result.get("steps") == ["backup", "verify", "commit", "rollback"]
                  and "no previous key" in (result.get("error") or "")
                  and not os.path.exists(ro.auth_path)
                  and leftovers == [],
                  (proc.returncode, result, leftovers))
            ro.stop_zen()
    finally:
        os.chmod(os.path.dirname(ro.auth_path), 0o755)

    ok = (not failures)
    ac("AC-MUSE-SWAP-ORDER", "steps backup,verify,commit; refusal backup,verify",
       "failures=%d" % len(failures), ok)
    return not failures


def mode_manual_success():
    world = World()
    world.start_zen()
    assert wait_up("http://127.0.0.1:%d/zen/go/v1/usage" % world.zen_port), "fixture zen did not come up"
    before = sha_file(world.auth_path)
    with open(world.auth_path, "rb") as f:
        before_bytes = f.read()
    ok, log = start_api(world)
    if not ok:
        check("manual-success: the account surface came up", False, open(log).read()[-500:])
        ac("AC-MUSE-SWAP-SUCCESS", "200 on the new key", "server did not come up", False)
        ac("AC-MUSE-SWAP-ORDER", "steps backup,verify,commit", "server did not come up", False)
        world.stop_zen()
        return False
    try:
        # The 임계 pin: an exhausted window is refused before anything moves.
        proc = world.cli("muse-swap", SPENT_ITEM, "--json")
        try:
            spent_result = json.loads(proc.stdout.decode())
        except ValueError:
            spent_result = {}
        check("manual-success: an exhausted candidate is refused, old key untouched",
              proc.returncode != 0
              and spent_result.get("steps") == ["backup", "verify"]
              and "exhausted" in (spent_result.get("error") or "")
              and sha_file(world.auth_path) == before,
              (proc.returncode, spent_result))
        status, candidates = api_get(world, "/muse-swap-candidates")
        by = {}
        if isinstance(candidates, dict):
            for entry in candidates.get("candidates", []):
                by[entry.get("account")] = entry
        new = by.get("finance", {})
        check("manual-success: the picked key is eligible with all three numbers",
              status == 200 and new.get("eligible") is True
              and [w["window"] for w in new.get("limits", [])] == ["rolling", "weekly", "monthly"]
              and all(isinstance(w["percent"], int) for w in new.get("limits", [])),
              candidates)
        dead = by.get("dead", {})
        check("manual-success: the 401 key is present but inactive, never 0%",
              dead.get("eligible") is False and dead.get("limits") == []
              and isinstance(dead.get("err"), str),
              dead)
        spent = by.get("spent", {})
        check("manual-success: the exhausted key shows its numbers but is inactive",
              spent.get("eligible") is False and spent.get("reason") == "exhausted"
              and [w["window"] for w in spent.get("limits", [])] == ["rolling", "weekly", "monthly"]
              and spent.get("limits", [{}])[0].get("percent") == 100,
              spent)
        check("manual-success: a key another box holds is not offered",
              "field" not in by, sorted(by))
        check("manual-success: the cho-only key is hidden on other boxes",
              "cho" not in by, sorted(by))
        check("manual-success: the active key is identified without exposing values",
              candidates.get("active") == "apps"
              and "SENTINEL-" not in json.dumps(candidates),
              candidates.get("active"))
        op = by.get("op", {})
        check("manual-success: an op:// helper key joins by item segment",
              op.get("eligible") is True and op.get("item") == OP_ITEM
              and [w["window"] for w in op.get("limits", [])] == ["rolling", "weekly", "monthly"],
              op)

        status, swapped = api_post(world, "/muse-swap", {"item": NEW_ITEM})
        check("manual-success: the swap commits (HTTP 200)",
              status == 200 and swapped.get("ok") is True, (status, swapped))
        live = json.load(open(world.auth_path))
        check("manual-success: the new key is live and nothing else moved",
              live.get("opencode-go", {}).get("key") == "SENTINEL-NEW-KEY-VALUE"
              and live.get("catcher", {}).get("key") == "UNCHANGED"
              and before != sha_file(world.auth_path),
              {k: ("<redacted>" if k == "opencode-go" else v) for k, v in live.items()})
        steps = swapped.get("steps")
        check("manual-success: order matches the 3 steps",
              steps == ["backup", "verify", "commit"], steps)
        check("manual-success: the swap says new sessions pick it up (seat-recovery)",
              swapped.get("needsRestart") is True, swapped)
        bak_path = world.auth_path + ".muse-swap-bak"
        check("manual-success: the previous key is kept 0600 beside live",
              os.path.isfile(bak_path)
              and open(bak_path, "rb").read() == before_bytes
              and (os.stat(bak_path).st_mode & 0o777) == 0o600, bak_path)
        check("manual-success: no key value reaches the service log",
              "SENTINEL-" not in open(log, errors="replace").read(), log)
        stop_api(world)
        # Without a sheet nothing is offered, however readable the keys are.
        ok, _ = start_api(world, extra={"AIRLOCK_MUSE_REGISTRY": ""})
        check("manual-success: the surface restarts without a sheet", ok, "server restart failed")
        if ok:
            status, no_sheet = api_get(world, "/muse-swap-candidates")
            check("manual-success: an unconfigured sheet offers nothing",
                  status == 200 and no_sheet.get("sheet") == "not-configured"
                  and no_sheet.get("candidates") == [], no_sheet)
            stop_api(world)
        ok, _ = start_api(world, extra={"AIRLOCK_MUSE_REGISTRY": os.path.join(world.tmp, "no-sheet.json")})
        if ok:
            status, bad_sheet = api_get(world, "/muse-swap-candidates")
            check("manual-success: an unreadable sheet offers nothing",
                  status == 200 and bad_sheet.get("sheet") == "unavailable"
                  and bad_sheet.get("candidates") == [], bad_sheet)
            stop_api(world)
        # The cho flag opens exactly the cho row, nowhere else.
        ok, _ = start_api(world, extra={"AIRLOCK_MUSE_CHO_VISIBLE": "1"})
        if ok:
            status, cho = api_get(world, "/muse-swap-candidates")
            cho_rows = {e.get("account"): e for e in cho.get("candidates", [])}
            check("manual-success: the cho key appears only where flagged",
                  status == 200 and cho.get("choVisible") is True
                  and cho_rows.get("cho", {}).get("eligible") is True, cho_rows)
            stop_api(world)
        ok = (not failures)
        ac("AC-MUSE-SWAP-SUCCESS", "200 on the new key, old entries preserved",
           "failures=%d" % len(failures), ok)
        ac("AC-MUSE-SWAP-ORDER", "steps backup,verify,commit",
           "steps=%r" % (steps,), steps == ["backup", "verify", "commit"])
    finally:
        stop_api(world)
        world.stop_zen()
    return not failures


def mode_manual_rollback():
    world = World()
    world.start_zen()
    assert wait_up("http://127.0.0.1:%d/zen/go/v1/usage" % world.zen_port), "fixture zen did not come up"
    before = sha_file(world.auth_path)
    ok, log = start_api(world)
    if not ok:
        check("manual-rollback: the account surface came up", False, open(log).read()[-500:])
        ac("AC-MUSE-SWAP-ROLLBACK", "old key untouched", "server did not come up", False)
        ac("AC-MUSE-SWAP-ORDER", "steps backup,verify", "server did not come up", False)
        world.stop_zen()
        return False
    try:
        import urllib.error
        # The picker omits these, but the mutation boundary enforces them too:
        # a crafted POST names any helper item.
        status, held = api_post(world, "/muse-swap", {"item": HELD_ITEM})
        check("manual-rollback: another box's key is refused at the boundary",
              status != 200 and held.get("ok") is False
              and held.get("steps") == ["backup", "verify"]
              and "another box" in (held.get("error") or "")
              and sha_file(world.auth_path) == before, (status, held))
        status, cho = api_post(world, "/muse-swap", {"item": CHO_ITEM})
        check("manual-rollback: the off-box cho key is refused at the boundary",
              status != 200 and cho.get("ok") is False
              and "not offered" in (cho.get("error") or "")
              and sha_file(world.auth_path) == before, (status, cho))
        status, swapped = api_post(world, "/muse-swap", {"item": DEAD_ITEM})
        check("manual-rollback: the 401 candidate is refused",
              status != 200 and swapped.get("ok") is False, (status, swapped))
        check("manual-rollback: the old key is byte-identical",
              sha_file(world.auth_path) == before, world.auth_path)
        debris = [name for name in os.listdir(os.path.dirname(world.auth_path))
                  if name.startswith("auth.json.") and name != "auth.json"]
        check("manual-rollback: no backup debris is left behind", debris == [], debris)
        steps = swapped.get("steps")
        check("manual-rollback: commit never ran after a failed verify",
              steps == ["backup", "verify"], steps)
        live = json.load(open(world.auth_path))
        check("manual-rollback: live still answers for the old key",
              live.get("opencode-go", {}).get("key") == "SENTINEL-OLD-KEY-VALUE", "live moved")
        check("manual-rollback: no key value reaches the refusal or the log",
              "SENTINEL-" not in json.dumps(swapped)
              and "SENTINEL-" not in open(log, errors="replace").read(),
              (swapped, log))
        ok = (not failures)
        ac("AC-MUSE-SWAP-ROLLBACK", "rc!=0, old key byte-identical, no debris",
           "failures=%d" % len(failures), ok)
        ac("AC-MUSE-SWAP-ORDER", "steps backup,verify",
           "steps=%r" % (steps,), steps == ["backup", "verify"])
    finally:
        stop_api(world)
        world.stop_zen()
    return not failures


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace-order", action="store_true")
    parser.add_argument("--scenario", default="")
    args = parser.parse_args(argv)
    selected = {s.strip() for s in args.scenario.split(",") if s.strip()}
    ran = False
    if args.trace_order:
        ran = True
        mode_trace_order()
    if "manual-success" in selected:
        ran = True
        mode_manual_success()
    if "manual-rollback" in selected:
        ran = True
        mode_manual_rollback()
    unknown = selected - {"manual-success", "manual-rollback"}
    if unknown:
        check("unknown scenarios refused: %s" % sorted(unknown), False)
    if not ran:
        print("usage: %s --trace-order | --scenario manual-success[,manual-rollback]"
              % os.path.basename(__file__), file=sys.stderr)
        return 2
    try:
        revision = subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=15, check=False).stdout.decode().strip() or "unknown"
    except Exception:
        revision = "unknown"
    for ac_id, expected, observed, passed in ac_rows:
        print("%s | expected: %s | observed: %s | verdict: %s | signal: fixture | "
              "evidence: install/test-muse-swap.py@%s"
              % (ac_id, expected, observed, "PASS" if passed else "FAIL", revision))
    if failures:
        print("%d check(s) failed" % len(failures))
        return 1
    print("all muse-swap checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
