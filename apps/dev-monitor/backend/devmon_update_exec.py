"""Run one app's ledger apply/remove, or the platform updater, through the action runner.

The runner survives the dev-monitor service restarting and writes its result to disk.
The platform action invokes airlock-update and records its result.
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
from urllib.parse import quote

SCHEMA_VERSION = 1

# The same id grammar bin/airlock-config enforces for a package.  Used to refuse an
# app id before it can reach a run record. Reinstall actions only record it; the closed
# teardown action is the sole action that passes the already-validated id to a command.
APP_ID = re.compile(r"\A(?!\.{1,2}\Z)[^/\x00]+\Z")

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


def run_path(directory: Path, run_id: str | None = None) -> Path:
    if run_id is not None:
        return directory / "runs" / (quote(run_id, safe="") + ".json")
    return directory / "run.json"


def plan_dir(directory: Path) -> Path:
    return directory / "plans"


def sentinel_dir(directory: Path) -> Path:
    return directory / "sentinels"


def ensure_dirs(directory: Path) -> None:
    for path in (directory, directory / "runs", plan_dir(directory), sentinel_dir(directory)):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def new_run_id(clock: float | None = None) -> str:
    """Sortable, unique per launch, and legal as a tmux window name."""
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(clock))
    return "upd-%s-%s" % (stamp, os.urandom(3).hex())


# ---------------------------------------------------------------- record I/O ----

def write_record(directory: Path, record: dict[str, Any]) -> None:
    """Write this run independently; run.json points to the latest launch."""
    ensure_dirs(directory)
    path = run_path(directory, record["runId"])
    descriptor, temporary = tempfile.mkstemp(prefix=".run.", dir=str(directory))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(record, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        latest = run_path(directory)
        if record.get("status") == "starting" or not latest.exists():
            # Only a launch moves the pointer. Finishing an older run cannot hide
            # the newest launch or overwrite its record.
            pointer = Path(temporary + ".latest")
            try:
                pointer.symlink_to(path.relative_to(directory))
                os.replace(pointer, latest)
            finally:
                pointer.unlink(missing_ok=True)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def read_record(directory: Path, run_id: str | None = None) -> dict[str, Any] | None:
    try:
        with run_path(directory, run_id).open(encoding="utf-8") as handle:
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


def updater_busy(root: Path) -> bool | None:
    """Observe this checkout's updater/installer processes without taking a lock.

    UI wrapper processes cover their preparation and completion as well. On a
    host without readable process metadata, None means it could not be measured.
    """
    root = root.resolve()
    try:
        processes = list(Path("/proc").iterdir())
    except OSError:
        return None
    targets = {root / "bin/airlock-update", root / "install/airlock-install.sh"}
    unknown = False
    for process in processes:
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            argv = [os.fsdecode(arg) for arg in
                    (process / "cmdline").read_bytes().split(b"\0") if arg]
            if not argv or "--dry-run" in argv:
                continue
            executable = Path(argv[0]).name
            if executable not in {"bash", "sh", "dash", "zsh"} and not executable.startswith("python"):
                continue
            script = None
            for arg in argv[1:]:
                if arg in {"-c", "-lc", "-ic", "-m"}:
                    break                     # command text is not a script path
                if not arg.startswith("-"):
                    script = Path(arg)
                    break
            if script is None:
                continue
            if script.name in {"airlock-update", "airlock-install.sh"}:
                candidate = script
                if not candidate.is_absolute():
                    candidate = (process / "cwd").resolve() / candidate
                if candidate.resolve() in targets:
                    return True
            if (script.name == "devmon_update_exec.py"
                    and "--root" in argv and "--action" in argv):
                checkout = argv[argv.index("--root") + 1]
                action = argv[argv.index("--action") + 1]
                if action == "platform" and Path(checkout).resolve() == root:
                    return True
        except (FileNotFoundError, ProcessLookupError):
            continue                         # exited while being observed
        except (OSError, IndexError):
            unknown = True
    return None if unknown else False


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
    resolved["note"] = ("실행이 결과를 남기지 못하고 끝났습니다 — 현재 상태를 확인하고 "
                        "같은 작업을 다시 실행하십시오.")
    resolved.setdefault("recovery", None)
    return resolved


# ---------------------------------------------------------------- the plan ----

def build_exec_argv(root: Path, directory: Path, run_id: str, action: str,
                    app_id: str | None, *, package_path: str | None = None) -> list[str]:
    """Fixed wrapper argv with one app id and optional engine source."""
    argv = [sys.executable, str(Path(__file__).resolve()),
            "--root", str(root), "--dir", str(directory), "--run", run_id,
            "--action", action]
    if app_id:
        argv += [f"--app={app_id}"]
    if package_path is not None:
        argv += ["--package-path", package_path]
    return argv


def build_plan(root: Path, directory: Path, run_id: str, action: str,
               app_id: str | None, *, package_path: str | None = None) -> dict[str, Any]:
    """The action_runner plan file. `cwd` and `cwd_root` are both the checkout.

    The runner re-resolves cwd after chdir and refuses anything outside cwd_root, so
    pinning both to the checkout means a symlink swapped in after the click cannot
    move the run somewhere else.
    """
    explain = {
        "platform": "Airlock 본체 업데이트",
        "app": "앱 '%s' 적용" % app_id,
        "install": "그 앱만 원장 엔진으로 적용",
        "teardown": "앱 '%s' teardown (앱 데이터는 유지)" % app_id,
    }[action]
    return {"cwd": str(root), "cwd_root": str(root),
            "exec": build_exec_argv(
                root, directory, run_id, action, app_id,
                package_path=package_path),
            "explain": explain}


def start_record(run_id: str, action: str, app_id: str | None) -> dict[str, Any]:
    """The record the BACKEND writes before launching, so a click is never invisible.

    Each wrapper writes only its own runId record.
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


