#!/usr/bin/env python3
"""devmon_spool — a Maildir-style atomic drop spool.

Layout: $SPOOL/{tmp,new,processing,bad}

A producer publishes by writing to tmp/ with O_EXCL and then link()ing it to
new/<event_id>.json — the appearance of a name in new/ is therefore atomic, and a
half-written file can never be picked up.

The collector is ONE watcher thread. It takes ownership by rename(new -> processing),
which is what makes concurrent collectors and restarts safe: whoever wins the rename owns
the file, and everyone else sees FileNotFoundError. Then it reads defensively (O_NOFOLLOW,
fstat regular, bounded read), requires the filename to equal the payload's event_id,
validates, and ingests. Anything that fails is quarantined in bad/ and recorded in
ingest_errors — never dropped silently.

The reader assumes nothing about the producer. In the default single-box install the producer
is the same user, but the spool is also the one place an outside process can hand this service
input, so it is read as if it were hostile: symlink, FIFO, device and directory are refused, a
payload over MAX_PAYLOAD (16KB) is refused, a filename that disagrees with the payload is
refused, and nothing ever clobbers existing evidence.
"""
import json
import os
import stat
import threading
import time

import devmon_messages as M

SUBDIRS = ('tmp', 'new', 'processing', 'bad')
POLL_INTERVAL = 2.0


def ensure_dirs(spool):
    """Create the spool, 0700 by default.

    Pending payloads carry the prompt and argv of action cards that have not been approved
    yet, so the directory mode is the thing protecting them. makedirs honours the umask and
    exist_ok keeps an existing mode, so both are set explicitly — otherwise clearing the
    state directory and restarting silently left the whole spool at 0755.

    With messages enabled the installer must already have established the exact cross-UID
    modes; startup validates and preserves them rather than silently repairing an incomplete
    boundary. processing/ and bad/ always remain collector-only.
    """
    hardened = os.environ.get('AIRLOCK_DEV_MONITOR_MESSAGES') == 'true'
    if hardened:
        expected = {'': 0o710, 'tmp': 0o3770, 'new': 0o3770,
                    'processing': 0o700, 'bad': 0o700}
        for name, mode in expected.items():
            path = os.path.join(spool, name) if name else spool
            if os.path.islink(path) or not os.path.isdir(path):
                raise RuntimeError('hardened spool directory is missing: %s' % (name or '.'))
            if stat.S_IMODE(os.stat(path).st_mode) != mode:
                raise RuntimeError('hardened spool mode mismatch: %s' % (name or '.'))
        return

    os.makedirs(spool, mode=0o700, exist_ok=True)
    try:
        os.chmod(spool, 0o700)
    except OSError:
        pass
    for d in SUBDIRS:
        path = os.path.join(spool, d)
        os.makedirs(path, mode=0o700, exist_ok=True)
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass


def _bad_name(spool, base):
    """A unique bad/ name, so a second failure never overwrites the first one's evidence."""
    stamp = M.now_utc().strftime('%Y%m%dT%H%M%S%fZ')
    return os.path.join(spool, 'bad', '%s.%s' % (base, stamp))


def _read_regular_bounded(path):
    """Open with O_NOFOLLOW, confirm it is a regular file, read a bounded amount.

    A symlink raises OSError(ELOOP); FIFO, device and directory are refused after the fact
    by fstat. O_NONBLOCK matters: opening a FIFO with no writer would otherwise block the
    watcher thread forever — we open it, then reject it.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError('not a regular file')
        if st.st_size > M.MAX_PAYLOAD:
            raise ValueError('oversize (%d bytes)' % st.st_size)
        data = os.read(fd, M.MAX_PAYLOAD + 1)
        if len(data) > M.MAX_PAYLOAD:
            raise ValueError('oversize (stream)')
        return data
    finally:
        os.close(fd)


def process_one(spool, filename):
    """Process one new/<filename>. -> 'inserted'|'coalesced'|'duplicate'|'bad'."""
    new_path = os.path.join(spool, 'new', filename)
    proc_path = os.path.join(spool, 'processing', filename)
    # 1) Take ownership with an atomic rename. Already gone = someone else has it.
    try:
        os.rename(new_path, proc_path)
    except FileNotFoundError:
        return 'duplicate'
    except OSError as e:
        M.record_ingest_error(filename, 'rename failed: %s' % e)
        return 'bad'
    # 2) Read defensively, validate, ingest.
    try:
        raw = _read_regular_bounded(proc_path)
        payload = json.loads(raw.decode('utf-8'))
        # The filename must equal the payload's event_id: otherwise a producer could
        # publish one id under another's name and defeat the dedup below.
        expect = None
        if isinstance(payload, dict) and isinstance(payload.get('event_id'), str):
            expect = payload['event_id'] + '.json'
        if expect != filename:
            raise ValueError('filename != payload event_id')
        status = M.ingest(payload)             # may raise (validation included)
    except Exception as e:  # noqa: BLE001 — any failure quarantines; nothing is silent
        raw_head = ''
        try:
            raw_head = raw.decode('utf-8', 'replace')
        except Exception:
            pass
        M.record_ingest_error(filename, '%s: %s' % (type(e).__name__, e), raw_head)
        try:
            os.rename(proc_path, _bad_name(spool, filename))
        except OSError:
            pass
        return 'bad'
    # 3) Success: drop the processing file. A crash between the commit and this unlink is
    #    harmless — the occurrence UNIQUE constraint makes a re-ingest a duplicate.
    try:
        os.remove(proc_path)
    except OSError:
        pass
    return status


def scan_once(spool, batch_max=500):
    """Scan new/ once, after recovering anything left in processing/. -> counts dict."""
    result = {'inserted': 0, 'coalesced': 0, 'duplicate': 0, 'bad': 0, 'dropped': 0}
    # Recovery: a file left in processing/ means we died mid-flight, so put it back.
    proc_dir = os.path.join(spool, 'processing')
    try:
        leftovers = os.listdir(proc_dir)
    except OSError:
        leftovers = []
    for f in leftovers:
        try:
            os.rename(os.path.join(proc_dir, f), os.path.join(spool, 'new', f))
        except OSError:
            pass
    new_dir = os.path.join(spool, 'new')
    try:
        files = sorted(os.listdir(new_dir))
    except OSError:
        return result
    if len(files) > batch_max:
        result['dropped'] = len(files) - batch_max      # backpressure, reported as a count
        files = files[:batch_max]
    for f in files:
        if not f.endswith('.json'):
            continue
        status = process_one(spool, f)
        result[status] = result.get(status, 0) + 1
    return result


def run_watcher(spool, stop_event):
    """The watcher thread: scan once at startup, then every POLL_INTERVAL."""
    ensure_dirs(spool)
    while not stop_event.is_set():
        try:
            r = scan_once(spool)
            if r.get('dropped'):
                M.record_ingest_error('(batch)', 'backpressure dropped %d' % r['dropped'])
        except Exception as e:  # noqa: BLE001 — the watcher must not die; retry next tick
            try:
                M.record_ingest_error('(watcher)', 'scan error: %s' % e)
            except Exception:
                pass
        stop_event.wait(POLL_INTERVAL)
