#!/usr/bin/env python3
"""Fixture verification for the generic managed release publisher contract."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin/airlock-managed-release"
CLI_COMMAND = (sys.executable, str(CLI))
SCHEMA = ROOT / "schemas/managed-app-store/release-contract-v1.schema.json"
NOW = "2026-09-12T04:00:00Z"
LATER = "2026-09-12T04:01:00Z"
CI_DIGEST = "sha256:" + "c" * 64
CORE_DIGEST = "sha256:" + "d" * 64
CORE_REVISION = "e" * 40


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode()


def digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def run(*args: str, cwd: Path | None = None, input_bytes: bytes | None = None, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, cwd=cwd, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if ok and result.returncode != 0:
        raise AssertionError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr.decode(errors='replace')}")
    if not ok and result.returncode == 0:
        raise AssertionError(f"command unexpectedly passed: {' '.join(args)}\n{result.stdout.decode(errors='replace')}")
    return result


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def generate_key(path: Path) -> tuple[bytes, str]:
    run("openssl", "genpkey", "-algorithm", "ED25519", "-out", str(path))
    path.chmod(0o600)
    public_der = run("openssl", "pkey", "-in", str(path), "-pubout", "-outform", "DER").stdout
    return public_der, digest(public_der)


def sign(key: Path, payload: bytes) -> bytes:
    with tempfile.NamedTemporaryFile(prefix="airlock-membership-payload-") as source:
        source.write(payload)
        source.flush()
        return run("openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-in", source.name).stdout


def package_digest(files: dict[str, tuple[int, bytes]]) -> str:
    manifest = [
        {"digest": digest(raw), "mode": f"{mode:04o}", "path": path, "type": "file"}
        for path, (mode, raw) in sorted(files.items())
    ]
    return digest(canonical(manifest))


def make_review_repo(root: Path, capabilities: list[str], sequence: int) -> tuple[Path, str]:
    repo = root / f"review-{sequence}-{'caps' if capabilities else 'plain'}"
    source = repo / "release-src"
    files = {
        "install.sh": (0o755, b"#!/usr/bin/env bash\necho fixture\n"),
        "manifest.toml": (0o644, b"contract = 1\nid = \"fixture-app\"\n"),
    }
    for relative, (mode, raw) in files.items():
        path = source / "packages/fixture-app" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(mode)
    catalog = {
        "apps": [{
            "compatibility": {"platforms": ["linux"], "profiles": ["team"]},
            "id": "fixture-app",
            "metadata": {"name": "Fixture app", "version": f"1.0.{sequence}"},
            "policy": "available",
            "source_label": "Fixture organisation",
        }],
        "channel_id": "stable",
        "organization_id": "fixture-org",
        "schema": "airlock.managed.catalog/v1",
    }
    lock = {
        "channel_id": "stable",
        "core": {"digest": CORE_DIGEST, "revision": CORE_REVISION},
        "organization_id": "fixture-org",
        "packages": [{
            "capabilities": capabilities,
            "data_compatibility": "stateless",
            "deactivator": "remove.sh",
            "digest": package_digest(files),
            "id": "fixture-app",
            "path": "packages/fixture-app",
        }],
        "schema": "airlock.managed.release-lock/v1",
        "target_profile": "team",
    }
    write_json(source / "catalog.json", catalog)
    write_json(source / "release.lock", lock)
    run("git", "init", "-q", repo)
    run("git", "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    run("git", "-C", str(repo), "config", "user.name", "Release fixture")
    run("git", "-C", str(repo), "add", "release-src")
    env = dict(os.environ, GIT_AUTHOR_DATE="2026-09-12T00:00:00Z", GIT_COMMITTER_DATE="2026-09-12T00:00:00Z")
    result = subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "reviewed release"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise AssertionError(result.stderr.decode())
    revision = run("git", "-C", str(repo), "rev-parse", "HEAD").stdout.decode().strip()
    return repo, revision


def prepare(repo: Path, revision: str, out: Path, publisher: str = "publisher-a", sequence: int = 1) -> None:
    run(
        *CLI_COMMAND, "prepare", "--source-repo", str(repo), "--revision", revision,
        "--input-prefix", "release-src", "--source-repository", "fixture/review",
        "--organization", "fixture-org", "--channel", "stable", "--epoch", "1",
        "--sequence", str(sequence), "--publisher", publisher, "--created-at", NOW,
        "--ci-evidence-digest", CI_DIGEST, "--out", str(out),
    )


def sign_stage(stage: Path, key: Path) -> None:
    run(*CLI_COMMAND, "sign", "--stage", str(stage), "--publisher-key", str(key))


def membership_value(root_key: Path, root_der: bytes, publisher_der: bytes, publisher_key_id: str, *, status: str = "active", ceiling: list[str] | None = None, publisher_id: str = "publisher-a", sequence: int = 1) -> dict[str, object]:
    value: dict[str, object] = {
        "channels": [{"channel_id": "stable", "epoch": 1}],
        "issued_at": "2026-09-12T00:00:00Z",
        "organization_id": "fixture-org",
        "publishers": [{
            "capability_ceiling": ceiling or [],
            "key_id": publisher_key_id,
            "not_after": "2027-09-12T00:00:00Z",
            "not_before": "2026-09-11T00:00:00Z",
            "public_key_der": base64.b64encode(publisher_der).decode(),
            "publisher_id": publisher_id,
            "status": status,
        }],
        "root_key_id": digest(root_der),
        "schema": "airlock.managed.membership/v1",
        "sequence": sequence,
    }
    value["root_signature"] = {
        "algorithm": "ed25519",
        "signature": base64.b64encode(sign(root_key, canonical(value))).decode(),
    }
    return value


def set_membership(authority: Path, value: dict[str, object], root_der: bytes) -> None:
    authority.mkdir(parents=True, exist_ok=True)
    (authority / "root-public.der").write_bytes(root_der)
    write_json(authority / "current-membership.json", value)


def promote(stage: Path, authority: Path, store: Path, *, ok: bool) -> subprocess.CompletedProcess[bytes]:
    return run(*CLI_COMMAND, "promote", "--stage", str(stage), "--authority", str(authority), "--store", str(store), "--promoted-at", LATER, ok=ok)


def tree_bytes(root: Path) -> dict[str, tuple[int, bytes | str]]:
    result: dict[str, tuple[int, bytes | str]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if stat.S_ISLNK(info.st_mode):
            result[relative] = (stat.S_IMODE(info.st_mode), os.readlink(path))
        else:
            result[relative] = (stat.S_IMODE(info.st_mode), path.read_bytes())
    return result


def copy_stage(source: Path, destination: Path) -> Path:
    shutil.copytree(source, destination, symlinks=True)
    return destination


def main() -> int:
    counters = {
        "deterministic": 0,
        "receipt": 0,
        "forward_recovery": 0,
        "tamper_rejects": 0,
        "replay_rejects": 0,
        "revoked_rejects": 0,
        "membership_rollback_rejects": 0,
        "membership_equivocation_rejects": 0,
        "invalid_authority_rejects": 0,
        "overcap_rejects": 0,
        "nonmember_rejects": 0,
        "partial_rejects": 0,
        "public_runtime_edits": -1,
    }
    schema = json.loads(SCHEMA.read_text())
    expected_defs = {"catalog", "releaseLock", "provenance", "snapshot", "signature", "membership", "promotionReceipt", "releaseState"}
    assert expected_defs <= set(schema["$defs"])
    refs: list[str] = []

    def walk(value: object) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "$ref":
                    refs.append(str(child))
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(schema)
    assert all(ref.startswith("#/$defs/") and ref.removeprefix("#/$defs/") in schema["$defs"] for ref in refs), refs
    for name in expected_defs:
        assert schema["$defs"][name]["additionalProperties"] is False

    with tempfile.TemporaryDirectory(prefix="airlock-managed-release-test-") as temporary:
        root = Path(temporary)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        outsider_key = root / "outsider-key.pem"
        root_der, _root_id = generate_key(root_key)
        publisher_der, publisher_key_id = generate_key(publisher_key)
        _outsider_der, _outsider_id = generate_key(outsider_key)
        authority = root / "authority"
        membership = membership_value(root_key, root_der, publisher_der, publisher_key_id)
        set_membership(authority, membership, root_der)

        repo1, revision1 = make_review_repo(root, [], 1)
        stage1 = root / "stage-1"
        stage1_copy = root / "stage-1-copy"
        prepare(repo1, revision1, stage1, sequence=1)
        prepare(repo1, revision1, stage1_copy, sequence=1)
        sign_stage(stage1, publisher_key)
        sign_stage(stage1_copy, publisher_key)
        assert tree_bytes(stage1) == tree_bytes(stage1_copy)
        counters["deterministic"] = 1

        run(*CLI_COMMAND, "verify", "--stage", str(stage1), "--signed", "--authority", str(authority), "--at", LATER)
        store = root / "store"
        (store / "releases").mkdir(parents=True)
        result = promote(stage1, authority, store, ok=True)
        promoted = json.loads(result.stdout)
        receipt = json.loads(Path(promoted["receipt"]).read_text())
        state = json.loads((store / "release-state.json").read_text())
        assert receipt["snapshot_digest"] == promoted["snapshot_digest"]
        assert state["channels"]["stable"]["receipt_digest"] == digest(canonical(receipt))
        assert state["membership_floors"]["fixture-org"] == {
            "membership_digest": digest(canonical(membership)),
            "sequence": 1,
        }
        counters["receipt"] = 1

        recovery_store = root / "recovery-store"
        (recovery_store / "releases").mkdir(parents=True)
        shutil.copytree(Path(promoted["release"]), recovery_store / "releases" / Path(promoted["release"]).name, symlinks=True)
        recovery = json.loads(promote(stage1, authority, recovery_store, ok=True).stdout)
        assert recovery["recovered"] is True
        assert json.loads((recovery_store / "release-state.json").read_text())["channels"]["stable"]["snapshot_digest"] == promoted["snapshot_digest"]
        counters["forward_recovery"] = 1

        before_state = (store / "release-state.json").read_bytes()
        before_releases = sorted(path.name for path in (store / "releases").iterdir())

        mutations = {
            "catalog": lambda path: (path / "catalog.json").write_bytes((path / "catalog.json").read_bytes() + b" "),
            "lock": lambda path: (path / "release.lock").write_bytes((path / "release.lock").read_bytes() + b" "),
            "package": lambda path: (path / "packages/fixture-app/manifest.toml").write_bytes(b"tampered\n"),
            "provenance": lambda path: (path / "provenance.json").write_bytes((path / "provenance.json").read_bytes() + b" "),
            "signature": lambda path: (path / "signature.json").write_bytes((path / "signature.json").read_bytes().replace(b"ed25519", b"ed25518")),
        }
        for name, mutate in mutations.items():
            candidate = copy_stage(stage1, root / f"tamper-{name}")
            mutate(candidate)
            promote(candidate, authority, store, ok=False)
            assert (store / "release-state.json").read_bytes() == before_state
            assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
            counters["tamper_rejects"] += 1

        partial = copy_stage(stage1, root / "partial")
        (partial / "bundle.tar").unlink()
        promote(partial, authority, store, ok=False)
        assert (store / "release-state.json").read_bytes() == before_state
        counters["partial_rejects"] = 1

        promote(stage1, authority, store, ok=False)
        assert (store / "release-state.json").read_bytes() == before_state
        counters["replay_rejects"] = 1

        repo2, revision2 = make_review_repo(root, [], 2)
        stage2 = root / "stage-2"
        prepare(repo2, revision2, stage2, sequence=2)
        sign_stage(stage2, publisher_key)
        revoked = membership_value(root_key, root_der, publisher_der, publisher_key_id, status="revoked", sequence=2)
        set_membership(authority, revoked, root_der)
        promote(stage2, authority, store, ok=False)
        revoked_state = json.loads((store / "release-state.json").read_text())
        assert revoked_state["channels"] == json.loads(before_state)["channels"]
        assert revoked_state["membership_floors"]["fixture-org"] == {
            "membership_digest": digest(canonical(revoked)),
            "sequence": 2,
        }
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["revoked_rejects"] = 1

        set_membership(authority, membership, root_der)
        revoked_state_raw = (store / "release-state.json").read_bytes()
        promote(stage2, authority, store, ok=False)
        assert (store / "release-state.json").read_bytes() == revoked_state_raw
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["membership_rollback_rejects"] = 1

        equivocated = membership_value(root_key, root_der, publisher_der, publisher_key_id, sequence=2)
        set_membership(authority, equivocated, root_der)
        promote(stage2, authority, store, ok=False)
        assert (store / "release-state.json").read_bytes() == revoked_state_raw
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["membership_equivocation_rejects"] = 1

        invalid_authority = membership_value(root_key, root_der, publisher_der, publisher_key_id, sequence=999)
        invalid_authority["root_signature"]["signature"] = base64.b64encode(b"x" * 64).decode()
        set_membership(authority, invalid_authority, root_der)
        promote(stage2, authority, store, ok=False)
        assert (store / "release-state.json").read_bytes() == revoked_state_raw
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["invalid_authority_rejects"] = 1

        membership3 = membership_value(root_key, root_der, publisher_der, publisher_key_id, sequence=3)
        set_membership(authority, membership3, root_der)
        outsider = copy_stage(stage2, root / "outsider-stage")
        (outsider / "signature.json").unlink()
        sign_stage(outsider, outsider_key)
        promote(outsider, authority, store, ok=False)
        nonmember_state = json.loads((store / "release-state.json").read_text())
        assert nonmember_state["channels"] == json.loads(before_state)["channels"]
        assert nonmember_state["membership_floors"]["fixture-org"] == {
            "membership_digest": digest(canonical(membership3)),
            "sequence": 3,
        }
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["nonmember_rejects"] = 1

        repo_caps, revision_caps = make_review_repo(root, ["system-unit"], 3)
        stage_caps = root / "stage-caps"
        prepare(repo_caps, revision_caps, stage_caps, sequence=2)
        sign_stage(stage_caps, publisher_key)
        ceiling = membership_value(root_key, root_der, publisher_der, publisher_key_id, ceiling=["rooted-artifact"], sequence=4)
        set_membership(authority, ceiling, root_der)
        promote(stage_caps, authority, store, ok=False)
        overcap_state = json.loads((store / "release-state.json").read_text())
        assert overcap_state["channels"] == json.loads(before_state)["channels"]
        assert overcap_state["membership_floors"]["fixture-org"] == {
            "membership_digest": digest(canonical(ceiling)),
            "sequence": 4,
        }
        assert sorted(path.name for path in (store / "releases").iterdir()) == before_releases
        counters["overcap_rejects"] = 1

    protected = ["bin/airlock-config", "bin/airlock-ledger", "bin/airlock-update", "install/airlock-install.sh"]
    base = run("git", "-C", str(ROOT), "merge-base", "HEAD", "origin/main", ok=True).stdout.decode().strip()
    changed = run("git", "-C", str(ROOT), "diff", "--name-only", base, "--", *protected).stdout.decode().splitlines()
    counters["public_runtime_edits"] = len(changed)

    assert counters == {
        "deterministic": 1,
        "receipt": 1,
        "forward_recovery": 1,
        "tamper_rejects": 5,
        "replay_rejects": 1,
        "revoked_rejects": 1,
        "membership_rollback_rejects": 1,
        "membership_equivocation_rejects": 1,
        "invalid_authority_rejects": 1,
        "overcap_rejects": 1,
        "nonmember_rejects": 1,
        "partial_rejects": 1,
        "public_runtime_edits": 0,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed release fixture: PASS")
    print(f"AC-MAU-R1 | expected: deterministic==1 && receipt==1 && forward_recovery==1 | observed: deterministic={counters['deterministic']},receipt={counters['receipt']},forward_recovery={counters['forward_recovery']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    print(f"AC-MAU-R2 | expected: tamper_rejects==5 && replay_rejects==1 && revoked_rejects==1 && membership_rollback_rejects==1 && membership_equivocation_rejects==1 && invalid_authority_rejects==1 && overcap_rejects==1 && nonmember_rejects==1 && partial_rejects==1 && public_runtime_edits==0 | observed: tamper_rejects={counters['tamper_rejects']},replay_rejects={counters['replay_rejects']},revoked_rejects={counters['revoked_rejects']},membership_rollback_rejects={counters['membership_rollback_rejects']},membership_equivocation_rejects={counters['membership_equivocation_rejects']},invalid_authority_rejects={counters['invalid_authority_rejects']},overcap_rejects={counters['overcap_rejects']},nonmember_rejects={counters['nonmember_rejects']},partial_rejects={counters['partial_rejects']},public_runtime_edits={counters['public_runtime_edits']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
