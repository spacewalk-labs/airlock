"""Airlock identity helper (backend-side, defense-in-depth).

The nginx gate is the PRIMARY authentication (it sits behind `tailscale serve`,
which strips client-supplied identity headers and injects the authenticated
`Tailscale-User-Login`). Backends import this to independently re-check the
identity after the gate — a second layer, NOT a substitute for the gate or for
binding to loopback. See SECURITY.md.

Config comes from the environment (set by `airlock-config env <app>`):
  AIRLOCK_IDENTITY_HEADER   e.g. "Tailscale-User-Login"  (fixed for tailscale)
  AIRLOCK_OWNER             e.g. "me@example.com"
  AIRLOCK_COLLABORATORS     comma-separated logins (optional)
"""
from __future__ import annotations

import os
from typing import Iterable


def header_name() -> str:
    h = os.environ.get("AIRLOCK_IDENTITY_HEADER", "").strip()
    if not h:
        raise RuntimeError(
            "AIRLOCK_IDENTITY_HEADER is not set — run the backend via the "
            "airlock env (see airlock-config env <app>)."
        )
    return h


def _norm(v: str) -> str:
    return (v or "").strip().lower()


def owner() -> str:
    return _norm(os.environ.get("AIRLOCK_OWNER", ""))


def allow_set() -> set[str]:
    s = {owner()}
    for c in os.environ.get("AIRLOCK_COLLABORATORS", "").split(","):
        c = _norm(c)
        if c:
            s.add(c)
    s.discard("")
    return s


def login(headers) -> str:
    """Extract the caller login from a headers mapping, case-insensitively.

    Accepts anything with a `.get` (dict, http.server BaseHTTPRequestHandler
    .headers, WSGI-style). Returns "" when absent.
    """
    name = header_name()
    getter = getattr(headers, "get", None)
    if getter is not None:
        val = getter(name)
        if val is None:
            val = getter(name.lower())
        if val is None and hasattr(headers, "items"):
            low = {str(k).lower(): v for k, v in headers.items()}
            val = low.get(name.lower())
        return _norm(val if val is not None else "")
    return ""


def is_allowed(login_value: str, *, owner_only: bool = False) -> bool:
    lv = _norm(login_value)
    if not lv:
        return False
    if owner_only:
        return lv == owner()
    return lv in allow_set()


def check(headers, *, owner_only: bool = False) -> tuple[bool, str]:
    """Convenience: (allowed, login) for a request's headers."""
    lv = login(headers)
    return is_allowed(lv, owner_only=owner_only), lv
