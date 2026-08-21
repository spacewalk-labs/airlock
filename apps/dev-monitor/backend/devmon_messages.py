#!/usr/bin/env python3
"""devmon_messages — persistent state for the Dev Monitor message axis (SQLite).

The key split is occurrence (an immutable receipt ledger) versus card (a mutable projection),
so deduplication, crash recovery, coalescing and flood accounting all happen in one atomic
transaction. apps/dev-monitor/README.md explains why that split exists.

This module uses stdlib sqlite3 only. airlock-dev-monitor.py imports it in one process with
multiple threads.
"""
import hashlib
import json
import os
import random
import re
import secrets
import sqlite3
import sys
import threading
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse

import devmon_roster as roster

# ---- constants / validation ----
ID_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}\Z')      # event_id/group_key/source
RESERVED_GROUP_PREFIX = 'dev-monitor:'                 # direct-inserted system cards
SKILL_RE = re.compile(r'^[a-z0-9][a-z0-9-]{0,63}\Z')  # skill name (installed-skill format)
# owner (P4): the roster.json key it must resolve against verbatim, so the validator accepts
# either spelling a producer might reach for and stores the one the roster actually keys on
# rather than asking `devmon_roster` to guess at lookup time.
OWNER_RE = re.compile(r'^@?[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z')
MAX_PAYLOAD = 16 * 1024                                # 16KB
MAX_URL = 2048                                         # upper bound for link.url
APPROVAL_TTL = timedelta(minutes=5)                   # approval nonce lifetime
COALESCE_WINDOW = timedelta(hours=24)                 # one card per group_key in 24h (per day)
FLOOD_WINDOW = timedelta(minutes=10)
FLOOD_THRESHOLD = 20
FLOOD_COOLDOWN = timedelta(minutes=30)
LANE_WATCHDOG_NOTICE_COOLDOWN = timedelta(minutes=30)
LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES = 24
LANE_PROBE_WINDOWS = {
    'slack-routine': timedelta(hours=24),
    'slack-urgent': timedelta(days=7),
}

# ---- severity (P3, owner decision D2_SEVERITY 2026-08-08) ----
# One axis, four values.  A producer says how much this matters and to whom; where it goes is
# the routing table's business alone (D1_ROUTING).  Ranked, because coalescing has to answer
# "this card, seen again, but worse" and the answer must not depend on arrival order.
SEVERITIES = ('page', 'attention', 'record', 'digest')
_SEVERITY_RANK = {'digest': 0, 'record': 1, 'attention': 2, 'page': 3}
# schema_version 1 keeps `urgency`, and this is how the two axes see each other.  It is one
# mapping used both ways rather than two tables that can disagree: a v1 card gets a severity,
# a v2 card gets the urgency the pin, the promotion and 229 older tests already read.
URGENCY_TO_SEVERITY = {'urgent': 'page', 'normal': 'record'}
# Channel names are rejected as severities with their own reason.  A producer that could say
# "email" would be routing, and on the day the table changes it would be wrong somewhere nobody
# thinks to look.  Naming them beats a generic "invalid severity" — the misspelling that
# actually happens is a person reaching for the channel they have in mind.
_CHANNEL_NAMES_AS_SEVERITY = frozenset(
    {'console', 'slack', 'email', 'slack-urgent', 'slack-routine', 'mail', 'webhook'})

# ---- routing (P3, owner decision D1_ROUTING 2026-08-08) ----
# The whole policy, as data.  A producer says severity and the box says where it goes, so this
# table is the only thing that knows about channels and the settings screen renders it rather
# than describing it.
#
# `console` is in every row and there is no argument that removes it: whatever goes out, the
# card stays.  Otherwise "I saw it in Slack and dealt with it" stops being a piece of work
# anyone can find, which is the hole this whole inbox was built to close.
ROUTING = {
    'page':      ('console', 'slack-urgent', 'email'),
    'attention': ('console', 'slack-routine'),
    'record':    ('console',),
    'digest':    ('console',),
}
CONSOLE = 'console'
# Which lanes this box can actually deliver to.  Set once at startup by the server, which is
# the only thing that knows what is configured; a lane with no worker must never receive rows,
# because rows in a lane nobody drains is exactly the 2026-07-30 silence — four urgent cards
# sat in the queue for nine days while the health endpoint reported the feature "on".
# Defaulting to the two Slack lanes keeps ingest's behaviour identical for any caller that
# never sets it, which includes every test that predates this.
_ENABLED_CHANNELS = {'slack-urgent', 'slack-routine'}
LANE_OLDEST_OPEN_LIMIT = timedelta(minutes=30)
SNOOZE_HOUR = 8                                       # "내일 다시" lands at 08:00, box-local
AGING = timedelta(days=3)                              # a task still in todo this long is "밀림"
ARCHIVE_IDLE = timedelta(hours=48)
ARCHIVE_ACTIVE_MIN = 20
RETENTION = timedelta(days=180)
FUTURE_SKEW = timedelta(minutes=5)

_local = threading.local()
_DB_PATH = None
# ---- roster (P4) ----
# Set once at startup, like `_ENABLED_CHANNELS`: the box's own identity does not change while
# it runs, and every caller that never sets these (every test that predates P4 included)
# gets an owner-less box, which resolves every declared owner straight through — no roster
# configured is a supported state, not a broken one.
_ROSTER_PATH = ''
_BOX_OWNER = None


def set_roster_path(path):
    global _ROSTER_PATH
    _ROSTER_PATH = (path or '').strip()


def roster_path():
    return _ROSTER_PATH


def set_box_owner(owner):
    global _BOX_OWNER
    _BOX_OWNER = owner


def box_owner():
    return _BOX_OWNER


def load_roster_snapshot(now=None):
    return roster.load_snapshot(_ROSTER_PATH, now=now)


def resolve_owner(raw_owner, snapshot=None, now=None):
    """Resolve one card's declared owner. Reads the roster file when no snapshot is passed
    in — callers projecting many cards at once (`feed`, `preview`) load one and reuse it."""
    if snapshot is None:
        snapshot = load_roster_snapshot(now=now)
    return roster.resolve(raw_owner, snapshot, _BOX_OWNER)


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


def _health_timestamp_valid_sql(column):
    """Portable SQLite predicate for the one persisted health-time format.

    Every repository writer persists ``iso()`` output: UTC, fixed width, and six
    fractional digits.  Health SQL accepts exactly that grammar and validates the
    calendar itself instead of delegating to SQLite's permissive date parser.
    Keeping the predicate in one generator makes indexes and reads textually
    identical, while avoiding a UDF dependency that would break an older writer.
    """
    year = 'CAST(substr(%s,1,4) AS INTEGER)' % column
    month = 'CAST(substr(%s,6,2) AS INTEGER)' % column
    day = 'CAST(substr(%s,9,2) AS INTEGER)' % column
    hour = 'CAST(substr(%s,12,2) AS INTEGER)' % column
    minute = 'CAST(substr(%s,15,2) AS INTEGER)' % column
    second = 'CAST(substr(%s,18,2) AS INTEGER)' % column
    shape = (
        "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T"
        "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]."
        "[0-9][0-9][0-9][0-9][0-9][0-9]Z'")
    max_day = (
        "CASE %s WHEN 2 THEN CASE WHEN (%s %% 4=0 AND "
        "(%s %% 100!=0 OR %s %% 400=0)) THEN 29 ELSE 28 END "
        "WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 "
        "ELSE 31 END" % (month, year, year, year))
    return (
        "(typeof(%s)='text' AND length(%s)=27 AND %s GLOB %s "
        "AND %s BETWEEN 1 AND 9999 AND %s BETWEEN 1 AND 12 "
        "AND %s BETWEEN 1 AND (%s) AND %s BETWEEN 0 AND 23 "
        "AND %s BETWEEN 0 AND 59 AND %s BETWEEN 0 AND 59)"
        % (column, column, column, shape, year, month, day, max_day,
           hour, minute, second))


def action_digest(payload):
    """Canonical hash of kind + recommended_action + link, used to decide card identity.

    Different link URLs have different digests, so they become different cards even when they
    have the same group_key (they coalesce per URL).
    """
    material = {
        'kind': payload.get('kind'),
        'action': payload.get('recommended_action'),
        'link': payload.get('link'),
    }
    blob = json.dumps(material, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode('utf-8')).hexdigest()


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


def route(severity):
    """The channels a severity delivers to, console first, always.

    A pure function of one enum and nothing else — not the card, not the config, not the
    clock. That is what makes the policy exhaustible by a table-driven test instead of
    merely described, and the empty cells are where a routing bug actually lives.
    """
    try:
        return ROUTING[severity]
    except KeyError:
        raise ValueError('no routing for severity %r' % (severity,))


def set_enabled_channels(channels):
    """Declare which outbox lanes this box can deliver to. Called once at startup."""
    global _ENABLED_CHANNELS
    _ENABLED_CHANNELS = set(channels)


def enabled_channels():
    return frozenset(_ENABLED_CHANNELS)


def enqueue_channels(severity):
    """The outbox rows a card of this severity should get: the policy, minus the console
    (which is the card itself), minus any lane this box cannot currently deliver to.

    The policy and the capability are kept apart on purpose. `route()` still says
    `page -> email` on a box with no mail transport — the settings screen shows the rule and
    the channel's own state separately, so an unconfigured lane reads as unconfigured rather
    than as absent from the policy.
    """
    return tuple(c for c in route(severity)
                 if c != CONSOLE and c in _ENABLED_CHANNELS)


def urgency_of_severity(severity):
    """The v1 axis a v2 card is stored on. `page` is the only severity that pins."""
    return 'urgent' if severity == 'page' else 'normal'


def stored_severity(severity, urgency):
    """A card's effective severity, for a card that may predate the column.

    One function because there were two readings of this and they disagreed: the projection
    fell back through the urgency mapping while the coalescing path did not, so a `urgent`
    card written before P3 was demoted to `record` by the next routine occurrence — losing
    the urgency, which is exactly the monotonicity this module is built to hold.
    """
    if severity in _SEVERITY_RANK:
        return severity
    return URGENCY_TO_SEVERITY.get(urgency)


def escalate_severity(current, incoming):
    """The severity of a card that has been seen again — the more severe of the two.

    Monotonic on purpose, and for the same reason `urgency` already is: a routine follow-up to
    a page must not quietly demote the card that woke somebody up. Pass `current` through
    `stored_severity` first; None here means a card whose severity cannot be resolved at all,
    which only the incoming value can answer.
    """
    if current not in _SEVERITY_RANK:
        return incoming
    return current if _SEVERITY_RANK[current] >= _SEVERITY_RANK[incoming] else incoming


