#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / 'migrate-legacy-state.py'
REPO = HERE.parent.parent
AC6 = {'invariants': 0, 'compensation': 0}


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


def load_module():
    spec = importlib.util.spec_from_file_location('migrate_legacy_state', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def make_legacy(root: Path, duplicate: bool = False) -> sqlite3.Connection:
    root.mkdir(parents=True)
    db = root / 'messages.db'
    conn = sqlite3.connect(db)
    conn.executescript(LEGACY_SCHEMA)
    now = '2026-08-21T00:00:00Z'
    conn.execute('INSERT INTO occurrences VALUES(?,?,?,?,?)',
                 ('event-safe', 'card-safe', 'group-safe', '{}', now))
    conn.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                 ('card-safe', 'group-safe', 'test', 'action', 'urgent', 'title', 'body',
                  None, None, None, now, now, None, None, 0, None, None, 1, now, None))
    conn.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                 ('card-normal', 'group-normal', 'test', 'info', 'normal', 'title', 'body',
                  None, None, None, now, now, None, None, 0, None, None, 1, now, None))
    conn.execute('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                 ('run-safe', 'card-safe', 'digest', '{}', 'succeeded', None, 0, None,
                  now, now, now))
    conn.execute('INSERT INTO approvals VALUES(?,?,?,?,?,?,?)',
                 ('nonce-safe', 'card-safe', 'digest', '{}', now, now, None))
    conn.execute('INSERT INTO deliveries(card_id,channel,status) VALUES(?,?,?)',
                 ('card-safe', 'slack', 'sent'))
    if duplicate:
        conn.execute('INSERT INTO deliveries(card_id,channel,status) VALUES(?,?,?)',
                     ('card-safe', 'slack', 'pending'))
        conn.execute('INSERT INTO deliveries(card_id,channel,status) VALUES(?,?,?)',
                     ('card-safe', 'slack-urgent', 'pending'))
    conn.execute('INSERT INTO events(subject_event_id,card_id,ts,kind) VALUES(?,?,?,?)',
                 ('event-safe', 'card-safe', now, 'ingested'))
    conn.execute('INSERT INTO ingest_errors(file_name,ts,reason) VALUES(?,?,?)',
                 ('safe.json', now, 'test'))
    conn.commit()
    return conn


def make_coalesce_fixture(path: Path, schema: str = 'phase1') -> None:
    module = load_module()
    messages = module._load_messages()
    if schema not in {'fresh', 'phase1', 'phase2'}:
        raise ValueError('unknown fixture schema')
    if schema == 'fresh':
        messages.init_db(str(path))
    else:
        conn = sqlite3.connect(path)
        conn.executescript(messages._SCHEMA)
        conn.close()
        if schema == 'phase2':
            messages.init_db(str(path))
    conn = sqlite3.connect(path)
    columns = ('card_id', 'group', 'level', 'title', 'body', 'link', 'run', 'count',
               'first_at', 'last_at', 'read_at', 'archived_at', 'ran_at', 'sent_at',
               'send_attempts', 'send_next_at')
    insert = 'INSERT INTO cards(%s) VALUES(%s)' % (
        ','.join('"group"' if item == 'group' else item for item in columns),
        ','.join('?' for _ in columns))
    run_a = '{"cwd":"/work","prompt":"inspect"}'
    run_b = '{ "prompt": "inspect", "cwd": "/work" }'
    rows = [
        ('a-new', 'same', 'normal', 'new', '', 'https://example.test/doc', run_a, 2,
         '2026-07-01T00:00:00.000000Z', '2026-09-10T00:00:00.000000Z',
         '2026-09-10T01:00:00.000000Z', None, None,
         '2026-09-10T02:00:00.000000Z', 2, None),
        ('z-new', 'same', 'urgent', 'tie', '', 'https://example.test/doc', run_b, 3,
         '2026-06-01T00:00:00.000000Z', '2026-09-10T00:00:00.000000Z',
         None, None, None, None, 0, '2026-09-10T00:00:00.000000Z'),
        ('old', 'same', 'normal', 'old', '', 'https://example.test/doc', run_a, 4,
         '2026-05-01T00:00:00.000000Z', '2026-08-01T00:00:00.000000Z',
         '2026-08-01T01:00:00.000000Z', None, None, None, 0, None),
        ('different-run', 'same', 'normal', 'run', '', 'https://example.test/doc',
         '{"cwd":"/work","prompt":"other"}', 5,
         '2026-05-02T00:00:00.000000Z', '2026-08-02T00:00:00.000000Z',
         None, None, None, None, 0, None),
        ('different-link', 'same', 'normal', 'link', '', 'https://example.test/other',
         run_a, 6, '2026-05-03T00:00:00.000000Z', '2026-08-03T00:00:00.000000Z',
         None, None, None, None, 0, None),
        ('cron:a1eedad1a93544b3beee223b', 'cron-job:a1eedad1a93544b3beee223b',
         'urgent', 'before evidence', '', None, run_a, 8,
         '2026-09-12T06:25:00.000000Z', '2026-09-12T07:57:00.000000Z',
         None, None, None, '2026-09-12T06:25:03.000000Z', 1, None),
        ('heartbeat:2026-09-09', 'heartbeat', 'urgent', 'heartbeat', '', None, None, 7,
         '2026-09-09T00:00:00.000000Z', '2026-09-09T00:00:00.000000Z',
         None, None, None, None, 0, None),
        ('heartbeat:2026-09-10', 'heartbeat', 'urgent', 'heartbeat', '', None, None, 8,
         '2026-09-10T00:00:00.000000Z', '2026-09-10T00:00:00.000000Z',
         None, None, None, None, 0, None),
    ]
    conn.executemany(insert, rows)
    conn.executemany(
        'INSERT INTO ledger VALUES(?,?,?,?,?)',
        [('event-a', 'same', 'fixture', '2026-09-10T00:00:00.000000Z', '{}'),
         ('event-heartbeat', 'heartbeat', 'fixture',
          '2026-09-10T00:00:01.000000Z', '{}')])
    if schema in {'fresh', 'phase2'}:
        conn.execute(
            'UPDATE cards SET ran_at=?,ran_input=?,ran_window=? WHERE card_id=?',
            ('2026-09-10T03:00:00.000000Z', '{"note":"","params":{}}',
             'dev-monitor:ac20-fixture', 'a-new'))
        conn.execute(
            'UPDATE cards SET ran_at=?,ran_input=?,ran_window=? WHERE card_id=?',
            ('2026-09-09T03:00:00.000000Z', '{"note":"loser","params":{}}',
             'dev-monitor:archived-fixture', 'old'))
    conn.commit()
    conn.execute('PRAGMA journal_mode=DELETE')
    conn.close()
    os.chmod(path, 0o600)


