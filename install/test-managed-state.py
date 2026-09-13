#!/usr/bin/env python3
"""Deterministic fixture for local managed enrollment and selection state."""

from __future__ import annotations

import base64
import copy
import hashlib
import importlib.util
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "bin/airlock-managed-state"
PROJECTOR = ROOT / "bin/airlock-managed-projector"
RELEASE = ROOT / "bin/airlock-managed-release"
RELEASE_FIXTURE = ROOT / "install/test-managed-release.py"
PROJECTOR_FIXTURE = ROOT / "install/test-managed-projector.py"
SCHEMA_DIR = ROOT / "schemas/managed-app-store"
NOW = "2026-09-12T04:00:00Z"
LATER = "2026-09-12T04:01:00Z"
CI_DIGEST = "sha256:" + "a" * 64
CORE_DIGEST = "sha256:" + "b" * 64
CORE_REVISION = "c" * 40


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


RF = load_module("managed_release_fixture", RELEASE_FIXTURE)
PF = load_module("managed_projector_fixture", PROJECTOR_FIXTURE)


def run(*args: str, env: dict[str, str] | None = None, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if ok and result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr.decode(errors='replace')}")
    if not ok and result.returncode == 0:
        raise AssertionError(f"command unexpectedly passed: {' '.join(args)}\n{result.stdout.decode(errors='replace')}")
    return result