def validate_payload(payload):
    """Validate producer JSON. Failure raises ValidationError with the reason; success returns
    a normalised dict."""
    if not isinstance(payload, dict):
        raise ValidationError('payload not an object')
    sv = payload.get('schema_version')
    if type(sv) is not int or sv not in (1, 2):   # reject bool True even though Python has True == 1
        raise ValidationError('unsupported schema_version')
    for f in ('event_id', 'group_key', 'source'):
        v = payload.get(f)
        if not isinstance(v, str) or not ID_RE.match(v):
            raise ValidationError(f'invalid {f}')
    if payload['event_id'].startswith(RESERVED_GROUP_PREFIX):
        raise ValidationError('reserved event_id')
    if payload['group_key'].startswith(RESERVED_GROUP_PREFIX):
        raise ValidationError('reserved group_key')
    kind = payload.get('kind')
    if kind not in ('action', 'info', 'link'):
        raise ValidationError('invalid kind')
    # P3: one axis per version, and never both at once.  A payload carrying `urgency` and
    # `severity` together is a producer telling this box two things that can disagree, and the
    # disagreement would only surface as a card routed somewhere nobody expected.
    if sv == 1:
        if 'severity' in payload:
            raise ValidationError('severity requires schema_version 2')
        urgency = payload.get('urgency')
        if urgency not in ('urgent', 'normal'):
            raise ValidationError('invalid urgency')
        severity = URGENCY_TO_SEVERITY[urgency]
    else:
        if 'urgency' in payload:
            raise ValidationError('urgency is schema_version 1; schema_version 2 uses severity')
        severity = payload.get('severity')
        if isinstance(severity, str) and severity.strip() in _CHANNEL_NAMES_AS_SEVERITY:
            raise ValidationError(
                'severity names a channel; a producer declares severity, not where it goes')
        if severity not in SEVERITIES:
            raise ValidationError('invalid severity')
        urgency = urgency_of_severity(severity)
    if not isinstance(payload.get('title'), str) or not payload['title'].strip():
        raise ValidationError('missing title')
    # P2: the producer declares whether a person still has to act. Optional on
    # schema_version 1 — v2 is P3's, and every producer that never sends it keeps working:
    # absent means "not declared", which reads as a record. `type is not bool` rather than
    # isinstance, because isinstance(1, bool) is False but isinstance(True, int) is True and
    # the mirror of that trap already cost this validator a line at schema_version.
    na = payload.get('needs_action')
    if na is not None and type(na) is not bool:
        raise ValidationError('needs_action must be a boolean')
    # P4: a producer states who this is, never a channel — resolving it into a Slack mention
    # or an email address is the roster's job, at delivery time, not the validator's here.
    # Neither schema version excludes it: unlike severity/urgency this is not a second
    # reading of the same fact, so there is nothing for the two versions to disagree about.
    owner = payload.get('owner')
    if owner is not None:
        if not isinstance(owner, str) or not OWNER_RE.match(owner.strip()):
            raise ValidationError('invalid owner')
        handle = owner.strip()
        owner = handle if handle.startswith('@') else '@' + handle
    try:
        created = parse_rfc3339(payload.get('created_at'))
    except ValueError as e:
        raise ValidationError('invalid created_at: %s' % e)
    if created > now_utc() + FUTURE_SKEW:
        raise ValidationError('created_at too far in future')
    if kind == 'action':
        ra = payload.get('recommended_action')
        if not isinstance(ra, dict):
            raise ValidationError('action requires recommended_action')
        has_skill = bool(isinstance(ra.get('skill'), str) and ra['skill'].strip())
        has_prompt = bool(isinstance(ra.get('prompt'), str) and ra['prompt'].strip())
        has_exec = bool(isinstance(ra.get('exec'), list) and ra['exec'])   # direct executable
        if (has_skill + has_prompt + has_exec) != 1:      # exactly one
            raise ValidationError('recommended_action needs exactly one of skill|prompt|exec')
        if has_skill and not SKILL_RE.match(ra['skill'].strip()):
            raise ValidationError('invalid skill name')
        if has_exec and not all(isinstance(x, str) and x for x in ra['exec']):
            raise ValidationError('exec must be a non-empty list of non-empty strings')
        if not isinstance(ra.get('cwd'), str) or not ra['cwd']:
            raise ValidationError('action requires cwd')
        if not isinstance(ra.get('explain'), str) or not ra['explain'].strip():
            raise ValidationError('action requires explain')
        if urgency == 'urgent' and not (has_skill or has_prompt or has_exec):
            raise ValidationError('urgent action without recommended_action')
    elif kind == 'link':
        ln = payload.get('link')
        if not isinstance(ln, dict):
            raise ValidationError('link requires link object')
        validate_link_url(ln.get('url'))          # http(s) host is required; every other form is rejected
        label = ln.get('label')
        if label is not None and (not isinstance(label, str) or len(label) > 200):
            raise ValidationError('link label must be a short string')
    else:  # info
        for f in ('outcome', 'why_it_matters', 'followup'):
            if not isinstance(payload.get(f), str) or not payload[f].strip():
                raise ValidationError(f'info requires {f}')
    # `severity` and `urgency` are both here so that ingest reads one authority instead of
    # re-deriving the mapping at every use.  Whichever the producer sent, the other is its
    # projection, and only this function decides which is which.
    return {'created_at': created, 'severity': severity, 'urgency': urgency, 'owner': owner}


# ---- connection ----
def init_db(path):
    """Call once before threads are created. Initialise the schema and WAL."""
    global _DB_PATH
    # The lane-aware claimant introduced with this schema uses UPDATE ... RETURNING.
    # Refuse the schema before creating even the state directory on an older runtime;
    # otherwise a later binary would find a half-initialised database.
    if sqlite3.sqlite_version_info < (3, 35, 0):
        raise RuntimeError(
            'dev-monitor messages require SQLite 3.35 or newer '
            '(UPDATE RETURNING support)')
    _DB_PATH = path
    state_dir = os.path.dirname(path)
    hardened = os.environ.get('AIRLOCK_DEV_MONITOR_MESSAGES') == 'true'
    if hardened:
        # The installer creates 0710 operator:writer before the service starts. Silently
        # recreating or chmodding it would either break the producer or widen an unverified
        # path, so hardening mode accepts exactly that pre-established boundary.
        if os.path.islink(state_dir) or not os.path.isdir(state_dir):
            raise RuntimeError('hardened dev-monitor state directory is missing')
        if (os.stat(state_dir).st_mode & 0o7777) != 0o710:
            raise RuntimeError('hardened dev-monitor state directory must be mode 0710')
    else:
        # The ordinary single-UID install remains private and self-creating.
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        try:
            os.chmod(state_dir, 0o700)
        except OSError:
            pass
    conn = sqlite3.connect(path)
    try:
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute('PRAGMA busy_timeout=5000')
        conn.executescript(_SCHEMA)
        conn.execute('BEGIN IMMEDIATE')
        try:
            _ensure_run_lifecycle_columns(conn)
            _ensure_lane_columns_and_indexes(conn)
            _recover_claimed_deliveries(conn)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    finally:
        conn.close()
    # DB file mode 0600 (collector only).
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _ensure_run_lifecycle_columns(conn):
    """Apply the run-lifecycle columns to databases created before retention existed."""
    columns = {row[1] for row in conn.execute('PRAGMA table_info(runs)').fetchall()}
    additions = (
        ('keep_requested', 'INTEGER NOT NULL DEFAULT 0'),
        ('kept_at', 'TEXT'),
        ('reclaimed_at', 'TEXT'),
    )
    for name, definition in additions:
        if name not in columns:
            conn.execute('ALTER TABLE runs ADD COLUMN %s %s' % (name, definition))


def _ensure_lane_columns_and_indexes(conn):
    """Add the two-lane schema to databases created by the original outbox."""
    card_columns = {row[1] for row in conn.execute('PRAGMA table_info(cards)').fetchall()}
    for name, definition in (
            ('severity', 'TEXT'),
            ('owner', 'TEXT'),
            ('needs_action', 'INTEGER'),
            ('task_state', 'TEXT'),
            ('snoozed_until', 'TEXT'),
            ('runbook', 'TEXT')):
        if name not in card_columns:
            conn.execute('ALTER TABLE cards ADD COLUMN %s %s' % (name, definition))

    delivery_columns = {
        row[1] for row in conn.execute('PRAGMA table_info(deliveries)').fetchall()
    }
    for name, definition in (
            ('claimed_by', 'TEXT'),
            ('lease_until', 'TEXT'),
            ('created_at', 'TEXT'),
            ('last_error_at', 'TEXT')):
        if name not in delivery_columns:
            conn.execute('ALTER TABLE deliveries ADD COLUMN %s %s' % (name, definition))

    # Every pre-lane Slack row represented today's urgent traffic. Do this before the
    # duplicate audit because a mixed slack/slack-urgent database can collide only after
    # the semantic values have converged.
    conn.execute("UPDATE deliveries SET channel='slack-urgent' WHERE channel='slack'")
    duplicate = conn.execute(
        "SELECT card_id, channel, COUNT(*) AS n FROM deliveries "
        "WHERE status IN ('pending','claimed') GROUP BY card_id, channel "
        "HAVING COUNT(*) > 1 LIMIT 1").fetchone()
    if duplicate is not None:
        raise RuntimeError(
            'delivery schema migration found duplicate open rows '
            'for card=%s channel=%s' % (duplicate[0], duplicate[1]))

    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_claim '
        'ON deliveries(channel, status, next_attempt_at)')
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS ux_deliveries_open "
        "ON deliveries(card_id, channel) WHERE status IN ('pending','claimed')")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_deliveries_sent "
        "ON deliveries(channel, sent_at) WHERE status='sent'")
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_watchdog_notice '
        'ON deliveries(card_id, channel, created_at)')
    # Valid health timestamps are canonical UTC strings, so lexical ordering is
    # chronological after the shared strict predicate has excluded malformed text.
    # Built-in SQL only: an old binary or sqlite tool can still maintain the indexes.
    sent_valid = _health_timestamp_valid_sql('sent_at')
    error_valid = _health_timestamp_valid_sql('last_error_at')
    created_valid = _health_timestamp_valid_sql('created_at')
    next_attempt_valid = _health_timestamp_valid_sql('next_attempt_at')
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_health_sent_v3 '
        'ON deliveries(channel, sent_at DESC, id DESC) '
        "WHERE status='sent' AND sent_at IS NOT NULL "
        'AND ' + sent_valid)
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_health_error_valid_v3 '
        'ON deliveries(channel, last_error_at DESC, id DESC, last_error) '
        "WHERE status!='superseded' AND last_error_at IS NOT NULL "
        'AND ' + error_valid)
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_health_failed_v3 '
        'ON deliveries(channel, last_error_at, id) '
        "WHERE status='failed'")
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_deliveries_health_bad_timestamp_v3 '
        'ON deliveries(channel, id) WHERE '
        "(status='sent' AND (sent_at IS NULL OR "
        'NOT ' + sent_valid + ')) OR '
        "(status!='superseded' AND last_error_at IS NOT NULL AND "
        'NOT ' + error_valid + ') OR '
        "(status IN ('pending','claimed') AND "
        'NOT ' + created_valid + ' AND NOT ' + next_attempt_valid + ')')
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_cards_probe ON cards(group_key, created_at)')
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_cards_watchdog_group_created '
        "ON cards(group_key, created_at, card_id) WHERE source='dev-monitor-watchdog'")
    conn.execute(
        'CREATE INDEX IF NOT EXISTS idx_events_card_kind ON events(card_id, kind)')


def _delivery_backoff_seconds(attempts):
    """Retry cap; attempts is the post-claim value."""
    return min(3600, 30 * (2 ** max(0, attempts - 1)))


def _delivery_jitter_seconds(attempts):
    return random.uniform(0, _delivery_backoff_seconds(attempts))


def _recover_claimed_deliveries(conn):
    """Return this process's interrupted batches to pending during single-process startup."""
    # This is safe only because init_db runs once before this process starts worker
    # threads. A second dev-monitor process would make a blanket claim sweep unsafe.
    now = now_utc()
    rows = conn.execute(
        "SELECT id, attempts FROM deliveries WHERE status='claimed'").fetchall()
    for row in rows:
        conn.execute(
            "UPDATE deliveries SET status='pending', claimed_by=NULL, lease_until=NULL, "
            "next_attempt_at=? WHERE id=? AND status='claimed'",
            (iso(now + timedelta(seconds=_delivery_backoff_seconds(row[1]))), row[0]))


def _conn():
    c = getattr(_local, 'conn', None)
    if c is None:
        if _DB_PATH is None:
            raise RuntimeError('init_db() not called')
        c = sqlite3.connect(_DB_PATH, timeout=5)
        c.row_factory = sqlite3.Row
        c.execute('PRAGMA busy_timeout=5000')
        c.execute('PRAGMA foreign_keys=ON')
        _local.conn = c
    return c