def _decoded_identity(row: sqlite3.Row) -> tuple[object, ...] | None:
    if row['card_id'].startswith('heartbeat:'):
        return None
    try:
        decoded = json.loads(row['run']) if row['run'] else None
        run_key = json.dumps(decoded, sort_keys=True, separators=(',', ':'))
    except (TypeError, ValueError):
        return None
    return (row['group'], run_key, row['link'])


def _coalesce_expectations(path: Path) -> dict[str, object]:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            'SELECT * FROM cards WHERE archived_at IS NULL '
            'ORDER BY last_at DESC,card_id ASC').fetchall()
        all_rows = conn.execute('SELECT card_id,count FROM cards').fetchall()
        ledger = [tuple(row) for row in conn.execute(
            'SELECT * FROM ledger ORDER BY id')]
    finally:
        conn.close()
    groups: dict[tuple[object, ...], list[sqlite3.Row]] = {}
    untouched: dict[str, tuple[object, ...]] = {}
    for row in rows:
        identity = _decoded_identity(row)
        if identity is None:
            untouched[row['card_id']] = tuple(row)
        else:
            groups.setdefault(identity, []).append(row)
    survivor_mutations = {'level', 'count', 'first_at', 'last_at', 'read_at'}
    survivors = {items[0]['card_id']: {
        'level': 'urgent' if any(item['level'] == 'urgent' for item in items)
        else 'normal',
        'count': sum(item['count'] for item in items),
        'first_at': min(item['first_at'] for item in items),
        'last_at': max(item['last_at'] for item in items),
        'read_at': None if any(item['read_at'] is None for item in items)
        else items[0]['read_at'],
        'delivery': tuple(items[0][key] for key in
                          ('sent_at', 'send_attempts', 'send_next_at')),
        'preserved': {key: items[0][key] for key in items[0].keys()
                      if key not in survivor_mutations},
    } for items in groups.values()}
    loser_mutations = {'count', 'archived_at'}
    losers = {item['card_id']: {
        key: item[key] for key in item.keys() if key not in loser_mutations
    } for items in groups.values() for item in items[1:]}
    return {
        'row_count': len(all_rows),
        'count_sum': sum(row['count'] for row in all_rows),
        'survivors': survivors,
        'losers': losers,
        'untouched': untouched,
        'ledger': ledger,
        'cron_before': {row['card_id']: tuple(row) for row in rows
                        if row['card_id'].startswith(
                            'cron:a1eedad1a93544b3beee223b')},
    }


