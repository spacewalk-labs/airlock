#!/usr/bin/env python3
"""Slack formatting and bounded HTTP transport; scheduling belongs to the loop."""
import json
import urllib.error
import urllib.request


LEVEL_MARK = {'urgent': '🔴', 'normal': '•'}
MAX_BODY_ITEMS = 4
MAX_DETAIL_CHARS = 240


def esc_mrkdwn(s):
    """Escape Slack mrkdwn control characters, so a semi-trusted title cannot turn into
    <!channel> or a disguised <url|link>. Slack's rule is that escaping & < > is enough to
    neutralise both the link and the mention syntax."""
    return (str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))


def _truncate_detail(value, limit=MAX_DETAIL_CHARS):
    """Bound one detail while making character loss explicit."""
    text = str(value).strip()
    if len(text) <= limit:
        return text
    return '%s… (%d chars omitted)' % (text[:limit], len(text) - limit)


def _body_items(body):
    """Read newline or convention-style `• ` body items without preserving empty rows."""
    items = []
    for line in str(body or '').splitlines():
        # Console bodies use `• ` because their list view collapses newlines. Accept both
        # forms here so Slack keeps the same semantic item boundaries.
        for part in line.split('• '):
            part = part.strip()
            if part:
                items.append(part)
    return items


def format_text(card, console_url=''):
    """Build the message text. A card's title/source go to the owner's own channel so they
    are not secrets, but they are escaped anyway to prevent mrkdwn injection. console_url is
    server-generated, so it is used as-is."""
    mark = LEVEL_MARK.get(card.get('level'), '•')
    lines = ['%s *%s*' % (mark, esc_mrkdwn(card.get('title', '(no title)'))),
             esc_mrkdwn(card.get('source', '?'))]
    if card.get('count', 1) > 1:
        lines[-1] += ' ×%d' % card['count']

    body_items = _body_items(card.get('body'))
    shown = body_items[:MAX_BODY_ITEMS]
    for index, item in enumerate(shown):
        detail = esc_mrkdwn(_truncate_detail(item))
        lines.append(detail if index == 0 else '• ' + detail)
    omitted = len(body_items) - len(shown)
    if omitted:
        lines.append('• … (%d more items omitted)' % omitted)

    if console_url:
        lines.append('<%s|Open in the console>' % console_url)
    return '\n'.join(lines)


def send(webhook, text, timeout=2):
    """POST to the webhook. -> (ok, status-or-error-type, raw Retry-After)."""
    data = json.dumps({'text': text}).encode('utf-8')
    req = urllib.request.Request(webhook, data=data,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            code = getattr(r, 'status', None)
            if code is None:
                code = r.getcode()
            retry_after = r.headers.get('Retry-After') if getattr(r, 'headers', None) else None
            return (200 <= code < 300), code, retry_after
    except urllib.error.HTTPError as e:
        retry_after = e.headers.get('Retry-After') if e.headers else None
        return False, e.code, retry_after
    except Exception as e:                          # noqa: BLE001 — type only, never the URL
        return False, type(e).__name__, None


def _retry_after_seconds(code, value):
    """Accept only 429 delta-seconds; dates and malformed remote values use jitter."""
    if code != 429 or value is None:
        return None
    # HTTP optional whitespace is SP / HTAB. str.strip() would also erase Unicode
    # whitespace and could turn a non-ASCII remote value into an accepted delta.
    raw = str(value).strip(' \t')
    if not raw.isascii() or not raw.isdecimal():
        return None
    try:
        seconds = int(raw, 10)
    except (TypeError, ValueError, OverflowError):
        return None
    if seconds < 0:
        return None
    return max(1, min(seconds, 3600))
