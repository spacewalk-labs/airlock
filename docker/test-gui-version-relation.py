#!/usr/bin/env python3
"""Offline behavior checks for the provisioner's stale-bundle gate."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
HELPER = HERE / "gui-version-relation.py"
SCHEMA = "airlock.gui-provisioner-bundle/v1"


def write_manifest(root: pathlib.Path, name: str, sha: str, epoch: int) -> pathlib.Path:
    path = root / name
    path.write_text(
        json.dumps({"schema": SCHEMA, "source_sha": sha, "source_epoch": epoch}) + "\n",
        encoding="utf-8",
    )
    return path


def classify(current: pathlib.Path | str, candidate: pathlib.Path) -> str:
    result = subprocess.run(
        [sys.executable, str(HELPER), str(current), str(candidate)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def main() -> int:
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        old = write_manifest(root, "old.json", "1" * 40, 100)
        same = write_manifest(root, "same.json", "1" * 40, 100)
        newer = write_manifest(root, "newer.json", "2" * 40, 200)
        equal_diverged = write_manifest(root, "equal-diverged.json", "3" * 40, 100)
        same_sha_bad_epoch = write_manifest(root, "same-sha-bad-epoch.json", "1" * 40, 101)

        cases = [
            ("-", old, "fresh"),
            (old, same, "same"),
            (old, newer, "chronological-forward"),
            (newer, old, "rollback"),
            (old, equal_diverged, "ambiguous"),
            (old, same_sha_bad_epoch, "ambiguous"),
        ]
        for current, candidate, expected in cases:
            actual = classify(current, candidate)
            assert actual == expected, (current, candidate, expected, actual)

        malformed = root / "malformed.json"
        malformed.write_text('{"schema":"wrong"}\n', encoding="utf-8")
        rejected = subprocess.run(
            [sys.executable, str(HELPER), str(old), str(malformed)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert rejected.returncode == 2
        assert "unexpected bundle manifest schema" in rejected.stderr

    print("passed=7 failed=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
