"""devmon_update_exec — run `bin/airlock-update` from the hub's settings panel.

Two halves in one file: a small library the backend imports, and the CLI that the
approval-action runner actually execs inside a tmux window.

Why this exists next to the message/action console instead of inside it
----------------------------------------------------------------------
The console's approval machinery (nonce, canonical plan, plan hash, runs table)
exists to pin a plan that a *producer* wrote into a card, so it cannot be edited
between the moment the owner reads it and the moment it runs (SECURITY.md, "Approval
is pinned to a plan, not to a card").  There is no producer here.  The argv this
module builds is a constant of this repository — `bash <root>/bin/airlock-update` —
and the only caller-supplied value is a closed enum plus an app id that must already
appear in the update snapshot.  A hash over a constant pins nothing.

That matters because the console is `messages = false` by default, and its documented
meaning is about intake: "If you do not want a local process to be able to raise cards
on your box at all, leave messages = false".  Update execution raises no card.  So it
hangs off the smaller ingress gate that update *detection* already uses
(`devmon_owner.load_gate_config`), and reuses only `action_runner`'s argv/exec contract.

Why it is not a subprocess of the backend
-----------------------------------------
`bin/airlock-update` re-runs the installer, and the installer runs
`systemctl --user restart airlock-dev-monitor.service` (apps/dev-monitor/install.sh).
A child of this backend would be killed halfway through its own update.  It therefore
runs in a tmux window, whose server is a different process tree, and every fact the
panel needs afterwards is on disk rather than in this process's memory.

Why a wrapper rather than exec'ing airlock-update directly
----------------------------------------------------------
The panel has to show a before/after `bin/airlock-status --json` summary and, on a
failure, the exact `--rollback` command.  airlock-update takes its own status readings
but keeps them inside a recovery directory it deletes on success.  This wrapper takes
the two readings the panel shows, and reads the recovery directory airlock-update
armed rather than inventing a second recovery mechanism.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# The same id grammar bin/airlock-config enforces for a package.  Used to refuse an
# app id before it can reach a run record, not to authorize one: the id never reaches
# a command line (see build_exec_argv — it is recorded, never passed).
APP_ID = re.compile(r"\A[a-z0-9][a-z0-9-]{0,31}\Z")

# A status run probes tailscale, nginx, the gate and every unit; on a loaded box it is
# tens of seconds.  Two of them plus a release fetch plus a full installer run is the
# real ceiling, and a run still going after this is a run whose window someone should
# look at rather than a number this file should keep raising.
STATUS_TIMEOUT = 300
UPDATE_TIMEOUT = 3600

# How long a record with no pid yet is still believed to be starting.  tmux window
# creation plus interpreter start is well under a second on a healthy box; this is
# sized for a loaded one, and a launch that genuinely failed is rewritten by the
# backend rather than waiting this out.
LAUNCH_GRACE = 60


def default_root() -> Path:
    return Path(__file__).resolve().parents[3]


def default_dir() -> Path:
    """Beside the update snapshot, not under the dev-monitor state directory.

    The dev-monitor state directory is created by the installer only when
    `messages = true`; this feature has to work on a box that never enabled it.
    """
    return Path(os.environ.get("AIRLOCK_UPDATE_RUN_DIR",
                               "~/.local/state/airlock/update-run")).expanduser()


def run_path(directory: Path) -> Path:
    return directory / "run.json"


def plan_dir(directory: Path) -> Path:
    return directory / "plans"


def sentinel_dir(directory: Path) -> Path:
    return directory / "sentinels"


def ensure_dirs(directory: Path) -> None:
    for path in (directory, plan_dir(directory), sentinel_dir(directory)):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def new_run_id(clock: float | None = None) -> str:
    """Sortable, unique per launch, and legal as a tmux window name."""
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(clock))
    return "upd-%s-%s" % (stamp, os.urandom(3).hex())


# ---------------------------------------------------------------- record I/O ----

def write_record(directory: Path, record: dict[str, Any]) -> None:
    """Atomically replace the single run record."""
    ensure_dirs(directory)
    path = run_path(directory)
    descriptor, temporary = tempfile.mkstemp(prefix=".run.", dir=str(directory))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(record, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def read_record(directory: Path) -> dict[str, Any] | None:
    try:
        with run_path(directory).open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict) or not isinstance(value.get("runId"), str):
        return None                      # a truncated or hand-edited file is not a run
    return value


# ---------------------------------------------------------------- liveness ----

def pid_alive(pid: Any, marker: bytes = b"devmon_update_exec") -> bool:
    """Is the recorded wrapper still running?

    Checked by cmdline, not by `kill(pid, 0)` alone: a run record outlives the process
    it describes, and after a reboot that pid belongs to something else.  Falling back
    to a bare signal probe where /proc is absent keeps the answer conservative rather
    than making the whole feature depend on procfs.

    `marker` is the wrapper's own module name, so a second wrapper reusing this record
    machinery (devmon_harness) asks about ITS process rather than matching whatever
    this file happens to be called.
    """
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        raw = Path("/proc/%d/cmdline" % pid).read_bytes()
    except FileNotFoundError:
        return False
    except OSError:
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True
    return marker in raw


def git_dir(root: Path) -> Path | None:
    """The absolute git directory airlock-update locks, or None if there is none yet.

    A box installed by `clone; rm -rf .git; git init` may not have run `git init` at
    all until its first update, which is a supported state — airlock-update creates
    the repository itself.  No repository means nothing holds the mutex.
    """
    try:
        result = subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    value = result.stdout.strip()
    return Path(value) if value else None


def updater_busy(root: Path) -> bool | None:
    """Is ANY airlock-update or rollback running — including one started in a terminal?

    True / False / **None when it cannot be measured**, and the third value is the point:
    a "no" that is really "I could not look" is the absence claim this whole panel exists
    to stop making.

    Measured by READING /proc/locks, never by taking the lock.  airlock-update serialises
    itself with a non-blocking exclusive `flock` on its own git directory
    (bin/airlock-update, acquire_update_mutex).  A probe that acquired that lock — even
    for microseconds — would make a real update, started one poll tick later, die with
    "another airlock-update is in progress".  Asking the kernel who holds it takes
    nothing.  (Verified against a live flock 2026-09-01: a lock held on a directory
    appears as `FLOCK ADVISORY WRITE <pid> <maj:min:ino> 0 EOF`, matched here on
    maj:min:ino.  apps/dev-monitor/test-backend.py holds one and asserts both answers,
    so the probe cannot regress into a function that only ever says "free".)

    Not a second opinion, either: this is the updater's OWN lock, so a run started over
    SSH and the daily detection timer's `--dry-run` are both visible, and there is no
    state of ours to drift out of step with it.
    """
    directory = git_dir(root)
    if directory is None:
        return False                     # no repository yet: nothing can hold the mutex
    try:
        stat = os.stat(directory)
    except OSError:
        return None
    try:
        raw = Path("/proc/locks").read_text()
    except OSError:
        return None                      # no procfs — say so rather than answering "free"
    wanted = "%02x:%02x:%d" % (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    for line in raw.splitlines():
        fields = line.split()
        if fields[1:2] == ["->"]:
            fields = fields[:1] + fields[2:]   # a blocked waiter is written "N: -> FLOCK …"
        if len(fields) > 5 and fields[1] == "FLOCK" and fields[5] == wanted:
            return True
    return False


def active(record: dict[str, Any] | None) -> bool:
    return bool(record) and record.get("status") in ("starting", "running")


def _age_seconds(stamp: Any) -> float | None:
    if not isinstance(stamp, str):
        return None
    try:
        parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - parsed).total_seconds()


def observed(record: dict[str, Any] | None,
             marker: bytes = b"devmon_update_exec") -> dict[str, Any] | None:
    """The record as the panel should read it: a dead 'running' run is 'interrupted'.

    A window closed by hand, an OOM kill or a reboot all leave the last written status
    saying `running` forever.  Resolving that here — against the wrapper's own pid —
    keeps a single writer for the file (the wrapper) while still letting a reader tell
    'in progress' from 'nobody finished this'.

    The grace window covers the one moment there is no pid to ask about: the backend
    writes the record BEFORE tmux has started anything, so that a click is never
    invisible, and until the wrapper claims it there is nothing alive to find.  Without
    the window every launch would read as 'interrupted' for its first seconds — the
    false alarm being reported to the very screen this exists to keep honest.  A launch
    that really failed does not wait it out: the backend overwrites the record itself.
    """
    if not active(record):
        return record
    if record.get("pid") is None:
        age = _age_seconds(record.get("startedAt"))
        if age is None or age < LAUNCH_GRACE:
            return record
    elif pid_alive(record.get("pid"), marker):
        return record
    resolved = dict(record)
    resolved["status"] = "interrupted"
    resolved["note"] = ("실행이 결과를 남기지 못하고 끝났습니다 — 아래 복구 명령으로 "
                        "되돌린 뒤 다시 시도하십시오.")
    resolved.setdefault("recovery", None)
    return resolved


# ---------------------------------------------------------------- the plan ----

def build_exec_argv(root: Path, directory: Path, run_id: str, action: str,
                    app_id: str | None) -> list[str]:
    """argv the action runner execs — element by element, no shell anywhere.

    Note what is NOT here: the app id.  Both buttons run the same command because
    there is no supported way to reinstall one app on its own (the installer has no
    per-app entry point; a single app's install is intent -> icon-stage -> install.sh
    -> serve render -> commit, and reproducing that outside would fork the ledger
    protocol).  The id is recorded so the panel can say which row was pressed; it is
    never an argument, so an id cannot reach a command line at all.
    """
    argv = [sys.executable, str(Path(__file__).resolve()),
            "--root", str(root), "--dir", str(directory), "--run", run_id,
            "--action", action]
    if app_id:
        argv += ["--app", app_id]
    return argv


def build_plan(root: Path, directory: Path, run_id: str, action: str,
               app_id: str | None) -> dict[str, Any]:
    """The action_runner plan file. `cwd` and `cwd_root` are both the checkout.

    The runner re-resolves cwd after chdir and refuses anything outside cwd_root, so
    pinning both to the checkout means a symlink swapped in after the click cannot
    move the run somewhere else.
    """
    explain = ("Airlock 본체 업데이트" if action == "platform"
               else "앱 '%s' 재설치 (본체 업데이트 경로로 수렴)" % app_id)
    return {"cwd": str(root), "cwd_root": str(root),
            "exec": build_exec_argv(root, directory, run_id, action, app_id),
            "explain": explain}


def start_record(run_id: str, action: str, app_id: str | None) -> dict[str, Any]:
    """The record the BACKEND writes before launching, so a click is never invisible.

    The wrapper refuses to overwrite a record whose runId is not its own, which is what
    stops a superseded launch from reporting over a live one.
    """
    return {"schemaVersion": SCHEMA_VERSION, "runId": run_id, "action": action,
            "appId": app_id, "status": "starting", "pid": None,
            "startedAt": now_iso(), "endedAt": None, "exitCode": None,
            "before": None, "after": None, "recovery": None, "note": ""}


def sweep_plans(directory: Path, older_than: float = 7 * 86400) -> None:
    """Keep the plan/sentinel directories from becoming a trash can.

    The message console's reaper does this for its own runs, and it does not run on a
    box with messages off — so this path sweeps its own, at launch, where the cost is
    already being paid.
    """
    cutoff = time.time() - older_than
    for folder in (plan_dir(directory), sentinel_dir(directory)):
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            path = folder / name
            try:
                if path.stat().st_mtime < cutoff:
                    path.unlink()
            except OSError:
                pass


# ---------------------------------------------------------------- the CLI ----

def status_summary(root: Path) -> dict[str, Any]:
    """One `bin/airlock-status --json` run, reduced to what the panel shows.

    Every way of not producing a verdict is a value, never an exception: the panel's
    job is to say what happened, and "the status tool did not answer" is one of the
    things that can happen during an update.
    """
    argv = [sys.executable, str(root / "bin" / "airlock-status"), "--json"]
    try:
        result = subprocess.run(argv, cwd=str(root), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True,
                                timeout=STATUS_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        return {"rc": 124, "verdict": None, "error": "airlock-status timed out"}
    except OSError as exc:
        return {"rc": 127, "verdict": None, "error": "airlock-status did not run: %s" % exc}
    try:
        document = json.loads(result.stdout)
    except ValueError:
        return {"rc": result.returncode, "verdict": None,
                "error": "airlock-status did not return JSON"}
    if not isinstance(document, dict) or not isinstance(document.get("checks"), list):
        return {"rc": result.returncode, "verdict": None,
                "error": "airlock-status returned an unknown shape"}
    checks = [c for c in document["checks"] if isinstance(c, dict)]
    revision = next((c for c in checks if c.get("id") == "install.revision"), None)
    return {
        "rc": result.returncode,
        "verdict": document.get("verdict"),
        "counts": document.get("counts"),
        # The success condition the card is judged on: install.revision has to move.
        "revision": (revision or {}).get("detail"),
        "revisionStatus": (revision or {}).get("status"),
        # Capped: this is a phone-width line, not a second copy of the status report.
        "problems": [{"id": c.get("id"), "status": c.get("status"),
                      "detail": c.get("detail")}
                     for c in checks if c.get("status") in ("fail", "unchecked", "warn")][:6],
    }


def recovery_hint(root: Path) -> dict[str, Any]:
    """The `--rollback` line airlock-update armed, read from where it armed it.

    airlock-update copies itself into <git-dir>/airlock-update-rollback and prints this
    command on every failure path.  Reading the directory rather than composing a
    command from memory means the panel cannot offer a recovery that was never armed:
    a run that failed before the arming step gets `available: false` and says so.
    """
    directory = git_dir(root)
    recovery = directory / "airlock-update-rollback" if directory else None
    if recovery is not None and (recovery / "airlock-update").is_file():
        return {"available": True,
                "command": 'AIRLOCK_DIR="%s" bash "%s" --rollback'
                           % (root, recovery / "airlock-update")}
    return {"available": False,
            "command": 'AIRLOCK_DIR="%s" bash "%s" --rollback' % (root, root / "bin" / "airlock-update"),
            "reason": ("자동 복구 기준점이 만들어지기 전에 멈췄습니다 — 되돌릴 변경이 "
                       "없을 수 있습니다. 위 명령은 남은 기록이 있을 때만 동작합니다.")}


def _claim(directory: Path, run_id: str) -> dict[str, Any]:
    """Load our own record, or refuse to write over someone else's."""
    record = read_record(directory)
    if record is None or record.get("runId") != run_id:
        raise SystemExit("devmon_update_exec: run %s is not the recorded run — "
                         "another launch superseded it" % run_id)
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="run bin/airlock-update for the hub panel")
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--dir", dest="directory", type=Path, default=default_dir())
    parser.add_argument("--run", required=True)
    parser.add_argument("--action", required=True, choices=("platform", "app"))
    parser.add_argument("--app", default=None)
    args = parser.parse_args(argv)

    root = args.root.resolve()
    directory = args.directory.expanduser()
    record = _claim(directory, args.run)
    record["pid"] = os.getpid()
    record["status"] = "running"
    write_record(directory, record)

    print("업데이트 전 상태를 확인합니다… (bin/airlock-status --json)", flush=True)
    record["before"] = status_summary(root)
    write_record(directory, record)

    argv_update = ["bash", str(root / "bin" / "airlock-update")]
    print("실행: %s" % " ".join(argv_update), flush=True)
    try:
        # stdout/stderr are inherited on purpose: the tmux pane the runner leaves open
        # is where a person reads what the installer actually did.
        code = subprocess.call(argv_update, cwd=str(root), timeout=UPDATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        code = 124
        record["note"] = "업데이트가 %d초 안에 끝나지 않아 중단했습니다." % UPDATE_TIMEOUT
    except OSError as exc:
        code = 127
        record["note"] = "업데이트를 실행하지 못했습니다: %s" % exc

    record["exitCode"] = code
    record["status"] = "done" if code == 0 else "failed"
    record["endedAt"] = now_iso()
    write_record(directory, record)

    print("\n업데이트 뒤 상태를 확인합니다… (bin/airlock-status --json)", flush=True)
    record["after"] = status_summary(root)
    if code != 0:
        record["recovery"] = recovery_hint(root)
    record["endedAt"] = now_iso()
    write_record(directory, record)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
