#!/usr/bin/env python3
"""Exercise installed heartbeat -> spool -> card -> local HTTP recorder.

--systemd additionally links the rendered heartbeat units into the user manager,
checks enable/schedule, then starts once. Refuses to replace an existing timer.
"""
import argparse
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
import http.server
import json
import os
import re
import runpy
from pathlib import Path
import shlex
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.request

APP = Path(__file__).resolve().parent
ROOT = APP.parents[1]
UNITS = ('airlock-devmon-heartbeat.service', 'airlock-devmon-heartbeat.timer')


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, timeout=60, **kwargs)



def check_disable(systemd=False):
    # Non-dry installer, scratch destinations, no production unit/privileged writes.
    # The wrapper either maintains queried state or delegates only our random
    # timer/service aliases to a real user manager. Every other call is contained.
    import secrets
    with tempfile.TemporaryDirectory(prefix='devmon-disable-') as tmp:
        scratch = Path(tmp)
        home = scratch / 'home'
        units = home / '.config/systemd/user'
        units.mkdir(parents=True)
        shim = scratch / 'bin'
        shim.mkdir()
        state = scratch / 'manager.json'
        calls = scratch / 'calls.jsonl'
        prefix = 'devmon-disable-' + secrets.token_hex(6)
        aliases = {unit: prefix + ('.timer' if unit.endswith('.timer') else '.service') for unit in UNITS}
        wrapper = shim / 'systemctl'
        wrapper.write_text('#!' + sys.executable + '\n' + '''import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['DISABLE_CALLS'], 'a') as out: out.write(json.dumps(args) + '\\n')
path = Path(os.environ['DISABLE_STATE'])
state = json.loads(path.read_text())
unit = next((arg for arg in args if arg in state['units']), None)
if unit is None: sys.exit(0)  # unrelated backend/firewall operations stay contained
mode = state['mode']
is_timer = unit.endswith('.timer')
if 'show' in args:
    if mode == 'query-failure': sys.exit(1)
elif 'disable' in args:
    if mode == ('timer-failure' if is_timer else 'service-failure'): sys.exit(1)
    if mode == ('timer-lie' if is_timer else 'service-lie'): sys.exit(0)
if state['real']:
    command = ['/usr/bin/systemctl', *[state['aliases'].get(arg, arg) for arg in args]]
    sys.exit(subprocess.run(command).returncode)
if 'show' in args:
    for key, value in state['units'][unit].items(): print(key + '=' + str(value))
elif 'disable' in args:
    state['units'][unit].update(ActiveState='inactive', MainPID='0', UnitFileState='disabled')
    path.write_text(json.dumps(state))
else: sys.exit(99)
''')
        wrapper.chmod(0o755)
        # The unrelated system firewall teardown must not touch a production file.
        (shim / 'sudo').write_text('#!/bin/sh\ncase "$*" in *is-enabled*|*is-active*|*"list table"*) exit 1;; esac\nexit 0\n')
        (shim / 'sudo').chmod(0o755)
        config = scratch / 'airlock.toml'
        config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                          '[apps.hub]\n[apps.dev-monitor]\nmessages=false\n')
        env = dict(os.environ)
        env.update({'HOME': str(home), 'PATH': str(shim) + ':/usr/local/bin:/usr/bin:/bin',
                    'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(APP), 'AIRLOCK_APP_ID': 'dev-monitor',
                    'AIRLOCK_CONFIG': str(config), 'AIRLOCK_DRY_RUN': '0', 'AIRLOCK_TS_FQDN': 'box.example.test',
                    'AIRLOCK_CONFD': str(scratch / 'confd'), 'AIRLOCK_WEBROOT': str(scratch / 'web'),
                    'AIRLOCK_STATE_DIR': str(scratch / 'state'), 'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592',
                    'DISABLE_STATE': str(state), 'DISABLE_CALLS': str(calls)})
        env.pop('AIRLOCK_RENDER_DIR', None)
        modes = ('timer-failure', 'service-failure', 'timer-lie', 'service-lie',
                 'query-failure', 'active', 'inactive', 'missing')
        for mode in modes:
            calls.write_text('')
            for unit in UNITS:
                (units / unit).write_text('recovery fragment\n')
            initial = dict(LoadState='not-found' if mode == 'missing' else 'loaded',
                           ActiveState='inactive' if mode in ('missing', 'inactive') else 'active',
                           MainPID='0' if mode in ('missing', 'inactive') else '123',
                           UnitFileState='' if mode == 'missing' else 'disabled' if mode == 'inactive' else 'enabled')
            state.write_text(json.dumps({'mode': mode, 'real': systemd, 'aliases': aliases,
                                         'units': {unit: initial for unit in UNITS}}))
            try:
                if systemd and mode != 'missing':
                    service = scratch / aliases[UNITS[0]]
                    timer = scratch / aliases[UNITS[1]]
                    service.write_text('[Service]\nType=oneshot\nExecStart=/bin/sleep 300\nTimeoutStartSec=310\n')
                    timer.write_text('[Timer]\nOnActiveSec=1d\nUnit=' + service.name + '\n[Install]\nWantedBy=timers.target\n')
                    for path in (service, timer):
                        assert run(['systemctl', '--user', 'link', str(path)]).returncode == 0
                    assert run(['systemctl', '--user', 'daemon-reload']).returncode == 0
                    if mode != 'inactive':
                        assert run(['systemctl', '--user', 'enable', '--now', timer.name]).returncode == 0
                        assert run(['systemctl', '--user', 'is-active', timer.name]).stdout.strip() == b'active'
                        assert run(['systemctl', '--user', 'start', '--no-block', service.name]).returncode == 0
                        for _ in range(100):
                            pid = run(['systemctl', '--user', 'show', service.name, '-p', 'MainPID', '--value']).stdout.strip()
                            if pid not in (b'', b'0'): break
                            time.sleep(.05)
                        assert pid not in (b'', b'0'), 'scratch oneshot did not enter flight'
                result = run(['bash', str(APP / 'install.sh')], env=env)
                success = mode in ('active', 'inactive', 'missing')
                assert (result.returncode == 0) == success, (mode, result.returncode, result.stderr.decode())
                assert all((units / unit).exists() != success for unit in UNITS), mode
                logged = [json.loads(line) for line in calls.read_text().splitlines()]
                assert any('show' in row and UNITS[1] in row for row in logged), mode
                if success:
                    if systemd:
                        for unit in aliases.values():
                            final = run(['systemctl', '--user', 'show', unit, '-p', 'ActiveState', '-p', 'MainPID']).stdout
                            assert b'ActiveState=inactive' in final or b'ActiveState=failed' in final, final
                            if unit.endswith('.service'):
                                assert b'MainPID=0' in final, final
                    else:
                        assert all(v['ActiveState'] == 'inactive' and v['MainPID'] == '0'
                                   for v in json.loads(state.read_text())['units'].values())
                else:
                    assert b'heartbeat' in result.stderr + result.stdout
            finally:
                if systemd:
                    for alias in aliases.values():
                        run(['systemctl', '--user', 'disable', '--now', alias])
                        run(['systemctl', '--user', 'reset-failed', alias])
                    run(['systemctl', '--user', 'daemon-reload'])
        print('DISABLE: non-dry installer 5 faults refused/files preserved; active/inactive/missing accepted; '
              + ('real timer + in-flight oneshot stopped' if systemd else 'queried state model confirmed'))


