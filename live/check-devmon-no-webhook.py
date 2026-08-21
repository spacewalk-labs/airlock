#!/usr/bin/env python3
"""Measure the messages-on/no-webhook watchdog gate in one disposable database."""

import importlib.util
import json
import os
import sqlite3
import sys
import urllib.request
from datetime import timedelta


LANES = ("slack-urgent", "slack-routine")
OFF = "off: no webhook configured"


def counts(conn):
    return {
        "watchdog_cards": conn.execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0],
        "watchdog_events": conn.execute(
            "SELECT COUNT(*) FROM events WHERE kind='lane_watchdog'"
        ).fetchone()[0],
        "watchdog_notice_deliveries": conn.execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0],
    }


def observation_timing(requested_seconds, elapsed_milliseconds):
    """Normalize the requested window separately from the monotonic measurement."""
    requested = int(requested_seconds)
    elapsed = int(elapsed_milliseconds)
    return {
        "observation_requested_seconds": requested,
        "observation_elapsed_milliseconds": elapsed,
        "observation_seconds": elapsed // 1000,
    }


def main():
    db_path, backend_dir, health_url, soak_seconds, elapsed_milliseconds = sys.argv[1:6]
    timing = observation_timing(soak_seconds, elapsed_milliseconds)
    with urllib.request.urlopen(health_url, timeout=6) as response:
        health = json.load(response)
    states = {
        lane: health.get("message_lanes", {}).get(lane, {}).get("worker_state")
        for lane in LANES
    }
    if health.get("messages") != "on" or any(value != OFF for value in states.values()):
        raise RuntimeError("effective messages/lane state does not match messages-on/no-webhook")

    conn = sqlite3.connect(db_path)
    try:
        zero = counts(conn)
    finally:
        conn.close()
    if any(zero.values()):
        raise RuntimeError("no-webhook watchdog observation was not zero: %r" % zero)

    sys.path.insert(0, backend_dir)
    backend_path = os.path.join(backend_dir, "airlock-dev-monitor.py")
    spec = importlib.util.spec_from_file_location("airlock_live_devmon_control", backend_path)
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    backend.MSG._local.__dict__.clear()
    backend.MSG.init_db(db_path)

    control_at = backend.MSG.now_utc()
    old_text = backend.MSG.iso(
        control_at - backend.MSG.LANE_OLDEST_OPEN_LIMIT - timedelta(seconds=1))
    with backend.MSG._conn() as db:
        db.execute(
            "INSERT INTO deliveries(card_id, channel, status, created_at, "
            "next_attempt_at) VALUES(?,?,?,?,?)",
            ("live-preaged-ledger-control", "slack-routine", "pending",
             old_text, old_text),
        )

    # Discriminator for the actual regression class: if an intentionally-off lane
    # falls through to the ordinary ledger path, this already-old row creates an
    # incident immediately instead of needing a 1,805-second natural soak.
    before_off = counts(backend.MSG._conn())
    backend._lane_watchdog_once(
        {"slack-urgent": "", "slack-routine": ""},
        active_incidents=set(), at=control_at,
    )
    after_off = counts(backend.MSG._conn())
    off_delta = {key: after_off[key] - before_off[key] for key in before_off}
    expected_zero = {key: 0 for key in before_off}
    if off_delta != expected_zero:
        raise RuntimeError("off lane fell through to ledger watchdog path: %r" % off_delta)

    before = counts(backend.MSG._conn())
    reason = backend.MSG.lane_watchdog_reason("slack-routine", "on", control_at)
    backend._lane_watchdog_once(
        {"slack-urgent": "configured-control", "slack-routine": "configured-control"},
        active_incidents=set(), at=control_at,
    )
    after = counts(backend.MSG._conn())
    delta = {key: after[key] - before[key] for key in before}
    expected = {
        "watchdog_cards": 1,
        "watchdog_events": 1,
        "watchdog_notice_deliveries": 1,
    }
    if reason is None or reason.get("state") != "stalled" or delta != expected:
        raise RuntimeError("known pre-aged control did not activate watchdog: %r %r" %
                           (reason, delta))

    print(json.dumps({
        "messages_effective": health["messages"],
        "worker_states": states,
        **timing,
        "zero_snapshot": zero,
        "off_branch_control": {"delta": off_delta},
        "positive_control": {"reason_state": reason["state"], "delta": delta},
    }, sort_keys=True))


if __name__ == "__main__":
    main()
