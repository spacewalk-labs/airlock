#!/usr/bin/env python3
"""SAFETY gate, Claude path: a rejected switch target must change nothing.

Contract (docs/tasks/active/20260922-subscription-accounts-SAFETY.task.md):
  - The candidate is verified BEFORE it reaches live; a target the server already
    rejected (a recorded death verdict) is refused without a single write.
  - When a switch fails, live + active + the previous account are all restored
    automatically — no human repair step.

Offline and self-contained: an isolated HOME with a two-slot pool. The rejected
target carries a recorded server rejection with its expiry still in the future,
so only the verdict — never the clock — can refuse it. No network is needed and
none is attempted: stdin is closed and the pool owner is never prompted.

Usage:
  install/test-accounts-switch.py --scenario rejected-target [--emit-ac]

  --emit-ac prints one AC row per acceptance claim, in the board's acceptance
  format (AC-id | expected | observed | verdict | signal | evidence).
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ACCOUNTS = os.path.join(ROOT, "bin", "airlock-accounts")

sys.path.insert(0, os.path.join(ROOT, "bin"))
import account_health  # noqa: E402

fails = 0


def ok(msg):
    print("ok: %s" % msg)


def bad(msg):
    global fails
    fails += 1
    print("FAIL: %s" % msg)


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def slot(name, email, dead=False):
    import time
    now_ms = int(time.time() * 1000)
    creds = {"claudeAiOauth": {
        "accessToken": "ACCESS-%s-NOT-A-REAL-TOKEN" % name,
        "refreshToken": "REFRESH-%s-NOT-A-REAL-TOKEN" % name,
        # Valid for hours: the clock must NOT be what refuses this target.
        "expiresAt": now_ms + 6 * 3600 * 1000,
        "refreshTokenExpiresAt": now_ms + 90 * 86400 * 1000,
        "subscriptionType": "max"},
        "_meta": {"email": email, "org": "claude_max", "kind": "personal"}}
    if dead:
        assert account_health.mark_dead.__module__  # product code plants the verdict
        return creds, True
    return creds, False


def main(argv):
    emit_ac = "--emit-ac" in argv
    argv = [a for a in argv if a != "--emit-ac"]
    if argv != ["--scenario", "rejected-target"]:
        print("usage: %s --scenario rejected-target [--emit-ac]"
              % os.path.basename(__file__), file=sys.stderr)
        return 2
    ac = []  # (ac_id, expected, observed, passed)

    tmp = tempfile.mkdtemp(prefix="accounts-switch-safety-")
    home = os.path.join(tmp, "home")
    pool = os.path.join(home, ".claude-accounts")
    live_dir = os.path.join(home, ".claude")
    os.makedirs(pool)
    os.makedirs(live_dir)

    live_path = os.path.join(live_dir, ".credentials.json")
    active_path = os.path.join(pool, ".active")
    alice = "alice@example.test (personal)"
    bob = "bob@example.test (personal)"

    alice_creds, _ = slot("ALICE", "alice@example.test")
    bob_creds, plant = slot("BOB", "bob@example.test", dead=True)
    assert plant
    for name, creds in ((alice, alice_creds), (bob, bob_creds)):
        with open(os.path.join(pool, name + ".json"), "w") as f:
            json.dump(creds, f)
    # The server already rejected Bob's lineage: plant the recorded verdict with
    # the product's own writer, so the fixture speaks the real marker protocol.
    bob_path = os.path.join(pool, bob + ".json")
    assert account_health.mark_dead(bob_path, bob_creds), \
        "fixture could not plant the death verdict"
    with open(live_path, "w") as f:
        json.dump(alice_creds, f)
    with open(active_path, "w") as f:
        f.write(alice)

    before = {key: sha_file(path) for key, path in (
        ("live", live_path), ("active", active_path),
        ("previous-pool-slot", os.path.join(pool, alice + ".json")),
        ("target-pool-slot", bob_path))}

    env = dict(os.environ, HOME=home)
    proc = subprocess.run(
        [ACCOUNTS, "swap", bob], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, stdin=subprocess.DEVNULL, env=env, check=False)
    if proc.returncode == 0:
        bad("rejected-target: the switch to a server-rejected account "
            "reported success — verification did not happen before commit")
        refused = False
    else:
        ok("rejected-target: the switch was refused (rc=%d)" % proc.returncode)
        refused = True
    err = proc.stderr.decode(errors="replace")
    remedy = ("re-login" in err or "rejected" in err or "dead" in err)
    if remedy:
        ok("rejected-target: the refusal names the remedy instead of a bare rc")
    else:
        bad("rejected-target: the refusal says nothing actionable: %r" % err[:200])
    ac.append(("AC-SAFETY-S1", "rc!=0 && refusal names the remedy",
               "rc=%d,remedy=%s" % (proc.returncode, remedy), refused and remedy))

    # live + active + the previous account: all three hashes must be untouched.
    # "The switch failed but live moved" is the exact data loss this gate bans.
    unchanged = 0
    for key, path in (("live", live_path), ("active", active_path),
                      ("previous-pool-slot", os.path.join(pool, alice + ".json")),
                      ("target-pool-slot", bob_path)):
        if not os.path.isfile(path):
            bad("rejected-target: %s is gone after the refused switch (%s)"
                % (key, path))
        elif sha_file(path) != before[key]:
            bad("rejected-target: %s changed during a refused switch" % key)
        else:
            ok("rejected-target: %s is byte-identical after the refusal" % key)
            unchanged += 1
    ac.append(("AC-SAFETY-S2", "live+active+previous+target hashes unchanged",
               "unchanged=%d/4" % unchanged, unchanged == 4))
    if os.path.exists(live_path + ".switch-bak"):
        bad("rejected-target: a live backup file was left behind by a switch "
            "that must not have touched live at all")
        debris = True
    else:
        ok("rejected-target: live was never staged, so no backup debris exists")
        debris = False

    # Zero human interventions: stdin was closed and the run still completed.
    print("ok: rejected-target: completed with stdin closed (no prompt possible)")
    ac.append(("AC-SAFETY-S3", "no staging debris && stdin-closed completion",
               "debris=%s,stdin=closed" % debris, not debris))
    if emit_ac:
        try:
            revision = subprocess.run(
                ["git", "-C", ROOT, "rev-parse", "HEAD"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=15, check=False).stdout.decode().strip() or "unknown"
        except Exception:
            revision = "unknown"
        for ac_id, expected, observed, passed in ac:
            print("%s | expected: %s | observed: %s | verdict: %s | signal: fixture | "
                  "evidence: install/test-accounts-switch.py@%s"
                  % (ac_id, expected, observed, "PASS" if passed else "FAIL", revision))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