def check_calendar(timer, scratch):
    expression = next(line.split('=', 1)[1] for line in timer.read_text().splitlines()
                      if line.startswith('OnCalendar='))
    def occurrences(calendar):
        result = run(['systemd-analyze', 'calendar', calendar, '--iterations=8',
                      '--base-time=2026-09-01 00:00:00'],
                     env=dict(os.environ, TZ='America/Santiago', LC_ALL='C'))
        assert result.returncode == 0, result.stderr.decode()
        return [datetime.strptime(value, '%a %Y-%m-%d %H:%M:%S UTC').replace(tzinfo=timezone.utc)
                for value in re.findall(r'\(in UTC\): (.+)', result.stdout.decode())]
    old = occurrences('daily')
    assert len(old) == 8
    assert not any(now.date().isoformat() == '2026-09-06' for now in old)
    assert max(b - a for a, b in zip(old, old[1:])) == timedelta(hours=47)
    scheduled = occurrences(expression)
    assert len(scheduled) == 8
    assert all(b - a == timedelta(days=1) for a, b in zip(scheduled, scheduled[1:]))
    assert all(now.hour == now.minute == now.second == 0 for now in scheduled)
    assert [now.date().isoformat() for now in scheduled] == [f'2026-09-{day:02d}' for day in range(2, 10)]
    # Run the actual producer at each systemd-calculated instant, then ingest its
    # output through the collector's stable UTC identity validation.
    sys.path.insert(0, str(APP))
    producer = runpy.run_path(str(APP / 'heartbeat.py'))['main']
    sys.path.insert(0, str(APP / 'backend'))
    import devmon_messages as messages
    spool = scratch / 'calendar-spool'
    for name in ('new', 'tmp'):
        (spool / name).mkdir(parents=True)
    with patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false', 'TZ': 'America/Santiago'}), \
            patch.object(messages, '_local', threading.local()), patch.object(messages, '_DB_PATH', None):
        messages.init_db(str(scratch / 'calendar.db'))
        for now in scheduled:
            class Clock:
                @staticmethod
                def now(tz):
                    return now.astimezone(tz)
            with patch.dict(producer.__globals__, {'datetime': Clock}), \
                    patch.object(sys, 'argv', ['heartbeat', '--spool', str(spool)]):
                producer()
            queued = list((spool / 'new').glob('*.json'))
            assert len(queued) == 1
            payload = json.loads(queued[0].read_text())
            day = now.date().isoformat()
            assert payload['id'] == 'heartbeat:' + day
            assert payload['title'] == '살아 있음 ' + day
            with patch.object(messages, 'now_utc', return_value=now):
                assert messages.ingest(payload) == 'inserted'
            queued[0].unlink()
        assert messages._conn().execute("SELECT count(*) FROM cards c JOIN ledger l ON l.id=c.card_id WHERE l.source='heartbeat'").fetchone()[0] == 8
        messages._conn().close()
    print('CALENDAR: Santiago daily skips 2026-09-06 (47h); UTC schedule 8 days/24h; producer IDs/collector cards=8 aligned')


