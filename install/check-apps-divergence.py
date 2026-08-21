#!/usr/bin/env python3
"""Fail when apps/ drift between this repo and airlock-apps grows past a path baseline.

The two trees already differ. A count of 18 would stay green if one known file
healed and a new one split. The baseline is the path list plus the kind of
split, not the count. A listed content path may keep changing blobs. A new
path, or a listed path whose kind gets worse, is red.

    python3 install/check-apps-divergence.py \\
        --work-root . --apps-root /path/to/airlock-apps
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

KINDS = {"only-work", "only-apps", "content"}
DEFAULT_BASELINE = Path(__file__).resolve().parent / "apps-divergence-baseline.txt"


def fail(message: str) -> None:
    raise SystemExit(f"apps-divergence: {message}")


def run_git(root: Path, *args: str) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        fail(f"git is missing ({exc})")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip() or f"exit {exc.returncode}"
        fail(f"git -C {root} {' '.join(args)} failed: {detail}")
    return completed.stdout


def list_apps(root: Path) -> dict[str, tuple[str, str]]:
    if not root.is_dir():
        fail(f"repository root is not a directory: {root}")
    listed = run_git(root, "ls-tree", "-r", "--full-tree", "HEAD", "apps")
    files: dict[str, tuple[str, str]] = {}
    for line in listed.splitlines():
        meta, path = line.split("\t", 1)
        mode, kind, digest = meta.split()
        if kind != "blob":
            continue
        files[path] = (mode, digest)
    return files


def load_baseline(path: Path) -> dict[str, str]:
    if not path.is_file():
        fail(f"baseline is missing: {path}")
    allowed: dict[str, str] = {}
    for index, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 2:
            fail(f"{path}:{index}: expected kind<TAB>path")
        kind, rel = parts[0].strip(), parts[1].strip()
        if kind not in KINDS:
            fail(f"{path}:{index}: unknown kind {kind!r}")
        if not rel.startswith("apps/") or any(part in {"", ".", ".."} for part in rel.split("/")):
            fail(f"{path}:{index}: path must stay under apps/: {rel!r}")
        if rel in allowed:
            fail(f"{path}:{index}: duplicate path {rel}")
        allowed[rel] = kind
    if not allowed:
        fail(f"{path}: baseline lists no paths")
    return allowed


def classify(
    work: dict[str, tuple[str, str]],
    apps: dict[str, tuple[str, str]],
) -> dict[str, str]:
    current: dict[str, str] = {}
    for path in set(work) - set(apps):
        current[path] = "only-work"
    for path in set(apps) - set(work):
        current[path] = "only-apps"
    for path in set(work) & set(apps):
        if work[path] != apps[path]:
            current[path] = "content"
    return current


def report(
    current: dict[str, str],
    baseline: dict[str, str],
    work_head: str,
    apps_head: str,
) -> int:
    extra = sorted(set(current) - set(baseline))
    healed = sorted(set(baseline) - set(current))
    kind_changed = sorted(
        path
        for path in set(current) & set(baseline)
        if current[path] != baseline[path]
    )
    print(
        "apps-divergence: "
        f"work={work_head} apps={apps_head} "
        f"work-only={sum(kind == 'only-work' for kind in current.values())} "
        f"apps-only={sum(kind == 'only-apps' for kind in current.values())} "
        f"content={sum(kind == 'content' for kind in current.values())} "
        f"baseline={len(baseline)} extra={len(extra)} kind-changed={len(kind_changed)}"
    )
    rc = 0
    for path in extra:
        print(f"apps-divergence: EXTRA {current[path]} {path}")
        rc = 1
    for path in kind_changed:
        print(f"apps-divergence: KIND {baseline[path]}->{current[path]} {path}")
        rc = 1
    for path in healed:
        print(f"apps-divergence: healed {baseline[path]} {path}")
    if extra or kind_changed:
        print(
            "apps-divergence: new drift is outside the known path list. "
            "A known path may keep changing blobs, but a new path or a worse "
            "kind (content becoming only-work/only-apps) is red. "
            "Update install/apps-divergence-baseline.txt only for an expected split."
        )
    return rc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-root", required=True, type=Path)
    parser.add_argument("--apps-root", required=True, type=Path)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    args = parser.parse_args(argv)
    work_root = args.work_root.resolve()
    apps_root = args.apps_root.resolve()
    work = list_apps(work_root)
    apps = list_apps(apps_root)
    if not work:
        fail(f"no tracked apps/ files in {args.work_root}")
    if not apps:
        fail(f"no tracked apps/ files in {args.apps_root}")
    current = classify(work, apps)
    baseline = load_baseline(args.baseline.resolve())
    work_head = run_git(work_root, "rev-parse", "--short", "HEAD").strip()
    apps_head = run_git(apps_root, "rev-parse", "--short", "HEAD").strip()
    return report(current, baseline, work_head, apps_head)


if __name__ == "__main__":
    sys.exit(main())
