#!/usr/bin/env python3
"""Verify the one live dev-monitor cutover canary without mutating its state."""

from __future__ import annotations

import argparse
import ipaddress
import json
import sqlite3
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class VerificationError(RuntimeError):
    pass


REQUIRED_COLUMNS = {
    "cards": {"card_id", "occurrence_count"},
    "occurrences": {"card_id"},
    "deliveries": {"id", "card_id", "channel", "status", "sent_at"},
    "approvals": {"card_id", "plan_sha256", "issued_at", "used_at"},
    "runs": {
        "run_id", "card_id", "plan_sha256", "status", "exit_code", "created_at",
        "ended_at",
    },
}


def _readonly_connection(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise VerificationError(f"database is not a regular file: {path}")
    uri = "file:" + urllib.parse.quote(str(path.resolve()), safe="/") + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as exc:
        raise VerificationError(f"cannot open database read-only: {exc}") from exc
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def _check_schema(conn: sqlite3.Connection) -> None:
    for table, required in REQUIRED_COLUMNS.items():
        columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        missing = sorted(required - columns)
        if missing:
            raise VerificationError(
                f"database schema missing {table} columns: {', '.join(missing)}")


def _read_canary(conn: sqlite3.Connection, card_id: str) -> dict[str, object]:
    _check_schema(conn)
    integrity = conn.execute("PRAGMA integrity_check").fetchone()
    if integrity is None or integrity[0] != "ok":
        raise VerificationError("database integrity_check is not ok")

    card = conn.execute(
        "SELECT card_id, occurrence_count FROM cards WHERE card_id=?", (card_id,)
    ).fetchone()
    if card is None:
        raise VerificationError(f"canary card not found: {card_id}")
    occurrences = conn.execute(
        "SELECT COUNT(*) FROM occurrences WHERE card_id=?", (card_id,)
    ).fetchone()[0]
    if occurrences < 1 or card["occurrence_count"] < 1:
        raise VerificationError("canary has no recorded occurrence")

    delivery = conn.execute(
        "SELECT channel, status, sent_at FROM deliveries "
        "WHERE card_id=? AND channel IN ('slack-urgent','slack-routine') "
        "ORDER BY id DESC LIMIT 1",
        (card_id,),
    ).fetchone()
    if delivery is None or delivery["status"] != "sent" or delivery["sent_at"] is None:
        raise VerificationError("canary latest Slack delivery is not terminal sent")

    run = conn.execute(
        "SELECT run_id, plan_sha256, status, exit_code, created_at, ended_at "
        "FROM runs WHERE card_id=? ORDER BY created_at DESC, run_id DESC LIMIT 1",
        (card_id,),
    ).fetchone()
    if run is None:
        raise VerificationError("canary has no run")
    if run["status"] != "done" or run["exit_code"] != 0 or run["ended_at"] is None:
        raise VerificationError("canary latest run is not terminal succeeded")
    approval = conn.execute(
        "SELECT 1 FROM approvals WHERE card_id=? AND plan_sha256=? "
        "AND used_at= ? AND issued_at<=used_at LIMIT 1",
        (card_id, run["plan_sha256"], run["created_at"]),
    ).fetchone()
    if approval is None:
        # redeem_approval writes used_at and run.created_at from the same instant in one
        # transaction. Equality avoids blessing a later retry with an older used nonce for
        # an identical plan, which a mere card/plan match cannot distinguish.
        raise VerificationError("canary latest run has no matching used approval")

    return {
        "card_id": card["card_id"],
        "occurrences": occurrences,
        "occurrence_count": card["occurrence_count"],
        "slack": {
            "channel": delivery["channel"],
            "status": delivery["status"],
            "sent_at": delivery["sent_at"],
        },
        "run": {
            "run_id": run["run_id"],
            "status": run["status"],
            "exit_code": run["exit_code"],
            "ended_at": run["ended_at"],
        },
    }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


def _read_health(url: str, timeout: float) -> dict[str, object]:
    parsed = urllib.parse.urlsplit(url)
    try:
        host = ipaddress.ip_address(parsed.hostname or "")
    except ValueError as exc:
        raise VerificationError("health URL host must be a loopback IP literal") from exc
    if parsed.scheme != "http" or not host.is_loopback:
        raise VerificationError("health URL must be loopback HTTP")
    if parsed.username or parsed.password or parsed.fragment:
        raise VerificationError("health URL must not contain credentials or a fragment")
    try:
        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(url, timeout=timeout) as response:
            if response.status != 200:
                raise VerificationError(f"health endpoint returned HTTP {response.status}")
            health = json.load(response)
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            raise VerificationError("health endpoint redirect is refused") from exc
        raise VerificationError(f"health endpoint returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise VerificationError(f"cannot read health endpoint: {exc}") from exc
    if not isinstance(health, dict):
        raise VerificationError("health response is not an object")

    if health.get("messages") != "on":
        raise VerificationError("message console is not on")
    if health.get("token_freshness") != "on":
        raise VerificationError("token freshness is not on")
    lanes = health.get("message_lanes")
    if not isinstance(lanes, dict):
        raise VerificationError("health response has no message_lanes object")
    for lane in ("slack-urgent", "slack-routine"):
        state = lanes.get(lane)
        if not isinstance(state, dict) or state.get("worker_state") != "on":
            raise VerificationError(f"{lane} worker is not on")
    email = lanes.get("email")
    if not isinstance(email, dict) or email.get("worker_state") != "off: no transport configured":
        raise VerificationError("email worker is not explicitly unconfigured")
    return {
        "messages": health["messages"],
        "token_freshness": health["token_freshness"],
        "slack_urgent": lanes["slack-urgent"]["worker_state"],
        "slack_routine": lanes["slack-routine"]["worker_state"],
        "email": email["worker_state"],
    }


def verify(db: Path, card_id: str, health_url: str, timeout: float) -> dict[str, object]:
    card_id = card_id.strip()
    if not card_id:
        raise VerificationError("canary id must not be empty")
    with _readonly_connection(db) as conn:
        canary = _read_canary(conn, card_id)
    return {"ok": True, "canary": canary, "health": _read_health(health_url, timeout)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--canary-id", required=True)
    parser.add_argument("--health-url", required=True)
    parser.add_argument("--timeout", type=float, default=6.0)
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        result = verify(args.db, args.canary_id, args.health_url, args.timeout)
    except (VerificationError, sqlite3.Error) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