def check_date_boundary(scratch, webhook, posts):
    # Same delivery worker/HTTP transport as production, one deterministic pass.
    sys.path.insert(0, str(APP / 'backend'))
    import devmon_messages as messages
    import devmon_loop as loop
    from devmon_heartbeat import heartbeat_payload
    def drain():
        loop.deliver_once(webhook)
    dbpath = str(scratch / 'date-boundary.db')
    with patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false'}):
        messages.init_db(dbpath)
        first = datetime(2026, 9, 10, 0, 0, 20, tzinfo=timezone.utc)
        second = first + timedelta(hours=23, minutes=59, seconds=50)
        start_posts = len(posts)
        for now in (first, second):
            day = now.date().isoformat()
            payload = heartbeat_payload(now)
            with patch.object(messages, 'now_utc', return_value=now):
                if now == first:
                    # An ordinary producer cannot preempt the stable daily ID.
                    attempts = (dict(payload, source='ordinary', group='ordinary', level='normal'),
                                dict(payload, level='normal'))
                    for attempted in attempts:
                        try:
                            messages.ingest(attempted)
                        except messages.ValidationError:
                            pass
                        else:
                            raise AssertionError('invalid producer claimed a heartbeat ID')
                    assert messages._conn().execute('SELECT count(*) FROM cards').fetchone()[0] == 0
                    assert messages._conn().execute('SELECT count(*) FROM ledger').fetchone()[0] == 0
                assert messages.ingest(payload) == 'inserted'
                drain()
                if now == first:
                    assert messages._conn().execute("SELECT count(*) FROM cards c JOIN ledger l ON l.id=c.card_id WHERE l.source='heartbeat'").fetchone()[0] == 1
                    assert len(posts) - start_posts == 1
                # Reopen the database as a restarted collector would: stable ID
                # still deduplicates, with no new pending row or HTTP request.
                messages.init_db(dbpath)
                assert messages.ingest(payload) == 'duplicate'
                drain()
                if now == first:
                    assert len(posts) - start_posts == 1
                    print('HEARTBEAT ID: ordinary/nonurgent preemption refused; heartbeat cards=1 POSTs=1; restart duplicate POSTs=0')
                    alive = messages.get_card(payload['id'])
                    ordinary = {'id':'same-group','group':'heartbeat','source':'same-group',
                                'level':'normal','title':'Ordinary record','body':'Independent'}
                    assert messages.ingest(ordinary) == 'inserted'
                    assert messages.get_card('same-group')['level'] == 'normal'
                    assert messages.get_card(payload['id']) == alive
                    drain()
                    assert len(posts) - start_posts == 1
                    assert messages._conn().execute('SELECT count(*) FROM cards').fetchone()[0] == 2
                    print('SAME GROUP: ordinary normal accepted as separate card; canonical alive unchanged; additional POSTs=0')
            later = now + timedelta(hours=1)
            with patch.object(messages, 'now_utc', return_value=later):
                before = len(posts)
                assert messages.ingest(heartbeat_payload(later)) == 'duplicate'
                drain()
                assert len(posts) == before
        print('TIME: same UTC day +1h canonical re-publication duplicate; additional POSTs=0')
        count = messages._conn().execute("SELECT count(*) FROM cards c JOIN ledger l ON l.id=c.card_id WHERE l.source='heartbeat'").fetchone()[0]
        assert count == 2 and len(posts) - start_posts == 2
        # An offset timestamp that represents the same UTC day uses the same ID.
        offset = dict(payload)
        with patch.object(messages, 'now_utc', return_value=second):
            assert messages.ingest(offset) == 'duplicate'
            try:
                messages.ingest(dict(payload, id='heartbeat:2026-09-12'))
            except messages.ValidationError:
                pass
            else:
                raise AssertionError('heartbeat ID/date mismatch accepted')
        for index, now in enumerate((first, second)):
            generic = dict(payload, id='ordinary-' + str(index),
                           source='ordinary', group='ordinary', created_at=now.isoformat())
            with patch.object(messages, 'now_utc', return_value=now):
                assert messages.ingest(generic) == ('inserted' if index == 0 else 'coalesced')
                drain()
        assert messages._conn().execute("SELECT count(*) FROM cards c JOIN ledger l ON l.id=c.card_id WHERE l.source='ordinary'").fetchone()[0] == 1
        assert len(posts) - start_posts == 3
        normal = dict(payload, id='ordinary-normal', source='ordinary',
                      group='ordinary-normal', level='normal')
        with patch.object(messages, 'now_utc', return_value=second):
            assert messages.ingest(normal) == 'inserted'
        assert messages._conn().execute("SELECT level FROM cards WHERE [group]='ordinary-normal'").fetchone()[0] == 'normal'
        print('ORDINARY: unreserved normal message accepted unchanged')
        print('DATE: 23:59:50 across UTC dates cards=2 POSTs=2; restart duplicate POSTs=0; ordinary cards=1 POSTs=1')


