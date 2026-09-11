#!/usr/bin/env python3
"""Atomic producer spool; accepted receipts stay in processing/ for offline rollback.

The collector snapshots bytes into its own inode before committing them. Producers
cannot alter that retained receipt through an already open descriptor. Old collectors
replay processing/ after restoring the database backup. Receipt files expire with ledger.
"""
import json
import os
import stat
import sqlite3
import sys
import tempfile

import devmon_messages as M

SUBDIRS = ('tmp', 'new', 'processing', 'bad')


def ensure_dirs(spool):
    """Create the spool, 0700 by default.

    Pending payloads carry agent prompts, so the directory mode protects them. makedirs honours the umask and
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


def _quarantine(path, spool, filename, error):
    bad = _bad_name(spool, filename)
    try:
        os.rename(path, bad)
        fd = os.open(bad+'.reason', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as handle:
            handle.write(type(error).__name__ + ': ' + str(error) + '\n')
    except OSError:
        sys.stderr.write('[messages] quarantine failed; file retained for retry\n')
    return 'bad'


def process_one(spool, filename):
    new = os.path.join(spool, 'new', filename)
    processing = os.path.join(spool, 'processing')
    retained = None
    committed = False
    try:
        raw = _read_regular_bounded(new)
        payload = json.loads(raw.decode('utf-8'))
        normalized = M.validate_payload(payload)
        if normalized['id']+'.json' != filename:
            raise ValueError('filename != payload id')
        if M.has_receipt(normalized['id']):
            os.unlink(new)
            return 'duplicate'
        # Replace the producer inode with a private, durable snapshot BEFORE DB commit.
        fd, snapshot = tempfile.mkstemp(prefix='.snapshot.', dir=processing)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(raw)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(snapshot, os.path.join(processing, filename))
            retained = os.path.join(processing, filename)
            directory = os.open(processing,os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(snapshot):
                os.unlink(snapshot)
        status = M.ingest(payload)
        committed = True
        os.unlink(new)
        return status
    except sqlite3.Error:
        # A busy/full database is not a rejected message; retry its retained file.
        return 'deferred'
    except (ValueError, UnicodeError, OSError) as error:
        if retained is not None and not committed and isinstance(error, ValueError):
            # Permanent input failure: its private snapshot must not replay forever.
            # SQLite errors retain it above; a committed receipt is never removed here.
            os.unlink(retained)
        return _quarantine(new, spool, filename, error)


def scan_once(spool, batch_max=500):
    result = dict.fromkeys(('inserted','coalesced','duplicate','bad','dropped','deferred'),0)
    processing = os.path.join(spool, 'processing')
    for name in os.listdir(processing):
        filename = name
        if not filename.endswith('.json') or name.startswith('.snapshot.'):
            continue
        if M.has_receipt(filename[:-5]):
            continue
        # Never overwrite a concurrent producer publication; both will be validated.
        source = os.path.join(processing,name)
        destination = os.path.join(spool,'new',filename)
        try:
            os.link(source,destination,follow_symlinks=False)
            os.unlink(source)
        except FileExistsError:
            continue
    files = sorted(f for f in os.listdir(os.path.join(spool,'new')) if f.endswith('.json'))
    result['dropped'] = max(0,len(files)-batch_max)  # Deferred by backpressure, never deleted.
    for filename in files[:batch_max]:
        status = process_one(spool,filename)
        result[status] += 1
    return result


def purge_receipts(spool):
    # Files first, then ledger deletion: a crash cannot resurrect expired receipts.
    cutoff = M.iso(M.now_utc()-M.RETENTION)
    ids = M._conn().execute('SELECT id FROM ledger WHERE received_at<=?', (cutoff,))
    for row in ids:
        try:
            os.unlink(os.path.join(spool,'processing',row[0]+'.json'))
        except FileNotFoundError:
            pass
