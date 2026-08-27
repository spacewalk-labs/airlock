#!/usr/bin/env python3
"""Print same-user PIDs that hold an Airlock singleton resource.

This is deliberately a read-only /proc probe.  The shell caller owns the policy
decision: map each PID back to its actual systemd --user unit, then stop only
that measured unit.
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import socket
import stat as stat_module
import sys


def fail(message: str) -> "NoReturn":
    print(f"resource-holder-pids: {message}", file=sys.stderr)
    raise SystemExit(2)


def same_user_processes() -> list[pathlib.Path]:
    processes: list[pathlib.Path] = []
    uid = os.geteuid()
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if proc.stat().st_uid == uid:
                processes.append(proc)
        except FileNotFoundError:
            continue
    return processes


def file_lock_holders(path: str) -> set[int]:
    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return set()
    except OSError as exc:
        fail(f"cannot stat {path!r}: {exc}")

    wanted = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    holders: set[int] = set()
    try:
        lines = pathlib.Path("/proc/locks").read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail(f"cannot read /proc/locks: {exc}")

    for line in lines:
        fields = line.split()
        if len(fields) < 6 or fields[1] not in {"FLOCK", "POSIX", "OFDLCK"}:
            continue
        # Blocked lock requests have an extra "->" field; they do not own the
        # resource and must not make us stop their unit.
        if fields[1] == "->" or "->" in fields[:3]:
            continue
        try:
            pid = int(fields[4])
            major_hex, minor_hex, inode_dec = fields[5].split(":", 2)
            identity = (int(major_hex, 16), int(minor_hex, 16), int(inode_dec))
        except (ValueError, IndexError):
            continue
        if identity == wanted:
            if pid <= 0:
                fail(f"matching lock on {path!r} has no process PID")
            holders.add(pid)
    return holders


def unix_socket_inodes(path: str) -> set[str]:
    wanted = {path, "@" + path}
    inodes: set[str] = set()
    try:
        lines = pathlib.Path("/proc/net/unix").read_text(encoding="utf-8").splitlines()[1:]
    except OSError as exc:
        fail(f"cannot read /proc/net/unix: {exc}")
    for line in lines:
        fields = line.split()
        if len(fields) >= 8 and fields[7] in wanted:
            inodes.add(fields[6])
    return inodes


def socket_holders(path: str) -> set[int]:
    inodes = unix_socket_inodes(path)
    if not inodes:
        return set()
    wanted = {f"socket:[{inode}]" for inode in inodes}
    matched: set[str] = set()
    holders: set[int] = set()
    for proc in same_user_processes():
        try:
            fds = list((proc / "fd").iterdir())
        except FileNotFoundError:
            continue
        except PermissionError:
            # Some same-uid non-dumpable processes hide fd/.  Do not confuse an
            # unrelated hidden process with the socket owner; the inode-level
            # completeness check below still fails closed if the target socket
            # itself could not be mapped.
            continue
        for fd in fds:
            try:
                target = os.readlink(fd)
            except (FileNotFoundError, PermissionError):
                continue
            if target in wanted:
                holders.add(int(proc.name))
                matched.add(target.removeprefix("socket:[").removesuffix("]"))
    missing = inodes - matched
    if missing:
        fail(f"cannot map target socket inode(s) to a same-user PID: {', '.join(sorted(missing))}")
    return holders


def _parse_record_time(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.timestamp()


def _process_start_epoch(pid: int) -> float:
    stat_text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    close_paren = stat_text.rfind(")")
    if close_paren < 0:
        fail(f"cannot parse /proc/{pid}/stat")
    fields = stat_text[close_paren + 2 :].split()
    try:
        start_ticks = int(fields[19])  # proc(5) field 22; fields starts at field 3
        ticks_per_second = os.sysconf("SC_CLK_TCK")
        with open("/proc/stat", encoding="ascii") as proc_stat:
            boot_epoch = next(int(line.split()[1]) for line in proc_stat if line.startswith("btime "))
    except (IndexError, OSError, StopIteration, ValueError) as exc:
        fail(f"cannot determine start time for pidfile PID {pid}: {exc}")
    return boot_epoch + start_ticks / ticks_per_second


def pidfile_holders(path: str, expected_environment: str) -> set[int]:
    """Return a PID only after proving the record identifies the expected daemon.

    A PID number plus inherited environment is insufficient: any child in a
    broad service could satisfy those two facts. The record must also agree
    with the current process's uid, hostname and start time. The shell caller
    separately proves the containing service's exact declared ExecStart and
    the PID's ancestry. Any live but unproven PID fails closed so cleanup
    cannot touch its file.
    """
    safe_open_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(path, safe_open_flags)
    except FileNotFoundError:
        return set()
    except OSError as exc:
        fail(f"cannot safely open pidfile {path!r}: {exc}")
    try:
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            metadata = os.fstat(source.fileno())
            if not stat_module.S_ISREG(metadata.st_mode):
                return set()
            if metadata.st_size > 1024 * 1024:
                fail(f"pidfile {path!r} is unexpectedly large")
            record = json.load(source)
        pid = int(record["pid"])
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return set()
    if pid <= 0:
        return set()

    proc = pathlib.Path("/proc") / str(pid)
    try:
        process_uid = proc.stat().st_uid
        environment = (proc / "environ").read_bytes().split(b"\0")
    except FileNotFoundError:
        return set()
    except PermissionError as exc:
        fail(f"cannot inspect live pidfile PID {pid}: {exc}")

    if process_uid != os.geteuid():
        fail(f"live pidfile PID {pid} belongs to uid {process_uid}, not this user")
    try:
        record_uid = int(record["uid"])
    except (KeyError, TypeError, ValueError):
        fail(f"live pidfile PID {pid} has no valid uid proof")
    if record_uid != process_uid:
        fail(f"live pidfile PID {pid} uid does not match its record")
    if record.get("hostname") != socket.gethostname():
        fail(f"live pidfile PID {pid} hostname does not match this host")

    record_start = _parse_record_time(record.get("startedAt"))
    if record_start is None:
        fail(f"live pidfile PID {pid} has no valid startedAt proof")
    try:
        process_start = _process_start_epoch(pid)
    except FileNotFoundError:
        return set()
    # Paseo writes the record as the supervisor starts. A generous ten-second
    # window tolerates scheduler and timestamp precision, while an old record
    # whose PID was reused fails closed instead of authorizing a service stop.
    if abs(record_start - process_start) > 10:
        fail(f"live pidfile PID {pid} start time does not match its record")

    expected = expected_environment.encode()
    if expected not in environment:
        fail(f"live pidfile PID {pid} does not carry {expected_environment}")
    return {pid}


def is_descendant(pid: int, ancestor: int) -> bool:
    """Return whether PID is a strict live descendant of ANCESTOR."""
    seen: set[int] = set()
    current = pid
    while current > 1 and current not in seen:
        seen.add(current)
        try:
            status = pathlib.Path(f"/proc/{current}/status").read_text(encoding="utf-8")
        except FileNotFoundError:
            return False
        parent_line = next((line for line in status.splitlines() if line.startswith("PPid:")), "")
        try:
            current = int(parent_line.split()[1])
        except (IndexError, ValueError):
            return False
        if current == ancestor:
            return True
    return False


def main() -> None:
    if len(sys.argv) not in {3, 4}:
        fail(
            "usage: resource-holder-pids.py file-lock PATH | unix-socket PATH | "
            "x-display NUMBER | pidfile PATH ENV=VALUE | process-descendant PID ANCESTOR"
        )
    if sys.argv[1] == "process-descendant":
        try:
            pid, ancestor = (int(value) for value in sys.argv[2:4])
        except ValueError:
            fail("process-descendant requires numeric PID and ANCESTOR")
        raise SystemExit(0 if is_descendant(pid, ancestor) else 1)
    kind, resource = sys.argv[1:3]
    if kind == "file-lock":
        holders = file_lock_holders(resource)
    elif kind == "unix-socket":
        holders = socket_holders(resource)
    elif kind == "x-display":
        if not resource.isdigit():
            fail(f"display number must be decimal, got {resource!r}")
        # DISPLAY in an environment is only intent, not resource ownership.
        # Stop authority comes solely from the pathname/abstract listener.
        holders = socket_holders(f"/tmp/.X11-unix/X{resource}")
    elif kind == "pidfile":
        if len(sys.argv) != 4 or "=" not in sys.argv[3]:
            fail("pidfile inspection requires an expected ENV=VALUE")
        holders = pidfile_holders(resource, sys.argv[3])
    else:
        fail(f"unknown resource kind: {kind!r}")
    for pid in sorted(holders):
        print(pid)


if __name__ == "__main__":
    main()