_SCHEMA = """
CREATE TABLE IF NOT EXISTS occurrences (
  event_id     TEXT PRIMARY KEY,
  card_id      TEXT NOT NULL,
  group_key    TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  received_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_occ_flood ON occurrences(group_key, received_at);
CREATE INDEX IF NOT EXISTS idx_occ_card  ON occurrences(card_id);

CREATE TABLE IF NOT EXISTS cards (
  card_id     TEXT PRIMARY KEY,
  group_key   TEXT NOT NULL,
  source      TEXT NOT NULL,
  kind        TEXT NOT NULL,
  urgency     TEXT NOT NULL,
  title       TEXT NOT NULL,
  body        TEXT,
  action_json TEXT,
  link_json   TEXT,
  action_digest TEXT,
  created_at  TEXT NOT NULL,
  received_at TEXT NOT NULL,
  read_at     TEXT,
  slack_sent_at TEXT,
  pinned      INTEGER NOT NULL DEFAULT 0,
  archived_at TEXT,
  dismissed_at TEXT,
  occurrence_count INTEGER NOT NULL DEFAULT 1,
  last_seen   TEXT NOT NULL,
  run_id      TEXT,
  severity    TEXT,
  owner       TEXT,
  needs_action INTEGER,
  task_state  TEXT,
  snoozed_until TEXT,
  runbook     TEXT
);
CREATE INDEX IF NOT EXISTS idx_card_group_open ON cards(group_key)
  WHERE dismissed_at IS NULL AND archived_at IS NULL;

CREATE TABLE IF NOT EXISTS runs (
  run_id      TEXT PRIMARY KEY,
  card_id     TEXT NOT NULL,
  plan_sha256 TEXT NOT NULL,
  plan_json   TEXT NOT NULL,
  status      TEXT NOT NULL,
  tmux_target TEXT,
  exit_code   INTEGER,
  error       TEXT,
  created_at  TEXT NOT NULL,
  started_at  TEXT,
  ended_at    TEXT,
  keep_requested INTEGER NOT NULL DEFAULT 0,
  kept_at     TEXT,
  reclaimed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_card ON runs(card_id, created_at);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);

CREATE TABLE IF NOT EXISTS approvals (
  nonce       TEXT PRIMARY KEY,
  card_id     TEXT NOT NULL,
  plan_sha256 TEXT NOT NULL,
  plan_json   TEXT NOT NULL,
  issued_at   TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  used_at     TEXT
);

CREATE TABLE IF NOT EXISTS deliveries (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id     TEXT NOT NULL,
  channel     TEXT NOT NULL,
  status      TEXT NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT,
  sent_at     TEXT,
  last_error  TEXT,
  claimed_by  TEXT,
  lease_until TEXT,
  created_at  TEXT,
  last_error_at TEXT
);

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  subject_event_id TEXT,
  card_id     TEXT,
  ts          TEXT NOT NULL,
  kind        TEXT NOT NULL,
  detail      TEXT
);

CREATE TABLE IF NOT EXISTS ingest_errors (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  file_name   TEXT NOT NULL,
  ts          TEXT NOT NULL,
  reason      TEXT NOT NULL,
  raw_head    TEXT
);
"""


def _audit(conn, kind, event_id=None, card_id=None, detail=None):
    conn.execute(
        'INSERT INTO events(subject_event_id, card_id, ts, kind, detail) VALUES(?,?,?,?,?)',
        (event_id, card_id, iso(now_utc()), kind, detail))


def record_ingest_error(file_name, reason, raw_head=''):
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute(
            'INSERT INTO ingest_errors(file_name, ts, reason, raw_head) VALUES(?,?,?,?)',
            (file_name, iso(now_utc()), reason, raw_head[:200]))


# ---- ingest (C2/M3 card/occurrence atomic transaction) ----
def ingest(payload):
    """Ingest a validated payload. -> 'inserted'|'coalesced'|'duplicate'.

    Once called only from the spool watcher thread. It no longer is — _emit_run_result
    ingests from the sentinel watcher, the reaper and the HTTP handler as well — so the
    coalesce race is prevented by BEGIN IMMEDIATE alone rather than by single-threading.
    """
    norm = validate_payload(payload)          # ValidationError means the caller moves it to bad/
    created = norm['created_at']
    # Read the axes from the validator, never from the raw payload: a v2 payload has no
    # `urgency` key at all, and a v1 payload has no `severity`.
    severity = norm['severity']
    urgency = norm['urgency']
    owner = norm['owner']
    event_id = payload['event_id']
    group_key = payload['group_key']
    digest = action_digest(payload)
    now = now_utc()
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        # 1) Idempotence: an occurrence already seen is a harmless finish (crash reprocessing guard, C2).
        seen = conn.execute('SELECT card_id FROM occurrences WHERE event_id=?',
                            (event_id,)).fetchone()
        if seen is not None:
            return 'duplicate'
        # 2) Coalesce target: an open card with the same group_key, action_digest and owner,
        #    created within 24h (the one-card-per-day rule). Owner is part of the identity
        #    (P4's invariant) — `owner IS ?` rather than `=` because SQLite's `=` never
        #    matches NULL against NULL, and two undeclared occurrences of the same group_key
        #    must still coalesce with each other.
        cutoff = iso(now - COALESCE_WINDOW)
        card = conn.execute(
            'SELECT * FROM cards WHERE group_key=? AND action_digest=? AND owner IS ? '
            'AND dismissed_at IS NULL AND archived_at IS NULL AND created_at>=? '
            'ORDER BY created_at DESC LIMIT 1',
            (group_key, digest, owner, cutoff)).fetchone()
        escalated = False
        new_severity = severity
        if card is None:
            # New card: this occurrence becomes its card_id.
            card_id = event_id
            pinned = 1 if urgency == 'urgent' else 0
            declared = payload.get('needs_action')
            conn.execute(
                'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, body, '
                'action_json, link_json, action_digest, created_at, received_at, pinned, '
                'occurrence_count, last_seen, needs_action, severity, owner) '
                'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                (card_id, group_key, payload['source'], payload['kind'], urgency,
                 payload['title'], payload.get('body'),
                 json.dumps(payload.get('recommended_action'), ensure_ascii=False)
                 if payload['kind'] == 'action' else None,
                 json.dumps(payload.get('link'), ensure_ascii=False)
                 if payload['kind'] == 'link' else None,
                 digest, iso(created), iso(now), pinned, 1, iso(now),
                 None if declared is None else int(declared), severity, owner))
            conn.execute(
                'INSERT INTO occurrences(event_id, card_id, group_key, payload_json, received_at) '
                'VALUES(?,?,?,?,?)',
                (event_id, card_id, group_key, json.dumps(payload, ensure_ascii=False), iso(now)))
            _audit(conn, 'ingested', event_id, card_id, severity)
            if pinned:
                _audit(conn, 'pin', event_id, card_id, 'urgent-auto')
            status = 'inserted'
        else:
            # Coalesce: add an occurrence and update the card projection (M3 monotonicity / read revival).
            card_id = card['card_id']
            conn.execute(
                'INSERT INTO occurrences(event_id, card_id, group_key, payload_json, received_at) '
                'VALUES(?,?,?,?,?)',
                (event_id, card_id, group_key, json.dumps(payload, ensure_ascii=False), iso(now)))
            # Severity escalates and never falls, and urgency is derived from the result rather
            # than computed beside it — two monotonic rules on two axes is two chances to
            # disagree about the same card.
            was = stored_severity(card['severity'], card['urgency'])
            new_severity = escalate_severity(was, severity)
            escalated = (new_severity != was)
            new_urgency = urgency_of_severity(new_severity)
            promote = (card['urgency'] != 'urgent' and new_urgency == 'urgent')
            # An occurrence may raise the card to "needs a person"; it may never lower it.
            # Otherwise one routine follow-up to a task silently empties the count this inbox
            # exists to keep honest.  NULL -> 0 is not a lowering: both read as a record, and
            # the 0 only records that a producer has now declared.
            declared = payload.get('needs_action')
            if declared is True:
                new_needs = 1
            elif declared is False and card['needs_action'] is None:
                new_needs = 0
            else:
                new_needs = card['needs_action']
            # Coalescing clears read_at so a repeat surfaces again.  A completed task is the one
            # card where that would be a lie: it reopens only for an occurrence that declares
            # action, and a record occurrence leaves it closed and read.
            reopen = (card['task_state'] == 'done' and declared is True)
            keep_closed = (card['task_state'] == 'done' and not reopen)
            new_state = 'todo' if reopen else card['task_state']
            conn.execute(
                'UPDATE cards SET occurrence_count=occurrence_count+1, last_seen=?, '
                'read_at=CASE WHEN ? THEN read_at ELSE NULL END, '
                'urgency=?, pinned=CASE WHEN ? THEN 1 ELSE pinned END, '
                'title=?, body=?, source=?, needs_action=?, task_state=?, severity=? '
                'WHERE card_id=?',
                (iso(now), 1 if keep_closed else 0, new_urgency, 1 if promote else 0,
                 payload['title'], payload.get('body'), payload['source'],
                 new_needs, new_state, new_severity, card_id))
            _audit(conn, 'coalesce', event_id, card_id, None)
            if promote:
                _audit(conn, 'pin', event_id, card_id, 'urgent-promote')
            if reopen:
                _audit(conn, 'reopen', event_id, card_id, 'coalesce-declares-action')
            status = 'coalesced'
        # 3) Enqueue the outbox from the routing table (the workers actually send).
        #    Until P3 this line read `urgency == 'urgent'`, which made the producer's urgency
        #    a routing decision in the one place nobody would look for one.
        #
        #    On a coalesce only an escalation enqueues, and it enqueues for the severity the
        #    card now has. Re-sending on every occurrence would turn one noisy producer into a
        #    pager storm, which is the behaviour the 24h coalescing window exists to prevent.
        if status == 'inserted':
            outbound = enqueue_channels(severity)
        elif escalated:
            outbound = enqueue_channels(new_severity)
        else:
            outbound = ()
        for channel in outbound:
            _enqueue_delivery(conn, card_id, channel)
    # Outside the transaction: flood detection uses a separate transaction.
    _maybe_flood(group_key)
    return status


def _enqueue_delivery(conn, card_id, channel='slack-urgent', at=None):
    # Enqueue one outbox row on one lane (the lane's worker retries and sends, at least once).
    # Named for Slack until P3, when `email` became a fourth value of the same column — a
    # channel-generic queue reached through a Slack-shaped name is how the next reader
    # concludes that email needs a second mechanism.
    # The group_key guard in _maybe_flood excludes recursive flood notifications.
    created_at = iso(at or now_utc())
    cur = conn.execute(
        'INSERT INTO deliveries(card_id, channel, status, next_attempt_at, created_at) '
        'VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING',
        (card_id, channel, 'pending', created_at, created_at))
    if cur.rowcount == 0:
        sys.stderr.write(
            '[devmon_messages] duplicate delivery suppressed '
            'card=%s channel=%s\n' % (card_id, channel))


# ---- flood detection (M8) ----
def _maybe_flood(group_key):
    if group_key.startswith('pipe:flood:'):
        return                                 # stop recursion
    now = now_utc()
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        window_start = iso(now - FLOOD_WINDOW)
        cnt = conn.execute(
            'SELECT COUNT(*) FROM occurrences WHERE group_key=? AND received_at>=?',
            (group_key, window_start)).fetchone()[0]
        if cnt < FLOOD_THRESHOLD:
            return
        flood_gk = 'pipe:flood:' + group_key
        # 30-minute cooldown: skip if a recent flood card already exists.
        cooldown_start = iso(now - FLOOD_COOLDOWN)
        recent = conn.execute(
            'SELECT card_id FROM cards WHERE group_key=? AND created_at>=? '
            'AND dismissed_at IS NULL ORDER BY created_at DESC LIMIT 1',
            (flood_gk, cooldown_start)).fetchone()
        if recent is not None:
            # During the cooldown, only update the existing flood card's count.
            conn.execute(
                'UPDATE cards SET occurrence_count=occurrence_count+1, last_seen=? WHERE card_id=?',
                (iso(now), recent['card_id']))
            return
        card_id = flood_gk + ':' + now.strftime('%Y%m%dT%H%M%SZ')
        conn.execute(
            'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, body, '
            'action_digest, created_at, received_at, pinned, occurrence_count, last_seen, '
            'needs_action, severity) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (card_id, flood_gk, 'monitor', 'info', 'urgent',
             'Message pipeline flood — ' + group_key,
             '%d or more events arrived within 10 minutes. Check the producer.' % cnt,
             'flood-' + group_key, iso(now), iso(now), 1, cnt, iso(now), 1, 'page'))
        _audit(conn, 'flood', None, card_id, 'count=%d gk=%s' % (cnt, group_key))
        _enqueue_delivery(conn, card_id, 'slack-urgent')


