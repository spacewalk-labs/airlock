#!/usr/bin/env python3
"""Append-only receipts (180 days), mutable daily cards, and delivery state."""
import json
import os
import random
import re
import sqlite3
import threading
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse
from devmon_heartbeat import heartbeat_payload

ID_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}\Z')
RESERVED_GROUP_PREFIX = 'dev-monitor:'
MAX_PAYLOAD = 16 * 1024
MAX_URL = 2048
MAX_RUN_PARAMS = 8
MAX_PARAM_CHOICES = 32
MAX_PARAM_TEXT = 200
ARCHIVE_IDLE = timedelta(hours=48)
ARCHIVE_ACTIVE_MIN = 20
RETENTION = timedelta(days=180)
FUTURE_SKEW = timedelta(minutes=5)
_local = threading.local()
_DB_PATH = None


def now_utc():
    return datetime.now(timezone.utc)

def iso(dt):
    return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')

def parse_rfc3339(s):
    """Accept timezone-aware RFC3339 only. Raises ValueError on failure."""
    if not isinstance(s, str):
        raise ValueError('created_at not a string')
    txt = s.strip()
    if txt.endswith('Z'):
        txt = txt[:-1] + '+00:00'
    dt = datetime.fromisoformat(txt)          # no offset means tz-naive
    if dt.tzinfo is None:
        raise ValueError('created_at must be timezone-aware')
    return dt.astimezone(timezone.utc)

class ValidationError(ValueError):
    pass

def validate_link_url(url):
    """Accept only absolute http/https URLs for link.url (a host is required). Reject every
    other form: javascript:, data:, file:, relative and protocol-relative. The frontend checks
    again immediately before clicking as defense in depth. Returns the accepted value unchanged."""
    if not isinstance(url, str) or not url.strip() or len(url) > MAX_URL:
        raise ValidationError('invalid link url')
    u = urlparse(url.strip())
    if u.scheme not in ('http', 'https') or not u.hostname:
        raise ValidationError('link url must be http(s) with host')  # hostname rather than netloc rejects ":443", etc.
    return url.strip()


def validate_run(run):
    """Validate and normalize the producer-owned execution declaration."""
    if not isinstance(run, dict) or not {'cwd', 'prompt'} <= set(run):
        raise ValidationError('run requires cwd and prompt')
    if set(run) - {'cwd', 'prompt', 'params'}:
        raise ValidationError('run has unknown fields')
    if any(not isinstance(run[key], str) or not run[key].strip() or '\0' in run[key]
           for key in ('cwd', 'prompt')):
        raise ValidationError('run cwd and prompt must be nonempty text')
    if 'params' not in run:
        return {'cwd': run['cwd'], 'prompt': run['prompt']}
    params = run['params']
    if not isinstance(params, list) or len(params) > MAX_RUN_PARAMS:
        raise ValidationError('run params must be an array of at most 8 entries')
    normalized = []
    seen = set()
    for item in params:
        if (not isinstance(item, dict) or not {'key', 'label'} <= set(item)
                or set(item) - {'key', 'label', 'choices', 'default'}):
            raise ValidationError('invalid run param declaration')
        key, label = item['key'], item['label']
        if not isinstance(key, str) or not ID_RE.fullmatch(key) or key in seen:
            raise ValidationError('invalid or duplicate run param key')
        if not isinstance(label, str) or not label.strip() or len(label) > MAX_PARAM_TEXT:
            raise ValidationError('invalid run param label')
        seen.add(key)
        entry = {'key': key, 'label': label}
        choices = item.get('choices')
        if 'choices' in item:
            if (not isinstance(choices, list) or not (1 <= len(choices) <= MAX_PARAM_CHOICES)
                    or any(not isinstance(value, str) or not value.strip()
                           or len(value) > MAX_PARAM_TEXT for value in choices)
                    or len(set(choices)) != len(choices)):
                raise ValidationError('invalid run param choices')
            entry['choices'] = list(choices)
        if 'default' in item:
            default = item['default']
            if not isinstance(default, str) or len(default) > MAX_PARAM_TEXT:
                raise ValidationError('invalid run param default')
            if choices is not None and default not in choices:
                raise ValidationError('run param default is not a choice')
            entry['default'] = default
        normalized.append(entry)
    return {'cwd': run['cwd'], 'prompt': run['prompt'], 'params': normalized}

