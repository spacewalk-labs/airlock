#!/usr/bin/env python3
"""devmon_email — the outbox worker that mails `page` cards. stdlib only.

Email is the second path for `page` (D3_EMAIL, 2026-08-08), and its value is that it fails
independently of Slack and leaves a record. It is a fourth value of the `deliveries.channel`
column, not a second queue: the same atomic claim, the same backoff, the same terminal
`failed` with a reason, the same per-lane health.

**A transport that is not configured produces no rows at all.** On 2026-07-30 a webhook was
empty, the worker never started, and four urgent cards sat in the queue for nine days while
the health endpoint reported the feature "on". So `config_from_env` returns None rather than a
half-filled object, the server leaves `email` out of the enabled channels, and the settings
screen says unconfigured — the routing table still says `page -> email`, because the rule and
this box's ability to obey it are two different facts and collapsing them is how the first one
disappears.

SMTP_PASSWORD is a SECRET. This module never puts it in a log line or an exception message,
which is why send() returns a short reason of its own making rather than letting an smtplib
exception carry the connection details out.
"""
import email.utils
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

import devmon_messages as MSG

LANE = 'email'
DEFAULT_PORT = 587
CONNECT_TIMEOUT = 20
MAX_BODY_CHARS = 4000


def config_from_env(env=None):
    """Build the transport config, or None when this box cannot send mail.

    All-or-nothing on purpose: a host with no recipient is not a partly working email path,
    it is a lane that would accept rows and never deliver them.
    """
    env = os.environ if env is None else env
    host = (env.get('DEV_MONITOR_SMTP_HOST') or '').strip()
    sender = (env.get('DEV_MONITOR_SMTP_FROM') or '').strip()
    # Recipients are the box owner's, full stop — P4 resolves a card's owner into an email
    # address and exposes it on the card projection (`owner_resolved.email`), but routing
    # `page` mail to that address instead of this static list is a separate decision this
    # box has not been given (human decision 2026-08-18: the email lane stays as configured).
    # Comma-separated, because an operator writing one address should not have to think.
    # De-duplicated, order kept. Two reasons, and the second is the one that bites: nobody
    # wants the same alert twice, and smtplib keys its refusal dict by address — so with
    # `a@x,a@x` a server refusing everybody returns one entry against two configured
    # recipients, and the partial-refusal branch below would call a delivery that reached
    # nobody a success.
    to, seen = [], set()
    for a in (env.get('DEV_MONITOR_SMTP_TO') or '').split(','):
        a = a.strip()
        if a and a not in seen:
            seen.add(a)
            to.append(a)
    if not host or not sender or not to:
        return None
    raw_port = (env.get('DEV_MONITOR_SMTP_PORT') or '').strip()
    try:
        port = int(raw_port) if raw_port else DEFAULT_PORT
    except ValueError:
        # A misspelled port is a configuration error, and guessing 587 here would mean the
        # operator's typo never surfaces anywhere.
        return None
    if not 1 <= port <= 65535:
        return None
    return {
        'host': host,
        'port': port,
        'from': sender,
        'to': tuple(to),
        # Both rulings the operator can make fit this one shape: an IP-registered relay sends
        # with no credential, an app password sends with one.
        'user': (env.get('DEV_MONITOR_SMTP_USER') or '').strip(),
        'password': env.get('DEV_MONITOR_SMTP_PASSWORD') or '',
    }


def format_message(card, console_url=''):
    """-> (subject, body). The publishing convention already rules the title, so this does
    not invent a second one: subject is the title, body is state / what is lost / what to do,
    which is what the producer was told to write."""
    # A subject is one line by definition, and the validator does not enforce that: a title
    # carrying CR or LF reaches here intact and EmailMessage refuses it, which used to raise
    # out of the worker's per-row loop and strand the rest of the claimed batch. Folding the
    # whitespace is also the header-injection defence — a title is semi-trusted input.
    title = ' '.join(str(card.get('title') or '(no title)').split()) or '(no title)'
    lines = [title, '']
    source = card.get('source') or '?'
    kind = card.get('kind') or ''
    meta = '%s · %s' % (source, kind)
    if (card.get('occurrence_count') or 1) > 1:
        meta += ' · seen %d times' % card['occurrence_count']
    lines += [meta, '']
    body = str(card.get('body') or '').strip()
    if body:
        lines += [body[:MAX_BODY_CHARS], '']
        if len(body) > MAX_BODY_CHARS:
            lines[-2] += '\n… (%d characters omitted)' % (len(body) - MAX_BODY_CHARS)
    action_line = card.get('action_line')
    if action_line is not None and str(action_line).strip():
        lines += ['What to do: ' + str(action_line).strip(), '']
    if console_url:
        lines += ['Open in the console: ' + console_url, '']
    return title, '\n'.join(lines)


