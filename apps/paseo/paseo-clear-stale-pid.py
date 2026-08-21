#!/usr/bin/env python3
"""Reap a stale Paseo singleton pidfile before the daemon starts.

Upstream (@getpaseo/cli — pinned per apps/paseo/install.sh, PASEO_VER) writes
$PASEO_HOME/paseo.pid to enforce "only one daemon" and checks it on every
`paseo daemon start`.

It is NOT true that upstream never reaps a stale record — an earlier version of
this comment claimed that and it was wrong (adversarial review, 2026-08-05, by
running 0.2.5's own clearExistingPidLock()). Upstream DOES unlink the record
when the recorded pid is dead. The case it cannot see is the one that bit us:
the pid is ALIVE, because after a reboot some unrelated process of the same uid
now holds that number. Upstream asks "is something running there?" via
kill(pid, 0), gets yes, and refuses:

    Another Paseo daemon is already running (PID 528, started ...)

With Restart=always/RestartSec=3 (apps/paseo/render.sh) that is not a one-time
failure — it is a permanent restart loop (measured on a real box: restart
counter into the double digits, the unit never comes up). This is invoked as
this unit's ExecStartPre (with a leading '-', so a problem HERE never blocks
the real ExecStart) — see apps/paseo/render.sh's render_paseo_unit.

And it really is permanent — it does NOT age out. Upstream does have a
heartbeat (the lock's mtime is refreshed every 30s, and a lock untouched for
5 minutes reads as abandoned), which looks like it should let a later start
reclaim the lock on its own. It does not: in 0.2.5's clearExistingPidLock, the
whole freshness branch sits behind canReclaimLiveLock(), which returns true
only for `reclaimStaleDesktopLock === true && lock.desktopManaged === true`. A
systemd-launched daemon's record carries no desktopManaged flag (confirmed
against the real record from the incident), so reclaimable is false and the
"already running" error is thrown unconditionally, freshness never consulted.
That is why the box sat in the loop instead of recovering after five minutes,
and it is why replacing the check below with an mtime/heartbeat test would not
have helped: upstream's own heartbeat path is unreachable here.

Ownership note for anyone tempted to "just fix the pidfile": this check, the
pidfile format, and the refusal-to-start behavior all live in @getpaseo/cli,
not in this repo (grep apps/paseo for "pid" — nothing here reads or writes
that file). This script is Airlock's own ExecStartPre-layer workaround, not a
patch to upstream. The upstream-facing report (a stale-pidfile reap, or at
least a documented recovery path, would remove the need for this) is tracked
separately (see docs/tasks — this script's existence is the reason the report
is not just "add a try/except").

Why PID-liveness alone is not enough: after a reboot, PIDs get reused by
unrelated processes. A record naming pid=528 while some live, unrelated process
now holds pid 528 is still stale — stopping at "is something running at that
pid" would call it a survivor and leave the daemon refusing to start forever,
defeating the point of this script.

But the opposite error is worse. Deleting the lock of a daemon that IS running
lets systemd start a second one on the same port, manufacturing the very restart
loop this guard exists to prevent — so every test here is one that CANNOT be
true of a live daemon, and anything merely odd resolves to "leave it alone":

  * no such process                      -> stale
  * live, but owned by a different uid   -> stale (the pid was reused)
  * live, but the record was written
    BEFORE this machine booted           -> stale (nothing survives a reboot)
  * anything else, including a hostname
    that does not match                  -> left alone, and said out loud

Staleness is judged against the BOOT rather than by comparing the process's own
/proc start time to the record. /proc start times are derived as
realtime-minus-uptime, so a forward wall-clock correction — an NTP step shortly
after boot is routine — shifts them later and would frame a live daemon as
having started after its own record. "Written before this boot" is both immune
to that and a much wider signal (hours, not seconds).

Whatever is decided is logged (No Silent Failure): a pidfile that vanished with
no log line would leave the next person debugging this with nothing but "it
started fine, I don't know why."
"""
import datetime
import json
import os
import re
import stat
import sys
import time

PROG = "paseo-pid-guard"
# How far before boot a record must fall before we call it a previous-boot
# leftover. Generous on purpose: the real signal is hours wide (a record from
# the last boot), so there is no reason to sit close to the line and risk a
# clock correction deciding a live daemon's fate.
BOOT_MARGIN_SECONDS = 120


def log(msg):
    print(f"[{PROG}] {msg}", file=sys.stderr)


