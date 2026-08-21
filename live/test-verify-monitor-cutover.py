#!/usr/bin/env python3
"""Tests for the read-only live cutover verifier."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sqlite3
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-monitor-cutover.py")
SPEC = importlib.util.spec_from_file_location("verify_monitor_cutover", SCRIPT)
verify_monitor_cutover = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(verify_monitor_cutover)


SCHEMA = """
CREATE TABLE cards(card_id TEXT PRIMARY KEY, occurrence_count INTEGER);
CREATE TABLE occurrences(event_id TEXT PRIMARY KEY, card_id TEXT);
CREATE TABLE deliveries(
  id INTEGER PRIMARY KEY, card_id TEXT, channel TEXT, status TEXT, sent_at TEXT);
CREATE TABLE approvals(
  nonce TEXT PRIMARY KEY, card_id TEXT, plan_sha256 TEXT, issued_at TEXT, used_at TEXT);
CREATE TABLE runs(
  run_id TEXT PRIMARY KEY, card_id TEXT, plan_sha256 TEXT, status TEXT,
  exit_code INTEGER, created_at TEXT, ended_at TEXT);
"""


def healthy() -> dict[str, object]:
    return {
        "messages": "on",
        "token_freshness": "on",
        "message_lanes": {
            "slack-urgent": {"worker_state": "on"},
            "slack-routine": {"worker_state": "on"},
            "email": {"worker_state": "off: no transport configured"},
        },
    }


class HealthHandler(BaseHTTPRequestHandler):
    payload = healthy()

    def do_GET(self):  # noqa: N802
        body = json.dumps(type(self).payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class VerifyMonitorCutoverTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.db = Path(self.tempdir.name) / "messages.db"
        with sqlite3.connect(self.db) as conn:
            conn.executescript(SCHEMA)
            conn.execute("INSERT INTO cards VALUES('canary', 1)")
            conn.execute("INSERT INTO occurrences VALUES('event-1', 'canary')")
            conn.execute(
                "INSERT INTO deliveries VALUES(1, 'canary', 'slack-routine', 'sent', '2026-08-21T00:00:01Z')")
            conn.execute(
                "INSERT INTO approvals VALUES("
                "'nonce', 'canary', 'plan', '2026-08-21T00:00:01Z', '2026-08-21T00:00:02Z')")
            conn.execute(
                "INSERT INTO runs VALUES("
                "'run-1', 'canary', 'plan', 'done', 0, "
                "'2026-08-21T00:00:02Z', '2026-08-21T00:00:03Z')")
        HealthHandler.payload = healthy()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), HealthHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/api/health"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tempdir.cleanup()

    def test_success_is_read_only(self):
        before = self._database_files()
        result = verify_monitor_cutover.verify(self.db, "canary", self.url, 2)
        after = self._database_files()
        self.assertTrue(result["ok"])
        self.assertEqual(result["canary"]["run"]["run_id"], "run-1")
        self.assertEqual(before, after)

    def _database_files(self):
        return {
            path.name: hashlib.sha256(path.read_bytes()).digest()
            for path in self.db.parent.glob(self.db.name + "*") if path.is_file()
        }

    def test_used_approval_must_match_successful_run(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute("UPDATE approvals SET plan_sha256='other'")
        with self.assertRaisesRegex(
                verify_monitor_cutover.VerificationError, "matching used approval"):
            verify_monitor_cutover.verify(self.db, "canary", self.url, 2)

    def test_latest_failed_run_cannot_hide_behind_old_success(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute(
                "INSERT INTO runs VALUES("
                "'run-2', 'canary', 'plan', 'failed', 1, "
                "'2026-08-21T00:00:04Z', '2026-08-21T00:00:05Z')")
        with self.assertRaisesRegex(
                verify_monitor_cutover.VerificationError, "latest run"):
            verify_monitor_cutover.verify(self.db, "canary", self.url, 2)

    def test_email_must_remain_unconfigured(self):
        HealthHandler.payload = healthy()
        HealthHandler.payload["message_lanes"]["email"] = {"worker_state": "on"}
        with self.assertRaisesRegex(
                verify_monitor_cutover.VerificationError, "email worker"):
            verify_monitor_cutover.verify(self.db, "canary", self.url, 2)

    def test_external_health_url_is_refused(self):
        with self.assertRaisesRegex(
                verify_monitor_cutover.VerificationError, "loopback IP literal"):
            verify_monitor_cutover.verify(
                self.db, "canary", "https://example.test/api/health", 2)

    def test_health_redirect_is_refused(self):
        class RedirectHandler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                self.send_response(302)
                self.send_header("Location", "http://192.0.2.1/fake-health")
                self.end_headers()

            def log_message(self, *_args):
                pass

        redirect = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        thread = threading.Thread(target=redirect.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{redirect.server_port}/api/health"
            with self.assertRaisesRegex(
                    verify_monitor_cutover.VerificationError, "redirect"):
                verify_monitor_cutover.verify(self.db, "canary", url, 2)
        finally:
            redirect.shutdown()
            redirect.server_close()
            thread.join(timeout=2)

    def test_missing_slack_delivery_is_refused(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute(
                "INSERT INTO deliveries VALUES("
                "2, 'canary', 'slack-routine', 'pending', NULL)")
        with self.assertRaisesRegex(
                verify_monitor_cutover.VerificationError, "latest Slack delivery"):
            verify_monitor_cutover.verify(self.db, "canary", self.url, 2)


if __name__ == "__main__":
    unittest.main()
