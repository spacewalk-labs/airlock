#!/usr/bin/env python3
"""The Codex reading keeps moving with nobody watching.

Every other Codex refresh in the gate is demand-driven: it happens because a panel
asked. So on a box where nobody opens the Codex section the number just stops — the
observed case had no state file at all for the 7.5 hours between a gate restart and the
first request. The Claude rows never had this problem because their collector is a
systemd timer that does not care whether anyone is looking. `_codex_usage_sweeper` is
that timer, and these are the three things it has to get right: it must keep asking,
one bad reading must not end it for the life of the process, and it must not pass
`force` (that would turn a dead Codex login into a probe every CODEX_USAGE_RETRY
seconds instead of one per sweep).

Run: python3 apps/devterm/test-codex-usage-sweep.py
"""
import asyncio, importlib.util, os, re, sys

# Captured before anything stubs it: the fake sleep below still has to actually yield,
# and reaching for asyncio.sleep by name at that point would find the stub itself.
REAL_SLEEP = asyncio.sleep

os.environ.setdefault("AIRLOCK_OWNER", "owner@example.com")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails, checks = [], 0


def check(name, cond):
    global checks
    checks += 1
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def run_sweeper(fake_cached, sweeps, sweep_period=0.0):
    """Drive the real sweeper against a stubbed reading, stopping after `sweeps` calls.

    The sleep is stubbed too: the point under test is the loop's shape, and a test that
    waits out CODEX_USAGE_SWEEP would take 25 minutes to prove it."""
    calls, slept = [], []
    done = asyncio.Event()

    async def cached(*a, **kw):
        calls.append((a, kw))
        if len(calls) >= sweeps:
            done.set()
        return fake_cached(len(calls))

    async def sleep(seconds):
        slept.append(seconds)
        await REAL_SLEEP(sweep_period)

    async def drive():
        task = asyncio.create_task(g._codex_usage_sweeper())
        try:
            await asyncio.wait_for(done.wait(), timeout=5)
        finally:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        return task

    real_cached = g._codex_usage_cached
    g._codex_usage_cached = cached
    # The sweeper reaches asyncio.sleep through the module's own `asyncio` binding.
    g.asyncio.sleep = sleep
    try:
        task = asyncio.run(drive())
    finally:
        g._codex_usage_cached = real_cached
        g.asyncio.sleep = REAL_SLEEP
    return calls, slept, task


# ---- it keeps asking -------------------------------------------------------------
calls, slept, task = run_sweeper(lambda n: {"use7d": 40}, sweeps=3)
check("the sweeper asks again after each sleep, not once at startup", len(calls) >= 3)
check("it sleeps between readings", len(slept) >= 2)
check("it sleeps for CODEX_USAGE_SWEEP",
      all(s == g.CODEX_USAGE_SWEEP for s in slept))
check("CODEX_USAGE_SWEEP is tied to the cache TTL, so a sweep is never a wasted spawn "
      "and the panel never opens on a stale value",
      g.CODEX_USAGE_SWEEP == g.CODEX_USAGE_TTL)

# ---- it forces, and that is the whole point --------------------------------------
# The first version of this file asserted the opposite, on the theory that force would
# bypass _codex_usage_refresh_due's backoff and hammer a box whose Codex credential was
# revoked. That theory was wrong twice over. It cannot hammer: the sweeper's own period
# IS the rate limit, and 300s is far slower than the 30s backoff being bypassed. And
# without force the sweep quietly does half its job — see the phase test below.
check("the sweep forces its refresh",
      all(kw.get("force") is True for a, kw in calls))

# ---- one bad reading does not end the loop ---------------------------------------
def blow_up_once(n):
    if n == 1:
        raise RuntimeError("probe exploded")
    return {"use7d": 40}


calls, slept, task = run_sweeper(blow_up_once, sweeps=3)
check("a raising reading does not kill the sweeper — it sweeps again", len(calls) >= 3)

# ...but cancellation must still get through, or shutdown hangs on it.
cancelled = {"ok": False}


async def cancel_propagates():
    async def cached(*a, **kw):
        raise asyncio.CancelledError()

    real = g._codex_usage_cached
    g._codex_usage_cached = cached
    try:
        task = asyncio.create_task(g._codex_usage_sweeper())
        try:
            await asyncio.wait_for(task, timeout=5)
        except asyncio.CancelledError:
            cancelled["ok"] = True
        except asyncio.TimeoutError:
            cancelled["ok"] = False
    finally:
        g._codex_usage_cached = real