def check_content_contract(scratch, webhook, posts):
    """Real producer -> collector -> HTTP; reject preemption before dedup storage."""
    sys.path.insert(0, str(APP / 'backend'))
    import devmon_messages as messages
    import devmon_spool as spool
    import devmon_loop as loop
    from examples.emit_message import emit
    queue = scratch / 'contract-spool'
    queue.mkdir()
    for name in ('new', 'tmp', 'processing', 'bad'):
        (queue / name).mkdir()
    result = run([sys.executable, str(APP / 'heartbeat.py'), '--spool', str(queue)])
    assert result.returncode == 0, result.stderr.decode()
    queued = next((queue / 'new').glob('*.json'))
    canonical = json.loads(queued.read_text())
    queued.unlink()
    day = canonical['id'].removeprefix('heartbeat:')
    assert canonical['title'] == '살아 있음 ' + day
    assert 'schema_version' not in canonical and canonical['level'] == 'urgent'
    assert canonical['id'] == 'heartbeat:' + day
    assert canonical['source'] == canonical['group'] == 'heartbeat'
    assert canonical['body'] == '하루 한 번 스풀부터 알림까지 도착하는 하트비트입니다.'
    page = dict(canonical, schema_version=2, severity='page', title='replacement content')
    del page['level']
    # The old implementation accepted this exact third-FIX case. Also exercise
    # content loss/substitution and behavior-changing extras, not just the title.
    variants = [page, dict(canonical, source='ordinary', group='ordinary'),
                dict(canonical, level='normal'), dict(canonical, title='replacement content'),
                dict(canonical, body='replacement body'),
                dict(canonical, needs_action=True), dict(canonical, owner='somebody'),
                dict(canonical, recommended_action={'cwd': '/tmp', 'prompt': 'act', 'explain': 'act'}),
                dict(canonical, kind='action', recommended_action={'cwd': '/tmp', 'prompt': 'act', 'explain': 'act'}),
                dict(canonical, kind='link', link={'url': 'https://example.test'}),
                dict(canonical, unknown_field='extra')]
    variants += [{key: value for key, value in canonical.items() if key != missing}
                 for missing in canonical]
    dbpath = str(scratch / 'contract.db')
    start_posts = len(posts)
    with patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES': 'false'}), \
            patch.object(messages, '_local', threading.local()), patch.object(messages, '_DB_PATH', None):
        messages.init_db(dbpath)
        for attempted in variants:
            # Malformed IDs cannot use emit(); the stable filename also checks
            # that quarantine releases the spool slot for the real producer.
            target = queue / 'new' / (canonical['id'] + '.json')
            target.write_text(json.dumps(attempted))
            counts = spool.scan_once(str(queue))
            assert counts.get('bad') == 1, (attempted, counts)
            for table in ('ledger', 'cards'):
                assert messages._conn().execute('SELECT count(*) FROM ' + table).fetchone()[0] == 0
        loop.deliver_once(webhook)
        assert len(posts) == start_posts
        assert emit(str(queue), canonical) == 'queued'
        assert spool.scan_once(str(queue)).get('inserted') == 1
        loop.deliver_once(webhook)
        assert len(posts) == start_posts + 1
        assert canonical['title'] in json.dumps(posts[-1], ensure_ascii=False)
        assert messages._conn().execute('SELECT title FROM cards').fetchone()[0] == canonical['title']
        messages._conn().close()
        messages._local.conn = None
        messages.init_db(dbpath)
        assert emit(str(queue), canonical) == 'queued'
        assert spool.scan_once(str(queue)).get('duplicate') == 1
        loop.deliver_once(webhook)
        assert len(posts) == start_posts + 1
        for table in ('ledger', 'cards'):
            assert messages._conn().execute('SELECT count(*) FROM ' + table).fetchone()[0] == 1
        messages._conn().close()
    print(f'CONTENT: variants={len(variants)} quarantined, ledger/cards=0; '
          'canonical alive cards=1 POSTs=1; reopened DB duplicate POSTs=0')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--systemd', action='store_true')
    parser.add_argument('--calendar-only', action='store_true')
    parser.add_argument('--disable-only', action='store_true')
    args = parser.parse_args()
    if args.disable_only:
        check_disable(args.systemd)
        return
    if args.calendar_only:
        with tempfile.TemporaryDirectory(prefix='devmon-calendar-') as tmp:
            check_calendar(APP / 'systemd/airlock-devmon-heartbeat.timer.in', Path(tmp))
        return
    posts = []
    class Recorder(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            posts.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')
        def log_message(self, *unused):
            pass
    recorder = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
    threading.Thread(target=recorder.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='devmon-heartbeat-test-') as tmp:
        scratch = Path(tmp)
        home = scratch / 'home'
        private = home / '.config/airlock'
        private.mkdir(parents=True)
        secret = private / 'dev-monitor-secrets.env'
        secret.write_text(f'TEST_HEARTBEAT_HOOK=http://127.0.0.1:{recorder.server_port}/webhook\n')
        secret.chmod(0o600)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = scratch / 'airlock.toml'
        config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                          '[apps.hub]\n[apps.dev-monitor]\nmessages=true\n'
                          f'backend_port={port}\nslack_webhook_urgent_env="TEST_HEARTBEAT_HOOK"\n')
        env = {'HOME': str(home), 'PATH': '/usr/local/bin:/usr/bin:/bin',
               'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(APP),
               'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(config),
               'AIRLOCK_DRY_RUN': '1', 'AIRLOCK_RENDER_DIR': str(scratch / 'render'),
               'AIRLOCK_TS_FQDN': 'box.example.test',
               'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592'}
        result = run(['bash', str(APP / 'install.sh')], env=env)
        assert result.returncode == 0, result.stderr.decode()
        assert b'enable --now airlock-devmon-heartbeat.timer' in result.stdout + result.stderr
        rendered = scratch / 'render/units'
        service = rendered / UNITS[0]
        timer = rendered / UNITS[1]
        assert 'TimeoutStartSec=30' in service.read_text()
        assert 'OnCalendar=*-*-* 00:00:00 UTC' in timer.read_text() and 'Persistent=true' in timer.read_text()
        manifest = tomllib.loads((APP / 'airlock-app.toml').read_text())
        assert manifest['artifacts']['units'][:3] == [UNITS[1], UNITS[0], 'airlock-dev-monitor.service']
        argv = shlex.split(next(line.split('=', 1)[1] for line in service.read_text().splitlines()
                                if line.startswith('ExecStart=')))
        # Missing spool must fail without silently creating an unconsumed queue.
        failed = run(argv, env=env)
        assert failed.returncode != 0
        state = home / '.local/state/airlock/dev-monitor'
        state.mkdir(parents=True, exist_ok=True)
        state.chmod(0o710)
        for name, mode in {'': 0o710, 'new': 0o3770, 'tmp': 0o3770,
                           'processing': 0o700, 'bad': 0o700}.items():
            path = state / 'spool' / name
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(mode)
        # Pin the producer's accepted wire contract before letting a collector drain it.
        assert run(argv, env=env).returncode == 0
        queued = list((state / 'spool/new').glob('*.json'))
        assert len(queued) == 1
        payload = json.loads(queued[0].read_text())
        assert payload['level'] == 'urgent' and 'schema_version' not in payload
        assert payload['source'] == payload['group'] == 'heartbeat'
        assert payload['title'] == '살아 있음 ' + payload['id'].removeprefix('heartbeat:')
        assert not payload['id'].startswith('dev-monitor:')
        assert run(argv, env=env).returncode == 0
        assert len(list((state / 'spool/new').glob('*.json'))) == 1
        queued[0].unlink()  # The measured runtime starts empty and publishes once below.
        runtime = dict(env)
        for path in (secret, scratch / 'render/files/dev-monitor.env'):
            for line in path.read_text().splitlines():
                if line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    runtime[key] = value
        runtime.update(AIRLOCK_DEV_MONITOR_MESSAGES='true', AIRLOCK_DEV_MONITOR_BACKEND_PORT=str(port))
        linked = []
        log = scratch / 'backend.log'
        with log.open('wb') as stream:
            backend = subprocess.Popen([sys.executable, str(APP / 'backend/airlock-dev-monitor.py')],
                                       env=runtime, stdout=stream, stderr=subprocess.STDOUT)
            try:
                for _ in range(150):
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/health', timeout=2) as response:
                            health = json.load(response)
                        assert health['messages'] == 'on' and health['slack'] == 'configured', health
                        break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise AssertionError('backend did not become ready')
                if args.systemd:
                    # Preflight ownership: refuse even an inactive pre-existing unit.
                    for unit in UNITS:
                        status = run(['systemctl', '--user', 'show', '-p', 'LoadState', '--value', unit])
                        assert status.stdout.strip() == b'not-found', 'existing unit: ' + unit
                    for unit in UNITS:
                        assert run(['systemctl', '--user', 'link', str(rendered / unit)]).returncode == 0
                        linked.append(unit)
                    assert run(['systemctl', '--user', 'daemon-reload']).returncode == 0
                    assert run(['systemctl', '--user', 'enable', '--now', UNITS[1]]).returncode == 0
                    assert run(['systemctl', '--user', 'is-enabled', UNITS[1]]).stdout.strip() == b'enabled'
                    schedule = run(['systemctl', '--user', 'list-timers', UNITS[1], '--no-pager'])
                    assert UNITS[1].encode() in schedule.stdout
                    next_elapse = run(['systemctl', '--user', 'show', '-p', 'NextElapseUSecRealtime', '--value', UNITS[1]])
                    assert next_elapse.stdout.strip() not in (b'', b'n/a')
                    print('TIMER: enabled; ' + next_elapse.stdout.decode().strip())
                    assert run(['systemctl', '--user', 'start', UNITS[0]]).returncode == 0
                else:
                    assert run(argv, env=env).returncode == 0
                def heartbeat_posts():
                    return [post for post in posts if payload['title'] in json.dumps(post, ensure_ascii=False)]
                count = 0
                for _ in range(200):
                    with sqlite3.connect(state / 'messages.db') as db:
                        count = db.execute("SELECT count(*) FROM cards c JOIN ledger l ON l.id=c.card_id WHERE l.source='heartbeat'").fetchone()[0]
                    if count == 1 and len(heartbeat_posts()) == 1:
                        break
                    time.sleep(.1)
                assert run(argv, env=env).returncode == 0
                time.sleep(2.5)  # Observe a further poll; duplicate publishing must not double-send.
                assert count == 1 and len(heartbeat_posts()) == 1, (count, len(heartbeat_posts()))
                print('VERIFY 5: cards source=heartbeat rows=1; Slack HTTP recorder POSTs=1')
            finally:
                if linked:
                    run(['systemctl', '--user', 'disable', '--now', UNITS[1]])
                    run(['systemctl', '--user', 'stop', UNITS[0]])
                    for unit in linked:
                        run(['systemctl', '--user', 'disable', unit])
                        run(['systemctl', '--user', 'reset-failed', unit])
                    run(['systemctl', '--user', 'daemon-reload'])
                backend.terminate()
                backend.wait(timeout=10)
        timer_source = scratch / 'rendered-heartbeat.timer'
        timer_source.write_bytes(timer.read_bytes())
        # Existing captured units exercise the messages=false removal branch.
        config.write_text(config.read_text().replace('messages=true', 'messages=false'))
        result = run(['bash', str(APP / 'install.sh')], env=env)
        assert result.returncode == 0, result.stderr.decode()
        assert not service.exists() and not timer.exists()
        assert b'disable --now airlock-devmon-heartbeat.timer' in result.stdout + result.stderr
        print('INSTALL: manifest+render+enable+disable+remove paths PASS; missing spool refused')
        check_calendar(timer_source, scratch)
        check_date_boundary(scratch, f'http://127.0.0.1:{recorder.server_port}/webhook', posts)
        check_content_contract(scratch, f'http://127.0.0.1:{recorder.server_port}/webhook', posts)
    recorder.shutdown()
    recorder.server_close()
    check_disable(args.systemd)
    print('heartbeat contract: PASS')


if __name__ == '__main__':
    main()
