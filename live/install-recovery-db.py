#!/usr/bin/env python3
"""Seed and observe the disposable install-recovery messages database.

This helper is intentionally usable only on a caller-named file.  The live driver
contains the disposable-root checks; this file supplies deterministic SQLite bytes
and a stable online-backup observation without importing test fixtures.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat


LEGACY_SCHEMA = """
CREATE TABLE occurrences(event_id TEXT PRIMARY KEY, card_id TEXT NOT NULL,
 group_key TEXT NOT NULL, payload_json TEXT NOT NULL, received_at TEXT NOT NULL);
CREATE TABLE cards(card_id TEXT PRIMARY KEY, group_key TEXT NOT NULL, source TEXT NOT NULL,
 kind TEXT NOT NULL, urgency TEXT NOT NULL, title TEXT NOT NULL, body TEXT,
 action_json TEXT, link_json TEXT, action_digest TEXT, created_at TEXT NOT NULL,
 received_at TEXT NOT NULL, read_at TEXT, slack_sent_at TEXT, pinned INTEGER NOT NULL DEFAULT 0,
 archived_at TEXT, dismissed_at TEXT, occurrence_count INTEGER NOT NULL DEFAULT 1,
 last_seen TEXT NOT NULL, run_id TEXT);
CREATE TABLE runs(run_id TEXT PRIMARY KEY, card_id TEXT NOT NULL, plan_sha256 TEXT NOT NULL,
 plan_json TEXT NOT NULL, status TEXT NOT NULL, tmux_target TEXT, exit_code INTEGER,
 error TEXT, created_at TEXT NOT NULL, started_at TEXT, ended_at TEXT);
CREATE TABLE approvals(nonce TEXT PRIMARY KEY, card_id TEXT NOT NULL, plan_sha256 TEXT NOT NULL,
 plan_json TEXT NOT NULL, issued_at TEXT NOT NULL, expires_at TEXT NOT NULL, used_at TEXT);
CREATE TABLE deliveries(id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
 channel TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt_at TEXT, sent_at TEXT, last_error TEXT);
CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, subject_event_id TEXT, card_id TEXT,
 ts TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT);
CREATE TABLE ingest_errors(id INTEGER PRIMARY KEY AUTOINCREMENT, file_name TEXT NOT NULL,
 ts TEXT NOT NULL, reason TEXT NOT NULL, raw_head TEXT);
"""

SEED_IDS = ("recovery-seed-action", "recovery-seed-info")
SEED_TIME = "2026-09-12T00:00:00Z"


def fail(message: str) -> None:
    raise SystemExit(f"install-recovery-db: {message}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_private(path: Path, what: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"cannot inspect {what}: {exc}")
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        fail(f"{what} is not a regular non-symlink file")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        fail(f"{what} must be owned by this uid and mode 0600 or stricter")


def seed_legacy(path: Path) -> int:
    if os.path.lexists(path):
        fail(f"refusing to replace existing database {path}")
    if path.parent.is_symlink() or not path.parent.is_dir():
        fail(f"database parent is not a regular directory: {path.parent}")
    connection = sqlite3.connect(path)
    try:
        connection.executescript(LEGACY_SCHEMA)
        connection.executemany(
            "INSERT INTO occurrences VALUES(?,?,?,?,?)",
            (
                (SEED_IDS[0], SEED_IDS[0], "recovery-action", "{}", SEED_TIME),
                (SEED_IDS[1], SEED_IDS[1], "recovery-info", "{}", SEED_TIME),
            ),
        )
        cards = (
            (SEED_IDS[0], "recovery-action", "driver", "action", "urgent", "seed action"),
            (SEED_IDS[1], "recovery-info", "driver", "info", "normal", "seed info"),
        )
        for card_id, group_key, source, kind, urgency, title in cards:
            connection.execute(
                "INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (card_id, group_key, source, kind, urgency, title, "", None, None, None,
                 SEED_TIME, SEED_TIME, None, None, 0, None, None, 1, SEED_TIME, None),
            )
        connection.execute(
            "INSERT INTO events(subject_event_id,card_id,ts,kind) VALUES(?,?,?,?)",
            (SEED_IDS[0], SEED_IDS[0], SEED_TIME, "ingested"),
        )
        connection.commit()
        connection.execute("PRAGMA journal_mode=DELETE")
    finally:
        connection.close()
    os.chmod(path, 0o600)
    observed = observe(path, None)
    if observed["schema"] != "legacy" or observed["integrity"] != "ok":
        fail("the database just seeded did not classify as intact legacy state")
    if observed["ids"] != list(SEED_IDS):
        fail(f"the database just seeded has unexpected ids: {observed['ids']!r}")
    print(json.dumps(observed, sort_keys=True))
    return 0


def schema_and_ids(connection: sqlite3.Connection) -> tuple[str, list[str]]:
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    if "ledger" in tables:
        schema = "canonical"
        ids = [row[0] for row in connection.execute("SELECT id FROM ledger ORDER BY id")]
    elif {"occurrences", "cards"} <= tables:
        schema = "legacy"
        ids = [
            row[0]
            for row in connection.execute("SELECT event_id FROM occurrences ORDER BY event_id")
        ]
        # A legacy card may not have an occurrence. Keep both seeded witnesses visible.
        ids.extend(
            row[0]
            for row in connection.execute("SELECT card_id FROM cards ORDER BY card_id")
            if row[0] not in ids
        )
        ids.sort()
    else:
        schema = "unknown"
        ids = []
    return schema, ids


def observe(path: Path, backup: Path | None) -> dict[str, object]:
    require_regular_private(path, "messages database")
    if backup is not None:
        if os.path.lexists(backup):
            fail(f"refusing to replace existing observation backup {backup}")
        if backup.parent.is_symlink() or not backup.parent.is_dir():
            fail(f"observation backup parent is unsafe: {backup.parent}")

    source = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    destination = None
    try:
        integrity_row = source.execute("PRAGMA integrity_check").fetchone()
        integrity = integrity_row[0] if integrity_row else "missing"
        schema, ids = schema_and_ids(source)
        if backup is not None:
            destination = sqlite3.connect(backup)
            source.backup(destination)
            destination.close()
            destination = None
            os.chmod(backup, 0o600)
    except Exception:
        if backup is not None and backup.exists():
            backup.unlink()
        raise
    finally:
        if destination is not None:
            destination.close()
        source.close()

    result: dict[str, object] = {
        "schema": schema,
        "integrity": integrity,
        "ids": ids,
        "rows": len(ids),
        "raw_sha256": sha256_file(path),
    }
    if backup is not None:
        result["online_backup_sha256"] = sha256_file(backup)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    seed = subparsers.add_parser("seed-legacy")
    seed.add_argument("database", type=Path)
    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("database", type=Path)
    snapshot.add_argument("backup", type=Path)
    args = parser.parse_args()
    if args.command == "seed-legacy":
        return seed_legacy(args.database)
    print(json.dumps(observe(args.database, args.backup), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
