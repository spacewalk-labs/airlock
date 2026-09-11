"""Owner-scoped, device-independent order for the hub launcher.

The manifest remains the authority on which apps exist.  This small state file only
remembers the owner's preferred ordering, and is normalised against the manifest on
every read and write so a removed id cannot linger and a newly installed app appears
at the end without a migration.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any


def default_root() -> Path:
    return Path(__file__).resolve().parents[3]


def default_state() -> Path:
    return Path(os.environ.get("AIRLOCK_HOME_ORDER_STATE",
                               "~/.local/state/airlock/home-order.json")).expanduser()


def _configured_order(base: Path) -> list[str]:
    """Read only configured app keys after the canonical reader reports mismatch.

    It resolves no app values and is reachable only after the real CLI has parsed the
    config far enough to identify the exact package lock refusal. Home-order state must
    remain writable while that package awaits reapproval, so its temporary membership
    set comes from the raw top-level keys.
    """
    configured = os.environ.get("AIRLOCK_CONFIG")
    if configured:
        path = Path(configured).expanduser()
        if not path.is_absolute():
            path = base / path
    else:
        path = base / "airlock.toml"
        for parent in [base, *base.parents]:
            candidate = parent / "airlock.toml"
            if candidate.exists():
                path = candidate
                break
    try:
        with path.resolve().open("rb") as handle:
            document = tomllib.load(handle)
    except (OSError, ValueError) as exc:
        raise RuntimeError("cannot read app keys during package lock mismatch") from exc
    apps = document.get("apps")
    if not isinstance(apps, dict):
        raise RuntimeError("config apps table is unavailable during package lock mismatch")
    return [app for app in apps if app not in ("hub", "feedback")]


def manifest_order(root: Path | None = None) -> list[str]:
    """Read the manifest's resolved order through its existing public CLI."""
    base = root or default_root()
    env = os.environ.copy()
    for name in ("AIRLOCK_CONFIG_SNAPSHOT", "AIRLOCK_CONFIG_SNAPSHOT_SHA256",
                 "AIRLOCK_INSTALL_PKG_INFO_SHA256"):
        env.pop(name, None)
    try:
        result = subprocess.run(
            [sys.executable, str(base / "bin" / "airlock-config"), "apps"],
            cwd=str(base), env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("airlock-config apps failed") from exc
    if result.returncode:
        if re.search(
                r"^airlock-config: package '[a-z0-9][a-z0-9-]{0,31}': "
                r"package lock digest mismatch(?:\n|\Z)", result.stderr,
                re.MULTILINE):
            return _configured_order(base)
        raise RuntimeError("airlock-config apps failed: " + result.stderr.strip())
    # hub is the launcher, rather than a launcher tile; feedback has its own fixed
    # surface beneath the launcher.  These match hub/index.html's tile input.
    return [app for app in result.stdout.splitlines()
            if app and app not in ("hub", "feedback")]


def normalize(order: Any, manifest: list[str]) -> list[str]:
    """Keep known ids once, then append every currently enabled app in manifest order."""
    wanted = order if isinstance(order, list) else []
    known = set(manifest)
    out: list[str] = []
    for app in wanted:
        if isinstance(app, str) and app in known and app not in out:
            out.append(app)
    out.extend(app for app in manifest if app not in out)
    return out


def read_order(manifest: list[str], state: Path | None = None) -> list[str]:
    path = state or default_state()
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        value = {}
    return normalize(value.get("order") if isinstance(value, dict) else None, manifest)


def write_order(order: Any, manifest: list[str], state: Path | None = None) -> list[str]:
    path = state or default_state()
    normal = normalize(order, manifest)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".home-order.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump({"order": normal}, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return normal