def build_email(config, subject, body):
    msg = EmailMessage()
    msg['From'] = config['from']
    msg['To'] = ', '.join(config['to'])
    msg['Subject'] = subject
    msg['Date'] = email.utils.formatdate()
    msg['Message-ID'] = email.utils.make_msgid()
    # A page is an alert, and a mail client that files it below today's newsletters has not
    # delivered it. These are advisory headers; the transport decision is the operator's.
    msg['X-Priority'] = '1'
    msg['Auto-Submitted'] = 'auto-generated'
    msg.set_content(body)
    return msg


def _terminal_smtp(code):
    """A 5xx is the server saying "not this message, ever" — retrying it burns the attempt
    budget and delays nothing but the failure. A 4xx is "not now"."""
    return isinstance(code, int) and 500 <= code < 600


def send(config, subject, body, timeout=CONNECT_TIMEOUT):
    """Send one message. -> (ok, code-or-error-name).

    Never returns the password, the host or an smtplib repr: the reason string lands in
    `deliveries.last_error`, which the settings screen renders.
    """
    server = None
    try:
        server = smtplib.SMTP(config['host'], config['port'], timeout=timeout)
        server.ehlo()
        if server.has_extn('starttls'):
            server.starttls(context=ssl.create_default_context())
            server.ehlo()
        if config['user'] and config['password']:
            server.login(config['user'], config['password'])
        refused = server.send_message(
            build_email(config, subject, body),
            from_addr=config['from'], to_addrs=list(config['to']))
        # Compared as a set against the configured recipients rather than by count: smtplib
        # keys `refused` by address, and counting alone was wrong the moment an address could
        # appear twice. In practice smtplib raises SMTPRecipientsRefused when it refuses
        # everybody, so this branch is the belt to that pair of braces.
        if set(refused) >= set(config['to']):
            # Every recipient rejected while the transaction still succeeded overall. Nothing
            # was delivered, so this is not a success no matter what the return code said.
            return False, 'all recipients refused'
        if refused:
            # Some were rejected and the rest were delivered. Retrying would send the message
            # again to everybody it already reached — up to the attempt cap — so this counts
            # as sent and says how many were dropped. The count rather than the addresses:
            # this string is stored and rendered, and a bounce list is not something to widen
            # the blast radius of.
            sys.stderr.write('[email] %d of %d recipients refused\n'
                             % (len(refused), len(config['to'])))
        return True, 250
    except smtplib.SMTPResponseException as e:
        return False, e.smtp_code
    except smtplib.SMTPRecipientsRefused:
        return False, 'recipients refused'
    except smtplib.SMTPAuthenticationError:
        return False, 'authentication refused'
    except Exception as e:                          # noqa: BLE001 — type only, never the config
        return False, type(e).__name__
    finally:
        if server is not None:
            try:
                server.quit()
            except Exception:                       # noqa: BLE001 — the send already decided
                pass


def _error_reason(code):
    return 'smtp %d' % code if isinstance(code, int) else str(code)


def run_worker(config, stop_event, console_url=''):
    """The email lane's outbox worker: one thread, one pass every 5 seconds.

    Deliberately the same shape as the Slack worker. The claim is already channel-scoped and
    atomic (P1), so a Slack worker never sees an email row and two workers never see the same
    one — this adds a transport, not a queue.
    """
    while not stop_event.is_set():
        try:
            batch = MSG.claim_due_deliveries(LANE, 10)
            for index, d in enumerate(batch):
                if index and stop_event.wait(1):
                    break
                # Two nested guards, and the outer one is the load-bearing half. An
                # exception escaping this row leaves it AND every row claimed after it in
                # `claimed` with no error recorded until the lease expires — neither sent nor
                # failed nor visibly stuck. The ledger writes are the realistic source: four
                # threads hold BEGIN IMMEDIATE on one SQLite file behind a 5s busy timeout,
                # so `database is locked` is a thing that happens rather than a hypothetical.
                try:
                    try:
                        subject, body = format_message(d, console_url)
                        ok, code = send(config, subject, body)
                    except Exception as e:  # noqa: BLE001 — a row we cannot even build
                        MSG.delivery_failed(d['id'], d['claimed_by'],
                                            'unsendable: ' + type(e).__name__)
                        continue
                    if ok:
                        MSG.delivery_sent(d['id'], d['card_id'], d['claimed_by'])
                    elif _terminal_smtp(code):
                        MSG.delivery_failed(d['id'], d['claimed_by'], _error_reason(code))
                    else:
                        MSG.delivery_retry(d['id'], d['claimed_by'], _error_reason(code))
                except Exception as e:      # noqa: BLE001 — the ledger itself refused
                    # Nothing more can be done for this row here; the lease expiry reclaims
                    # it. What must not happen is the rest of the batch going with it.
                    sys.stderr.write('[email] ledger write failed for delivery %s: %s\n'
                                     % (d['id'], type(e).__name__))
                    continue
        except Exception as e:                      # noqa: BLE001 — the worker must not die
            sys.stderr.write('[email] worker err: %s\n' % type(e).__name__)
        stop_event.wait(5)