def app_summary(root: Path, app_id: str) -> dict[str, Any]:
    """Read the selected app's committed revision without probing other apps or Paseo."""
    try:
        result = subprocess.run([sys.executable, str(root / "bin/airlock-ledger"), "list", "--json"],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                cwd=str(root), timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"rc": 127, "verdict": None, "error": str(exc)}
    if result.returncode != 0:
        return {"rc": result.returncode, "verdict": None, "appId": app_id,
                "revision": None, "installed": None}
    try:
        store = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {"rc": result.returncode, "verdict": None, "error": str(exc),
                "appId": app_id, "revision": None, "installed": None}
    row = store.get(app_id)
    revision = row.get("commit") if isinstance(row, dict) else None
    return {"rc": result.returncode, "verdict": None, "appId": app_id,
            "revision": revision, "installed": app_id in store}


def _claim(directory: Path, run_id: str) -> dict[str, Any]:
    """Load our own record, or refuse to write over someone else's."""
    record = read_record(directory, run_id)
    if record is None or record.get("runId") != run_id:
        raise SystemExit("devmon_update_exec: run %s is not the recorded run — "
                         "its launch record is unavailable" % run_id)
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="run a closed Airlock lifecycle action")
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--dir", dest="directory", type=Path, default=default_dir())
    parser.add_argument("--run", required=True)
    parser.add_argument("--action", required=True,
                        choices=("platform", "app", "install", "teardown"))
    parser.add_argument("--app", default=None)
    parser.add_argument("--package-path", default=None)
    args = parser.parse_args(argv)

    root = args.root.resolve()
    directory = args.directory.expanduser()
    record = _claim(directory, args.run)
    record["pid"] = os.getpid()
    record["status"] = "running"
    write_record(directory, record)

    print("적용 전 상태를 확인합니다…", flush=True)
    record["before"] = status_summary(root) if args.action == "platform" else app_summary(root, args.app)
    write_record(directory, record)

    if args.action == "platform":
        argv_update = ["bash", str(root / "bin" / "airlock-update")]
    else:
        if not isinstance(args.app, str) or APP_ID.fullmatch(args.app) is None:
            record.update(status="failed", exitCode=2, endedAt=now_iso(),
                          note="app action requires a valid app id")
            write_record(directory, record)
            return 2
        argv_update = [sys.executable, str(root / "bin" / "airlock-ledger"),
                       "remove" if args.action == "teardown" else "apply"]
        if args.action != "teardown" and args.package_path:
            argv_update += ["--source", args.package_path]
        argv_update += ["--", args.app]
    subject = {"platform": "플랫폼 업데이트", "app": "앱 업데이트",
               "install": "앱 설치", "teardown": "앱 teardown"}[args.action]
    print("실행: %s" % " ".join(argv_update), flush=True)
    try:
        # stdout/stderr are inherited on purpose: the tmux pane the runner leaves open
        # is where a person reads what the installer actually did.
        code = subprocess.call(argv_update, cwd=str(root), stdin=subprocess.DEVNULL,
                               timeout=UPDATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        code = 124
        record["note"] = "%s가 %d초 안에 끝나지 않아 중단했습니다." % (
            subject, UPDATE_TIMEOUT)
    except OSError as exc:
        code = 127
        record["note"] = "%s를 실행하지 못했습니다: %s" % (subject, exc)

    record["exitCode"] = code
    record["status"] = "done" if code == 0 else "failed"
    record["endedAt"] = now_iso()
    write_record(directory, record)

    print("\n적용 뒤 상태를 확인합니다…", flush=True)
    record["after"] = status_summary(root) if args.action == "platform" else app_summary(root, args.app)
    if code != 0 and not record.get("note"):
        record["note"] = ({
            "platform": "플랫폼 업데이트가 실패했습니다. 실행 창의 출력을 확인하고 다시 실행하십시오.",
            "app": "앱 업데이트가 실패했습니다. 실행 창에서 엔진의 복원 결과를 확인하십시오.",
            "install": ("앱 설치가 실패했습니다. 실행 창의 출력을 확인하고, "
                        "엔진의 복원 결과를 확인하십시오."),
            "teardown": ("앱 teardown이 실패했습니다. 실행 창의 출력을 확인하십시오. "
                         "실패한 자원의 상태를 확인하고 다시 실행하십시오."),
        }[args.action])
    record["endedAt"] = now_iso()
    write_record(directory, record)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
