#!/usr/bin/env python3
"""Offline legacy-to-endstate row mapping. No service or producer control."""
import json
import shlex
import sqlite3

from devmon_messages import _SCHEMA, MAX_DELIVERY_ATTEMPTS, iso, now_utc


def _run(raw):
    if not raw:
        return None
    action = json.loads(raw)
    if not isinstance(action, dict) or not isinstance(action.get('cwd'), str):
        return None
    prompt = action.get('prompt')
    if not prompt and action.get('skill'):
        prompt = '/' + action['skill']
    if not prompt and action.get('exec'):
        prompt = 'Check current state and, if appropriate, run: ' + shlex.join(action['exec'])
    if not isinstance(prompt,str) or not prompt.strip():
        return None
    return json.dumps({'cwd':action['cwd'],'prompt':prompt})


def convert(source, target):
    """Write a new offline file. Keep every card and exactly the original receipts."""
    old = sqlite3.connect('file:'+str(source)+'?mode=ro',uri=True)
    old.row_factory = sqlite3.Row
    new = sqlite3.connect(target)
    report = {}
    try:
        new.executescript(_SCHEMA)
        tables = {r[0] for r in old.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'cards','occurrences','deliveries'} <= tables:
            raise ValueError('legacy database is missing required tables')
        with new:
            for receipt in old.execute('SELECT * FROM occurrences'):
                # Preserve raw historical payloads, including old system wrappers.
                raw = json.loads(receipt['payload_json'])
                source_name = raw.get('source','') if isinstance(raw,dict) else ''
                if not source_name:
                    card = old.execute('SELECT source FROM cards WHERE card_id=?', (receipt['card_id'],)).fetchone()
                    source_name = card[0] if card else ''
                new.execute('INSERT INTO ledger VALUES(?,?,?,?,?)',
                            (receipt['event_id'],receipt['group_key'],source_name,
                             receipt['received_at'],receipt['payload_json']))
            for row in old.execute('SELECT * FROM cards'):
                card = dict(row)
                level = card['urgency']
                if level not in ('normal','urgent'):
                    raise ValueError('unsupported urgency value')
                link = json.loads(card['link_json']) if card['link_json'] else None
                if isinstance(link,dict):
                    link = link.get('url')
                deliveries = [dict(r) for r in old.execute('SELECT * FROM deliveries WHERE card_id=?',(card['card_id'],))]
                queued = [d for d in deliveries if d['status'] in ('pending','claimed')]
                sent = card.get('slack_sent_at') or next((d['sent_at'] for d in deliveries if d['status']=='sent'),None)
                attempts = max((d['attempts'] for d in deliveries),default=0)
                due = None
                if queued:
                    # A claimed last attempt may have died before its POST. Leave one
                    # attempt available to drain it; there is no proof it was delivered.
                    attempts = min(MAX_DELIVERY_ATTEMPTS-1,max(d['attempts'] for d in queued))
                    sent = None
                    due = min((d.get('next_attempt_at') or iso(now_utc())) for d in queued)
                    if any(d['status']=='claimed' for d in queued):
                        due = iso(now_utc())
                elif not sent and any(d['status']=='failed' for d in deliveries):
                    attempts = MAX_DELIVERY_ATTEMPTS
                new.execute('INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                    (card['card_id'],card['group_key'],level,card['title'],card['body'],link,
                     _run(card['action_json']),card['occurrence_count'],card['received_at'],
                     card['last_seen'],card['read_at'],card['archived_at'] or card.get('dismissed_at'),
                     card.get('ran_at'),sent,attempts,due))
            report = {table:old.execute('SELECT COUNT(*) FROM "'+table+'"').fetchone()[0]
                      for table in tables if table != 'sqlite_sequence'}
            counts = dict(new.execute("SELECT 'cards',COUNT(*) FROM cards UNION ALL SELECT 'ledger',COUNT(*) FROM ledger"))
            if counts != {'cards':report['cards'],'ledger':report['occurrences']}:
                raise ValueError('row count mismatch')
            # Compare receipt identity, payload, group, and time, not just totals.
            expected = set(old.execute('SELECT event_id,group_key,received_at,payload_json FROM occurrences'))
            actual = set(new.execute('SELECT id,"group",received_at,payload FROM ledger'))
            if {tuple(r) for r in expected} != actual:
                raise ValueError('receipt mapping mismatch')
            old_ids = {r[0] for r in old.execute('SELECT card_id FROM cards')}
            if old_ids != {r[0] for r in new.execute('SELECT card_id FROM cards')}:
                raise ValueError('card identity mismatch')
            if new.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('integrity check failed')
        report['pending_deliveries'] = old.execute("SELECT COUNT(*) FROM deliveries WHERE status IN ('pending','claimed')").fetchone()[0]
        report['pending_cards'] = old.execute("SELECT COUNT(DISTINCT card_id) FROM deliveries WHERE status IN ('pending','claimed')").fetchone()[0]
        if old.execute("SELECT COUNT(*) FROM deliveries d WHERE status IN ('pending','claimed') AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.card_id=d.card_id)").fetchone()[0]:
            raise ValueError('queued delivery has no card')
        report.update({'new_cards':counts['cards'],'new_ledger':counts['ledger'],'integrity':'ok'})
        return report
    finally:
        old.close()
        new.close()
