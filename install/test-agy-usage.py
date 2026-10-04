#!/usr/bin/env python3
"""agy quota: the screen parser and the account surface's stored-first, 20-minute rule.

No agy is started. The parser gets the real /usage screen text captured on a box
(2026-09-15), and the route is exercised with a stand-in probe.
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, time, threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(name, cond, observed=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" — {observed}"))
    if not cond:
        failures.append(name)


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


SCREEN = """
└ Models & Quota
  Account: someone@example.com
GEMINI MODELS
  Models within this group: Gemini Flash, Gemini Pro
  Weekly Limit Remaining
    [██████████] 99.91%
    100% remaining · Refreshes in 166h 3m
  Five Hour Limit Remaining
    [█████████░] 98.70%
    99% remaining · Refreshes in 3h 3m
CLAUDE AND GPT MODELS
  Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
  Weekly Limit Remaining
    [██████████] 99.92%
    100% remaining · Refreshes in 166h 13m
  Five Hour Limit Remaining
    [██████████] 99.60%
    100% remaining · Refreshes in 13m
"""

probe = load("agy_usage", os.path.join(ROOT, "bin", "airlock-agy-usage"))
now = 1_000_000.0
r = probe.parse(SCREEN, now)
check("parser: account and both groups", r and r["account"] == "someone@example.com"
      and [g["name"] for g in r["groups"]] == ["GEMINI MODELS", "CLAUDE AND GPT MODELS"], r)
g = r["groups"][0] if r else {}
check("parser: remaining percentages", g.get("weeklyRemaining") == 99.91 and g.get("fiveHourRemaining") == 98.70, g)
check("parser: refresh times become absolute", g.get("fiveHourResetAt") == int(now + 3 * 3600 + 3 * 60), g)
check("parser: minutes-only refresh", r and r["groups"][1]["fiveHourResetAt"] == int(now + 13 * 60), r)
check("parser: a partial screen is no reading, never a guess",
      probe.parse(SCREEN.split("Five Hour Limit Remaining")[0], now) is None)
check("parser: an unrelated screen is no reading", probe.parse("Welcome to the Antigravity CLI", now) is None)
# A spent weekly limit replaces the 5-hour bar with a "Disabled:" line (measured
# 2026-09-25). That used to fail the whole screen, so the reading froze forever.
SPENT = SCREEN.split("CLAUDE AND GPT MODELS")[0] + """CLAUDE AND GPT MODELS
  Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
  Weekly Limit Remaining
    [░░░░░░░░░░] 0.00%
    Refreshes in 115h 48m
  Five Hour Limit Remaining
    Disabled: You have hit your weekly limit, the 5-hour limit does not currently apply.
"""
r2 = probe.parse(SPENT, now)
g2 = r2["groups"][1] if r2 and len(r2["groups"]) == 2 else {}
# An untouched window shows "Quota available" and may lose its "%" (2026-09-26).
FULL = SCREEN.split("CLAUDE AND GPT MODELS")[0] + """CLAUDE AND GPT MODELS
  Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
  Weekly Limit Remaining
    [██████████░░░░░] 55.32%
    Refreshes in 79h 19m
  Five Hour Limit Remaining
    [██████████████████████████████████████████████████] 100.00
    Quota available
"""
r3 = probe.parse(FULL, now)
g3 = r3["groups"][1] if r3 and len(r3["groups"]) == 2 else {}
check("parser: an untouched window reads as full, reset now",
      g3.get("weeklyRemaining") == 55.32 and g3.get("fiveHourRemaining") == 100.0
      and g3.get("fiveHourResetAt") == int(now), r3)
check("parser: a spent weekly limit reads as spent until the weekly reset",
      g2.get("weeklyRemaining") == 0.0 and g2.get("fiveHourRemaining") == 0.0
      and g2.get("fiveHourResetAt") == g2.get("weeklyResetAt") == int(now + 115 * 3600 + 48 * 60), r2)

state = tempfile.mkdtemp()
os.environ["AIRLOCK_STATE_DIR"] = state
os.environ.pop("AIRLOCK_AGY_BIN", None)
api = load("accounts_api", os.path.join(ROOT, "bin", "airlock-accounts-api"))
check("route: a box without agy says disabled", api._agy_usage_payload() == {"enabled": False})

api.AGY_BIN = "/bin/true"
api.AGY_USAGE_PROBE = "/bin/true"
runs = []
def fake_refresh():
    runs.append(time.time())
    with api._cache_lock:
        api._agy_usage.update(refreshing=False, lastErr=None)
api._agy_usage_refresh = fake_refresh
os.makedirs(os.path.dirname(api.AGY_USAGE_STATE), exist_ok=True)

def store(age):
    rec = dict(r, observedAt=int(time.time() - age))
    with open(api.AGY_USAGE_STATE, "w") as f:
        json.dump(rec, f)

store(5 * 60)
p = api._agy_usage_payload(); time.sleep(0.2)
check("route: a reading under 20 minutes is served without re-reading",
      p.get("account") == "someone@example.com" and not runs and p["refreshing"] is False, (p, runs))
store(25 * 60)
p = api._agy_usage_payload(); time.sleep(0.2)
check("route: an older reading is served at once and re-read in the background",
      p.get("groups") and p["refreshing"] is True and len(runs) == 1, (p, runs))
os.remove(api.AGY_USAGE_STATE)
p = api._agy_usage_payload(); time.sleep(0.2)
check("route: no reading yet starts a read and says so", "groups" not in p and len(runs) == 2, (p, runs))

diag = load("agy_usage", os.path.join(ROOT, "bin", "airlock-agy-usage"))
check("diag: exact allowlist key set",
      set(diag.DIAG_FIELDS) == {"sent", "elapsedMs", "bytesRead", "sawUsageHeader",
                                "groupHeaderCount", "weeklyCount", "fiveHourCount",
                                "refreshCount", "trustPromptSeen", "exitReason"},
      diag.DIAG_FIELDS)
# Adversarial inputs: screen text, emails, paths and env-shaped values must not
# survive in the snapshot — counts and stage literals only.
snap = diag.diag_snapshot(True, 45123, 88123, True, 2, 4, 4, 8, True, "ok")
blob = json.dumps(snap)
check("diag: no screen text, account, path or env in snapshot",
      "@" not in blob and "GEMINI" not in blob and "/" not in blob
      and "MODELS" not in blob and "ok" in blob, blob)
snap2 = diag.diag_snapshot(False, 0, 0, False, 0, 0, 0, 0, False,
                           "timeout-before-send")
check("diag: failure stages stay literal",
      snap2["exitReason"] == "timeout-before-send" and snap2["sent"] is False,
      snap2)

print(f"---\nagy-usage: {len(failures)} failed")
sys.exit(1 if failures else 0)