def validate_payload(payload):
    """Normalize a message; legacy identity/time and urgency remain readable."""
    if not isinstance(payload, dict):
        raise ValidationError('payload not an object')
    out = dict(payload)
    for new, legacy in (('id', 'event_id'), ('group', 'group_key'), ('level', 'urgency')):
        if new in out and legacy in out and out[new] != out[legacy]:
            raise ValidationError('conflicting ' + new)
        out[new] = out.get(new, out.get(legacy))
    for key in ('id', 'group', 'source'):
        if not isinstance(out.get(key), str) or not ID_RE.fullmatch(out[key]):
            raise ValidationError('invalid ' + key)
    if out['id'].startswith(RESERVED_GROUP_PREFIX) or out['group'].startswith(RESERVED_GROUP_PREFIX):
        raise ValidationError('reserved identity')
    if out['level'] not in ('normal', 'urgent'):
        raise ValidationError('invalid level')
    if not isinstance(out.get('title'), str) or not out['title'].strip():
        raise ValidationError('missing title')
    if not isinstance(out.get('body', ''), str):
        raise ValidationError('invalid body')
    try:
        created = parse_rfc3339(out['created_at']) if 'created_at' in out else now_utc()
    except (ValueError, TypeError) as error:
        raise ValidationError('invalid created_at') from error
    if created > now_utc() + FUTURE_SKEW:
        raise ValidationError('created_at too far in future')
    # A heartbeat has one complete content shape, shared with its real producer.
    # Its reserved ID supplies the UTC day even when created_at is absent on wire.
    if out['source'] == 'heartbeat' or out['id'].startswith('heartbeat:'):
        try:
            day = datetime.strptime(out['id'].removeprefix('heartbeat:'), '%Y-%m-%d').replace(tzinfo=timezone.utc)
        except ValueError as error:
            raise ValidationError('invalid heartbeat date') from error
        if 'created_at' in out and created.date() != day.date():
            raise ValidationError('heartbeat date mismatch')
        candidate = dict(payload)
        for new, legacy in (('id', 'event_id'), ('group', 'group_key'), ('level', 'urgency')):
            if legacy in candidate:
                candidate[new] = candidate.pop(legacy)
        # Only the old wire wrapper is retired; title/body/urgent/day remain exact.
        for retired in ('schema_version', 'kind', 'outcome', 'why_it_matters', 'followup', 'created_at'):
            candidate.pop(retired, None)
        if candidate != heartbeat_payload(day):
            raise ValidationError('heartbeat requires the canonical daily payload')
    run = out.get('run')
    if run is not None:
        run = validate_run(run)
    link = out.get('link')
    if isinstance(link, dict):
        link = link.get('url')
    if link is not None:
        validate_link_url(link)
    return {'id': out['id'], 'group': out['group'], 'source': out['source'],
            'level': out['level'], 'title': out['title'], 'body': out.get('body', ''),
            'link': link, 'run': run, 'created_at': created}


def init_db(path):
    """Open only the final schema; legacy files require the offline migration first."""
    global _DB_PATH
    state_dir = os.path.dirname(path)
    if os.environ.get('AIRLOCK_DEV_MONITOR_MESSAGES') == 'true':
        if os.path.islink(state_dir) or not os.path.isdir(state_dir):
            raise RuntimeError('hardened dev-monitor state directory is missing')
        if (os.stat(state_dir).st_mode & 0o7777) != 0o710:
            raise RuntimeError('hardened dev-monitor state directory must be mode 0710')
    else:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        os.chmod(state_dir, 0o700)
    conn = sqlite3.connect(path)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables and tables != {'ledger', 'cards'}:
            raise RuntimeError('offline messages database conversion required')
        conn.executescript(_SCHEMA)
        columns = {row[1] for row in conn.execute('PRAGMA table_info(cards)')}
        for column in ('ran_input', 'ran_window'):
            if column not in columns:
                conn.execute('ALTER TABLE cards ADD COLUMN %s TEXT' % column)
        conn.execute('PRAGMA journal_mode=WAL')
        conn.commit()
    finally:
        conn.close()
    os.chmod(path, 0o600)
    _DB_PATH = path


