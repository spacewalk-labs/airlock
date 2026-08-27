#!/usr/bin/env python3
"""token-freshness — the periodic half: check the provider credentials, then say so.

Run by airlock-token-freshness.service (see systemd/ and install-token-timer.sh). One
run does two things, in this order:

  1. Write the snapshot. Always, whatever the verdict — the dashboard card reads it, and
     its age is the only way a checker that stopped running is visible as staleness
     rather than as silence. This must happen even when step 2 cannot.
  2. Publish a card to the dev-monitor spool for anything that is not ok. That console
     already exists, already reaches the operator, and already coalesces one card per
     group_key per day — which is exactly the cadence a daily expiry warning wants.

Step 2 is best effort and never fails the run on its own; step 1 is the run's job.

    python3 token-freshness.py [--warn-hours N] [--stale-hours N] [--spool DIR]
                               [--snapshot PATH] [--no-spool] [--quiet]

Exit status is about the CHECK MACHINERY, not the verdict: 0 when the check ran and the
snapshot was written, 1 when it could not. An expired token is a card, not a crash —
systemd's OnFailure= is reserved for the watchdog itself dying, which is the failure
nobody would otherwise see.

What it never does: read, print or publish a token value. It only ever handles the
verdicts devmon_tokens produces, which carry timestamps and field names.
"""
import argparse
import os
import sys
import uuid
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'backend'))
import devmon_tokens as T          # noqa: E402
import devmon_accounts as ACCOUNTS  # noqa: E402


def _publisher():
    """Import the spool producer, LAZILY — step 1 must not depend on step 2.

    The publish contract (write to tmp/, link(2) into new/) is written down in exactly
    one place, so this imports the example rather than re-typing its twenty lines. But
    importing it at module scope would mean an absent or broken examples/ directory kills
    the run before the snapshot is written — which is precisely the ordering guarantee
    this file claims to keep.
    """
    sys.path.insert(0, os.path.join(HERE, 'examples'))
    import emit_message
    return emit_message

SOURCE = 'token-freshness'
# Cards worth waking someone for. `unknown` is handled separately below: a MISSING
# credentials file most often means the provider was never set up on this box, and a
# daily card about it would train the reader to ignore the channel. It still never
# renders as ok — the dashboard card shows unknown as its own state.
CARD_STATUSES = (T.EXPIRED, T.EXPIRING)


def wants_card(verdict):
    if verdict['status'] in CARD_STATUSES:
        return True
    # A file that exists but cannot be read is an anomaly, not an absence.
    return verdict['status'] == T.UNKNOWN and verdict.get('reason') != 'missing'


def card_for(verdict, now):
    """Build the spool payload. Every field here is derived from the verdict."""
    provider = verdict['provider']
    urgency = 'urgent' if verdict['status'] == T.EXPIRED else 'normal'
    title = '%s credentials: %s — %s' % (provider, verdict['status'], verdict['detail'])
    body = 'Checked %s. Source: %s' % (verdict.get('checked_at') or T.iso(now),
                                       verdict.get('path') or '(unknown path)')
    return {
        'schema_version': 1,
        # A fresh event_id per run: the collector coalesces by group_key, so repeated
        # runs update one card instead of creating one per day per provider.
        'event_id': '%s-%s-%s' % (SOURCE, now.strftime('%Y%m%dT%H%M%SZ'),
                                  uuid.uuid4().hex[:6]),
        'group_key': '%s:%s' % (SOURCE, provider),
        'source': SOURCE,
        'kind': 'info',
        'urgency': urgency,
        'title': title,
        'body': body,
        'created_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'outcome': verdict['detail'],
        'why_it_matters': (
            'Nothing else on this box reads a credential expiry. Left alone, the first '
            'sign of this is an agent run that fails.'),
        'followup': 'Re-authenticate this provider before the deadline.',
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--warn-hours', type=int, default=T.DEFAULT_WARN_HOURS,
                    help='claude: warn when the refresh deadline is this close')
    ap.add_argument('--stale-hours', type=int, default=T.DEFAULT_STALE_HOURS,
                    help='codex: warn when last_refresh is this old')
    ap.add_argument('--spool', default=os.environ.get('DEV_MONITOR_SPOOL'),
                    help='dev-monitor spool directory (default: $DEV_MONITOR_SPOOL)')
    ap.add_argument('--snapshot', default=None,
                    help='where to write the verdict (default: the state directory)')
    ap.add_argument('--no-spool', action='store_true',
                    help='snapshot only — the dashboard card still works, nothing is published')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args(argv)
    if a.warn_hours < 1 or a.stale_hours < 1:
        ap.error('--warn-hours and --stale-hours must be at least 1')

    now = datetime.now(timezone.utc)
    raw, source_error = ACCOUNTS.raw_deadlines()
    snap = T.check_all(raw, now=now, warn_hours=a.warn_hours, stale_hours=a.stale_hours)
    snap['source_error'] = source_error
    snapshot = a.snapshot or T.snapshot_path()

    # --- 1. the snapshot, which is the run's actual job ---
    try:
        T.write_snapshot(snapshot, snap)
    except OSError as e:
        # Loud and non-zero: a watchdog that cannot record its own verdict has failed,
        # and this is the case OnFailure= exists for.
        sys.stderr.write('token-freshness: could not write %s: %s\n' % (snapshot, e))
        return 1
    if not a.quiet:
        for v in snap['providers']:
            print('%-8s %-14s %s' % (v['provider'], v['status'], v['detail']))
        print('snapshot: %s' % snapshot)

    # A valid platform payload may honestly say both providers are missing; that is a
    # successful check whose verdict is unknown. Failure to obtain the payload is the
    # watchdog itself failing. Preserve the unknown snapshot above, then fail loudly so
    # OnFailure= remains truthful rather than turning a broken ABI into a green timer.
    if source_error:
        sys.stderr.write('token-freshness: platform account metadata unavailable (%s)\n'
                         % source_error)
        return 1

    # --- 2. tell the operator, through the console that already exists ---
    if a.no_spool:
        return 0
    noisy = [v for v in snap['providers'] if wants_card(v)]
    if not noisy:
        return 0
    if not a.spool:
        # Not silent, and not fatal: the snapshot above is written and the dashboard
        # card will show the same verdict. Only the push half is unavailable.
        sys.stderr.write('token-freshness: %d provider(s) need attention but no spool is '
                         'configured — the dashboard card has the verdict, the message '
                         'console will not.\n' % len(noisy))
        return 0
    try:
        emit_message = _publisher()
    except ImportError as e:
        sys.stderr.write('token-freshness: the spool producer is unavailable (%s) — the '
                         'snapshot is written and the dashboard card has the verdict.\n' % e)
        return 0
    for v in noisy:
        v = dict(v, checked_at=snap['checked_at'])
        try:
            result = emit_message.emit(a.spool, card_for(v, now))
        except SystemExit as e:
            # emit() refuses a spool that is not there. Stop rather than repeat the same
            # refusal once per provider — but say so, and only once.
            sys.stderr.write('token-freshness: %s\n' % e)
            break
        except OSError as e:
            sys.stderr.write('token-freshness: could not publish %s: %s\n'
                             % (v['provider'], e))
            continue
        if not a.quiet:
            print('%s: %s card %s' % (v['provider'], v['status'], result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