def check_coalesce_round_trip(path: Path) -> dict[str, int]:
    expected = _coalesce_expectations(path)
    before_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    result = subprocess.run(
        [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path), '--offline'],
        text=True, capture_output=True, check=False)
    if result.returncode:
        raise AssertionError(result.stderr)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        rows = {row['card_id']: row for row in conn.execute('SELECT * FROM cards')}
        assert len(rows) == expected['row_count']
        assert sum(row['count'] for row in rows.values()) == expected['count_sum']
        for card_id, values in expected['survivors'].items():
            row = rows[card_id]
            assert row['archived_at'] is None
            assert row['level'] == values['level']
            assert row['count'] == values['count']
            assert row['first_at'] == values['first_at']
            assert row['last_at'] == values['last_at']
            assert row['read_at'] == values['read_at']
            assert tuple(row[key] for key in
                         ('sent_at', 'send_attempts', 'send_next_at')) == values['delivery']
            for key, value in values['preserved'].items():
                assert row[key] == value
        for card_id, preserved in expected['losers'].items():
            assert rows[card_id]['archived_at'] is not None
            assert rows[card_id]['count'] == 0
            for key, value in preserved.items():
                assert rows[card_id][key] == value
        for card_id, values in expected['untouched'].items():
            assert tuple(rows[card_id]) == values
        assert [tuple(row) for row in conn.execute(
            'SELECT * FROM ledger ORDER BY id')] == expected['ledger']
        for card_id, values in expected['cron_before'].items():
            assert tuple(rows[card_id]) == values
        assert conn.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    finally:
        conn.close()
    after_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    repeated = subprocess.run(
        [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path), '--offline'],
        text=True, capture_output=True, check=False)
    assert repeated.returncode == 0, repeated.stderr
    assert 'coalesced=0' in repeated.stdout
    assert hashlib.sha256(path.read_bytes()).hexdigest() == after_hash
    compensated = subprocess.run(
        [sys.executable, str(SCRIPT), '--compensate-coalesce-open-cards', str(path),
         '--offline'], text=True, capture_output=True, check=False)
    assert compensated.returncode == 0, compensated.stderr
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before_hash
    return {
        'survivors': len(expected['survivors']),
        'losers': len(expected['losers']),
        'rows': expected['row_count'],
        'invariants': 1,
        'compensation': 1,
    }


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.legacy = self.root / 'legacy'
        self.canonical = self.root / 'canonical'
        self.backup = self.root / 'rollback' / 'messages.db'

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *(str(arg) for arg in args)],
            text=True, capture_output=True, check=False)

    def test_database_requires_backup_before_any_target_write(self):
        conn = make_legacy(self.legacy)
        conn.close()
        before = (self.legacy / 'messages.db').read_bytes()
        result = self.run_script(self.legacy, self.canonical, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertIn('--db-backup is required', result.stderr)
        self.assertFalse((self.canonical / 'messages.db').exists())
        self.assertEqual(before, (self.legacy / 'messages.db').read_bytes())

    def test_spool_only_import_needs_no_database_backup(self):
        source = self.legacy / 'spool' / 'new'
        source.mkdir(parents=True)
        (source / 'one.json').write_text('{}\n')
        result = self.run_script(self.legacy, self.canonical, '--offline')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('database_migrated=0 spool_copied=1', result.stdout)
        self.assertEqual(
            '{}\n', (self.canonical / 'spool' / 'new' / 'one.json').read_text())

    def test_import_requires_explicit_offline_attestation(self):
        conn = make_legacy(self.legacy)
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup)
        self.assertEqual(2, result.returncode)
        self.assertIn('--offline is required', result.stderr)
        self.assertFalse(self.backup.exists())

    def test_endstate_classifies_converts_and_repeats_without_a_second_backup(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'messages.db'

        classified = self.run_script('--schema-state', source)
        self.assertEqual(0, classified.returncode, classified.stderr)
        self.assertEqual('legacy', classified.stdout.strip())

        converted = self.run_script('--endstate', source, '--offline')
        self.assertEqual(0, converted.returncode, converted.stderr)
        self.assertEqual('converted=1 backup_retained=1', converted.stdout.strip())
        backup = self.legacy / 'messages.db.pre-endstate'
        self.assertTrue(backup.is_file())
        self.assertTrue(Path(str(backup) + '.manifest.json').is_file())
        self.assertTrue(Path(str(backup) + '.target.json').is_file())

        classified = self.run_script('--schema-state', source)
        self.assertEqual(0, classified.returncode, classified.stderr)
        self.assertEqual('canonical', classified.stdout.strip())
        before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in self.legacy.iterdir() if path.is_file()}
        repeated = self.run_script('--endstate', source, '--offline')
        after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in self.legacy.iterdir() if path.is_file()}
        self.assertEqual(0, repeated.returncode, repeated.stderr)
        self.assertEqual('converted=0 backup_retained=1', repeated.stdout.strip())
        self.assertEqual(before, after)

    def test_endstate_publish_failure_retains_legacy_source_and_resumable_backup(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'messages.db'
        module = load_module()

        with mock.patch.object(
                module, '_publish_clone', side_effect=OSError('injected publish failure')):
            with self.assertRaises(OSError):
                module.endstate(str(source), offline=True)

        backup = self.legacy / 'messages.db.pre-endstate'
        self.assertTrue(backup.is_file())
        self.assertTrue(Path(str(backup) + '.manifest.json').is_file())
        legacy = sqlite3.connect(source)
        try:
            self.assertEqual(
                {'occurrences', 'cards', 'runs', 'approvals', 'deliveries', 'events',
                 'ingest_errors', 'sqlite_sequence'},
                {row[0] for row in legacy.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")})
            self.assertEqual('ok', legacy.execute('PRAGMA integrity_check').fetchone()[0])
        finally:
            legacy.close()

        resumed = self.run_script('--endstate', source, '--offline')
        self.assertEqual(0, resumed.returncode, resumed.stderr)
        self.assertEqual('canonical', self.run_script(
            '--schema-state', source).stdout.strip())

    def test_endstate_count_failure_happens_before_publish_and_can_resume(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'messages.db'
        module = load_module()
        actual_counts = module._counts

        def mismatched_clone_counts(path):
            counts = actual_counts(path)
            if set(counts) == {'ledger', 'cards'}:
                return dict(counts, ledger=counts['ledger'] + 1)
            return counts

        with mock.patch.object(module, '_counts', side_effect=mismatched_clone_counts):
            with self.assertRaisesRegex(
                    module.MigrationError, 'row counts changed during conversion'):
                module.endstate(str(source), offline=True)

        self.assertEqual('legacy', self.run_script(
            '--schema-state', source).stdout.strip())
        backup = self.legacy / 'messages.db.pre-endstate'
        self.assertTrue(backup.is_file())
        self.assertFalse(Path(str(backup) + '.target.json').exists())
        resumed = self.run_script('--endstate', source, '--offline')
        self.assertEqual(0, resumed.returncode, resumed.stderr)
        self.assertEqual('canonical', self.run_script(
            '--schema-state', source).stdout.strip())

    def test_endstate_refuses_a_busy_writer_before_backup_or_publish(self):
        conn = make_legacy(self.legacy)
        source = self.legacy / 'messages.db'
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute('BEGIN IMMEDIATE')
        conn.execute("UPDATE cards SET title='uncommitted' WHERE card_id='card-safe'")
        try:
            result = self.run_script('--endstate', source, '--offline')
            self.assertEqual(2, result.returncode)
            self.assertFalse(self.legacy.joinpath(
                'messages.db.pre-endstate').exists())
            observer = sqlite3.connect(source)
            try:
                self.assertEqual('title', observer.execute(
                    "SELECT title FROM cards WHERE card_id='card-safe'").fetchone()[0])
            finally:
                observer.close()
        finally:
            conn.rollback()
            conn.close()

    def test_endstate_refuses_a_redirected_database_leaf(self):
        conn = make_legacy(self.legacy)
        conn.close()
        link = self.root / 'messages-link.db'
        link.symlink_to(self.legacy / 'messages.db')
        result = self.run_script('--endstate', link, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertIn('regular non-symlink', result.stderr)
        self.assertFalse(self.root.joinpath('messages-link.db.pre-endstate').exists())

    def test_compensate_endstate_restores_once_and_is_idempotent(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'messages.db'
        converted = self.run_script('--endstate', source, '--offline')
        self.assertEqual(0, converted.returncode, converted.stderr)

        restored = self.run_script('--compensate-endstate', source, '--offline')
        self.assertEqual(0, restored.returncode, restored.stderr)
        self.assertEqual('restore=ok backup_retained=1', restored.stdout.strip())
        self.assertEqual('legacy', self.run_script('--schema-state', source).stdout.strip())
        self.assertTrue(self.legacy.joinpath('messages.db.pre-endstate').is_file())

        repeated = self.run_script('--compensate-endstate', source, '--offline')
        self.assertEqual(0, repeated.returncode, repeated.stderr)
        self.assertEqual('compensated=0 already_legacy=1', repeated.stdout.strip())

    def test_compensate_endstate_refuses_to_discard_later_writes(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'messages.db'
        converted = self.run_script('--endstate', source, '--offline')
        self.assertEqual(0, converted.returncode, converted.stderr)
        live = sqlite3.connect(source)
        live.execute("UPDATE cards SET title='later-write' WHERE card_id='card-safe'")
        live.commit()
        live.close()

        refused = self.run_script('--compensate-endstate', source, '--offline')
        self.assertEqual(2, refused.returncode)
        self.assertIn('does not match the backup', refused.stderr)
        current = sqlite3.connect(source)
        try:
            self.assertEqual(
                'later-write',
                current.execute(
                    "SELECT title FROM cards WHERE card_id='card-safe'").fetchone()[0])
        finally:
            current.close()
        self.assertEqual('legacy', self.run_script(
            '--schema-state', self.legacy / 'messages.db.pre-endstate').stdout.strip())

    def test_online_backup_captures_committed_wal_without_mutating_source(self):
        conn = make_legacy(self.legacy)
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute("INSERT INTO events(ts,kind) VALUES('2026-08-21T02:00:00Z','online')")
        conn.commit()
        source = self.legacy / 'messages.db'
        wal = Path(str(source) + '-wal')
        before = {
            path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size,
                   path.stat().st_mtime_ns)
            for path in (source, wal)
        }
        result = self.run_script(
            '--backup-source', source, '--db-backup', self.backup)
        after = {
            path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size,
                   path.stat().st_mtime_ns)
            for path in (source, wal)
        }
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(before, after)
        self.assertIn('backup=ok', result.stdout)
        for count in ('occurrences=1','cards=2','runs=1'):
            self.assertIn(count,result.stdout)
        copy = sqlite3.connect(self.backup)
        try:
            self.assertEqual(2, copy.execute('SELECT COUNT(*) FROM events').fetchone()[0])
            self.assertEqual('ok', copy.execute('PRAGMA integrity_check').fetchone()[0])
        finally:
            copy.close()
            conn.close()
        self.assertTrue(Path(str(self.backup) + '.manifest.json').is_file())
        for suffix in ('-wal', '-shm', '-journal'):
            self.assertFalse(Path(str(self.backup) + suffix).exists())

    def test_online_backup_resumes_into_the_offline_migration(self):
        conn = make_legacy(self.legacy)
        conn.close()
        backed_up = self.run_script(
            '--backup-source', self.legacy / 'messages.db',
            '--db-backup', self.backup)
        self.assertEqual(0, backed_up.returncode, backed_up.stderr)
        migrated = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(0, migrated.returncode, migrated.stderr)
        verified = self.run_script('--verify', self.canonical / 'messages.db')
        self.assertEqual(0, verified.returncode, verified.stderr)

    def test_online_backup_refuses_stale_target_marker_namespace(self):
        conn = make_legacy(self.legacy)
        conn.close()
        self.backup.parent.mkdir(parents=True)
        marker = Path(str(self.backup) + '.target.json')
        marker.write_text('{}\n')
        result = self.run_script(
            '--backup-source', self.legacy / 'messages.db',
            '--db-backup', self.backup)
        self.assertEqual(2, result.returncode)
        self.assertIn('database backup already exists', result.stderr)
        self.assertFalse(self.backup.exists())
        self.assertFalse(Path(str(self.backup) + '.manifest.json').exists())
        self.assertEqual('{}\n', marker.read_text())

    def test_online_backup_resume_refuses_source_changed_during_approval(self):
        conn = make_legacy(self.legacy)
        conn.execute('PRAGMA journal_mode=WAL')
        conn.commit()
        backed_up = self.run_script(
            '--backup-source', self.legacy / 'messages.db',
            '--db-backup', self.backup)
        self.assertEqual(0, backed_up.returncode, backed_up.stderr)
        conn.execute("INSERT INTO events(ts,kind) VALUES('2026-08-21T03:00:00Z','late')")
        conn.commit()
        conn.close()
        migrated = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(2, migrated.returncode)
        self.assertIn('source changed since database backup', migrated.stderr)
        self.assertFalse((self.canonical / 'messages.db').exists())

    def test_migrates_wal_rows_columns_channels_and_spool(self):
        conn = make_legacy(self.legacy)
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute("INSERT INTO events(ts,kind) VALUES('2026-08-21T01:00:00Z','wal-row')")
        conn.commit()  # Keep the connection open: the committed row may still be in WAL.
        source_db = self.legacy / 'messages.db'
        source_wal = Path(str(source_db) + '-wal')
        before = {
            path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size,
                   path.stat().st_mtime_ns)
            for path in (source_db, source_wal)
        }
        spool = self.legacy / 'spool' / 'new'
        spool.mkdir(parents=True)
        (spool / 'one.json').write_text('{}\n')
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        after = {
            path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size,
                   path.stat().st_mtime_ns)
            for path in (source_db, source_wal)
        }
        self.assertEqual(before, after)
        self.assertNotIn(
            'severity', {row[1] for row in conn.execute('PRAGMA table_info(cards)')})
        conn.close()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('database_migrated=1 spool_copied=1', result.stdout)
        target = self.canonical / 'messages.db'
        self.assertEqual(0o600, target.stat().st_mode & 0o777)
        self.assertEqual(0o600, self.backup.stat().st_mode & 0o777)
        db = sqlite3.connect(target)
        db.row_factory = sqlite3.Row
        try:
            self.assertEqual('ok', db.execute('PRAGMA integrity_check').fetchone()[0])
            self.assertEqual(1, db.execute('SELECT COUNT(*) FROM ledger').fetchone()[0])
            levels = dict(db.execute('SELECT card_id,level FROM cards'))
            self.assertEqual({'card-safe':'urgent','card-normal':'normal'},levels)
            self.assertIsNone(db.execute('SELECT ran_at FROM cards LIMIT 1').fetchone()[0])
            self.assertEqual({'ledger','cards'}, {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")})
        finally:
            db.close()
        self.assertEqual('{}\n', (self.canonical / 'spool' / 'new' / 'one.json').read_text())
        verified = self.run_script('--verify', target)
        self.assertEqual(0, verified.returncode, verified.stderr)
        self.assertIn('integrity_check=ok', verified.stdout)

        backup_db = sqlite3.connect(self.backup)
        target_db = sqlite3.connect(target)
        try:
            self.assertEqual(2,backup_db.execute('SELECT COUNT(*) FROM events').fetchone()[0])
            self.assertEqual(1,backup_db.execute('SELECT COUNT(*) FROM runs').fetchone()[0])
            self.assertEqual(backup_db.execute('SELECT event_id,group_key,received_at,payload_json FROM occurrences').fetchall(),
                             target_db.execute('SELECT id,[group],received_at,payload FROM ledger').fetchall())
            self.assertEqual(backup_db.execute('SELECT card_id,group_key,urgency,title,body,occurrence_count,last_seen FROM cards ORDER BY card_id').fetchall(),
                             target_db.execute('SELECT card_id,[group],level,title,body,count,last_at FROM cards ORDER BY card_id').fetchall())
        finally:
            backup_db.close()
            target_db.close()

        db = sqlite3.connect(target)
        try:
            db.execute('DROP INDEX cards_send')
            db.commit()
        finally:
            db.close()
        partial = self.run_script('--verify', target)
        self.assertEqual(2, partial.returncode)
        self.assertIn('canonical indexes', partial.stderr)

    def test_duplicate_open_deliveries_become_one_due_card(self):
        conn = make_legacy(self.legacy, duplicate=True)
        conn.close()
        result = self.run_script(self.legacy,self.canonical,'--db-backup',self.backup,'--offline')
        self.assertEqual(0,result.returncode,result.stderr)
        db=sqlite3.connect(self.canonical/'messages.db')
        self.assertEqual(1,db.execute('SELECT COUNT(*) FROM cards WHERE send_next_at IS NOT NULL').fetchone()[0])
        db.close()
        backup=sqlite3.connect(self.backup)
        self.assertEqual(2,backup.execute("SELECT COUNT(*) FROM deliveries WHERE status='pending'").fetchone()[0])
        backup.close()

    def test_pending_and_claimed_drain_failed_and_unqueued_history_stay(self):
        import http.server
        import threading
        conn=make_legacy(self.legacy)
        conn.execute('DELETE FROM deliveries')
        template=dict(zip([c[1] for c in conn.execute('PRAGMA table_info(cards)')],
                          conn.execute("SELECT * FROM cards WHERE card_id='card-safe'").fetchone()))
        for name in ('failed','unqueued'):
            row=dict(template,card_id=name,group_key=name)
            conn.execute('INSERT INTO cards VALUES('+','.join('?' for _ in row)+')',tuple(row.values()))
        for cid,status,attempts in (('card-safe','pending',2),('card-normal','claimed',6),('failed','failed',1)):
            conn.execute('INSERT INTO deliveries(card_id,channel,status,attempts) VALUES(?,?,?,?)',
                         (cid,'slack-urgent',status,attempts))
        conn.commit();conn.close()
        result=self.run_script(self.legacy,self.canonical,'--db-backup',self.backup,'--offline')
        self.assertEqual(0,result.returncode,result.stderr)
        sys.path.insert(0,str(HERE/'backend'))
        import devmon_messages as messages
        import devmon_loop as loop
        messages._local=threading.local()
        messages.init_db(str(self.canonical/'messages.db'))
        self.assertEqual(messages.delivery_health()['pending_count'],2)
        self.assertEqual(messages.get_card('failed')['delivery'],'failed')
        self.assertEqual(messages.get_card('unqueued')['delivery'],'none')
        posts=[]
        class Recorder(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                posts.append(self.rfile.read(int(self.headers['Content-Length'])))
                self.send_response(200);self.end_headers()
            def log_message(self,*args): pass
        server=http.server.HTTPServer(('127.0.0.1',0),Recorder)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            hook='http://127.0.0.1:%d/hook'%server.server_port
            self.assertTrue(loop.deliver_once(hook));self.assertTrue(loop.deliver_once(hook))
            self.assertFalse(loop.deliver_once(hook))
            self.assertEqual(len(posts),2)
            self.assertEqual(messages.delivery_health()['pending_count'],0)
            self.assertEqual(messages.delivery_health()['failed_count'],1)
            self.assertEqual(messages.get_card('card-normal')['level'],'normal')
            self.assertEqual(messages.get_card('card-normal')['send_attempts'],6)
            self.assertIsNone(messages.get_card('unqueued')['sent_at'])
        finally:
            messages._conn().close();messages._local=threading.local()
            server.shutdown();server.server_close();thread.join()
        backup=sqlite3.connect(self.backup)
        self.assertEqual([('claimed',6),('failed',1),('pending',2)],
                         backup.execute('SELECT status,attempts FROM deliveries ORDER BY status').fetchall())
        backup.close()
        print('SYNTHETIC DRAIN: pending1/claimed1 -> POST2 sent2; failed1 preserved; unqueued1 POST0; raw attempts in backup')

    def test_converted_old_digest_keeps_same_daily_card_and_distinct_links(self):
        import threading
        conn=make_legacy(self.legacy)
        conn.execute("UPDATE cards SET action_digest='retired-digest' WHERE card_id='card-safe'")
        conn.commit();conn.close()
        result=self.run_script(self.legacy,self.canonical,'--db-backup',self.backup,'--offline')
        self.assertEqual(0,result.returncode,result.stderr)
        sys.path.insert(0,str(HERE/'backend'))
        import devmon_messages as messages
        messages._local=threading.local();messages.init_db(str(self.canonical/'messages.db'))
        now=messages.parse_rfc3339('2026-08-21T01:00:00Z')
        with mock.patch.object(messages,'now_utc',return_value=now):
            payload={'id':'next','group':'group-safe','source':'test','level':'urgent','title':'T','body':'B'}
            self.assertEqual(messages.ingest(payload),'coalesced')
            self.assertEqual(messages.get_card('card-safe')['count'],2)
            self.assertEqual(messages.delivery_health()['pending_count'],0)
            self.assertEqual(messages.ingest(dict(payload,id='link',link='https://example.test/new')),'inserted')
            self.assertEqual(messages.ingest(dict(payload,id='run',run={'cwd':'/tmp/project','prompt':'Check'})),'inserted')
        self.assertEqual(messages._conn().execute('SELECT COUNT(*) FROM cards').fetchone()[0],4)
        messages._conn().close();messages._local=threading.local()

    def test_unexpected_urgency_fails_closed(self):
        conn = make_legacy(self.legacy)
        conn.execute("UPDATE cards SET urgency='surprise' WHERE card_id='card-normal'")
        conn.commit()
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertIn('invalid legacy data', result.stderr)
        self.assertTrue(self.backup.exists())
        self.assertFalse((self.canonical / 'messages.db').exists())

    def test_spool_collision_is_rejected_before_backup_or_publish(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'spool' / 'new'
        source.mkdir(parents=True)
        (source / 'one.json').write_text('source')
        target = self.canonical / 'spool' / 'new'
        target.mkdir(parents=True)
        (target / 'one.json').write_text('target')
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertFalse(self.backup.exists())
        self.assertFalse((self.canonical / 'messages.db').exists())
        self.assertEqual('target', (target / 'one.json').read_text())

    def test_spool_publish_failure_rolls_back_prior_moves(self):
        module = load_module()
        stage = self.root / 'stage'
        for lane, name in (('new', 'one.json'), ('tmp', 'two.json')):
            path = stage / lane
            path.mkdir(parents=True)
            (path / name).write_text(name)
        real_replace = module.os.replace
        calls = 0

        def fail_second(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('injected move failure')
            return real_replace(source, target)

        with mock.patch.object(module.os, 'replace', side_effect=fail_second):
            with self.assertRaises(OSError):
                module._publish_spool(stage, self.canonical)
        self.assertTrue((stage / 'new' / 'one.json').exists())
        self.assertTrue((stage / 'tmp' / 'two.json').exists())
        self.assertFalse((self.canonical / 'spool' / 'new' / 'one.json').exists())

    def test_backup_final_name_is_published_only_after_complete_copy(self):
        conn = make_legacy(self.legacy)
        conn.close()
        module = load_module()
        self.backup.parent.mkdir()
        with mock.patch.object(module.os, 'link', side_effect=OSError('injected')):
            with self.assertRaises(OSError):
                module._sqlite_backup(
                    self.legacy / 'messages.db', self.backup, exclusive=True)
        self.assertFalse(self.backup.exists())
        self.assertEqual([], list(self.backup.parent.glob('.messages-backup.*')))
        self.assertFalse(Path(str(self.backup) + '.manifest.json').exists())

    def test_rejects_overlap_existing_backup_and_second_import(self):
        conn = make_legacy(self.legacy)
        conn.close()
        overlap = self.run_script(
            self.legacy, self.legacy / 'new', '--db-backup', self.backup,
            '--offline')
        self.assertEqual(2, overlap.returncode)
        self.backup.parent.mkdir()
        self.backup.write_text('do not overwrite')
        existing = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(2, existing.returncode)
        self.assertEqual('do not overwrite', self.backup.read_text())

        self.backup.unlink()
        first = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(0, first.returncode, first.stderr)
        second_backup = self.root / 'second-backup.db'
        second = self.run_script(
            self.legacy, self.canonical, '--db-backup', second_backup, '--offline')
        self.assertEqual(2, second.returncode)
        self.assertIn('canonical database already exists', second.stderr)
        self.assertFalse(second_backup.exists())

        inside = self.run_script(
            self.legacy, self.root / 'another-target',
            '--db-backup', self.legacy / 'unsafe-backup.db', '--offline')
        self.assertEqual(2, inside.returncode)
        self.assertIn('outside both state roots', inside.stderr)
        resume_source = self.run_script(
            self.legacy, self.root / 'resume-target',
            '--db-backup', self.legacy / 'messages.db', '--resume', '--offline')
        self.assertEqual(2, resume_source.returncode)
        self.assertIn('outside both state roots', resume_source.stderr)

    def test_init_failure_leaves_backup_and_no_target(self):
        conn = make_legacy(self.legacy)
        conn.close()
        module = load_module()
        with mock.patch.object(module,'_migrate_clone',side_effect=RuntimeError('synthetic conversion failure')):
            with self.assertRaises(RuntimeError):
                module.migrate(str(self.legacy),str(self.canonical),str(self.backup),offline=True)
        self.assertTrue(self.backup.exists())
        self.assertFalse((self.canonical / 'messages.db').exists())
        resumed = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(0, resumed.returncode, resumed.stderr)
        self.assertTrue((self.canonical / 'messages.db').exists())

    def test_closed_stdout_does_not_turn_success_into_partial_rollback(self):
        conn = make_legacy(self.legacy)
        conn.close()
        source = self.legacy / 'spool' / 'new'
        source.mkdir(parents=True)
        (source / 'one.json').write_text('{}\n')
        module = load_module()
        with mock.patch('builtins.print', side_effect=BrokenPipeError):
            result = module.migrate(
                str(self.legacy), str(self.canonical), str(self.backup),
                offline=True)
        self.assertEqual(0, result)
        self.assertTrue((self.canonical / 'messages.db').exists())
        self.assertTrue((self.canonical / 'spool' / 'new' / 'one.json').exists())

    def test_resume_completes_spool_after_hard_crash_between_moves(self):
        conn = make_legacy(self.legacy)
        conn.close()
        for lane, name in (('new', 'one.json'), ('tmp', 'two.json')):
            source = self.legacy / 'spool' / lane
            source.mkdir(parents=True)
            (source / name).write_text(name)
        probe = """
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location('migration_probe', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_replace = module.os.replace
def crash_before_second(source, target):
    if pathlib.Path(target).name == 'two.json':
        os._exit(77)
    return real_replace(source, target)
module.os.replace = crash_before_second
module.migrate(sys.argv[2], sys.argv[3], sys.argv[4], offline=True)
"""
        crashed = subprocess.run(
            [sys.executable, '-c', probe, str(SCRIPT), str(self.legacy),
             str(self.canonical), str(self.backup)], check=False)
        self.assertEqual(77, crashed.returncode)
        self.assertTrue((self.canonical / 'messages.db').exists())
        self.assertTrue((self.canonical / 'spool' / 'new' / 'one.json').exists())
        self.assertFalse((self.canonical / 'spool' / 'tmp' / 'two.json').exists())
        resumed = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(0, resumed.returncode, resumed.stderr)
        self.assertTrue((self.canonical / 'spool' / 'new' / 'one.json').exists())
        self.assertTrue((self.canonical / 'spool' / 'tmp' / 'two.json').exists())

    def test_resume_rejects_same_shape_but_modified_target_database(self):
        conn = make_legacy(self.legacy)
        conn.close()
        first = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(0, first.returncode, first.stderr)
        target = self.canonical / 'messages.db'
        db = sqlite3.connect(target)
        try:
            db.execute("UPDATE cards SET title='modified' WHERE card_id='card-safe'")
            db.commit()
            self.assertEqual('ok', db.execute('PRAGMA integrity_check').fetchone()[0])
        finally:
            db.close()
        resumed = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(2, resumed.returncode)
        self.assertIn('does not match the backup', resumed.stderr)

    def test_resume_rejects_target_with_committed_wal_state(self):
        conn = make_legacy(self.legacy)
        conn.close()
        first = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(0, first.returncode, first.stderr)
        target = self.canonical / 'messages.db'
        live = sqlite3.connect(target)
        live.execute('PRAGMA journal_mode=WAL')
        live.execute("UPDATE cards SET title='wal-modified' WHERE card_id='card-safe'")
        live.commit()
        resumed = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup,
            '--resume', '--offline')
        self.assertEqual(2, resumed.returncode)
        self.assertIn('SQLite journal state', resumed.stderr)
        self.assertEqual(
            'wal-modified',
            live.execute(
                "SELECT title FROM cards WHERE card_id='card-safe'").fetchone()[0])
        live.close()

    def test_restore_is_atomic_and_retains_backup(self):
        conn = make_legacy(self.legacy)
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(0, result.returncode, result.stderr)
        target = self.canonical / 'messages.db'
        live = sqlite3.connect(target)
        live.execute('PRAGMA journal_mode=WAL')
        live.execute('CREATE TABLE restore_sentinel(value TEXT)')
        live.execute("INSERT INTO restore_sentinel VALUES('committed-in-wal')")
        live.commit()
        refused = self.run_script(
            '--restore-backup', self.backup, '--restore-to', target, '--offline')
        self.assertEqual(2, refused.returncode)
        self.assertIn('SQLite journal state', refused.stderr)
        self.assertEqual(
            'committed-in-wal',
            live.execute('SELECT value FROM restore_sentinel').fetchone()[0])
        self.assertTrue(Path(str(target) + '-wal').exists())
        self.assertTrue(Path(str(target) + '-shm').exists())
        live.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        live.execute('PRAGMA journal_mode=DELETE')
        live.close()
        restored = self.run_script(
            '--restore-backup', self.backup, '--restore-to', target, '--offline')
        self.assertEqual(0, restored.returncode, restored.stderr)
        self.assertTrue(self.backup.exists())
        db = sqlite3.connect(target)
        try:
            columns = {row[1] for row in db.execute('PRAGMA table_info(cards)')}
            self.assertNotIn('severity', columns)
        finally:
            db.close()

        legacy_verify = self.run_script('--verify', self.backup)
        self.assertEqual(2, legacy_verify.returncode)
        self.assertIn('exactly ledger and cards', legacy_verify.stderr)

    def test_restore_refuses_hot_rollback_journal_without_touching_it(self):
        conn = make_legacy(self.legacy)
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(0, result.returncode, result.stderr)
        target = self.canonical / 'messages.db'
        crash = (
            "import os,sqlite3,sys; c=sqlite3.connect(sys.argv[1]); "
            "c.execute('PRAGMA journal_mode=DELETE'); c.execute('BEGIN IMMEDIATE'); "
            "c.execute(\"UPDATE cards SET body=hex(randomblob(50000))\"); "
            "os._exit(0)")
        subprocess.run([sys.executable, '-c', crash, str(target)], check=True)
        journal = Path(str(target) + '-journal')
        self.assertTrue(journal.exists())
        before = hashlib.sha256(journal.read_bytes()).hexdigest()
        refused = self.run_script(
            '--restore-backup', self.backup, '--restore-to', target, '--offline')
        self.assertEqual(2, refused.returncode)
        self.assertIn('SQLite journal state', refused.stderr)
        self.assertEqual(before, hashlib.sha256(journal.read_bytes()).hexdigest())
        recovered = sqlite3.connect(target)
        try:
            self.assertEqual(
                'ok', recovered.execute('PRAGMA integrity_check').fetchone()[0])
        finally:
            recovered.close()


class CoalesceOpenCardsTests(unittest.TestCase):
    def test_official_schema_generations_are_accepted(self):
        for schema in ('fresh', 'phase1', 'phase2'):
            with self.subTest(schema=schema), tempfile.TemporaryDirectory(
                    prefix='devmon-coalesce-schema-') as raw:
                path = Path(raw) / 'messages.db'
                make_coalesce_fixture(path, schema=schema)
                self.assertIn(
                    'cron:a1eedad1a93544b3beee223b',
                    _coalesce_expectations(path)['cron_before'])
                observed = check_coalesce_round_trip(path)
                self.assertEqual(observed['invariants'], 1)
                self.assertEqual(observed['compensation'], 1)

    def test_unknown_column_and_wrong_table_are_rejected_without_mutation(self):
        cases = {
            'unknown-column': 'ALTER TABLE cards ADD COLUMN surprise TEXT',
            'wrong-table': 'CREATE TABLE surprise(value TEXT)',
        }
        for name, statement in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory(
                    prefix='devmon-coalesce-bad-schema-') as raw:
                path = Path(raw) / 'messages.db'
                make_coalesce_fixture(path, schema='phase2')
                conn = sqlite3.connect(path)
                try:
                    conn.execute(statement)
                    conn.commit()
                    conn.execute('PRAGMA journal_mode=DELETE')
                finally:
                    conn.close()
                before = hashlib.sha256(path.read_bytes()).hexdigest()
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), '--coalesce-open-cards',
                     str(path), '--offline'], text=True, capture_output=True,
                    check=False)
                self.assertEqual(result.returncode, 2)
                self.assertIn('canonical', result.stderr)
                self.assertEqual(before, hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertFalse(Path(
                    str(path) + '.pre-coalesce-open-cards').exists())

    def test_forward_and_compensation_require_offline_attestation(self):
        with tempfile.TemporaryDirectory(prefix='devmon-coalesce-gate-') as raw:
            path = Path(raw) / 'messages.db'
            make_coalesce_fixture(path)
            forward = subprocess.run(
                [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path)],
                text=True, capture_output=True, check=False)
            compensate = subprocess.run(
                [sys.executable, str(SCRIPT), '--compensate-coalesce-open-cards',
                 str(path)], text=True, capture_output=True, check=False)
            self.assertNotEqual(forward.returncode, 0)
            self.assertNotEqual(compensate.returncode, 0)
            self.assertIn('--offline is required', forward.stderr)
            self.assertIn('--offline is required', compensate.stderr)

    def test_fixture_folds_decoded_identity_and_mixed_level_then_exactly_compensates(self):
        with tempfile.TemporaryDirectory(prefix='devmon-coalesce-') as raw:
            path = Path(raw) / 'messages.db'
            make_coalesce_fixture(path)
            self.assertEqual(
                _coalesce_expectations(path)['survivors']['a-new']['level'], 'urgent')
            observed = check_coalesce_round_trip(path)
            self.assertEqual(observed, {
                'survivors': 4, 'losers': 2, 'rows': 8,
                'invariants': 1, 'compensation': 1,
            })
            backup = Path(str(path) + '.pre-coalesce-open-cards')
            self.assertTrue(backup.is_file())
            self.assertTrue(Path(str(backup) + '.manifest.json').is_file())
            self.assertTrue(Path(str(backup) + '.target.json').is_file())
            wal = Path(str(path) + '-wal')
            wal.write_bytes(b'uncheckpointed-state')
            unsafe_noop = subprocess.run(
                [sys.executable, str(SCRIPT), '--compensate-coalesce-open-cards',
                 str(path), '--offline'], text=True, capture_output=True, check=False)
            self.assertNotEqual(unsafe_noop.returncode, 0)
            self.assertIn('SQLite journal state', unsafe_noop.stderr)
            AC6.update({
                'invariants': observed['invariants'],
                'compensation': observed['compensation'],
            })

    def test_forward_resumes_after_receipt_is_durable_before_database_replace(self):
        module = load_module()
        with tempfile.TemporaryDirectory(prefix='devmon-coalesce-resume-') as raw:
            path = Path(raw) / 'messages.db'
            make_coalesce_fixture(path)
            backup = Path(str(path) + module.COALESCE_BACKUP_SUFFIX)
            module._exact_copy(path, backup, no_clobber=True)
            module._write_backup_manifest(backup, path)
            clone = Path(raw) / 'interrupted.db'
            shutil.copyfile(backup, clone)
            module._coalesce_clone(clone)
            expected_sha256 = module._file_sha256(clone)
            module._write_target_marker(backup, expected_sha256)
            clone.unlink()

            resumed = subprocess.run(
                [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path),
                 '--offline'], text=True, capture_output=True, check=False)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertIn('coalesced=1', resumed.stdout)
            self.assertEqual(module._file_sha256(path), expected_sha256)

            repeated = subprocess.run(
                [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path),
                 '--offline'], text=True, capture_output=True, check=False)
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertIn('coalesced=0', repeated.stdout)

    def test_compensation_refuses_to_discard_a_later_write(self):
        with tempfile.TemporaryDirectory(prefix='devmon-coalesce-later-write-') as raw:
            path = Path(raw) / 'messages.db'
            make_coalesce_fixture(path)
            forward = subprocess.run(
                [sys.executable, str(SCRIPT), '--coalesce-open-cards', str(path),
                 '--offline'], text=True, capture_output=True, check=False)
            self.assertEqual(forward.returncode, 0, forward.stderr)
            conn = sqlite3.connect(path)
            try:
                conn.execute(
                    'UPDATE cards SET title=? WHERE card_id=?',
                    ('later write', 'a-new'))
                conn.commit()
            finally:
                conn.close()
            changed_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            compensate = subprocess.run(
                [sys.executable, str(SCRIPT), '--compensate-coalesce-open-cards',
                 str(path), '--offline'], text=True, capture_output=True, check=False)
            self.assertNotEqual(compensate.returncode, 0)
            self.assertIn('does not match the backup', compensate.stderr)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), changed_hash)

    def test_compensation_refuses_journal_state_even_when_main_file_matches_backup(self):
        with tempfile.TemporaryDirectory(prefix='devmon-coalesce-journal-') as raw:
            path = Path(raw) / 'messages.db'
            make_coalesce_fixture(path)
            check_coalesce_round_trip(path)
            Path(str(path) + '-wal').touch()
            compensate = subprocess.run(
                [sys.executable, str(SCRIPT), '--compensate-coalesce-open-cards',
                 str(path), '--offline'], text=True, capture_output=True, check=False)
            self.assertNotEqual(compensate.returncode, 0)
            self.assertIn('database has SQLite journal state', compensate.stderr)


