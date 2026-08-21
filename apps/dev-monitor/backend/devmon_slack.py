#!/usr/bin/env python3
"""devmon_slack — the outbox worker that pushes urgent cards to Slack. stdlib only.

At-least-once, deliberately: a duplicate ping is a nuisance, a missed one is the failure
this feature exists to prevent. ingest() enqueues at the moment a card becomes urgent; this
worker claims pending deliveries, sends, and either marks them sent or reschedules with
backoff (giving up as failed after the cap).

The webhook URL is a SECRET, injected via DEV_MONITOR_SLACK_WEBHOOK. This module never puts
that value into a log line or an exception message — which is why send() returns a short
error string of its own making rather than letting a urllib exception carry the URL out.
"""
import json
import sys
import urllib.error
import urllib.request

import devmon_messages as MSG

URGENCY_MARK = {'urgent': '🔴', 'normal': '•'}
# enum -> what a human reads in Slack. Not an identity map: the point is that 'action'
# reads as something being asked of you, which the bare enum name does not convey.
KIND_LABEL = {'action': 'action requested', 'link': 'link', 'info': 'notice'}
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
    mark = URGENCY_MARK.get(card.get('urgency'), '•')
    kind = KIND_LABEL.get(card.get('kind'), card.get('kind', ''))
    lines = ['%s *%s*' % (mark, esc_mrkdwn(card.get('title', '(no title)'))),
             '_%s · %s_' % (esc_mrkdwn(card.get('source', '?')), esc_mrkdwn(kind))]
    if card.get('occurrence_count', 1) > 1:
        lines[-1] += '  ×%d' % card['occurrence_count']

    body_items = _body_items(card.get('body'))
    shown = body_items[:MAX_BODY_ITEMS]
    for index, item in enumerate(shown):
        detail = esc_mrkdwn(_truncate_detail(item))
        lines.append(detail if index == 0 else '• ' + detail)
    omitted = len(body_items) - len(shown)
    if omitted:
        lines.append('• … (%d more items omitted)' % omitted)

    action_line = card.get('action_line')
    if action_line is not None and str(action_line).strip():
        lines.append('• Action: ' + esc_mrkdwn(_truncate_detail(action_line)))
    # P4: mention the resolved owner only when the roster actually names a Slack member —
    # a card with no declared owner, or one that fell back to the box owner, adds nothing
    # here. The fallback itself is not silent; it is visible on the card (the console/API
    # projection), which is where "not only in the log" is verified. Repeating it in every
    # Slack line for cards nobody assigned would be noise, not visibility.
    owner_info = MSG.resolve_owner(card.get('owner'))
    if not owner_info['fallback'] and owner_info['slack_member_id']:
        lines.append('• Owner: <@%s>' % owner_info['slack_member_id'])
    if console_url:
        lines.append('<%s|Open in the console>' % console_url)
    return '\n'.join(lines)


def send(webhook, text, timeout=8):
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


def _terminal_http(code):
    return isinstance(code, int) and 400 <= code < 500 and code not in (408, 429)


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


def _error_reason(code):
    return 'http %d' % code if isinstance(code, int) else str(code)


def run_worker(lane, webhook, stop_event, console_url=''):
    """One lane's outbox worker: one thread, one pass every 5 seconds."""
    while not stop_event.is_set():
        try:
            batch = MSG.claim_due_deliveries(lane, 10)
            for index, d in enumerate(batch):
                if index and stop_event.wait(1):
                    break
                ok, code, retry_after = send(webhook, format_text(d, console_url))
                if ok:
                    MSG.delivery_sent(d['id'], d['card_id'], d['claimed_by'])
                elif _terminal_http(code):
                    MSG.delivery_failed(
                        d['id'], d['claimed_by'], _error_reason(code))
                else:
                    MSG.delivery_retry(
                        d['id'], d['claimed_by'], _error_reason(code),
                        _retry_after_seconds(code, retry_after))
        except Exception as e:                      # noqa: BLE001 — the worker must not die
            sys.stderr.write('[slack] worker err: %s\n' % type(e).__name__)
        stop_event.wait(5)
