#!/usr/bin/env python3
"""Offline V14 on an explicitly supplied DB COPY and preceding backend checkout.

Never starts/stops installed services or posts to a configured webhook. All writes
are to a temporary rehearsal directory; output contains counts only.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import uuid
from datetime import timedelta
from unittest.mock import patch

APP=Path(__file__).resolve().parent
sys.path.insert(0,str(APP/'backend'))
sys.path.insert(0,str(APP))
import devmon_messages as M
import devmon_loop as loop
import devmon_spool as spool
from devmon_heartbeat import heartbeat_payload
from examples.emit_message import emit


def contents(db):
    return {r[0]:db.execute('SELECT * FROM "'+r[0]+'" ORDER BY rowid').fetchall()
            for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def run(copy, old_backend):
    source=sqlite3.connect(copy.resolve().as_uri()+'?mode=ro',uri=True)
    original=contents(source)
    posts=[]
    class Recorder(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            posts.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200);self.end_headers()
        def log_message(self,*args): pass
    with tempfile.TemporaryDirectory(prefix='devmon-rehearsal-') as tmp, \
            patch.dict(os.environ,{'AIRLOCK_DEV_MONITOR_MESSAGES':'false'}):
        root=Path(tmp);dbpath=root/'messages.db'
        target=sqlite3.connect(dbpath);source.backup(target);target.close();os.chmod(dbpath,0o600)
        command=[sys.executable,str(APP/'migrate-legacy-state.py')]
        result=subprocess.run(command+['--endstate',str(dbpath),'--offline'],capture_output=True,text=True)
        assert result.returncode==0,result.stderr
        backup=dbpath.with_name('messages.db.pre-endstate')
        saved=sqlite3.connect(backup)
        assert contents(saved)==original
        assert saved.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        saved.close()
        M._local=threading.local();M.init_db(str(dbpath))
        db=M._conn()
        assert {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}=={'ledger','cards'}
        old_cards=source.execute('SELECT COUNT(*) FROM cards').fetchone()[0]
        old_receipts=source.execute('SELECT COUNT(*) FROM occurrences').fetchone()[0]
        missing=source.execute('SELECT COUNT(*) FROM cards c WHERE NOT EXISTS(SELECT 1 FROM occurrences o WHERE o.card_id=c.card_id)').fetchone()[0]
        assert db.execute('SELECT COUNT(*) FROM cards').fetchone()[0]==old_cards
        assert db.execute('SELECT COUNT(*) FROM ledger').fetchone()[0]==old_receipts
        assert {r[0] for r in source.execute('SELECT card_id FROM cards')}=={r[0] for r in db.execute('SELECT card_id FROM cards')}
        old_fields='card_id,group_key,urgency,title,body,occurrence_count,received_at,last_seen,read_at'
        new_fields='card_id,[group],level,title,body,count,first_at,last_at,read_at'
        assert source.execute('SELECT '+old_fields+' FROM cards ORDER BY card_id').fetchall()==[tuple(r) for r in db.execute('SELECT '+new_fields+' FROM cards ORDER BY card_id')]
        assert source.execute('SELECT event_id,group_key,received_at,payload_json FROM occurrences ORDER BY event_id').fetchall()==[tuple(r) for r in db.execute('SELECT id,[group],received_at,payload FROM ledger ORDER BY id')]
        pending=source.execute("SELECT COUNT(*) FROM deliveries WHERE status IN ('pending','claimed')").fetchone()[0]
        assert pending==0,'This actual-copy oracle expects separate synthetic drain coverage.'
        assert M.delivery_health()['pending_count']==0
        print('REAL COPY: cards=%d ledger=%d receiptless_cards=%d pending/claimed=%d integrity=ok; all card IDs/core fields/receipt tuples preserved' % (old_cards,old_receipts,missing,pending))
        print('BACKUP: '+','.join('%s=%d'%(name,len(rows)) for name,rows in sorted(original.items()))+'; exact table contents unchanged')
        queue=root/'spool';spool.ensure_dirs(str(queue))
        heartbeat=heartbeat_payload(M.now_utc()+timedelta(days=1))
        while M.has_receipt(heartbeat['id']):
            day=M.parse_rfc3339(heartbeat['id'].split(':',1)[1]+'T00:00:00Z')
            heartbeat=heartbeat_payload(day+timedelta(days=1))
        normal={'id':'rollback-'+uuid.uuid4().hex,'group':'rollback-'+uuid.uuid4().hex,
                'source':'contract','level':'normal','title':'Rollback receipt','body':'Preserve'}
        server=http.server.HTTPServer(('127.0.0.1',0),Recorder)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:
            for payload in (heartbeat,normal): assert emit(str(queue),payload)=='queued'
            assert spool.scan_once(str(queue))['inserted']==2
            assert loop.deliver_once('http://127.0.0.1:%d/hook'%server.server_port)
            assert len(posts)==1 and heartbeat['title'] in posts[0]['text']
            assert M.get_card(heartbeat['id'])['sent_at']
        finally:
            server.shutdown();server.server_close();worker.join()
        print('CUTOVER HEARTBEAT: canonical alive card1 local_POST1 sent_at=1')
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)');db.close();M._local=threading.local()
        result=subprocess.run(command+['--restore-backup',str(backup),'--restore-to',str(dbpath),'--offline'],capture_output=True,text=True)
        assert result.returncode==0,result.stderr
        restored=sqlite3.connect(dbpath)
        assert contents(restored)==original
        restored.close()
        child='''import json,sys,threading
sys.path.insert(0,sys.argv[1])
import devmon_messages as M,devmon_spool as S
M._local=threading.local();M.init_db(sys.argv[2]);M.set_slack_enabled(True)
r=S.scan_once(sys.argv[3]);assert r['inserted']==2,r
for event_id in sys.argv[4:]:
    assert M._conn().execute('SELECT COUNT(*) FROM occurrences WHERE event_id=?',(event_id,)).fetchone()[0]==1
print('OLD CODE: restored startup=ok retained_spool_inserted=2 missing=0')
'''
        result=subprocess.run([sys.executable,'-c',child,str(old_backend),str(dbpath),str(queue),heartbeat['id'],normal['id']],capture_output=True,text=True)
        assert result.returncode==0,result.stderr
        print(result.stdout.strip())
        assert contents(source)==original
        print('ROLLBACK: restored tables exact; old collector replayed post-cutover files; source copy unchanged; loss=0')
    source.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--copy',type=Path,required=True)
    parser.add_argument('--old-backend',type=Path,required=True)
    args=parser.parse_args()
    run(args.copy,args.old_backend)
