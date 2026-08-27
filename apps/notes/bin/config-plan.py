#!/usr/bin/env python3
"""Validate Airlock's nested Notes config and emit server/client plans."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import unicodedata
from pathlib import Path


ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?\Z")
ENTRY_KEYS = frozenset({"id", "label", "path", "home_file", "writable"})


class ConfigError(ValueError):
    pass


def fail(message: str) -> None:
    raise ConfigError(message)


def valid_home_file(value: object) -> bool:
    if not isinstance(value, str) or not 1 <= len(value) <= 120:
        return False
    if value.startswith(".") or value in {".", ".."}:
        return False
    punctuation = "._-()[]"
    return all(
        character in punctuation
        or character == " "
        or unicodedata.category(character)[0] in {"L", "N"}
        for character in value
    )


def expand_path(raw: object, home: Path, *, check_paths: bool, writable: bool) -> Path:
    if not isinstance(raw, str) or not raw.startswith("$HOME/"):
        fail("vault path must start with literal $HOME/")
    if any(character in raw for character in "\x00\t\r\n"):
        fail("vault path must not contain control characters")
    if "," in raw:
        fail("vault path must not contain ',' (Docker --mount separator)")
    candidate = home / raw[len("$HOME/") :]
    if candidate.is_symlink():
        fail(f"vault path must not be a symlink: {candidate}")
    home_resolved = home.resolve(strict=check_paths)
    resolved = candidate.resolve(strict=check_paths)
    try:
        resolved.relative_to(home_resolved)
    except ValueError:
        fail(f"vault path escapes HOME: {raw}")
    if resolved == home_resolved:
        fail("vault path must resolve below HOME")
    if not check_paths:
        return resolved
    info = resolved.stat()
    if not stat.S_ISDIR(info.st_mode):
        fail(f"vault path is not a directory: {resolved}")
    if info.st_uid != os.getuid():
        fail(f"vault path owner differs from current uid: {resolved}")
    if writable and stat.S_IMODE(info.st_mode) != 0o700:
        fail(f"writable vault must be mode 0700: {resolved}")
    if writable:
        for path in resolved.rglob("*"):
            if not path.is_symlink():
                continue
            target = path.resolve(strict=False)
            try:
                target.relative_to(resolved)
            except ValueError:
                fail(f"writable vault contains outward symlink: {path}")
    return resolved


def build_plan(args: argparse.Namespace) -> dict:
    try:
        entries = json.loads(args.entries_json)
    except json.JSONDecodeError as exc:
        fail(f"vaults.entries is not valid JSON: {exc}")
    if not isinstance(entries, list) or not entries:
        fail("vaults.entries must be a non-empty array")
    if not 1 <= args.vault_slots <= 10:
        fail("vault_slots must be between 1 and 10")
    if len(entries) > args.vault_slots:
        fail("vaults.entries exceeds vault_slots")
    if not 1 <= args.reader_port <= 65535:
        fail("reader_port is outside 1..65535")
    if not 1 <= args.editor_port_base <= 65535:
        fail("editor_port_base is outside 1..65535")
    if args.editor_port_base + args.vault_slots - 1 > 65535:
        fail("editor port span exceeds 65535")

    home = args.home.resolve(strict=not args.skip_path_check)
    seen_ids: set[str] = set()
    seen_labels: set[str] = set()
    seen_paths: set[str] = set()
    vaults: list[dict] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != ENTRY_KEYS:
            fail(f"vault[{index}] must contain exactly {sorted(ENTRY_KEYS)}")
        vault_id = entry["id"]
        label = entry["label"]
        writable = entry["writable"]
        if not isinstance(vault_id, str) or not ID_RE.fullmatch(vault_id):
            fail(f"vault[{index}] has invalid id")
        if (
            not isinstance(label, str)
            or not label.strip()
            or len(label) > 80
            or any(ord(character) < 32 for character in label)
        ):
            fail(f"vault[{index}] has invalid label")
        if type(writable) is not bool:
            fail(f"vault[{index}].writable must be boolean")
        if not valid_home_file(entry["home_file"]):
            fail(f"vault[{index}] has invalid home_file")
        resolved = expand_path(
            entry["path"], home, check_paths=not args.skip_path_check, writable=writable
        )
        path_key = str(resolved)
        if vault_id in seen_ids:
            fail(f"duplicate vault id: {vault_id}")
        if label in seen_labels:
            fail(f"duplicate vault label: {label}")
        if path_key in seen_paths:
            fail(f"duplicate vault path: {path_key}")
        seen_ids.add(vault_id)
        seen_labels.add(label)
        seen_paths.add(path_key)
        vaults.append(
            {
                "id": vault_id,
                "label": label,
                "path": path_key,
                "home_file": entry["home_file"],
                "writable": writable,
                "editor_port": args.editor_port_base + index if writable else None,
                "editor_path": f"/notes/editor/{vault_id}/" if writable else None,
                "reader_container": f"airlock-notes-reader-{vault_id}",
            }
        )
    if args.default_vault not in seen_ids:
        fail("vaults.default_vault must name an entry")
    return {
        "schema_version": 1,
        "default_vault": args.default_vault,
        "reader_port": args.reader_port,
        "router_container": "airlock-notes-router",
        "vaults": vaults,
    }


def client_plan(plan: dict) -> dict:
    return {
        "schema_version": 1,
        "default_vault": plan["default_vault"],
        "vaults": [
            {
                "id": vault["id"],
                "label": vault["label"],
                "home_file": vault["home_file"],
                "writable": vault["writable"],
                "editor_path": vault["editor_path"],
            }
            for vault in plan["vaults"]
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--entries-json", required=True)
    parser.add_argument("--default-vault", required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reader-port", type=int, required=True)
    parser.add_argument("--editor-port-base", type=int, required=True)
    parser.add_argument("--vault-slots", type=int, required=True)
    parser.add_argument("--skip-path-check", action="store_true")
    parser.add_argument("--format", choices=("server", "client"), default="server")
    args = parser.parse_args()
    try:
        plan = build_plan(args)
    except (ConfigError, OSError) as exc:
        print(f"notes config: {exc}", file=sys.stderr)
        return 2
    payload = client_plan(plan) if args.format == "client" else plan
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
