"""devmon_harness — the settings panel's 하네스 section: what it may run, and how.

The section shows four layers and can press exactly one of them.  That asymmetry is
the design, not an unfinished state:

  Claude Code CLI  — updates itself.  Version only, no button, and no `latest` is
                     collected for it so that nothing downstream can build an
                     "outdated" verdict out of a number with nothing to compare to.
  Codex CLI        — an npm global install.  The one harness binary a person still has
                     to upgrade by hand, so it is the one button here: `codex`.
  공통 스킬        — wiring, counted per agent root by the collector.  `recheck` asks
                     the existing detection oneshot to measure again, now.
  훅               — drift is DISPLAYED and never applied.  Reconciling a hook is a
                     reviewed procedure (/harness-provision); a panel that merged them
                     silently would be the failure this row exists to report.

Why the upgrade is a tmux run and not a subprocess of the backend
-----------------------------------------------------------------
`npm install -g` on a loaded box is tens of seconds, and the panel has to survive the
page being closed while it happens.  So it uses the contract update execution already
established (devmon_update_exec, "Why it is not a subprocess of the backend"): the
approval-action runner execs this file in a tmux window, this file is the single
writer of one run record on disk, and the panel reads that record.  The record helpers
are imported rather than copied — one record format, one liveness rule.

Why it does NOT reuse the update run record
-------------------------------------------
A Codex upgrade and `bin/airlock-update` share no failure: the updater holds a git
mutex, restarts this backend under itself and arms a rollback directory; npm does
none of that and must not be blocked by, or reported over, an update in flight.  Two
independent runs, two records, two lines on the panel.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import devmon_update_exec as EXEC
import devmon_updates as UPDATES

SCHEMA_VERSION = 1

# What this file may be asked to do.  A closed enum, and the only caller-supplied
# value: like update execution there is no producer here, so there is no plan to pin —
# the argv below is a constant of this repository.
ACTIONS = ("codex",)

# `npm install -g` fetches, builds and links.  Past this a run is one somebody should
# look at in its window, not a number to keep raising.
UPGRADE_TIMEOUT = 900

# This module's own name in the wrapper's cmdline: how `observed()` tells OUR live
# process from a stale pid that now belongs to something else.
MARKER = b"devmon_harness"


def default_dir() -> Path:
    """Beside the update snapshot and the update run, for the same reason as those two:
    the dev-monitor state directory only exists when `messages = true`."""
    return Path(os.environ.get("AIRLOCK_HARNESS_RUN_DIR",
                               "~/.local/state/airlock/harness-run")).expanduser()


def read_record(directory: Path) -> dict[str, Any] | None:
    return EXEC.read_record(directory)


def observed(record: dict[str, Any] | None) -> dict[str, Any] | None:
    return EXEC.observed(record, MARKER)


def active(record: dict[str, Any] | None) -> bool:
    return EXEC.active(record)


def start_record(run_id: str, action: str) -> dict[str, Any]:
    """The record the BACKEND writes before launching, so a click is never invisible."""
    return {"schemaVersion": SCHEMA_VERSION, "runId": run_id, "action": action,
            "status": "starting", "pid": None, "startedAt": EXEC.now_iso(),
            "endedAt": None, "exitCode": None,
            "before": None, "after": None, "note": ""}


def build_exec_argv(directory: Path, run_id: str, action: str) -> list[str]:
    """argv the action runner execs — element by element, no shell anywhere."""
    return [sys.executable, str(Path(__file__).resolve()),
            "--dir", str(directory), "--run", run_id, "--action", action]


def build_plan(root: Path, directory: Path, run_id: str, action: str) -> dict[str, Any]:
    """The action_runner plan file.  `cwd` and `cwd_root` are both the checkout.

    The runner re-resolves cwd after chdir and refuses anything outside cwd_root, so
    pinning both to the checkout means a symlink swapped in after the click cannot move
    the run somewhere else.  Nothing here reads the checkout — npm is a global install —
    but the runner requires a place to be, and this is the one it already validates.
    """
    return {"cwd": str(root), "cwd_root": str(root),
            "exec": build_exec_argv(directory, run_id, action),
            "explain": "Codex CLI 를 npm 최신 버전으로 갱신"}


# ---------------------------------------------------------------- the CLI ----

def upgrade_argv() -> list[str] | None:
    """`npm install -g <pkg>@latest`, or None when npm cannot be located.

    Resolved through the platform's shared discovery rather than PATH: this runs from a
    tmux window started by a systemd --user service, whose PATH omits every place a
    node CLI actually lands (bin/bin_discovery.py, "Why this exists").
    """
    npm, _ = UPDATES.bin_discovery.find_bin("npm")
    if not npm:
        return None
    return [npm, "install", "-g", UPDATES.CODEX_PACKAGE + "@latest"]


def codex_summary() -> dict[str, Any]:
    """What the panel shows before and after: the same reading the collector takes.

    Deliberately the collector's own functions.  A wrapper that measured the version
    its own way could report a success the panel's next snapshot then contradicts.
    """
    return {"installed": UPDATES._cli("codex"), "latest": UPDATES.codex_latest()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="run a harness upgrade for the hub panel")
    parser.add_argument("--dir", dest="directory", type=Path, default=default_dir())
    parser.add_argument("--run", required=True)
    parser.add_argument("--action", required=True, choices=ACTIONS)
    args = parser.parse_args(argv)

    directory = args.directory.expanduser()
    record = EXEC.read_record(directory)
    if record is None or record.get("runId") != args.run:
        raise SystemExit("devmon_harness: run %s is not the recorded run — "
                         "another launch superseded it" % args.run)
    record["pid"] = os.getpid()
    record["status"] = "running"
    EXEC.write_record(directory, record)

    record["before"] = codex_summary()
    EXEC.write_record(directory, record)
    print("현재 Codex CLI: %s (최신 %s)" % (record["before"]["installed"],
                                            record["before"]["latest"]), flush=True)

    command = upgrade_argv()
    if command is None:
        record["exitCode"] = 127
        record["status"] = "failed"
        record["note"] = ("npm 을 찾지 못했습니다 — Codex CLI 는 npm 전역 설치라 "
                          "npm 없이는 갱신할 수 없습니다.")
        record["endedAt"] = EXEC.now_iso()
        record["after"] = record["before"]
        EXEC.write_record(directory, record)
        print(record["note"], file=sys.stderr)
        return 127

    print("실행: %s" % " ".join(command), flush=True)
    try:
        # stdout/stderr are inherited on purpose: the tmux pane the runner leaves open
        # is where a person reads what npm actually did.
        code = subprocess.call(command, timeout=UPGRADE_TIMEOUT)
    except subprocess.TimeoutExpired:
        code = 124
        record["note"] = "갱신이 %d초 안에 끝나지 않아 중단했습니다." % UPGRADE_TIMEOUT
    except OSError as exc:
        code = 127
        record["note"] = "npm 을 실행하지 못했습니다: %s" % exc

    record["exitCode"] = code
    record["status"] = "done" if code == 0 else "failed"
    record["endedAt"] = EXEC.now_iso()
    EXEC.write_record(directory, record)

    # Read the installed version back rather than trusting the exit code.  npm can
    # return 0 having installed into a prefix this box does not resolve, and the panel's
    # claim is "codex --version is now current", not "npm was happy".
    record["after"] = codex_summary()
    if code == 0 and record["after"]["installed"] == record["before"]["installed"]:
        record["note"] = ("npm 은 성공했는데 실행되는 codex 의 버전이 그대로입니다 — "
                          "다른 경로의 codex 가 PATH 앞에 있을 수 있습니다.")
    record["endedAt"] = EXEC.now_iso()
    EXEC.write_record(directory, record)
    print("\n갱신 뒤 Codex CLI: %s" % record["after"]["installed"], flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