# ---- lane liveness (P1) ----
def maybe_enqueue_lane_probe(channel, at=None):
    """Create at most one direct probe card per lane window.

    A failed probe is suppressed by the probe card itself, not by a successful
    delivery.  That distinction keeps a dark lane to one probe per window.
    """
    window = LANE_PROBE_WINDOWS.get(channel)
    if window is None:
        raise ValueError('unknown delivery lane: %s' % channel)
    at = at or now_utc()
    at_text = iso(at)
    window_start = iso(at - window)
    sent_valid = _health_timestamp_valid_sql('sent_at')
    probe_key = 'dev-monitor:lane-probe:' + channel
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        last_success = conn.execute(
            'SELECT sent_at FROM deliveries INDEXED BY idx_deliveries_health_sent_v3 '
            "WHERE channel=? AND status='sent' AND sent_at IS NOT NULL "
            'AND ' + sent_valid + ' '
            'ORDER BY sent_at DESC, id DESC LIMIT 1',
            (channel,)).fetchone()
        last_success = last_success[0] if last_success is not None else None
        if last_success is not None and last_success >= window_start:
            return None
        recent_probe = conn.execute(
            'SELECT 1 FROM cards WHERE group_key=? AND created_at>=? LIMIT 1',
            (probe_key, window_start)).fetchone()
        if recent_probe is not None:
            return None

        card_id = probe_key + ':' + at.strftime('%Y%m%dT%H%M%SZ')
        lane_name = channel.removeprefix('slack-')
        conn.execute(
            'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, body, '
            'action_digest, created_at, received_at, read_at, pinned, occurrence_count, '
            'last_seen, needs_action, severity) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (card_id, probe_key, 'dev-monitor-probe', 'info', 'normal',
             'Slack %s lane liveness probe' % lane_name,
             'State: no delivery succeeded inside the %s probe window.\n'
             'What could be lost: messages assigned to the %s lane.\n'
             'What to do: receipt of this message proves the lane can deliver.'
             % ('24-hour' if window == timedelta(hours=24) else '7-day', lane_name),
             None, at_text, at_text, at_text, 0, 1, at_text, 0, 'record'))
        _audit(conn, 'lane_probe', None, card_id, 'lane=%s' % channel)
        _enqueue_delivery(conn, card_id, channel)
        return card_id


def lane_watchdog_reason(channel, worker_state='on', at=None):
    """Return a named unhealthy state for one lane, or ``None`` when healthy."""
    if channel not in LANE_PROBE_WINDOWS:
        raise ValueError('unknown delivery lane: %s' % channel)
    at = at or now_utc()
    # A lane without a webhook is supported configuration.  The startup banner and
    # /api/health name it, but there is no incident to page through the other lane.
    if worker_state == 'off: no webhook configured':
        return None
    if worker_state != 'on':
        return {
            'state': worker_state,
            'detail': 'the lane worker is not running',
        }

    health = delivery_lane_health(channel, at)
    if health['ledger_error_count']:
        return {
            'state': 'ledger-invalid',
            'detail': '%d retained delivery rows have invalid health timestamps'
                      % health['ledger_error_count'],
        }
    oldest = health['oldest_pending_age_seconds']
    if oldest is not None and oldest >= int(LANE_OLDEST_OPEN_LIMIT.total_seconds()):
        state = 'rate-limited' if health['delivery_state'] == 'rate-limited' else 'stalled'
        return {
            'state': state,
            'detail': 'oldest open delivery is %d seconds old' % oldest,
        }
    terminal_failures = health['terminal_failures_since_success']
    if health['last_success_at'] is not None:
        stale_after = LANE_PROBE_WINDOWS[channel] * 1.25
        success_age_seconds = health['last_success_age_seconds']
        if success_age_seconds >= int(stale_after.total_seconds()):
            return {
                'state': 'stale',
                'detail': 'last success is %d seconds old' % success_age_seconds,
            }
        if terminal_failures >= 2:
            return {
                'state': 'failed',
                'detail': '%d terminal deliveries failed after the last success'
                          % terminal_failures,
            }
    elif terminal_failures:
        return {
            'state': 'failed',
            'detail': '%d terminal deliveries failed before the lane ever succeeded'
                      % terminal_failures,
        }
    return None


def record_lane_watchdog(channel, reason, at=None):
    """Persist one active incident per lane; return ``(card_id, created)``."""
    if channel not in LANE_PROBE_WINDOWS:
        raise ValueError('unknown delivery lane: %s' % channel)
    at = at or now_utc()
    at_text = iso(at)
    group_key = 'dev-monitor:lane-watchdog:' + channel
    lane_name = channel.removeprefix('slack-')
    state = reason['state']
    detail = reason['detail']
    title = 'Slack %s lane is %s' % (lane_name, state)
    body = ('State: %s.\nWhat could be lost: messages assigned to the %s lane.\n'
            'What to do: run systemctl --user status airlock-dev-monitor.service and '
            'check the %s webhook.' % (detail, lane_name, lane_name))
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        unresolved = conn.execute(
            "SELECT card_id, archived_at, dismissed_at FROM cards "
            "WHERE group_key=? AND source='dev-monitor-watchdog' AND NOT EXISTS ("
            'SELECT 1 FROM events WHERE events.card_id=cards.card_id '
            "AND events.kind IN ('lane_watchdog_recovered','lane_watchdog_superseded')) "
            'ORDER BY created_at, card_id',
            (group_key,)).fetchall()
        if unresolved:
            # A continuing incident updates one card instead of minting 48 cards/day.
            # read/dismiss are owner UI state, not evidence of lane recovery.
            canonical = unresolved[0]
            duplicates = unresolved[1:]
            if duplicates:
                # Old cooldown cards may each own a notice.  Keep the strongest outcome
                # per channel on the canonical incident so enqueue idempotence survives
                # the fold; retire only redundant open work, never terminal history.
                incident_ids = [row['card_id'] for row in unresolved]
                placeholders = ','.join('?' for _ in incident_ids)
                deliveries = conn.execute(
                    'SELECT id, card_id, channel, status FROM deliveries WHERE card_id IN ('
                    + placeholders + ") AND status!='superseded'",
                    incident_ids).fetchall()
                status_order = {'sent': 0, 'claimed': 1, 'pending': 2, 'failed': 3}
                for notice_channel in {row['channel'] for row in deliveries}:
                    candidates = sorted(
                        (row for row in deliveries if row['channel'] == notice_channel),
                        key=lambda row: (
                            status_order.get(row['status'], 4),
                            row['card_id'] != canonical['card_id'], row['id']))
                    keeper = candidates[0]
                    for delivery in candidates[1:]:
                        if delivery['status'] in ('pending', 'claimed'):
                            conn.execute(
                                "UPDATE deliveries SET status='superseded', claimed_by=NULL, "
                                "lease_until=NULL, last_error='superseded watchdog notice', "
                                'last_error_at=? WHERE id=?',
                                (at_text, delivery['id']))
                    if keeper['card_id'] != canonical['card_id']:
                        conn.execute('UPDATE deliveries SET card_id=? WHERE id=?',
                                     (canonical['card_id'], keeper['id']))
                        _audit(conn, 'lane_watchdog_notice_adopted', None,
                               canonical['card_id'],
                               'from=%s lane=%s state=%s' % (
                                   keeper['card_id'], notice_channel, keeper['status']))
            conn.execute(
                'UPDATE cards SET occurrence_count=1, last_seen=?, '
                'title=?, body=?, pinned=0, archived_at=CASE WHEN dismissed_at IS NULL '
                'THEN NULL ELSE archived_at END WHERE card_id=?',
                (at_text, title, body, canonical['card_id']))
            if canonical['archived_at'] is not None and canonical['dismissed_at'] is None:
                _audit(conn, 'lane_watchdog_reopened', None, canonical['card_id'],
                       'lane=%s' % channel)
            for duplicate in duplicates:
                conn.execute(
                    'UPDATE cards SET pinned=0, archived_at=? WHERE card_id=?',
                    (at_text, duplicate['card_id']))
                conn.execute(
                    "UPDATE deliveries SET status='superseded', claimed_by=NULL, lease_until=NULL, "
                    "last_error='superseded watchdog incident', last_error_at=? "
                    "WHERE card_id=? AND status IN ('pending','claimed')",
                    (at_text, duplicate['card_id']))
                _audit(conn, 'lane_watchdog_superseded', None, duplicate['card_id'],
                       'canonical=%s' % canonical['card_id'])
            return canonical['card_id'], False
        card_id_base = group_key + ':' + at.strftime('%Y%m%dT%H%M%SZ')
        card_id = card_id_base
        suffix = 0
        while conn.execute('SELECT 1 FROM cards WHERE card_id=?', (card_id,)).fetchone():
            suffix += 1
            card_id = '%s:%d' % (card_id_base, suffix)
        conn.execute(
            # P1's lane incident card deliberately stays undeclared for now. Declaring it a
            # task is right — a dark lane is the campaign's own flagship "someone must act" —
            # but it also stops the sweep from archiving it, and P1 asserts that archive in two
            # tests. Measured: nothing else depends on it, because
            # active_lane_watchdog_channels() and the reopen-across-a-gap path both ignore
            # archived_at. Ruling asked for on the board rather than taken here.
            'INSERT INTO cards(card_id, group_key, source, kind, urgency, title, body, '
            'action_digest, created_at, received_at, pinned, occurrence_count, last_seen, '
            'severity) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (card_id, group_key, 'dev-monitor-watchdog', 'info', 'urgent',
             title, body, None, at_text, at_text, 0, 1, at_text, 'page'))
        _audit(conn, 'lane_watchdog', None, card_id,
               'lane=%s state=%s detail=%s' % (channel, state, detail))
        return card_id, True


def active_lane_watchdog_channels():
    """Return lanes with unresolved visible, dismissed, or idle-swept incidents."""
    prefix = 'dev-monitor:lane-watchdog:'
    rows = _conn().execute(
        "SELECT group_key FROM cards WHERE source='dev-monitor-watchdog' AND NOT EXISTS ("
        'SELECT 1 FROM events WHERE events.card_id=cards.card_id '
        "AND events.kind IN ('lane_watchdog_recovered','lane_watchdog_superseded'))").fetchall()
    return {
        row['group_key'][len(prefix):] for row in rows
        if row['group_key'].startswith(prefix)
        and row['group_key'][len(prefix):] in LANE_PROBE_WINDOWS
    }


def resolve_lane_watchdog(channel, at=None):
    """Archive an incident after an observed non-incident lane state."""
    if channel not in LANE_PROBE_WINDOWS:
        raise ValueError('unknown delivery lane: %s' % channel)
    at = at or now_utc()
    group_key = 'dev-monitor:lane-watchdog:' + channel
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        rows = conn.execute(
            "SELECT card_id FROM cards WHERE group_key=? AND source='dev-monitor-watchdog' "
            'AND NOT EXISTS ('
            'SELECT 1 FROM events WHERE events.card_id=cards.card_id '
            "AND events.kind IN ('lane_watchdog_recovered','lane_watchdog_superseded'))",
            (group_key,)).fetchall()
        for row in rows:
            # archived_at may already hold an idle-sweep time. Recovery is the cooldown
            # boundary, so always replace it with the observed recovery timestamp.
            conn.execute(
                'UPDATE cards SET pinned=0, archived_at=? WHERE card_id=?',
                (iso(at), row['card_id']))
            conn.execute(
                "UPDATE deliveries SET status='superseded', claimed_by=NULL, lease_until=NULL, "
                "last_error='watchdog incident recovered before delivery', last_error_at=? "
                "WHERE card_id=? AND status IN ('pending','claimed')",
                (iso(at), row['card_id']))
            _audit(conn, 'lane_watchdog_recovered', None, row['card_id'],
                   'lane=%s' % channel)
        return len(rows)


def enqueue_lane_watchdog_notice(card_id, channel, at=None):
    """Queue a crossover notice, retrying terminal failure at most once per 30 minutes."""
    if channel not in LANE_PROBE_WINDOWS:
        raise ValueError('unknown delivery lane: %s' % channel)
    at = at or now_utc()
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            'SELECT group_key FROM cards WHERE card_id=? AND source=?',
            (card_id, 'dev-monitor-watchdog')).fetchone()
        if row is None:
            raise ValueError('unknown watchdog card: %s' % card_id)
        sent_or_open = conn.execute(
            "SELECT 1 FROM deliveries WHERE card_id=? AND channel=? "
            "AND status IN ('pending','claimed','sent') LIMIT 1",
            (card_id, channel)).fetchone()
        if sent_or_open is not None:
            return False
        cooldown_start = iso(at - LANE_WATCHDOG_NOTICE_COOLDOWN)
        recent_attempt = conn.execute(
            'SELECT 1 FROM deliveries d JOIN cards c ON c.card_id=d.card_id '
            "WHERE c.source='dev-monitor-watchdog' AND c.group_key=? "
            'AND d.channel=? AND d.created_at>? LIMIT 1',
            (row['group_key'], channel, cooldown_start)).fetchone()
        if recent_attempt is not None:
            return False
        retrying = conn.execute(
            "SELECT 1 FROM deliveries WHERE card_id=? AND channel=? AND status='failed' LIMIT 1",
            (card_id, channel)).fetchone() is not None
        _enqueue_delivery(conn, card_id, channel, at)
        _audit(conn, 'lane_watchdog_notice_retry' if retrying else 'lane_watchdog_notice',
               None, card_id, 'lane=%s' % channel)
        return True


