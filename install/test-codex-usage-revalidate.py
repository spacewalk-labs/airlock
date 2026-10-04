#!/usr/bin/env python3
"""/codex-usage honours `X-Airlock-Revalidate: wait` once the remembered value expires.

Without the header an expired value is answered at once with `stale: true` while the
refresh runs behind it (the panel's first paint). With it — the fleet collector, which
polls slower than the TTL — the answer waits for that refresh, so a box nobody watches
does not read stale forever. A refresh that fails or overruns still answers the old
value marked stale, never an empty timeout payload.

Offline: the module is loaded from bin/, `_probe` is a fake, state lives in a temp dir.
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.path.join(os.path.dirname(HERE), "bin", "airlock-accounts-api")
failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f": {detail}"))
    if not cond:
        failures.append(name)


with tempfile.TemporaryDirectory() as tmp:
    os.environ["AIRLOCK_STATE_DIR"] = tmp
    os.environ["AIRLOCK_CODEX_AUTH"] = os.path.join(tmp, "auth.json")
    with open(os.environ["AIRLOCK_CODEX_AUTH"], "w") as f:
        f.write("{}")
    loader = importlib.machinery.SourceFileLoader("accounts_api", API)
    api = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(api)

    probe = {"use7d": 3, "delay": 0.3, "status": 200}

    def fake_probe(args=()):
        time.sleep(probe["delay"])
        return probe["status"], {"use7d": probe["use7d"], "observedAt": "new"}

    api._probe = fake_probe
    api._codex_auth_mtime = lambda: 1      # one stable login generation
    api.CODEX_USAGE_WAIT = 2

    def expire(value):
        # a remembered reading older than the TTL, for the current login
        with api._cache_lock:
            api._codex_usage_cache.update(
                payload={"use7d": value, "observedAt": "old"}, refreshing=False,
                valueAt=time.time() - api.CODEX_USAGE_TTL - 60, lastTryAt=0.0,
                authMtime=api._codex_auth_mtime())

    def settle():
        with api._cache_lock:
            api._codex_refresh_done.wait_for(
                lambda: not api._codex_usage_cache["refreshing"], timeout=5)

    expire(83)
    out = api._codex_usage_cached(wait=True)
    check("no-header answers the old value at once", out["use7d"] == 83 and out["stale"] is True, out)
    settle()

    expire(83)
    out = api._codex_usage_cached(wait=True, revalidate=True)
    check("revalidate waits for the fresh value", out["use7d"] == 3 and out["stale"] is False, out)

    expire(83)
    probe.update(status=500)
    out = api._codex_usage_cached(wait=True, revalidate=True)
    check("failed refresh keeps the old value, marked stale",
          out["use7d"] == 83 and out["stale"] is True, out)

    expire(83)
    probe.update(status=200, delay=3)
    out = api._codex_usage_cached(wait=True, revalidate=True)
    check("overrunning refresh answers the old value, not a timeout payload",
          out["use7d"] == 83 and out["stale"] is True and out.get("err") != "timeout", out)
    settle()

sys.exit(1 if failures else 0)
