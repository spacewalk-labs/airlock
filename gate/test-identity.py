#!/usr/bin/env python3
"""Tests for gate/identity.py (T3, backend-side). No live services."""
import importlib
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

FAILS = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)

def reload_with(env):
    for k in ("AIRLOCK_IDENTITY_HEADER", "AIRLOCK_OWNER", "AIRLOCK_COLLABORATORS"):
        os.environ.pop(k, None)
    os.environ.update(env)
    import identity
    return importlib.reload(identity)

BASE = {
    "AIRLOCK_IDENTITY_HEADER": "Tailscale-User-Login",
    "AIRLOCK_OWNER": "me@example.com",
    "AIRLOCK_COLLABORATORS": "friend@example.com, other@example.com",
}
idn = reload_with(BASE)

# exact-case header
check("login: exact header", idn.login({"Tailscale-User-Login": "me@example.com"}) == "me@example.com")
# lowercased header key (proxies vary)
check("login: lowercase key", idn.login({"tailscale-user-login": "Me@Example.com"}) == "me@example.com")
# absent header -> "" -> denied
check("login: absent -> empty", idn.login({"X-Other": "z"}) == "")

# owner allowed
check("allow: owner", idn.is_allowed("me@example.com") is True)
# collaborator allowed (case-insensitive, trimmed)
check("allow: collaborator", idn.is_allowed("FRIEND@example.com") is True)
# stranger denied
check("deny: stranger", idn.is_allowed("evil@example.com") is False)
# empty denied (forged/stripped header)
check("deny: empty", idn.is_allowed("") is False)

# owner_only excludes collaborators
check("owner_only: owner ok", idn.is_allowed("me@example.com", owner_only=True) is True)
check("owner_only: collaborator denied", idn.is_allowed("friend@example.com", owner_only=True) is False)

# check() convenience
allowed, who = idn.check({"Tailscale-User-Login": "friend@example.com"})
check("check(): returns (allowed, login)", allowed is True and who == "friend@example.com")
allowed2, _ = idn.check({"Tailscale-User-Login": "friend@example.com"}, owner_only=True)
check("check(): owner_only path", allowed2 is False)

# missing header-name env -> loud failure (not silent allow)
idn2 = reload_with({"AIRLOCK_OWNER": "me@example.com"})
try:
    idn2.login({"Tailscale-User-Login": "me@example.com"})
    check("fail-loud: missing AIRLOCK_IDENTITY_HEADER raises", False)
except RuntimeError:
    check("fail-loud: missing AIRLOCK_IDENTITY_HEADER raises", True)

print("---")
print(f"failed={len(FAILS)}")
sys.exit(1 if FAILS else 0)