# ---- state transitions (conditional UPDATE + audit, one transaction) ----
def _transition(card_id, set_sql, params, audit_kind, cond_sql=''):
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        cur = conn.execute(
            'UPDATE cards SET ' + set_sql + ' WHERE card_id=?' + cond_sql,
            params + (card_id,))
        if cur.rowcount != 1:
            return False
        _audit(conn, audit_kind, None, card_id, None)
        return True


def mark_read(card_id):
    return _transition(card_id, 'read_at=?', (iso(now_utc()),), 'read',
                       ' AND read_at IS NULL')


def set_pin(card_id, pinned):
    return _transition(card_id, 'pinned=?', (1 if pinned else 0,),
                       'pin' if pinned else 'unpin')


def archive(card_id):
    return _transition(card_id, 'archived_at=?', (iso(now_utc()),), 'archive',
                       ' AND archived_at IS NULL')


def dismiss(card_id):
    return _transition(card_id, 'dismissed_at=?', (iso(now_utc()),), 'dismiss',
                       ' AND dismissed_at IS NULL')


def undismiss(card_id):
    return _transition(card_id, 'dismissed_at=NULL', (), 'undismiss',
                       ' AND dismissed_at IS NOT NULL')


# ---- task state (P2): todo -> doing -> done, with snoozed as a detour ----
# Every one of these is refused on a card that does not declare action, and the refusal is
# the same conditional UPDATE matching no row that read/pin/archive already use.  That is the
# server half of the screen's rule: a record card is offered no completion, so a person
# cannot be the reason a "still to do" number stops meaning that.
_IS_TASK = ' AND needs_action=1'
_OPEN = " AND (task_state IS NULL OR task_state IN ('todo','snoozed'))"


def next_snooze_deadline(at=None):
    """The next 08:00 in this box's local timezone, returned as UTC.

    A per-card snooze needs no timezone machinery beyond this: there is no send-once marker
    and no catch-up after a restart, which is why the morning digest is a separate task and
    this is not.
    """
    local = (at or now_utc()).astimezone()
    target = local.replace(hour=SNOOZE_HOUR, minute=0, second=0, microsecond=0)
    if target <= local:
        target += timedelta(days=1)
    return target.astimezone(timezone.utc)


def start_task(card_id):
    return _transition(card_id, "task_state='doing', snoozed_until=NULL", (), 'task_start',
                       _IS_TASK + _OPEN)


def complete_task(card_id):
    return _transition(card_id, "task_state='done', snoozed_until=NULL", (), 'task_done',
                       _IS_TASK + " AND (task_state IS NULL OR task_state<>'done')")


def reopen_task(card_id):
    return _transition(card_id, "task_state='todo', snoozed_until=NULL", (), 'task_reopen',
                       _IS_TASK + " AND task_state='done'")


def snooze_task(card_id, until=None):
    until = until or next_snooze_deadline()
    return _transition(card_id, "task_state='snoozed', snoozed_until=?", (iso(until),),
                       'task_snooze', _IS_TASK + " AND (task_state IS NULL OR task_state='todo')")


def unsnooze_task(card_id):
    return _transition(card_id, "task_state='todo', snoozed_until=NULL", (), 'task_unsnooze',
                       _IS_TASK + " AND task_state='snoozed'")


def not_task(card_id):
    """"Not a task" — clears needs_action and leaves the card where it is.

    Without it a person completes something they never had to do, and the count fills with
    false completions instead of false tasks.  Refused on a card that is already a record,
    so the button cannot be pressed twice into a different meaning.
    """
    return _transition(card_id, 'needs_action=0, task_state=NULL, snoozed_until=NULL', (),
                       'not_task', ' AND COALESCE(needs_action,0)=1')


# ---- queries ----
def _card_to_dict(row, roster_snapshot=None):
    result_prefix = 'devmon:run-result:'
    group_key = row['group_key']
    result_run_id = group_key[len(result_prefix):] if group_key.startswith(result_prefix) else None
    # P4: resolved fresh from the roster on every projection rather than cached at ingest —
    # `owner` is the fact a card carries, but who that resolves to (and whether the box had to
    # fall back) can change from one read to the next as the daily snapshot ages or refreshes.
    owner_info = resolve_owner(row['owner'], snapshot=roster_snapshot)
    return {
        'card_id': row['card_id'], 'group_key': group_key, 'source': row['source'],
        'kind': row['kind'], 'urgency': row['urgency'],
        # NULL on a card written before this column meant anything; the screen reads it
        # through the same mapping the validator uses rather than inventing a default.
        'severity': stored_severity(row['severity'], row['urgency']),
        'title': row['title'],
        'body': row['body'],
        'action': json.loads(row['action_json']) if row['action_json'] else None,
        'link': json.loads(row['link_json']) if row['link_json'] else None,
        'created_at': row['created_at'], 'received_at': row['received_at'],
        'read_at': row['read_at'], 'slack_sent_at': row['slack_sent_at'],
        'pinned': bool(row['pinned']), 'archived': row['archived_at'] is not None,
        'occurrence_count': row['occurrence_count'], 'last_seen': row['last_seen'],
        'run_id': row['run_id'], 'result_run_id': result_run_id,
        'needs_action': None if row['needs_action'] is None else bool(row['needs_action']),
        'task_state': row['task_state'], 'snoozed_until': row['snoozed_until'],
        # owner: the raw string this card carries, or None if none was declared.
        # owner_resolved: who to attribute/notify — the roster's answer, or the box owner and
        # why, never silent. roster_*: the snapshot's own age, so staleness is on screen and
        # not only in the fallback reason.
        'owner': row['owner'],
        'owner_resolved': {
            'owner': owner_info['owner'], 'name': owner_info['name'],
            'email': owner_info['email'], 'slack_member_id': owner_info['slack_member_id'],
            'fallback': owner_info['fallback'], 'fallback_reason': owner_info['fallback_reason'],
        },
        'roster_generated_at': owner_info['roster_generated_at'],
        'roster_age_seconds': owner_info['roster_age_seconds'],
    }


# The one definition of "a person still has to act on this".  counts(), the preview, the
# badge, the ordering and the auto-archive all read this string; a second spelling would be
# a second answer, and the number on the phone is the whole point of this phase.
#
# Three things are deliberate.  `doing` is not needs-me — it has its own count, because the
# badge is what is untouched, not what is in flight.  A snooze returns by this query rather
# than by a background job, so a dead sweep thread cannot swallow a task.  And COALESCE, not
# `needs_action = 1`, because an undeclared card must make this predicate FALSE rather than
# NULL: `NOT (NULL)` is NULL, which would quietly exclude every undeclared card from the
# auto-archive that negates it.
#
# Takes one parameter: the current time, as an iso() string.
NEEDS_ME_SQL = (
    "COALESCE(needs_action, 0) = 1 AND dismissed_at IS NULL AND archived_at IS NULL "
    "AND (task_state IS NULL OR task_state = 'todo' "
    "OR (task_state = 'snoozed' AND (snoozed_until IS NULL OR snoozed_until <= ?)))"
)

ORDER = ('ORDER BY pinned DESC, (' + NEEDS_ME_SQL + ') DESC, (read_at IS NULL) DESC, '
         'created_at DESC, received_at DESC')


def feed(scope='active'):
    conn = _conn()
    if scope == 'archived':
        where = 'dismissed_at IS NULL AND archived_at IS NOT NULL'
    elif scope == 'all':
        where = 'dismissed_at IS NULL'
    else:  # active
        where = 'dismissed_at IS NULL AND archived_at IS NULL'
    rows = conn.execute('SELECT * FROM cards WHERE ' + where + ' ' + ORDER,
                        (iso(now_utc()),)).fetchall()
    snapshot = load_roster_snapshot()          # one read for the whole batch, not one per row
    return {'messages': [_card_to_dict(r, snapshot) for r in rows], 'counts': counts()}


def preview(limit=5):
    conn = _conn()
    now = now_utc()
    at = iso(now)
    rows = conn.execute(
        'SELECT * FROM cards WHERE dismissed_at IS NULL AND archived_at IS NULL '
        + ORDER + ' LIMIT ?', (at, limit)).fetchall()
    # The hub strip's top three, server-filtered by the one needs-me predicate rather than
    # handed the general `messages` list to re-filter — a second, client-side re-derivation
    # of "is this needs-me right now" (task_state, snoozed_until) is exactly the drift P2's
    # single SQL fragment exists to prevent.
    top_rows = conn.execute(
        'SELECT * FROM cards WHERE ' + NEEDS_ME_SQL + ' ' + ORDER + ' LIMIT 3',
        (at, at)).fetchall()
    snapshot = load_roster_snapshot(now=now)   # one read for the whole batch, not one per row
    # unread_count stays in this response even though the badge no longer means unread: a
    # widget that has not been changed yet reads it, and it must not go blank on deploy day.
    return {'messages': [_card_to_dict(r, snapshot) for r in rows],
            'top': [_card_to_dict(r, snapshot) for r in top_rows],
            'unread_count': unread_count(),
            'needs_action_count': needs_action_count(),
            **collector_status(now)}


def collector_status(at=None):
    """When the pipeline last received anything at all, and how long it has been silent
    since. A number, not a flag — P5's hub strip must be able to tell a box where messages
    were only just enabled (quiet, nothing to compare against yet) from one where a
    producer stopped calling in (an age that keeps growing), the same discipline P3 uses
    for lane health: unconfigured reads as quiet, stalled accumulates.

    ``collected_at`` counts every card ever inserted, including archived/dismissed ones —
    the ingest pipeline being alive is what this answers, not what is still on screen.
    """
    conn = _conn()
    at = at or now_utc()
    collected_at = conn.execute('SELECT MAX(received_at) FROM cards').fetchone()[0]
    if collected_at is None:
        return {'collected_at': None, 'collected_age_seconds': None}
    age = conn.execute(
        'SELECT MAX(0, CAST((julianday(?) - julianday(?)) * 86400 AS INTEGER))',
        (iso(at), collected_at)).fetchone()[0]
    return {'collected_at': collected_at, 'collected_age_seconds': age}


def unread_count():
    conn = _conn()
    return conn.execute(
        'SELECT COUNT(*) FROM cards WHERE read_at IS NULL AND dismissed_at IS NULL '
        'AND archived_at IS NULL').fetchone()[0]


def needs_action_count(at=None):
    """How many cards still need a person. The number on the phone."""
    conn = _conn()
    return conn.execute('SELECT COUNT(*) FROM cards WHERE ' + NEEDS_ME_SQL,
                        (iso(at or now_utc()),)).fetchone()[0]


def counts():
    conn = _conn()
    now = now_utc()
    at = iso(now)
    def q(where, params=()):
        return conn.execute('SELECT COUNT(*) FROM cards WHERE ' + where, params).fetchone()[0]
    active = 'dismissed_at IS NULL AND archived_at IS NULL'
    task = active + ' AND needs_action=1'
    return {
        'active': q(active),
        'unread': q(active + ' AND read_at IS NULL'),
        'action': q(active + " AND kind='action'"),
        'link': q(active + " AND kind='link'"),
        'urgent': q(active + " AND urgency='urgent'"),
        'archived': q('dismissed_at IS NULL AND archived_at IS NOT NULL'),
        # The needs-me axis. `closed` is the mock-up's "완료·기록" chip: everything that is
        # not asking for anything, whether because it never was a task or because it is done.
        'needs_me': q(NEEDS_ME_SQL, (at,)),
        'doing': q(task + " AND task_state='doing'"),
        'snoozed': q(task + " AND task_state='snoozed' AND snoozed_until>?", (at,)),
        'closed': q(active + " AND (COALESCE(needs_action,0)<>1 OR task_state='done')"),
        'aging': q(NEEDS_ME_SQL + ' AND created_at<=?', (at, iso(now - AGING))),
    }


