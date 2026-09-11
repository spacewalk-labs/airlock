#!/usr/bin/env python3
"""Actual spool, SQLite, owner HTTP and local webhook contract; no live services."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request
import uuid
from unittest.mock import patch

APP = Path(__file__).resolve().parent
sys.path.insert(0, str(APP / 'backend'))
sys.path.insert(0, str(APP))
import devmon_messages as messages
import devmon_spool as spool
import devmon_loop as loop
from examples.emit_message import emit


def check_alarm():
    with tempfile.TemporaryDirectory(prefix='devmon-alarm-') as tmp:
        root = Path(tmp)
        (root / 'bin').mkdir()
        journal = root / 'bin/journalctl'
        journal.write_text('#!/bin/sh\nexit 0\n')
        journal.chmod(0o755)
        queue = root / 'spool'
        for name in spool.SUBDIRS:
            (queue / name).mkdir(parents=True)
        env = {**os.environ, 'DEV_MONITOR_SPOOL': str(queue),
               'DEV_MONITOR_TOKEN_SNAPSHOT': str(root / 'snapshot.json'),
               'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH']}
        result = subprocess.run(['bash', str(APP / 'token-freshness-alarm.sh')],
                                env=env, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        files = list((queue / 'new').glob('*.json'))
        assert len(files) == 1, 'alarm must publish one message'
        payload = json.loads(files[0].read_text())
        normalized = messages.validate_payload(payload)
        assert normalized['level'] == 'urgent'
        for text in ('failed at', 'periodic credential check did not complete',
                     'verdict ages silently', 'systemctl --user status'):
            assert text in normalized['body'], text
        assert (root / 'TOKEN-FRESHNESS-LAST-FAILURE').exists()
        assert not (root / 'TOKEN-FRESHNESS-PUBLISH-FAILING').read_text().startswith('usage:')


def check():
    posts = []
    class Recorder(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            posts.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        def log_message(self, *args): pass
    with tempfile.TemporaryDirectory(prefix='devmon-wire-') as tmp, patch.dict(os.environ, {'AIRLOCK_DEV_MONITOR_MESSAGES':'false'}):
        root = Path(tmp)
        queue = root / 'spool'
        for name in spool.SUBDIRS: (queue / name).mkdir(parents=True)
        messages._local = threading.local()
        messages.init_db(str(root / 'messages.db'))
        recorder = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
        threading.Thread(target=recorder.serve_forever, daemon=True).start()
        hook = f'http://127.0.0.1:{recorder.server_port}/hook'
        ids = ['old-' + uuid.uuid4().hex, 'new-' + uuid.uuid4().hex]
        old = {'schema_version':1, 'event_id':ids[0], 'group_key':ids[0], 'source':'contract',
               'urgency':'urgent', 'kind':'info', 'title':'Legacy urgency card', 'body':'Legacy body <text>',
               'created_at':messages.iso(messages.now_utc()), 'outcome':'kept','why_it_matters':'kept','followup':'none'}
        new = {'id':ids[1], 'group':ids[1], 'source':'contract','level':'urgent',
               'title':'New level card','body':'New body <text>','link':'https://example.test/result',
               'run':{'cwd':'/tmp/project','prompt':'Check present state'}}
        try:
            for payload in (old, new):
                assert emit(str(queue), payload) == 'queued'
                assert spool.scan_once(str(queue))['inserted'] == 1
                loop.deliver_once(hook)
                assert emit(str(queue), payload) == 'queued'
                assert spool.scan_once(str(queue))['duplicate'] == 1
                loop.deliver_once(hook)
            assert len(posts) == 2
            for payload in (old,new):
                assert sum(payload['title'] in post['text'] for post in posts) == 1
            assert messages._conn().execute('SELECT count(*) FROM cards').fetchone()[0] == 2
            assert messages._conn().execute("SELECT count(*) FROM cards WHERE sent_at IS NOT NULL").fetchone()[0] == 2
            spec = importlib.util.spec_from_file_location('wire_backend', APP / 'backend/airlock-dev-monitor.py')
            backend = importlib.util.module_from_spec(spec); spec.loader.exec_module(backend)
            backend.OWNER_CONFIG = {'owner':'owner@example.test','secret':'synthetic-proxy',
                                    'spool':str(queue),'db':str(root / 'messages.db')}
            backend._MESSAGES_STATE = 'on'
            server = http.server.ThreadingHTTPServer(('127.0.0.1',0), backend.Handler)
            threading.Thread(target=server.serve_forever,daemon=True).start()
            base = f'http://127.0.0.1:{server.server_port}'
            headers = {'X-Devmon-Owner':'owner@example.test','X-Devmon-Proxy-Secret':'synthetic-proxy'}
            def get(path, owner=True):
                request = urllib.request.Request(base+path,headers=headers if owner else {})
                with urllib.request.urlopen(request,timeout=3) as response: return json.load(response)
            try:
                feed = get('/api/owner/messages')
                assert {c['card_id'] for c in feed['messages']} == set(ids)
                keys = {'card_id','group','source','level','title','body','link','run','first_at','last_at',
                        'count','read_at','sent_at','archived','ran_at','send_attempts','send_next_at','delivery'}
                assert all(set(c)==keys and c['level']=='urgent' and c['count']==1 for c in feed['messages'])
                assert feed['counts'] == {'active':2,'urgent':2,'unread':2,'archived':0}
                try: get('/api/owner/messages',False)
                except urllib.error.HTTPError as error: assert error.code==403
                else: raise AssertionError('non-owner admitted')
                health = get('/api/health',False)
                assert health['pending_count']==0 and health['failed_count']==0 and health['last_sent_at']
                assert 'message_lanes' not in health
                # The actual owner mutations remain reachable after the state-axis removal.
                for action in ('read','archive'):
                    req=urllib.request.Request(base+'/api/owner/messages/'+ids[0]+'/'+action,data=b'{}',
                        headers={**headers,'Content-Type':'application/json','Origin':base},method='POST')
                    with urllib.request.urlopen(req,timeout=3) as response: assert response.status==200
                assert get('/api/owner/messages')['counts']['archived']==1
                for retired in ('pin','unpin','dismiss','undismiss'):
                    req=urllib.request.Request(base+'/api/owner/messages/'+ids[0]+'/'+retired,data=b'{}',
                        headers={**headers,'Content-Type':'application/json','Origin':base},method='POST')
                    try: urllib.request.urlopen(req,timeout=3)
                    except urllib.error.HTTPError as error: assert error.code==404
                    else: raise AssertionError('retired mutation accepted')
                with messages._conn():
                    messages._conn().execute('UPDATE cards SET sent_at=NULL,send_attempts=6,send_next_at=NULL WHERE card_id=?',(ids[1],))
                failed = get('/api/owner/messages')['messages'][0]
                assert failed['delivery']=='failed'
                return {'feed':feed,'failed':failed,'health':health,'posts':len(posts),'ids':ids}
            finally: server.shutdown();server.server_close()
        finally: recorder.shutdown();recorder.server_close();messages._conn().close()


if __name__=='__main__':
    check_alarm()
    result=check()
    print(json.dumps(result,ensure_ascii=False) if '--json' in sys.argv else
          'WIRE: v1 urgency/new level cards=2 POSTs=2 (one each); replay POSTs=0; API shape/owner/read/archive PASS')
