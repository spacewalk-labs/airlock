#!/usr/bin/env python3
"""Deterministic fixture for the managed-state airlock-config consumer."""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
import types
from importlib.machinery import SourceFileLoader
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "bin/airlock-config"
PROJECTOR = ROOT / "bin/airlock-managed-projector"
STATE = ROOT / "bin/airlock-managed-state"
STATE_FIXTURE = ROOT / "install/test-managed-state.py"


def load_module(name: str, path: Path):
    if path.suffix == ".py":
        spec = importlib.util.spec_from_file_location(name, path)
    else:
        loader = SourceFileLoader(name, str(path))
        spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SF = load_module("managed_state_fixture_for_consumer", STATE_FIXTURE)
RF = SF.RF


def run(
    *args: str,
    env: dict[str, str] | None = None,
    ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if ok and result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"{result.stderr.decode(errors='replace')}"
        )
    if not ok and result.returncode == 0:
        raise AssertionError(
            f"command unexpectedly passed: {' '.join(args)}\n"
            f"{result.stdout.decode(errors='replace')}"
        )
    return result


def write_private(path: Path, raw: bytes) -> None:
    path.write_bytes(raw)
    path.chmod(0o600)


def invoke(
    config: Path,
    state: Path,
    stage: Path,
    authority: Path,
    output: Path,
    *,
    ok: bool,
    promoted_current: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    # Model the installer-owned handoff: the producer has one durable output
    # and returns the canonical receipt on stdout; only a successful caller
    # freezes those exact bytes into its private run file.
    receipt = output.with_name(output.name + ".receipt.json")
    write_private(receipt, b"receipt-sentinel\n")
    env = dict(os.environ, AIRLOCK_CONFIG=str(config), AIRLOCK_STATE_DIR=str(state.parent / "runtime"))
    command = [
        sys.executable, str(CONFIG), "managed-config-snapshot",
        "--state", str(state), "--release", str(stage),
        "--authority", str(authority),
    ]
    if promoted_current:
        command.append("--promoted-current")
    command.append(str(output))
    result = run(*command, env=env, ok=ok)
    if result.returncode == 0:
        assert receipt.read_bytes() == b"receipt-sentinel\n"
        write_private(receipt, result.stdout)
    return result


def managed_consumer_env(
    config: Path,
    state: Path,
    stage: Path,
    authority: Path,
    output: Path,
) -> dict[str, str]:
    receipt_path = output.with_name(output.name + ".receipt.json")
    receipt_raw = receipt_path.read_bytes()
    receipt = json.loads(receipt_raw)
    return dict(
        os.environ,
        AIRLOCK_CONFIG=str(config),
        AIRLOCK_CONFIG_SNAPSHOT=str(output),
        AIRLOCK_CONFIG_SNAPSHOT_SHA256=receipt["config_sha256"],
        AIRLOCK_MANAGED_CONFIG_RECEIPT=str(receipt_path),
        AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256=hashlib.sha256(receipt_raw).hexdigest(),
        AIRLOCK_MANAGED_STATE=str(state),
        AIRLOCK_MANAGED_RELEASE=str(stage),
        AIRLOCK_MANAGED_AUTHORITY=str(authority),
        AIRLOCK_STATE_DIR=str(state.parent / "runtime"),
    )


def authority_variant(
    path: Path,
    root_key: Path,
    root_der: bytes,
    publisher_der: bytes,
    publisher_key_id: str,
    *,
    sequence: int,
    ceiling: list[str] | None = None,
) -> None:
    SF.make_authority(
        path, root_key, root_der, publisher_der, publisher_key_id,
        sequence=sequence, ceiling=ceiling,
    )
    membership_path = path / "current-membership.json"
    membership = json.loads(membership_path.read_text())
    for publisher in membership["publishers"]:
        publisher["not_before"] = "2000-01-01T00:00:00Z"
        publisher["not_after"] = "9999-12-31T23:59:59Z"
    membership.pop("root_signature")
    membership["root_signature"] = {
        "algorithm": "ed25519",
        "signature": base64.b64encode(RF.sign(root_key, RF.canonical(membership))).decode(),
    }
    RF.write_json(membership_path, membership)


def expect_failure_unchanged(
    config: Path,
    state: Path,
    stage: Path,
    authority: Path,
    output: Path,
    sentinel: bytes,
) -> subprocess.CompletedProcess[bytes]:
    write_private(output, sentinel)
    result = invoke(config, state, stage, authority, output, ok=False)
    assert result.stdout == b""
    assert output.read_bytes() == sentinel
    receipt = output.with_name(output.name + ".receipt.json")
    assert receipt.read_bytes() == b"receipt-sentinel\n"
    return result


def wait_for_state_lock(state: Path, process: subprocess.Popen[bytes]) -> None:
    lock_path = state.with_name(state.name + ".lock")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError("managed config consumer exited before verified state locking")
        try:
            fd = os.open(lock_path, os.O_RDWR)
        except FileNotFoundError:
            time.sleep(0.002)
            continue
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            else:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
        time.sleep(0.002)
    raise AssertionError("did not observe verified state lock")


def delayed_consumer(
    root: Path,
    config: Path,
    state: Path,
    stage: Path,
    authority: Path,
    output: Path,
    *,
    label: str,
    pause_at: str,
) -> tuple[subprocess.Popen[bytes], Path, Path]:
    """Pause immediately before the lease or in post-verification validation."""
    assert pause_at in {"lease", "validate"}
    ready = root / f"{label}-ready"
    proceed = root / f"{label}-proceed"
    wrapper = root / f"{label}-managed-consumer.py"
    receipt = output.with_name(output.name + ".receipt.json")
    write_private(receipt, b"receipt-sentinel\n")
    wrapper.write_text(f'''\
import importlib.util
import os
import subprocess
import sys
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path

config_cli = Path({str(CONFIG)!r})
loader = SourceFileLoader("delayed_airlock_config", str(config_cli))
spec = importlib.util.spec_from_loader("delayed_airlock_config", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
real_run = subprocess.run
real_popen = subprocess.Popen
ready = Path({str(ready)!r})
proceed = Path({str(proceed)!r})
pause_at = {pause_at!r}
managed_state = Path({str(STATE)!r})

def pause():
    ready.write_bytes(b"ready\\n")
    deadline = time.monotonic() + 30
    while not proceed.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("timed out waiting to release deterministic consumer pause")
        time.sleep(0.002)

def delayed_run(arguments, **kwargs):
    if (pause_at == "validate" and len(arguments) >= 3
            and Path(arguments[1]) == config_cli and arguments[2] == "validate"):
        pause()
    return real_run(arguments, **kwargs)

def delayed_popen(arguments, **kwargs):
    if (pause_at == "lease" and len(arguments) >= 2
            and Path(arguments[1]) == managed_state and "--lease" in arguments):
        pause()
    return real_popen(arguments, **kwargs)

module.subprocess.run = delayed_run
module.subprocess.Popen = delayed_popen
module.cmd_managed_config_snapshot(sys.argv[1:])
''')
    env = dict(os.environ, AIRLOCK_CONFIG=str(config), AIRLOCK_STATE_DIR=str(root / "runtime"))
    process = subprocess.Popen(
        [
            sys.executable, str(wrapper), "--state", str(state),
            "--release", str(stage), "--authority", str(authority),
            str(output),
        ],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 30
    while not ready.exists():
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(
                "consumer exited before post-verification validation: "
                + (stderr or stdout).decode(errors="replace")
            )
        if time.monotonic() >= deadline:
            process.kill()
            process.wait()
            raise AssertionError("consumer never reached post-verification validation")
        time.sleep(0.002)
    return process, ready, proceed


def expect_loader_failure(action) -> None:
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            action()
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError("tampered managed projection unexpectedly passed")


def invoke_with_forged_projection(
    config_module,
    config: Path,
    state: Path,
    stage: Path,
    authority: Path,
    output: Path,
    projection_raw: bytes,
    projection_digest: str,
) -> None:
    sentinel = output.read_bytes()
    receipt = output.with_name(output.name + ".receipt.json")
    write_private(receipt, b"receipt-sentinel\n")
    real_subprocess = config_module.subprocess

    def forged_run(arguments, **_kwargs):
        assert Path(arguments[1]) == config_module.MANAGED_PROJECTOR
        projection_path = Path(arguments[arguments.index("--out") + 1])
        projection_path.write_bytes(projection_raw)
        receipt = {
            "output": str(projection_path),
            "projection_digest": projection_digest,
        }
        return subprocess.CompletedProcess(arguments, 0, RF.canonical(receipt), b"")

    original_config = os.environ.get("AIRLOCK_CONFIG")
    original_state_dir = os.environ.get("AIRLOCK_STATE_DIR")
    os.environ["AIRLOCK_CONFIG"] = str(config)
    os.environ["AIRLOCK_STATE_DIR"] = str(state.parent / "runtime")
    config_module.subprocess = types.SimpleNamespace(run=forged_run, PIPE=subprocess.PIPE)
    try:
        expect_loader_failure(lambda: config_module.cmd_managed_config_snapshot([
            "--state", str(state), "--release", str(stage),
            "--authority", str(authority), str(output),
        ]))
    finally:
        config_module.subprocess = real_subprocess
        if original_config is None:
            os.environ.pop("AIRLOCK_CONFIG", None)
        else:
            os.environ["AIRLOCK_CONFIG"] = original_config
        if original_state_dir is None:
            os.environ.pop("AIRLOCK_STATE_DIR", None)
        else:
            os.environ["AIRLOCK_STATE_DIR"] = original_state_dir
    assert output.read_bytes() == sentinel
    assert receipt.read_bytes() == b"receipt-sentinel\n"


def prepare_u1_fixture(
    material_root: Path,
    box: Path,
    core_revision: str,
    core_digest: str,
) -> int:
    """Build a real fixed-path Linux enrollment inside an isolated root.

    The caller supplies the namespace (the U1 test uses chroot in a user+mount
    namespace), not a product path override. Product code still opens only the
    production `/etc`, `/opt`, and `/var/lib` anchors.
    """
    if os.geteuid() != 0 or os.getegid() != 0:
        raise AssertionError("U1 fixture must run as real namespace root")
    if (len(core_revision) != 40
            or any(character not in "0123456789abcdef" for character in core_revision)
            or not core_digest.startswith("sha256:")
            or len(core_digest) != 71
            or any(character not in "0123456789abcdef" for character in core_digest[7:])):
        raise AssertionError("U1 fixture core identity is malformed")

    material_root.mkdir(parents=True, exist_ok=True)
    root_key = material_root / "root-key.pem"
    publisher_key = material_root / "publisher-key.pem"
    root_der, root_key_id = RF.generate_key(root_key)
    publisher_der, publisher_key_id = RF.generate_key(publisher_key)

    namespace = Path("/var/lib/airlock/managed/0")
    authority = namespace / "authority"
    store = namespace / "store"
    state = namespace / "managed-state.json"
    for protected in (
        Path("/etc/airlock"), Path("/opt/airlock/libexec"),
        Path("/var/lib/airlock"), Path("/var/lib/airlock/managed"),
    ):
        protected.mkdir(parents=True, exist_ok=True)
        protected.chmod(0o755)
    namespace.mkdir(parents=True, exist_ok=True)
    namespace.chmod(0o700)
    authority_variant(
        authority, root_key, root_der, publisher_der, publisher_key_id,
        sequence=2,
    )
    authority.chmod(0o700)

    previous_revision, previous_digest = SF.CORE_REVISION, SF.CORE_DIGEST
    original_materialize_package = SF.materialize_package

    def materialize_capability_package(
        path: Path, package_id: str, *, required_secret: bool = False,
    ) -> dict[str, tuple[int, bytes]]:
        files = original_materialize_package(
            path, package_id, required_secret=required_secret,
        )
        if package_id == "required-app":
            manifest = files["airlock-app.toml"][1] + (
                b'\n[artifacts]\nunits = [{ name = "fixture-required.service", '
                b'scope = "system" }]\n'
            )
            (path / "airlock-app.toml").write_bytes(manifest)
            files["airlock-app.toml"] = (0o644, manifest)
        return files

    # The updater judges host compatibility on every managed run, so a delivered
    # enrollment fixture must carry this host's measured profile rather than the
    # abstract label the source-only state fixture uses.
    host_profile = "linux-" + {"amd64": "x86_64", "arm64": "aarch64"}.get(
        platform.machine().lower(), platform.machine().lower())
    original_write_json = SF.RF.write_json

    def host_profiled_write_json(path: Path, value: dict) -> None:
        if path.name == "catalog.json":
            for app in value["apps"]:
                app["compatibility"] = {"platforms": ["linux"], "profiles": [host_profile]}
        elif path.name == "release.lock":
            value["target_profile"] = host_profile
        original_write_json(path, value)

    SF.CORE_REVISION, SF.CORE_DIGEST = core_revision, core_digest
    SF.materialize_package = materialize_capability_package
    SF.RF.write_json = host_profiled_write_json
    try:
        stage = SF.make_stage(
            material_root, publisher_key, sequence=50,
            required_capabilities=["system-unit"],
        )
    finally:
        SF.CORE_REVISION, SF.CORE_DIGEST = previous_revision, previous_digest
        SF.materialize_package = original_materialize_package
        SF.RF.write_json = original_write_json
    snapshot_digest = SF.snapshot_digest(stage)
    store.mkdir(parents=True, exist_ok=True)
    (store / "releases").mkdir()
    store.chmod(0o700)
    (store / "releases").chmod(0o700)
    promoted = json.loads(RF.promote(stage, authority, store, ok=True).stdout)

    selection = material_root / "selection.json"
    selection_value = SF.selection_value(snapshot_digest, [
        ("available-app", "managed"),
        ("notes", "public"),
        ("required-app", "managed"),
    ], 1)
    RF.write_json(selection, selection_value)
    enrollment = material_root / "enrollment.json"
    enrollment_value = {
        "capability_ceilings": {"required-app": ["system-unit"]},
        "organization_id": "fixture-org",
        "root_key_id": root_key_id,
        "schema": "airlock.managed.enrollment/v1",
    }
    RF.write_json(enrollment, enrollment_value)
    SF.state_run(
        "enroll", state, stage, authority, selection, enrollment=enrollment,
    )

    local_only = material_root / "local-only"
    required_local = material_root / "required-local"
    SF.materialize_package(local_only, "local-only", required_secret=True)
    SF.materialize_package(required_local, "required-app", required_secret=True)
    box.mkdir(parents=True, exist_ok=True)
    config = box / "airlock.toml"
    config.write_text(SF.config_text(local_only, required_local))
    config.chmod(0o600)

    installed_measurer = Path("/opt/airlock/libexec/airlock-managed-release")
    shutil.copyfile(ROOT / "bin/airlock-managed-release", installed_measurer)
    installed_measurer.chmod(0o555)

    for directory in (authority, store, store / "releases", namespace):
        directory.chmod(0o700)
    for private in (
        state, state.with_name(state.name + ".lock"),
        authority / "root-public.der", authority / "current-membership.json",
        store / ".promotion.lock", store / "release-state.json",
    ):
        private.chmod(0o600)

    state_value = json.loads(state.read_bytes())
    anchor = {
        "authority_path": str(authority),
        "channel_id": "stable",
        "enrollment_digest": state_value["enrollment_digest"],
        "organization_id": "fixture-org",
        "root_key_id": root_key_id,
        "schema": "airlock.managed.install-anchor/v1",
        "state_path": str(state),
        "store_path": str(store),
        "writer_gid": 0,
        "writer_uid": 0,
    }
    anchor_path = Path("/etc/airlock/managed-channel.json")
    RF.write_json(anchor_path, anchor)
    anchor_path.chmod(0o644)
    print(json.dumps({
        "config": str(config),
        "managed_release": promoted["release"],
        "schema": "airlock.test.update-channel-fixture/v1",
    }, separators=(",", ":"), sort_keys=True))
    return 0


def main(emit_ac: bool) -> int:
    d5 = {
        "verified_state": 0,
        "effective_validate": 0,
        "required_pin": 0,
        "public_builtin": 0,
        "local_values_preserved": 0,
        "secret_refs_preserved": 0,
        "private_output": 0,
        "schema_inputs": 0,
        "receipt_binding": 0,
        "operator_unchanged": 0,
    }
    d6 = {
        "root_mismatch_rejects": 0,
        "authority_rollback_rejects": 0,
        "authority_equivocation_rejects": 0,
        "authority_unaccepted_rejects": 0,
        "state_drift_rejects": 0,
        "consumer_first_serialized": 0,
        "writer_first_refuses": 0,
        "writer_first_fresh": 0,
        "projection_digest_rejects": 0,
        "toml_tamper_rejects": 0,
        "public_org_only_rejects": 0,
        "time_override_rejects": 0,
        "prewrite_unchanged": 0,
        "public_validate": 0,
        "public_json": 0,
        "public_env": 0,
        "public_bytes_unchanged": 0,
    }
    d7 = {
        "canonical_receipt": 0,
        "producer_authority": 0,
        "consumers_authenticated": 0,
        "managed_source": 0,
        "signed_digest": 0,
        "signed_capabilities": 0,
        "explicit_sibling": 0,
        "lock_excludes_managed": 0,
    }
    d8 = {
        "receipt_hash_rejects": 0,
        "receipt_only_rejects": 0,
        "snapshot_receipt_rejects": 0,
        "verified_state_tamper_rejects": 0,
        "source_tamper_rejects": 0,
        "digest_tamper_rejects": 0,
        "capability_tamper_rejects": 0,
        "authority_mix_rejects": 0,
        "authority_revocation_rejects": 0,
        "all_consumers_reject_tamper": 0,
        "postreceipt_state_advance_survives": 0,
        "next_run_observes_state": 0,
        "lease_released_after_receipt": 0,
        "producer_stdout_prewrite_empty": 0,
        "stdout_failure_postlinearization": 0,
    }
    promoted_current = {
        "canonical_receipt": 0,
        "consumers_authenticated": 0,
        "mode_tamper_rejects": 0,
        "missing_receipt_rejects": 0,
        "modified_receipt_rejects": 0,
        "foreign_release_rejects": 0,
        "stale_current_rejects": 0,
        "current_revocation_rejects": 0,
        "signed_stage_mode": 0,
    }

    with tempfile.TemporaryDirectory(prefix="airlock-managed-config-consumer-test-") as temporary:
        root = Path(temporary)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        root_der, root_key_id = RF.generate_key(root_key)
        publisher_der, publisher_key_id = RF.generate_key(publisher_key)
        authority = root / "authority"
        authority_variant(
            authority, root_key, root_der, publisher_der, publisher_key_id,
            sequence=2,
        )
        original_materialize_package = SF.materialize_package

        def materialize_capability_package(
            path: Path, package_id: str, *, required_secret: bool = False,
        ) -> dict[str, tuple[int, bytes]]:
            files = original_materialize_package(
                path, package_id, required_secret=required_secret,
            )
            if package_id == "required-app":
                manifest = files["airlock-app.toml"][1] + (
                    b'\n[artifacts]\nunits = [{ name = "fixture-required.service", '
                    b'scope = "system" }]\n'
                )
                (path / "airlock-app.toml").write_bytes(manifest)
                files["airlock-app.toml"] = (0o644, manifest)
            return files

        SF.materialize_package = materialize_capability_package
        try:
            stage = SF.make_stage(
                root, publisher_key, sequence=50,
                required_capabilities=["system-unit"],
            )
        finally:
            SF.materialize_package = original_materialize_package
        snapshot_digest = SF.snapshot_digest(stage)

        local_only = root / "local-only"
        required_local = root / "required-local"
        SF.materialize_package(local_only, "local-only", required_secret=True)
        SF.materialize_package(required_local, "required-app", required_secret=True)
        config = root / "airlock.toml"
        config.write_text(SF.config_text(local_only, required_local))
        config_before = config.read_bytes()

        selection_value = SF.selection_value(snapshot_digest, [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 1)
        selection = root / "selection.json"
        RF.write_json(selection, selection_value)
        enrollment = root / "enrollment.json"
        enrollment_value = {
            "capability_ceilings": {"required-app": ["system-unit"]},
            "organization_id": "fixture-org",
            "root_key_id": root_key_id,
            "schema": "airlock.managed.enrollment/v1",
        }
        RF.write_json(enrollment, enrollment_value)
        state = root / "managed-state.json"
        SF.state_run(
            "enroll", state, stage, authority, selection, enrollment=enrollment,
        )
        state_before = state.read_bytes()

        output = root / "effective.toml"
        write_private(output, b"happy-sentinel\n")
        result = invoke(config, state, stage, authority, output, ok=True)
        receipt = json.loads(result.stdout)
        receipt_path = output.with_name(output.name + ".receipt.json")
        receipt_raw = receipt_path.read_bytes()
        assert result.stdout == receipt_raw == RF.canonical(receipt)
        effective_raw = output.read_bytes()
        effective = tomllib.loads(effective_raw.decode())
        state_value = json.loads(state.read_text())

        assert receipt["state_digest"] == RF.digest(state_before)
        assert receipt["selection_digest"] == RF.digest(RF.canonical(selection_value))
        assert receipt["snapshot_digest"] == snapshot_digest
        d5["verified_state"] = 1
        validation_env = managed_consumer_env(config, state, stage, authority, output)
        run(sys.executable, str(CONFIG), "validate", env=validation_env)
        d5["effective_validate"] = 1
        assert effective["packages"]["required-app"]["path"] == str(
            (stage / "packages/required-app").resolve()
        )
        d5["required_pin"] = 1
        assert "notes" in effective["apps"] and "notes" not in effective.get("packages", {})
        d5["public_builtin"] = 1
        assert effective["site"]["name"] == "Fixture Site"
        assert effective["auth"]["owner"] == "owner@fixture.dev"
        assert effective["paths"]["wiki"] == "/srv/fixture-wiki"
        d5["local_values_preserved"] = 1
        assert effective["apps"]["local-only"]["token_env"] == "LOCAL_SECRET_REFERENCE"
        assert effective["apps"]["required-app"]["token_env"] == "REQUIRED_SECRET_REFERENCE"
        d5["secret_refs_preserved"] = 1
        assert stat.S_IMODE(output.stat().st_mode) == 0o600 and output.stat().st_uid == os.geteuid()
        d5["private_output"] = 1
        validator = SF.SchemaValidator(SF.SCHEMA_DIR)
        validator.validate_document(selection_value, "desired-state-v1.schema.json")
        validator.validate_document(state_value, "managed-state-v1.schema.json")
        d5["schema_inputs"] = 2
        assert receipt["config_digest"] == RF.digest(effective_raw)
        assert receipt["local_config_digest"] == RF.digest(config_before)
        assert receipt["config_path"] == str(output)
        assert receipt["config_origin"] == str(config)
        assert isinstance(receipt["verified_at"], str) and receipt["verified_at"].endswith("Z")
        d5["receipt_binding"] = 1
        assert config.read_bytes() == config_before and state.read_bytes() == state_before
        d5["operator_unchanged"] = 1

        assert receipt["schema"] == "airlock.managed.config-receipt/v1"
        assert receipt["release_mode"] == "signed-stage"
        promoted_current["signed_stage_mode"] = 1
        assert "receipt_path" not in receipt
        assert receipt["config_sha256"] == hashlib.sha256(effective_raw).hexdigest()
        assert stat.S_IMODE(receipt_path.stat().st_mode) == 0o600
        d7["canonical_receipt"] = 1
        assert receipt["state_path"] == str(state)
        assert receipt["release_path"] == str(stage)
        assert receipt["authority_path"] == str(authority)
        assert receipt["root_key_id"] == root_key_id
        d7["producer_authority"] = 1

        consumer_commands = [
            ("validate",),
            ("package-info",),
            ("json",),
            ("env", "required-app"),
            ("webjson",),
            ("plaintext",),
        ]
        consumer_results = {
            command: run(sys.executable, str(CONFIG), *command, env=validation_env)
            for command in consumer_commands
        }
        d7["consumers_authenticated"] = len(consumer_results)
        package_info = json.loads(consumer_results[("package-info",)].stdout)
        required_info = package_info["packages"]["required-app"]
        available_info = package_info["packages"]["available-app"]
        local_info = package_info["packages"]["local-only"]
        assert required_info["source_class"] == available_info["source_class"] == "managed"
        d7["managed_source"] = 2
        receipt_packages = {row["id"]: row for row in receipt["managed_packages"]}
        assert required_info["signed_package_digest"] == receipt_packages["required-app"]["package_digest"]
        assert available_info["signed_package_digest"] == receipt_packages["available-app"]["package_digest"]
        d7["signed_digest"] = 2
        assert required_info["requested_capabilities"] == ["system-unit"]
        assert required_info["effective_capabilities"] == ["system-unit"]
        assert required_info["capabilities"] == ["system-unit"]
        assert receipt_packages["required-app"]["capabilities"] == ["system-unit"]
        d7["signed_capabilities"] = 1
        assert local_info["source_class"] == "explicit"
        assert "signed_package_digest" not in local_info
        d7["explicit_sibling"] = 1

        state_lock_fd = os.open(state.with_name(state.name + ".lock"), os.O_RDWR)
        try:
            fcntl.flock(state_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(state_lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(state_lock_fd)
        d8["lease_released_after_receipt"] = 1

        lock_root = root / "lock-finalize-root"
        lock_root.mkdir()
        lock_module = load_module("airlock_config_managed_lock_finalize", CONFIG)
        lock_module.REPO_ROOT = lock_root
        lock_module.PACKAGE_LOCK_PATH = lock_root / "airlock.lock"
        prior_environment = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(validation_env)
            lock_cfg = lock_module.load()
            lock_module.cmd_lock_finalize(lock_cfg)
        finally:
            os.environ.clear()
            os.environ.update(prior_environment)
        lock_value = tomllib.loads((lock_root / "airlock.lock").read_text())
        assert set(lock_value) == {"local-only"}
        d7["lock_excludes_managed"] = 1

        # Save one genuine projection so the config consumer's closed-envelope loader can
        # be challenged directly without installing an ambient projector override.
        projection_path = root / "genuine-projection.json"
        write_private(projection_path, b"projection-sentinel\n")
        projector_env = dict(
            os.environ,
            AIRLOCK_MANAGED_PROJECTOR_STATE=str(state),
            AIRLOCK_MANAGED_PROJECTOR_RELEASE=str(stage),
            AIRLOCK_MANAGED_PROJECTOR_AUTHORITY=str(authority),
            AIRLOCK_MANAGED_PROJECTOR_AT=SF.LATER,
            AIRLOCK_MANAGED_PROJECTOR_RELEASE_MODE="signed-stage",
        )
        projected = run(
            sys.executable, str(PROJECTOR), "--config", str(config),
            "--release", str(stage), "--authority", str(authority),
            "--state", str(state), "--at", SF.LATER, "--out", str(projection_path),
            env=projector_env,
        )
        projection_raw = projection_path.read_bytes()
        projection = json.loads(projection_raw)
        config_module = load_module("airlock_config_consumer_under_test", CONFIG)

        tamper_output = root / "projection-digest-tamper.toml"
        write_private(tamper_output, b"projection-digest-tamper\n")
        invoke_with_forged_projection(
            config_module, config, state, stage, authority, tamper_output,
            projection_raw, "sha256:" + "0" * 64,
        )
        d6["projection_digest_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        bad_projection = json.loads(projection_raw)
        bad_projection["config_toml"] += "# tampered after projection\n"
        bad_projection_raw = RF.canonical(bad_projection)
        tamper_output = root / "toml-tamper.toml"
        write_private(tamper_output, b"toml-tamper\n")
        invoke_with_forged_projection(
            config_module, config, state, stage, authority, tamper_output,
            bad_projection_raw, RF.digest(bad_projection_raw),
        )
        d6["toml_tamper_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        other_root_key = root / "other-root-key.pem"
        other_root_der, _other_root_id = RF.generate_key(other_root_key)
        other_root_authority = root / "other-root-authority"
        authority_variant(
            other_root_authority, other_root_key, other_root_der,
            publisher_der, publisher_key_id, sequence=2,
        )
        failure_output = root / "root-mismatch.toml"
        expect_failure_unchanged(
            config, state, stage, other_root_authority, failure_output, b"root-mismatch\n",
        )
        d6["root_mismatch_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        rollback_authority = root / "rollback-authority"
        authority_variant(
            rollback_authority, root_key, root_der, publisher_der, publisher_key_id,
            sequence=1,
        )
        failure_output = root / "authority-rollback.toml"
        expect_failure_unchanged(
            config, state, stage, rollback_authority, failure_output, b"authority-rollback\n",
        )
        d6["authority_rollback_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        equivocal_authority = root / "equivocal-authority"
        authority_variant(
            equivocal_authority, root_key, root_der, publisher_der, publisher_key_id,
            sequence=2, ceiling=[],
        )
        failure_output = root / "authority-equivocation.toml"
        expect_failure_unchanged(
            config, state, stage, equivocal_authority, failure_output, b"authority-equivocation\n",
        )
        d6["authority_equivocation_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        unaccepted_authority = root / "unaccepted-authority"
        authority_variant(
            unaccepted_authority, root_key, root_der, publisher_der, publisher_key_id,
            sequence=3,
        )
        failure_output = root / "authority-unaccepted.toml"
        expect_failure_unchanged(
            config, state, stage, unaccepted_authority, failure_output, b"authority-unaccepted\n",
        )
        d6["authority_unaccepted_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        def forged_receipt_environment(label: str, mutate) -> tuple[dict[str, str], Path]:
            value = json.loads(receipt_raw)
            path = root / f"forged-{label}-receipt.json"
            mutate(value)
            raw = RF.canonical(value)
            write_private(path, raw)
            env = dict(validation_env)
            env["AIRLOCK_MANAGED_CONFIG_RECEIPT"] = str(path)
            env["AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256"] = hashlib.sha256(raw).hexdigest()
            return env, path

        hash_env, hash_path = forged_receipt_environment("hash", lambda _value: None)
        hash_path.write_bytes(hash_path.read_bytes() + b" ")
        run(sys.executable, str(CONFIG), "validate", env=hash_env, ok=False)
        d8["receipt_hash_rejects"] = 1

        receipt_only_env = dict(validation_env)
        receipt_only_env.pop("AIRLOCK_MANAGED_STATE")
        receipt_only_env.pop("AIRLOCK_MANAGED_RELEASE")
        receipt_only_env.pop("AIRLOCK_MANAGED_AUTHORITY")
        run(sys.executable, str(CONFIG), "validate", env=receipt_only_env, ok=False)
        d8["receipt_only_rejects"] = 1

        state_fact_env, _state_fact_receipt = forged_receipt_environment(
            "verified-state", lambda value: value["verified_state"].__setitem__(
                "legacy_adoption", {"forged": True}
            ),
        )
        run(sys.executable, str(CONFIG), "validate", env=state_fact_env, ok=False)
        d8["verified_state_tamper_rejects"] = 1

        source_env, _source_receipt = forged_receipt_environment(
            "source", lambda value: value["managed_packages"][0].__setitem__(
                "source_class", "explicit"
            ),
        )
        run(sys.executable, str(CONFIG), "validate", env=source_env, ok=False)
        d8["source_tamper_rejects"] = 1

        digest_env, _digest_receipt = forged_receipt_environment(
            "digest", lambda value: value["managed_packages"][0].__setitem__(
                "package_digest", "sha256:" + "0" * 64
            ),
        )
        run(sys.executable, str(CONFIG), "validate", env=digest_env, ok=False)
        d8["digest_tamper_rejects"] = 1

        capability_env, _capability_receipt = forged_receipt_environment(
            "capability", lambda value: value["managed_packages"][-1].__setitem__(
                "capabilities", []
            ),
        )
        run(sys.executable, str(CONFIG), "validate", env=capability_env, ok=False)
        d8["capability_tamper_rejects"] = 1

        authority_env, _authority_receipt = forged_receipt_environment(
            "authority", lambda value: value.__setitem__(
                "authority_path", str(other_root_authority)
            ),
        )
        authority_env["AIRLOCK_MANAGED_AUTHORITY"] = str(other_root_authority)
        run(sys.executable, str(CONFIG), "validate", env=authority_env, ok=False)
        d8["authority_mix_rejects"] = 1

        mismatched_snapshot = root / "receipt-mismatch.toml"
        write_private(mismatched_snapshot, effective_raw + b"# different candidate\n")
        snapshot_env, _snapshot_receipt = forged_receipt_environment(
            "snapshot", lambda value: value.__setitem__(
                "config_path", str(mismatched_snapshot)
            ),
        )
        snapshot_env["AIRLOCK_CONFIG_SNAPSHOT"] = str(mismatched_snapshot)
        snapshot_env["AIRLOCK_CONFIG_SNAPSHOT_SHA256"] = hashlib.sha256(
            mismatched_snapshot.read_bytes()
        ).hexdigest()
        run(sys.executable, str(CONFIG), "validate", env=snapshot_env, ok=False)
        d8["snapshot_receipt_rejects"] = 1

        rejecting_commands = [
            ("validate",),
            ("package-info",),
            ("json",),
            ("env", "required-app"),
            ("webjson",),
            ("plaintext",),
        ]
        for command in rejecting_commands:
            run(sys.executable, str(CONFIG), *command, env=source_env, ok=False)
        d8["all_consumers_reject_tamper"] = len(rejecting_commands)

        failure_output = root / "time-override.toml"
        time_override_receipt = failure_output.with_name(failure_output.name + ".receipt.json")
        time_override_sentinel = b"time-override\n"
        write_private(failure_output, time_override_sentinel)
        write_private(time_override_receipt, b"receipt-sentinel\n")
        time_override_env = dict(
            os.environ, AIRLOCK_CONFIG=str(config), AIRLOCK_STATE_DIR=str(root / "runtime"),
        )
        result = run(
            sys.executable, str(CONFIG), "managed-config-snapshot",
            "--state", str(state), "--release", str(stage),
            "--authority", str(authority), "--at", SF.LATER,
            str(failure_output),
            env=time_override_env, ok=False,
        )
        assert result.stdout == b"" and failure_output.read_bytes() == time_override_sentinel
        assert time_override_receipt.read_bytes() == b"receipt-sentinel\n"
        d6["time_override_rejects"] = 1
        d6["prewrite_unchanged"] += 1
        d8["producer_stdout_prewrite_empty"] = 1

        organization_only_state = json.loads(state_before)
        organization_only_selection = SF.selection_value(snapshot_digest, [
            ("available-app", "public"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 1)
        organization_only_state["owner_selection"] = organization_only_selection
        organization_only_state["owner_selection_digest"] = RF.digest(
            RF.canonical(organization_only_selection)
        )
        write_private(state, RF.canonical(organization_only_state))
        failure_output = root / "organization-only-public.toml"
        expect_failure_unchanged(
            config, state, stage, authority, failure_output, b"organization-only-public\n",
        )
        d6["public_org_only_rejects"] = 1
        d6["prewrite_unchanged"] += 1
        write_private(state, state_before)

        drift_selection_value = SF.selection_value(snapshot_digest, [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 2)
        drift_selection = root / "drift-selection.json"
        RF.write_json(drift_selection, drift_selection_value)
        failure_output = root / "state-drift.toml"
        drift_sentinel = b"state-drift\n"
        write_private(failure_output, drift_sentinel)
        drift_receipt = failure_output.with_name(failure_output.name + ".receipt.json")
        write_private(drift_receipt, b"receipt-sentinel\n")
        drift_env = dict(
            os.environ, AIRLOCK_CONFIG=str(config), AIRLOCK_STATE_DIR=str(root / "runtime"),
        )
        consumer = subprocess.Popen(
            [
                sys.executable, str(CONFIG), "managed-config-snapshot",
                "--state", str(state), "--release", str(stage),
                "--authority", str(authority), str(failure_output),
            ],
            env=drift_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        wait_for_state_lock(state, consumer)
        writer = subprocess.Popen(
            [
                sys.executable, str(STATE), "select", "--state", str(state),
                "--release", str(stage), "--authority", str(authority),
                "--selection", str(drift_selection), "--at", SF.LATER,
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        consumer_stdout, consumer_stderr = consumer.communicate(timeout=30)
        writer_stdout, writer_stderr = writer.communicate(timeout=30)
        assert writer.returncode == 0, writer_stderr.decode(errors="replace")
        assert consumer.returncode != 0, consumer_stdout.decode(errors="replace")
        assert b"changed during projection" in consumer_stderr
        assert failure_output.read_bytes() == drift_sentinel
        assert drift_receipt.read_bytes() == b"receipt-sentinel\n"
        d6["state_drift_rejects"] = 1
        d6["prewrite_unchanged"] += 1

        # The prior drift control covers a writer during projection. This one starts a
        # real writer only after the final verified inspection has completed and the
        # ordinary validator is deliberately paused. The writer must remain behind the
        # same state lock until the old-state output transaction linearizes.
        lease_state_before = state.read_bytes()
        later_selection_value = SF.selection_value(snapshot_digest, [
            ("notes", "public"),
            ("required-app", "managed"),
        ], 3)
        later_selection = root / "later-selection.json"
        RF.write_json(later_selection, later_selection_value)
        serialized_output = root / "consumer-first.toml"
        serialized_sentinel = b"consumer-first-sentinel\n"
        write_private(serialized_output, serialized_sentinel)
        serialized_consumer, _ready, proceed = delayed_consumer(
            root, config, state, stage, authority, serialized_output,
            label="consumer-first", pause_at="validate",
        )
        serialized_writer = subprocess.Popen(
            [
                sys.executable, str(STATE), "select", "--state", str(state),
                "--release", str(stage), "--authority", str(authority),
                "--selection", str(later_selection), "--at", SF.LATER,
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        time.sleep(0.1)
        assert serialized_writer.poll() is None
        assert state.read_bytes() == lease_state_before
        assert serialized_output.read_bytes() == serialized_sentinel
        proceed.write_bytes(b"continue\n")
        consumer_stdout, consumer_stderr = serialized_consumer.communicate(timeout=30)
        writer_stdout, writer_stderr = serialized_writer.communicate(timeout=30)
        assert serialized_consumer.returncode == 0, consumer_stderr.decode(errors="replace")
        assert serialized_writer.returncode == 0, writer_stderr.decode(errors="replace")
        serialized_receipt = json.loads(consumer_stdout)
        assert serialized_receipt["state_digest"] == RF.digest(lease_state_before)
        serialized_config = tomllib.loads(serialized_output.read_text())
        assert "available-app" in serialized_config["packages"]
        assert json.loads(state.read_text())["owner_selection"]["sequence"] == 3
        d6["consumer_first_serialized"] = 1

        # The first run is now a frozen config+receipt pair. A normal selection
        # advance after its receipt/lease completed belongs to the next run and
        # must not retroactively invalidate any of its six config consumers.
        postreceipt_results = {
            command: run(sys.executable, str(CONFIG), *command, env=validation_env)
            for command in consumer_commands
        }
        postreceipt_info = json.loads(postreceipt_results[("package-info",)].stdout)
        assert postreceipt_info["packages"]["available-app"]["source_class"] == "managed"
        d8["postreceipt_state_advance_survives"] = len(postreceipt_results)

        # A fresh run must, in contrast, consume the new selection and all of
        # its follow-up consumers must stay bound to that new frozen run.
        writer_first_output = root / "writer-first.toml"
        write_private(writer_first_output, b"writer-first-sentinel\n")
        writer_first_result = invoke(
            config, state, stage, authority, writer_first_output, ok=True,
        )
        writer_first_receipt = json.loads(writer_first_result.stdout)
        assert writer_first_receipt["state_digest"] == RF.digest(state.read_bytes())
        writer_first_config = tomllib.loads(writer_first_output.read_text())
        assert "available-app" not in writer_first_config.get("packages", {})
        writer_first_env = managed_consumer_env(
            config, state, stage, authority, writer_first_output,
        )
        next_run_results = {
            command: run(sys.executable, str(CONFIG), *command, env=writer_first_env)
            for command in consumer_commands
        }
        next_run_info = json.loads(next_run_results[("package-info",)].stdout)
        assert "available-app" not in next_run_info["packages"]
        d8["next_run_observes_state"] = len(next_run_results)
        d6["writer_first_fresh"] = 1

        # Now pause after projection but before the final lease. A writer which wins
        # this exact former TOCTOU window commits sequence 4; the consumer must compare
        # under its newly acquired lease and refuse without replacing its sentinel.
        gap_selection_value = SF.selection_value(snapshot_digest, [
            ("available-app", "managed"),
            ("notes", "public"),
            ("required-app", "managed"),
        ], 4)
        gap_selection = root / "gap-selection.json"
        RF.write_json(gap_selection, gap_selection_value)
        gap_output = root / "writer-first-gap.toml"
        gap_sentinel = b"writer-first-gap-sentinel\n"
        write_private(gap_output, gap_sentinel)
        gap_consumer, _ready, gap_proceed = delayed_consumer(
            root, config, state, stage, authority, gap_output,
            label="writer-first", pause_at="lease",
        )
        gap_writer = run(
            sys.executable, str(STATE), "select", "--state", str(state),
            "--release", str(stage), "--authority", str(authority),
            "--selection", str(gap_selection), "--at", SF.LATER,
        )
        assert gap_writer.returncode == 0
        gap_proceed.write_bytes(b"continue\n")
        gap_stdout, gap_stderr = gap_consumer.communicate(timeout=30)
        assert gap_consumer.returncode != 0
        assert gap_stdout == b""
        assert b"managed state changed before the effective config transaction" in gap_stderr
        assert gap_output.read_bytes() == gap_sentinel
        d6["writer_first_refuses"] = 1
        d6["prewrite_unchanged"] += 1

        gap_fresh_output = root / "writer-first-fresh.toml"
        write_private(gap_fresh_output, b"writer-first-fresh-sentinel\n")
        gap_fresh_result = invoke(
            config, state, stage, authority, gap_fresh_output, ok=True,
        )
        gap_fresh_receipt = json.loads(gap_fresh_result.stdout)
        assert gap_fresh_receipt["state_digest"] == RF.digest(state.read_bytes())
        assert "available-app" in tomllib.loads(gap_fresh_output.read_text())["packages"]

        # Current signed producer authority is still live evidence even though
        # mutable selection state is not. A real current-membership revocation
        # must invalidate the frozen receipt, independently of state advance.
        membership_path = authority / "current-membership.json"
        membership_before = membership_path.read_bytes()
        revoked_membership = json.loads(membership_before)
        revoked_membership["sequence"] += 1
        revoked_membership["publishers"] = []
        revoked_membership.pop("root_signature")
        revoked_membership["root_signature"] = {
            "algorithm": "ed25519",
            "signature": base64.b64encode(
                RF.sign(root_key, RF.canonical(revoked_membership))
            ).decode(),
        }
        RF.write_json(membership_path, revoked_membership)
        revoked_result = run(
            sys.executable, str(CONFIG), "validate", env=validation_env, ok=False,
        )
        assert b"producer release verification failed" in revoked_result.stderr
        d8["authority_revocation_rejects"] = 1
        membership_path.write_bytes(membership_before)

        # The explicit promoted-current ABI accepts the immutable release only
        # when it is still the exact authenticated current pointer. The
        # resulting receipt preserves the original release path and binds the
        # mode used by every one of the six follow-up consumers.
        promoted_store = root / "promoted-store"
        (promoted_store / "releases").mkdir(parents=True)
        promoted_value = json.loads(
            RF.promote(stage, authority, promoted_store, ok=True).stdout
        )
        promoted_release = Path(promoted_value["release"])
        promoted_output = root / "promoted-effective.toml"
        write_private(promoted_output, b"promoted-sentinel\n")
        promoted_result = invoke(
            config, state, promoted_release, authority, promoted_output,
            ok=True, promoted_current=True,
        )
        promoted_receipt_path = promoted_output.with_name(
            promoted_output.name + ".receipt.json"
        )
        promoted_receipt_raw = promoted_receipt_path.read_bytes()
        promoted_receipt = json.loads(promoted_receipt_raw)
        assert promoted_result.stdout == promoted_receipt_raw == RF.canonical(promoted_receipt)
        assert promoted_receipt["release_mode"] == "promoted-current"
        assert promoted_receipt["release_path"] == str(promoted_release)
        promoted_current["canonical_receipt"] = 1
        promoted_env = managed_consumer_env(
            config, state, promoted_release, authority, promoted_output,
        )
        for command in consumer_commands:
            run(sys.executable, str(CONFIG), *command, env=promoted_env)
        promoted_current["consumers_authenticated"] = len(consumer_commands)

        def promoted_receipt_variant(label: str, release_mode: str) -> dict[str, str]:
            value = json.loads(promoted_receipt_raw)
            value["release_mode"] = release_mode
            raw = RF.canonical(value)
            path = root / f"promoted-{label}-receipt.json"
            write_private(path, raw)
            env = dict(promoted_env)
            env["AIRLOCK_MANAGED_CONFIG_RECEIPT"] = str(path)
            env["AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256"] = hashlib.sha256(raw).hexdigest()
            return env

        run(
            sys.executable, str(CONFIG), "validate",
            env=promoted_receipt_variant("as-stage", "signed-stage"), ok=False,
        )
        signed_as_promoted = json.loads(receipt_raw)
        signed_as_promoted["release_mode"] = "promoted-current"
        signed_as_promoted_raw = RF.canonical(signed_as_promoted)
        signed_as_promoted_path = root / "signed-as-promoted-receipt.json"
        write_private(signed_as_promoted_path, signed_as_promoted_raw)
        signed_as_promoted_env = dict(validation_env)
        signed_as_promoted_env["AIRLOCK_MANAGED_CONFIG_RECEIPT"] = str(
            signed_as_promoted_path
        )
        signed_as_promoted_env["AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256"] = (
            hashlib.sha256(signed_as_promoted_raw).hexdigest()
        )
        run(
            sys.executable, str(CONFIG), "validate",
            env=signed_as_promoted_env, ok=False,
        )
        promoted_current["mode_tamper_rejects"] = 2

        missing_store = root / "promoted-missing-store"
        shutil.copytree(promoted_store, missing_store)
        missing_release = missing_store / "releases" / promoted_release.name
        (missing_release / "promotion-receipt.json").unlink()
        missing_output = root / "promoted-missing.toml"
        write_private(missing_output, b"promoted-missing-sentinel\n")
        missing_result = invoke(
            config, state, missing_release, authority, missing_output,
            ok=False, promoted_current=True,
        )
        assert missing_result.stdout == b""
        assert missing_output.read_bytes() == b"promoted-missing-sentinel\n"
        promoted_current["missing_receipt_rejects"] = 1

        modified_store = root / "promoted-modified-store"
        shutil.copytree(promoted_store, modified_store)
        modified_release = modified_store / "releases" / promoted_release.name
        modified_receipt_path = modified_release / "promotion-receipt.json"
        modified_receipt = json.loads(modified_receipt_path.read_text())
        modified_receipt["sequence"] += 1
        RF.write_json(modified_receipt_path, modified_receipt)
        modified_output = root / "promoted-modified.toml"
        write_private(modified_output, b"promoted-modified-sentinel\n")
        modified_result = invoke(
            config, state, modified_release, authority, modified_output,
            ok=False, promoted_current=True,
        )
        assert modified_result.stdout == b""
        assert modified_output.read_bytes() == b"promoted-modified-sentinel\n"
        promoted_current["modified_receipt_rejects"] = 1

        foreign_release = promoted_store / "releases" / ("f" * 64)
        shutil.copytree(promoted_release, foreign_release)
        foreign_output = root / "promoted-foreign.toml"
        write_private(foreign_output, b"promoted-foreign-sentinel\n")
        foreign_result = invoke(
            config, state, foreign_release, authority, foreign_output,
            ok=False, promoted_current=True,
        )
        assert foreign_result.stdout == b""
        assert foreign_output.read_bytes() == b"promoted-foreign-sentinel\n"
        promoted_current["foreign_release_rejects"] = 1

        revoked_membership = json.loads(membership_before)
        revoked_membership["sequence"] += 1
        revoked_membership["publishers"] = []
        revoked_membership.pop("root_signature")
        revoked_membership["root_signature"] = {
            "algorithm": "ed25519",
            "signature": base64.b64encode(
                RF.sign(root_key, RF.canonical(revoked_membership))
            ).decode(),
        }
        RF.write_json(membership_path, revoked_membership)
        run(sys.executable, str(CONFIG), "validate", env=promoted_env, ok=False)
        promoted_current["current_revocation_rejects"] = 1
        membership_path.write_bytes(membership_before)

        next_stage = SF.make_stage(
            root, publisher_key, sequence=51,
            required_capabilities=["system-unit"],
        )
        RF.promote(next_stage, authority, promoted_store, ok=True)
        stale_output = root / "promoted-stale.toml"
        write_private(stale_output, b"promoted-stale-sentinel\n")
        stale_result = invoke(
            config, state, promoted_release, authority, stale_output,
            ok=False, promoted_current=True,
        )
        assert stale_result.stdout == b""
        assert stale_output.read_bytes() == b"promoted-stale-sentinel\n"
        promoted_current["stale_current_rejects"] = 1

        # stdout belongs to the installer handoff, not a second producer-owned
        # replacement. A closed reader is therefore a post-linearization error:
        # the single effective config is committed, but the run must fail.
        broken_stdout_output = root / "broken-stdout.toml"
        broken_stdout_sentinel = b"broken-stdout-sentinel\n"
        write_private(broken_stdout_output, broken_stdout_sentinel)
        broken_stdout = subprocess.Popen(
            [
                sys.executable, str(CONFIG), "managed-config-snapshot",
                "--state", str(state), "--release", str(stage),
                "--authority", str(authority), str(broken_stdout_output),
            ],
            env=dict(
                os.environ, AIRLOCK_CONFIG=str(config),
                AIRLOCK_STATE_DIR=str(root / "runtime"),
            ),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        assert broken_stdout.stdout is not None and broken_stdout.stderr is not None
        broken_stdout.stdout.close()
        broken_stdout_stderr = broken_stdout.stderr.read()
        broken_stdout_returncode = broken_stdout.wait(timeout=30)
        assert broken_stdout_returncode != 0
        assert b"stdout failed after the effective-config replacement linearized" in broken_stdout_stderr
        assert broken_stdout_output.read_bytes() != broken_stdout_sentinel
        d8["stdout_failure_postlinearization"] = 1

        public_config = root / "public-only.toml"
        public_config.write_text('''[airlock]
config_version = 2

[site]
name = "Public fixture"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
''')
        public_before = public_config.read_bytes()
        public_env = dict(
            os.environ, AIRLOCK_CONFIG=str(public_config), AIRLOCK_STATE_DIR=str(root / "public-runtime"),
        )
        run(sys.executable, str(CONFIG), "validate", env=public_env)
        d6["public_validate"] = 1
        public_json = json.loads(run(sys.executable, str(CONFIG), "json", env=public_env).stdout)
        assert public_json["site"]["name"] == "Public fixture"
        d6["public_json"] = 1
        public_env_rows = run(sys.executable, str(CONFIG), "env", "hub", env=public_env).stdout
        assert b"AIRLOCK_SITE_NAME=" in public_env_rows
        d6["public_env"] = 1
        assert public_config.read_bytes() == public_before and not (root / "public-runtime").exists()
        d6["public_bytes_unchanged"] = 1

    assert d5 == {
        "verified_state": 1,
        "effective_validate": 1,
        "required_pin": 1,
        "public_builtin": 1,
        "local_values_preserved": 1,
        "secret_refs_preserved": 1,
        "private_output": 1,
        "schema_inputs": 2,
        "receipt_binding": 1,
        "operator_unchanged": 1,
    }
    assert d6 == {
        "root_mismatch_rejects": 1,
        "authority_rollback_rejects": 1,
        "authority_equivocation_rejects": 1,
        "authority_unaccepted_rejects": 1,
        "state_drift_rejects": 1,
        "consumer_first_serialized": 1,
        "writer_first_refuses": 1,
        "writer_first_fresh": 1,
        "projection_digest_rejects": 1,
        "toml_tamper_rejects": 1,
        "public_org_only_rejects": 1,
        "time_override_rejects": 1,
        "prewrite_unchanged": 10,
        "public_validate": 1,
        "public_json": 1,
        "public_env": 1,
        "public_bytes_unchanged": 1,
    }
    assert d7 == {
        "canonical_receipt": 1,
        "producer_authority": 1,
        "consumers_authenticated": 6,
        "managed_source": 2,
        "signed_digest": 2,
        "signed_capabilities": 1,
        "explicit_sibling": 1,
        "lock_excludes_managed": 1,
    }
    assert d8 == {
        "receipt_hash_rejects": 1,
        "receipt_only_rejects": 1,
        "snapshot_receipt_rejects": 1,
        "verified_state_tamper_rejects": 1,
        "source_tamper_rejects": 1,
        "digest_tamper_rejects": 1,
        "capability_tamper_rejects": 1,
        "authority_mix_rejects": 1,
        "authority_revocation_rejects": 1,
        "all_consumers_reject_tamper": 6,
        "postreceipt_state_advance_survives": 6,
        "next_run_observes_state": 6,
        "lease_released_after_receipt": 1,
        "producer_stdout_prewrite_empty": 1,
        "stdout_failure_postlinearization": 1,
    }
    assert promoted_current == {
        "canonical_receipt": 1,
        "consumers_authenticated": 6,
        "mode_tamper_rejects": 2,
        "missing_receipt_rejects": 1,
        "modified_receipt_rejects": 1,
        "foreign_release_rejects": 1,
        "stale_current_rejects": 1,
        "current_revocation_rejects": 1,
        "signed_stage_mode": 1,
    }

    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed config consumer fixture: PASS")
    if emit_ac:
        print(
            "AC-MAU-D5 | expected: verified_state==1 && effective_validate==1 && "
            "required_pin==1 && public_builtin==1 && local_values_preserved==1 && "
            "secret_refs_preserved==1 && private_output==1 && schema_inputs==2 && "
            "receipt_binding==1 && operator_unchanged==1 | observed: "
            f"verified_state={d5['verified_state']},effective_validate={d5['effective_validate']},"
            f"required_pin={d5['required_pin']},public_builtin={d5['public_builtin']},"
            f"local_values_preserved={d5['local_values_preserved']},"
            f"secret_refs_preserved={d5['secret_refs_preserved']},private_output={d5['private_output']},"
            f"schema_inputs={d5['schema_inputs']},receipt_binding={d5['receipt_binding']},"
            f"operator_unchanged={d5['operator_unchanged']} | verdict: PASS | signal: fixture | "
            f"evidence: install/test-managed-config-consumer.py@{revision}"
        )
        print(
            "AC-MAU-U0P-CONFIG | expected: canonical_receipt==1 && "
            "consumers_authenticated==6 && mode_tamper_rejects==2 && "
            "missing_receipt_rejects==1 && modified_receipt_rejects==1 && "
            "foreign_release_rejects==1 && stale_current_rejects==1 && "
            "current_revocation_rejects==1 && signed_stage_mode==1 | observed: "
            f"canonical_receipt={promoted_current['canonical_receipt']},"
            f"consumers_authenticated={promoted_current['consumers_authenticated']},"
            f"mode_tamper_rejects={promoted_current['mode_tamper_rejects']},"
            f"missing_receipt_rejects={promoted_current['missing_receipt_rejects']},"
            f"modified_receipt_rejects={promoted_current['modified_receipt_rejects']},"
            f"foreign_release_rejects={promoted_current['foreign_release_rejects']},"
            f"stale_current_rejects={promoted_current['stale_current_rejects']},"
            f"current_revocation_rejects={promoted_current['current_revocation_rejects']},"
            f"signed_stage_mode={promoted_current['signed_stage_mode']} | "
            "verdict: PASS | signal: fixture | "
            f"evidence: install/test-managed-config-consumer.py@{revision}"
        )
        print(
            "AC-MAU-D6 | expected: root_mismatch_rejects==1 && authority_rollback_rejects==1 && "
            "authority_equivocation_rejects==1 && authority_unaccepted_rejects==1 && "
            "state_drift_rejects==1 && consumer_first_serialized==1 && "
            "writer_first_refuses==1 && writer_first_fresh==1 && "
            "projection_digest_rejects==1 && toml_tamper_rejects==1 && "
            "public_org_only_rejects==1 && time_override_rejects==1 && "
            "prewrite_unchanged==10 && public_validate==1 && "
            "public_json==1 && public_env==1 && public_bytes_unchanged==1 | observed: "
            f"root_mismatch_rejects={d6['root_mismatch_rejects']},"
            f"authority_rollback_rejects={d6['authority_rollback_rejects']},"
            f"authority_equivocation_rejects={d6['authority_equivocation_rejects']},"
            f"authority_unaccepted_rejects={d6['authority_unaccepted_rejects']},"
            f"state_drift_rejects={d6['state_drift_rejects']},"
            f"consumer_first_serialized={d6['consumer_first_serialized']},"
            f"writer_first_refuses={d6['writer_first_refuses']},"
            f"writer_first_fresh={d6['writer_first_fresh']},"
            f"projection_digest_rejects={d6['projection_digest_rejects']},"
            f"toml_tamper_rejects={d6['toml_tamper_rejects']},"
            f"public_org_only_rejects={d6['public_org_only_rejects']},"
            f"time_override_rejects={d6['time_override_rejects']},"
            f"prewrite_unchanged={d6['prewrite_unchanged']},public_validate={d6['public_validate']},"
            f"public_json={d6['public_json']},public_env={d6['public_env']},"
            f"public_bytes_unchanged={d6['public_bytes_unchanged']} | verdict: PASS | signal: fixture | "
            f"evidence: install/test-managed-config-consumer.py@{revision}"
        )
        print(
            "AC-MAU-D7 | expected: canonical_receipt==1 && producer_authority==1 && "
            "consumers_authenticated==6 && managed_source==2 && signed_digest==2 && "
            "signed_capabilities==1 && explicit_sibling==1 && lock_excludes_managed==1 | "
            "observed: "
            f"canonical_receipt={d7['canonical_receipt']},producer_authority={d7['producer_authority']},"
            f"consumers_authenticated={d7['consumers_authenticated']},managed_source={d7['managed_source']},"
            f"signed_digest={d7['signed_digest']},signed_capabilities={d7['signed_capabilities']},"
            f"explicit_sibling={d7['explicit_sibling']},"
            f"lock_excludes_managed={d7['lock_excludes_managed']} | verdict: PASS | signal: fixture | "
            f"evidence: install/test-managed-config-consumer.py@{revision}"
        )
        print(
            "AC-MAU-D8 | expected: receipt_hash_rejects==1 && snapshot_receipt_rejects==1 && "
            "receipt_only_rejects==1 && "
            "verified_state_tamper_rejects==1 && source_tamper_rejects==1 && "
            "digest_tamper_rejects==1 && "
            "capability_tamper_rejects==1 && authority_mix_rejects==1 && "
            "authority_revocation_rejects==1 && all_consumers_reject_tamper==6 && "
            "postreceipt_state_advance_survives==6 && next_run_observes_state==6 && "
            "lease_released_after_receipt==1 && producer_stdout_prewrite_empty==1 && "
            "stdout_failure_postlinearization==1 | observed: "
            f"receipt_hash_rejects={d8['receipt_hash_rejects']},"
            f"receipt_only_rejects={d8['receipt_only_rejects']},"
            f"snapshot_receipt_rejects={d8['snapshot_receipt_rejects']},"
            f"verified_state_tamper_rejects={d8['verified_state_tamper_rejects']},"
            f"source_tamper_rejects={d8['source_tamper_rejects']},"
            f"digest_tamper_rejects={d8['digest_tamper_rejects']},"
            f"capability_tamper_rejects={d8['capability_tamper_rejects']},"
            f"authority_mix_rejects={d8['authority_mix_rejects']},"
            f"authority_revocation_rejects={d8['authority_revocation_rejects']},"
            f"all_consumers_reject_tamper={d8['all_consumers_reject_tamper']},"
            f"postreceipt_state_advance_survives={d8['postreceipt_state_advance_survives']},"
            f"next_run_observes_state={d8['next_run_observes_state']},"
            f"lease_released_after_receipt={d8['lease_released_after_receipt']},"
            f"producer_stdout_prewrite_empty={d8['producer_stdout_prewrite_empty']},"
            f"stdout_failure_postlinearization={d8['stdout_failure_postlinearization']} | "
            "verdict: PASS | signal: fixture | "
            f"evidence: install/test-managed-config-consumer.py@{revision}"
        )
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-ac", action="store_true")
    parser.add_argument(
        "--prepare-u1-fixture", nargs=4,
        metavar=("MATERIAL_ROOT", "BOX", "CORE_REVISION", "CORE_DIGEST"),
    )
    arguments = parser.parse_args()
    if arguments.prepare_u1_fixture:
        material, box, revision, digest = arguments.prepare_u1_fixture
        raise SystemExit(prepare_u1_fixture(
            Path(material), Path(box), revision, digest,
        ))
    raise SystemExit(main(arguments.emit_ac))
