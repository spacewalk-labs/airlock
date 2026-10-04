#!/usr/bin/env python3
"""The live account's usage survives a throttled usage endpoint.

Observed defect: on a box with many Claude Code sessions the usage endpoint answered the
live account with nothing but 429 for 105-129 minutes, the panel kept showing the last
reading, and the account ran out while it still read 44%. Fix: when the live account's
usage call is throttled, airlock-accounts-status reads the windows from one short Claude
Code turn (`rate_limit_event`). No existing suite loads that module's Claude usage path
in-process, hence a new file.

Offline: a fake `claude` (CLAUDE_BIN) and a fake live credential in a temp HOME.
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATUS = os.path.join(ROOT, "bin", "airlock-accounts-status")

tmp = tempfile.mkdtemp(prefix="claude-session-usage-")
os.environ["HOME"] = tmp
os.environ["AIRLOCK_STATE_DIR"] = os.path.join(tmp, "state")
calls = os.path.join(tmp, "calls")
fake = os.path.join(tmp, "claude")
event = {"type": "rate_limit_event", "rate_limit_info": {
    "status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": 0.44, "resetsAt": 1790647800},
        "seven_day": {"utilization": 0.18, "resetsAt": 1791165600}}}}
with open(fake, "w") as f:
    f.write("#!/bin/sh\necho x >> %s\necho '{\"type\":\"system\"}'\necho '%s'\n"
            % (calls, json.dumps(event)))
os.chmod(fake, 0o755)
os.environ["CLAUDE_BIN"] = fake
os.makedirs(os.path.join(tmp, ".claude"))
with open(os.path.join(tmp, ".claude", ".credentials.json"), "w") as f:
    json.dump({"claudeAiOauth": {"accessToken": "t", "expiresAt": (time.time() + 3600) * 1000,
                                 "refreshTokenExpiresAt": (time.time() + 86400 * 30) * 1000}}, f)

loader = importlib.machinery.SourceFileLoader("accounts_status", STATUS)
spec = importlib.util.spec_from_loader("accounts_status", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m._profile = lambda tok: ({"email": "a@example.test", "org": "", "kind": "personal",
                           "tier": None}, None)
m._usage = lambda tok: {"err": "http-429"}

fails = 0
for label in ("first read", "second read within the TTL"):
    u = m._describe(m.LIVE, with_usage=True, is_live=True)["usage"]
    want = {"use5h": 44, "use7d": 18, "reset5h": "2026-09-29T02:10:00+00:00",
            "reset7d": "2026-10-05T02:00:00+00:00"}
    ok = u == want
    fails += not ok
    print(("ok  " if ok else "FAIL") + f" live 429 -> session reading ({label}): {u}")
n = len(open(calls).read().split())
ok = n == 1
fails += not ok
print(("ok  " if ok else "FAIL") + f" one Claude Code turn for two reads within the TTL ({n})")
sys.exit(1 if fails else 0)