# ---- sweep (M9 / retention) ----
def sweep():
    """Runs every 15 minutes: archive excess cards and hard-purge after 180d. One sweep thread."""
    now = now_utc()
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        # 1) Archive: if active > 20, archive only the oldest eligible cards, leaving 20 active.
        active = conn.execute(
            'SELECT COUNT(*) FROM cards WHERE dismissed_at IS NULL AND archived_at IS NULL'
        ).fetchone()[0]
        excess = active - ARCHIVE_ACTIVE_MIN
        if excess > 0:
            idle = iso(now - ARCHIVE_IDLE)
            # Archiving excludes a card from the needs-me count, so a card that still needs a
            # person is never swept: read-and-idle is exactly what an unfinished task looks
            # like, and this is the count's silent leak if it is not stated here.
            rows = conn.execute(
                'SELECT card_id FROM cards WHERE dismissed_at IS NULL AND archived_at IS NULL '
                'AND pinned=0 AND read_at IS NOT NULL AND read_at<=? AND last_seen<=? '
                'AND NOT (' + NEEDS_ME_SQL + ') '
                'ORDER BY created_at ASC LIMIT ?', (idle, idle, iso(now), excess)).fetchall()
            for r in rows:
                conn.execute('UPDATE cards SET archived_at=? WHERE card_id=? '
                             'AND archived_at IS NULL AND pinned=0',
                             (iso(now), r['card_id']))
                _audit(conn, 'archive', None, r['card_id'], 'sweep')
        # 2) 180d hard purge, including the card's execution/approval/delivery ledgers so the
        #    original plan does not persist forever (#7). Exclude cards with an active run_id,
        #    a kept run, or any terminal run that still has a tmux target: deleting the DB record
        #    while the pane lives would make later generation-aware reclamation impossible.
        old = iso(now - RETENTION)
        purged = conn.execute(
            'SELECT card_id FROM cards WHERE received_at<=? AND run_id IS NULL '
            'AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.card_id=cards.card_id '
            'AND r.reclaimed_at IS NULL AND (r.keep_requested=1 OR r.tmux_target IS NOT NULL))',
            (old,)).fetchall()
        for r in purged:
            cid = r['card_id']
            conn.execute('DELETE FROM occurrences WHERE card_id=?', (cid,))
            conn.execute('DELETE FROM events WHERE card_id=?', (cid,))
            conn.execute('DELETE FROM approvals WHERE card_id=?', (cid,))
            conn.execute('DELETE FROM runs WHERE card_id=?', (cid,))
            conn.execute('DELETE FROM deliveries WHERE card_id=?', (cid,))
            conn.execute('DELETE FROM cards WHERE card_id=?', (cid,))
        # Expired approval nonces have a short TTL, so delete any over a day old at once to
        # avoid retaining the original plan.
        conn.execute('DELETE FROM approvals WHERE issued_at<=?', (iso(now - timedelta(days=1)),))
        if purged:
            _audit(conn, 'purge', None, None, 'count=%d' % len(purged))


# ============================================================
# Action axis (P3): plan (canonical + nonce) -> execute (CAS + drift) -> run FSM.
# Security invariant: preview == execution. Prompts and skills live only in plan_json; the tmux
# command line receives only a server-controlled path.
# ============================================================
RUN_ACTIVE = ('starting', 'running')
RUN_TERMINAL = ('done', 'failed', 'stopped', 'interrupted')
RUN_KEEPABLE = RUN_ACTIVE + RUN_TERMINAL


def canonical_plan(card_row, exec_cfg):
    """Derive the canonical execution plan plus sha256 from a card's current recommended_action.
    Invalid cases (not action, dismissed, cwd missing/outside, bad skill syntax) return None and
    are treated as drift/rejection. plan = {cwd(realpath), skill|prompt, explain}."""
    if card_row is None or card_row['kind'] != 'action' or card_row['dismissed_at'] is not None:
        return None
    raw = card_row['action_json']
    if not raw:
        return None
    action = json.loads(raw)
    cwd = action.get('cwd')
    if not isinstance(cwd, str) or not cwd:
        return None
    real = os.path.realpath(os.path.expanduser(cwd))
    root = exec_cfg.get('cwd_root')
    if root:
        rroot = os.path.realpath(os.path.expanduser(root))
        # Only strictly below root is allowed: root itself is refused. With root=$HOME, this allows
        #   projects below the home directory regardless of their folder convention, but never the
        #   home directory itself. The os.sep suffix prevents a prefix attack that mistakes
        #   '/srv/project-two' for a child of '/srv/project'.
        if not real.startswith(rroot + os.sep):
            return None                                   # outside the allowed root, or the root itself
    if not os.path.isdir(real):
        return None                                       # refuse a directory that does not exist
    # The plan is cwd(realpath) + skill|prompt + reason. If any of these changes after approval,
    # the newly derived sha disagrees and becomes plan_stale, preventing execution of something
    # different from what was approved.
    plan = {'cwd': real, 'explain': action.get('explain', '')}
    exec_argv = action.get('exec')
    skill = action.get('skill')
    if isinstance(exec_argv, list) and exec_argv:
        # Direct executable: argv list (no Claude and no shell parsing). exec[0] must be an existing
        #   executable absolute path. The owner previews the exact argv before approving, so it has the
        #   same trust model as a prompt: their own machine and their own script.
        if not all(isinstance(x, str) and x for x in exec_argv):
            return None
        prog = os.path.realpath(os.path.expanduser(exec_argv[0]))
        if not os.path.isabs(exec_argv[0]) or not os.path.isfile(prog) or not os.access(prog, os.X_OK):
            return None                                   # absolute path, existence and execute permission required
        plan['exec'] = [prog] + [str(x) for x in exec_argv[1:]]  # normalise prog realpath for a stable drift sha
    elif skill:
        skill = skill.strip()
        if not SKILL_RE.match(skill):
            return None
        plan['skill'] = skill
    else:
        prompt = action.get('prompt')
        if not isinstance(prompt, str) or not prompt.strip():
            return None
        plan['prompt'] = prompt
    blob = json.dumps(plan, sort_keys=True, ensure_ascii=False)
    return plan, hashlib.sha256(blob.encode('utf-8')).hexdigest()


def issue_approval(card_id, exec_cfg):
    """Derive a plan from the current card and issue a one-time nonce (5 minutes). ->
    dict(ok/nonce/plan|error)."""
    conn = _conn()
    now = now_utc()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        card = conn.execute('SELECT * FROM cards WHERE card_id=?', (card_id,)).fetchone()
        if card is None:
            return {'ok': False, 'error': 'card_not_found'}
        if card['run_id'] is not None:
            return {'ok': False, 'error': 'run_active'}
        cp = canonical_plan(card, exec_cfg)
        if cp is None:
            return {'ok': False, 'error': 'not_executable'}
        plan, sha = cp
        nonce = secrets.token_urlsafe(24)
        conn.execute(
            'INSERT INTO approvals(nonce, card_id, plan_sha256, plan_json, issued_at, expires_at) '
            'VALUES(?,?,?,?,?,?)',
            (nonce, card_id, sha, json.dumps(plan, ensure_ascii=False),
             iso(now), iso(now + APPROVAL_TTL)))
        _audit(conn, 'plan', None, card_id, sha[:12])
    return {'ok': True, 'nonce': nonce, 'plan': plan, 'sha256': sha}


def redeem_approval(card_id, nonce, exec_cfg):
    """CAS the nonce (once), rederive and compare the current plan sha (mismatch means
    plan_stale = C5), then create a starting run. dev-monitor launches tmux next. ->
    dict(ok/plan/run_id|error)."""
    if not isinstance(nonce, str) or not nonce:
        return {'ok': False, 'error': 'no_nonce'}
    conn = _conn()
    now = now_utc()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        appr = conn.execute('SELECT * FROM approvals WHERE nonce=? AND card_id=?',
                            (nonce, card_id)).fetchone()
        if appr is None:
            return {'ok': False, 'error': 'no_approval'}
        if appr['used_at'] is not None:
            return {'ok': False, 'error': 'nonce_used'}
        if parse_rfc3339(appr['expires_at']) < now:
            return {'ok': False, 'error': 'expired'}
        card = conn.execute('SELECT * FROM cards WHERE card_id=?', (card_id,)).fetchone()
        if card is None:
            return {'ok': False, 'error': 'card_not_found'}
        if card['run_id'] is not None:
            return {'ok': False, 'error': 'run_active'}
        cp = canonical_plan(card, exec_cfg)
        if cp is None:
            return {'ok': False, 'error': 'plan_stale'}   # currently not executable (dismissed/cwd/skill drift)
        plan, sha = cp
        if sha != appr['plan_sha256']:
            return {'ok': False, 'error': 'plan_stale'}   # changed since approval: require confirmation again
        cur = conn.execute('UPDATE approvals SET used_at=? WHERE nonce=? AND used_at IS NULL',
                          (iso(now), nonce))
        if cur.rowcount != 1:                              # race loser (simultaneous click)
            return {'ok': False, 'error': 'nonce_used'}
        # Burn this card's OTHER outstanding approvals in the same transaction. One click
        # approves one execution; a preview that was opened and cancelled must not leave a
        # second capability alive for the rest of its five minutes, redeemable without any
        # further click once this run ends.
        conn.execute('UPDATE approvals SET used_at=? WHERE card_id=? AND used_at IS NULL',
                     (iso(now), card_id))
        run_id = 'run-' + now.strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3)
        conn.execute(
            'INSERT INTO runs(run_id, card_id, plan_sha256, plan_json, status, created_at) '
            'VALUES(?,?,?,?,?,?)',
            (run_id, card_id, sha, json.dumps(plan, ensure_ascii=False), 'starting', iso(now)))
        conn.execute('UPDATE cards SET run_id=? WHERE card_id=?', (run_id, card_id))
        # Redeeming an approval IS the person saying they have started (parent document's
        # todo -> doing trigger). A card that is not a task is untouched.
        if conn.execute(
                "UPDATE cards SET task_state='doing', snoozed_until=NULL WHERE card_id=?"
                + _IS_TASK + _OPEN, (card_id,)).rowcount:
            _audit(conn, 'task_start', None, card_id, 'approval-redeemed')
        _audit(conn, 'execute', None, card_id, run_id)
    return {'ok': True, 'plan': plan, 'run_id': run_id}


def run_mark_running(run_id, tmux_target):
    """starting -> running and record the target. -> True if transitioned. False means the run
    ended in the meantime, so the caller must kill the tmux window it just created as an orphan
    (#4). reap_runs never touches a targetless run, but the backend's own _reap_stuck_starting
    does once it can prove no window of this run's name exists, so False is a reachable
    outcome for a launch that took longer than that grace period — not merely defensive."""
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        cur = conn.execute(
            "UPDATE runs SET status='running', tmux_target=?, started_at=? "
            "WHERE run_id=? AND status='starting'",
            (tmux_target, iso(now_utc()), run_id))
        if cur.rowcount == 1:
            _audit(conn, 'run_running', None, None, run_id)
            return True
        return False


RUN_RESULT_LABEL = {'done': 'completed', 'failed': 'failed', 'interrupted': 'interrupted because the window closed'}


def _emit_run_result(run_id, status, exit_code, card_title):
    """Record execution termination as a message card, so its result is not missed when the
    observer modal is closed or the user is elsewhere. The execution window (tmux) remains alive,
    so this card is a notification rather than a log.

    - The group_key includes run_id, deliberately producing one card per run. With a fixed
      group_key, the 24h coalesce rule would fold multiple results into one line and lose which
      execution finished.
    - stopped is not announced: the owner just pressed Stop, so the notification would add no
      information.
    - The termination itself has already committed (this function runs outside that transaction).
      If this fails, execution state is still correct, so surface the failure on stderr but do not
      swallow it silently.
    """
    label = RUN_RESULT_LABEL.get(status)
    if label is None:
        return
    rc = '' if exit_code is None else ' (rc=%d)' % exit_code
    head = '✅ Run completed' if status == 'done' else '⚠️ Run ' + label
    title = (head + ' — ' + (card_title or run_id))[:160]
    payload = {
        'schema_version': 1,
        'event_id': 'devmon.runresult.' + run_id,
        'group_key': 'devmon:run-result:' + run_id,
        'source': 'dev-monitor',
        'kind': 'info',
        'urgency': 'normal',
        # The Outcome refuses to count the "eleven job-finished-fine notices that arrived
        # overnight", and this is the producer of every one of them.
        #
        # token-freshness.py is the producer that should be declaring True next to this one —
        # every verdict it emits ends in "re-authenticate before the deadline". It does not,
        # because that file is byte-identical to its airlock-apps copy and any edit splits it;
        # install/check-apps-divergence.py refuses new drift and its baseline is a shared gate,
        # not something this card widens on its own. Asked on the board.
        'needs_action': False,
        'title': title,
        'body': 'Run %s%s. The run window (tmux) is still open for 24 hours after turn end; '
                'use Keep if you want it indefinitely.' % (label, rc),
        'outcome': '%s%s' % (label, rc),
        'why_it_matters': 'This is the result of the work you approved and ran; use it to decide whether to keep watching it or run it again.',
        'followup': 'Open the run window (%s) in devterm and check its output.' % run_window_name(run_id),
        'created_at': iso(now_utc()),
    }
    try:
        ingest(payload)
    except Exception as e:  # noqa: BLE001 — notification failure must not roll back termination
        sys.stderr.write('[runresult] card emit fail run=%s: %s\n' % (run_id, e))


