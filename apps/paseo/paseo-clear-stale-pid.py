#!/usr/bin/env python3
"""Remove a dead Paseo pidfile only after the installer completes handover.

The candidate unit must never call this from ExecStartPre: PASEO_HOME and
paseo.pid may still belong to a live legacy daemon. ``install.sh`` first proves
the record, application command marker, process environment, containing systemd
service environment, and PID release. This final guard then removes only a
regular, parseable record whose PID no longer exists.

Any live PID is left untouched, even if its uid, hostname, or timestamp looks
stale. PID reuse makes those cases ambiguous; deleting a live daemon's shared
state is worse than a clear, non-destructive install failure. The resource probe
fails those ambiguous live cases before this script can run.
"""
import json
import os
import stat
import sys

PROG = "paseo-pid-guard"
SAFE_OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


def log(msg):
    print(f"[{PROG}] {msg}", file=sys.stderr)


def _stale_reason(pid):
    """Return a reason only when no process currently owns this PID."""
    return None if os.path.isdir(f"/proc/{pid}") else f"pid {pid} is not running"


def _remove(path, reason, judged_raw, pid, judged_identity):
    """Delete the pidfile, but only if it still holds the exact bytes the
    staleness judgement was made about.

    Between reading the record and acting on it, a daemon can legitimately
    start and write a FRESH record to the same path. Unlinking by path alone
    would then delete a live daemon's lock on the strength of a verdict about a
    record that no longer exists (general review, 2026-08-05). Re-reading and
    comparing closes that window: if the content changed, someone else is in
    charge of this file and we leave it alone.
    """
    if os.path.isdir(f"/proc/{pid}"):
        log(f"NOT removing {path}: pid {pid} appeared after the dead-PID check")
        return
    try:
        fd = os.open(path, SAFE_OPEN_FLAGS)
        with os.fdopen(fd, "r") as current:
            current_stat = os.fstat(current.fileno())
            current_raw = current.read()
    except FileNotFoundError:
        return  # already gone -- fine, nothing to do
    except OSError as e:
        log(f"wanted to remove stale pidfile {path} ({reason}) but could not re-read it: {e}")
        return

    current_identity = (current_stat.st_dev, current_stat.st_ino)
    if current_identity != judged_identity or current_raw != judged_raw:
        log(
            f"NOT removing {path}: it was replaced or rewritten while this check ran, so the "
            f"stale verdict ({reason}) is about a record that no longer exists"
        )
        return

    try:
        final_stat = os.lstat(path)
        if (final_stat.st_dev, final_stat.st_ino) != judged_identity \
           or not stat.S_ISREG(final_stat.st_mode) \
           or os.path.isdir(f"/proc/{pid}"):
            log(f"NOT removing {path}: inode or PID ownership changed before unlink")
            return
        os.remove(path)
        log(f"removed stale pidfile {path}: {reason}")
    except FileNotFoundError:
        pass  # raced with someone else's cleanup -- the desired end state anyway
    except OSError as e:
        log(f"wanted to remove stale pidfile {path} ({reason}) but could not: {e}")


def main(argv):
    if len(argv) != 3 or argv[1] != "--after-handover":
        log(
            f"usage: {argv[0] if argv else PROG} --after-handover <pidfile> "
            "-- doing nothing"
        )
        return 0

    path = argv[2]

    # Open one no-follow file descriptor and bind all parsing/removal evidence
    # to its dev+inode. A path swap cannot turn a dead-record verdict into an
    # unlink of somebody else's live state.
    try:
        fd = os.open(path, SAFE_OPEN_FLAGS)
    except FileNotFoundError:
        return 0  # normal state: no pidfile, nothing to reap
    except OSError as e:
        log(f"cannot stat {path}: {e} -- leaving it for the daemon to sort out")
        return 1
    try:
        with os.fdopen(fd, "r") as source:
            st = os.fstat(source.fileno())
            if not stat.S_ISREG(st.st_mode):
                log(f"{path} is not a regular file -- refusing to read it, leaving it for the daemon")
                return 1
            raw = source.read()
    except FileNotFoundError:
        return 0  # raced with someone else's cleanup -- nothing to reap
    except OSError as e:
        log(f"cannot read {path}: {e} -- leaving it for the daemon to sort out")
        return 1

    try:
        rec = json.loads(raw)
        pid = int(rec["pid"])
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as e:
        # This may be a live legacy daemon between truncate and rewrite. There
        # is no PID to prove ownership or release, so fail closed instead of
        # deleting unknown shared state.
        log(f"NOT removing {path}: unparseable record ({e}); ownership is unknown")
        return 1

    reason = _stale_reason(pid)
    if reason:
        _remove(path, reason, raw, pid, (st.st_dev, st.st_ino))
        return 0 if not os.path.lexists(path) else 1
    else:
        log(
            f"{path}: pid {pid} exists -- ownership is live or ambiguous; "
            f"leaving shared state untouched"
        )
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001 - fail closed before candidate start
        log(f"unexpected error, leaving the pidfile alone: {e}")
        sys.exit(1)