asyncio.run(cancel_propagates())
check("CancelledError is re-raised, not swallowed by the catch-all "
      "(otherwise gate shutdown waits out a sweep that will never end)",
      cancelled["ok"])


# ---- the phase trap: a sweep that declines its own tick ---------------------------
# Sleeping exactly CODEX_USAGE_TTL means the next tick finds the value a hair UNDER the
# TTL (the probe itself took time), so _codex_usage_refresh_due declines and the refresh
# slips to the tick after — 2x the period, with the value stale for half of it. This
# drives the real cache path on a fake clock and measures when probes actually fire.
def sweep_probe_times(ticks_wanted=4):
    clock = [1000.0]
    probes, ticks = [], []

    async def probe(_args):
        probes.append(clock[0])
        clock[0] += 1.0                 # a real app-server probe is not instantaneous
        return {"use7d": 40, "stale": False}

    async def sleep(seconds):
        # The fake clock makes every sleep instantaneous, so the loop would run
        # thousands of times before the driver noticed. Park once we have enough.
        if len(ticks) >= ticks_wanted:
            await REAL_SLEEP(3600)      # cancelled by the driver
            return
        ticks.append(clock[0])
        clock[0] += seconds
        await REAL_SLEEP(0)

    saved = (g.time.time, g._probe_json, g._codex_auth_mtime,
             g._codex_usage_state_save, g.asyncio.sleep)
    g.time.time = lambda: clock[0]
    g._probe_json = probe
    g._codex_auth_mtime = lambda: 12345
    g._codex_usage_state_save = lambda: True
    g.asyncio.sleep = sleep
    g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                authMtime=12345, task=None)

    async def drive():
        task = asyncio.create_task(g._codex_usage_sweeper())
        while len(ticks) < ticks_wanted:
            await REAL_SLEEP(0.01)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    try:
        asyncio.run(drive())
    finally:
        (g.time.time, g._probe_json, g._codex_auth_mtime,
         g._codex_usage_state_save, g.asyncio.sleep) = saved
        g._codex_usage_cache.update(valueAt=0.0, lastTryAt=0.0, payload=None,
                                    authMtime=None, task=None)
    # The parked final iteration probes once more against a frozen clock; that last
    # entry is a harness artefact, not a sweep interval.
    return probes[:ticks_wanted]


probe_times = sweep_probe_times()
gaps = [round(b - a) for a, b in zip(probe_times, probe_times[1:])]
check("every sweep tick actually takes a reading — the gap is one period, not two "
      f"(gaps {gaps}, period {g.CODEX_USAGE_SWEEP})",
      len(gaps) >= 2 and all(gap <= g.CODEX_USAGE_SWEEP + 5 for gap in gaps))
check("...and the value therefore never ages past the TTL between readings",
      all(gap <= g.CODEX_USAGE_TTL + 5 for gap in gaps))


# ---- force belongs to the sweeper alone -------------------------------------------
# The sweeper may force because its own period is the rate limit. A REQUEST path may
# not: requests arrive whenever a panel or a fleet collector asks, so forcing there
# bypasses the CODEX_USAGE_RETRY backoff and turns every poll into an app-server spawn.
# This actually happened while writing this file — a `sed` aimed at the sweeper also hit
# `_serve_acct_alert`, and only an independent review caught it before merge. Checked by
# reading the source, because the defect was a stray edit rather than a wrong idea, and
# a stray edit lands wherever the pattern matched.
gate_source = open(os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"),
                   encoding="utf-8").read()
forced = re.findall(r"_codex_usage_cached\([^)]*force\s*=\s*True[^)]*\)", gate_source)
check(f"exactly one call site forces a Codex refresh (found {len(forced)})",
      len(forced) == 1)
sweeper_body = gate_source.split("async def _codex_usage_sweeper(")[-1]
sweeper_body = sweeper_body.split(chr(10) + "async def ")[0]
check("...and it is the sweeper's, not a request handler's",
      bool(forced) and forced[0] in sweeper_body)

print()
print(f"codex usage sweep: {checks - len(fails)} passed, {len(fails)} failed")
sys.exit(1 if fails else 0)
