#!/usr/bin/env python3
"""Owner HTTP -> real tmux -> stub agent: prompt argv, timing and ran_at."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
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
sys.path.insert(0, str(APP / 'backend'))
import devmon_messages as messages
import devmon_spool as spool


def check():
    if not shutil.which('tmux'):
        raise SystemExit('RUN CONTRACT NOT RUN: tmux is required')
    with tempfile.TemporaryDirectory(prefix='devmon-run-') as tmp:
        root = Path(tmp)
        cwd = root / 'project with spaces'
        cwd.mkdir()
        record = root / 'argv.json'
        canary = cwd / 'injected'
        agent = root / 'stub-agent'
        agent.write_text('#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\n'
                         + 'Path(%r).write_text(json.dumps({"argv":sys.argv,"cwd":os.getcwd()}))\n' % str(record))
        agent.chmod(0o755)
        selector = root / 'selector.py'
        selector.write_text('import json\nprint(json.dumps(%r))\n' % {
            'schema_version': 1, 'provider': 'codex', 'binary': str(agent), 'reason': 'test stub'})
        session = 'devmon-run-' + uuid.uuid4().hex[:12]
        socket = session + '-socket'
        with patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false'}):
            messages._local = threading.local()
            messages.init_db(str(root / 'messages.db'))
            spec = importlib.util.spec_from_file_location('run_backend', APP / 'backend/airlock-dev-monitor.py')
            backend = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(backend)
        backend.OWNER_CONFIG = {'owner': 'owner@example.test', 'secret': 'synthetic-proxy',
                                'db': str(root / 'messages.db'), 'spool': str(root / 'spool')}
        backend.EXEC_CONFIG = {'cwd_root': str(root), 'session': session,
            'agent': {'provider': 'codex', 'select_bin': str(selector)},
            'runner': str(APP / 'backend/action_runner.py')}
        prompt = '--option ; $(touch injected) `touch injected` "quoted"\nCheck current state first.'
        payload = {'id': 'run:one', 'group': 'run-group', 'source': 'fixture', 'level': 'normal',
                   'title': 'Run fixture', 'body': 'Check the present state',
                   'run': {'cwd': str(cwd), 'prompt': prompt}}
        queue = root / 'spool'
        for name in spool.SUBDIRS:
            (queue / name).mkdir(parents=True)
        emitted = subprocess.run([sys.executable, str(APP / 'examples/emit_message.py'),
            '--spool', str(queue), '--source', 'fixture', '--group-key', 'run-group',
            '--event-id', 'run:one', '--title', payload['title'], '--body', payload['body'],
            '--cwd', str(cwd), '--prompt=' + prompt], capture_output=True, timeout=5)
        assert emitted.returncode == 0, emitted.stderr
        assert spool.scan_once(str(queue))['inserted'] == 1
        messages.ingest(dict(payload, id='run:two'))
        card = messages.get_card('run:one')
        expected = prompt + '\n\nMessage context: last_at=%s count=2' % card['last_at']
        class Handler(backend.Handler):
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = 'http://127.0.0.1:%s' % server.server_port
        def post(card_id, owner=True, path='/api/owner/run'):
            headers = {'Content-Type': 'application/json', 'Origin': base,
                       'X-Devmon-Owner': 'owner@example.test' if owner else 'other@example.test',
                       'X-Devmon-Proxy-Secret': 'synthetic-proxy'}
            req = urllib.request.Request(base + path, data=json.dumps({'card_id': card_id}).encode(),
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
            assert post('run:one', owner=False)[0] == 403
            assert not record.exists() and messages.get_card('run:one')['ran_at'] is None
            started = time.monotonic()
            status, answer = post('run:one')
            elapsed = time.monotonic() - started
            assert status == 200, answer
            assert elapsed < 1, elapsed
            assert answer['target'] and messages.get_card('run:one')['ran_at'] == answer['ran_at']
            deadline = time.monotonic() + 3
            while not record.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            actual = json.loads(record.read_text())
            assert actual['argv'] == [str(agent), 'exec', '--', expected], actual['argv']
            assert actual['cwd'] == str(cwd)
            assert not canary.exists()
            edge_root = root / 'allowed;'
            edge_cwd = edge_root / 'project\\;'
            edge_cwd.mkdir(parents=True)
            backend.EXEC_CONFIG.update(cwd_root=str(edge_root), session=session + ';')
            for index, edge_prompt in enumerate(('literal;', 'literal\\;')):
                record.unlink()
                edge_id = 'edge-' + str(index)
                messages.ingest(dict(payload, id=edge_id, group=edge_id,
                    run={'cwd': str(edge_cwd), 'prompt': edge_prompt}))
                edge_status, edge_answer = post(edge_id)
                assert edge_status == 200, edge_answer
                deadline = time.monotonic() + 3
                while not record.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                edge_actual = json.loads(record.read_text())
                assert edge_actual['argv'] == [str(agent), 'exec', '--', edge_prompt]
                assert edge_actual['cwd'] == str(edge_cwd)
                assert messages.get_card(edge_id)['count'] == 1
                assert messages.get_card(edge_id)['ran_at'] == edge_answer['ran_at']
            print('TMUX PARSER: count1 trailing semicolon/backslash-semicolon exact argv; cwd/root/session endings preserved; ran_at recorded')
            backend.EXEC_CONFIG.update(cwd_root=str(root), session=session)
            failed = dict(payload, id='run:failed', group='failed-group')
            messages.ingest(failed)
            original = backend._tmux
            def fail_window(*args, **kwargs):
                return None if args[0] == 'new-window' else original(*args, **kwargs)
            with patch.object(backend, '_tmux', side_effect=fail_window):
                assert post('run:failed')[0] == 502
            assert messages.get_card('run:failed')['ran_at'] is None
            assert post('run:one', path='/api/run')[0] == 404
            assert post('run:one', path='/api/owner/messages/run%3Aone/plan')[0] == 404
            tables = {row[0] for row in messages._conn().execute("SELECT name FROM sqlite_master WHERE type='table'")}
            assert not tables & {'approvals', 'runs'}, tables
            assert not (root / 'plans').exists() and not (root / 'sentinels').exists()
            print('RUN: non-owner403; owner200 window=%.3fs; prompt argv1/cwd/context PASS; ran_at success only; no injection' % elapsed)
            print('TABLES: approvals=0 runs=0; message plans/sentinels=0')
        finally:
            server.shutdown()
            server.server_close()
            patch_call.stop()
            patch_run.stop()
            subprocess.run(['tmux', '-L', socket, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            messages._conn().close()


if __name__ == '__main__':
    check()
