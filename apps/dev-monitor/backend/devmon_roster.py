#!/usr/bin/env python3
"""devmon_roster — resolve a card's declared owner against the company roster snapshot.

`roster.json` is produced by another repository (a daily timer, 06:45 local) and read here
as a snapshot, never a query: this box holds no directory credential, and delivery must work
when the network does not. Five distinct failures at the configured path — not configured, no
file, unreadable, unparseable, or parseable with no `generated_at` — collapse to the same
outcome as a snapshot older than 72 hours: resolution falls back to the box owner. A sixth,
an owner id the snapshot does not contain, falls back the same way. Collapsing them is the
point: each is a producer or a deployment broken in a different way, and none of them is a
reason to withhold a notification. What must not happen is the quiet version — every fallback
carries a reason, so a card can say what happened instead of only logging it.

docs/tasks/active/dev-monitor-inbox.md, section "The roster", is the contract this module
implements; that document's wording ("resolve to the box owner, and say so") is authoritative
over anything below.
"""
import json
from datetime import datetime, timedelta, timezone

STALE_AFTER = timedelta(hours=72)


def _parse_generated_at(value):
    """RFC3339/ISO 8601 UTC only, timezone-aware. None on anything else."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        return None
    return dt.astimezone(timezone.utc)


def load_snapshot(path, now=None):
    """Read the roster file once. -> a snapshot dict, reusable across many resolve() calls
    for one request so a feed of N cards reads the file once rather than N times.

    people is None whenever the snapshot cannot be trusted (five conditions, one of them
    staleness) — `reason` names why. generated_at/age_seconds are reported even when the
    snapshot is too stale to use, so a caller can still say how old the name it fell back
    from was.
    """
    now = now or datetime.now(timezone.utc)
    path = (path or '').strip()
    if not path:
        return {'people': None, 'generated_at': None, 'age_seconds': None,
                'reason': 'not-configured'}
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {'people': None, 'generated_at': None, 'age_seconds': None, 'reason': 'missing'}
    except OSError:
        # Permission denied, and anything else opening a file can do short of "not there".
        return {'people': None, 'generated_at': None, 'age_seconds': None,
                'reason': 'unreadable'}
    try:
        data = json.loads(raw)
    except ValueError:
        return {'people': None, 'generated_at': None, 'age_seconds': None,
                'reason': 'invalid-json'}
    if not isinstance(data, dict):
        return {'people': None, 'generated_at': None, 'age_seconds': None,
                'reason': 'invalid-json'}
    generated_at = _parse_generated_at(data.get('generated_at'))
    if generated_at is None:
        return {'people': None, 'generated_at': None, 'age_seconds': None,
                'reason': 'missing-generated-at'}
    people = data.get('people')
    if not isinstance(people, dict):
        return {'people': None, 'generated_at': generated_at, 'age_seconds': None,
                'reason': 'invalid-json'}
    age_seconds = max(0.0, (now - generated_at).total_seconds())
    if timedelta(seconds=age_seconds) > STALE_AFTER:
        return {'people': None, 'generated_at': generated_at, 'age_seconds': age_seconds,
                'reason': 'stale'}
    return {'people': people, 'generated_at': generated_at, 'age_seconds': age_seconds,
            'reason': None}


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def resolve(raw_owner, snapshot, box_owner):
    """Resolve one card's declared owner against an already-loaded snapshot.

    raw_owner is the exact string a card carries (already normalised by the validator, or
    None if no owner was declared). -> a dict a caller can put straight on a card or fold
    into a Slack/email line: `owner` is always the identity to attribute this card to —
    the declared owner when resolved, the box owner on any fallback.
    """
    result = {
        'declared': raw_owner,
        'owner': raw_owner,
        'name': None,
        'email': None,
        'slack_member_id': None,
        'fallback': False,
        'fallback_reason': None,
        'roster_generated_at': _iso(snapshot['generated_at']) if snapshot['generated_at'] else None,
        'roster_age_seconds': snapshot['age_seconds'],
    }
    if raw_owner is None:
        result['owner'] = box_owner
        result['fallback'] = True
        result['fallback_reason'] = snapshot['reason'] or 'no-owner-declared'
        return result
    people = snapshot['people']
    if people is None:
        result['owner'] = box_owner
        result['fallback'] = True
        result['fallback_reason'] = snapshot['reason']
        return result
    person = people.get(raw_owner)
    if not isinstance(person, dict):
        result['owner'] = box_owner
        result['fallback'] = True
        result['fallback_reason'] = 'unknown-owner'
        return result
    result['name'] = person.get('name')
    result['email'] = person.get('email')
    result['slack_member_id'] = person.get('slack_member_id')
    return result