def _conn():
    conn = getattr(_local, 'conn', None)
    if conn is None:
        if _DB_PATH is None:
            raise RuntimeError('init_db() not called')
        conn = sqlite3.connect(_DB_PATH, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute('PRAGMA busy_timeout=5000')
        _local.conn = conn
    return conn


_SCHEMA = """
CREATE TABLE IF NOT EXISTS ledger (
  id TEXT PRIMARY KEY, "group" TEXT NOT NULL, source TEXT NOT NULL,
  received_at TEXT NOT NULL, payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ledger_received ON ledger(received_at);
CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY, "group" TEXT NOT NULL, level TEXT NOT NULL,
  title TEXT NOT NULL, body TEXT, link TEXT, run TEXT,
  count INTEGER NOT NULL DEFAULT 1, first_at TEXT NOT NULL, last_at TEXT NOT NULL,
  read_at TEXT, archived_at TEXT, ran_at TEXT,
  sent_at TEXT, send_attempts INTEGER NOT NULL DEFAULT 0, send_next_at TEXT
);
CREATE INDEX IF NOT EXISTS cards_group ON cards("group", first_at);
CREATE INDEX IF NOT EXISTS cards_send ON cards(sent_at, send_next_at);
"""
MAX_DELIVERY_ATTEMPTS = 6  # Includes the first POST: one initial attempt plus five retries.


def has_receipt(event_id):
    return _conn().execute('SELECT 1 FROM ledger WHERE id=?', (event_id,)).fetchone() is not None


def ingest(payload):
    p = validate_payload(payload)
    now = iso(now_utc())
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        if has_receipt(p['id']):
            return 'duplicate'
        candidates = conn.execute(
            'SELECT * FROM cards WHERE "group"=? AND archived_at IS NULL '
            'ORDER BY last_at DESC,card_id ASC', (p['group'],)).fetchall()
        card = None
        for candidate in candidates:
            try:
                same = json.loads(candidate['run']) if candidate['run'] else None
            except (ValueError, TypeError):
                continue
            if (same == p['run'] and candidate['link'] == p['link']
                    and ((p['source'] != 'heartbeat' and not candidate['card_id'].startswith('heartbeat:')) or candidate['card_id'] == p['id'])):
                card = candidate
                break
        if card is None:
            conn.execute(
                'INSERT INTO cards(card_id,"group",level,title,body,link,run,first_at,last_at,send_next_at) '
                'VALUES(?,?,?,?,?,?,?,?,?,?)',
                (p['id'],p['group'],p['level'],p['title'],p['body'],p['link'],
                 json.dumps(p['run']) if p['run'] else None,now,now,now if p['level']=='urgent' else None))
            status = 'inserted'
        else:
            conn.execute(
                'UPDATE cards SET count=count+1,last_at=?,read_at=NULL,send_next_at=CASE '
                "WHEN level='normal' AND ?='urgent' AND sent_at IS NULL AND send_attempts=0 THEN ? ELSE send_next_at END,"
                'level=?,title=?,body=? '
                'WHERE card_id=?',
                (now,p['level'],now,'urgent' if p['level']=='urgent' or card['level']=='urgent' else 'normal',
                 p['title'],p['body'],card['card_id']))
            status = 'coalesced'
        conn.execute('INSERT INTO ledger(id,"group",source,received_at,payload) VALUES(?,?,?,?,?)',
                     (p['id'],p['group'],p['source'],now,json.dumps(payload,ensure_ascii=False)))
    return status


def _transition(card_id, column):
    with _conn():
        cur = _conn().execute('UPDATE cards SET '+column+'=? WHERE card_id=? AND '+column+' IS NULL',
                              (iso(now_utc()),card_id))
    return cur.rowcount == 1


def mark_read(card_id):
    return _transition(card_id, 'read_at')


def archive(card_id):
    return _transition(card_id, 'archived_at')


# History cards without an original receipt remain cards; no receipt is invented.
_CARD_SELECT = 'SELECT c.*,COALESCE(l.source, "") AS source FROM cards c LEFT JOIN ledger l ON l.id=c.card_id '


def _card_to_dict(row):
    card = dict(row)
    card['run'] = json.loads(card['run']) if card['run'] else None
    card['archived'] = card.pop('archived_at') is not None
    card['delivery'] = ('sent' if card['sent_at'] else
                        'failed' if card['send_attempts'] >= MAX_DELIVERY_ATTEMPTS else
                        'pending' if card['send_next_at'] else 'none')
    return card


def feed(scope='active'):
    where = '' if scope == 'all' else 'WHERE c.archived_at IS ' + ('NOT NULL ' if scope=='archived' else 'NULL ')
    rows = _conn().execute(
        _CARD_SELECT + where + 'ORDER BY c.last_at DESC,c.card_id ASC').fetchall()
    return {'messages':[_card_to_dict(row) for row in rows], 'counts':counts()}


def counts():
    def q(where):
        return _conn().execute('SELECT COUNT(*) FROM cards WHERE '+where).fetchone()[0]
    return {'active':q('archived_at IS NULL'), 'unread':unread_count(),
            'urgent':q("archived_at IS NULL AND level='urgent'"),'archived':q('archived_at IS NOT NULL')}


def unread_count():
    return _conn().execute('SELECT COUNT(*) FROM cards WHERE read_at IS NULL AND archived_at IS NULL').fetchone()[0]


def preview(limit=5):
    cards = feed()['messages'][:limit]
    return {'messages':cards,'top':[c for c in cards if not c['read_at']][:3],
            'unread_count':unread_count(),**collector_status()}


def collector_status(at=None):
    collected = _conn().execute('SELECT MAX(received_at) FROM ledger').fetchone()[0]
    age = max(0,int(((at or now_utc())-parse_rfc3339(collected)).total_seconds())) if collected else None
    return {'collected_at':collected,'collected_age_seconds':age}


def get_card(card_id):
    row = _conn().execute(_CARD_SELECT+'WHERE c.card_id=?', (card_id,)).fetchone()
    return _card_to_dict(row) if row else None


def mark_ran(card_id, ran_input, ran_window):
    at = iso(now_utc())
    with _conn():
        _conn().execute(
            'UPDATE cards SET ran_at=?,ran_input=?,ran_window=? WHERE card_id=?',
            (at, ran_input, ran_window, card_id))
    return at


def delivery_health():
    row = _conn().execute(
        "SELECT SUM(send_next_at IS NOT NULL AND sent_at IS NULL AND send_attempts<?),MAX(sent_at),"
        "SUM(archived_at IS NULL AND sent_at IS NULL AND send_attempts>=?) FROM cards",
        (MAX_DELIVERY_ATTEMPTS,MAX_DELIVERY_ATTEMPTS)).fetchone()
    return {'pending_count':row[0] or 0,'last_sent_at':row[1],'failed_count':row[2] or 0}


def next_delivery():
    row = _conn().execute(_CARD_SELECT+
        "WHERE c.send_next_at IS NOT NULL AND c.sent_at IS NULL AND c.send_attempts<? "
        'AND (c.send_next_at IS NULL OR c.send_next_at<=?) ORDER BY c.first_at LIMIT 1',
        (MAX_DELIVERY_ATTEMPTS,iso(now_utc()))).fetchone()
    return _card_to_dict(row) if row else None


def finish_delivery(card, ok, retry_after=None):
    # Only the single loop writes these columns. Commit after POST, including its attempt.
    # A crash after a successful response leaves the same attempt due on restart.
    attempt = card['send_attempts'] + 1
    at = now_utc()
    next_at = None
    if not ok and attempt < MAX_DELIVERY_ATTEMPTS:
        base = min(3600,30 * 2 ** (attempt-1))
        delay = base + random.uniform(0,base)
        if retry_after is not None:
            delay = max(delay,retry_after)
        next_at = iso(at + timedelta(seconds=delay))
    with _conn():
        _conn().execute('UPDATE cards SET sent_at=?,send_attempts=?,send_next_at=? WHERE card_id=?',
                        (iso(at) if ok else None,attempt,next_at,card['card_id']))


def sweep():
    """Archive idle read cards and delete receipts/cards older than 180 days."""
    now = now_utc()
    with _conn():
        conn = _conn()
        conn.execute('BEGIN IMMEDIATE')
        excess = counts()['active'] - ARCHIVE_ACTIVE_MIN
        if excess > 0:
            idle = iso(now - ARCHIVE_IDLE)
            conn.execute('UPDATE cards SET archived_at=? WHERE card_id IN ('
                         'SELECT card_id FROM cards WHERE archived_at IS NULL '
                         'AND read_at<=? AND last_at<=? ORDER BY first_at LIMIT ?)',
                         (iso(now),idle,idle,excess))
        cutoff = iso(now - RETENTION)
        conn.execute('DELETE FROM ledger WHERE received_at<=?', (cutoff,))
        conn.execute('DELETE FROM cards WHERE last_at<=?', (cutoff,))
