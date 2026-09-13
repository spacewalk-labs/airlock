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
import urllib.parse
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
        with (patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false'}),
              patch.dict(sys.modules, {'devmon_weekly_docs': None})):
            public_spec = importlib.util.spec_from_file_location(
                'run_backend_without_template', APP / 'backend/airlock-dev-monitor.py')
            public_backend = importlib.util.module_from_spec(public_spec)
            public_spec.loader.exec_module(public_backend)
        assert public_backend.WEEKLY_DOCS is None
        try:
            public_backend._compose_template_input({
                'template': 'fixture-template', 'week': '2026-09-18',
                'action': 'prompt'})
        except ValueError as error:
            assert str(error) == 'unsupported template'
        else:
            raise AssertionError('backend accepted a template without its private definition')
        backend.OWNER_CONFIG = {'owner': 'owner@example.test', 'secret': 'synthetic-proxy',
                                'db': str(db), 'spool': str(root / 'spool')}
        backend.HOME = str(root)
        original_home = os.environ.get('HOME')
        os.environ['HOME'] = str(root)
        backend.EXEC_CONFIG = {'cwd_root': str(root), 'session': session,
            'agent': {'provider': 'codex', 'select_bin': str(selector)},
            'runner': str(APP / 'backend/action_runner.py')}
        if backend.WEEKLY_DOCS is None:
            class FixtureTemplate:
                TEMPLATE_ID = 'fixture-template'
                ACTIONS = frozenset(('prompt', 'save', 'delete'))

                @staticmethod
                def build(_home, week, action, url=None):
                    run = {'template': FixtureTemplate.TEMPLATE_ID, 'week': week,
                           'action': action,
                           'cwd': '~/workspace/template-fixture',
                           'prompt': 'Server-owned fixture for ' + week,
                           'default_note': '' if action == 'prompt' else action + ' fixture',
                           'examples': ['First template note']}
                    if url is not None:
                        run['url'] = url
                    return {'title': 'Fixture Template', 'run': run}
            backend.WEEKLY_DOCS = FixtureTemplate
        template_id = backend.WEEKLY_DOCS.TEMPLATE_ID
        template_action = 'save'
        template_definition = backend.WEEKLY_DOCS.build(
            str(root), '2026-09-18', template_action,
            'https://docs.example.test/report?a=1#part')
        template_cwd = Path(os.path.expanduser(template_definition['run']['cwd']))
        template_cwd.mkdir(parents=True)

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

        def get(query, owner=True, path='/api/owner/run/template'):
            headers = {'X-Devmon-Owner': 'owner@example.test' if owner else 'other@example.test',
                       'X-Devmon-Proxy-Secret': 'synthetic-proxy'}
            req = urllib.request.Request(
                base + path + '?' + urllib.parse.urlencode(query), headers=headers)
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
            template_path = '/api/owner/run/template'
            template_window_path = '/api/owner/run/template/window'
            template_negative = [
                {},
                {'template': 'not-a-template', 'week': '2026-09-18', 'action': 'prompt'},
                {'template': template_id, 'week': '2026-09-18'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'other'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'save'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'delete'},
                {'template': template_id, 'week': '2026/09/18', 'action': 'prompt'},
                {'template': template_id, 'week': '2026-09-17', 'action': 'prompt'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'prompt',
                 'url': 'http://docs.example.test/report'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'prompt',
                 'url': 'https://docs.example.test/report\n추가 지시'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'prompt',
                 'note': 'x' * 8001},
                {'template': template_id, 'week': '2026-09-18', 'action': 'prompt',
                 'cwd': '/tmp'},
                {'template': template_id, 'week': '2026-09-18', 'action': 'prompt',
                 'prompt': 'injected'},
            ]
            for case in template_negative:
                status, answer = post(case, path=template_path)
                assert status == 400, (case, status, answer)
            assert get({'template': template_id, 'week': '2026-09-18',
                        'action': 'prompt', 'note': 'query injection'})[0] == 400
            assert post({'template': template_id, 'week': '2026-09-18',
                         'action': 'prompt'}, owner=False,
                        path=template_path)[0] == 403

            saved_owner = backend.OWNER_CONFIG
            backend.OWNER_CONFIG = None
            try:
                assert get({'template': template_id, 'week': '2026-09-18',
                            'action': 'prompt'})[0] == 404
            finally:
                backend.OWNER_CONFIG = saved_owner

            with (patch.object(backend, '_write_template_run', side_effect=OSError('fixture')),
                  patch.object(backend, '_launch_message') as launch):
                record_status, record_answer = post({
                    'template': template_id, 'week': '2026-09-25',
                    'action': template_action,
                    'url': 'https://docs.example.test/report'}, path=template_path)
                assert record_status == 500 and record_answer['error'] == 'run_record_failed'
                launch.assert_not_called()

            write_template_run = backend._write_template_run
            write_calls = 0
            def fail_detail(config, value):
                nonlocal write_calls
                write_calls += 1
                if write_calls == 1:
                    return write_template_run(config, value)
                raise OSError('fixture')
            with (patch.object(backend, '_write_template_run', side_effect=fail_detail),
                  patch.object(backend, '_launch_message', return_value='123:@99') as launch):
                detail_status, detail_answer = post({
                    'template': template_id, 'week': '2026-09-25',
                    'action': template_action,
                    'url': 'https://docs.example.test/report'}, path=template_path)
                assert detail_status == 200 and detail_answer['recorded'] is False
                launch.assert_called_once()
            fallback_status, fallback_window = post({
                'template': template_id, 'week': '2026-09-25',
                'action': template_action}, path=template_window_path)
            assert fallback_status == 200
            assert fallback_window['window'].startswith(
                session + ':' + template_id + '-' + template_action + '-')
            fallback_record = json.loads(backend._template_run_path(
                backend.OWNER_CONFIG, template_id, '2026-09-25',
                template_action).read_text())
            assert fallback_record['ran_at'] is None and fallback_record['requested_at']

            url = 'https://docs.example.test/report?a=1#part'
            fixed_template_prompt = template_definition['run']['prompt']
            preview_status, preview = get({
                'template': template_id, 'week': '2026-09-18',
                'action': template_action, 'url': url})
            assert preview_status == 200, preview
            assert preview['run'] == template_definition['run']

            template_note = 'Owner note line one.\nKeep the fixed decisions.'
            status, template_answer = post({
                'template': template_id, 'week': '2026-09-18',
                'action': template_action, 'url': url,
                'note': template_note}, path=template_path)
            assert status == 200, template_answer
            assert template_answer['recorded'] is True
            wait_for(record)
            template_actual = json.loads(record.read_text())
            assert template_actual['argv'] == [
                str(agent), 'exec', '--', fixed_template_prompt + '\n\n' + template_note]
            assert template_actual['cwd'] == str(template_cwd)
            template_record = json.loads(backend._template_run_path(
                backend.OWNER_CONFIG, template_id, '2026-09-18',
                template_action).read_text())
            assert template_record['ran_at'] == template_answer['ran_at']
            assert template_record['ran_window'] == template_answer['window']
            assert backend._template_run_path(
                backend.OWNER_CONFIG, template_id, '2026-09-18',
                template_action).stat().st_mode & 0o777 == 0o600
            assert backend._template_run_path(
                backend.OWNER_CONFIG, template_id, '2026-09-18',
                template_action).parent.stat().st_mode & 0o777 == 0o700
            assert json.loads(template_record['ran_input']) == {
                'template': template_id, 'week': '2026-09-18',
                'action': template_action, 'url': url, 'note': template_note}
            window_status, template_window = post({
                'template': template_id, 'week': '2026-09-18',
                'action': template_action}, path=template_window_path)
            assert window_status == 200 and template_window['state'] == 'active', template_window
            assert post({'template': template_id, 'week': '2026-09-18',
                         'action': 'delete'}, path=template_window_path)[0] == 404
            record.unlink()

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
            print('TEMPLATE-RUN-BACKEND | expected: rejects==13&&query_note_rejected==1&&owner_gate==1&&console_off==404&&server_prompt==1&&action_recorded==1&&window_selected==1&&action_isolated==1&&record_fail_no_launch==1&&detail_fail_no_retry==1 | observed: rejects=13,query_note_rejected=1,owner_gate=1,console_off=404,server_prompt=1,action_recorded=1,window_selected=1,action_isolated=1,record_fail_no_launch=1,detail_fail_no_retry=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-run-contract.py@%s' % revision)
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
            if original_home is None:
                os.environ.pop('HOME', None)
            else:
                os.environ['HOME'] = original_home


if __name__ == '__main__':
    check()