def state_run(command: str, state: Path, stage: Path, authority: Path, selection: Path, *, enrollment: Path | None = None, config: Path | None = None, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    argv = [
        sys.executable, str(STATE), command, "--state", str(state), "--release", str(stage),
        "--authority", str(authority), "--selection", str(selection), "--at", LATER,
    ]
    if enrollment is not None:
        argv.extend(["--enrollment", str(enrollment)])
    if config is not None:
        argv.extend(["--config", str(config)])
    return run(*argv, ok=ok)


def privileged_argv(*args: str) -> list[str]:
    if os.geteuid() == 0:
        return list(args)
    return ["/usr/bin/sudo", "-n", "--", *args]


def privileged_run(*args: str, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    return run(*privileged_argv(*args), ok=ok)


def delegated_identity() -> tuple[int, int]:
    if os.geteuid() != 0:
        return os.geteuid(), os.getegid()
    nobody = pwd.getpwnam("nobody")
    return nobody.pw_uid, nobody.pw_gid


def delegated_argv(writer_uid: int, writer_gid: int, *args: str) -> list[str]:
    if os.geteuid() != 0:
        assert (writer_uid, writer_gid) == (os.geteuid(), os.getegid())
        return list(args)
    return [
        "/usr/bin/setpriv", "--reuid", str(writer_uid), "--regid", str(writer_gid),
        "--clear-groups", *args,
    ]


def delegated_run(
    writer_uid: int, writer_gid: int, *args: str, ok: bool = True
) -> subprocess.CompletedProcess[bytes]:
    return run(*delegated_argv(writer_uid, writer_gid, *args), ok=ok)


def new_system_root() -> Path:
    code = (
        "import os,tempfile; "
        "p=tempfile.mkdtemp(prefix='airlock-managed-state-',dir='/run'); "
        "os.chmod(p,0o755); print(p)"
    )
    result = privileged_run(sys.executable, "-c", code)
    path = Path(result.stdout.decode().strip())
    if path.parent != Path("/run") or not path.name.startswith("airlock-managed-state-"):
        raise AssertionError(f"unexpected privileged fixture root: {path}")
    return path


def remove_system_root(path: Path) -> None:
    code = (
        "import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1]); "
        "assert p.parent==pathlib.Path('/run') and "
        "p.name.startswith('airlock-managed-state-'); shutil.rmtree(p)"
    )
    privileged_run(sys.executable, "-c", code, str(path))


def bootstrap_argv(
    system_root: Path,
    writer_uid: int,
    writer_gid: int,
    stage: Path,
    authority: Path,
    selection: Path,
    enrollment: Path,
    legacy_config: Path | None = None,
) -> list[str]:
    argv = [
        sys.executable, str(STATE), "bootstrap", "--root-prefix", str(system_root),
        "--writer-uid", str(writer_uid), "--writer-gid", str(writer_gid),
        "--release", str(stage), "--authority", str(authority),
        "--selection", str(selection), "--enrollment", str(enrollment),
        "--at", LATER,
    ]
    if legacy_config is not None:
        argv.extend(["--legacy-config", str(legacy_config)])
    return argv


def bootstrap_run(
    system_root: Path,
    writer_uid: int,
    writer_gid: int,
    stage: Path,
    authority: Path,
    selection: Path,
    enrollment: Path,
    *,
    legacy_config: Path | None = None,
    ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return privileged_run(
        *bootstrap_argv(
            system_root, writer_uid, writer_gid, stage, authority, selection,
            enrollment, legacy_config,
        ),
        ok=ok,
    )


def projector_run(config: Path, stage: Path, authority: Path, state: Path, output: Path, env: dict[str, str], *, ok: bool) -> subprocess.CompletedProcess[bytes]:
    return run(
        sys.executable, str(PROJECTOR), "--config", str(config), "--release", str(stage),
        "--authority", str(authority), "--state", str(state), "--at", LATER,
        "--out", str(output), env=env, ok=ok,
    )


def package_files(package_id: str, *, required_secret: bool = False) -> dict[str, tuple[int, bytes]]:
    required = ""
    if required_secret:
        required = "\n[[config.required]]\nname = \"token_env\"\ntype = \"string\"\n"
    return {
        "airlock-app.toml": (0o644, f'contract = 1\nid = "{package_id}"\n{required}'.encode()),
        "deactivate.sh": (0o755, b"#!/usr/bin/env bash\nexit 0\n"),
        "install.sh": (0o755, b"#!/usr/bin/env bash\nexit 0\n"),
        "smoke.sh": (0o755, b"#!/usr/bin/env bash\nexit 0\n"),
    }


def materialize_package(path: Path, package_id: str, *, required_secret: bool = False) -> dict[str, tuple[int, bytes]]:
    files = package_files(package_id, required_secret=required_secret)
    for relative, (mode, raw) in files.items():
        target = path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        target.chmod(mode)
    return files


def make_stage(
    root: Path,
    publisher_key: Path,
    *,
    sequence: int,
    required_capabilities: list[str] | None = None,
    organization: str = "fixture-org",
    channel: str = "stable",
    epoch: int = 1,
) -> Path:
    repo = root / f"review-{organization}-{channel}-{epoch}-{sequence}"
    source = repo / "release-src"
    policies = {
        "available-app": "available",
        "blocked-app": "blocked",
        "notes": "available",
        "required-app": "required",
    }
    catalog_apps = []
    packages = []
    for package_id, policy in sorted(policies.items()):
        catalog_apps.append({
            "compatibility": {"platforms": ["linux"], "profiles": ["team"]},
            "id": package_id,
            "metadata": {"name": package_id, "version": f"1.0.{sequence}"},
            "policy": policy,
            "source_label": "Fixture organisation",
        })
        if policy == "blocked":
            continue
        files = materialize_package(
            source / "packages" / package_id,
            package_id,
            required_secret=package_id == "required-app",
        )
        packages.append({
            "capabilities": required_capabilities or [] if package_id == "required-app" else [],
            "data_compatibility": "stateless",
            "deactivator": "deactivate.sh",
            "digest": RF.package_digest(files),
            "id": package_id,
            "path": f"packages/{package_id}",
        })
    RF.write_json(source / "catalog.json", {
        "apps": catalog_apps,
        "channel_id": channel,
        "organization_id": organization,
        "schema": "airlock.managed.catalog/v1",
    })
    RF.write_json(source / "release.lock", {
        "channel_id": channel,
        "core": {"digest": CORE_DIGEST, "revision": CORE_REVISION},
        "organization_id": organization,
        "packages": packages,
        "schema": "airlock.managed.release-lock/v1",
        "target_profile": "team",
    })
    run("git", "init", "-q", str(repo))
    run("git", "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    run("git", "-C", str(repo), "config", "user.name", "Managed state fixture")
    run("git", "-C", str(repo), "add", "release-src")
    commit_env = dict(os.environ, GIT_AUTHOR_DATE=NOW, GIT_COMMITTER_DATE=NOW)
    run("git", "-C", str(repo), "commit", "-q", "-m", "reviewed managed state", env=commit_env)
    revision = run("git", "-C", str(repo), "rev-parse", "HEAD").stdout.decode().strip()
    stage = root / f"signed-{organization}-{channel}-{epoch}-{sequence}"
    run(
        sys.executable, str(RELEASE), "prepare", "--source-repo", str(repo),
        "--revision", revision, "--input-prefix", "release-src",
        "--source-repository", "fixture/managed-state", "--organization", organization,
        "--channel", channel, "--epoch", str(epoch), "--sequence", str(sequence),
        "--publisher", "publisher-a", "--created-at", NOW,
        "--ci-evidence-digest", CI_DIGEST, "--out", str(stage),
    )
    run(sys.executable, str(RELEASE), "sign", "--stage", str(stage), "--publisher-key", str(publisher_key))
    return stage


def make_authority(
    path: Path,
    root_key: Path,
    root_der: bytes,
    publisher_der: bytes,
    publisher_key_id: str,
    *,
    sequence: int = 1,
    ceiling: list[str] | None = None,
    channels: list[dict[str, Any]] | None = None,
) -> None:
    membership = RF.membership_value(
        root_key, root_der, publisher_der, publisher_key_id,
        ceiling=ceiling if ceiling is not None else ["system-unit"], sequence=sequence,
    )
    if channels is not None:
        membership["channels"] = channels
        membership.pop("root_signature")
        membership["root_signature"] = {
            "algorithm": "ed25519",
            "signature": base64.b64encode(RF.sign(root_key, RF.canonical(membership))).decode(),
        }
    RF.set_membership(path, membership, root_der)


def config_text(local_only: Path, required_local: Path, *, owner: str = "owner@fixture.dev") -> str:
    return f'''[airlock]
config_version = 2

[site]
name = "Fixture Site"

[auth]
provider = "tailscale"
owner = "{owner}"

[paths]
wiki = "/srv/fixture-wiki"

[apps.hub]

[apps.local-only]
token_env = "LOCAL_SECRET_REFERENCE"

[packages.local-only]
path = "{local_only}"

[apps.required-app]
token_env = "REQUIRED_SECRET_REFERENCE"

[packages.required-app]
path = "{required_local}"
'''


def selection_value(snapshot_digest: str, rows: list[tuple[str, str]], sequence: int, organization: str = "fixture-org") -> dict[str, Any]:
    return {
        "organization_id": organization,
        "schema": "airlock.managed.selection/v1",
        "selections": [{"id": app_id, "source": source} for app_id, source in sorted(rows)],
        "sequence": sequence,
        "snapshot_digest": snapshot_digest,
    }


def snapshot_digest(stage: Path) -> str:
    return RF.digest((stage / "snapshot.json").read_bytes())


def write_private(path: Path, raw: bytes) -> None:
    path.write_bytes(raw)
    path.chmod(0o600)


def under_root(root: Path, absolute: str) -> Path:
    return root / Path(absolute).relative_to("/")


def delegated_write(
    writer_uid: int, writer_gid: int, path: Path, raw: bytes
) -> None:
    encoded = base64.b64encode(raw).decode("ascii")
    code = (
        "import base64,os,pathlib,sys; p=pathlib.Path(sys.argv[1]); "
        "raw=base64.b64decode(sys.argv[2]); "
        "fd=os.open(p,os.O_WRONLY|os.O_TRUNC|os.O_CLOEXEC|"
        "getattr(os,'O_NOFOLLOW',0)); "
        "f=os.fdopen(fd,'wb'); f.write(raw); f.flush(); os.fsync(f.fileno()); f.close()"
    )
    delegated_run(writer_uid, writer_gid, sys.executable, "-c", code, str(path), encoded)


def bootstrap_fixture(
    root: Path,
    publisher_key: Path,
    stage: Path,
    authority: Path,
    enrollment: Path,
    initial_selection: Path,
) -> dict[str, int]:
    counters = {
        "anchor_state": 0,
        "repeat_safe": 0,
        "wrong_owner_rejects": 0,
        "insecure_parent_rejects": 0,
        "symlink_rejects": 0,
        "state_conflict_rejects": 0,
        "partial_recovery": 0,
        "concurrent_conflict": 0,
        "nonroot_namespace_write": 0,
        "nonroot_anchor_rejects": 0,
        "nonroot_authority_rejects": 0,
    }
    writer_uid, writer_gid = delegated_identity()
    roots: list[Path] = []

    next_stage = make_stage(root, publisher_key, sequence=9)
    next_selection = root / "bootstrap-selection-2.json"
    RF.write_json(next_selection, selection_value(snapshot_digest(next_stage), [
        ("available-app", "managed"),
        ("notes", "public"),
        ("required-app", "managed"),
    ], 2))
    forged_selection = root / "bootstrap-selection-3.json"
    RF.write_json(forged_selection, selection_value(snapshot_digest(next_stage), [
        ("available-app", "managed"),
        ("notes", "public"),
        ("required-app", "managed"),
    ], 3))
    conflicting_selection = root / "bootstrap-selection-conflict.json"
    RF.write_json(conflicting_selection, selection_value(snapshot_digest(stage), [
        ("available-app", "local"),
        ("notes", "public"),
        ("required-app", "managed"),
    ], 1))

    def system_root() -> Path:
        path = new_system_root()
        roots.append(path)
        return path

    def prepare_path(path: Path, *, mode: int = 0o755, owner: tuple[int, int] = (0, 0)) -> None:
        code = (
            "import os,pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "p.mkdir(parents=True,exist_ok=True); "
            "os.chown(p,int(sys.argv[2]),int(sys.argv[3])); "
            "os.chmod(p,int(sys.argv[4],8))"
        )
        privileged_run(
            sys.executable, "-c", code, str(path), str(owner[0]), str(owner[1]),
            f"{mode:o}",
        )

    try:
        primary = system_root()
        first = bootstrap_run(
            primary, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment,
        )
        first_value = json.loads(first.stdout)
        expected_output_keys = {
            "anchor", "anchor_sha256", "changed", "namespace", "state", "state_digest",
        }
        assert set(first_value) == expected_output_keys and first_value["changed"] is True
        assert first_value["anchor"] == "/etc/airlock/managed-channel.json"
        assert first_value["namespace"] == f"/var/lib/airlock/managed/{writer_uid}"
        assert first_value["state"] == f"/var/lib/airlock/managed/{writer_uid}/managed-state.json"

        anchor_path = under_root(primary, first_value["anchor"])
        namespace = under_root(primary, first_value["namespace"])
        state_path = under_root(primary, first_value["state"])
        copied_authority = namespace / "authority"
        managed_parent = namespace.parent
        anchor_raw = anchor_path.read_bytes()
        anchor = json.loads(anchor_raw)
        state_raw = state_path.read_bytes()
        state_value = json.loads(state_raw)
        assert anchor_raw == RF.canonical(anchor)
        assert hashlib.sha256(anchor_raw).hexdigest() == first_value["anchor_sha256"]
        assert RF.digest(state_raw) == first_value["state_digest"]
        assert anchor["schema"] == "airlock.managed.install-anchor/v1"
        assert anchor["writer_uid"] == writer_uid and anchor["writer_gid"] == writer_gid
        assert anchor["organization_id"] == state_value["organization_id"]
        assert anchor["root_key_id"] == state_value["root_key_id"]
        assert anchor["enrollment_digest"] == state_value["enrollment_digest"]
        assert anchor["channel_id"] == state_value["snapshot"]["channel_id"]
        assert (anchor_path.stat().st_uid, anchor_path.stat().st_gid, stat.S_IMODE(anchor_path.stat().st_mode)) == (0, 0, 0o644)
        assert (namespace.stat().st_uid, namespace.stat().st_gid, stat.S_IMODE(namespace.stat().st_mode)) == (writer_uid, writer_gid, 0o700)
        counters["anchor_state"] = 1

        repeated = bootstrap_run(
            primary, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment,
        )
        assert json.loads(repeated.stdout)["changed"] is False
        assert anchor_path.read_bytes() == anchor_raw and state_path.read_bytes() == state_raw
        counters["repeat_safe"] = 1

        conflict = bootstrap_run(
            primary, writer_uid, writer_gid, stage, authority,
            conflicting_selection, enrollment, ok=False,
        )
        assert conflict.stdout == b""
        assert anchor_path.read_bytes() == anchor_raw and state_path.read_bytes() == state_raw
        counters["state_conflict_rejects"] = 1

        delegated_result = delegated_run(
            writer_uid, writer_gid,
            sys.executable, str(STATE), "select", "--state", str(state_path),
            "--release", str(next_stage), "--authority", str(copied_authority),
            "--selection", str(next_selection), "--at", LATER,
        )
        assert json.loads(delegated_result.stdout)["changed"] is True
        assert json.loads(state_path.read_text())["owner_selection"]["sequence"] == 2
        counters["nonroot_namespace_write"] = 1

        boundary_code = '''
import os
import pathlib
import sys

anchor, parent, namespace = map(pathlib.Path, sys.argv[1:])
try:
    os.open(anchor, os.O_WRONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0))
except PermissionError:
    pass
else:
    raise SystemExit("delegated writer opened root anchor for write")
try:
    (parent / "escaped").write_text("escape")
except PermissionError:
    pass
else:
    raise SystemExit("delegated writer wrote outside its namespace")
proof = namespace / "delegated-write-proof"
proof.write_text("writer-only")
proof.unlink()
'''
        delegated_run(
            writer_uid, writer_gid, sys.executable, "-c", boundary_code,
            str(anchor_path), str(managed_parent), str(namespace),
        )
        assert anchor_path.read_bytes() == anchor_raw and not (managed_parent / "escaped").exists()
        counters["nonroot_anchor_rejects"] = 1

        membership_path = copied_authority / "current-membership.json"
        membership_raw = membership_path.read_bytes()
        forged = json.loads(membership_raw)
        forged["sequence"] += 1
        delegated_write(writer_uid, writer_gid, membership_path, RF.canonical(forged))
        before_forgery = state_path.read_bytes()
        forged_result = delegated_run(
            writer_uid, writer_gid,
            sys.executable, str(STATE), "select", "--state", str(state_path),
            "--release", str(next_stage), "--authority", str(copied_authority),
            "--selection", str(forged_selection), "--at", LATER, ok=False,
        )
        assert forged_result.stdout == b"" and state_path.read_bytes() == before_forgery
        delegated_write(writer_uid, writer_gid, membership_path, membership_raw)
        counters["nonroot_authority_rejects"] = 1

        partial = system_root()
        partial_first = bootstrap_run(
            partial, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment,
        )
        partial_value = json.loads(partial_first.stdout)
        partial_namespace = under_root(partial, partial_value["namespace"])
        privileged_run("/usr/bin/chown", "0:0", str(partial_namespace))
        recovered = bootstrap_run(
            partial, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment,
        )
        assert json.loads(recovered.stdout)["changed"] is True
        assert (partial_namespace.stat().st_uid, partial_namespace.stat().st_gid) == (writer_uid, writer_gid)
        counters["partial_recovery"] = 1

        insecure = system_root()
        insecure_parent = under_root(insecure, "/var/lib/airlock/managed")
        prepare_path(insecure_parent, mode=0o777)
        insecure_result = bootstrap_run(
            insecure, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment, ok=False,
        )
        assert insecure_result.stdout == b""
        assert not under_root(insecure, "/etc/airlock/managed-channel.json").exists()
        counters["insecure_parent_rejects"] = 1

        wrong_owner = system_root()
        wrong_parent = under_root(wrong_owner, "/var/lib/airlock/managed")
        prepare_path(wrong_parent, owner=(writer_uid, writer_gid))
        wrong_result = bootstrap_run(
            wrong_owner, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment, ok=False,
        )
        assert wrong_result.stdout == b""
        assert not under_root(wrong_owner, "/etc/airlock/managed-channel.json").exists()
        counters["wrong_owner_rejects"] = 1

        symlink_root = system_root()
        prepare_path(symlink_root / "etc")
        prepare_path(symlink_root / "symlink-target")
        privileged_run(
            sys.executable, "-c",
            "import os,sys; os.symlink(sys.argv[1],sys.argv[2])",
            str(symlink_root / "symlink-target"), str(symlink_root / "etc/airlock"),
        )
        symlink_result = bootstrap_run(
            symlink_root, writer_uid, writer_gid, stage, authority,
            initial_selection, enrollment, ok=False,
        )
        assert symlink_result.stdout == b""
        assert not under_root(symlink_root, "/etc/airlock/managed-channel.json").exists()
        counters["symlink_rejects"] = 1

        concurrent = system_root()
        commands = [
            privileged_argv(*bootstrap_argv(
                concurrent, writer_uid, writer_gid, stage, authority,
                selection, enrollment,
            ))
            for selection in (initial_selection, conflicting_selection)
        ]
        processes = [
            subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for command in commands
        ]
        results = [process.communicate() + (process.returncode,) for process in processes]
        assert sorted(result[2] for result in results) == [0, 2]
        concurrent_state = json.loads(
            under_root(concurrent, f"/var/lib/airlock/managed/{writer_uid}/managed-state.json").read_text()
        )
        allowed_digests = {
            RF.digest(RF.canonical(json.loads(path.read_text())))
            for path in (initial_selection, conflicting_selection)
        }
        assert concurrent_state["owner_selection_digest"] in allowed_digests
        counters["concurrent_conflict"] = 1
    finally:
        for path in reversed(roots):
            remove_system_root(path)

    assert counters == {
        "anchor_state": 1,
        "repeat_safe": 1,
        "wrong_owner_rejects": 1,
        "insecure_parent_rejects": 1,
        "symlink_rejects": 1,
        "state_conflict_rejects": 1,
        "partial_recovery": 1,
        "concurrent_conflict": 1,
        "nonroot_namespace_write": 1,
        "nonroot_anchor_rejects": 1,
        "nonroot_authority_rejects": 1,
    }
    return counters


def bootstrap_legacy_fixture() -> int:
    counters = {
        "fresh_unchanged": 0,
        "legacy_bound": 0,
        "exact_retry": 0,
        "partial_recovery": 0,
        "conflict_rejects": 0,
        "missing_rejects": 0,
        "invalid_rejects": 0,
        "ambiguous_rejects": 0,
        "untrusted_rejects": 0,
        "changed_rejects": 0,
    }
    writer_uid, writer_gid = delegated_identity()
    system_roots: list[Path] = []

    def system_root() -> Path:
        path = new_system_root()
        system_roots.append(path)
        return path

    def published_bytes(path: Path) -> dict[str, bytes]:
        return {
            item.relative_to(path).as_posix(): item.read_bytes()
            for item in sorted(path.rglob("*"))
            if (item.is_file() and not item.is_symlink()
                and item.name != ".bootstrap.lock")
        }

    with tempfile.TemporaryDirectory(prefix="airlock-managed-legacy-bootstrap-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        root_der, root_key_id = RF.generate_key(root_key)
        publisher_der, publisher_key_id = RF.generate_key(publisher_key)
        authority = root / "authority"
        make_authority(authority, root_key, root_der, publisher_der, publisher_key_id)
        stage = make_stage(root, publisher_key, sequence=71)
        enrollment = root / "enrollment.json"
        RF.write_json(enrollment, {
            "capability_ceilings": {
                "available-app": [], "notes": [], "required-app": [],
            },
            "organization_id": "fixture-org",
            "root_key_id": root_key_id,
            "schema": "airlock.managed.enrollment/v1",
        })
        selection = root / "selection.json"
        RF.write_json(selection, selection_value(snapshot_digest(stage), [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 1))
        local_only = root / "local-only"
        required_local = root / "required-local"
        materialize_package(local_only, "local-only", required_secret=True)
        materialize_package(required_local, "required-app", required_secret=True)
        config = root / "airlock.toml"
        config_raw = config_text(local_only, required_local).encode()
        config.write_bytes(config_raw)
        config.chmod(0o600)
        conflicting_config = root / "other-airlock.toml"
        conflicting_raw = config_text(
            local_only, required_local, owner="other-owner@fixture.dev",
        ).encode()
        conflicting_config.write_bytes(conflicting_raw)
        conflicting_config.chmod(0o600)

        try:
            fresh_root = system_root()
            fresh = bootstrap_run(
                fresh_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment,
            )
            fresh_value = json.loads(fresh.stdout)
            fresh_state = under_root(fresh_root, fresh_value["state"])
            assert set(fresh_value) == {
                "anchor", "anchor_sha256", "changed", "namespace", "state",
                "state_digest",
            }
            assert json.loads(fresh_state.read_text())["legacy_adoption"] is None
            counters["fresh_unchanged"] = 1

            legacy_root = system_root()
            first = bootstrap_run(
                legacy_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=config,
            )
            first_value = json.loads(first.stdout)
            state_path = under_root(legacy_root, first_value["state"])
            state_value = json.loads(state_path.read_text())
            assert first_value["changed"] is True
            assert state_value["legacy_adoption"] == {
                "config_digest": RF.digest(config_raw),
                "owner_identity_digest": RF.digest(RF.canonical("owner@fixture.dev")),
            }
            assert b"owner@fixture.dev" not in state_path.read_bytes()
            assert b"SECRET_REFERENCE" not in state_path.read_bytes()
            counters["legacy_bound"] = 1

            before_retry = published_bytes(legacy_root)
            retry = bootstrap_run(
                legacy_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=config,
            )
            assert json.loads(retry.stdout)["changed"] is False
            assert published_bytes(legacy_root) == before_retry
            counters["exact_retry"] = 1

            for candidate in (conflicting_config, None):
                before_conflict = published_bytes(legacy_root)
                conflict = bootstrap_run(
                    legacy_root, writer_uid, writer_gid, stage, authority,
                    selection, enrollment, legacy_config=candidate, ok=False,
                )
                assert conflict.stdout == b""
                assert published_bytes(legacy_root) == before_conflict
                counters["conflict_rejects"] += 1

            partial_root = system_root()
            partial_first = bootstrap_run(
                partial_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=config,
            )
            partial_value = json.loads(partial_first.stdout)
            partial_namespace = under_root(partial_root, partial_value["namespace"])
            partial_state = under_root(partial_root, partial_value["state"])
            partial_state_raw = partial_state.read_bytes()
            privileged_run("/usr/bin/chown", "0:0", str(partial_namespace))
            recovered = bootstrap_run(
                partial_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=config,
            )
            assert json.loads(recovered.stdout)["changed"] is True
            assert partial_state.read_bytes() == partial_state_raw
            assert json.loads(partial_state.read_text())["legacy_adoption"] == state_value["legacy_adoption"]
            counters["partial_recovery"] = 1

            missing_root = system_root()
            missing = bootstrap_run(
                missing_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=root / "missing.toml", ok=False,
            )
            assert missing.stdout == b"" and not under_root(
                missing_root, "/etc/airlock/managed-channel.json",
            ).exists()
            counters["missing_rejects"] = 1

            invalid_config = root / "invalid.toml"
            invalid_config.write_bytes(b"[auth]\nowner = [\n")
            invalid_config.chmod(0o600)
            invalid_root = system_root()
            invalid = bootstrap_run(
                invalid_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=invalid_config, ok=False,
            )
            assert invalid.stdout == b"" and not under_root(
                invalid_root, "/etc/airlock/managed-channel.json",
            ).exists()
            counters["invalid_rejects"] = 1

            ambiguous_config = root / "ambiguous.toml"
            ambiguous_config.write_text(config_text(local_only, required_local, owner=""))
            ambiguous_config.chmod(0o600)
            ambiguous_root = system_root()
            ambiguous = bootstrap_run(
                ambiguous_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=ambiguous_config, ok=False,
            )
            assert ambiguous.stdout == b"" and not under_root(
                ambiguous_root, "/etc/airlock/managed-channel.json",
            ).exists()
            counters["ambiguous_rejects"] = 1

            untrusted_config = root / "untrusted.toml"
            untrusted_config.write_bytes(config_raw)
            untrusted_config.chmod(0o622)
            untrusted_root = system_root()
            untrusted = bootstrap_run(
                untrusted_root, writer_uid, writer_gid, stage, authority,
                selection, enrollment, legacy_config=untrusted_config, ok=False,
            )
            assert untrusted.stdout == b"" and not under_root(
                untrusted_root, "/etc/airlock/managed-channel.json",
            ).exists()
            counters["untrusted_rejects"] = 1

            changed_config = root / "changing.toml"
            changed_config.write_bytes(config_raw)
            changed_config.chmod(0o600)
            ready = root / "mutator.ready"
            stop = root / "mutator.stop"
            mutator_code = '''
import os
import pathlib
import sys

path, ready, stop = map(pathlib.Path, sys.argv[1:4])
values = [bytes.fromhex(sys.argv[4]), bytes.fromhex(sys.argv[5])]
ready.write_text("ready")
index = 0
while not stop.exists():
    temporary = path.with_name(path.name + ".next")
    temporary.write_bytes(values[index])
    temporary.chmod(0o600)
    os.replace(temporary, path)
    index = 1 - index
'''
            mutator = subprocess.Popen([
                sys.executable, "-c", mutator_code, str(changed_config),
                str(ready), str(stop), config_raw.hex(), conflicting_raw.hex(),
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for _ in range(10000):
                if ready.exists():
                    break
            assert ready.exists()
            changed_root = system_root()
            try:
                changed = bootstrap_run(
                    changed_root, writer_uid, writer_gid, stage, authority,
                    selection, enrollment, legacy_config=changed_config, ok=False,
                )
            finally:
                stop.write_text("stop")
                mutator_stdout, mutator_stderr = mutator.communicate(timeout=10)
            assert mutator.returncode == 0, (mutator_stdout, mutator_stderr)
            assert changed.stdout == b"" and b"changed" in changed.stderr
            assert not under_root(
                changed_root, "/etc/airlock/managed-channel.json",
            ).exists()
            counters["changed_rejects"] = 1
        finally:
            for path in reversed(system_roots):
                remove_system_root(path)

    assert counters == {
        "fresh_unchanged": 1,
        "legacy_bound": 1,
        "exact_retry": 1,
        "partial_recovery": 1,
        "conflict_rejects": 2,
        "missing_rejects": 1,
        "invalid_rejects": 1,
        "ambiguous_rejects": 1,
        "untrusted_rejects": 1,
        "changed_rejects": 1,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed bootstrap legacy ABI fixture: PASS")
    print(
        "AC-MAU-D3L | expected: fresh_unchanged==1 && legacy_bound==1 && "
        "exact_retry==1 && partial_recovery==1 && conflict_rejects==2 && "
        "missing_rejects==1 && invalid_rejects==1 && ambiguous_rejects==1 && "
        "untrusted_rejects==1 && changed_rejects==1 | observed: "
        + ",".join(f"{key}={value}" for key, value in counters.items())
        + f" | verdict: PASS | signal: fixture | evidence: install/test-managed-state.py@{revision}"
    )
    return 0


def refresh_lifecycle_fixture() -> int:
    counters = {
        "installed_refresh": 0,
        "lapse_blocks_refresh": 0,
        "unenroll_blocks_refresh": 0,
        "cached_survives_lapse": 0,
        "cached_survives_unenroll": 0,
        "state_preserved": 0,
        "public_local_preserved": 0,
        "fleet_stopped": 0,
        "trusted_transition": 0,
        "transition_floor": 0,
    }
    writer_uid, writer_gid = delegated_identity()
    system_root = new_system_root()

    def namespace_bytes(path: Path) -> dict[str, bytes]:
        return {
            item.relative_to(path).as_posix(): item.read_bytes()
            for item in sorted(path.rglob("*"))
            if item.is_file() and not item.is_symlink()
        }

    def installed(command: str, *arguments: str, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
        return delegated_run(
            writer_uid, writer_gid, sys.executable, str(STATE), command,
            "--root-prefix", str(system_root), *arguments, ok=ok,
        )

    def transition(status: str, anchor_sha256: str, at: str, *, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
        return privileged_run(
            sys.executable, str(STATE), "access-transition",
            "--root-prefix", str(system_root), "--status", status,
            "--expected-anchor-sha256", anchor_sha256, "--at", at, ok=ok,
        )

    with tempfile.TemporaryDirectory(prefix="airlock-managed-lifecycle-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        root_der, root_key_id = RF.generate_key(root_key)
        publisher_der, publisher_key_id = RF.generate_key(publisher_key)
        authority = root / "authority"
        make_authority(authority, root_key, root_der, publisher_der, publisher_key_id)
        stages = [make_stage(root, publisher_key, sequence=sequence) for sequence in (81, 82, 83)]
        enrollment = root / "enrollment.json"
        RF.write_json(enrollment, {
            "capability_ceilings": {
                "available-app": [], "notes": [], "required-app": [],
            },
            "organization_id": "fixture-org",
            "root_key_id": root_key_id,
            "schema": "airlock.managed.enrollment/v1",
        })
        selection = root / "selection.json"
        RF.write_json(selection, selection_value(snapshot_digest(stages[0]), [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 1))
        try:
            boot = json.loads(bootstrap_run(
                system_root, writer_uid, writer_gid, stages[0], authority,
                selection, enrollment,
            ).stdout)
            state_path = under_root(system_root, boot["state"])
            namespace = under_root(system_root, boot["namespace"])
            state_raw = state_path.read_bytes()

            first = json.loads(installed(
                "refresh-installed", "--source", str(stages[0]), "--at", LATER,
            ).stdout)
            second = json.loads(installed(
                "refresh-installed", "--source", str(stages[1]), "--at", LATER,
            ).stdout)
            assert first["access_status"] == "active"
            assert second["access_status"] == "active"
            counters["installed_refresh"] = 1

            active = json.loads(installed("inspect-installed-access").stdout)
            assert active == {
                "fleet_evidence_allowed": True,
                "organization_snapshots_allowed": True,
                "public_local_updates_allowed": True,
                "recovery_bundles_preserved": True,
                "running_apps_preserved": True,
                "status": "active",
            }
            namespace_before_lapse = namespace_bytes(namespace)
            untrusted = installed(
                "access-transition", "--status", "lapsed",
                "--expected-anchor-sha256", boot["anchor_sha256"],
                "--at", "2026-09-12T04:02:00Z", ok=False,
            )
            assert b"must run as root:root" in untrusted.stderr
            wrong_anchor = transition(
                "lapsed", "0" * 64, "2026-09-12T04:02:00Z", ok=False,
            )
            assert b"another install anchor" in wrong_anchor.stderr
            counters["trusted_transition"] = 1

            lapsed = json.loads(transition(
                "lapsed", boot["anchor_sha256"], "2026-09-12T04:02:00Z",
            ).stdout)
            assert lapsed == {
                "changed": True,
                "path": "/etc/airlock/managed-access.json",
                "status": "lapsed",
            }
            lapsed_status = json.loads(installed("inspect-installed-access").stdout)
            assert lapsed_status["organization_snapshots_allowed"] is False
            assert lapsed_status["fleet_evidence_allowed"] is False
            assert lapsed_status["running_apps_preserved"] is True
            assert lapsed_status["recovery_bundles_preserved"] is True
            assert lapsed_status["public_local_updates_allowed"] is True
            counters["fleet_stopped"] = 1
            counters["public_local_preserved"] = 1

            store_state = namespace / "store/release-state.json"
            store_before_refusal = store_state.read_bytes()
            releases_before_refusal = sorted((namespace / "store/releases").iterdir())
            refused_lapse = installed(
                "refresh-installed", "--source", str(stages[2]), "--at", LATER,
                ok=False,
            )
            assert b"snapshots stop" in refused_lapse.stderr
            assert store_state.read_bytes() == store_before_refusal
            assert sorted((namespace / "store/releases").iterdir()) == releases_before_refusal
            counters["lapse_blocks_refresh"] = 1

            current_cached = json.loads(installed(
                "resolve-installed-cached", "--snapshot-digest",
                second["snapshot_digest"], "--at", LATER,
            ).stdout)
            predecessor_cached = json.loads(installed(
                "resolve-installed-cached", "--snapshot-digest",
                first["snapshot_digest"], "--at", LATER,
            ).stdout)
            assert current_cached["access_status"] == "lapsed"
            assert predecessor_cached["access_status"] == "lapsed"
            counters["cached_survives_lapse"] = 1

            unenrolled = json.loads(transition(
                "unenrolled", boot["anchor_sha256"], "2026-09-12T04:03:00Z",
            ).stdout)
            assert unenrolled["changed"] is True and unenrolled["status"] == "unenrolled"
            repeat = json.loads(transition(
                "unenrolled", boot["anchor_sha256"], "2026-09-12T04:03:00Z",
            ).stdout)
            assert repeat["changed"] is False
            reverse = transition(
                "lapsed", boot["anchor_sha256"], "2026-09-12T04:04:00Z",
                ok=False,
            )
            assert b"not admitted" in reverse.stderr
            counters["transition_floor"] = 1
            refused_unenroll = installed(
                "refresh-installed", "--source", str(stages[2]), "--at", LATER,
                ok=False,
            )
            assert b"snapshots stop" in refused_unenroll.stderr
            counters["unenroll_blocks_refresh"] = 1
            after_unenroll = json.loads(installed(
                "resolve-installed-cached", "--snapshot-digest",
                second["snapshot_digest"], "--at", LATER,
            ).stdout)
            assert after_unenroll["access_status"] == "unenrolled"
            counters["cached_survives_unenroll"] = 1
            assert state_path.read_bytes() == state_raw
            assert namespace_bytes(namespace) == namespace_before_lapse
            counters["state_preserved"] = 1
        finally:
            remove_system_root(system_root)

    assert counters == {
        "installed_refresh": 1,
        "lapse_blocks_refresh": 1,
        "unenroll_blocks_refresh": 1,
        "cached_survives_lapse": 1,
        "cached_survives_unenroll": 1,
        "state_preserved": 1,
        "public_local_preserved": 1,
        "fleet_stopped": 1,
        "trusted_transition": 1,
        "transition_floor": 1,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed installed refresh/lifecycle fixture: PASS")
    print(
        "AC-MAU-SRO | expected: "
        + " && ".join(f"{key}=={value}" for key, value in counters.items())
        + " | observed: " + ",".join(f"{key}={value}" for key, value in counters.items())
        + f" | verdict: PASS | signal: fixture | evidence: install/test-managed-state.py@{revision}"
    )
    return 0


class SchemaError(Exception):
    pass


class SchemaValidator:
    def __init__(self, directory: Path):
        self.directory = directory
        self.documents: dict[str, dict[str, Any]] = {}

    def document(self, name: str) -> dict[str, Any]:
        if name not in self.documents:
            self.documents[name] = json.loads((self.directory / name).read_text())
        return self.documents[name]

    @staticmethod
    def pointer(document: Any, fragment: str) -> Any:
        value = document
        if fragment:
            if not fragment.startswith("/"):
                raise SchemaError(f"unsupported schema fragment {fragment!r}")
            for raw in fragment.removeprefix("/").split("/"):
                token = raw.replace("~1", "/").replace("~0", "~")
                value = value[token]
        return value

    def resolve(self, ref: str, current_name: str) -> tuple[Any, str, dict[str, Any]]:
        target_name, separator, fragment = ref.partition("#")
        name = target_name or current_name
        document = self.document(name)
        return self.pointer(document, fragment if separator else ""), name, document

    def validate(self, instance: Any, schema: dict[str, Any], current_name: str, root: dict[str, Any] | None = None, where: str = "$") -> None:
        root = root or self.document(current_name)
        if "$ref" in schema:
            resolved, name, document = self.resolve(schema["$ref"], current_name)
            self.validate(instance, resolved, name, document, where)
            return
        if "oneOf" in schema:
            matches = 0
            for branch in schema["oneOf"]:
                try:
                    self.validate(instance, branch, current_name, root, where)
                    matches += 1
                except SchemaError:
                    pass
            if matches != 1:
                raise SchemaError(f"{where}: oneOf matched {matches} branches")
        if "const" in schema and instance != schema["const"]:
            raise SchemaError(f"{where}: const mismatch")
        if "enum" in schema and instance not in schema["enum"]:
            raise SchemaError(f"{where}: enum mismatch")
        expected_type = schema.get("type")
        type_ok = {
            "object": isinstance(instance, dict),
            "array": isinstance(instance, list),
            "string": isinstance(instance, str),
            "integer": isinstance(instance, int) and not isinstance(instance, bool),
            "null": instance is None,
        }.get(expected_type, True)
        if not type_ok:
            raise SchemaError(f"{where}: expected {expected_type}")
        # JSON Schema supplies this pattern at runtime; the fixture is intentionally
        # proving the checked-in schema rather than duplicating a second literal.
        if isinstance(instance, str) and "pattern" in schema and re.search(schema["pattern"], instance) is None:  # noqa: regex-anchor
            raise SchemaError(f"{where}: pattern mismatch")
        if isinstance(instance, int) and not isinstance(instance, bool) and "minimum" in schema and instance < schema["minimum"]:
            raise SchemaError(f"{where}: below minimum")
        if isinstance(instance, list):
            if len(instance) < schema.get("minItems", 0):
                raise SchemaError(f"{where}: too few items")
            if schema.get("uniqueItems") and len({RF.canonical(item) for item in instance}) != len(instance):
                raise SchemaError(f"{where}: duplicate items")
            if "items" in schema:
                for index, item in enumerate(instance):
                    self.validate(item, schema["items"], current_name, root, f"{where}[{index}]")
        if isinstance(instance, dict):
            properties = schema.get("properties", {})
            missing = set(schema.get("required", [])) - set(instance)
            if missing:
                raise SchemaError(f"{where}: missing {sorted(missing)}")
            if "propertyNames" in schema:
                for key in instance:
                    self.validate(key, schema["propertyNames"], current_name, root, f"{where}.<key>")
            for key, value in instance.items():
                if key in properties:
                    self.validate(value, properties[key], current_name, root, f"{where}.{key}")
                elif schema.get("additionalProperties") is False:
                    raise SchemaError(f"{where}: extra property {key}")
                elif isinstance(schema.get("additionalProperties"), dict):
                    self.validate(value, schema["additionalProperties"], current_name, root, f"{where}.{key}")

    def validate_document(self, instance: Any, name: str) -> None:
        document = self.document(name)
        self.validate(instance, document, name, document)


def main() -> int:
    counters = {
        "fresh_write": 0,
        "sequence_advance": 0,
        "idempotent": 0,
        "rollback_rejects": 0,
        "equivocation_rejects": 0,
        "concurrent_converges": 0,
        "post_projection_floor": 0,
        "private_state": 0,
        "authority_advance": 0,
        "same_epoch_sequence_advance": 0,
        "cross_channel_rejects": 0,
        "original_channel_followup": 0,
        "same_channel_epoch_advance": 0,
        "membership_rollback_rejects": 0,
        "membership_equivocation_rejects": 0,
        "capability_rejects": 0,
        "invalid_authority_rejects": 0,
        "root_mismatch_rejects": 0,
        "org_mismatch_rejects": 0,
        "adoption": 0,
        "repeat_adoption_rejects": 0,
        "ambiguous_adoption_rejects": 0,
        "public_builtin": 0,
        "public_org_only_rejects": 0,
        "schema_valid": 0,
        "schema_drift_rejects": 0,
    }
    validator = SchemaValidator(SCHEMA_DIR)
    with tempfile.TemporaryDirectory(prefix="airlock-managed-state-test-") as temporary:
        root = Path(temporary)
        root.chmod(0o755)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        root_der, root_key_id = RF.generate_key(root_key)
        publisher_der, publisher_key_id = RF.generate_key(publisher_key)
        authority = root / "authority"
        make_authority(authority, root_key, root_der, publisher_der, publisher_key_id)
        stage = make_stage(root, publisher_key, sequence=7)
        snap_digest = snapshot_digest(stage)

        local_only = root / "local-only"
        required_local = root / "required-local"
        materialize_package(local_only, "local-only", required_secret=True)
        materialize_package(required_local, "required-app", required_secret=True)
        config = root / "airlock.toml"
        config.write_text(config_text(local_only, required_local))
        config_before = config.read_bytes()
        env = dict(os.environ, AIRLOCK_STATE_DIR=str(root / "runtime-state"))

        enrollment_value = {
            "capability_ceilings": {
                "available-app": [],
                "notes": [],
                "required-app": [],
            },
            "organization_id": "fixture-org",
            "root_key_id": root_key_id,
            "schema": "airlock.managed.enrollment/v1",
        }
        enrollment = root / "enrollment.json"
        RF.write_json(enrollment, enrollment_value)
        initial_value = selection_value(snap_digest, [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 1)
        initial_selection = root / "selection-1.json"
        RF.write_json(initial_selection, initial_value)
        state = root / "managed-state.json"

        channel_authority = root / "channel-authority"
        make_authority(
            channel_authority, root_key, root_der, publisher_der, publisher_key_id,
            channels=[
                {"channel_id": "canary", "epoch": 1},
                {"channel_id": "stable", "epoch": 1},
            ],
        )
        channel_rows = [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ]
        stable_50 = make_stage(root, publisher_key, channel="stable", epoch=1, sequence=50)
        stable_50_selection = root / "channel-stable-50-selection.json"
        RF.write_json(
            stable_50_selection,
            selection_value(snapshot_digest(stable_50), channel_rows, 1),
        )
        channel_state = root / "channel-state.json"
        state_run(
            "enroll", channel_state, stable_50, channel_authority, stable_50_selection,
            enrollment=enrollment,
        )

        canary_60 = make_stage(root, publisher_key, channel="canary", epoch=1, sequence=60)
        canary_60_selection = root / "channel-canary-60-selection.json"
        RF.write_json(
            canary_60_selection,
            selection_value(snapshot_digest(canary_60), channel_rows, 2),
        )
        channel_before_rejection = channel_state.read_bytes()
        result = state_run(
            "select", channel_state, canary_60, channel_authority,
            canary_60_selection, ok=False,
        )
        assert b"channel" in result.stderr and channel_state.read_bytes() == channel_before_rejection
        counters["cross_channel_rejects"] = 1

        stable_51 = make_stage(root, publisher_key, channel="stable", epoch=1, sequence=51)
        stable_51_selection = root / "channel-stable-51-selection.json"
        RF.write_json(
            stable_51_selection,
            selection_value(snapshot_digest(stable_51), channel_rows, 2),
        )
        state_run("select", channel_state, stable_51, channel_authority, stable_51_selection)
        channel_state_value = json.loads(channel_state.read_text())
        assert channel_state_value["snapshot"]["channel_id"] == "stable"
        assert channel_state_value["snapshot"]["sequence"] == 51
        counters["same_epoch_sequence_advance"] = 1
        counters["original_channel_followup"] = 1

        channel_authority_epoch_2 = root / "channel-authority-epoch-2"
        make_authority(
            channel_authority_epoch_2, root_key, root_der, publisher_der,
            publisher_key_id, sequence=2,
            channels=[
                {"channel_id": "canary", "epoch": 1},
                {"channel_id": "stable", "epoch": 2},
            ],
        )
        stable_epoch_2 = make_stage(root, publisher_key, channel="stable", epoch=2, sequence=1)
        stable_epoch_2_selection = root / "channel-stable-epoch-2-selection.json"
        RF.write_json(
            stable_epoch_2_selection,
            selection_value(snapshot_digest(stable_epoch_2), channel_rows, 3),
        )
        state_run(
            "select", channel_state, stable_epoch_2, channel_authority_epoch_2,
            stable_epoch_2_selection,
        )
        channel_state_value = json.loads(channel_state.read_text())
        assert channel_state_value["snapshot"]["channel_id"] == "stable"
        assert channel_state_value["snapshot"]["epoch"] == 2
        assert channel_state_value["snapshot"]["sequence"] == 1
        counters["same_channel_epoch_advance"] = 1

        validator.validate_document(enrollment_value, "managed-state-v1.schema.json")
        validator.validate_document(initial_value, "desired-state-v1.schema.json")
        counters["schema_valid"] += 2
        adopt_result = state_run(
            "adopt", state, stage, authority, initial_selection,
            enrollment=enrollment, config=config,
        )
        assert json.loads(adopt_result.stdout)["changed"] is True
        state_value = json.loads(state.read_text())
        validator.validate_document(state_value, "managed-state-v1.schema.json")
        counters["schema_valid"] += 1
        assert state_value["legacy_adoption"] is not None
        assert b"owner@fixture.dev" not in state.read_bytes()
        assert b"SECRET_REFERENCE" not in state.read_bytes()
        assert config.read_bytes() == config_before
        counters["adoption"] = 1
        assert stat.S_IMODE(state.stat().st_mode) == 0o600
        counters["private_state"] = 1

        projection_output = root / "projection.json"
        write_private(projection_output, b"projection-sentinel\n")
        projector_run(config, stage, authority, state, projection_output, env, ok=True)
        projection = json.loads(projection_output.read_text())
        validator.validate_document(projection, "desired-state-v1.schema.json")
        counters["schema_valid"] += 1
        projected_config = tomllib.loads(projection["config_toml"])
        plans = {row["id"]: row for row in projection["apps"]}
        assert plans["notes"]["source_class"] == "public"
        assert "notes" in projected_config["apps"]
        assert "notes" not in projected_config.get("packages", {})
        assert projected_config["site"]["name"] == "Fixture Site"
        assert projected_config["apps"]["local-only"]["token_env"] == "LOCAL_SECRET_REFERENCE"
        assert projected_config["apps"]["required-app"]["token_env"] == "REQUIRED_SECRET_REFERENCE"
        assert config.read_bytes() == config_before
        counters["public_builtin"] = 1

        broken_projection = copy.deepcopy(projection)
        broken_projection["unexpected"] = True
        try:
            validator.validate_document(broken_projection, "desired-state-v1.schema.json")
        except SchemaError:
            counters["schema_drift_rejects"] += 1
        broken_selection = copy.deepcopy(initial_value)
        broken_selection.pop("snapshot_digest")
        try:
            validator.validate_document(broken_selection, "desired-state-v1.schema.json")
        except SchemaError:
            counters["schema_drift_rejects"] += 1

        public_only_value = selection_value(snap_digest, [
            ("available-app", "public"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 2)
        public_only = root / "selection-2-public.json"
        RF.write_json(public_only, public_only_value)
        state_before_public = state.read_bytes()
        result = state_run("select", state, stage, authority, public_only, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_public
        public_failure_output = root / "public-org-only-projection.json"
        public_sentinel = b"public-org-only-sentinel\n"
        write_private(public_failure_output, public_sentinel)
        result = run(
            sys.executable, str(PROJECTOR), "--config", str(config), "--release", str(stage),
            "--authority", str(authority), "--selection", str(public_only), "--at", LATER,
            "--out", str(public_failure_output), env=env, ok=False,
        )
        assert result.stdout == b""
        assert public_failure_output.read_bytes() == public_sentinel
        assert state.read_bytes() == state_before_public
        counters["public_org_only_rejects"] = 1

        accepted_value = selection_value(snap_digest, [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 2)
        accepted_selection = root / "selection-2.json"
        RF.write_json(accepted_selection, accepted_value)
        state_run("select", state, stage, authority, accepted_selection)
        state_after_public = state.read_bytes()
        assert json.loads(state_after_public)["owner_selection"]["sequence"] == 2
        counters["sequence_advance"] = 1

        projection_failure_config = root / "missing-local.toml"
        projection_failure_config.write_text(config_text(local_only, required_local).replace(
            'token_env = "REQUIRED_SECRET_REFERENCE"\n\n[packages.required-app]',
            '[packages.required-app]',
        ))
        post_floor_output = root / "post-floor-projection.json"
        post_floor_sentinel = b"post-floor-sentinel\n"
        write_private(post_floor_output, post_floor_sentinel)
        result = projector_run(
            projection_failure_config, stage, authority, state, post_floor_output, env, ok=False,
        )
        assert result.stdout == b"" and post_floor_output.read_bytes() == post_floor_sentinel
        assert state.read_bytes() == state_after_public

        repeat = state_run("select", state, stage, authority, accepted_selection)
        assert json.loads(repeat.stdout)["changed"] is False
        assert state.read_bytes() == state_after_public
        counters["idempotent"] = 1

        result = state_run("select", state, stage, authority, initial_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_after_public
        counters["rollback_rejects"] = 1
        counters["post_projection_floor"] = 1

        equivocal_value = selection_value(snap_digest, [
            ("available-app", "local"), ("notes", "public"), ("required-app", "managed"),
        ], 2)
        equivocal = root / "selection-2-equivocal.json"
        RF.write_json(equivocal, equivocal_value)
        result = state_run("select", state, stage, authority, equivocal, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_after_public
        counters["equivocation_rejects"] = 1

        concurrent_paths = []
        for suffix, source in (("a", "managed"), ("b", "local")):
            value = selection_value(snap_digest, [
                ("available-app", source), ("notes", "public"), ("required-app", "managed"),
            ], 3)
            path = root / f"selection-3-{suffix}.json"
            RF.write_json(path, value)
            concurrent_paths.append(path)
        commands = []
        for path in concurrent_paths:
            commands.append([
                sys.executable, str(STATE), "select", "--state", str(state), "--release", str(stage),
                "--authority", str(authority), "--selection", str(path), "--at", LATER,
            ])
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for command in commands]
        concurrent_results = [process.communicate() + (process.returncode,) for process in processes]
        assert sorted(result[2] for result in concurrent_results) == [0, 2]
        concurrent_state = json.loads(state.read_text())
        assert concurrent_state["owner_selection"]["sequence"] == 3
        assert concurrent_state["owner_selection_digest"] in {RF.digest(RF.canonical(json.loads(path.read_text()))) for path in concurrent_paths}
        counters["concurrent_converges"] = 1

        authority2 = root / "authority-2"
        make_authority(
            authority2, root_key, root_der, publisher_der, publisher_key_id,
            sequence=2,
        )
        authority_advance_selection = root / "selection-4-authority.json"
        RF.write_json(authority_advance_selection, selection_value(snap_digest, [
            ("available-app", "managed"), ("notes", "public"), ("required-app", "managed"),
        ], 4))
        state_run("select", state, stage, authority2, authority_advance_selection)
        assert json.loads(state.read_text())["authority"]["sequence"] == 2
        counters["authority_advance"] = 1
        state_before_failures = state.read_bytes()

        next_selection = root / "selection-5.json"
        RF.write_json(next_selection, selection_value(snap_digest, [
            ("available-app", "managed"), ("notes", "public"), ("required-app", "managed"),
        ], 5))
        result = state_run("select", state, stage, authority, next_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_failures
        counters["membership_rollback_rejects"] = 1

        equivocal_authority = root / "authority-2-equivocal"
        make_authority(
            equivocal_authority, root_key, root_der, publisher_der, publisher_key_id,
            sequence=2, ceiling=["rooted-artifact", "system-unit"],
        )
        result = state_run("select", state, stage, equivocal_authority, next_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_failures
        counters["membership_equivocation_rejects"] = 1

        overcap_stage = make_stage(root, publisher_key, sequence=8, required_capabilities=["system-unit"])
        overcap_selection = root / "selection-5-overcap.json"
        RF.write_json(overcap_selection, selection_value(snapshot_digest(overcap_stage), [
            ("notes", "public"), ("required-app", "managed"),
        ], 5))
        result = state_run("select", state, overcap_stage, authority2, overcap_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_failures
        counters["capability_rejects"] = 1

        invalid_authority = root / "invalid-authority"
        invalid_authority.mkdir()
        (invalid_authority / "root-public.der").write_bytes((authority / "root-public.der").read_bytes())
        (invalid_authority / "current-membership.json").write_bytes((authority / "current-membership.json").read_bytes() + b" ")
        result = state_run("select", state, stage, invalid_authority, next_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_failures
        counters["invalid_authority_rejects"] = 1

        other_root_key = root / "other-root-key.pem"
        other_root_der, _other_root_id = RF.generate_key(other_root_key)
        other_authority = root / "other-authority"
        make_authority(other_authority, other_root_key, other_root_der, publisher_der, publisher_key_id)
        result = state_run("select", state, stage, other_authority, next_selection, ok=False)
        assert result.stdout == b"" and state.read_bytes() == state_before_failures
        counters["root_mismatch_rejects"] = 1

        repeat_adopt = state_run(
            "adopt", state, stage, authority, initial_selection,
            enrollment=enrollment, config=config, ok=False,
        )
        assert repeat_adopt.stdout == b"" and state.read_bytes() == state_before_failures
        counters["repeat_adoption_rejects"] = 1

        ambiguous_config = root / "ambiguous.toml"
        ambiguous_config.write_text(config_text(local_only, required_local, owner="owner@example.com"))
        ambiguous_state = root / "ambiguous-state.json"
        result = state_run(
            "adopt", ambiguous_state, stage, authority, initial_selection,
            enrollment=enrollment, config=ambiguous_config, ok=False,
        )
        assert result.stdout == b"" and not ambiguous_state.exists()
        counters["ambiguous_adoption_rejects"] = 1

        other_enrollment_value = copy.deepcopy(enrollment_value)
        other_enrollment_value["organization_id"] = "other-org"
        other_enrollment = root / "other-enrollment.json"
        RF.write_json(other_enrollment, other_enrollment_value)
        other_state = root / "other-state.json"
        result = state_run(
            "enroll", other_state, stage, authority, initial_selection,
            enrollment=other_enrollment, ok=False,
        )
        assert result.stdout == b"" and not other_state.exists()
        counters["org_mismatch_rejects"] = 1

        fresh_state = root / "fresh-state.json"
        result = state_run(
            "enroll", fresh_state, stage, authority, initial_selection,
            enrollment=enrollment,
        )
        assert json.loads(result.stdout)["changed"] is True
        assert json.loads(fresh_state.read_text())["legacy_adoption"] is None
        counters["fresh_write"] = 1

        bootstrap_counters = bootstrap_fixture(
            root, publisher_key, stage, authority, enrollment, initial_selection
        )

    assert counters == {
        "fresh_write": 1,
        "sequence_advance": 1,
        "idempotent": 1,
        "rollback_rejects": 1,
        "equivocation_rejects": 1,
        "concurrent_converges": 1,
        "post_projection_floor": 1,
        "private_state": 1,
        "authority_advance": 1,
        "same_epoch_sequence_advance": 1,
        "cross_channel_rejects": 1,
        "original_channel_followup": 1,
        "same_channel_epoch_advance": 1,
        "membership_rollback_rejects": 1,
        "membership_equivocation_rejects": 1,
        "capability_rejects": 1,
        "invalid_authority_rejects": 1,
        "root_mismatch_rejects": 1,
        "org_mismatch_rejects": 1,
        "adoption": 1,
        "repeat_adoption_rejects": 1,
        "ambiguous_adoption_rejects": 1,
        "public_builtin": 1,
        "public_org_only_rejects": 1,
        "schema_valid": 4,
        "schema_drift_rejects": 2,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed selection state fixture: PASS")
    print(f"AC-MAU-D3 | expected: fresh_write==1 && sequence_advance==1 && idempotent==1 && rollback_rejects==1 && equivocation_rejects==1 && concurrent_converges==1 && post_projection_floor==1 && private_state==1 && authority_advance==1 && same_epoch_sequence_advance==1 && cross_channel_rejects==1 && original_channel_followup==1 && same_channel_epoch_advance==1 | observed: fresh_write={counters['fresh_write']},sequence_advance={counters['sequence_advance']},idempotent={counters['idempotent']},rollback_rejects={counters['rollback_rejects']},equivocation_rejects={counters['equivocation_rejects']},concurrent_converges={counters['concurrent_converges']},post_projection_floor={counters['post_projection_floor']},private_state={counters['private_state']},authority_advance={counters['authority_advance']},same_epoch_sequence_advance={counters['same_epoch_sequence_advance']},cross_channel_rejects={counters['cross_channel_rejects']},original_channel_followup={counters['original_channel_followup']},same_channel_epoch_advance={counters['same_channel_epoch_advance']} | verdict: PASS | signal: fixture | evidence: install/test-managed-state.py@{revision}")
    print(f"AC-MAU-D4 | expected: capability_rejects==1 && invalid_authority_rejects==1 && membership_rollback_rejects==1 && membership_equivocation_rejects==1 && root_mismatch_rejects==1 && org_mismatch_rejects==1 && adoption==1 && repeat_adoption_rejects==1 && ambiguous_adoption_rejects==1 && public_builtin==1 && public_org_only_rejects==1 && schema_valid==4 && schema_drift_rejects==2 | observed: capability_rejects={counters['capability_rejects']},invalid_authority_rejects={counters['invalid_authority_rejects']},membership_rollback_rejects={counters['membership_rollback_rejects']},membership_equivocation_rejects={counters['membership_equivocation_rejects']},root_mismatch_rejects={counters['root_mismatch_rejects']},org_mismatch_rejects={counters['org_mismatch_rejects']},adoption={counters['adoption']},repeat_adoption_rejects={counters['repeat_adoption_rejects']},ambiguous_adoption_rejects={counters['ambiguous_adoption_rejects']},public_builtin={counters['public_builtin']},public_org_only_rejects={counters['public_org_only_rejects']},schema_valid={counters['schema_valid']},schema_drift_rejects={counters['schema_drift_rejects']} | verdict: PASS | signal: fixture | evidence: install/test-managed-state.py@{revision}")
    print(
        "AC-MAU-D3B | expected: anchor_state==1 && repeat_safe==1 && "
        "wrong_owner_rejects==1 && insecure_parent_rejects==1 && symlink_rejects==1 && "
        "state_conflict_rejects==1 && partial_recovery==1 && concurrent_conflict==1 && "
        "nonroot_namespace_write==1 && nonroot_anchor_rejects==1 && "
        "nonroot_authority_rejects==1 | observed: "
        + ",".join(f"{key}={value}" for key, value in bootstrap_counters.items())
        + f" | verdict: PASS | signal: fixture | evidence: install/test-managed-state.py@{revision}"
    )
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--bootstrap-legacy-fixture"]:
        raise SystemExit(bootstrap_legacy_fixture())
    if sys.argv[1:] == ["--refresh-offline-fixture"]:
        raise SystemExit(refresh_lifecycle_fixture())
    if sys.argv[1:]:
        raise SystemExit(
            "usage: test-managed-state.py "
            "[--bootstrap-legacy-fixture|--refresh-offline-fixture]"
        )
    raise SystemExit(main())
