#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / 'migrate-legacy-state.py'


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
        self.assertIn('backup=ok occurrences=1 cards=2 runs=1', result.stdout)
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
            self.assertEqual(2, db.execute('SELECT COUNT(*) FROM events').fetchone()[0])
            card = db.execute(
                "SELECT severity,owner,needs_action,task_state,runbook FROM cards "
                "WHERE card_id='card-safe'").fetchone()
            self.assertEqual('page', card['severity'])
            self.assertIsNone(card['owner'])
            self.assertIsNone(card['needs_action'])
            self.assertIsNone(card['task_state'])
            self.assertIsNone(card['runbook'])
            normal = db.execute(
                "SELECT severity FROM cards WHERE card_id='card-normal'").fetchone()
            self.assertEqual('record', normal['severity'])
            run = db.execute('SELECT keep_requested,kept_at,reclaimed_at FROM runs').fetchone()
            self.assertEqual(0, run['keep_requested'])
            self.assertIsNone(run['kept_at'])
            delivery = db.execute('SELECT channel,claimed_by,lease_until,created_at,last_error_at FROM deliveries').fetchone()
            self.assertEqual('slack-urgent', delivery['channel'])
            self.assertIsNone(delivery['claimed_by'])
        finally:
            db.close()
        self.assertEqual('{}\n', (self.canonical / 'spool' / 'new' / 'one.json').read_text())
        verified = self.run_script('--verify', target)
        self.assertEqual(0, verified.returncode, verified.stderr)
        self.assertIn('integrity_check=ok', verified.stdout)

        backup_db = sqlite3.connect(self.backup)
        target_db = sqlite3.connect(target)
        try:
            for table in ('occurrences', 'cards', 'runs', 'approvals',
                          'deliveries', 'events', 'ingest_errors'):
                source_count = backup_db.execute(
                    'SELECT COUNT(*) FROM %s' % table).fetchone()[0]
                target_count = target_db.execute(
                    'SELECT COUNT(*) FROM %s' % table).fetchone()[0]
                self.assertEqual(source_count, target_count, table)
            old_card_columns = (
                'card_id,group_key,source,kind,urgency,title,body,action_json,'
                'link_json,action_digest,created_at,received_at,read_at,'
                'slack_sent_at,pinned,archived_at,dismissed_at,occurrence_count,'
                'last_seen,run_id')
            self.assertEqual(
                backup_db.execute(
                    'SELECT %s FROM cards ORDER BY card_id' % old_card_columns).fetchall(),
                target_db.execute(
                    'SELECT %s FROM cards ORDER BY card_id' % old_card_columns).fetchall())
        finally:
            backup_db.close()
            target_db.close()

        db = sqlite3.connect(target)
        try:
            db.execute('DROP INDEX idx_deliveries_claim')
            db.commit()
        finally:
            db.close()
        partial = self.run_script('--verify', target)
        self.assertEqual(2, partial.returncode)
        self.assertIn('canonical indexes', partial.stderr)

    def test_duplicate_open_delivery_fails_without_identifiers(self):
        conn = make_legacy(self.legacy, duplicate=True)
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertNotIn('card-safe', result.stderr)
        self.assertNotIn('slack-urgent', result.stderr)
        self.assertTrue(self.backup.exists())
        self.assertFalse((self.canonical / 'messages.db').exists())

    def test_unexpected_urgency_fails_closed(self):
        conn = make_legacy(self.legacy)
        conn.execute("UPDATE cards SET urgency='surprise' WHERE card_id='card-normal'")
        conn.commit()
        conn.close()
        result = self.run_script(
            self.legacy, self.canonical, '--db-backup', self.backup, '--offline')
        self.assertEqual(2, result.returncode)
        self.assertIn('unsupported urgency', result.stderr)
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
        original = module._load_messages

        class Broken:
            @staticmethod
            def init_db(_path):
                raise RuntimeError('sentinel-secret-row')

        module._load_messages = lambda: Broken
        try:
            with self.assertRaises(RuntimeError):
                module.migrate(
                    str(self.legacy), str(self.canonical), str(self.backup),
                    offline=True)
        finally:
            module._load_messages = original
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
        self.assertIn('canonical schema', legacy_verify.stderr)

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


if __name__ == '__main__':
    unittest.main()
