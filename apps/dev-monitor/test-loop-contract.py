#!/usr/bin/env python3
"""Actual local HTTP, fake-clock retries, process death, spool replay and idle threads."""
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

APP = Path(__file__).resolve().parent
sys.path.insert(0,str(APP/'backend'))
sys.path.insert(0,str(APP))
import devmon_messages as M
import devmon_loop as loop
import devmon_spool as spool
from examples.emit_message import emit


def open_db(root):
    M._local = threading.local()
    M.init_db(str(root/'messages.db'))
    spool.ensure_dirs(str(root/'spool'))


def payload(name, level='urgent'):
    return {'id':name,'group':name,'source':'contract','level':level,'title':name,'body':'Body'}


class Recorder(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.server.posts.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(self.server.code)
        if self.server.code == 429:
            self.send_header('Retry-After','1')
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self,*args):
        pass


def retries(root, server, hook):
    controls = 0
    for code in (500,429,400):
        case = root/str(code);case.mkdir()
        open_db(case)
        server.code = code
        before = len(server.posts)
        now = datetime(2026,9,10,tzinfo=timezone.utc)
        delays = []
        with patch.object(M,'now_utc',side_effect=lambda: now), \
                patch.object(M.random,'uniform',side_effect=lambda a,b:b/2) as jitter:
            assert emit(str(case/'spool'),payload('retry')) == 'queued'
            for attempt in range(6):
                assert emit(str(case/'spool'),payload('normal-'+str(attempt),'normal')) == 'queued'
                loop.tick(str(case/'spool'),hook)
                card = M.get_card('retry')
                assert card['send_attempts'] == attempt+1
                assert M._conn().execute('SELECT COUNT(*) FROM ledger').fetchone()[0] == attempt+2
                if attempt < 5:
                    due = M.parse_rfc3339(card['send_next_at'])
                    delays.append((due-now).total_seconds())
                    now = due
            assert card['delivery']=='failed' and card['sent_at'] is None
            assert M.delivery_health()=={'pending_count':0,'last_sent_at':None,'failed_count':1}
            loop.tick(str(case/'spool'),hook)
            assert len(server.posts)-before == 6
            assert delays == [45,90,180,360,720] and jitter.call_count==5
        print('RETRY HTTP%d: total_attempts=6 (initial included), jitter delays=%s; collected=7 failed=1' % (code,delays))
        M._conn().close()
        controls += 1
    return controls


def fault(root,server,hook):
    case=root/'fault';case.mkdir();open_db(case)
    assert emit(str(case/'spool'),payload('fault'))=='queued'
    assert spool.scan_once(str(case/'spool'))['inserted']==1
    M._conn().close();M._local=threading.local()
    server.code=200;before=len(server.posts)
    command=[sys.executable,__file__,'--send',str(case),hook]
    killed=subprocess.run(command+['--kill'],capture_output=True,timeout=8)
    assert killed.returncode == -signal.SIGKILL,killed.stderr
    M._local=threading.local()
    assert M.get_card('fault')['sent_at'] is None
    assert M.get_card('fault')['send_attempts']==0
    M._conn().close();M._local=threading.local()
    resumed=subprocess.run(command,capture_output=True,timeout=8)
    assert resumed.returncode==0,resumed.stderr
    assert len(server.posts)-before==2
    assert M.get_card('fault')['sent_at']
    assert M._conn().execute('SELECT COUNT(*) FROM ledger').fetchone()[0]==1
    print('FAULT: SIGKILL after POST before commit; restart total_POSTs=2 ledger=1 sent=1 missing=0')
    M._conn().close()
    return len(server.posts)-before


def retention(root):
    case=root/'retention';case.mkdir();open_db(case)
    before=datetime(2026,1,1,tzinfo=timezone.utc)
    with patch.object(M,'now_utc',return_value=before):
        assert emit(str(case/'spool'),payload('expire','normal'))=='queued'
        spool.scan_once(str(case/'spool'))
    receipt=case/'spool/processing/expire.json'
    assert receipt.exists()
    with patch.object(M,'now_utc',return_value=before+timedelta(days=179)):
        loop.tick(str(case/'spool'),'',cleanup=True)
        assert M.has_receipt('expire') and receipt.exists()
    with patch.object(M,'now_utc',return_value=before+timedelta(days=181)):
        loop.tick(str(case/'spool'),'',cleanup=True)
        assert not M.has_receipt('expire') and not receipt.exists()
        assert spool.scan_once(str(case/'spool'))['inserted']==0
    print('RETENTION: day179 retained; day181 ledger/card/spool expired; resurrection=0')
    M._conn().close()