if __name__ == '__main__':
    if '--live-copy' in sys.argv:
        index = sys.argv.index('--live-copy')
        try:
            path = Path(sys.argv[index + 1])
        except IndexError:
            raise SystemExit('--live-copy requires a database path')
        observed = check_coalesce_round_trip(path)
        revision = subprocess.check_output(
            ['git', 'rev-parse', '--short=12', 'HEAD'], cwd=REPO, text=True).strip()
        print('AC-6 | expected: invariants == 1 && compensation == 1 | '
              'observed: invariants=%d,compensation=%d | verdict: PASS | signal: replay | '
              'evidence: apps/dev-monitor/test-migrate-legacy-state.py@%s'
              % (observed['invariants'], observed['compensation'], revision))
        print('LIVE-COPY: rows=%d survivors=%d losers=%d' % (
            observed['rows'], observed['survivors'], observed['losers']))
    else:
        program = unittest.main(exit=False)
        if not program.result.wasSuccessful():
            raise SystemExit(1)
        revision = subprocess.check_output(
            ['git', 'rev-parse', '--short=12', 'HEAD'], cwd=REPO, text=True).strip()
        verdict = 'PASS' if all(value == 1 for value in AC6.values()) else 'FAIL'
        print('AC-6 | expected: invariants == 1 && compensation == 1 | '
              'observed: invariants=%d,compensation=%d | verdict: %s | signal: fixture | '
              'evidence: apps/dev-monitor/test-migrate-legacy-state.py@%s'
              % (AC6['invariants'], AC6['compensation'], verdict, revision))
