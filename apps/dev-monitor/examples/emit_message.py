#!/usr/bin/env python3
"""emit_message — an example producer: publish one card to the dev-monitor spool, atomically.

Copy this. It is the whole contract, and the contract is deliberately tiny: write the file
fully (and fsync it) into tmp/, then link(2) it to new/<event_id>.json, then unlink the tmp
name. Because the file only becomes visible under its final name once it is complete, the
watcher can never pick up a half-written payload. A link that fails with EEXIST means this
event_id was already published — that is ordinary dedup, not an error.

Usage (the spool path the installer creates):
  python3 emit_message.py --spool ~/.local/state/airlock/dev-monitor/spool \
      --source disk --group-key disk:cleanup --kind action --urgency urgent \
      --title "Disk is at 92% — clean up?" \
      --cwd /path/to/your/project --prompt "Clean up old logs" --explain "Frees disk space"

Or set DEV_MONITOR_SPOOL instead of passing --spool.

"queued" means the spool accepted the file, NOT that it became a card: the watcher still has
to validate it. A rejected payload lands in spool/bad/ with the reason recorded. See
apps/dev-monitor/README.md.
"""
import argparse
import errno
import json
import os
import sys
import tempfile
import uuid
from datetime import datetime, timezone


def emit(spool, payload):
    """Atomically publish. Returns: 'queued' (spool publish succeeded — **not collector acceptance**) | 'duplicate'."""
    event_id = payload['event_id']
    new_dir = os.path.join(spool, 'new')
    tmp_dir = os.path.join(spool, 'tmp')
    # Do not create the spool — if it is absent, this box has no message channel (observation-only) or the path is wrong.
    # Creating it would leave files accumulating in a directory with no collector, print "publish succeeded", and lose them permanently (a trap on another box).
    if not (os.path.isdir(new_dir) and os.path.isdir(tmp_dir)):
        raise SystemExit('Spool missing: %s — new/ and tmp/ are absent. This spool is host-specific; do not create it automatically.' % spool)
    blob = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    fd, tmp_path = tempfile.mkstemp(dir=tmp_dir)
    try:
        os.write(fd, blob)
        # mkstemp creates 0600. Relax to 0644 so a spool deliberately shared with another
        # UID also works; in the default single-user spool the 0700 directory is what gates
        # access, and the file mode changes nothing.
        os.fchmod(fd, 0o644)
        os.fsync(fd)
    finally:
        os.close(fd)
    target = os.path.join(new_dir, event_id + '.json')
    try:
        os.link(tmp_path, target)          # atomic publish (no-clobber)
        return 'queued'                    # landed in spool — collector acceptance/card creation requires separate confirmation
    except OSError as e:
        if e.errno == errno.EEXIST:
            return 'duplicate'             # same event_id already published = normal
        raise
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spool', default=os.environ.get('DEV_MONITOR_SPOOL'))
    ap.add_argument('--source', required=True)
    ap.add_argument('--group-key', required=True)
    ap.add_argument('--kind', choices=('action', 'info', 'link'), default='info')
    ap.add_argument('--urgency', choices=('urgent', 'normal'), default='normal')
    ap.add_argument('--title', required=True)
    ap.add_argument('--body', default='')
    ap.add_argument('--event-id', default=None)
    # action
    ap.add_argument('--cwd')
    ap.add_argument('--skill')
    ap.add_argument('--prompt')
    ap.add_argument('--exec', nargs='+', dest='exec_argv',
                    help='action: invoke the executable directly (first argument=absolute executable path, rest=arguments). Does not go through Claude')
    ap.add_argument('--explain')
    # link
    ap.add_argument('--url', help='link kind: http(s) URL (opens a new tab when clicked)')
    ap.add_argument('--label', help='link kind: display label (defaults to title)')
    # info
    ap.add_argument('--outcome', default='')
    ap.add_argument('--why', default='')
    ap.add_argument('--followup', default='none')
    a = ap.parse_args()
    if not a.spool:
        sys.exit('DEV_MONITOR_SPOOL is not set (or use --spool)')

    now = datetime.now(timezone.utc)
    event_id = a.event_id or ('%s-%s-%s' % (
        a.source, now.strftime('%Y-%m-%dT%H:%M:%SZ'), uuid.uuid4().hex[:4]))
    payload = {
        'schema_version': 1, 'event_id': event_id, 'group_key': a.group_key,
        'source': a.source, 'kind': a.kind, 'urgency': a.urgency,
        'title': a.title, 'body': a.body,
        'created_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    if a.kind == 'action':
        # Checked here rather than left to the watcher: without it the script prints
        # 'queued' and the payload is quarantined in bad/ where nobody looks.
        if not a.cwd or not a.explain:
            sys.exit('action kind requires --cwd and --explain')
        if not (a.exec_argv or a.skill or a.prompt):
            sys.exit('action kind requires exactly one of --exec, --skill or --prompt')
        ra = {'cwd': a.cwd, 'explain': a.explain}
        if a.exec_argv:
            ra['exec'] = a.exec_argv
        elif a.skill:
            ra['skill'] = a.skill
        elif a.prompt:
            ra['prompt'] = a.prompt
        payload['recommended_action'] = ra
    elif a.kind == 'link':
        if not a.url:
            sys.exit('link kind requires --url')
        ln = {'url': a.url}
        if a.label:
            ln['label'] = a.label
        payload['link'] = ln
    else:
        payload.update(outcome=a.outcome or a.title,
                       why_it_matters=a.why or a.body or a.title,
                       followup=a.followup)
    result = emit(a.spool, payload)
    print('%s: %s' % (result, event_id))
    if result == 'queued':
        sys.stderr.write('  ↳ Written to the spool, which is not the same as accepted: the watcher '
                         'validates it next. Check the console (or spool/bad/) to confirm it became a card.\n')


if __name__ == '__main__':
    main()
