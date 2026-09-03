#!/usr/bin/env python3
"""Classify a GUI bundle against the release currently selected in a guest.

The bundle contract does not yet have a signed monotonic release sequence. Commit time is
therefore a deliberately conservative stopgap: it catches the stale-release rollback that
motivated this gate, refuses equal-time divergent commits, and never claims Git ancestry.
This helper ships inside the candidate bundle, so it is defense in depth for honest,
gate-aware candidates—not the authoritative product update trust boundary.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

SCHEMA = "airlock.gui-provisioner-bundle/v1"


def load_manifest(path: str) -> tuple[str, int]:
    try:
        doc = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read bundle manifest {path}: {exc}") from exc
    if doc.get("schema") != SCHEMA:
        raise ValueError(f"unexpected bundle manifest schema in {path}")
    sha = doc.get("source_sha")
    epoch = doc.get("source_epoch")
    if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        raise ValueError(f"invalid source_sha in {path}")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch <= 0:
        raise ValueError(f"invalid source_epoch in {path}")
    return sha, epoch


def relation(current_path: str, candidate_path: str) -> str:
    candidate_sha, candidate_epoch = load_manifest(candidate_path)
    if current_path == "-":
        return "fresh"
    current_sha, current_epoch = load_manifest(current_path)
    if candidate_sha == current_sha:
        if candidate_epoch != current_epoch:
            return "ambiguous"
        return "same"
    if candidate_epoch > current_epoch:
        return "chronological-forward"
    if candidate_epoch < current_epoch:
        return "rollback"
    return "ambiguous"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: gui-version-relation.py <current-manifest|-> <candidate-manifest>", file=sys.stderr)
        return 2
    try:
        print(relation(argv[1], argv[2]))
    except ValueError as exc:
        print(f"gui-version-relation: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