def _run_terminate(run_id, status, exit_code=None, error=None):
    """running/starting -> terminal. Clear the card run_id idempotently and emit a result card.
    -> (changed, tmux_target); without a change, -> (False, None)."""
    conn = _conn()
    changed, target, card_title = False, None, None
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        r = conn.execute('SELECT card_id, status, tmux_target FROM runs WHERE run_id=?',
                        (run_id,)).fetchone()
        if r is not None and r['status'] not in RUN_TERMINAL:
            conn.execute('UPDATE runs SET status=?, exit_code=?, error=?, ended_at=? WHERE run_id=?',
                        (status, exit_code, (error or '')[:500] or None, iso(now_utc()), run_id))
            conn.execute('UPDATE cards SET run_id=NULL WHERE card_id=? AND run_id=?',
                        (r['card_id'], run_id))
            _audit(conn, 'run_' + status, None, r['card_id'],
                   run_id + (' rc=%s' % exit_code if exit_code is not None else ''))
            # A finished run leaves the card in `doing`: the run succeeding is not the
            # problem being handled, and the person closes it. Every other ending puts the
            # task back in front of them.
            if status != 'done' and conn.execute(
                    "UPDATE cards SET task_state='todo' WHERE card_id=?" + _IS_TASK
                    + " AND task_state='doing'", (r['card_id'],)).rowcount:
                _audit(conn, 'task_reopen', None, r['card_id'], 'run-' + status)
            src = conn.execute('SELECT title FROM cards WHERE card_id=?',
                               (r['card_id'],)).fetchone()
            card_title = src['title'] if src else None
            changed, target = True, r['tmux_target']
    # Notify after commit: ingest starts its own transaction, so calling it above would nest one.
    if changed:
        _emit_run_result(run_id, status, exit_code, card_title)
    return (changed, target)


def run_finish(run_id, exit_code):
    """Sentinel received -> done (rc == 0) | failed."""
    _run_terminate(run_id, 'done' if exit_code == 0 else 'failed', exit_code=exit_code)


def run_fail(run_id, error):
    """tmux launch failure, etc. -> failed."""
    _run_terminate(run_id, 'failed', error=error)


def run_stop(run_id):
    """Owner stop -> stopped. -> (changed, tmux_target); the caller kills target."""
    return _run_terminate(run_id, 'stopped')


def run_keep(run_id):
    """Record the owner's explicit request to retain a run window indefinitely.

    Keep is allowed while a run is active as well as after turn completion, so an owner can
    make the decision before stepping away. It is intentionally one-way: this operation is an
    exemption from automatic reclamation, not another timer to manage.
    -> (ok, error), where an already-kept run is an idempotent success.
    """
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            'SELECT status, keep_requested, kept_at, reclaimed_at FROM runs WHERE run_id=?',
            (run_id,)).fetchone()
        if row is None:
            return (False, 'not_found')
        if row['reclaimed_at'] is not None:
            return (False, 'already_reclaimed')
        if row['status'] not in RUN_KEEPABLE:
            return (False, 'not_keepable')
        if row['keep_requested']:
            return (True, None)
        now = iso(now_utc())
        conn.execute('UPDATE runs SET keep_requested=1, kept_at=? WHERE run_id=?',
                     (now, run_id))
        _audit(conn, 'run_keep', None, None, run_id)
    return (True, None)


def reclaimable_runs():
    """Return terminal runs whose windows may still be reclaimed by the backend reaper."""
    rows = _conn().execute(
        'SELECT * FROM runs WHERE status IN (\'done\', \'failed\', \'stopped\', \'interrupted\') '
        'AND ended_at IS NOT NULL AND keep_requested=0 AND reclaimed_at IS NULL'
    ).fetchall()
    return [dict(row) for row in rows]


def run_mark_reclaimed(run_id, reason='retention'):
    """Record that external cleanup of a terminal run completed successfully."""
    conn = _conn()
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            'SELECT card_id, status, keep_requested, reclaimed_at FROM runs WHERE run_id=?',
            (run_id,)).fetchone()
        if (row is None or row['status'] not in RUN_TERMINAL or row['keep_requested']
                or row['reclaimed_at'] is not None):
            return False
        conn.execute('UPDATE runs SET reclaimed_at=? WHERE run_id=?',
                     (iso(now_utc()), run_id))
        _audit(conn, 'run_reclaimed', None, row['card_id'],
               '%s: %s' % (reason, run_id))
    return True


def run_window_name(run_id):
    """Display name of a run's tmux window, a label so a person can tell which window belongs to
    which run in devterm. It is NOT a correlation key: window names are not unique (same-name
    windows may coexist), and may also collide with a window that remains as a login shell after
    completion. The reaper matches run and window only with the unique, stable window_id
    (tmux_target)."""
    return 'exec-' + run_id.split('-')[-1]


# ---- view session: a tmux session that exposes only that run's window to the modal ----
VIEW_SESSION_PREFIX = 'devmon-view-'


def run_view_session(run_id):
    """Name of the run's observation tmux session.

    This value goes unchanged into devterm's URL `?arg=`, so it must survive devterm-shell's
    normalisation (`[^A-Za-z0-9_-]` -> `_`). run_id is `run-<UTC>-<hex>`, which is lossless in
    that character set (see redeem_approval). The prefix filters it in devterm's session list.
    """
    return VIEW_SESSION_PREFIX + run_id


def run_view_request(run_row, alive_keys, session):
    """Pure decision about whether to open an observation session. -> (ok, payload|error_code).

    Fail closed: return window_id only if the stored target matches the current-generation alive
    set by its FULL key (`<server_pid>:<window_id>`). Comparing window_id alone would attach to a
    different run's window after a tmux server restart reuses `@N` — the exact High2 trap hit in
    round 7 on the kill path. Viewing attaches with write access, so that could send keystrokes to
    someone else's run.

    error_code uses the same vocabulary as the stop path (the frontend maps its messages in one
    place): not_found / not_active / launching (target not recorded) / stale_target_format /
    stale_generation (generation mismatch or window gone) / tmux_unavailable (alive query unknown).
    """
    if run_row is None:
        return (False, 'not_found')
    if run_row['status'] not in RUN_ACTIVE:
        return (False, 'not_active')
    target = run_row['tmux_target']
    if target is None:
        return (False, 'launching')             # launching: frontend retries briefly
    if alive_keys is None:
        return (False, 'tmux_unavailable')      # defer judgement; do not misidentify a live window as gone
    if ':' not in target:
        return (False, 'stale_target_format')   # legacy (@N): generation cannot be compared
    if target not in alive_keys:
        return (False, 'stale_generation')
    return (True, {'view': run_view_session(run_row['run_id']),
                   'window_id': target.rsplit(':', 1)[-1],
                   'target': target,
                   'session': session})


def active_view_sessions():
    """Set of view-session names that must remain alive: active (starting|running) runs.
    The reconciler uses it to reap any devmon-view-* outside this set, idempotently."""
    conn = _conn()
    rows = conn.execute(
        "SELECT run_id FROM runs WHERE status IN ('starting','running')").fetchall()
    return {run_view_session(r['run_id']) for r in rows}


REAP_GRACE_S = 30


def reap_runs(alive_ids, now=None):
    """Backstop. alive_ids is the set of window_ids currently present in the exec session.

    Correlation uses only the stored tmux_target (window_id). tmux assigns a unique, non-reused
    window_id to every window, which makes it reliable; window names are not unique and therefore
    cannot be correlation keys (the root cause in rounds 4/5/6). The sentinel is the normal
    completion path. The reaper cleans up only a sudden window death (external kill, etc.) that
    happens without the sentinel:

    - No recorded target (launching, or crash before mark_running): leave it alone. The sentinel
      records normal completion, and until then the card lock prevents double execution. Ending it
      rashly here would orphan a live Claude process (round 4).
    - Target recorded and window alive: retain it.
    - Target recorded but window gone, and the target record (started_at) is older than the
      REAP_GRACE_S grace period: window (= process) death is certain -> interrupted.
      The grace period MUST use started_at (the point where the window is created and target is
      recorded), not created_at. In a straddle where the reaper snapshots windows just before one
      is created and its target recorded, started_at is approximately the snapshot time and is
      always inside grace. If based on created_at, a launch delayed over 30 seconds (lock contention
      or tmux hang) would have expired grace already, interrupting a live window, unlocking its card
      and allowing double execution (round 7 High1).
    """
    conn = _conn()
    now = now or now_utc()
    alive = set(alive_ids)
    rows = conn.execute(
        "SELECT run_id, tmux_target, started_at FROM runs "
        "WHERE status IN ('starting','running')").fetchall()
    for r in rows:
        tgt = r['tmux_target']
        if tgt is None:
            continue                                      # launching/crash-orphan: sentinel and card lock own it
        if ':' not in tgt:
            # Legacy format without generation (pid) (@N): it cannot be safely compared with a
            # current pid:@N key. Matching its suffix in this generation reopens the window-id reuse
            # overkill (High2), so do NOT terminate it. (Not present in a real deployment: runs have
            # stored native pid:wid from the first deployment. This is a format-migration guard, round 8.)
            continue
        if tgt in alive:
            continue                                      # recorded window is live (generation-aware comparison)
        # With a target, started_at must exist too; run_mark_running writes both together.
        if r['started_at'] is None:
            continue                                      # theoretically impossible: target exists without started_at
        age = (now - parse_rfc3339(r['started_at'])).total_seconds()
        if age < REAP_GRACE_S:
            continue                                      # target just recorded; snapshot may predate its window
        _run_terminate(r['run_id'], 'interrupted')        # confirmed window disappearance -> terminate


def _run_to_dict(r):
    return {'run_id': r['run_id'], 'card_id': r['card_id'], 'status': r['status'],
            'exit_code': r['exit_code'], 'error': r['error'], 'tmux_target': r['tmux_target'],
            'created_at': r['created_at'], 'started_at': r['started_at'], 'ended_at': r['ended_at'],
            'keep': bool(r['keep_requested']), 'kept_at': r['kept_at'],
            'reclaimed_at': r['reclaimed_at'],
            'plan': json.loads(r['plan_json'])}


def list_runs(card_id=None, limit=50):
    conn = _conn()
    if card_id:
        rows = conn.execute('SELECT * FROM runs WHERE card_id=? ORDER BY created_at DESC LIMIT ?',
                          (card_id, limit)).fetchall()
    else:
        rows = conn.execute('SELECT * FROM runs ORDER BY created_at DESC LIMIT ?',
                          (limit,)).fetchall()
    return {'runs': [_run_to_dict(r) for r in rows]}


def get_run(run_id):
    r = _conn().execute('SELECT * FROM runs WHERE run_id=?', (run_id,)).fetchone()
    return _run_to_dict(r) if r else None


def active_run_targets():
    """(run_id, tmux_target): runs that should be alive. Used by the reaper for its alive check."""
    rows = _conn().execute(
        "SELECT run_id, tmux_target FROM runs WHERE status IN ('starting','running')").fetchall()
    return [(r['run_id'], r['tmux_target']) for r in rows]


# ============================================================
# Slack outbox (P4): urgent cards are enqueued into deliveries by ingest; the worker sends them.
# At least once: retry with backoff until success; after the cap mark failed. slack_sent_at is
# orthogonal to read state.
# ============================================================
MAX_DELIVERY_ATTEMPTS = 6
DELIVERY_LEASE_SECONDS = 120


