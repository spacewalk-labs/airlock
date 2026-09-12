#!/usr/bin/env python3
"""Deterministic fixture for the bounded managed desired-state projector."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECTOR = ROOT / "bin/airlock-managed-projector"
RELEASE = ROOT / "bin/airlock-managed-release"
RELEASE_FIXTURE = ROOT / "install/test-managed-release.py"
SCHEMA = ROOT / "schemas/managed-app-store/desired-state-v1.schema.json"
NOW = "2026-09-12T04:00:00Z"
LATER = "2026-09-12T04:01:00Z"
CI_DIGEST = "sha256:" + "a" * 64
CORE_DIGEST = "sha256:" + "b" * 64
CORE_REVISION = "c" * 40


def load_release_fixture():
    spec = importlib.util.spec_from_file_location("managed_release_fixture", RELEASE_FIXTURE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


FX = load_release_fixture()


def run(*args: str, env: dict[str, str] | None = None, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if ok and result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr.decode(errors='replace')}")
    if not ok and result.returncode == 0:
        raise AssertionError(f"command unexpectedly passed: {' '.join(args)}\n{result.stdout.decode(errors='replace')}")
    return result


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


def make_signed_release(root: Path) -> tuple[Path, Path, str, dict[str, object]]:
    repo = root / "review"
    source = repo / "release-src"
    policies = {
        "available-app": "available",
        "blocked-app": "blocked",
        "required-app": "required",
    }
    catalog_apps = []
    locked_packages = []
    for package_id, policy in sorted(policies.items()):
        catalog_apps.append({
            "compatibility": {"platforms": ["linux"], "profiles": ["team"]},
            "id": package_id,
            "metadata": {"name": package_id, "version": "1.0.0"},
            "policy": policy,
            "source_label": "Fixture organisation",
        })
        if policy == "blocked":
            continue
        files = materialize_package(
            source / "packages" / package_id,
            package_id,
            required_secret=(package_id == "required-app"),
        )
        locked_packages.append({
            "capabilities": [],
            "data_compatibility": "stateless",
            "deactivator": "deactivate.sh",
            "digest": FX.package_digest(files),
            "id": package_id,
            "path": f"packages/{package_id}",
        })
    catalog = {
        "apps": catalog_apps,
        "channel_id": "stable",
        "organization_id": "fixture-org",
        "schema": "airlock.managed.catalog/v1",
    }
    lock = {
        "channel_id": "stable",
        "core": {"digest": CORE_DIGEST, "revision": CORE_REVISION},
        "organization_id": "fixture-org",
        "packages": locked_packages,
        "schema": "airlock.managed.release-lock/v1",
        "target_profile": "team",
    }
    FX.write_json(source / "catalog.json", catalog)
    FX.write_json(source / "release.lock", lock)
    run("git", "init", "-q", str(repo))
    run("git", "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    run("git", "-C", str(repo), "config", "user.name", "Desired state fixture")
    run("git", "-C", str(repo), "add", "release-src")
    commit_env = dict(os.environ, GIT_AUTHOR_DATE=NOW, GIT_COMMITTER_DATE=NOW)
    run("git", "-C", str(repo), "commit", "-q", "-m", "reviewed desired state", env=commit_env)
    revision = run("git", "-C", str(repo), "rev-parse", "HEAD").stdout.decode().strip()
    stage = root / "signed-release"
    run(
        sys.executable, str(RELEASE), "prepare", "--source-repo", str(repo),
        "--revision", revision, "--input-prefix", "release-src",
        "--source-repository", "fixture/desired-state", "--organization", "fixture-org",
        "--channel", "stable", "--epoch", "1", "--sequence", "7",
        "--publisher", "publisher-a", "--created-at", NOW,
        "--ci-evidence-digest", CI_DIGEST, "--out", str(stage),
    )
    root_key = root / "root-key.pem"
    publisher_key = root / "publisher-key.pem"
    root_der, _root_id = FX.generate_key(root_key)
    publisher_der, publisher_key_id = FX.generate_key(publisher_key)
    authority = root / "authority"
    membership = FX.membership_value(root_key, root_der, publisher_der, publisher_key_id)
    FX.set_membership(authority, membership, root_der)
    run(sys.executable, str(RELEASE), "sign", "--stage", str(stage), "--publisher-key", str(publisher_key))
    snapshot_raw = (stage / "snapshot.json").read_bytes()
    return stage, authority, FX.digest(snapshot_raw), lock


def config_text(local_only: Path, required_local: Path | None, *, available_local: Path | None = None, blocked_local: Path | None = None, owner: str = "owner@fixture.dev") -> str:
    rows = [
        '[airlock]\nconfig_version = 2',
        '[site]\nname = "Fixture Site"',
        f'[auth]\nprovider = "tailscale"\nowner = "{owner}"',
        '[paths]\nwiki = "/srv/fixture-wiki"',
        '[apps.hub]',
        '[apps.local-only]\ntoken_env = "LOCAL_SECRET_REFERENCE"',
        f'[packages.local-only]\npath = "{local_only}"',
    ]
    if required_local is not None:
        rows.extend([
            '[apps.required-app]\ntoken_env = "REQUIRED_SECRET_REFERENCE"',
            f'[packages.required-app]\npath = "{required_local}"',
        ])
    if available_local is not None:
        rows.extend([
            '[apps.available-app]',
            f'[packages.available-app]\npath = "{available_local}"',
        ])
    if blocked_local is not None:
        rows.extend([
            '[apps.blocked-app]',
            f'[packages.blocked-app]\npath = "{blocked_local}"',
        ])
    return "\n\n".join(rows) + "\n"


def write_private(path: Path, raw: bytes) -> None:
    path.write_bytes(raw)
    path.chmod(0o600)


def selection_value(snapshot_digest: str, rows: list[tuple[str, str]], sequence: int = 1) -> dict[str, object]:
    return {
        "organization_id": "fixture-org",
        "schema": "airlock.managed.selection/v1",
        "selections": [{"id": app_id, "source": source} for app_id, source in sorted(rows)],
        "sequence": sequence,
        "snapshot_digest": snapshot_digest,
    }


def invoke(config: Path, stage: Path, authority: Path, selection: Path, output: Path, env: dict[str, str], *, ok: bool) -> subprocess.CompletedProcess[bytes]:
    return run(
        sys.executable, str(PROJECTOR), "--config", str(config), "--release", str(stage),
        "--authority", str(authority), "--selection", str(selection), "--at", LATER,
        "--out", str(output), env=env, ok=ok,
    )


def main(emit_ac: bool) -> int:
    counters = {
        "available_select": 0,
        "required_pin": 0,
        "deterministic": 0,
        "collision_choice": 0,
        "site_values_preserved": 0,
        "secret_refs_preserved": 0,
        "operator_unchanged": 0,
        "blocked_rejects": 0,
        "collision_rejects": 0,
        "required_bypass_rejects": 0,
        "missing_local_rejects": 0,
        "identity_rejects": 0,
        "signed_release_rejects": 0,
        "prewrite_unchanged": 0,
    }
    schema = json.loads(SCHEMA.read_text())
    assert set(schema["$defs"]) == {"appId", "desiredProjection", "digest", "id", "ownerSelection"}
    assert schema["$defs"]["ownerSelection"]["additionalProperties"] is False
    assert schema["$defs"]["desiredProjection"]["additionalProperties"] is False
    with tempfile.TemporaryDirectory(prefix="airlock-managed-projector-test-") as temporary:
        root = Path(temporary)
        stage, authority, snapshot_digest, lock = make_signed_release(root)
        local_only = root / "local-only"
        required_local = root / "required-local"
        available_local = root / "available-local"
        blocked_local = root / "blocked-local"
        materialize_package(local_only, "local-only", required_secret=True)
        materialize_package(required_local, "required-app", required_secret=True)
        materialize_package(available_local, "available-app")
        materialize_package(blocked_local, "blocked-app")
        env = dict(os.environ, AIRLOCK_STATE_DIR=str(root / "state"))

        config = root / "airlock.toml"
        config.write_text(config_text(local_only, required_local))
        config_before = config.read_bytes()
        selection = root / "selection.json"
        FX.write_json(selection, selection_value(snapshot_digest, [
            ("available-app", "managed"),
            ("required-app", "managed"),
        ]))
        output1, output2 = root / "projection-1.json", root / "projection-2.json"
        write_private(output1, b"sentinel-1\n")
        write_private(output2, b"sentinel-2\n")
        invoke(config, stage, authority, selection, output1, env, ok=True)
        invoke(config, stage, authority, selection, output2, env, ok=True)
        assert output1.read_bytes() == output2.read_bytes()
        assert stat.S_IMODE(output1.stat().st_mode) == 0o600
        projection = json.loads(output1.read_text())
        assert output1.read_bytes() == FX.canonical(projection)
        assert projection["config_digest"] == FX.digest(projection["config_toml"].encode())
        projected_config = tomllib.loads(projection["config_toml"])
        plans = {row["id"]: row for row in projection["apps"]}
        locks = {row["id"]: row for row in lock["packages"]}
        assert plans["available-app"]["source_class"] == "managed"
        counters["available_select"] = 1
        assert plans["required-app"]["source_class"] == "managed"
        assert plans["required-app"]["package_digest"] == locks["required-app"]["digest"]
        assert projected_config["packages"]["required-app"]["path"] == str((stage / "packages/required-app").resolve())
        counters["required_pin"] = 1
        assert plans["blocked-app"]["source_class"] == "none"
        assert projected_config["site"]["name"] == "Fixture Site"
        assert projected_config["auth"]["owner"] == "owner@fixture.dev"
        assert projected_config["paths"]["wiki"] == "/srv/fixture-wiki"
        counters["site_values_preserved"] = 1
        assert projected_config["apps"]["local-only"]["token_env"] == "LOCAL_SECRET_REFERENCE"
        assert projected_config["apps"]["required-app"]["token_env"] == "REQUIRED_SECRET_REFERENCE"
        counters["secret_refs_preserved"] = 1
        assert config.read_bytes() == config_before
        counters["operator_unchanged"] = 1
        counters["deterministic"] = 1

        collision_config = root / "collision.toml"
        collision_config.write_text(config_text(local_only, required_local, available_local=available_local))
        collision_selection = root / "collision-selection.json"
        FX.write_json(collision_selection, selection_value(snapshot_digest, [
            ("available-app", "local"),
            ("required-app", "managed"),
        ], sequence=2))
        collision_output = root / "collision-projection.json"
        write_private(collision_output, b"collision-choice\n")
        invoke(collision_config, stage, authority, collision_selection, collision_output, env, ok=True)
        collision_projection = json.loads(collision_output.read_text())
        assert {row["id"]: row for row in collision_projection["apps"]}["available-app"]["source_class"] == "local"
        counters["collision_choice"] = 1

        failures: list[tuple[str, Path, dict[str, object]]] = [
            ("blocked", root / "blocked.toml", selection_value(snapshot_digest, [
                ("available-app", "managed"), ("required-app", "managed"),
            ], sequence=3)),
            ("collision", collision_config, selection_value(snapshot_digest, [
                ("required-app", "managed"),
            ], sequence=4)),
            ("required-bypass", config, selection_value(snapshot_digest, [
                ("available-app", "managed"), ("required-app", "local"),
            ], sequence=5)),
            ("missing-local", root / "missing-local.toml", selection_value(snapshot_digest, [
                ("available-app", "managed"),
            ], sequence=6)),
            ("identity", root / "identity.toml", selection_value(snapshot_digest, [
                ("available-app", "managed"), ("required-app", "managed"),
            ], sequence=7)),
        ]
        (root / "blocked.toml").write_text(config_text(local_only, required_local, blocked_local=blocked_local))
        (root / "missing-local.toml").write_text(config_text(local_only, None))
        (root / "identity.toml").write_text(config_text(local_only, required_local, owner="owner@example.com"))
        counter_keys = {
            "blocked": "blocked_rejects",
            "collision": "collision_rejects",
            "required-bypass": "required_bypass_rejects",
            "missing-local": "missing_local_rejects",
            "identity": "identity_rejects",
        }
        for name, failing_config, selection_value_raw in failures:
            failing_selection = root / f"{name}-selection.json"
            FX.write_json(failing_selection, selection_value_raw)
            target = root / f"{name}-projection.json"
            sentinel = f"{name}-sentinel\n".encode()
            write_private(target, sentinel)
            result = invoke(failing_config, stage, authority, failing_selection, target, env, ok=False)
            assert result.stdout == b""
            assert target.read_bytes() == sentinel
            counters[counter_keys[name]] = 1
            counters["prewrite_unchanged"] += 1

        tampered_stage = root / "tampered-release"
        shutil.copytree(stage, tampered_stage)
        (tampered_stage / "catalog.json").write_bytes((tampered_stage / "catalog.json").read_bytes() + b" ")
        tampered_output = root / "tampered-release-projection.json"
        tampered_sentinel = b"tampered-release-sentinel\n"
        write_private(tampered_output, tampered_sentinel)
        result = invoke(config, tampered_stage, authority, selection, tampered_output, env, ok=False)
        assert result.stdout == b""
        assert tampered_output.read_bytes() == tampered_sentinel
        counters["signed_release_rejects"] = 1
        counters["prewrite_unchanged"] += 1

    assert counters == {
        "available_select": 1,
        "required_pin": 1,
        "deterministic": 1,
        "collision_choice": 1,
        "site_values_preserved": 1,
        "secret_refs_preserved": 1,
        "operator_unchanged": 1,
        "blocked_rejects": 1,
        "collision_rejects": 1,
        "required_bypass_rejects": 1,
        "missing_local_rejects": 1,
        "identity_rejects": 1,
        "signed_release_rejects": 1,
        "prewrite_unchanged": 6,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed desired-state projector fixture: PASS")
    if emit_ac:
        print(f"AC-MAU-D1 | expected: available_select==1 && required_pin==1 && deterministic==1 && collision_choice==1 && site_values_preserved==1 && secret_refs_preserved==1 && operator_unchanged==1 | observed: available_select={counters['available_select']},required_pin={counters['required_pin']},deterministic={counters['deterministic']},collision_choice={counters['collision_choice']},site_values_preserved={counters['site_values_preserved']},secret_refs_preserved={counters['secret_refs_preserved']},operator_unchanged={counters['operator_unchanged']} | verdict: PASS | signal: fixture | evidence: install/test-managed-projector.py@{revision}")
        print(f"AC-MAU-D2 | expected: blocked_rejects==1 && collision_rejects==1 && required_bypass_rejects==1 && missing_local_rejects==1 && identity_rejects==1 && signed_release_rejects==1 && prewrite_unchanged==6 | observed: blocked_rejects={counters['blocked_rejects']},collision_rejects={counters['collision_rejects']},required_bypass_rejects={counters['required_bypass_rejects']},missing_local_rejects={counters['missing_local_rejects']},identity_rejects={counters['identity_rejects']},signed_release_rejects={counters['signed_release_rejects']},prewrite_unchanged={counters['prewrite_unchanged']} | verdict: PASS | signal: fixture | evidence: install/test-managed-projector.py@{revision}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-ac", action="store_true")
    args = parser.parse_args()
    raise SystemExit(main(args.emit_ac))
