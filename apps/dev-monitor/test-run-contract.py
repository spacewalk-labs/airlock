#!/usr/bin/env python3
"""Owner HTTP -> real tmux -> stub agent acceptance for card execution."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from unittest.mock import patch

APP = Path(__file__).resolve().parent
ROOT = APP.parent.parent
sys.path.insert(0, str(APP / 'backend'))
import devmon_messages as messages


PRE_PHASE_SCHEMA = '''
CREATE TABLE ledger (
  id TEXT PRIMARY KEY, "group" TEXT NOT NULL, source TEXT NOT NULL,
  received_at TEXT NOT NULL, payload TEXT NOT NULL
);
CREATE TABLE cards (
  card_id TEXT PRIMARY KEY, "group" TEXT NOT NULL, level TEXT NOT NULL,
  title TEXT NOT NULL, body TEXT, link TEXT, run TEXT,
  count INTEGER NOT NULL DEFAULT 1, first_at TEXT NOT NULL, last_at TEXT NOT NULL,
  read_at TEXT, archived_at TEXT, ran_at TEXT,
  sent_at TEXT, send_attempts INTEGER NOT NULL DEFAULT 0, send_next_at TEXT
);
'''


def reset_db(path):
    old = getattr(messages._local, 'conn', None)
    if old is not None:
        old.close()
    messages._local = threading.local()
    messages.init_db(str(path))


def wait_for(path):
    deadline = time.monotonic() + 3
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(.02)
    assert path.exists(), 'stub agent did not receive the prompt'


def check():
    if not shutil.which('tmux'):
        raise SystemExit('RUN CONTRACT NOT RUN: tmux is required')
    with tempfile.TemporaryDirectory(prefix='devmon-run-') as tmp:
        root = Path(tmp)
        fresh = root / 'fresh.db'
        reset_db(fresh)
        tables = {row[0] for row in messages._conn().execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        fresh_columns = {row[1] for row in messages._conn().execute('PRAGMA table_info(cards)')}
        assert tables == {'ledger', 'cards'}
        assert {'ran_input', 'ran_window'} <= fresh_columns

        pre_phase = root / 'pre-phase.db'
        conn = sqlite3.connect(pre_phase)
        conn.executescript(PRE_PHASE_SCHEMA)
        conn.close()
        reset_db(pre_phase)
        migrated = [row[1] for row in messages._conn().execute('PRAGMA table_info(cards)')]
        migrated_tables = {row[0] for row in messages._conn().execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        reset_db(pre_phase)
        migrated_twice = [row[1] for row in messages._conn().execute('PRAGMA table_info(cards)')]
        assert migrated_tables == {'ledger', 'cards'}
        assert migrated.count('ran_input') == migrated.count('ran_window') == 1
        assert migrated_twice == migrated

        db = root / 'messages.db'
        reset_db(db)
        cwd = root / 'project with spaces'
        cwd.mkdir()
        record = root / 'argv.json'
        canary = cwd / 'injected'
        agent = root / 'stub-agent'
        agent.write_text(
            '#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\n'
            + 'Path(%r).write_text(json.dumps({"argv":sys.argv,"cwd":os.getcwd()}))\n'
            % str(record))
        agent.chmod(0o755)
        selector = root / 'selector.py'
        selector.write_text('import json\nprint(json.dumps(%r))\n' % {
            'schema_version': 1, 'provider': 'codex', 'binary': str(agent),
            'reason': 'test stub'})
        session = 'devmon-run-' + uuid.uuid4().hex[:12]
        socket = session + '-socket'
        with patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false'}):
            spec = importlib.util.spec_from_file_location(
                'run_backend', APP / 'backend/airlock-dev-monitor.py')
            backend = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(backend)
        backend.OWNER_CONFIG = {'owner': 'owner@example.test', 'secret': 'synthetic-proxy',
                                'db': str(db), 'spool': str(root / 'spool')}
        backend.EXEC_CONFIG = {'cwd_root': str(root), 'session': session,
            'agent': {'provider': 'codex', 'select_bin': str(selector)},
            'runner': str(APP / 'backend/action_runner.py')}

        prompt = '--option ; $(touch injected) `touch injected` "quoted"\nCheck current state first;'
        declaration = [
            {'key': 'mode', 'label': 'Mode', 'choices': ['diagnose', 'fix'], 'default': 'diagnose'},
            {'key': 'scope', 'label': 'Scope'},
            {'key': 'free', 'label': 'Optional free text'},
            {'key': 'required', 'label': 'Required choice', 'choices': ['go', 'stop']},
        ]
        payload = {'id': 'run:one', 'group': 'run-group', 'source': 'fixture',
                   'level': 'normal', 'title': 'Run fixture', 'body': 'Present state',
                   'run': {'cwd': str(cwd), 'prompt': prompt, 'params': declaration}}
        messages.ingest(payload)
        messages.ingest(dict(payload, id='run:two'))

        class Handler(backend.Handler):
            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = 'http://127.0.0.1:%s' % server.server_port

        def post(body, owner=True, path='/api/owner/run'):
            headers = {'Content-Type': 'application/json', 'Origin': base,
                       'X-Devmon-Owner': 'owner@example.test' if owner else 'other@example.test',
                       'X-Devmon-Proxy-Secret': 'synthetic-proxy'}
            req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                         headers=headers, method='POST')
            try:
                with urllib.request.urlopen(req, timeout=5) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        original_run, original_call = subprocess.run, subprocess.call

        def on_socket(command):
            return [command[0], '-L', socket, *command[1:]] if command[0] == 'tmux' else command

        def isolated_run(command, *args, **kwargs):
            return original_run(on_socket(command), *args, **kwargs)

        def isolated_call(command, *args, **kwargs):
            return original_call(on_socket(command), *args, **kwargs)

        patch_run = patch.object(subprocess, 'run', side_effect=isolated_run)
        patch_call = patch.object(subprocess, 'call', side_effect=isolated_call)
        patch_run.start()
        patch_call.start()
        try:
            assert post({'card_id': 'run:one'}, owner=False)[0] == 403
            assert all(messages.get_card('run:one')[name] is None
                       for name in ('ran_at', 'ran_input', 'ran_window'))

            negative = [
                {'params': []},
                {'params': {'unknown': 'x', 'required': 'go'}},
                {'params': {'required': 1}},
                {'params': {'required': 'other'}},
                {'params': {}},
                {'params': {'required': 'go', 'scope': 'x' * 201}},
                {'params': {'required': 'go'}, 'note': 'x' * 8001},
            ]
            for case in negative:
                status, answer = post({'card_id': 'run:one', **case})
                assert status == 400, (case, status, answer)
            assert all(messages.get_card('run:one')[name] is None
                       for name in ('ran_at', 'ran_input', 'ran_window'))

            supplied_scope = '; "quotes" and newlines\nstay verbatim'
            note = 'Decision; keep `literal` and $(literal).\nSecond line.'
            card = messages.get_card('run:one')
            canonical = json.dumps(
                {'free': '', 'mode': 'diagnose', 'required': 'go', 'scope': supplied_scope},
                ensure_ascii=False, sort_keys=True, separators=(',', ':'))
            expected = (prompt + '\n\nMessage context: last_at=%s count=2' % card['last_at']
                        + '\n\nParameters: ' + canonical + '\n\nOwner note:\n' + note)
            started = time.monotonic()
            status, answer = post({'card_id': 'run:one',
                                   'params': {'required': 'go', 'scope': supplied_scope},
                                   'note': note})
            elapsed = time.monotonic() - started
            assert status == 200, answer
            assert elapsed < 1, elapsed
            wait_for(record)
            actual = json.loads(record.read_text())
            assert actual['argv'] == [str(agent), 'exec', '--', expected], actual['argv']
            assert actual['cwd'] == str(cwd)
            assert not canary.exists()
            stored = messages.get_card('run:one')
            assert stored['ran_at'] == answer['ran_at']
            assert stored['ran_window'] == answer['window']
            assert stored['ran_window'].startswith('@')
            assert stored['ran_input'] == json.dumps(
                {'note': note, 'params': json.loads(canonical)}, ensure_ascii=False,
                sort_keys=True, separators=(',', ':'))

            record.unlink()
            other = dict(payload, id='run:other', group='other-group')
            messages.ingest(other)
            second_status, second = post({'card_id': 'run:other',
                                          'params': {'required': 'go'}, 'note': ''})
            assert second_status == 200, second
            wait_for(record)
            assert second['window'] != answer['window']
            selected_status, selected = post(
                {'card_id': 'run:one'}, path='/api/owner/run/window')
            assert selected_status == 200 and selected['state'] == 'active', selected
            assert post({'card_id': 'run:one'}, owner=False,
                        path='/api/owner/run/window')[0] == 403
            current_window = original_run(
                ['tmux', '-L', socket, 'display-message', '-p', '-t', session, '#{window_id}'],
                capture_output=True, text=True, check=True).stdout.strip()
            assert current_window == answer['window'], (current_window, answer['window'])
            original_run(['tmux', '-L', socket, 'kill-window', '-t', answer['window']], check=True)
            ended_status, ended = post({'card_id': 'run:one'}, path='/api/owner/run/window')
            assert ended_status == 200 and ended['state'] == 'ended', ended

            failed = dict(payload, id='run:failed', group='failed-group')
            messages.ingest(failed)
            with patch.object(backend, '_launch_message', side_effect=OSError('fixture')):
                assert post({'card_id': 'run:failed', 'params': {'required': 'go'}})[0] == 502
            assert all(messages.get_card('run:failed')[name] is None
                       for name in ('ran_at', 'ran_input', 'ran_window'))

            nested_env = dict(os.environ, DEVMON_FRONTEND_NESTED='1')
            frontend = original_run(
                ['node', str(APP / 'test-frontend-contract.mjs')], env=nested_env,
                capture_output=True, text=True, timeout=10)
            assert frontend.returncode == 0, frontend.stderr + frontend.stdout

            revision = subprocess.check_output(
                ['git', 'rev-parse', '--short=12', 'HEAD'], text=True, cwd=ROOT).strip()
            print('AC-10 | expected: argv_one==1&&metachar_verbatim==1&&canonical_params==1&&cwd_bounded==1&&owner_403==1 | observed: argv_one=1,metachar_verbatim=1,canonical_params=1,cwd_bounded=1,owner_403=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
            print('AC-11 | expected: negative_controls==7&&defaults_resolved==2 | observed: negative_controls=7,defaults_resolved=2 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
            print('AC-12 | expected: success_fields==3&&failure_unchanged==3 | observed: success_fields=3,failure_unchanged=3 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
            print('AC-13 | expected: own_window==1&&ended_answer==1&&ended_ui==1 | observed: own_window=1,ended_answer=1,ended_ui=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
            print('AC-14 | expected: table_count==2&&added_columns==2&&init_idempotent==1 | observed: table_count=2,added_columns=2,init_idempotent=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            patch_call.stop()
            patch_run.stop()
            subprocess.run(['tmux', '-L', socket, 'kill-server'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            conn = getattr(messages._local, 'conn', None)
            if conn is not None:
                conn.close()


if __name__ == '__main__':
    check()
