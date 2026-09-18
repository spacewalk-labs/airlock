#!/usr/bin/env python3
"""Live-box entry boundary regression fixture.

All product invocations are bound to temporary HOME/state/render/checkout roots and
command shims.  Nothing in this fixture invokes an installed Airlock clone or a real
systemd, Tailscale, nginx, Docker, or service mutation.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from typing import Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install" / "airlock-install.sh"
UPDATER = ROOT / "bin" / "airlock-update"
FIXTURE_MARKER = ".airlock-live-box-fixture-v1"
FIXTURE_MARKER_CONTENT = "airlock.live-box-fixture/v1\n"


def run(
    argv: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    full_env = os.environ.copy()
    full_env.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    if env:
        full_env.update(env)
    return subprocess.run(
        list(argv),
        cwd=cwd or ROOT,
        env=full_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def fixture_lease_env(root: Path) -> dict[str, str]:
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    marker = root / FIXTURE_MARKER
    marker.write_text(FIXTURE_MARKER_CONTENT, encoding="ascii")
    marker.chmod(0o600)
    return {
        "AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR": os.fspath(root / "airlock-live-box")
    }


def fixture_mutation_env(root: Path, state: Path, home: Path) -> dict[str, str]:
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    home.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    shims = root / "shims"
    shims.mkdir(exist_ok=True)
    for command in ("sudo", "systemctl", "systemd-run", "tailscale"):
        write_executable(shims / command, "#!/usr/bin/env bash\nexit 0\n")
    return {
        "HOME": os.fspath(home),
        "AIRLOCK_STATE_DIR": os.fspath(state),
        "AIRLOCK_WEBROOT": os.fspath(root / "webroot"),
        "AIRLOCK_CONFD": os.fspath(root / "confd"),
        "AIRLOCK_NGINX_SITE": os.fspath(root / "nginx" / "airlock.conf"),
        "AIRLOCK_UNIT_DIR_USER": os.fspath(root / "units-user"),
        "AIRLOCK_UNIT_DIR_SYSTEM": os.fspath(root / "units-system"),
        "PATH": os.fspath(shims) + os.pathsep + os.environ.get("PATH", ""),
        **fixture_lease_env(root),
    }


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def fingerprint(root: Path) -> tuple[tuple[object, ...], ...]:
    if not root.exists() and not root.is_symlink():
        return ()
    rows: list[tuple[object, ...]] = []
    paths = [root, *sorted(root.rglob("*"))]
    for path in paths:
        info = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        mode = stat.S_IMODE(info.st_mode)
        if path.is_symlink():
            rows.append((relative, "symlink", mode, info.st_uid, info.st_gid, os.readlink(path)))
        elif path.is_file():
            rows.append(
                (relative, "file", mode, info.st_uid, info.st_gid, info.st_size, digest(path))
            )
        elif path.is_dir():
            rows.append((relative, "dir", mode, info.st_uid, info.st_gid))
        else:
            rows.append((relative, "other", mode, info.st_uid, info.st_gid))
    return tuple(rows)


def git(argv: Sequence[str], directory: Path, env: Mapping[str, str]) -> None:
    result = run(["git", "-C", os.fspath(directory), *argv], env=env)
    if result.returncode:
        raise AssertionError(f"git {' '.join(argv)} failed: {result.stderr}")


def seed_release_tree(directory: Path, marker: str) -> None:
    for relative in ("bin", "install", "docker"):
        (directory / relative).mkdir(parents=True, exist_ok=True)
    write_executable(directory / "bin" / "airlock-config", "#!/bin/sh\nexit 0\n")
    write_executable(directory / "install" / "airlock-install.sh", "#!/bin/sh\nexit 0\n")
    write_executable(directory / "docker" / "orbstack-machine-setup.sh", "#!/bin/sh\nexit 0\n")
    (directory / "README.md").write_text(f"release {marker}\n", encoding="utf-8")


def installer_mutant(path: Path, injected: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    source = INSTALLER.read_text(encoding="utf-8")
    boundary = "# Classify the complete argv before sourcing helpers or looking at live state."
    if source.count(boundary) != 1:
        raise AssertionError("installer mutation boundary changed")
    path.write_text(source.replace(boundary, injected + "\n\n" + boundary), encoding="utf-8")
    return path


def fixture_boundary_mutant(source: Path, target: Path, call: str) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    value = source.read_text(encoding="utf-8")
    if value.count(call) != 1:
        raise AssertionError(f"fixture boundary mutation call changed in {source}")
    replacement = (
        'printf "%s\\n" boundary-bypassed > "${AIRLOCK_FIXTURE_NEGATIVE_SENTINEL:?}"\n'
        "exit 0"
    )
    target.write_text(value.replace(call, replacement), encoding="utf-8")
    return target


def probe_fixture_boundary(scratch: Path) -> dict[str, int]:
    scratch.mkdir(mode=0o700)
    fixture_lease_env(scratch)
    home = scratch / "home"
    state = scratch / "state"
    checkout = scratch / "checkout"
    for path in (home, state):
        path.mkdir()
    seed_release_tree(checkout, "fixture-boundary")
    common = {
        "HOME": os.fspath(home),
        "AIRLOCK_STATE_DIR": os.fspath(state),
        **fixture_lease_env(scratch),
    }

    installer_sentinel = scratch / "installer-mutated"
    installer_env = {
        **common,
        "AIRLOCK_FIXTURE_NEGATIVE_SENTINEL": os.fspath(installer_sentinel),
    }
    installer_result = run(["bash", os.fspath(INSTALLER)], env=installer_env)
    installer_pre_effect = int(installer_sentinel.exists())
    installer_mutated = fixture_boundary_mutant(
        INSTALLER,
        scratch / "mutants" / "install" / "airlock-install.sh",
        '_airlock_fixture_boundary "$_airlock_fixture_mode" \\\n'
        '  || _airlock_arg_die "unsafe fixture execution refused before live effects"',
    )
    installer_negative = run(["bash", os.fspath(installer_mutated)], env=installer_env)

    updater_sentinel = scratch / "updater-mutated"
    updater_env = {
        **common,
        "HOME": "/var/empty",
        "AIRLOCK_DIR": os.fspath(checkout),
        "AIRLOCK_FIXTURE_NEGATIVE_SENTINEL": os.fspath(updater_sentinel),
    }
    updater_result = run(["bash", os.fspath(UPDATER)], env=updater_env)
    updater_pre_effect = int(updater_sentinel.exists())
    updater_mutated = fixture_boundary_mutant(
        UPDATER,
        scratch / "mutants" / "bin" / "airlock-update",
        'fixture_boundary "$ROOT" "$dry" "$machine" \\\n'
        '    || die "unsafe fixture execution refused before live effects"',
    )
    updater_negative = run(["bash", os.fspath(updater_mutated)], env=updater_env)
    return {
        "installer_refuses": int(
            installer_result.returncode != 0
            and "unsafe fixture execution refused before live effects" in installer_result.stderr
        ),
        "updater_refuses": int(
            updater_result.returncode != 0
            and "unsafe fixture execution refused before live effects" in updater_result.stderr
        ),
        "pre_effect_mutations": installer_pre_effect + updater_pre_effect,
        "product_mutants_detected": int(
            installer_negative.returncode == 0 and installer_sentinel.exists()
        )
        + int(updater_negative.returncode == 0 and updater_sentinel.exists()),
    }


def nginx_site(*, publish: bool = True, gate: bool = True, api_gates: int = 0) -> str:
    """`api_gates` = the `/publish/api/...` locations render-nginx.sh adds since #441,
    each repeating the selector gate line (the real shape; F3, 2026-09-16)."""
    value = "server {\n    listen 127.0.0.1:19902;\n}\n"
    if publish:
        value += (
            "# ==== Publish dedicated document-view gate ====\n"
            "server {\n"
            "    listen 127.0.0.1:19925;\n"
            + ("    if ($hub_ok = 0) { return 403; }\n" if gate else "")
            + "".join(
                f"    location ~ ^/publish/api/route{i}$ {{\n"
                "        if ($hub_ok = 0) { return 403; }\n"
                "    }\n"
                for i in range(api_gates)
            )
            + "}\n"
            "# ==== End publish dedicated document-view gate ====\n"
        )
    return value


def run_nginx_continuity(
    library: Path, current: Path, candidate: Path
) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "bash",
            "-c",
            '. "$1"; airlock_require_nginx_publish_continuity "$2" "$3" 1 19925 hub_ok',
            "airlock-nginx-continuity",
            os.fspath(library),
            os.fspath(current),
            os.fspath(candidate),
        ]
    )


def extract_shell_function(source: str, name: str) -> str:
    start = source.index(f"{name}() {{")
    end = source.index("\n}\n", start) + len("\n}\n")
    return source[start:end]


def run_shell_function(
    source: str,
    invocation: str,
    *,
    args: Sequence[str] = (),
    env: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return run(
        ["bash", "-c", f"set -u\n{source}\n{invocation}", "airlock-pure-guard", *args],
        env=env,
    )


def nginx_canonical_call_order(source: str) -> bool:
    try:
        definition = source.index("_airlock_canonical_nginx_site() {")
        call = source.index(
            'NGINX_SITE="$(_airlock_canonical_nginx_site "$NGINX_SITE")"',
            definition,
        )
        export = source.index("export AIRLOCK_WEBROOT AIRLOCK_CONFD AIRLOCK_NGINX_SITE", call)
        owner_prewrite = source.index("# AIRLOCK_OWNER_CONTINUITY_PREWRITE", export)
        publish_guard = source.index("airlock_require_nginx_publish_continuity", owner_prewrite)
        copy = source.index('airlock_run sudo cp "$tmp" "$NGINX_SITE"', publish_guard)
    except ValueError:
        return False
    return definition < call < export < owner_prewrite < publish_guard < copy


def probe_nginx_publish_guard(scratch: Path) -> dict[str, int]:
    scratch.mkdir(mode=0o700)
    current = scratch / "current.conf"
    candidate = scratch / "candidate.conf"
    missing = scratch / "missing.conf"
    ungated = scratch / "ungated.conf"
    current.write_text(nginx_site(), encoding="utf-8")
    candidate.write_text(nginx_site(), encoding="utf-8")
    missing.write_text(nginx_site(publish=False), encoding="utf-8")
    ungated.write_text(nginx_site(gate=False), encoding="utf-8")
    real_shape = scratch / "real-shape.conf"
    real_shape.write_text(nginx_site(gate=False, api_gates=2), encoding="utf-8")
    before = fingerprint(current)

    admitted = run_nginx_continuity(ROOT / "install" / "lib.sh", current, candidate)
    missing_result = run_nginx_continuity(ROOT / "install" / "lib.sh", current, missing)
    ungated_result = run_nginx_continuity(ROOT / "install" / "lib.sh", current, ungated)
    real_shape_result = run_nginx_continuity(ROOT / "install" / "lib.sh", current, real_shape)

    library_source = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
    function_start = library_source.index("airlock_require_nginx_publish_continuity() {")
    function_end = library_source.index("\n}\n", function_start) + len("\n}\n")
    mutant_library = scratch / "mutant-lib.sh"
    mutant_library.write_text(
        library_source[:function_start]
        + "airlock_require_nginx_publish_continuity() { return 0; }\n"
        + library_source[function_end:],
        encoding="utf-8",
    )
    mutant_missing = run_nginx_continuity(mutant_library, current, missing)
    mutant_ungated = run_nginx_continuity(mutant_library, current, ungated)

    installer_source = INSTALLER.read_text(encoding="utf-8")
    canonical_name = "_airlock_canonical_nginx_site"
    canonical_function = extract_shell_function(installer_source, canonical_name)
    live_alias = run_shell_function(
        canonical_function,
        f'{canonical_name} "$1"',
        args=("/etc/nginx/conf.d/./airlock.conf",),
    )
    real_parent = scratch / "real-parent"
    real_parent.mkdir()
    parent_alias = scratch / "parent-alias"
    parent_alias.symlink_to(real_parent, target_is_directory=True)
    parent_alias_path = parent_alias / "airlock.conf"
    parent_alias_result = run_shell_function(
        canonical_function,
        f'{canonical_name} "$1"',
        args=(os.fspath(parent_alias_path),),
    )
    final_target = real_parent / "target.conf"
    final_target.write_text(nginx_site(), encoding="utf-8")
    final_symlink = real_parent / "final-link.conf"
    final_symlink.symlink_to(final_target)
    final_symlink_result = run_shell_function(
        canonical_function,
        f'{canonical_name} "$1"',
        args=(os.fspath(final_symlink),),
    )
    snapshot_function = extract_shell_function(installer_source, "_airlock_snapshot_nginx_site")
    final_symlink_snapshot = run_shell_function(
        snapshot_function,
        '_airlock_snapshot_nginx_site "$1" "$2"',
        args=(os.fspath(final_symlink), os.fspath(scratch / "symlink.snapshot")),
    )
    alias_mutant = run_shell_function(
        f'{canonical_name}() {{ printf "%s\\n" "$1"; }}',
        f'{canonical_name} "$1"',
        args=("/etc/nginx/conf.d/./airlock.conf",),
    )
    parent_alias_mutant = run_shell_function(
        f'{canonical_name}() {{ printf "%s\\n" "$1"; }}',
        f'{canonical_name} "$1"',
        args=(os.fspath(parent_alias_path),),
    )
    final_symlink_mutant = run_shell_function(
        f'{canonical_name}() {{ readlink -f -- "$1"; }}',
        f'{canonical_name} "$1"',
        args=(os.fspath(final_symlink),),
    )
    fixture_name = "_airlock_fixture_boundary"
    fixture_function = extract_shell_function(installer_source, fixture_name)
    fixture_root = scratch / "sealed-fixture"
    fixture_env = fixture_mutation_env(
        fixture_root,
        fixture_root / "state",
        fixture_root / "home",
    )
    fixture_admitted = run_shell_function(
        fixture_function,
        f"{fixture_name} mutate",
        env=fixture_env,
    )
    root_refusals = []
    root_mutants = []
    for key in ("AIRLOCK_WEBROOT", "AIRLOCK_CONFD", "AIRLOCK_NGINX_SITE"):
        missing_root_env = dict(fixture_env)
        missing_root_env.pop(key)
        root_refusals.append(
            run_shell_function(
                fixture_function,
                f"{fixture_name} mutate",
                env=missing_root_env,
            ).returncode
            != 0
        )
        root_mutants.append(
            run_shell_function(
                f"{fixture_name}() {{ return 0; }}",
                f"{fixture_name} mutate",
                env=missing_root_env,
            ).returncode
            == 0
        )
    source = installer_source
    canonical_definition_at = source.index(f"{canonical_name}() {{")
    canonical_call_at = source.index(
        'NGINX_SITE="$(_airlock_canonical_nginx_site "$NGINX_SITE")"',
        canonical_definition_at,
    )
    fixture_call_at = source.index('_airlock_fixture_boundary "$_airlock_fixture_mode"')
    target_log_at = source.index("verified fixture targets before effects", fixture_call_at)
    root_at = source.index('HERE="$(cd "$(dirname "$0")" && pwd)"', target_log_at)
    recovery_at = source.index("# Never trust caller markers", root_at)
    render_at = source.index('bash "$ROOT/install/render-nginx.sh" > "$tmp"')
    guard_at = source.index("airlock_require_nginx_publish_continuity", render_at)
    copy_at = source.index('airlock_run sudo cp "$tmp" "$NGINX_SITE"', guard_at)
    reload_at = source.index("airlock_run sudo systemctl reload nginx", copy_at)
    product_mutants_detected = int(mutant_missing.returncode == 0) + int(
        mutant_ungated.returncode == 0
    )
    canonical_call_removed = source.replace(
        'NGINX_SITE="$(_airlock_canonical_nginx_site "$NGINX_SITE")" \\\n  || die "cannot canonicalize nginx output path"\n',
        "",
        1,
    )
    canonical_mutants_detected = (
        int(alias_mutant.stdout.strip() != "/etc/nginx/conf.d/airlock.conf")
        + int(parent_alias_mutant.stdout.strip() != os.fspath(real_parent / "airlock.conf"))
        + int(final_symlink_mutant.stdout.strip() != os.fspath(final_symlink))
        + int(not nginx_canonical_call_order(canonical_call_removed))
    )
    return {
        "continuity_admits": int(admitted.returncode == 0),
        "missing_listen_refuses": int(
            missing_result.returncode != 0 and "19925" in missing_result.stderr
        ),
        "missing_gate_refuses": int(
            ungated_result.returncode != 0 and "publish gate" in ungated_result.stderr
        ),
        "real_render_shape_admits": int(real_shape_result.returncode == 0),
        "sealed_live_roots": sum(root_refusals),
        "root_mutants_detected": sum(root_mutants),
        "fixture_boundary_admits": int(fixture_admitted.returncode == 0),
        "live_alias_canonicalizes": int(
            live_alias.returncode == 0
            and live_alias.stdout.strip() == "/etc/nginx/conf.d/airlock.conf"
        ),
        "parent_alias_canonicalizes": int(
            parent_alias_result.returncode == 0
            and parent_alias_result.stdout.strip() == os.fspath(real_parent / "airlock.conf")
        ),
        "final_symlink_preserved": int(
            final_symlink_result.returncode == 0
            and final_symlink_result.stdout.strip() == os.fspath(final_symlink)
        ),
        "final_symlink_refuses": int(final_symlink_snapshot.returncode != 0),
        "canonical_call_order": int(
            canonical_definition_at < canonical_call_at
            and nginx_canonical_call_order(source)
        ),
        "current_unchanged": int(before == fingerprint(current)),
        "call_order": int(
            fixture_call_at < target_log_at < root_at < recovery_at
            and render_at < guard_at < copy_at < reload_at
        ),
        "product_mutants_detected": product_mutants_detected,
        "canonical_mutants_detected": canonical_mutants_detected,
    }


def canonical_owner_map(owner: str) -> str:
    return (
        "map $http_tailscale_user_login $owner_ok {\n"
        "    default 0;\n"
        f'    "{owner}" 1;\n'
        "}\n"
    )


def owner_v1_unit(owner: str) -> str:
    return f"# airlock-owner-v1 owner={owner}\n{canonical_owner_map(owner)}"


def owner_site(owner: str, *, sentinel: bool = True) -> str:
    owner_unit = owner_v1_unit(owner) if sentinel else canonical_owner_map(owner)
    return (
        owner_unit
        + "map $owner_ok $airlock_role {\n"
        "    default guest;\n"
        "    1 owner;\n"
        "}\n"
        "server { listen 127.0.0.1:19902; }\n"
    )


def run_owner_continuity(
    library: Path,
    current: Path,
    present: bool,
    snapshot_owner: str,
    transfer_from: str = "",
    candidate: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "bash",
            "-c",
            '. "$1"; airlock_require_nginx_owner_continuity "$2" "$3" "$4" "$5" "$6"',
            "airlock-owner-continuity",
            os.fspath(library),
            os.fspath(current),
            "1" if present else "0",
            snapshot_owner,
            transfer_from,
            os.fspath(candidate) if candidate is not None else "",
        ]
    )


def owner_call_orders(source: str) -> tuple[bool, bool]:
    try:
        pre_marker = source.index("# AIRLOCK_OWNER_CONTINUITY_PREWRITE")
        pre_call = source.index("airlock_require_nginx_owner_continuity", pre_marker)
        dry_write = source.index('install -d "$WEBROOT/assets"', pre_call)
        live_write = source.index('airlock_run sudo mkdir -p "$WEBROOT/assets"', pre_call)
        render = source.index('bash "$ROOT/install/render-nginx.sh" > "$tmp"')
        final_snapshot = source.index("# Re-snapshot at the last responsible moment", render)
        final_snapshot_call = source.index("_airlock_snapshot_nginx_site", final_snapshot)
        publish_guard = source.index("airlock_require_nginx_publish_continuity", final_snapshot)
        final_marker = source.index("# AIRLOCK_OWNER_CONTINUITY_PRECOPY", publish_guard)
        final_call = source.index("airlock_require_nginx_owner_continuity", final_marker)
        copy = source.index('airlock_run sudo cp "$tmp" "$NGINX_SITE"', final_call)
    except ValueError:
        return False, False
    binding = (
        source.count("airlock_require_nginx_owner_continuity") == 2
        and '"$_airlock_snapshot_owner" "$_airlock_transfer_owner_from"'
        in source[pre_call:dry_write]
        and '"$_airlock_snapshot_owner" "$_airlock_transfer_owner_from" "$tmp"'
        in source[final_call:copy]
        and '"$NGINX_SITE" "$_airlock_owner_site_snapshot"'
        in source[final_snapshot_call:publish_guard]
    )
    prewrite = (
        binding
        and pre_marker < pre_call < dry_write
        and pre_call < live_write
    )
    precopy = binding and render < final_snapshot < publish_guard < final_marker < final_call < copy
    return prewrite, precopy


def owner_call_order(source: str) -> bool:
    return all(owner_call_orders(source))


def probe_owner_continuity(scratch: Path) -> dict[str, int]:
    scratch.mkdir(mode=0o700)
    library = ROOT / "install" / "lib.sh"
    render_source = (ROOT / "install" / "render-nginx.sh").read_text(encoding="utf-8")
    library_source = library.read_text(encoding="utf-8")

    empty = scratch / "absent.snapshot"
    legacy = scratch / "legacy.conf"
    sentinel_same = scratch / "sentinel-same.conf"
    sentinel_old = scratch / "sentinel-old.conf"
    sentinel_intruder = scratch / "sentinel-intruder.conf"
    sentinel_mismatch = scratch / "sentinel-mismatch.conf"
    v1_duplicate = scratch / "v1-duplicate.conf"
    legacy_duplicate = scratch / "legacy-duplicate.conf"
    v1_noncanonical_overlay = scratch / "v1-noncanonical-overlay.conf"
    current_tamper = scratch / "current-tamper.conf"
    current_noncanonical = scratch / "current-noncanonical.conf"
    candidate_new = scratch / "candidate-new.conf"
    candidate_tamper = scratch / "candidate-tamper.conf"
    candidate_noncanonical = scratch / "candidate-noncanonical.conf"
    candidate_legacy = scratch / "candidate-legacy.conf"
    candidate_wrong_owner = scratch / "candidate-wrong-owner.conf"
    candidate_duplicate = scratch / "candidate-duplicate.conf"
    candidate_noncanonical_overlay = scratch / "candidate-noncanonical-overlay.conf"
    promoted = scratch / "promoted.conf"

    golden_render = ROOT / "install" / "golden" / "equivalence-render.txt"
    golden_value = golden_render.read_text(encoding="utf-8")
    golden_sentinel = "# airlock-owner-v1 owner=owner@fixture.dev\n"
    if golden_value.count(golden_sentinel) != 1:
        raise AssertionError("equivalence render golden lacks one owner-v1 sentinel")

    empty.write_text("", encoding="utf-8")
    legacy.write_text(golden_value.replace(golden_sentinel, "", 1), encoding="utf-8")
    sentinel_same.write_text(owner_site("new@example.com"), encoding="utf-8")
    sentinel_old.write_text(owner_site("old@example.com"), encoding="utf-8")
    sentinel_intruder.write_text(owner_site("intruder@example.com"), encoding="utf-8")
    sentinel_mismatch.write_text(
        owner_site("old@example.com").replace(
            canonical_owner_map("old@example.com"),
            canonical_owner_map("new@example.com"),
            1,
        ),
        encoding="utf-8",
    )
    v1_duplicate.write_text(
        owner_site("new@example.com") + canonical_owner_map("other@example.com"),
        encoding="utf-8",
    )
    legacy_duplicate.write_text(
        owner_site("new@example.com", sentinel=False)
        + canonical_owner_map("other@example.com"),
        encoding="utf-8",
    )
    current_tamper.write_text(
        owner_site("new@example.com").replace("    default 0;", "    default  0;", 1),
        encoding="utf-8",
    )
    noncanonical_map = (
        'map $http_tailscale_user_login $owner_ok { default 0; "new@example.com" 1; }\n'
    )
    current_noncanonical.write_text(
        noncanonical_map + "server { listen 127.0.0.1:19902; }\n",
        encoding="utf-8",
    )
    v1_noncanonical_overlay.write_text(
        owner_site("new@example.com") + noncanonical_map,
        encoding="utf-8",
    )
    candidate_new.write_text(owner_site("new@example.com"), encoding="utf-8")
    candidate_tamper.write_text(current_tamper.read_text(encoding="utf-8"), encoding="utf-8")
    candidate_noncanonical.write_text(
        "# airlock-owner-v1 owner=new@example.com\n"
        + noncanonical_map
        + "server { listen 127.0.0.1:19902; }\n",
        encoding="utf-8",
    )
    candidate_legacy.write_text(owner_site("new@example.com", sentinel=False), encoding="utf-8")
    candidate_wrong_owner.write_text(owner_site("old@example.com"), encoding="utf-8")
    candidate_duplicate.write_text(v1_duplicate.read_text(encoding="utf-8"), encoding="utf-8")
    candidate_noncanonical_overlay.write_text(
        v1_noncanonical_overlay.read_text(encoding="utf-8"), encoding="utf-8"
    )
    promoted.write_text(golden_value, encoding="utf-8")

    watched_inputs = (
        empty,
        legacy,
        sentinel_same,
        sentinel_old,
        sentinel_intruder,
        sentinel_mismatch,
        v1_duplicate,
        legacy_duplicate,
        v1_noncanonical_overlay,
        current_tamper,
        current_noncanonical,
        candidate_new,
        candidate_tamper,
        candidate_noncanonical,
        candidate_legacy,
        candidate_wrong_owner,
        candidate_duplicate,
        candidate_noncanonical_overlay,
        promoted,
    )
    before = {os.fspath(item): fingerprint(item) for item in watched_inputs}

    emitter_source = (
        extract_shell_function(library_source, "airlock_emit_owner_v1_map")
        + "\n"
        + extract_shell_function(library_source, "airlock_emit_owner_v1_unit")
    )
    emitter_result = run_shell_function(
        emitter_source,
        'airlock_emit_owner_v1_unit "$1"',
        args=("new@example.com",),
    )

    def renderer_binding(value: str) -> bool:
        return (
            value.count('airlock_emit_owner_v1_unit "$AIRLOCK_OWNER"') == 1
            and 'emit_identity_map owner_ok "$AIRLOCK_OWNER"' not in value
        )

    renderer_contract = int(
        emitter_result.returncode == 0
        and emitter_result.stdout == owner_v1_unit("new@example.com")
        and renderer_binding(render_source)
    )

    first = run_owner_continuity(library, empty, False, "new@example.com")
    legacy_upgrade = run_owner_continuity(
        library,
        legacy,
        True,
        "owner@fixture.dev",
        candidate=golden_render,
    )
    promoted_result = run_owner_continuity(
        library, promoted, True, "owner@fixture.dev", candidate=golden_render
    )
    sentinel_same_result = run_owner_continuity(
        library, sentinel_same, True, "new@example.com", candidate=candidate_new
    )
    sentinel_mismatch_result = run_owner_continuity(
        library, sentinel_old, True, "new@example.com"
    )
    exact_transfer = run_owner_continuity(
        library,
        sentinel_old,
        True,
        "new@example.com",
        "old@example.com",
        candidate_new,
    )
    transfer_refusals = (
        run_owner_continuity(
            library, empty, False, "new@example.com", "old@example.com"
        ),
        run_owner_continuity(
            library, sentinel_old, True, "new@example.com", "wrong@example.com"
        ),
        run_owner_continuity(
            library, sentinel_same, True, "new@example.com", "new@example.com"
        ),
    )
    exact_block_tamper = (
        run_owner_continuity(library, current_tamper, True, "new@example.com"),
        run_owner_continuity(
            library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_tamper,
        ),
    )
    noncanonical = (
        run_owner_continuity(library, current_noncanonical, True, "new@example.com"),
        run_owner_continuity(
            library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_noncanonical,
        ),
    )
    legacy_candidate = run_owner_continuity(
        library,
        sentinel_same,
        True,
        "new@example.com",
        candidate=candidate_legacy,
    )
    sentinel_map_mismatch = run_owner_continuity(
        library, sentinel_mismatch, True, "old@example.com"
    )
    candidate_wrong = run_owner_continuity(
        library,
        sentinel_same,
        True,
        "new@example.com",
        candidate=candidate_wrong_owner,
    )
    unique_owner_refusals = (
        run_owner_continuity(library, v1_duplicate, True, "new@example.com"),
        run_owner_continuity(library, legacy_duplicate, True, "new@example.com"),
        run_owner_continuity(
            library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_duplicate,
        ),
        run_owner_continuity(library, v1_noncanonical_overlay, True, "new@example.com"),
        run_owner_continuity(
            library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_noncanonical_overlay,
        ),
    )
    golden_same_current = run_owner_continuity(
        library, golden_render, True, "owner@fixture.dev"
    )
    golden_same_candidate = run_owner_continuity(
        library, golden_render, True, "owner@fixture.dev", candidate=golden_render
    )
    golden_different_current = run_owner_continuity(
        library, golden_render, True, "other@example.com"
    )
    golden_different_candidate = run_owner_continuity(
        library, sentinel_same, True, "new@example.com", candidate=golden_render
    )

    snapshot_source = extract_shell_function(
        INSTALLER.read_text(encoding="utf-8"), "_airlock_snapshot_nginx_site"
    )
    race_current = scratch / "race-current.conf"
    race_first_snapshot = scratch / "race-first.snapshot"
    race_final_snapshot = scratch / "race-final.snapshot"
    race_current.write_text(owner_site("old@example.com"), encoding="utf-8")
    race_pre_snapshot = run_shell_function(
        snapshot_source,
        '_airlock_snapshot_nginx_site "$1" "$2"',
        args=(os.fspath(race_current), os.fspath(race_first_snapshot)),
    )
    pre_toctou = run_owner_continuity(
        library, race_first_snapshot, True, "new@example.com", "old@example.com"
    )
    race_current.write_text(owner_site("intruder@example.com"), encoding="utf-8")
    race_post_snapshot = run_shell_function(
        snapshot_source,
        '_airlock_snapshot_nginx_site "$1" "$2"',
        args=(os.fspath(race_current), os.fspath(race_final_snapshot)),
    )
    post_toctou = run_owner_continuity(
        library,
        race_final_snapshot,
        True,
        "new@example.com",
        "old@example.com",
        candidate_new,
    )
    stale_toctou = run_owner_continuity(
        library,
        race_first_snapshot,
        True,
        "new@example.com",
        "old@example.com",
        candidate_new,
    )

    function_start = library_source.index("airlock_require_nginx_owner_continuity() {")
    function_end = library_source.index("\n}\n", function_start) + len("\n}\n")

    def mutant_library(name: str, value: str) -> Path:
        mutant = scratch / name
        mutant.write_text(value, encoding="utf-8")
        return mutant

    bypass_library = mutant_library(
        "bypass-lib.sh",
        library_source[:function_start]
        + "airlock_require_nginx_owner_continuity() { return 0; }\n"
        + library_source[function_end:],
    )
    deny_library = mutant_library(
        "deny-lib.sh",
        library_source[:function_start]
        + "airlock_require_nginx_owner_continuity() { return 1; }\n"
        + library_source[function_end:],
    )
    exact_library_source = library_source.replace(
        "    if exact_count(value, canonical_unit(owner)) != 1 \\\n"
        "            or exact_count(value, canonical_map(owner)) != 1:\n",
        "    if False:\n",
        1,
    )
    exact_library = mutant_library("exact-lib.sh", exact_library_source)
    legacy_library_source = library_source.replace(
        "        if exact_count(current_value, canonical_map(current_owner)) != 1:\n",
        "        if False:\n",
        1,
    )
    legacy_library = mutant_library("legacy-lib.sh", legacy_library_source)
    candidate_library_source = library_source.replace(
        "if candidate_raw:\n", "if False and candidate_raw:\n", 1
    )
    candidate_library = mutant_library("candidate-lib.sh", candidate_library_source)
    transfer_library_source = library_source.replace(
        "    elif transfer_from != current_owner:\n", "    elif False:\n", 1
    )
    transfer_library = mutant_library("transfer-lib.sh", transfer_library_source)
    candidate_owner_source = library_source.replace(
        "    if candidate_owner != snapshot_owner:\n", "    if False:\n", 1
    )
    candidate_owner_library = mutant_library("candidate-owner-lib.sh", candidate_owner_source)
    unique_header_source = library_source.replace(
        "    if value.count(OWNER_MAP_HEADER) != 1:\n",
        "    if False:\n",
        1,
    )
    unique_header_library = mutant_library("unique-header-lib.sh", unique_header_source)
    unique_header_mutants_detected = 0
    if unique_header_source != library_source:
        unique_header_mutants_detected = sum(
            item.returncode == 0
            for item in (
                run_owner_continuity(
                    unique_header_library, v1_duplicate, True, "new@example.com"
                ),
                run_owner_continuity(
                    unique_header_library, legacy_duplicate, True, "new@example.com"
                ),
                run_owner_continuity(
                    unique_header_library,
                    sentinel_same,
                    True,
                    "new@example.com",
                    candidate=candidate_duplicate,
                ),
                run_owner_continuity(
                    unique_header_library,
                    v1_noncanonical_overlay,
                    True,
                    "new@example.com",
                ),
                run_owner_continuity(
                    unique_header_library,
                    sentinel_same,
                    True,
                    "new@example.com",
                    candidate=candidate_noncanonical_overlay,
                ),
            )
        )
    renderer_mutant = render_source.replace(
        'airlock_emit_owner_v1_unit "$AIRLOCK_OWNER"',
        'airlock_emit_owner_v1_map "$AIRLOCK_OWNER"',
        1,
    )

    semantic_mutants = (
        run_owner_continuity(
            bypass_library, current_tamper, True, "new@example.com"
        ).returncode
        == 0,
        run_owner_continuity(deny_library, empty, False, "new@example.com").returncode
        != 0,
        not renderer_binding(renderer_mutant),
        exact_library_source != library_source
        and run_owner_continuity(
            exact_library, sentinel_mismatch, True, "old@example.com"
        ).returncode
        == 0,
        legacy_library_source != library_source
        and run_owner_continuity(
            legacy_library, current_noncanonical, True, "new@example.com"
        ).returncode
        == 0,
        candidate_library_source != library_source
        and run_owner_continuity(
            candidate_library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_legacy,
        ).returncode
        == 0,
        transfer_library_source != library_source
        and run_owner_continuity(
            transfer_library, sentinel_old, True, "new@example.com"
        ).returncode
        == 0,
        candidate_owner_source != library_source
        and run_owner_continuity(
            candidate_owner_library,
            sentinel_same,
            True,
            "new@example.com",
            candidate=candidate_wrong_owner,
        ).returncode
        == 0,
        unique_header_mutants_detected == 5,
    )

    installer_source = INSTALLER.read_text(encoding="utf-8")
    pre_start = installer_source.index("# AIRLOCK_OWNER_CONTINUITY_PREWRITE")
    pre_end = installer_source.index(
        '\n\nif [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then', pre_start
    )
    pre_block = installer_source[pre_start:pre_end]
    without_pre = installer_source[:pre_start] + installer_source[pre_end:]
    pre_insert = without_pre.index('airlock_run sudo mkdir -p "$WEBROOT/assets"')
    pre_mutant = without_pre[:pre_insert] + pre_block + without_pre[pre_insert:]

    final_start = installer_source.index("  # AIRLOCK_OWNER_CONTINUITY_PRECOPY")
    final_end = installer_source.index(
        '  airlock_run sudo cp "$tmp" "$NGINX_SITE"', final_start
    )
    final_block = installer_source[final_start:final_end]
    without_final = installer_source[:final_start] + installer_source[final_end:]
    final_insert = without_final.index('  airlock_run sudo cp "$tmp" "$NGINX_SITE"')
    final_insert = without_final.index("\n", final_insert) + 1
    final_mutant = (
        without_final[:final_insert] + final_block + without_final[final_insert:]
    )
    prewrite_order, precopy_order = owner_call_orders(installer_source)
    pre_marker = installer_source.index("# AIRLOCK_OWNER_CONTINUITY_PREWRITE")
    pre_call = installer_source.index(
        "airlock_require_nginx_owner_continuity", pre_marker
    )

    return {
        "renderer_contract": renderer_contract,
        "first_install_admits": int(first.returncode == 0),
        "legacy_upgrade_admits": int(legacy_upgrade.returncode == 0),
        "legacy_promotes_to_v1": int(
            legacy_upgrade.returncode == 0
            and "# airlock-owner-v1" not in legacy.read_text(encoding="utf-8")
            and promoted_result.returncode == 0
            and promoted.read_text(encoding="utf-8").count(golden_sentinel) == 1
        ),
        "sentinel_same_owner_admits": int(sentinel_same_result.returncode == 0),
        "sentinel_mismatch_refuses": int(sentinel_mismatch_result.returncode != 0),
        "exact_transfer_admits": int(exact_transfer.returncode == 0),
        "transfer_refusals": sum(item.returncode != 0 for item in transfer_refusals),
        "exact_block_tamper_refusals": sum(
            item.returncode != 0 for item in exact_block_tamper
        ),
        "noncanonical_refusals": sum(item.returncode != 0 for item in noncanonical),
        "candidate_v1_required": int(legacy_candidate.returncode != 0),
        "unique_owner_refusals": sum(
            item.returncode != 0 for item in unique_owner_refusals
        ),
        "golden_full_render_same_owner": int(golden_same_current.returncode == 0)
        + int(golden_same_candidate.returncode == 0),
        "golden_full_render_different_owner": int(golden_different_current.returncode != 0)
        + int(golden_different_candidate.returncode != 0),
        "toctou_refuses": int(
            race_pre_snapshot.returncode == 0
            and race_pre_snapshot.stdout.strip() == "1"
            and pre_toctou.returncode == 0
            and race_post_snapshot.returncode == 0
            and race_post_snapshot.stdout.strip() == "1"
            and post_toctou.returncode != 0
        ),
        "inputs_unchanged": int(
            before == {os.fspath(item): fingerprint(item) for item in watched_inputs}
        ),
        "prewrite_call_order": int(prewrite_order),
        "precopy_call_order": int(precopy_order),
        "semantic_mutants_detected": sum(semantic_mutants),
        "unique_header_mutants_detected": unique_header_mutants_detected,
        "order_mutants_detected": int(not owner_call_order(pre_mutant))
        + int(not owner_call_order(final_mutant)),
        "resnapshot_mutants_detected": int(stale_toctou.returncode == 0),
        "explicit_path_bound": int(
            "--transfer-owner-from=*)" in installer_source
            and "--transfer-owner-from is accepted only by a full ordinary install"
            in installer_source
            and owner_call_order(installer_source)
        ),
        "argv_validation_pre_effect": int(
            installer_source.index("--transfer-owner-from must be one safe email-like login")
            < installer_source.index("# AIRLOCK_FIXTURE_BOUNDARY_CALL")
        ),
        "dry_preview_owner_neutral": int(
            '_airlock_owner_site_present=0' in installer_source[pre_marker:pre_call]
        ),
        "legacy_guards_removed": int(
            "_airlock_require_isolated_inputs_do_not_target_live" not in installer_source
            and "_airlock_require_nonlive_nginx_site_override" not in installer_source
        ),
    }


def probe_installer_entry(scratch: Path, installer: Path = INSTALLER) -> dict[str, int]:
    scratch.mkdir()
    home = scratch / "home"
    state = scratch / "state"
    shims = scratch / "shims"
    home.mkdir()
    state.mkdir()
    shims.mkdir()
    call_log = scratch / "calls.log"
    cgroup = scratch / "cgroup"
    cgroup.write_text(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/airlock-paseo.service\n",
        encoding="ascii",
    )
    write_executable(
        shims / "systemctl",
        "#!/usr/bin/env bash\n"
        f"printf 'systemctl %s\\n' \"$*\" >> {call_log!s}\n"
        "case \"$*\" in '--user show-environment') exit 0 ;; esac\n"
        "exit 0\n",
    )
    write_executable(
        shims / "systemd-run",
        "#!/usr/bin/env bash\n"
        f"printf 'systemd-run %s\\n' \"$*\" >> {call_log!s}\n"
        "exit 0\n",
    )
    write_executable(
        shims / "tailscale",
        "#!/usr/bin/env bash\n"
        f"printf 'tailscale %s\\n' \"$*\" >> {call_log!s}\n"
        "exit 0\n",
    )
    common = {
        "HOME": os.fspath(home),
        "PATH": os.fspath(shims) + os.pathsep + os.environ.get("PATH", ""),
        "AIRLOCK_STATE_DIR": os.fspath(state),
        "AIRLOCK_SELFKILL_CGROUP_FILE": os.fspath(cgroup),
        "AIRLOCK_SELFKILL_SYSTEMD_RUN": os.fspath(shims / "systemd-run"),
    }
    help_result = run(["bash", os.fspath(installer), "--help"], env=common)
    invalid_result = run(
        ["bash", os.fspath(installer), "--definitely-invalid"], env=common
    )

    config = scratch / "airlock.toml"
    config.write_text(
        '[airlock]\nconfig_version = 2\n'
        '[site]\nname = "Fixture"\n'
        '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\ncollaborators = []\n'
        '[agent]\nprovider = "claude"\n'
        '[paths]\nwiki = ""\n'
        '[apps.hub]\n',
        encoding="utf-8",
    )
    dry_state, dry_home, _transaction_id, transaction = make_transaction(
        scratch / "degraded-dry-run", "degraded"
    )
    live_web = Path(transaction["AIRLOCK_WEBROOT"])
    live_confd = Path(transaction["AIRLOCK_CONFD"])
    live_nginx = Path(transaction["AIRLOCK_NGINX_SITE"])
    dry_env = {
        **transaction,
        "PATH": os.fspath(shims) + os.pathsep + os.environ.get("PATH", ""),
        "HOME": os.fspath(dry_home),
        "AIRLOCK_DRY_RUN": "1",
        "AIRLOCK_CONFIG": os.fspath(config),
        "AIRLOCK_STATE_DIR": os.fspath(dry_state),
        "AIRLOCK_WEBROOT": os.fspath(live_web),
        "AIRLOCK_CONFD": os.fspath(live_confd),
        "AIRLOCK_TS_FQDN": "fixture.example.ts.net",
        "AIRLOCK_PASEO_MEM_CAP_BYTES": "34359738368",
    }
    watched = (
        fingerprint(dry_state),
        fingerprint(live_web),
        fingerprint(live_confd),
        fingerprint(live_nginx),
    )
    dry_result = run(["bash", os.fspath(installer)], env=dry_env)
    watched_after = (
        fingerprint(dry_state),
        fingerprint(live_web),
        fingerprint(live_confd),
        fingerprint(live_nginx),
    )

    calls = call_log.read_text(encoding="utf-8").splitlines() if call_log.exists() else []
    combined = "\n".join(
        (
            help_result.stdout,
            help_result.stderr,
            invalid_result.stdout,
            invalid_result.stderr,
            dry_result.stdout,
            dry_result.stderr,
        )
    )
    return {
        "help_contract": int(help_result.returncode == 0 and "airlock-install" in help_result.stdout),
        "invalid_contract": int(invalid_result.returncode != 0),
        "unit_creations": sum(line.startswith("systemd-run ") for line in calls),
        "service_mutations": sum(
            any(word in line for word in (" restart ", " start ", " stop ", " reload "))
            for line in calls
        ),
        "ingress_mutations": sum(
            line.startswith("tailscale serve ") and not line.startswith("tailscale serve status ")
            for line in calls
        ),
        "recovery_calls": combined.count("recovering unfinished install transaction"),
        "live_root_writes": int(watched != watched_after),
        "dry_run_completed": int(dry_result.returncode == 0),
    }


def probe_updater_entry(scratch: Path) -> dict[str, int]:
    scratch.mkdir()
    release = scratch / "release"
    box = scratch / "box"
    release.mkdir()
    box.mkdir()
    gitconfig = scratch / "gitconfig"
    git_env = {"GIT_CONFIG_GLOBAL": os.fspath(gitconfig)}
    run(["git", "config", "-f", os.fspath(gitconfig), "user.name", "airlock-test"])
    run(
        [
            "git",
            "config",
            "-f",
            os.fspath(gitconfig),
            "user.email",
            "airlock-test@localhost",
        ]
    )
    run(["git", "config", "-f", os.fspath(gitconfig), "init.defaultBranch", "main"])

    seed_release_tree(release, "old")
    git(["init", "-q", "-b", "main"], release, git_env)
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 1111111"], release, git_env)
    seed_release_tree(box, "old")
    git(["init", "-q", "-b", "main"], box, git_env)
    git(["add", "-A"], box, git_env)
    git(["commit", "-q", "-m", "installed fixture"], box, git_env)
    seed_release_tree(release, "new")
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 2222222"], release, git_env)

    before = fingerprint(box)
    help_result = run(["bash", os.fspath(UPDATER), "--help"], env=git_env)
    dry_result = run(
        ["bash", os.fspath(UPDATER), "--dry-run"],
        env={
            **git_env,
            "AIRLOCK_DIR": os.fspath(box),
            "AIRLOCK_RELEASE_URL": os.fspath(release),
        },
    )
    after = fingerprint(box)

    linked = scratch / "linked-worktree"
    git(["worktree", "add", "-q", "-b", "fixture-linked", os.fspath(linked)], box, git_env)
    (linked / "MY-NOTES.md").write_text("operator note\n", encoding="utf-8")
    git(["add", "MY-NOTES.md"], linked, git_env)
    git(["commit", "-q", "-m", "operator-owned note"], linked, git_env)
    release_head = run(["git", "-C", os.fspath(release), "rev-parse", "HEAD"], env=git_env)
    common_before = fingerprint(box / ".git")
    linked_before = fingerprint(linked)
    linked_dry = run(
        ["bash", os.fspath(UPDATER), "--dry-run", "--json"],
        env={
            **git_env,
            "AIRLOCK_DIR": os.fspath(linked),
            "AIRLOCK_RELEASE_URL": os.fspath(release),
        },
    )
    linked_changed = int(
        common_before != fingerprint(box / ".git")
        or linked_before != fingerprint(linked)
    )
    try:
        linked_value = json.loads(linked_dry.stdout)
    except json.JSONDecodeError:
        linked_value = {}
    linked_provenance = int(
        release_head.returncode == 0
        and linked_dry.returncode == 0
        and linked_value.get("available") is True
        and linked_value.get("ref") == release_head.stdout.strip()
    )
    return {
        "read_cases": 2,
        "help_contract": int(help_result.returncode == 0 and "airlock-update" in help_result.stdout),
        "dry_run_completed": int(dry_result.returncode == 0 and linked_provenance == 1),
        "checkout_writes": int(before != after) + linked_changed,
    }


def updater_lease_mutant(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    source = UPDATER.read_text(encoding="utf-8")
    marker = "    # AIRLOCK_UPDATE_LIVE_BOX_LEASE_CALL — the regression fixture mutates this boundary.\n"
    if source.count(marker) != 1:
        raise AssertionError("updater lease mutation boundary changed")
    injected = (
        '    printf "%s\\n" mutation-before-lease > '
        '"${AIRLOCK_STATE_DIR:?}/updater-before-lease"\n'
    )
    path.write_text(source.replace(marker, injected + marker), encoding="utf-8")
    path.chmod(0o755)
    return path


def probe_updater_lease_guard(scratch: Path, updater: Path = UPDATER) -> int:
    scratch.mkdir(mode=0o700)
    release = scratch / "release"
    box = scratch / "box"
    gitconfig = scratch / "gitconfig"
    git_env = {"GIT_CONFIG_GLOBAL": os.fspath(gitconfig)}
    run(["git", "config", "-f", os.fspath(gitconfig), "user.name", "airlock-test"])
    run(
        [
            "git",
            "config",
            "-f",
            os.fspath(gitconfig),
            "user.email",
            "airlock-test@localhost",
        ]
    )
    run(["git", "config", "-f", os.fspath(gitconfig), "init.defaultBranch", "main"])

    seed_release_tree(release, "old")
    git(["init", "-q", "-b", "main"], release, git_env)
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 1111111"], release, git_env)
    seed_release_tree(box, "old")
    for relative in ("bin/airlock-ledger", "install/lib.sh", "install/preflight.sh"):
        tool_copy = box / relative
        tool_copy.write_bytes((ROOT / relative).read_bytes())
    (box / "bin" / "airlock-ledger").chmod(0o755)
    git(["init", "-q", "-b", "main"], box, git_env)
    git(["add", "-A"], box, git_env)
    git(["commit", "-q", "-m", "installed fixture"], box, git_env)
    seed_release_tree(release, "new")
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 2222222"], release, git_env)

    state = scratch / "state"
    home = scratch / "home"
    fixture_tools = scratch / "trusted-update-tools"
    (fixture_tools / "bin").mkdir(parents=True)
    (fixture_tools / "install").mkdir()
    for relative in ("bin/airlock-ledger", "install/lib.sh", "install/preflight.sh"):
        (fixture_tools / relative).write_bytes((ROOT / relative).read_bytes())
    (fixture_tools / "bin" / "airlock-ledger").chmod(0o755)
    home.mkdir()
    neutral_cgroup = home / "fixture-cgroup"
    neutral_cgroup.write_text("0::/fixture.scope\n", encoding="ascii")
    environment = {
        **git_env,
        **fixture_mutation_env(scratch, state, home),
        "AIRLOCK_DIR": os.fspath(box),
        "AIRLOCK_RELEASE_URL": os.fspath(release),
        "AIRLOCK_LIVE_BOX_CARD": "fixture/UPDATER",
        "AIRLOCK_SELFKILL_CGROUP_FILE": os.fspath(neutral_cgroup),
        "AIRLOCK_FIXTURE_UPDATE_TOOLS_ROOT": os.fspath(fixture_tools),
    }
    watched_paths = (
        box,
        state,
        home,
        scratch / "webroot",
        scratch / "confd",
        scratch / "nginx",
    )
    before = {path: fingerprint(path) for path in watched_paths}
    forged = run(
        ["bash", os.fspath(updater), "--no-install"],
        env={
            **environment,
            "AIRLOCK_LIVE_BOX_LEASE_ID": "0" * 32,
            "AIRLOCK_LIVE_BOX_LEASE_FD": "999999",
            "AIRLOCK_LIVE_BOX_LEASE_RECORD": os.fspath(
                scratch / "forged" / "live-box-lease.json"
            ),
            "AIRLOCK_UPDATE_ACTIVE_LEASE_TOOLS_ROOT": os.fspath(scratch / "fake-tools"),
        },
    )
    forged_refused = int(
        forged.returncode != 0
        and before == {path: fingerprint(path) for path in watched_paths}
    )
    holder, _ready, held_until, _child_pid = start_lease_holder(
        scratch / "holder-updater", scratch
    )
    try:
        result = run(
            ["bash", os.fspath(updater), "--no-install"],
            env=environment,
        )
    finally:
        stop_lease_holder(holder, held_until)
    collision_refused = int(
        result.returncode != 0
        and "live box lease collision before mutation" in result.stderr
        and before == {path: fingerprint(path) for path in watched_paths}
        and not list(scratch.glob("airlock-update-lease.*"))
    )
    admitted = run(
        ["bash", os.fspath(updater), "--no-install"],
        env=environment,
    )
    streamed = run(
        [
            "bash",
            "-c",
            'bash -s -- --no-install < "$1"',
            "bash",
            os.fspath(updater),
        ],
        env=environment,
    )
    return int(
        forged_refused == 1
        and collision_refused == 1
        and admitted.returncode == 0
        and streamed.returncode == 0
        and (box / "README.md").read_text(encoding="utf-8") == "release new\n"
        and not (scratch / "airlock-live-box" / "live-box-lease.json").exists()
        and not list(scratch.glob("airlock-update-lease.*"))
    )


def probe_updater_selfkill_order(scratch: Path) -> int:
    scratch.mkdir(mode=0o700)
    release = scratch / "release"
    box = scratch / "box"
    tools = scratch / "tools"
    shims = scratch / "shims"
    home = scratch / "home"
    state = scratch / "state"
    calls = scratch / "calls"
    gitconfig = scratch / "gitconfig"
    git_env = {"GIT_CONFIG_GLOBAL": os.fspath(gitconfig)}
    for key, value in (("user.name", "airlock-test"), ("user.email", "airlock-test@localhost"),
                       ("init.defaultBranch", "main")):
        run(["git", "config", "-f", os.fspath(gitconfig), key, value])
    seed_release_tree(release, "old")
    git(["init", "-q", "-b", "main"], release, git_env)
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 1111111"], release, git_env)
    seed_release_tree(box, "old")
    git(["init", "-q", "-b", "main"], box, git_env)
    git(["add", "-A"], box, git_env)
    git(["commit", "-q", "-m", "installed fixture"], box, git_env)
    seed_release_tree(release, "new")
    installer_lease = scratch / "installer-lease"
    write_executable(
        release / "bin" / "airlock-config",
        "#!/usr/bin/env python3\nraise SystemExit(0)\n",
    )
    write_executable(
        release / "install" / "airlock-install.sh",
        "#!/usr/bin/env bash\n"
        'printf "%s %s\\n" "$AIRLOCK_LIVE_BOX_LEASE_ID" "$AIRLOCK_LIVE_BOX_LEASE_FD" '
        f"> {os.fspath(installer_lease)!r}\n"
        '"$AIRLOCK_FIXTURE_UPDATE_TOOLS_ROOT/bin/airlock-ledger" live-box-lease-require\n',
    )
    git(["add", "-A"], release, git_env)
    git(["commit", "-q", "-m", "release from fixture @ 2222222"], release, git_env)

    (tools / "bin").mkdir(parents=True)
    (tools / "install").mkdir()
    (tools / "bin" / "airlock-update").write_bytes(UPDATER.read_bytes())
    (tools / "install" / "lib.sh").write_bytes((ROOT / "install" / "lib.sh").read_bytes())
    (tools / "install" / "preflight.sh").write_bytes(
        (ROOT / "install" / "preflight.sh").read_bytes()
    )
    ledger_wrapper = (
        "#!/usr/bin/env bash\n"
        f"printf 'ledger-%s\\n' \"$1\" >> {os.fspath(calls)!r}\n"
        f"exec {os.fspath(ROOT / 'bin' / 'airlock-ledger')!r} \"$@\"\n"
        "# live-box-lease-require\n"
    )
    write_executable(tools / "bin" / "airlock-ledger", ledger_wrapper)
    (tools / "bin" / "airlock-update").chmod(0o755)

    fixture_env = fixture_mutation_env(scratch, state, home)
    write_executable(shims / "systemctl", "#!/usr/bin/env bash\nexit 0\n")
    systemd_run = (
        "#!/usr/bin/env bash\n"
        f"printf 'escape\\n' >> {os.fspath(calls)!r}\n"
        "while [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done\n"
        "[ \"${1:-}\" != -- ] || shift\n"
        "AIRLOCK_SELFKILL_ESCAPED=1 \"$@\"\n"
    )
    write_executable(shims / "systemd-run", systemd_run)
    cgroup = home / "cgroup"
    cgroup.write_text(
        "0::/user.slice/user-1001.slice/user@1001.service/app.slice/airlock-paseo.service\n",
        encoding="ascii",
    )
    environment = {
        **git_env,
        **fixture_env,
        "AIRLOCK_DIR": os.fspath(box),
        "AIRLOCK_RELEASE_URL": os.fspath(release),
        "AIRLOCK_LIVE_BOX_CARD": "fixture/SELFKILL",
        "AIRLOCK_SELFKILL_CGROUP_FILE": os.fspath(cgroup),
        "AIRLOCK_SELFKILL_SYSTEMD_RUN": os.fspath(shims / "systemd-run"),
        "AIRLOCK_FIXTURE_UPDATE_TOOLS_ROOT": os.fspath(tools),
        "PATH": os.fspath(shims) + os.pathsep + os.environ.get("PATH", ""),
    }

    victim = scratch / "airlock-update-capsule.victim"
    victim.mkdir()
    (victim / ".airlock-update-capsule-v1").write_text(
        "airlock.update-capsule/v1\n", encoding="ascii"
    )
    sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
    try:
        ambient = run(
            ["bash", os.fspath(tools / "bin" / "airlock-update"), "--help"],
            env={
                "AIRLOCK_UPDATE_CAPSULE_ROOT": os.fspath(victim),
                "AIRLOCK_UPDATE_KEEPER_PID": str(sleeper.pid),
            },
        )
        ambient_state_safe = int(
            ambient.returncode == 0 and victim.is_dir() and sleeper.poll() is None
        )
    finally:
        sleeper.terminate()
        sleeper.wait(timeout=5)

    forged = run(
        ["bash", os.fspath(tools / "bin" / "airlock-update"), "--no-install"],
        env={
            **environment,
            "AIRLOCK_LIVE_BOX_LEASE_ID": "0" * 32,
            "AIRLOCK_LIVE_BOX_LEASE_FD": "999999",
            "AIRLOCK_LIVE_BOX_LEASE_RECORD": os.fspath(scratch / "forged.json"),
        },
    )
    forged_calls = calls.read_text(encoding="ascii").splitlines() if calls.exists() else []
    forged_pre_escape = int(
        forged.returncode != 0 and forged_calls == ["ledger-live-box-lease-require"]
    )
    calls.write_text("", encoding="ascii")
    result = run(
        ["bash", os.fspath(tools / "bin" / "airlock-update")],
        env=environment,
    )
    observed = calls.read_text(encoding="ascii").splitlines() if calls.exists() else []
    return int(
        result.returncode == 0
        and ambient_state_safe == 1
        and forged_pre_escape == 1
        and observed[:4]
        == [
            "escape",
            "ledger-live-box-lease-run",
            "ledger-live-box-lease-require",
            "ledger-live-box-lease-require",
        ]
        and re.fullmatch(r"[0-9a-f]{32} [3-9][0-9]*\n", installer_lease.read_text())
        and (box / "README.md").read_text(encoding="utf-8") == "release new\n"
    )


def transaction_env(state: Path, home: Path) -> dict[str, str]:
    fixture_root = state.parent
    return {
        **fixture_mutation_env(fixture_root, state, home),
        "AIRLOCK_CONFIG_SNAPSHOT_SHA256": "0" * 64,
        "AIRLOCK_INSTALL_PKG_INFO_SHA256": "1" * 64,
        "AIRLOCK_SELFKILL_CGROUP_FILE": os.fspath(home / "fixture-cgroup"),
    }


def make_transaction(root: Path, phase: str) -> tuple[Path, Path, str, dict[str, str]]:
    state = root / "state"
    home = root / "home"
    state.mkdir(parents=True)
    home.mkdir()
    (home / "fixture-cgroup").write_text("0::/fixture.scope\n", encoding="ascii")
    env = transaction_env(state, home)
    created = run(
        [os.fspath(ROOT / "bin" / "airlock-ledger"), "transaction-begin", "fresh:fixture"],
        env=env,
    )
    if created.returncode:
        raise AssertionError(f"transaction fixture setup failed: {created.stderr}")
    transaction_id = created.stdout.strip()
    transaction_path = state / "install-transaction.json"
    value = json.loads(transaction_path.read_text(encoding="utf-8"))
    value["phase"] = phase
    transaction_path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return state, home, transaction_id, env


def probe_explicit_recovery(
    scratch: Path, installer: Path = INSTALLER
) -> dict[str, int]:
    scratch.mkdir()
    blocked = 0
    diagnostics = 0
    implicit = 0
    mutation_free = 0
    for phase in ("prepared", "installing", "rolling_back", "degraded"):
        case = scratch / phase
        state, home, transaction_id, env = make_transaction(case, phase)
        before = fingerprint(state)
        result = run(["bash", os.fspath(installer)], env=env)
        after = fingerprint(state)
        implicit += result.stderr.count("recovering unfinished install transaction")
        fields = (
            f"transaction: {transaction_id}",
            f"phase: {phase}",
            f"checkpoint: {state}/install-checkpoints/{transaction_id}",
            f"recover: bash install/airlock-install.sh --recover-transaction={transaction_id}",
        )
        blocked += int(result.returncode != 0)
        diagnostics += int(all(field in result.stderr for field in fields))
        mutation_free += int(before == after)

    wrong_root = scratch / "wrong-id"
    state, home, transaction_id, env = make_transaction(wrong_root, "degraded")
    before = fingerprint(state)
    wrong_id = "f" * 32 if transaction_id != "f" * 32 else "e" * 32
    wrong = run(
        ["bash", os.fspath(installer), f"--recover-transaction={wrong_id}"], env=env
    )
    exact_id_rejects = int(wrong.returncode != 0 and before == fingerprint(state))

    recovery_root = scratch / "explicit"
    state, home, transaction_id, env = make_transaction(recovery_root, "degraded")
    checkpoint = state / "install-checkpoints" / transaction_id
    checkpoint_before = fingerprint(checkpoint)
    recovered = run(
        [
            "bash",
            os.fspath(installer),
            f"--recover-transaction={transaction_id}",
        ],
        env=env,
    )
    value = json.loads((state / "install-transaction.json").read_text(encoding="utf-8"))
    candidate_calls = sum(
        marker in (recovered.stdout + recovered.stderr)
        for marker in ("validating airlock.toml", "validating the complete install candidate", "installing hub")
    )

    # A successful managed transaction intentionally remains committed:durable.
    # It is terminal evidence, not recovery debt, and must not permanently block
    # the next candidate before config validation.
    durable_root = scratch / "durable-terminal"
    durable_state, _home, durable_id, durable_env = make_transaction(
        durable_root, "committed"
    )
    durable_path = durable_state / "install-transaction.json"
    durable_value = json.loads(durable_path.read_text(encoding="utf-8"))
    authority = {
        "anchor_sha256": "1" * 64,
        "authority_membership_digest": "sha256:" + "2" * 64,
        "authority_sequence": 7,
        "capabilities": [],
        "channel_id": "fixture",
        "config_sha256": "0" * 64,
        "core_digest": "sha256:" + "3" * 64,
        "core_revision": "4" * 40,
        "enrollment_digest": "sha256:" + "5" * 64,
        "epoch": 2,
        "fetched_public_revision": "6" * 40,
        "installed_measurer_sha256": "7" * 64,
        "lock_digest": "sha256:" + "8" * 64,
        "next_measurer_sha256": "9" * 64,
        "organization_id": "fixture",
        "package_digest": "sha256:" + "a" * 64,
        "promotion_receipt_digest": "sha256:" + "b" * 64,
        "public_tree": "c" * 40,
        "publisher_key_id": "sha256:" + "d" * 64,
        "receipt_sha256": "e" * 64,
        "root_key_id": "sha256:" + "f" * 64,
        "schema": "airlock.managed.intent-authority/v1",
        "selection_digest": "sha256:" + "1" * 64,
        "selection_sequence": 5,
        "sequence": 11,
        "snapshot_digest": "sha256:" + "2" * 64,
        "state_digest": "sha256:" + "3" * 64,
        "target_profile": "fixture",
    }
    authorities = {"fixture": authority}
    authority_bytes = (
        json.dumps(
            {
                "authorities": authorities,
                "schema": "airlock.managed.run-authorities/v1",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode()
    durable_value["app_scoped_plan"] = {
        "plan_sha256": "4" * 64,
        "dependency_snapshot_sha256": "5" * 64,
    }
    durable_value["managed_authorities"] = authorities
    durable_value["managed_authority_sha256"] = hashlib.sha256(authority_bytes).hexdigest()
    durable_value["trusted_measurer_activation"] = {
        "new_path": f"/opt/airlock/libexec/.airlock-managed-release.{durable_id}.new",
        "new_sha256": authority["next_measurer_sha256"],
        "old_path": f"/opt/airlock/libexec/.airlock-managed-release.{durable_id}.old",
        "old_sha256": authority["installed_measurer_sha256"],
        "schema": "airlock.trusted-measurer.activation/v1",
        "state": "durable",
        "target": "/opt/airlock/libexec/airlock-managed-release",
    }
    durable_path.write_text(
        json.dumps(durable_value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    durable_config = durable_root / "airlock.toml"
    durable_config.write_text(
        '[airlock]\nconfig_version = 2\n'
        '[site]\nname = "Fixture"\n'
        '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\ncollaborators = []\n'
        '[agent]\nprovider = "claude"\n'
        '[paths]\nwiki = ""\n'
        '[apps.hub]\n',
        encoding="utf-8",
    )
    durable_env["AIRLOCK_CONFIG"] = os.fspath(durable_config)
    durable_check = run(
        [os.fspath(ROOT / "bin" / "airlock-ledger"), "transaction-show"],
        env=durable_env,
    )
    durable_next = run(["bash", os.fspath(installer)], env=durable_env)
    durable_output = durable_next.stdout + durable_next.stderr
    durable_terminal_admitted = int(
        durable_check.returncode == 0
        and durable_next.returncode != 0
        and "unfinished transaction blocks a new candidate" not in durable_output
        and "validating airlock.toml" in durable_output
    )
    return {
        "implicit_recovery_calls": implicit,
        "blocked_phases": blocked,
        "diagnostic_sets": diagnostics,
        "refusal_state_matches": mutation_free,
        "exact_id_rejects": exact_id_rejects,
        "explicit_recoveries": int(recovered.returncode == 0 and value["phase"] == "rolled_back"),
        "candidate_calls_after_recovery": candidate_calls,
        "checkpoint_preserved": int(checkpoint_before == fingerprint(checkpoint)),
        "durable_terminal_admitted": durable_terminal_admitted,
    }


def lease_argv(
    state: Path,
    agent: str,
    card: str,
    reason: str,
    command: Sequence[str],
) -> tuple[list[str], dict[str, str]]:
    return (
        [
            os.fspath(ROOT / "bin" / "airlock-ledger"),
            "live-box-lease-run",
            f"--agent-id={agent}",
            f"--card={card}",
            f"--reason={reason}",
            "--ttl-seconds=30",
            "--",
            *command,
        ],
        fixture_lease_env(state),
    )


def wait_for(path: Path, *, present: bool = True) -> None:
    deadline = time.monotonic() + 8
    while path.exists() != present and time.monotonic() < deadline:
        time.sleep(0.02)
    if path.exists() != present:
        raise AssertionError(f"timed out waiting for {path} present={present}")


def start_lease_holder(root: Path, state: Path) -> tuple[subprocess.Popen[str], Path, Path, Path]:
    root.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    ready = root / "ready"
    release = root / "release"
    child_pid = root / "child.pid"
    child_source = (
        "import pathlib,sys,time\n"
        "ready,release=map(pathlib.Path,sys.argv[1:])\n"
        "ready.write_text('ready\\n')\n"
        "deadline=time.monotonic()+20\n"
        "while not release.exists() and time.monotonic()<deadline: time.sleep(0.02)\n"
    )
    source = (
        "import os,pathlib,subprocess,sys\n"
        "ready,release,pid=map(pathlib.Path,sys.argv[1:4])\n"
        "fds=(int(os.environ['AIRLOCK_LIVE_BOX_LEASE_FD']),int(os.environ['AIRLOCK_LIVE_BOX_LEASE_GUARD_FD']))\n"
        "child=subprocess.Popen([sys.executable,'-c',sys.argv[4],str(ready),str(release)],pass_fds=fds)\n"
        "pid.write_text(str(child.pid))\n"
        "raise SystemExit(child.wait())\n"
    )
    argv, extra = lease_argv(
        state,
        "agent-holder",
        "fixture/HOLDER",
        "fixture-holder",
        [
            sys.executable,
            "-c",
            source,
            os.fspath(ready),
            os.fspath(release),
            os.fspath(child_pid),
            child_source,
        ],
    )
    environment = os.environ.copy()
    environment.update(extra)
    holder = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    wait_for(ready)
    return holder, ready, release, child_pid


def stop_lease_holder(holder: subprocess.Popen[str], release: Path) -> None:
    release.write_text("release\n", encoding="ascii")
    try:
        holder.wait(timeout=8)
    except subprocess.TimeoutExpired:
        holder.kill()
        holder.wait(timeout=5)


def probe_runtime_fallback(scratch: Path) -> int:
    helper = r'''
import pathlib
import runpy
import sys

ledger, runtime_parent, fallback_parent, marker = sys.argv[1:5]
namespace = runpy.run_path(ledger)
command = namespace["command_live_box_lease_run"]
command.__globals__["LIVE_BOX_RUNTIME_PARENT"] = pathlib.Path(runtime_parent)
command.__globals__["LIVE_BOX_FALLBACK_PARENT"] = pathlib.Path(fallback_parent)
raise SystemExit(command([
    "--agent-id=fixture-fallback",
    "--card=fixture/FALLBACK",
    "--reason=runtime-fallback",
    "--ttl-seconds=30",
    "--",
    sys.executable,
    "-c",
    "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('held\\n')",
    marker,
]))
'''
    acquired = 0
    for name, runtime_mode in (("missing", None), ("unwritable", 0o500)):
        case = scratch / name
        runtime_parent = case / "run-user"
        fallback_parent = case / "fallback"
        case.mkdir(parents=True)
        if runtime_mode is not None:
            runtime = runtime_parent / str(os.getuid())
            runtime.mkdir(parents=True)
            runtime.chmod(runtime_mode)
        marker = case / "mutation"
        result = run(
            [
                sys.executable,
                "-c",
                helper,
                os.fspath(ROOT / "bin" / "airlock-ledger"),
                os.fspath(runtime_parent),
                os.fspath(fallback_parent),
                os.fspath(marker),
            ],
            env={"AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR": ""},
        )
        lease_dir = fallback_parent / f"airlock-live-box-{os.getuid()}"
        acquired += int(
            result.returncode == 0
            and marker.exists()
            and lease_dir.is_dir()
            and stat.S_IMODE(lease_dir.stat().st_mode) == 0o700
        )
    return acquired


def probe_live_box_lease(scratch: Path) -> dict[str, int]:
    scratch.mkdir()
    mutation = scratch / "forbidden-mutation"
    collision_refusals = 0
    metadata_fields = 0
    pre_refusal_mutations = 0
    lease_winners = 0
    fd_loss_rejects = 0
    path_input_bypasses = 0
    fixture_override_refusals = 0

    # Generic live window and ordinary installer collide with the same holder.
    state = scratch / "shared-state"
    holder, _ready, release, _child_pid = start_lease_holder(scratch / "holder-a", state)
    try:
        shown = run(
            [os.fspath(ROOT / "bin" / "airlock-ledger"), "live-box-lease-show"],
            env=fixture_lease_env(state),
        )
        record = json.loads(shown.stdout)
        metadata_fields = sum(
            key in record for key in ("agent_id", "card", "reason", "expires_at")
        )
        lease_winners = int(shown.returncode == 0 and holder.poll() is None)
        fd_loss = run(
            [
                "bash",
                "-c",
                f". {str(ROOT / 'install' / 'lib.sh')!r}; airlock_require_live_box_lease",
            ],
            env={
                "AIRLOCK_ROOT": os.fspath(ROOT),
                "AIRLOCK_STATE_DIR": os.fspath(state),
                **fixture_lease_env(state),
                "AIRLOCK_LIVE_BOX_LEASE_ID": record["lease_id"],
                "AIRLOCK_LIVE_BOX_LEASE_FD": "999999",
                "AIRLOCK_LIVE_BOX_LEASE_RECORD": os.fspath(
                    state / "airlock-live-box" / "live-box-lease.json"
                ),
            },
        )
        fd_loss_rejects = int(fd_loss.returncode != 0)
        for reason in ("generic-collision", "window-collision"):
            argv, extra = lease_argv(
                state,
                "agent-other",
                "fixture/OTHER",
                reason,
                [sys.executable, "-c", f"open({os.fspath(mutation)!r},'w').write('bad')"],
            )
            if reason == "window-collision":
                extra["AIRLOCK_STATE_DIR"] = os.fspath(scratch / "different-state")
                extra["HOME"] = os.fspath(scratch / "different-home")
                extra["XDG_RUNTIME_DIR"] = os.fspath(scratch / "different-runtime")
            result = run(argv, env=extra)
            if reason == "window-collision":
                path_input_bypasses += int(result.returncode == 0)
            collision_refusals += int(
                result.returncode != 0
                and all(field in result.stderr for field in ("agent-holder", "HOLDER", "fixture-holder", "expires_at="))
            )
        home = state / "installer-home"
        home.mkdir()
        (home / "fixture-cgroup").write_text("0::/fixture.scope\n", encoding="ascii")
        installer_env = fixture_mutation_env(state, state / "installer-state", home)
        installer_env.update(
            {
                "AIRLOCK_SELFKILL_CGROUP_FILE": os.fspath(home / "fixture-cgroup"),
                "AIRLOCK_LIVE_BOX_CARD": "fixture/OTHER",
            }
        )
        installer_collision = run(
            ["bash", os.fspath(INSTALLER)],
            env=installer_env,
        )
        collision_refusals += int(
            installer_collision.returncode != 0
            and "live box lease collision before mutation" in installer_collision.stderr
        )
        pre_refusal_mutations = int(mutation.exists())

        # The only path override is a marked fixture seam. An arbitrary or
        # falsely marked alternate root must fail before its command can run.
        for name, marker_value in (("unmarked", None), ("bad-marker", "wrong\n")):
            alternate = scratch / name
            alternate.mkdir(mode=0o700)
            if marker_value is not None:
                marker = alternate / FIXTURE_MARKER
                marker.write_text(marker_value, encoding="ascii")
                marker.chmod(0o600)
            argv, _extra = lease_argv(
                state,
                "agent-override",
                "fixture/OVERRIDE",
                "override-must-refuse",
                [sys.executable, "-c", f"open({os.fspath(mutation)!r},'w').write('bad')"],
            )
            result = run(
                argv,
                env={
                    "AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR": os.fspath(
                        alternate / "airlock-live-box"
                    )
                },
            )
            fixture_override_refusals += int(result.returncode != 0)
        pre_refusal_mutations = int(mutation.exists())
    finally:
        stop_lease_holder(holder, release)

    # Exact recovery is a mutator too and must collide before transaction restore.
    recovery_root = scratch / "recovery-collision"
    state, _home, transaction_id, env = make_transaction(recovery_root, "degraded")
    before = fingerprint(state / "install-checkpoints" / transaction_id)
    holder, _ready, release, _child_pid = start_lease_holder(
        scratch / "holder-recovery", state.parent
    )
    try:
        recovery_collision = run(
            ["bash", os.fspath(INSTALLER), f"--recover-transaction={transaction_id}"],
            env=env,
        )
        collision_refusals += int(
            recovery_collision.returncode != 0
            and "live box lease collision before mutation" in recovery_collision.stderr
            and before == fingerprint(state / "install-checkpoints" / transaction_id)
        )
    finally:
        stop_lease_holder(holder, release)

    # A child already inside the lease reuses the same id; it does not contend
    # against itself or mint a second record.
    nested_script = (
        f'. {str(ROOT / "install" / "lib.sh")!r}; '
        'before="$AIRLOCK_LIVE_BOX_LEASE_ID"; '
        'airlock_enter_live_box_lease nested true; '
        '[ "$before" = "$AIRLOCK_LIVE_BOX_LEASE_ID" ]'
    )
    nested_state = scratch / "nested-state"
    nested_state.mkdir()
    argv, extra = lease_argv(
        nested_state,
        "agent-nested",
        "fixture/NESTED",
        "nested-fixture",
        ["bash", "-c", nested_script],
    )
    nested = run(argv, env=extra)
    nested_reuse = int(
        nested.returncode == 0
        and not (nested_state / "airlock-live-box" / "live-box-lease.json").exists()
    )

    # Killing the wrapper cannot free the lease while its child still holds the
    # inherited fd. Once that child exits, a new holder recovers the stale record.
    crash_state = scratch / "crash-state"
    holder, _ready, release, child_pid_path = start_lease_holder(
        scratch / "holder-crash", crash_state
    )
    child_pid = int(child_pid_path.read_text(encoding="ascii"))
    holder.kill()
    holder.wait(timeout=5)
    argv, extra = lease_argv(
        crash_state,
        "agent-steal",
        "fixture/STEAL",
        "must-not-steal",
        ["true"],
    )
    while_child = run(argv, env=extra)
    stale_lock_steals = int(while_child.returncode == 0)
    release.write_text("release\n", encoding="ascii")
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    recovered = run(argv, env=extra)
    crash_release = int(recovered.returncode == 0)

    # Prove the mutation oracle is live: bypassing the guard must be observable.
    negative_path = scratch / "negative-control-mutation"
    direct = run(
        [
            sys.executable,
            "-c",
            f"open({os.fspath(negative_path)!r},'w').write('observed')",
        ]
    )
    negative_control = int(direct.returncode == 0 and negative_path.exists())

    return {
        "lease_winners": lease_winners,
        "metadata_fields": metadata_fields,
        "fd_loss_rejects": fd_loss_rejects,
        "path_input_bypasses": path_input_bypasses,
        "fixture_override_refusals": fixture_override_refusals,
        "runtime_fallback_acquires": probe_runtime_fallback(scratch / "fallback"),
        "collision_refusals": collision_refusals,
        "pre_refusal_mutations": pre_refusal_mutations,
        "nested_reuse": nested_reuse,
        "crash_release": crash_release,
        "stale_lock_steals": stale_lock_steals,
        "updater_guard": int(
            probe_updater_lease_guard(scratch / "updater-collision") == 1
            and probe_updater_selfkill_order(scratch / "updater-selfkill") == 1
            and probe_updater_lease_guard(
                scratch / "updater-mutant",
                updater_lease_mutant(scratch / "updater-mutant-source" / "bin" / "airlock-update"),
            )
            == 0
        ),
        "negative_control": negative_control,
    }


def revision() -> str:
    result = run(["git", "rev-parse", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else "UNCOMMITTED"


def evaluate_live_doc_gate(value: object, rev: str, expected_box: str) -> dict[str, int]:
    if not isinstance(value, dict):
        raise ValueError("live document-gate evidence must be a JSON object")
    endpoint = value.get("endpoint")
    mapping = value.get("mapping")
    response = value.get("response")
    gate = value.get("gate")
    if not all(isinstance(item, dict) for item in (endpoint, mapping, response, gate)):
        raise ValueError("live document-gate evidence is missing a structured observation")
    assert isinstance(endpoint, dict)
    assert isinstance(mapping, dict)
    assert isinstance(response, dict)
    assert isinstance(gate, dict)
    url = endpoint.get("url")
    fqdn = endpoint.get("fqdn")
    body_sha = response.get("body_sha256")
    site_sha = gate.get("site_sha256")
    observed = {
        "box_match": int(bool(expected_box) and value.get("box") == expected_box),
        "revision_match": int(
            value.get("source_revision") == rev
            and bool(re.fullmatch(r"[0-9a-f]{40}", str(value.get("installed_revision", ""))))
        ),
        "endpoint_exact": int(
            isinstance(url, str)
            and isinstance(fqdn, str)
            and bool(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", fqdn))
            and bool(re.fullmatch(  # noqa: regex-anchor - runtime fqdn; fullmatch closes it
                rf"https://{re.escape(fqdn)}:8000/[^/?#]+\.html", url
            ))
            and endpoint.get("port") == 8000
        ),
        "mapping_8000_19925": int(
            mapping
            == {"https_port": 8000, "target_host": "127.0.0.1", "target_port": 19925}
        ),
        "document_200": int(
            response.get("http_code") == 200
            and response.get("redirect_count") == 0
            and response.get("ssl_verify_result") == 0
            and isinstance(response.get("content_type"), str)
            and response["content_type"].lower().startswith("text/html")
            and bool(re.fullmatch(r"[0-9a-f]{64}", str(body_sha or "")))
            and bool(re.fullmatch(r"[0-9]{4}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](?:\.[0-9]+)?\+09:00", str(response.get("captured_at", ""))))
        ),
        "gate_denies_unauthenticated": int(
            gate.get("loopback_without_identity_status") == 403
            and gate.get("publish_marker_count") == 1
            and bool(re.fullmatch(r"[0-9a-f]{64}", str(site_sha or "")))
        ),
    }
    expected = {
        "box_match": 1,
        "revision_match": 1,
        "endpoint_exact": 1,
        "mapping_8000_19925": 1,
        "document_200": 1,
        "gate_denies_unauthenticated": 1,
    }
    mutants = []
    for section, key, replacement in (
        ("response", "http_code", 502),
        ("mapping", "target_port", 19924),
        ("gate", "loopback_without_identity_status", 200),
    ):
        mutated = json.loads(json.dumps(value))
        mutated[section][key] = replacement
        mutants.append(evaluate_live_doc_gate_core(mutated, rev, expected_box) != expected)
    return {**observed, "negative_controls": sum(mutants)}


def evaluate_live_doc_gate_core(
    value: dict[str, object], rev: str, expected_box: str
) -> dict[str, int]:
    """Evaluator body used by negative controls without recursively mutating."""
    endpoint = value.get("endpoint") if isinstance(value.get("endpoint"), dict) else {}
    mapping = value.get("mapping") if isinstance(value.get("mapping"), dict) else {}
    response = value.get("response") if isinstance(value.get("response"), dict) else {}
    gate = value.get("gate") if isinstance(value.get("gate"), dict) else {}
    assert isinstance(endpoint, dict)
    assert isinstance(mapping, dict)
    assert isinstance(response, dict)
    assert isinstance(gate, dict)
    url = endpoint.get("url")
    fqdn = endpoint.get("fqdn")
    return {
        "box_match": int(bool(expected_box) and value.get("box") == expected_box),
        "revision_match": int(
            value.get("source_revision") == rev
            and bool(re.fullmatch(r"[0-9a-f]{40}", str(value.get("installed_revision", ""))))
        ),
        "endpoint_exact": int(
            isinstance(url, str)
            and isinstance(fqdn, str)
            and bool(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", fqdn))
            and bool(re.fullmatch(  # noqa: regex-anchor - runtime fqdn; fullmatch closes it
                rf"https://{re.escape(fqdn)}:8000/[^/?#]+\.html", url
            ))
            and endpoint.get("port") == 8000
        ),
        "mapping_8000_19925": int(
            mapping == {"https_port": 8000, "target_host": "127.0.0.1", "target_port": 19925}
        ),
        "document_200": int(
            response.get("http_code") == 200
            and response.get("redirect_count") == 0
            and response.get("ssl_verify_result") == 0
            and isinstance(response.get("content_type"), str)
            and response["content_type"].lower().startswith("text/html")
            and bool(re.fullmatch(r"[0-9a-f]{64}", str(response.get("body_sha256", ""))))
            and bool(re.fullmatch(r"[0-9]{4}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](?:\.[0-9]+)?\+09:00", str(response.get("captured_at", ""))))
        ),
        "gate_denies_unauthenticated": int(
            gate.get("loopback_without_identity_status") == 403
            and gate.get("publish_marker_count") == 1
            and bool(re.fullmatch(r"[0-9a-f]{64}", str(gate.get("site_sha256", ""))))
        ),
    }


def emit_ac(
    ac_id: str,
    expected: str,
    observed: Mapping[str, object],
    verdict: str,
    signal: str,
    rev: str,
    evidence_path: str = "install/test-live-box-isolation.py",
) -> None:
    values = ",".join(f"{key}={value}" for key, value in observed.items())
    print(
        f"AC-{ac_id} | expected: {expected} | observed: {values} | "
        f"verdict: {verdict} | signal: {signal} | "
        f"evidence: {evidence_path}@{rev}"
    )


def main() -> int:
    flags = {arg for arg in sys.argv[1:] if arg.startswith("--") and "=" not in arg}
    allowed = {"--emit-ac", "--guard-only", "--require-live"}
    unknown = [
        arg
        for arg in sys.argv[1:]
        if arg not in allowed
        and not arg.startswith("--live-doc-gate-evidence=")
        and not arg.startswith("--live-box=")
    ]
    if unknown:
        print(f"unknown argument: {unknown[0]}", file=sys.stderr)
        return 2
    guard_only = "--guard-only" in sys.argv[1:]
    require_live = "--require-live" in flags
    live_evidence_args = [
        arg.split("=", 1)[1]
        for arg in sys.argv[1:]
        if arg.startswith("--live-doc-gate-evidence=")
    ]
    live_box_args = [
        arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("--live-box=")
    ]
    if len(live_evidence_args) > 1 or any(not value for value in live_evidence_args):
        print("--live-doc-gate-evidence requires one non-empty path", file=sys.stderr)
        return 2
    live_evidence_path = Path(live_evidence_args[0]).resolve() if live_evidence_args else None
    if len(live_box_args) > 1 or any(not value for value in live_box_args):
        print("--live-box requires one non-empty box name", file=sys.stderr)
        return 2
    live_box = live_box_args[0] if live_box_args else ""
    if live_evidence_path is not None and not live_box:
        print("--live-doc-gate-evidence requires --live-box", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="airlock-live-box-isolation-") as raw:
        scratch = Path(raw).resolve()
        nginx_guard = probe_nginx_publish_guard(scratch / "nginx-guard")
        nginx_guard_expected = (
            "continuity_admits==1 && missing_listen_refuses==1 && "
            "missing_gate_refuses==1 && real_render_shape_admits==1 && "
            "sealed_live_roots==3 && root_mutants_detected==3 && "
            "fixture_boundary_admits==1 && live_alias_canonicalizes==1 && "
            "parent_alias_canonicalizes==1 && final_symlink_preserved==1 && "
            "final_symlink_refuses==1 && canonical_call_order==1 && "
            "current_unchanged==1 && call_order==1 && product_mutants_detected==2 && "
            "canonical_mutants_detected==4"
        )
        nginx_guard_pass = nginx_guard == {
            "continuity_admits": 1,
            "real_render_shape_admits": 1,
            "missing_listen_refuses": 1,
            "missing_gate_refuses": 1,
            "sealed_live_roots": 3,
            "root_mutants_detected": 3,
            "fixture_boundary_admits": 1,
            "live_alias_canonicalizes": 1,
            "parent_alias_canonicalizes": 1,
            "final_symlink_preserved": 1,
            "final_symlink_refuses": 1,
            "canonical_call_order": 1,
            "current_unchanged": 1,
            "call_order": 1,
            "product_mutants_detected": 2,
            "canonical_mutants_detected": 4,
        }
        owner_guard = probe_owner_continuity(scratch / "owner-continuity")
        owner_guard_expected = (
            "renderer_contract==1 && first_install_admits==1 && "
            "legacy_upgrade_admits==1 && legacy_promotes_to_v1==1 && "
            "sentinel_same_owner_admits==1 && sentinel_mismatch_refuses==1 && "
            "exact_transfer_admits==1 && transfer_refusals==3 && "
            "exact_block_tamper_refusals==2 && noncanonical_refusals==2 && "
            "candidate_v1_required==1 && "
            "golden_full_render_same_owner==2 && "
            "golden_full_render_different_owner==2 && toctou_refuses==1 && "
            "inputs_unchanged==1 && prewrite_call_order==1 && precopy_call_order==1 && "
            "unique_owner_refusals==5 && "
            "semantic_mutants_detected==9 && "
            "unique_header_mutants_detected==5 && "
            "order_mutants_detected==2 && resnapshot_mutants_detected==1 && "
            "explicit_path_bound==1 && argv_validation_pre_effect==1 && "
            "dry_preview_owner_neutral==1 && legacy_guards_removed==1"
        )
        owner_guard_pass = owner_guard == {
            "renderer_contract": 1,
            "first_install_admits": 1,
            "legacy_upgrade_admits": 1,
            "legacy_promotes_to_v1": 1,
            "sentinel_same_owner_admits": 1,
            "sentinel_mismatch_refuses": 1,
            "exact_transfer_admits": 1,
            "transfer_refusals": 3,
            "exact_block_tamper_refusals": 2,
            "noncanonical_refusals": 2,
            "candidate_v1_required": 1,
            "golden_full_render_same_owner": 2,
            "golden_full_render_different_owner": 2,
            "toctou_refuses": 1,
            "inputs_unchanged": 1,
            "prewrite_call_order": 1,
            "precopy_call_order": 1,
            "unique_owner_refusals": 5,
            "semantic_mutants_detected": 9,
            "unique_header_mutants_detected": 5,
            "order_mutants_detected": 2,
            "resnapshot_mutants_detected": 1,
            "explicit_path_bound": 1,
            "argv_validation_pre_effect": 1,
            "dry_preview_owner_neutral": 1,
            "legacy_guards_removed": 1,
        }
        if guard_only:
            rev = revision()
            emit_ac(
                "MAU-L0-NGINX-PUBLISH-GUARD",
                nginx_guard_expected,
                nginx_guard,
                "PASS" if nginx_guard_pass else "FAIL",
                "fixture",
                rev,
            )
            emit_ac(
                "MAU-L0-OWNER-CONTINUITY",
                owner_guard_expected,
                owner_guard,
                "PASS" if owner_guard_pass else "FAIL",
                "fixture",
                rev,
            )
            return 0 if nginx_guard_pass and owner_guard_pass else 1
        fixture_boundary = probe_fixture_boundary(scratch / "fixture-boundary")
        installer = probe_installer_entry(scratch / "installer")
        l1_mutant = installer_mutant(
            scratch / "l1-mutant" / "install" / "airlock-install.sh",
            r'''# Product mutant: every read-only oracle must observe this injected regression.
systemd-run --unit=airlock-negative-control true
systemctl --user restart airlock-negative-control.service
tailscale serve reset
printf '%s\n' 'recovering unfinished install transaction' >&2
if [ -n "${AIRLOCK_WEBROOT:-}" ]; then
  mkdir -p "$AIRLOCK_WEBROOT" "${AIRLOCK_CONFD:-$AIRLOCK_WEBROOT/confd}"
fi
_airlock_install_usage() { printf '%s\n' 'mutated fixture usage'; }
_airlock_arg_die() { exit 0; }
[ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || exit 91''',
        )
        installer_mutated = probe_installer_entry(scratch / "installer-mutated", l1_mutant)
        updater = probe_updater_entry(scratch / "updater")
        recovery = probe_explicit_recovery(scratch / "recovery")
        l2_mutant = installer_mutant(
            scratch / "l2-mutant" / "install" / "airlock-install.sh",
            r'''# Product mutant: bypass/refuse the recovery boundary and alter its evidence.
case "${1:-}" in
--recover-transaction=*) ;;
*)
  printf '%s\n' 'recovering unfinished install transaction' >&2
  printf '%s\n' 'mutated recovery state' > "${AIRLOCK_STATE_DIR:?}/mutant-write"
  exit 0
  ;;
esac
printf '%s\n' 'validating airlock.toml' >&2
_airlock_mutant_checkpoint="$(find "${AIRLOCK_STATE_DIR:?}/install-checkpoints" -type f -print -quit 2>/dev/null || true)"
[ -z "$_airlock_mutant_checkpoint" ] || printf '%s\n' mutated >> "$_airlock_mutant_checkpoint"
exit 91''',
        )
        recovery_mutated = probe_explicit_recovery(scratch / "recovery-mutated", l2_mutant)
        lease = probe_live_box_lease(scratch / "lease")

        sentinel = scratch / "negative-control"
        sentinel.mkdir()
        (sentinel / "value").write_text("before\n", encoding="utf-8")
        before = fingerprint(sentinel)
        (sentinel / "value").write_text("after\n", encoding="utf-8")
        negative_control = int(before != fingerprint(sentinel))

        fixture_boundary_expected = (
            "installer_refuses==1 && updater_refuses==1 && "
            "pre_effect_mutations==0 && product_mutants_detected==2"
        )
        fixture_boundary_pass = fixture_boundary == {
            "installer_refuses": 1,
            "updater_refuses": 1,
            "pre_effect_mutations": 0,
            "product_mutants_detected": 2,
        }
        rev = revision()
        emit_ac(
            "MAU-L0-FIXTURE-BOUNDARY",
            fixture_boundary_expected,
            fixture_boundary,
            "PASS" if fixture_boundary_pass else "FAIL",
            "fixture",
            rev,
        )
        emit_ac(
            "MAU-L0-NGINX-PUBLISH-GUARD",
            nginx_guard_expected,
            nginx_guard,
            "PASS" if nginx_guard_pass else "FAIL",
            "fixture",
            rev,
        )
        emit_ac(
            "MAU-L0-OWNER-CONTINUITY",
            owner_guard_expected,
            owner_guard,
            "PASS" if owner_guard_pass else "FAIL",
            "fixture",
            rev,
        )

        installer_observed = {
            "help_contract": installer["help_contract"],
            "invalid_contract": installer["invalid_contract"],
            "dry_run_completed": installer["dry_run_completed"],
            "recovery_calls": installer["recovery_calls"],
            "unit_creations": installer["unit_creations"],
            "ingress_mutations": installer["ingress_mutations"],
            "service_mutations": installer["service_mutations"],
            "live_root_writes": installer["live_root_writes"],
            "mutation_oracles": sum(
                installer_mutated[key] != installer[key]
                for key in (
                    "help_contract",
                    "invalid_contract",
                    "dry_run_completed",
                    "recovery_calls",
                    "unit_creations",
                    "ingress_mutations",
                    "service_mutations",
                    "live_root_writes",
                )
            ),
        }
        installer_expected = (
            "help_contract==1 && invalid_contract==1 && "
            "dry_run_completed==1 && recovery_calls==0 && unit_creations==0 && "
            "ingress_mutations==0 && service_mutations==0 && live_root_writes==0 && "
            "mutation_oracles==8"
        )
        installer_l1_pass = installer_observed == {
            "help_contract": 1,
            "invalid_contract": 1,
            "dry_run_completed": 1,
            "recovery_calls": 0,
            "unit_creations": 0,
            "ingress_mutations": 0,
            "service_mutations": 0,
            "live_root_writes": 0,
            "mutation_oracles": 8,
        }
        emit_ac(
            "MAU-L1-INSTALLER",
            installer_expected,
            installer_observed,
            "PASS" if installer_l1_pass else "FAIL",
            "fixture",
            rev,
        )
        updater_observed = {
            "read_cases": updater["read_cases"],
            "help_contract": updater["help_contract"],
            "dry_run_completed": updater["dry_run_completed"],
            "checkout_writes": updater["checkout_writes"],
            "negative_control": negative_control,
        }
        updater_expected = (
            "read_cases==2 && help_contract==1 && dry_run_completed==1 && "
            "checkout_writes==0 && negative_control==1"
        )
        updater_l1_pass = updater_observed == {
            "read_cases": 2,
            "help_contract": 1,
            "dry_run_completed": 1,
            "checkout_writes": 0,
            "negative_control": 1,
        }
        emit_ac(
            "MAU-L1-UPDATER",
            updater_expected,
            updater_observed,
            "PASS" if updater_l1_pass else "FAIL",
            "fixture",
            rev,
        )
        l2_expected = (
            "implicit_recovery_calls==0 && blocked_phases==4 && diagnostic_sets==4 && "
            "refusal_state_matches==4 && exact_id_rejects==1 && explicit_recoveries==1 && "
            "candidate_calls_after_recovery==0 && checkpoint_preserved==1 && "
            "durable_terminal_admitted==1 && mutation_oracles==9"
        )
        recovery_observed = {
            **recovery,
            "mutation_oracles": sum(
                recovery_mutated[key] != recovery[key] for key in recovery
            ),
        }
        l2_pass = recovery_observed == {
            "implicit_recovery_calls": 0,
            "blocked_phases": 4,
            "diagnostic_sets": 4,
            "refusal_state_matches": 4,
            "exact_id_rejects": 1,
            "explicit_recoveries": 1,
            "candidate_calls_after_recovery": 0,
            "checkpoint_preserved": 1,
            "durable_terminal_admitted": 1,
            "mutation_oracles": 9,
        }
        emit_ac(
            "MAU-L2",
            l2_expected,
            recovery_observed,
            "PASS" if l2_pass else "FAIL",
            "fixture",
            rev,
        )
        common_lease = {key: value for key, value in lease.items() if key != "updater_guard"}
        l3_expected = (
            "lease_winners==1 && metadata_fields==4 && fd_loss_rejects==1 && "
            "path_input_bypasses==0 && fixture_override_refusals==2 && "
            "runtime_fallback_acquires==2 && collision_refusals==4 && "
            "pre_refusal_mutations==0 && nested_reuse==1 && crash_release==1 && "
            "stale_lock_steals==0 && negative_control==1"
        )
        common_l3_pass = common_lease == {
            "lease_winners": 1,
            "metadata_fields": 4,
            "fd_loss_rejects": 1,
            "path_input_bypasses": 0,
            "fixture_override_refusals": 2,
            "runtime_fallback_acquires": 2,
            "collision_refusals": 4,
            "pre_refusal_mutations": 0,
            "nested_reuse": 1,
            "crash_release": 1,
            "stale_lock_steals": 0,
            "negative_control": 1,
        }
        emit_ac(
            "MAU-L3-COMMON",
            l3_expected,
            common_lease,
            "PASS" if common_l3_pass else "FAIL",
            "fixture",
            rev,
        )
        updater_guard = {"updater_guard": lease["updater_guard"]}
        emit_ac(
            "MAU-L3-UPDATER",
            "updater_guard==1",
            updater_guard,
            "PASS" if updater_guard == {"updater_guard": 1} else "FAIL",
            "fixture",
            rev,
        )
        emit_ac(
            "MAU-L4",
            "tx_id_match==1 && source_copy_hash_match==1 && "
            "checkpoint_manifest_match==1 && explicit_recovery_runs==1 && "
            "final_terminal==1 && failed_restores==0 && checkpoint_preserved==1 && "
            "ledger_hash_match==1 && live_smokes_green==1",
            {},
            "UNMEASURED",
            "live",
            rev,
        )
        emit_ac(
            "MAU-L5",
            "task_docs==3 && contract_links==3 && lease_rules==3 && "
            "preconditions==3 && forbidden_calls==3 && negative_control==1",
            {},
            "UNMEASURED",
            "projection",
            rev,
        )
        doc_gate_expected = (
            "box_match==1 && revision_match==1 && endpoint_exact==1 && "
            "mapping_8000_19925==1 && document_200==1 && "
            "gate_denies_unauthenticated==1 && negative_controls==3"
        )
        doc_gate_expected_values = {
            "box_match": 1,
            "revision_match": 1,
            "endpoint_exact": 1,
            "mapping_8000_19925": 1,
            "document_200": 1,
            "gate_denies_unauthenticated": 1,
            "negative_controls": 3,
        }
        doc_gate_observed: dict[str, int] = {}
        doc_gate_verdict = "UNMEASURED"
        doc_gate_evidence = "install/test-live-box-isolation.py"
        if live_evidence_path is not None:
            doc_gate_evidence = os.fspath(live_evidence_path)
            try:
                live_value = json.loads(live_evidence_path.read_text(encoding="utf-8"))
                doc_gate_observed = evaluate_live_doc_gate(live_value, rev, live_box)
                doc_gate_verdict = (
                    "PASS" if doc_gate_observed == doc_gate_expected_values else "FAIL"
                )
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                print(f"live document-gate evidence rejected: {exc}", file=sys.stderr)
                doc_gate_observed = {"evidence_valid": 0}
                doc_gate_verdict = "FAIL"
        emit_ac(
            "MAU-L6-DOC-GATE-LIVE",
            doc_gate_expected,
            doc_gate_observed,
            doc_gate_verdict,
            "live",
            rev,
            doc_gate_evidence,
        )
        all_measured_pass = (
            fixture_boundary_pass
            and nginx_guard_pass
            and owner_guard_pass
            and installer_l1_pass
            and updater_l1_pass
            and l2_pass
            and common_l3_pass
            and updater_guard == {"updater_guard": 1}
            and (not require_live or doc_gate_verdict == "PASS")
        )
        return 0 if all_measured_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
