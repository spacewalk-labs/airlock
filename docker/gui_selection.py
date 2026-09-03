#!/usr/bin/env python3
"""Validate the root provisioner's pinned bundle metadata and GUI selection."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


EXPECTED_PROFILE = {
    "always": ["hub"],
    "required": ["devterm", "fileview", "publish"],
    "default": ["paseo"],
    "install": ["devterm", "fileview", "publish", "paseo"],
}


def _read(path: pathlib.Path, label: str) -> tuple[dict, bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label} is invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value, raw


def validate(
    manifest_path: pathlib.Path,
    profile_path: pathlib.Path,
    catalog_path: pathlib.Path,
    selection_path: pathlib.Path | None,
    target_arch: str,
) -> tuple[str, list[str], int]:
    manifest, _ = _read(manifest_path, "manifest")
    profile, profile_raw = _read(profile_path, "profile")
    catalog, catalog_raw = _read(catalog_path, "catalog")
    if manifest.get("schema") != "airlock.gui-provisioner-bundle/v1":
        raise ValueError("bad bundle schema")
    if profile.get("schema") != "airlock.gui-default-profile/v1":
        raise ValueError("bad profile schema")
    source_sha = manifest.get("source_sha", "")
    if re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("bad source SHA")
    source_epoch = manifest.get("source_epoch")
    if not isinstance(source_epoch, int) or isinstance(source_epoch, bool) or source_epoch <= 0:
        raise ValueError("bad source epoch")
    if manifest.get("profile_path") != "docker/gui-default-profile.json":
        raise ValueError("bad profile path")
    if manifest.get("catalog_path") != "docker/gui-catalog.json":
        raise ValueError("bad catalog path")
    if hashlib.sha256(profile_raw).hexdigest() != manifest.get("profile_sha256"):
        raise ValueError("profile digest mismatch")
    if hashlib.sha256(catalog_raw).hexdigest() != manifest.get("catalog_sha256"):
        raise ValueError("catalog digest mismatch")
    for key, expected in EXPECTED_PROFILE.items():
        if profile.get(key) != expected:
            raise ValueError(f"profile {key} drifted")
    if catalog.get("unavailable"):
        raise ValueError("catalog contains unavailable apps")
    apps = catalog.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("catalog app list is empty or invalid")
    by_id: dict[str, dict] = {}
    for app in apps:
        if not isinstance(app, dict) or not isinstance(app.get("id"), str):
            raise ValueError("catalog app entry is invalid")
        if app["id"] in by_id:
            raise ValueError("catalog contains duplicate app id")
        by_id[app["id"]] = app

    if selection_path is None:
        optional = profile["default"]
    else:
        request, _ = _read(selection_path, "selection")
        if set(request) != {"schema", "selected_optional_apps"}:
            raise ValueError("selection keys are invalid")
        if request.get("schema") != "airlock.gui-selection/v1":
            raise ValueError("selection schema is invalid")
        optional = request.get("selected_optional_apps")
        if not isinstance(optional, list) or any(not isinstance(item, str) for item in optional):
            raise ValueError("selected_optional_apps must be a string list")
        if len(optional) != len(set(optional)):
            raise ValueError("selected_optional_apps contains a duplicate")

    reserved = set(profile["always"]) | set(profile["required"])
    bad_reserved = sorted(set(optional) & reserved)
    if bad_reserved:
        raise ValueError("selection directly names locked app(s): " + ", ".join(bad_reserved))
    unknown = sorted(set(optional) - set(by_id))
    if unknown:
        raise ValueError("selection names unknown app(s): " + ", ".join(unknown))
    unsupported = []
    for app_id in optional:
        limits = by_id[app_id].get("arch") or []
        if not isinstance(limits, list) or any(not isinstance(item, str) for item in limits):
            raise ValueError(f"catalog architecture list is invalid: {app_id}")
        if limits and target_arch not in limits:
            unsupported.append(app_id)
    if unsupported:
        raise ValueError(
            "selection is unsupported on this architecture: " + ", ".join(sorted(unsupported))
        )
    install = sorted(set(profile["required"]) | set(optional))
    return source_sha, install, source_epoch


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print("usage: gui_selection.py MANIFEST PROFILE CATALOG SELECTION|- ARCH", file=sys.stderr)
        return 2
    selection = None if argv[4] == "-" else pathlib.Path(argv[4])
    try:
        source_sha, install, source_epoch = validate(
            pathlib.Path(argv[1]), pathlib.Path(argv[2]), pathlib.Path(argv[3]), selection, argv[5]
        )
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    print(source_sha)
    print(",".join(install))
    print(source_epoch)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