def delivery_lane_health(channel, at=None):
    """Derive one lane's delivery health from the outbox ledger.

    ``consecutive_failures`` is deliberately a row count, not an attempt counter: it is
    the number of delivery rows whose ``last_error_at`` is later than this lane's most
    recent successful delivery. Keeping the definition here makes the API reproducible
    from the retained ledger without a second, drift-prone counter.
    """
    conn = _conn()
    at = at or now_utc()
    # One SQL statement is load-bearing: workers update the ledger concurrently, and
    # separate SELECTs can otherwise combine a pre-send pending count with a post-send
    # success/error result in one impossible health object.
    sent_valid = _health_timestamp_valid_sql('sent_at')
    error_valid = _health_timestamp_valid_sql('last_error_at')
    created_valid = _health_timestamp_valid_sql('created_at')
    next_attempt_valid = _health_timestamp_valid_sql('next_attempt_at')
    summary = conn.execute(
        "WITH valid_success AS MATERIALIZED ("
        "SELECT sent_at AS last_success_at "
        "FROM deliveries INDEXED BY idx_deliveries_health_sent_v3 "
        "WHERE channel=:channel AND status='sent' AND sent_at IS NOT NULL "
        "AND " + sent_valid + " "
        "ORDER BY sent_at DESC, id DESC LIMIT 1), "
        "success AS MATERIALIZED (SELECT last_success_at "
        "FROM valid_success UNION ALL SELECT NULL "
        "WHERE NOT EXISTS (SELECT 1 FROM valid_success)), "
        "open_summary AS MATERIALIZED (SELECT COUNT(*) AS pending_count, "
        "SUM(CASE WHEN last_error='http 429' "
        "AND " + next_attempt_valid + " AND next_attempt_at>:at "
        "THEN 1 ELSE 0 END) AS rate_limited_count, "
        "MIN(COALESCE(CASE WHEN " + created_valid + " THEN julianday(created_at) END, "
        "CASE WHEN " + next_attempt_valid + " THEN julianday(next_attempt_at) END)) "
        "AS oldest_pending_jd FROM deliveries INDEXED BY idx_deliveries_claim "
        "WHERE channel=:channel AND status IN ('pending','claimed')), "
        "latest_error AS MATERIALIZED (SELECT last_error, last_error_at FROM deliveries "
        "INDEXED BY idx_deliveries_health_error_valid_v3 WHERE channel=:channel "
        "AND status!='superseded' AND last_error_at IS NOT NULL "
        "AND " + error_valid + " "
        "ORDER BY last_error_at DESC, id DESC LIMIT 1), "
        "error_count AS MATERIALIZED (SELECT COUNT(*) AS n FROM deliveries "
        "INDEXED BY idx_deliveries_health_error_valid_v3, success "
        "WHERE channel=:channel AND status!='superseded' AND last_error_at IS NOT NULL "
        "AND " + error_valid + " AND "
        "(success.last_success_at IS NULL OR last_error_at>success.last_success_at)), "
        "failed_count AS MATERIALIZED (SELECT COUNT(*) AS n FROM deliveries "
        "INDEXED BY idx_deliveries_health_failed_v3, success WHERE channel=:channel "
        "AND status='failed' AND (success.last_success_at IS NULL OR "
        "(last_error_at IS NOT NULL AND " + error_valid + " "
        "AND last_error_at>success.last_success_at))), "
        "bad_timestamp AS MATERIALIZED (SELECT COUNT(*) AS n FROM deliveries "
        "INDEXED BY idx_deliveries_health_bad_timestamp_v3 WHERE channel=:channel AND ("
        "(status='sent' AND (sent_at IS NULL OR NOT " + sent_valid + ")) OR "
        "(status!='superseded' AND last_error_at IS NOT NULL "
        "AND NOT " + error_valid + ") OR "
        "(status IN ('pending','claimed') AND "
        "NOT " + created_valid + " AND NOT " + next_attempt_valid + "))) "
        "SELECT CASE WHEN success.last_success_at IS NOT NULL "
        "OR open_summary.pending_count>0 OR error_count.n>0 OR failed_count.n>0 "
        "OR bad_timestamp.n>0 THEN 1 ELSE 0 END AS total, "
        "success.last_success_at, CASE WHEN success.last_success_at IS NULL THEN NULL "
        "ELSE MAX(0, CAST((julianday(:at)-julianday(success.last_success_at))*86400 "
        "AS INTEGER)) END AS last_success_age, open_summary.pending_count, "
        "open_summary.rate_limited_count, CASE WHEN oldest_pending_jd IS NULL THEN NULL "
        "ELSE MAX(0, CAST((julianday(:at)-oldest_pending_jd)*86400 AS INTEGER)) END "
        "AS oldest_pending_age, latest_error.last_error, latest_error.last_error_at, "
        "error_count.n AS consecutive_failures, failed_count.n "
        "AS terminal_failures_since_success, bad_timestamp.n AS ledger_error_count "
        "FROM success CROSS JOIN open_summary CROSS JOIN error_count "
        "CROSS JOIN failed_count CROSS JOIN bad_timestamp LEFT JOIN latest_error ON 1=1",
        {'channel': channel, 'at': iso(at)}).fetchone()

    total = int(summary['total'])
    last_success_at = summary['last_success_at']
    pending_count = int(summary['pending_count'] or 0)
    rate_limited_count = int(summary['rate_limited_count'] or 0)
    oldest_pending_age = summary['oldest_pending_age']

    last_error = summary['last_error']
    last_error_at = summary['last_error_at']
    failures = summary['consecutive_failures']
    terminal_failures = summary['terminal_failures_since_success']

    if total == 0:
        delivery_state = 'idle'
    elif rate_limited_count:
        delivery_state = 'rate-limited'
    elif pending_count:
        delivery_state = 'pending'
    elif last_error_at is not None and (
            last_success_at is None or last_error_at > last_success_at):
        delivery_state = 'failed'
    elif last_success_at is not None:
        delivery_state = 'sent'
    else:
        delivery_state = 'failed'

    return {
        'delivery_state': delivery_state,
        'last_success_at': last_success_at,
        'last_success_age_seconds': summary['last_success_age'],
        'pending_count': pending_count,
        'oldest_pending_age_seconds': oldest_pending_age,
        'last_error': last_error,
        'last_error_at': last_error_at,
        'consecutive_failures': int(failures),
        'terminal_failures_since_success': int(terminal_failures),
        'ledger_error_count': int(summary['ledger_error_count']),
    }


def claim_due_deliveries(channel, limit=10):
    """Atomically claim one lane's due rows and return their card projection."""
    conn = _conn()
    now_dt = now_utc()
    now = iso(now_dt)
    lease_until = iso(now_dt + timedelta(seconds=DELIVERY_LEASE_SECONDS))
    worker = f"{channel}:{os.getpid()}:{secrets.token_hex(4)}"
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        retired = conn.execute(
            "UPDATE deliveries SET status='failed', last_error='attempt budget exhausted', "
            "last_error_at=?, claimed_by=NULL, lease_until=NULL "
            "WHERE channel=? AND attempts>=? "
            "AND (status='pending' OR (status='claimed' AND lease_until<=?))",
            (now, channel, MAX_DELIVERY_ATTEMPTS, now))
        if retired.rowcount:
            _audit(conn, 'slack_failed', None, None,
                   'lane=%s retired=%d reason=attempt budget exhausted' %
                   (channel, retired.rowcount))
            sys.stderr.write(
                '[devmon_messages] retired exhausted deliveries '
                'lane=%s count=%d\n' % (channel, retired.rowcount))

        claimed = conn.execute(
            "UPDATE deliveries SET status='claimed', claimed_by=?, lease_until=?, "
            "attempts=attempts+1 WHERE id IN ("
            "SELECT id FROM deliveries WHERE channel=? AND attempts<? AND ("
            "(status='pending' AND (next_attempt_at IS NULL OR next_attempt_at<=?)) OR "
            "(status='claimed' AND lease_until<=?)) ORDER BY id LIMIT ?) RETURNING id",
            (worker, lease_until, channel, MAX_DELIVERY_ATTEMPTS, now, now, limit)).fetchall()
        ids = sorted(row[0] for row in claimed)
        if not ids:
            return []
        placeholders = ','.join('?' for _ in ids)
        rows = conn.execute(
            'SELECT d.id AS id, d.card_id AS card_id, d.channel AS channel, '
            'd.attempts AS attempts, d.claimed_by AS claimed_by, '
            'd.lease_until AS lease_until, c.title AS title, c.body AS body, '
            'c.action_json AS action_json, c.urgency AS urgency, c.source AS source, '
            'c.kind AS kind, c.occurrence_count AS occurrence_count, c.owner AS owner '
            'FROM deliveries d JOIN cards c ON c.card_id=d.card_id '
            'WHERE d.id IN (%s) ORDER BY d.id' % placeholders,
            ids).fetchall()
        result = []
        for row in rows:
            item = dict(row)
            action = json.loads(item.pop('action_json')) if item['action_json'] else None
            item['action'] = action
            item['action_line'] = action.get('explain') if action else None
            result.append(item)
        return result


def delivery_sent(delivery_id, card_id, worker):
    """Delivery succeeded -> mark sent and set the card's slack_sent_at (first time only).
    Does not touch read state; the two axes are orthogonal."""
    conn = _conn()
    now = iso(now_utc())
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        cur = conn.execute(
            "UPDATE deliveries SET status='sent', sent_at=?, next_attempt_at=NULL, "
            "claimed_by=NULL, lease_until=NULL WHERE id=? AND status='claimed' "
            "AND claimed_by=?", (now, delivery_id, worker))
        if cur.rowcount != 1:
            return False
        conn.execute('UPDATE cards SET slack_sent_at=? WHERE card_id=? AND slack_sent_at IS NULL',
                    (now, card_id))
        _audit(conn, 'slack_sent', None, card_id, 'delivery=%s' % delivery_id)
        return True


def delivery_failed(delivery_id, worker, error):
    """Fail a claimed delivery immediately for a terminal remote response."""
    conn = _conn()
    now = iso(now_utc())
    short_error = (error or '')[:300]
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            'SELECT card_id, attempts FROM deliveries WHERE id=?', (delivery_id,)).fetchone()
        if row is None:
            return False
        cur = conn.execute(
            "UPDATE deliveries SET status='failed', next_attempt_at=NULL, last_error=?, "
            "last_error_at=?, claimed_by=NULL, lease_until=NULL "
            "WHERE id=? AND status='claimed' AND claimed_by=?",
            (short_error, now, delivery_id, worker))
        if cur.rowcount != 1:
            # The claim pass may have retired an expired sixth attempt while its
            # terminal HTTP response was in flight. Preserve the actionable code.
            conn.execute(
                "UPDATE deliveries SET last_error=?, last_error_at=? WHERE id=? "
                "AND status='failed' AND last_error='attempt budget exhausted'",
                (short_error, now, delivery_id))
            return False
        _audit(conn, 'slack_failed', None, row['card_id'],
               'delivery=%s attempts=%d terminal' % (delivery_id, row['attempts']))
        return True


def delivery_retry(delivery_id, worker, error, retry_after=None):
    """Record a claimed attempt's failure without accepting a stale claimant's outcome."""
    conn = _conn()
    now = now_utc()
    now_text = iso(now)
    short_error = (error or '')[:300]
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            'SELECT card_id, attempts FROM deliveries WHERE id=?', (delivery_id,)).fetchone()
        if row is None:
            return False
        attempts = row['attempts']
        if attempts >= MAX_DELIVERY_ATTEMPTS:
            cur = conn.execute(
                "UPDATE deliveries SET status='failed', next_attempt_at=NULL, last_error=?, "
                "last_error_at=?, claimed_by=NULL, lease_until=NULL "
                "WHERE id=? AND status='claimed' AND claimed_by=?",
                (short_error, now_text, delivery_id, worker))
            if cur.rowcount == 1:
                _audit(conn, 'slack_failed', None, row['card_id'],
                       'delivery=%s attempts=%d' % (delivery_id, attempts))
                return True
        else:
            delay = retry_after if retry_after is not None else _delivery_jitter_seconds(attempts)
            cur = conn.execute(
                "UPDATE deliveries SET status='pending', next_attempt_at=?, last_error=?, "
                "last_error_at=?, claimed_by=NULL, lease_until=NULL "
                "WHERE id=? AND status='claimed' AND claimed_by=?",
                (iso(now + timedelta(seconds=delay)), short_error, now_text,
                 delivery_id, worker))
            if cur.rowcount == 1:
                return True

        # A claim pass may have retired this expired at-cap row before its stale POST
        # returned. Keep the actionable HTTP reason while still rejecting the stale CAS.
        conn.execute(
            "UPDATE deliveries SET last_error=?, last_error_at=? WHERE id=? "
            "AND status='failed' AND last_error='attempt budget exhausted'",
            (short_error, now_text, delivery_id))
        return False
