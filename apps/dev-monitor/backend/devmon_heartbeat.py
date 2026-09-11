"""Canonical daily heartbeat payload, shared by publisher and collector.

This is a content contract, not source authentication. Ordinary messages keep
their existing schema. Phase 4 changes the heartbeat wire format here once.
"""
from datetime import timezone


def heartbeat_payload(created):
    """Build the one heartbeat shape for an aware instant's UTC calendar day."""
    if created.tzinfo is None:
        raise ValueError('heartbeat timestamp must be timezone-aware')
    created = created.astimezone(timezone.utc)
    day = created.date().isoformat()
    title = '살아 있음 ' + day
    return {
        'id': 'heartbeat:' + day,
        'group': 'heartbeat',
        'source': 'heartbeat',
        'level': 'urgent',
        'title': title,
        'body': '하루 한 번 스풀부터 알림까지 도착하는 하트비트입니다.',
    }
