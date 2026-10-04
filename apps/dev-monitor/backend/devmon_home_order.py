"""Owner-scoped, device-independent order for the hub launcher.

This file is the only place that decides what a submitted order means.  The
client sends only the rows it drew, so a hidden id — one whose app is not
currently installed, or a link that has no source row this reader can see —
never appears in the request.  Dropping it here would delete the owner's
placement of an app they still have, so `normalize` re-attaches every id the
saved copy holds and appends ids the install record names but the saved copy
does not yet.  A newly installed app therefore lands at the end without a
migration, and an uninstalled one keeps its slot.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def default_root() -> Path:
    return Path(__file__).resolve().parents[3]


def default_state() -> Path:
    return Path(os.environ.get("AIRLOCK_HOME_ORDER_STATE",
                               "~/.local/state/airlock/home-order.json")).expanduser()


def _is_line(item: Any) -> bool:
    """A named divider is the only non-id row the format has."""
    return isinstance(item, dict) and isinstance(item.get("line"), str)


def normalize(order: Any, installed: list[str], stored: Any = None) -> list[str | dict]:
    """One answer for every read and write: what this box should draw, in order.

    `order` is what the caller supplied — a fresh client's visible rows, or the
    saved copy on a read.  `installed` is the install record's ids.  `stored` is
    the saved copy as it is on disk, and the only reason an id can come back
    that the caller never mentioned.
    """
    wanted = order if isinstance(order, list) else []
    out: list[str | dict] = []
    for item in wanted:
        if _is_line(item):
            out.append({"line": item["line"]})
        elif isinstance(item, str) and item not in out:
            out.append(item)
    for item in (stored if isinstance(stored, list) else []):
        # Only ids are carried back, and only once. A line the caller dropped on
        # purpose stays dropped: unlike an id, it has no other record of where
        # the owner put it.
        if isinstance(item, str) and item not in out:
            out.append(item)
    for app_id in (installed if isinstance(installed, list) else []):
        if app_id not in out:
            out.append(app_id)
    return out


def _stored(path: Path) -> list:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return []
    if not isinstance(value, dict):
        return []
    order = value.get("order")
    return order if isinstance(order, list) else []


def read_order(installed: list[str], state: Path | None = None) -> list[str | dict]:
    path = state or default_state()
    stored = _stored(path)
    return normalize(stored, installed, stored)


def write_order(order: Any, installed: list[str],
                state: Path | None = None) -> list[str | dict]:
    path = state or default_state()
    normal = normalize(order, installed, _stored(path))
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