def threads(root):
    case=root/'backend';case.mkdir()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    queue=case/'spool'
    spool.ensure_dirs(str(queue))
    # Instrument names/native IDs only; execute the actual backend main unchanged.
    runner=case/'start.py'
    runner.write_text('''import json,os,runpy,threading
start=threading.Thread.start
path=os.environ['THREAD_RECORD']
def record(self):
    start(self)
    with open(path,'a') as f: f.write(json.dumps([self.native_id,self.name])+'\\n')
threading.Thread.start=record
with open(path,'w') as f: f.write(json.dumps([threading.get_native_id(),'HTTP'])+'\\n')
runpy.run_path(os.environ['BACKEND_SCRIPT'],run_name='__main__')
''')
    env={'PATH':os.environ['PATH'],'HOME':str(case),'AIRLOCK_DEV_MONITOR_MESSAGES':'1',
         'AIRLOCK_DEV_MONITOR_BACKEND_PORT':str(port),'DEV_MONITOR_OWNER':'owner@example.test',
         'DEV_MONITOR_PROXY_SECRET':'synthetic','DEV_MONITOR_DB':str(case/'messages.db'),
         'DEV_MONITOR_SPOOL':str(queue),'THREAD_RECORD':str(case/'threads.jsonl'),
         'BACKEND_SCRIPT':str(APP/'backend/airlock-dev-monitor.py')}
    proc=subprocess.Popen([sys.executable,str(runner)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        import urllib.request
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            if proc.poll() is not None:
                raise AssertionError(proc.communicate()[1])
            try:
                with urllib.request.urlopen('http://127.0.0.1:%d/api/health'%port,timeout=1) as response:
                    assert json.load(response)['messages']=='on'
                break
            except OSError:
                time.sleep(.05)
        else: raise AssertionError('backend did not become healthy')
        expected={'HTTP','loop','history_sampler','top_sampler'}
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            live={int(p.name) for p in Path('/proc/%d/task'%proc.pid).iterdir()}
            records=dict(json.loads(line) for line in (case/'threads.jsonl').read_text().splitlines())
            names={records.get(tid,'unrecorded') for tid in live}
            if names==expected and len(live)==4: break
            time.sleep(.05)
        assert names==expected and len(live)==4,(live,names)
        db=sqlite3.connect(case/'messages.db')
        tables={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")};db.close()
        assert tables=={'ledger','cards'},tables
        print('IDLE: tables=cards,ledger; permanent_threads=4 HTTP,loop,history_sampler,top_sampler (request thread gone)')
    finally:
        proc.terminate()
        proc.communicate(timeout=8)


def main():
    if '--send' in sys.argv:
        root=Path(sys.argv[2]);open_db(root)
        loop.deliver_once(sys.argv[3],after_post=(lambda:os.kill(os.getpid(),signal.SIGKILL)) if '--kill' in sys.argv else None)
        return
    with tempfile.TemporaryDirectory(prefix='devmon-loop-') as tmp, patch.dict(os.environ,{'AIRLOCK_DEV_MONITOR_MESSAGES':'false'}):
        root=Path(tmp)
        server=http.server.HTTPServer(('127.0.0.1',0),Recorder)
        server.posts=[];server.code=200
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        hook='http://127.0.0.1:%d/hook'%server.server_port
        try:
            retry_controls = retries(root,server,hook)
            crash_posts = fault(root,server,hook)
            retention(root)
            threads(root)
            revision = subprocess.check_output(
                ['git', 'rev-parse', '--short=12', 'HEAD'], text=True, cwd=APP.parent.parent
            ).strip()
            print('AC-5 | expected: retry_controls == 3 && crash_posts == 2 | '
                  'observed: retry_controls=%d,crash_posts=%d | verdict: PASS | '
                  'signal: fixture | evidence: apps/dev-monitor/test-loop-contract.py@%s'
                  % (retry_controls, crash_posts, revision))
        finally:
            server.shutdown();server.server_close();worker.join()


if __name__=='__main__':
    main()
