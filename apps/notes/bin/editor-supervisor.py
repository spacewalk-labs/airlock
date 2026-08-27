#!/usr/bin/env python3
"""Run one loopback SilverBullet process for each writable configured vault."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def required_path(name: str) -> Path:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing {name}")
    path = Path(value)
    if not path.is_absolute() or not path.is_file():
        raise RuntimeError(f"{name} is not an absolute file: {path}")
    return path


def main() -> int:
    try:
        plan_path = required_path("AIRLOCK_NOTES_PLAN")
        silverbullet = required_path("AIRLOCK_NOTES_SILVERBULLET_BIN")
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"notes editor supervisor: {exc}", file=sys.stderr)
        return 2

    children: list[subprocess.Popen[bytes]] = []
    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        for child in children:
            if child.poll() is None:
                child.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    base_env = os.environ.copy()
    base_env.update({"SB_SHELL_BACKEND": "off", "SB_RUNTIME_API": "0"})
    try:
        for vault in plan.get("vaults", []):
            if not vault.get("writable"):
                continue
            env = base_env.copy()
            env["SB_URL_PREFIX"] = vault["editor_path"].rstrip("/")
            child = subprocess.Popen(
                [
                    str(silverbullet),
                    "-L",
                    "127.0.0.1",
                    "-p",
                    str(vault["editor_port"]),
                    vault["path"],
                ],
                env=env,
            )
            children.append(child)
        while not stopping:
            failed = next((child for child in children if child.poll() is not None), None)
            if failed is not None:
                print(
                    f"notes editor supervisor: child exited rc={failed.returncode}",
                    file=sys.stderr,
                )
                return 1
            time.sleep(0.5)
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
        deadline = time.monotonic() + 8
        for child in children:
            try:
                child.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                child.kill()
        for child in children:
            child.wait()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