def _parse_iso8601_utc(s):
    """Parse '2026-08-05T02:20:49.771Z' (or without fractional seconds) to epoch
    seconds. Hand-rolled instead of datetime.fromisoformat: that method only
    accepts a literal 'Z' suffix starting in Python 3.11, and this script must
    not silently misbehave on whatever python3 a box happens to ship."""
    m = re.match(
        r"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?Z\Z", s or ""
    )
    if not m:
        return None
    y, mo, d, h, mi, se = (int(x) for x in m.groups()[:6])
    frac = m.group(7) or "0"
    micros = int(frac.ljust(6, "0")[:6])
    try:
        dt = datetime.datetime(y, mo, d, h, mi, se, micros, tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return dt.timestamp()


def _boot_epoch():
    """Epoch seconds at which this system booted, or None if unreadable."""
    try:
        with open("/proc/uptime") as f:
            return time.time() - float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def _stale_reason(pid, hostname, uid, started_at):
    """Return a human-readable reason the record is stale, or None if it may
    describe a live daemon and must therefore be left alone.

    The bar for returning a reason is deliberately high. A wrong 'stale' here
    deletes a LIVE daemon's lock, systemd starts a second daemon on the same
    port, and the box lands in exactly the restart loop this script exists to
    prevent -- strictly worse than doing nothing. So each check below is
    something that CANNOT be true of a live daemon, and anything merely odd or
    unreadable resolves to 'leave it alone'."""
    proc_dir = f"/proc/{pid}"
    if not os.path.isdir(proc_dir):
        return f"pid {pid} is not running"

    try:
        st = os.stat(proc_dir)
    except OSError as e:
        return f"pid {pid}'s /proc entry vanished mid-check ({e})"

    if uid is not None and st.st_uid != uid:
        return (
            f"pid {pid} is alive but owned by uid {st.st_uid}, record says "
            f"uid {uid} (PID reused by a different process)"
        )

    # Hostname is REPORTED, never acted on. Renaming a host does not stop a
    # running daemon, so deleting a live daemon's lock over a rename would
    # manufacture exactly the double-start this guard exists to prevent
    # (general review, 2026-08-05).
    try:
        import socket

        cur_hostname = socket.gethostname()
    except OSError:
        cur_hostname = None
    if cur_hostname and hostname and cur_hostname != hostname:
        log(
            f"note: record hostname {hostname!r} != this host {cur_hostname!r} "
            f"-- not staleness on its own; pid {pid} is alive, leaving it to the checks below"
        )

    # Staleness is judged against the BOOT, not against the record's own age.
    #
    # The previous version compared this process's /proc start time to the
    # record's startedAt. That is not safe: /proc start times are derived as
    # realtime-minus-uptime, so ANY forward wall-clock correction -- an NTP step
    # shortly after boot is routine -- shifts the computed start later and makes
    # a perfectly live daemon look like it began after its own record was
    # written, deleting its lock (general review, 2026-08-05).
    #
    # What genuinely cannot be true of a live daemon is simpler: a record
    # written BEFORE this machine booted cannot describe a process still running
    # now, because nothing survives a reboot. That is exactly the incident this
    # guard exists for -- a record from the previous boot matched against a pid
    # some unrelated process now happens to hold. It also compares timestamps
    # that are typically hours apart, far outside anything a clock correction
    # moves, so the margin below is generous rather than load-bearing.
    boot = _boot_epoch()
    rec_start = _parse_iso8601_utc(started_at)
    if boot is not None and rec_start is not None:
        if boot - rec_start > BOOT_MARGIN_SECONDS:
            return (
                f"pid {pid} is alive, but the record was written "
                f"({started_at!r}) before this machine booted ({boot:.0f}) -- "
                f"nothing survives a reboot, so that pid now belongs to an "
                f"unrelated process"
            )

    return None


def _remove(path, reason, judged_raw):
    """Delete the pidfile, but only if it still holds the exact bytes the
    staleness judgement was made about.

    Between reading the record and acting on it, a daemon can legitimately
    start and write a FRESH record to the same path. Unlinking by path alone
    would then delete a live daemon's lock on the strength of a verdict about a
    record that no longer exists (general review, 2026-08-05). Re-reading and
    comparing closes that window: if the content changed, someone else is in
    charge of this file and we leave it alone.
    """
    try:
        with open(path, "r") as f:
            current_raw = f.read()
    except FileNotFoundError:
        return  # already gone -- fine, nothing to do
    except OSError as e:
        log(f"wanted to remove stale pidfile {path} ({reason}) but could not re-read it: {e}")
        return

    if current_raw != judged_raw:
        log(
            f"NOT removing {path}: it was rewritten while this check ran, so the "
            f"stale verdict ({reason}) is about a record that no longer exists"
        )
        return

    try:
        os.remove(path)
        log(f"removed stale pidfile {path}: {reason}")
    except FileNotFoundError:
        pass  # raced with someone else's cleanup -- the desired end state anyway
    except OSError as e:
        log(f"wanted to remove stale pidfile {path} ({reason}) but could not: {e}")


def main(argv):
    if len(argv) != 2:
        log(f"usage: {argv[0] if argv else PROG} <pidfile> -- doing nothing")
        return 0

    path = argv[1]

    # Only ever open a REGULAR file. `ExecStartPre=-` neutralises a non-zero exit
    # and a signal death, but not a HANG: opening a FIFO here blocks forever, the
    # unit hits DefaultTimeoutStartSec (~90s), start fails, and Restart=always
    # turns that into a ~93s loop -- this guard becoming the outage
    # (adversarial review, 2026-08-05).
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return 0  # normal state: no pidfile, nothing to reap
    except OSError as e:
        log(f"cannot stat {path}: {e} -- leaving it for the daemon to sort out")
        return 0
    if not stat.S_ISREG(st.st_mode):
        log(f"{path} is not a regular file -- refusing to read it, leaving it for the daemon")
        return 0

    try:
        with open(path, "r") as f:
            raw = f.read()
    except FileNotFoundError:
        return 0  # raced with someone else's cleanup -- nothing to reap
    except OSError as e:
        log(f"cannot read {path}: {e} -- leaving it for the daemon to sort out")
        return 0

    try:
        rec = json.loads(raw)
        pid = int(rec["pid"])
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as e:
        _remove(path, f"unparseable record ({e}) -- would wedge every future boot", raw)
        return 0

    hostname = rec.get("hostname")
    started_at = rec.get("startedAt")
    uid_raw = rec.get("uid")
    try:
        uid = int(uid_raw) if uid_raw is not None else None
    except (TypeError, ValueError):
        uid = None

    reason = _stale_reason(pid, hostname, uid, started_at)
    if reason:
        _remove(path, reason, raw)
    else:
        log(
            f"{path}: pid {pid} is running, owned by the recorded uid, and the "
            f"record was written during this boot -- treating it as a live "
            f"daemon and leaving it alone"
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001 - never block the real ExecStart on our own bug
        log(f"unexpected error, leaving the pidfile alone: {e}")
        sys.exit(0)
