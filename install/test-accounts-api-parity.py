#!/usr/bin/env python3
"""Differential test: the platform account surface must answer exactly what devterm's
gate answers, for the same inputs.

WHY THIS SHAPE
    The account-list logic carries distinctions that were paid for in production and are
    easy to lose in a port: "no store" and "no data" are different operator states and
    only one resolves by waiting; the two localized pool labels alias to one canonical
    kind and unknowns are NOT guessed; usage carries an `age` because a number without
    one cannot be trusted. Reading the port and finding it plausible does not test any of
    that. Running BOTH implementations over the same inputs and requiring identical JSON
    does.

    It works because devterm's gate imports cleanly as a module — measured, not assumed
    (a module-level side effect would have made this impossible and sent the test back to
    eyeballing a diff).

    This suite dies with devterm's copy in step 5c. Until then it is what keeps the two
    from drifting while both exist.
"""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fails = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        fails.append(name)


def load(path, name, env):
    old = dict(os.environ)
    os.environ.update(env)
    for k, v in list(os.environ.items()):
        if v is None:
            del os.environ[k]
    try:
        # An explicit loader: bin/airlock-accounts-api has no .py suffix, and without one
        # spec_from_file_location returns None rather than raising.
        spec = importlib.util.spec_from_file_location(name, path, loader=SourceFileLoader(name, path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


TMP = tempfile.mkdtemp()
# A fake account CLI: both implementations shell out to one, and it must be the SAME
# output so any difference is the port's, not the fixture's.
CLI = os.path.join(TMP, "fake-accounts")
with open(CLI, "w") as f:
    f.write('''#!/usr/bin/env python3
import json, sys
print(json.dumps({
  "active": "a@example.test",
  "accounts": [
    {"email": "a@example.test", "kind": "personal"},
    {"email": "b@example.test", "kind": "\\uac1c\\uc778"},
    {"email": "c@example.test", "kind": "team"},
    {"email": "d@example.test", "kind": "somethingelse"},
    {"email": "e@example.test"},
  ],
}))
''')
os.chmod(CLI, 0o755)

STORE = os.path.join(TMP, "fleet.json")
with open(STORE, "w") as f:
    json.dump({
        "a@example.test|personal": {"usage": {"u5": 40, "u7": 10}, "observedAt": 1000,
                                    "holders": ["box1", "box2"]},
        "b@example.test|개인": {"usage": {"u5": 90, "u7": 50}, "observedAt": 2000},
        "c@example.test|team": {"observedAt": 3000},
    }, f)

CASES = [
    ("store as a file", {"STORE": STORE, "URL": ""}),
    ("no store at all", {"STORE": "", "URL": ""}),
    ("url only (unreachable)", {"STORE": "", "URL": "http://127.0.0.1:9/nope"}),
    ("missing store file", {"STORE": os.path.join(TMP, "absent.json"), "URL": ""}),
]

for label, c in CASES:
    gate = load(os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"), "dg_" + label.replace(" ", "_"),
                # DEVTERM_ACCOUNTS gates the CLI path: without it devterm holds
                # CLAUDE_SWITCH="" and answers an empty list, which would have made this
                # test compare the port against a disabled feature and call it a diff.
                {"DEVTERM_WEB": TMP, "DEVTERM_ACCOUNTS": "true", "DEVTERM_CLAUDE_SWITCH": CLI,
                 "DEVTERM_CLAUDE_STATUS": CLI,
                 "DEVTERM_FLEET_STORE": c["STORE"], "DEVTERM_FLEET_STORE_URL": c["URL"]})
    api = load(os.path.join(ROOT, "bin/airlock-accounts-api"), "api_" + label.replace(" ", "_"),
               {"AIRLOCK_ACCOUNTS_BIN": CLI,
                "AIRLOCK_HUB_FLEET_STORE": c["STORE"], "AIRLOCK_HUB_FLEET_STORE_URL": c["URL"]})

    import asyncio
    a = asyncio.new_event_loop().run_until_complete(gate._acct_list_with_usage())
    b = api._acct_list_with_usage()
    # `age` is derived from wall-clock at call time, so the two runs differ by
    # milliseconds. Compare it separately, within a second, and require it to be present
    # in exactly the same places — its absence is what "cannot be trusted" means.
    def split_age(d):
        ages = {}
        for acct in d.get("accounts", []):
            u = acct.get("usage")
            if isinstance(u, dict) and "age" in u:
                ages[acct.get("email")] = u.pop("age")
        return ages
    ages_a, ages_b = split_age(a), split_age(b)
    check(f"[{label}] account list is byte-identical to devterm's",
          json.dumps(a, sort_keys=True, ensure_ascii=False) == json.dumps(b, sort_keys=True, ensure_ascii=False),
          f"\n    devterm={json.dumps(a, sort_keys=True, ensure_ascii=False)}\n    platform={json.dumps(b, sort_keys=True, ensure_ascii=False)}")
    check(f"[{label}] `age` is present on exactly the same accounts",
          set(ages_a) == set(ages_b), f"devterm={sorted(ages_a)} platform={sorted(ages_b)}")
    check(f"[{label}] `age` agrees within a second",
          all(abs(ages_a[k] - ages_b[k]) <= 1 for k in ages_a), f"{ages_a} vs {ages_b}")

# The thresholds must be the same numbers, from the same single source.
gate = load(os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"), "dg_th", {"DEVTERM_WEB": TMP})
api = load(os.path.join(ROOT, "bin/airlock-accounts-api"), "api_th", {})
check("thresholds are identical (the frontend colours rows with these)",
      gate.USAGE_TH == api.USAGE_TH, f"{gate.USAGE_TH} vs {api.USAGE_TH}")
check("kind canonicalisation is identical for every label devterm knows",
      all(gate._claude_kind(k) == api._claude_kind(k)
          for k in ("personal", "개인", "team", "팀", "Personal", " team ", "unknown", "", None, 5)))

gate_mod = load(os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"), "gate_grade",
                {"DEVTERM_WEB": TMP})
api_mod = load(os.path.join(ROOT, "bin/airlock-accounts-api"), "api_grade", {})

# ---- 🔴 the grading logic is IDENTICAL, because only the concurrency was rewritten ----
# The codex usage cache could not be re-homed: devterm runs an asyncio task and cancels
# it when auth.json changes, and the platform service is a threaded stdlib server with no
# task to cancel. That rewrite was approved on one condition — that it stays confined to
# the concurrency and does not touch the judgement. This is the check that holds it there.
#
# _acct_alert_level decides what a person is told about their account: which axis wins at
# equal severity, whether a spent 5h window mutes a critical 7d one, whether a revoked
# Codex credential grades as crit. A rewrite that drifted here would change the warning
# a person acts on, silently, and nothing else in this suite would notice.
_GRADE_CASES = [
    (None, None, None, None, None),         # nothing known
    (0, 0, 30, 0, None),                    # all healthy
    (78, 0, 30, None, None), (88, 0, 30, None, None),   # 5h warn / crit boundaries
    (0, 88, 30, None, None), (0, 93, 30, None, None),   # 7d warn / crit boundaries
    (100, 0, 30, None, None),               # a spent 5h window is not a quiet state
    (100, 95, 30, None, None),              # ...and does not mute a critical 7d window
    (0, 0, 5, None, None), (0, 0, 1, None, None),       # refresh-token expiry
    (0, 0, 30, 95, None),                   # codex axis alone
    (0, 0, 30, None, "auth"),               # a revoked Codex credential
    (88, 0, 4, 95, "auth"),                 # every axis at once — priority decides
    (float("nan"), float("inf"), None, None, None),     # non-finite inputs
]
for _case in _GRADE_CASES:
    _a = gate_mod._acct_alert_level(*_case)
    _b = api_mod._acct_alert_level(*_case)
    check(f"grade parity for {_case}", _a == _b, f"devterm={_a} platform={_b}")
check("the grading thresholds are the same object shape",
      gate_mod.USAGE_TH == api_mod.USAGE_TH)

# ---- the route set itself, as a ratchet ----
# 🔴 Everything above compares the OUTPUT of one helper. Nothing was comparing the set of
# routes, so "8 of 18 moved" existed only in a prose note in the card — a route could be
# dropped, renamed, or quietly never ported and every check here would still pass. That
# is the same blind spot that left eight terminal POSTs unguarded while a guard test was
# green: a check scoped narrower than the thing it is trusted to cover.
#
# The list below is the contract. A route may leave it (a port lands) but nothing may
# join it without an edit here, and a route that is on it while actually implemented is
# also an error — a stale list stops being a measurement.
STILL_IN_DEVTERM = {
    ln.strip() for ln in
    open(os.path.join(ROOT, "install/account-routes-not-yet-moved.txt"))
    if ln.strip() and not ln.startswith("#")
}
# devterm's terminal line and its orca sidebar are a different surface and never move.
TERMINAL_ROUTES = {
    "/sessions", "/upload-image", "/upload-file", "/kill-session", "/list-dir",
    "/rename-session", "/tab-prefs", "/recent-images", "/recent-image", "/resolve",
    "/layout", "/pane", "/secret-put", "/secret-list", "/secret-del",
}

_gate_txt = open(os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py")).read()
_all = {r for r, _ in re.findall(
    r'elif path == b"(/[a-z0-9-]+)" and method == b"(GET|POST)":', _gate_txt)}
# Positive control: if the dispatch shape ever changes, this scan returns a small set and
# every comparison below would pass by looking at nothing.
check(f"the gate dispatch scan finds routes ({len(_all)} found)", len(_all) >= 25)
_gate_acct = {r for r in _all if r not in TERMINAL_ROUTES and not r.startswith("/orca")}
# 🔴 Classified by exclusion, not by keyword. The first version of this matched names
# containing "acct"/"codex"/"xai"/"claude" and silently dropped `/accounts` — the account
# list itself — which is how the card reported "18 routes" for days when there were 19.
check(f"the account line is {len(_gate_acct)} routes", len(_gate_acct) >= 19)

_api_txt = open(os.path.join(ROOT, "bin/airlock-accounts-api")).read()
_api = set(re.findall(r'self\.path == "(/[a-z0-9-]+)"', _api_txt))
for _grp in re.findall(r'self\.path in \(([^)]*)\)', _api_txt):
    _api |= set(re.findall(r'"(/[a-z0-9-]+)"', _grp))
check(f"the platform surface scan finds routes ({len(_api)} found)", len(_api) >= 5)

_missing = _gate_acct - _api - STILL_IN_DEVTERM
check("no account route is missing from the platform without being declared so"
      + (f" (undeclared gap: {', '.join(sorted(_missing))})" if _missing else ""),
      not _missing)
_stale = STILL_IN_DEVTERM & _api
check("the not-yet-moved list has no stale entries"
      + (f" (already implemented: {', '.join(sorted(_stale))})" if _stale else ""),
      not _stale)
_unknown = _api - _gate_acct
check("the platform serves no route the gate does not have"
      + (f" (extra: {', '.join(sorted(_unknown))})" if _unknown else ""),
      not _unknown)
print(f"     route parity: {len(_api)}/{len(_gate_acct)} moved, "
      f"{len(STILL_IN_DEVTERM)} declared still in devterm")

if fails:
    print(f"\n{len(fails)} check(s) failed")
    sys.exit(1)
print("\nall account surface parity checks passed")
