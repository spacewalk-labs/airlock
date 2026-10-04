#!/usr/bin/env python3
"""Slack formatting and bounded HTTP transport; scheduling belongs to the loop."""
import json
import re
import urllib.error
import urllib.request

from devmon_secrets import resolve, slack_webhooks


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


def format_text(card, console_url='', resolved=False):
    """Build the message text. A card's title/source go to the owner's own channel so they
    are not secrets, but they are escaped anyway to prevent mrkdwn injection. console_url is
    server-generated, so it is used as-is."""
    mark = '✅' if resolved else LEVEL_MARK.get(card.get('level'), '•')
    title = card.get('title', '(no title)')
    if resolved:
        title = title.removeprefix('✅ ')
    lines = ['%s *%s*' % (mark, esc_mrkdwn(title)),
             esc_mrkdwn(card.get('source', '?'))]
    if card.get('count', 1) > 1:
        lines[-1] += ' ×%d' % card['count']

    body = card.get('body')
    body_items = ([body] if body else []) if resolved else _body_items(body)
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


def _bot_request(token, method, payload, timeout):
    """Return (ok, code, raw Retry-After, ts); never expose response text."""
    try:
        req = urllib.request.Request(
            'https://slack.com/api/' + method,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Authorization': 'Bearer ' + token,
                     'Content-Type': 'application/json; charset=utf-8'})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            code = response.status
            retry_after = response.headers.get('Retry-After')
            if not 200 <= code < 300:
                return False, code, retry_after, None
            body = json.load(response)
            if not isinstance(body, dict):
                return False, 'invalid_response', retry_after, None
            if body.get('ok') is True:
                ts = body.get('ts')
                if not isinstance(ts, str) or not re.fullmatch(r'[0-9]+\.[0-9]+', ts):
                    return False, 'invalid_response', retry_after, None
                return True, code, retry_after, ts
            error = body.get('error')
            if (not isinstance(error, str) or not re.fullmatch(r'[a-z_]+', error)
                    or token in error):
                error = 'invalid_response'
            return False, error, retry_after, None
    except urllib.error.HTTPError as error:
        return False, error.code, error.headers.get('Retry-After') if error.headers else None, None
    except Exception as error:  # noqa: BLE001 — type only, never token/channel/response
        return False, type(error).__name__, None, None


def post_message(token, channel, text, timeout=2):
    return _bot_request(token, 'chat.postMessage', {'channel': channel, 'text': text}, timeout)


def update_message(token, channel, ts, text, timeout=2):
    return _bot_request(token, 'chat.update', {'channel': channel, 'ts': ts, 'text': text}, timeout)


class BotSender:
    def __init__(self, token, channel):
        self.token = token
        self.channel = channel

    def __call__(self, text):
        return post_message(self.token, self.channel, text)

    def update(self, ts, text):
        return update_message(self.token, self.channel, ts, text)


def make_sender(env):
    """Choose bot when complete, otherwise the existing webhook, otherwise no sender."""
    token = resolve(env, env.get('DEVMON_SLACK_BOT_TOKEN_NAME')).strip()
    channel = env.get('DEVMON_SLACK_CHANNEL', '').strip()
    if token and channel:
        return BotSender(token, channel)
    webhook = slack_webhooks(env)['slack-urgent']
    if webhook:
        return lambda text: send(webhook, text)
    return None


def _retry_after_seconds(code, value):
    """Accept rate-limit delta-seconds; dates and malformed values use jitter."""
    if code not in (429, 'ratelimited') or value is None:
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
