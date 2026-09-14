#!/usr/bin/env python3
"""Fixture verification for the generic managed release publisher contract."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
import runpy
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
PUBLIC_SOURCE_REVISION = "1" * 40
CANONICAL_RELEASE_SUBJECT = f"release from source @ {PUBLIC_SOURCE_REVISION}"
# Reconstruct the historical label only inside the compatibility fixture.  The
# production reader deliberately recognizes labels by syntax, not by repository name.
HISTORICAL_RELEASE_LABEL = "-".join(("airlock", "work"))


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


def resolve_current(store: Path, authority: Path, *, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    return run(
        *CLI_COMMAND, "resolve-current", "--store", str(store),
        "--channel", "stable", "--authority", str(authority), "--at", LATER,
        ok=ok,
    )


def verify_current(
    store: Path, authority: Path, release: Path, *, ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return run(
        *CLI_COMMAND, "verify-current", "--release", str(release),
        "--store", str(store), "--channel", "stable",
        "--authority", str(authority), "--at", LATER,
        ok=ok,
    )


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


def refresh(
    source: Path, authority: Path, store: Path, root_key_id: str, *, ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return run(
        *CLI_COMMAND, "refresh", "--source", str(source),
        "--authority", str(authority), "--store", str(store),
        "--refreshed-at", LATER, "--expected-organization", "fixture-org",
        "--expected-channel", "stable", "--expected-root-key-id", root_key_id,
        ok=ok,
    )


def resolve_cached(
    store: Path, authority: Path, root_key_id: str, snapshot_digest: str,
    *, at: str = LATER, ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return run(
        *CLI_COMMAND, "resolve-cached", "--store", str(store),
        "--authority", str(authority), "--channel", "stable",
        "--expected-organization", "fixture-org",
        "--expected-root-key-id", root_key_id,
        "--snapshot-digest", snapshot_digest, "--at", at, ok=ok,
    )


def refresh_offline_fixture() -> int:
    counters = {
        "complete_refresh": 0,
        "enrollment_binding_rejects": 0,
        "partial_rejects": 0,
        "tamper_rejects": 0,
        "interrupted_safe": 0,
        "conflict_converges": 0,
        "current_cached": 0,
        "predecessor_cached": 0,
        "offline_cached": 0,
        "revoked_rejects": 0,
        "uncached_rejects": 0,
        "older_rejects": 0,
    }
    with tempfile.TemporaryDirectory(prefix="airlock-managed-refresh-") as temporary:
        root = Path(temporary)
        root_key = root / "root-key.pem"
        publisher_key = root / "publisher-key.pem"
        root_der, root_key_id = generate_key(root_key)
        publisher_der, publisher_key_id = generate_key(publisher_key)
        authority = root / "authority"
        set_membership(
            authority,
            membership_value(root_key, root_der, publisher_der, publisher_key_id,
                             ceiling=["system-unit"]),
            root_der,
        )
        store = root / "store"
        (store / "releases").mkdir(parents=True)

        def signed_stage(base: Path, sequence: int, capabilities: list[str] | None = None) -> Path:
            base.mkdir(parents=True, exist_ok=True)
            repo, revision = make_review_repo(base, capabilities or [], sequence)
            stage = base / f"stage-{sequence}"
            prepare(repo, revision, stage, sequence=sequence)
            sign_stage(stage, publisher_key)
            return stage

        stage1 = signed_stage(root / "one", 1)
        first = json.loads(refresh(stage1, authority, store, root_key_id).stdout)
        first_digest = first["snapshot_digest"]
        assert json.loads(resolve_cached(
            store, authority, root_key_id, first_digest,
        ).stdout)["role"] == "current"
        counters["complete_refresh"] = 1
        counters["current_cached"] = 1

        binding_cases = [
            ("--expected-organization", "other-org"),
            ("--expected-channel", "canary"),
            ("--expected-root-key-id", "sha256:" + "0" * 64),
        ]
        for changed_argument, changed_value in binding_cases:
            arguments = [
                *CLI_COMMAND, "refresh", "--source", str(stage1),
                "--authority", str(authority), "--store", str(store),
                "--refreshed-at", LATER, "--expected-organization", "fixture-org",
                "--expected-channel", "stable", "--expected-root-key-id", root_key_id,
            ]
            arguments[arguments.index(changed_argument) + 1] = changed_value
            rejected = run(*arguments, ok=False)
            assert b"enrolled" in rejected.stderr
            counters["enrollment_binding_rejects"] += 1

        state_before = (store / "release-state.json").read_bytes()
        releases_before = sorted(path.name for path in (store / "releases").iterdir())
        stage2 = signed_stage(root / "two", 2)
        partial = copy_stage(stage2, root / "partial")
        (partial / "bundle.tar").unlink()
        partial_result = refresh(partial, authority, store, root_key_id, ok=False)
        assert b"stage: expected exactly" in partial_result.stderr
        assert (store / "release-state.json").read_bytes() == state_before
        assert sorted(path.name for path in (store / "releases").iterdir()) == releases_before
        counters["partial_rejects"] = 1

        tampered = copy_stage(stage2, root / "tampered")
        (tampered / "packages/fixture-app/manifest.toml").write_bytes(b"tampered\n")
        refresh(tampered, authority, store, root_key_id, ok=False)
        assert (store / "release-state.json").read_bytes() == state_before
        assert sorted(path.name for path in (store / "releases").iterdir()) == releases_before
        counters["tamper_rejects"] = 1

        interrupted = store / ".refresh-interrupted"
        interrupted.mkdir()
        (interrupted / "partial").write_bytes(b"not published\n")
        second = json.loads(refresh(stage2, authority, store, root_key_id).stdout)
        second_digest = second["snapshot_digest"]
        assert interrupted.is_dir()
        assert json.loads(resolve_cached(
            store, authority, root_key_id, second_digest,
        ).stdout)["role"] == "current"
        assert json.loads(resolve_cached(
            store, authority, root_key_id, first_digest,
        ).stdout)["role"] == "recovery-predecessor"
        counters["interrupted_safe"] = 1
        counters["predecessor_cached"] = 1

        shutil.rmtree(stage1)
        shutil.rmtree(stage2)
        offline = resolve_cached(
            store, authority, root_key_id, first_digest,
            at="2028-09-12T04:01:00Z",
        )
        assert json.loads(offline.stdout)["cached"] is True
        counters["offline_cached"] = 1
        revoked = membership_value(
            root_key, root_der, publisher_der, publisher_key_id,
            status="revoked", sequence=2,
        )
        set_membership(authority, revoked, root_der)
        revoked_result = resolve_cached(
            store, authority, root_key_id, first_digest, ok=False,
        )
        assert b"publisher key is revoked" in revoked_result.stderr
        counters["revoked_rejects"] = 1
        set_membership(
            authority,
            membership_value(root_key, root_der, publisher_der, publisher_key_id,
                             ceiling=["system-unit"]),
            root_der,
        )
        missing = resolve_cached(
            store, authority, root_key_id, "sha256:" + "f" * 64, ok=False,
        )
        assert b"exact managed bundle is not cached" in missing.stderr
        counters["uncached_rejects"] = 1

        stage3a = signed_stage(root / "three-a", 3)
        stage3b = signed_stage(root / "three-b", 3, ["system-unit"])
        commands = [
            [
                *CLI_COMMAND, "refresh", "--source", str(stage),
                "--authority", str(authority), "--store", str(store),
                "--refreshed-at", LATER, "--expected-organization", "fixture-org",
                "--expected-channel", "stable", "--expected-root-key-id", root_key_id,
            ]
            for stage in (stage3a, stage3b)
        ]
        processes = [
            subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for command in commands
        ]
        results = [process.communicate() + (process.returncode,) for process in processes]
        assert sorted(result[2] for result in results) == [0, 2]
        winner = json.loads(next(result[0] for result in results if result[2] == 0))
        current = json.loads(resolve_current(store, authority).stdout)
        assert current["snapshot_digest"] == winner["snapshot_digest"]
        counters["conflict_converges"] = 1

        stage4 = signed_stage(root / "four", 4)
        fourth = json.loads(refresh(stage4, authority, store, root_key_id).stdout)
        fourth_cached = json.loads(resolve_cached(
            store, authority, root_key_id, fourth["snapshot_digest"],
        ).stdout)
        winner_cached = json.loads(resolve_cached(
            store, authority, root_key_id, winner["snapshot_digest"],
        ).stdout)
        assert fourth_cached["role"] == "current"
        assert winner_cached["role"] == "recovery-predecessor"
        older = resolve_cached(store, authority, root_key_id, second_digest, ok=False)
        assert b"not current or its recovery predecessor" in older.stderr
        counters["older_rejects"] = 1

    assert counters == {
        "complete_refresh": 1,
        "enrollment_binding_rejects": 3,
        "partial_rejects": 1,
        "tamper_rejects": 1,
        "interrupted_safe": 1,
        "conflict_converges": 1,
        "current_cached": 1,
        "predecessor_cached": 1,
        "offline_cached": 1,
        "revoked_rejects": 1,
        "uncached_rejects": 1,
        "older_rejects": 1,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed release refresh/offline fixture: PASS")
    print(
        "AC-MAU-RF | expected: "
        + " && ".join(f"{key}=={value}" for key, value in counters.items())
        + " | observed: " + ",".join(f"{key}={value}" for key, value in counters.items())
        + f" | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}"
    )
    return 0


def commit_fixture(repo: Path, subject: str, *, allow_empty: bool = False) -> str:
    command = ["git", "-C", str(repo), "commit", "-q", "-m", subject]
    if allow_empty:
        command.insert(4, "--allow-empty")
    env = dict(
        os.environ,
        GIT_AUTHOR_DATE="2026-09-12T00:00:00Z",
        GIT_COMMITTER_DATE="2026-09-12T00:00:00Z",
    )
    result = subprocess.run(
        command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.decode(errors="replace"))
    return run("git", "-C", str(repo), "rev-parse", "HEAD").stdout.decode().strip()


def make_public_repo(
    root: Path,
    name: str,
    entries: dict[str, tuple[str, int, bytes | str]],
    *,
    subject: str | None = None,
) -> tuple[Path, str]:
    repo = root / name
    repo.mkdir()
    run("git", "init", "-q", "-b", "main", str(repo))
    run("git", "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    run("git", "-C", str(repo), "config", "user.name", "Public core fixture")
    for relative, (kind, mode, value) in entries.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == "file":
            assert isinstance(value, bytes)
            path.write_bytes(value)
            path.chmod(mode)
        else:
            assert kind == "symlink" and isinstance(value, str) and mode == 0o777
            path.symlink_to(value)
    run("git", "-C", str(repo), "add", "-A")
    release_subject = subject or CANONICAL_RELEASE_SUBJECT
    return repo, commit_fixture(repo, release_subject, allow_empty=not entries)


def public_manifest_oracle(
    entries: dict[str, tuple[str, int, bytes | str]],
) -> tuple[list[dict[str, object]], str]:
    manifest: list[dict[str, object]] = []
    for path in sorted(entries, key=lambda value: value.encode("utf-8")):
        kind, mode, value = entries[path]
        row: dict[str, object] = {
            "mode": f"{mode:04o}",
            "path": path,
            "type": kind,
        }
        if kind == "file":
            assert isinstance(value, bytes)
            row["digest"] = digest(value)
        else:
            assert kind == "symlink" and isinstance(value, str)
            row["target"] = value
        manifest.append(row)
    return manifest, digest(canonical(manifest))


def measure_public_core(
    repo: Path, revision: str, *, ok: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    result = run(
        *CLI_COMMAND, "measure-public-core", "--repository", str(repo),
        "--revision", revision, ok=ok,
    )
    if not ok:
        assert result.stdout == b"", result.stdout
    return result


def git_read_snapshot(repo: Path) -> tuple[bytes, bytes, bytes]:
    return (
        run("git", "-C", str(repo), "status", "--porcelain=v1", "--untracked-files=all").stdout,
        run("git", "-C", str(repo), "for-each-ref", "--format=%(refname) %(objectname)").stdout,
        run("git", "-C", str(repo), "rev-parse", "HEAD^{tree}").stdout,
    )


def unassigned_runtime_edits(repo: Path) -> list[str]:
    protected = ["bin/airlock-ledger", "install/airlock-install.sh"]
    # origin/main is the integrated ownership boundary: edits already merged
    # there were assigned to their app/platform PR.  This release verifier owns
    # neither protected path, so only edits introduced by the current branch or
    # worktree are unassigned here.  An immutable historical base turns every
    # later owner-approved platform change into permanent false-positive debt.
    base = run(
        "git", "-C", str(repo), "merge-base", "HEAD", "origin/main",
    ).stdout.decode().strip()
    return run(
        "git", "-C", str(repo), "diff", "--name-only", base, "--", *protected,
    ).stdout.decode().splitlines()


def print_core_ac(counters: dict[str, int], revision: str) -> None:
    print(f"AC-MAU-U0C | expected: core_measures==1 && core_new_subject_accepts==1 && core_legacy_subject_accepts==1 && core_closed_shape==1 && core_independent_digest==1 && core_clone_equal==1 && core_read_only==1 && core_replace_ignored==1 && core_mutation_changes==6 && core_input_rejects==6 && core_subject_rejects==2 && core_tree_rejects==4 && core_empty_stdout_rejects==12 | observed: core_measures={counters['core_measures']},core_new_subject_accepts={counters['core_new_subject_accepts']},core_legacy_subject_accepts={counters['core_legacy_subject_accepts']},core_closed_shape={counters['core_closed_shape']},core_independent_digest={counters['core_independent_digest']},core_clone_equal={counters['core_clone_equal']},core_read_only={counters['core_read_only']},core_replace_ignored={counters['core_replace_ignored']},core_mutation_changes={counters['core_mutation_changes']},core_input_rejects={counters['core_input_rejects']},core_subject_rejects={counters['core_subject_rejects']},core_tree_rejects={counters['core_tree_rejects']},core_empty_stdout_rejects={counters['core_empty_stdout_rejects']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--case", choices=["measure-public-core", "refresh-offline"])
    arguments.add_argument("--emit-ac", action="store_true")
    options = arguments.parse_args()
    if options.case == "refresh-offline":
        return refresh_offline_fixture()
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
        "current_resolves": 0,
        "current_closed_shape": 0,
        "current_read_only": 0,
        "current_symlink_rejects": 0,
        "current_receipt_rejects": 0,
        "current_pointer_rejects": 0,
        "current_race_rejects": 0,
        "current_signed_race_rejects": 0,
        "current_revocation_rejects": 0,
        "promoted_current_verifies": 0,
        "promoted_current_closed_shape": 0,
        "promoted_current_missing_rejects": 0,
        "promoted_current_modified_rejects": 0,
        "promoted_current_foreign_rejects": 0,
        "promoted_current_stale_rejects": 0,
        "promoted_current_revocation_rejects": 0,
        "signed_stage_strict": 0,
        "core_measures": 0,
        "core_new_subject_accepts": 0,
        "core_legacy_subject_accepts": 0,
        "core_closed_shape": 0,
        "core_independent_digest": 0,
        "core_clone_equal": 0,
        "core_read_only": 0,
        "core_replace_ignored": 0,
        "core_mutation_changes": 0,
        "core_input_rejects": 0,
        "core_subject_rejects": 0,
        "core_tree_rejects": 0,
        "core_empty_stdout_rejects": 0,
        "unassigned_runtime_edits": -1,
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

        public_entries: dict[str, tuple[str, int, bytes | str]] = {
            "README.md": ("file", 0o644, b"public core fixture\n"),
            "bin/tool": ("file", 0o755, b"#!/bin/sh\necho public\n"),
            "docs/contract.txt": ("file", 0o644, b"closed measurement\n"),
            "readme-link": ("symlink", 0o777, "README.md"),
        }
        public_repo, public_revision = make_public_repo(
            root, "public-core", public_entries,
        )
        _manifest, public_digest = public_manifest_oracle(public_entries)
        public_tree = run(
            "git", "-C", str(public_repo), "rev-parse", "HEAD^{tree}",
        ).stdout.decode().strip()
        public_before = git_read_snapshot(public_repo)
        measured_result = measure_public_core(public_repo, public_revision)
        measured = json.loads(measured_result.stdout)
        expected_measurement = {
            "digest": public_digest,
            "public_revision": public_revision,
            "public_tree": public_tree,
            "schema": "airlock.core-public-measurement/v1",
            "source_revision": PUBLIC_SOURCE_REVISION,
        }
        assert measured_result.stdout == canonical(expected_measurement)
        assert set(measured) == {
            "digest", "public_revision", "public_tree", "schema",
            "source_revision",
        }
        counters["core_measures"] = 1
        counters["core_new_subject_accepts"] = 1
        counters["core_closed_shape"] = 1
        counters["core_independent_digest"] = 1
        assert git_read_snapshot(public_repo) == public_before
        counters["core_read_only"] = 1

        public_clone = root / "public-core-clone"
        run(
            "git", "clone", "-q", "--depth=1", f"file://{public_repo}",
            str(public_clone),
        )
        clone_before = git_read_snapshot(public_clone)
        clone_result = measure_public_core(public_clone, public_revision)
        assert clone_result.stdout == measured_result.stdout
        assert git_read_snapshot(public_clone) == clone_before
        counters["core_clone_equal"] = 1

        legacy_repo, legacy_revision = make_public_repo(
            root, "public-legacy-subject", public_entries,
            subject=(
                f"release from {HISTORICAL_RELEASE_LABEL} @ "
                f"{PUBLIC_SOURCE_REVISION[:7]}"
            ),
        )
        legacy_measurement = json.loads(
            measure_public_core(legacy_repo, legacy_revision).stdout
        )
        assert legacy_measurement["source_revision"] == PUBLIC_SOURCE_REVISION[:7]
        counters["core_legacy_subject_accepts"] = 1

        replacement_entries = dict(public_entries)
        replacement_entries["README.md"] = (
            "file", 0o644, b"replacement different content\n",
        )
        replacement_entries["bin/backdoor"] = (
            "file", 0o755, b"#!/bin/sh\necho replacement\n",
        )
        replacement_repo, replacement_revision = make_public_repo(
            root, "public-replacement", replacement_entries,
            subject="release from source @ " + "2" * 40,
        )
        run(
            "git", "-C", str(public_repo), "fetch", "-q",
            str(replacement_repo), replacement_revision,
        )
        run(
            "git", "-C", str(public_repo), "replace",
            public_revision, replacement_revision,
        )
        replacement_ref = f"refs/replace/{public_revision}"
        assert run(
            "git", "-C", str(public_repo), "show-ref", "--verify",
            replacement_ref,
        ).stdout.decode().split()[0] == replacement_revision
        replaced_before = git_read_snapshot(public_repo)
        replaced_result = measure_public_core(public_repo, public_revision)
        assert replaced_result.stdout == measured_result.stdout
        assert replaced_result.stdout == clone_result.stdout
        assert git_read_snapshot(public_repo) == replaced_before
        assert run(
            "git", "-C", str(public_repo), "show-ref", "--verify",
            replacement_ref,
        ).stdout.decode().split()[0] == replacement_revision
        counters["core_replace_ignored"] = 1

        mutations: dict[str, dict[str, tuple[str, int, bytes | str]]] = {}
        changed_content = dict(public_entries)
        changed_content["README.md"] = ("file", 0o644, b"changed public core\n")
        mutations["content"] = changed_content
        changed_mode = dict(public_entries)
        changed_mode["bin/tool"] = ("file", 0o644, b"#!/bin/sh\necho public\n")
        mutations["mode"] = changed_mode
        changed_path = dict(public_entries)
        changed_path["ABOUT.md"] = changed_path.pop("README.md")
        mutations["path"] = changed_path
        changed_symlink = dict(public_entries)
        changed_symlink["readme-link"] = ("symlink", 0o777, "docs/contract.txt")
        mutations["symlink"] = changed_symlink
        added_path = dict(public_entries)
        added_path["NOTICE"] = ("file", 0o644, b"added path\n")
        mutations["addition"] = added_path
        deleted_path = dict(public_entries)
        del deleted_path["docs/contract.txt"]
        mutations["deletion"] = deleted_path
        for name, entries in mutations.items():
            mutation_repo, mutation_revision = make_public_repo(
                root, f"public-{name}", entries,
            )
            _mutation_manifest, mutation_digest = public_manifest_oracle(entries)
            mutation_result = measure_public_core(mutation_repo, mutation_revision)
            mutation_measurement = json.loads(mutation_result.stdout)
            assert mutation_measurement["digest"] == mutation_digest
            assert mutation_measurement["digest"] != public_digest
            counters["core_mutation_changes"] += 1

        rejected: list[tuple[Path, str, str]] = [
            (public_repo, public_revision[:39], "input"),
            (public_repo, public_revision[:12], "input"),
            (public_repo, "HEAD", "input"),
            (public_repo, "f" * 40, "input"),
        ]
        abbreviated_subject_repo, abbreviated_subject_revision = make_public_repo(
            root, "public-abbreviated-subject", public_entries,
            subject=f"release from source @ {PUBLIC_SOURCE_REVISION[:7]}",
        )
        rejected.append((abbreviated_subject_repo, abbreviated_subject_revision, "subject"))
        extra_subject_repo, extra_subject_revision = make_public_repo(
            root, "public-extra-subject", public_entries,
            subject=(
                f"release from source @ {PUBLIC_SOURCE_REVISION} extra"
            ),
        )
        rejected.append((extra_subject_repo, extra_subject_revision, "subject"))

        empty_repo, empty_revision = make_public_repo(
            root, "public-empty", {},
        )
        rejected.append((empty_repo, empty_revision, "tree"))
        unsafe_entries = dict(public_entries)
        unsafe_entries["escape"] = ("symlink", 0o777, "../outside")
        unsafe_repo, unsafe_revision = make_public_repo(
            root, "public-unsafe-symlink", unsafe_entries,
        )
        rejected.append((unsafe_repo, unsafe_revision, "tree"))

        gitlink_repo, gitlink_parent = make_public_repo(
            root, "public-gitlink", public_entries,
        )
        run(
            "git", "-C", str(gitlink_repo), "update-index", "--add",
            "--cacheinfo", f"160000,{gitlink_parent},nested-repository",
        )
        gitlink_revision = commit_fixture(
            gitlink_repo,
            CANONICAL_RELEASE_SUBJECT,
        )
        rejected.append((gitlink_repo, gitlink_revision, "tree"))

        invalid_utf8_repo = root / "public-invalid-utf8"
        invalid_utf8_repo.mkdir()
        run("git", "init", "-q", "-b", "main", str(invalid_utf8_repo))
        run("git", "-C", str(invalid_utf8_repo), "config", "user.email", "fixture@example.invalid")
        run("git", "-C", str(invalid_utf8_repo), "config", "user.name", "Public core fixture")
        invalid_path = os.fsencode(invalid_utf8_repo) + b"/invalid-\xff"
        invalid_fd = os.open(invalid_path, os.O_WRONLY | os.O_CREAT, 0o644)
        try:
            os.write(invalid_fd, b"invalid UTF-8 path\n")
        finally:
            os.close(invalid_fd)
        invalid_add = subprocess.run(
            [b"git", b"-C", os.fsencode(invalid_utf8_repo), b"add", b"-A"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        assert invalid_add.returncode == 0, invalid_add.stderr
        invalid_utf8_revision = commit_fixture(
            invalid_utf8_repo,
            CANONICAL_RELEASE_SUBJECT,
        )
        rejected.append((invalid_utf8_repo, invalid_utf8_revision, "tree"))

        public_repo_link = root / "public-core-link"
        public_repo_link.symlink_to(public_repo, target_is_directory=True)
        rejected.append((public_repo_link, public_revision, "input"))
        rejected.append((public_repo / "bin", public_revision, "input"))

        for repo, revision, kind in rejected:
            measure_public_core(repo, revision, ok=False)
            counters[f"core_{kind}_rejects"] += 1
            counters["core_empty_stdout_rejects"] += 1

        core_expected = {
            "core_measures": 1,
            "core_new_subject_accepts": 1,
            "core_legacy_subject_accepts": 1,
            "core_closed_shape": 1,
            "core_independent_digest": 1,
            "core_clone_equal": 1,
            "core_read_only": 1,
            "core_replace_ignored": 1,
            "core_mutation_changes": 6,
            "core_input_rejects": 6,
            "core_subject_rejects": 2,
            "core_tree_rejects": 4,
            "core_empty_stdout_rejects": 12,
        }
        if options.case == "measure-public-core":
            assert {
                key: counters[key] for key in core_expected
            } == core_expected
            revision = run(
                "git", "-C", str(ROOT), "rev-parse", "HEAD",
            ).stdout.decode().strip()
            print("managed release measure-public-core fixture: PASS")
            if options.emit_ac:
                print_core_ac(counters, revision)
            return 0

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

        store_before_resolve = tree_bytes(store)
        authority_before_resolve = tree_bytes(authority)
        current_result = resolve_current(store, authority)
        assert current_result.stdout == canonical(json.loads(current_result.stdout))
        current = json.loads(current_result.stdout)
        assert set(current) == {
            "authority_membership_digest", "authority_sequence", "bundle_digest",
            "catalog_digest", "channel_id", "core_digest", "core_revision", "epoch",
            "lock_digest", "organization_id", "promotion_membership_digest",
            "promotion_receipt_digest", "promotion_receipt_path", "publisher_id",
            "publisher_key_id", "receipt_id", "release_path", "requested_capabilities",
            "root_key_id", "schema", "sequence", "snapshot_digest", "target_profile",
            "verified_at",
        }
        assert current == {
            "authority_membership_digest": digest(canonical(membership)),
            "authority_sequence": 1,
            "bundle_digest": json.loads((Path(promoted["release"]) / "snapshot.json").read_text())["artifacts"]["bundle.tar"],
            "catalog_digest": json.loads((Path(promoted["release"]) / "snapshot.json").read_text())["artifacts"]["catalog.json"],
            "channel_id": "stable",
            "core_digest": CORE_DIGEST,
            "core_revision": CORE_REVISION,
            "epoch": 1,
            "lock_digest": json.loads((Path(promoted["release"]) / "snapshot.json").read_text())["artifacts"]["release.lock"],
            "organization_id": "fixture-org",
            "promotion_membership_digest": receipt["membership_digest"],
            "promotion_receipt_digest": digest(canonical(receipt)),
            "promotion_receipt_path": str(Path(promoted["receipt"])),
            "publisher_id": "publisher-a",
            "publisher_key_id": publisher_key_id,
            "receipt_id": receipt["receipt_id"],
            "release_path": str(Path(promoted["release"])),
            "requested_capabilities": [],
            "root_key_id": digest(root_der),
            "schema": "airlock.managed.current-release/v1",
            "sequence": 1,
            "snapshot_digest": promoted["snapshot_digest"],
            "target_profile": "team",
            "verified_at": LATER,
        }
        counters["current_resolves"] = 1
        counters["current_closed_shape"] = 1
        assert tree_bytes(store) == store_before_resolve
        assert tree_bytes(authority) == authority_before_resolve
        counters["current_read_only"] = 1

        current_release = Path(promoted["release"])
        current_verification = verify_current(store, authority, current_release)
        assert current_verification.stdout == canonical(json.loads(current_verification.stdout))
        current_verified = json.loads(current_verification.stdout)
        assert set(current_verified) == {
            "bundle_digest", "membership_digest", "publisher_key_id", "snapshot_digest",
        }
        assert current_verified == {
            "bundle_digest": current["bundle_digest"],
            "membership_digest": current["authority_membership_digest"],
            "publisher_key_id": current["publisher_key_id"],
            "snapshot_digest": current["snapshot_digest"],
        }
        counters["promoted_current_verifies"] = 1
        counters["promoted_current_closed_shape"] = 1

        # The default ABI remains a strict signed-stage verifier. Promotion is
        # accepted only through the explicit current-pointer mode.
        run(
            *CLI_COMMAND, "verify", "--stage", str(stage1), "--signed",
            "--authority", str(authority), "--at", LATER,
        )
        run(
            *CLI_COMMAND, "verify", "--stage", str(current_release), "--signed",
            "--authority", str(authority), "--at", LATER, ok=False,
        )
        counters["signed_stage_strict"] = 2

        missing_store = root / "verify-current-missing-store"
        shutil.copytree(store, missing_store)
        missing_release = missing_store / "releases" / current_release.name
        (missing_release / "promotion-receipt.json").unlink()
        verify_current(missing_store, authority, missing_release, ok=False)
        counters["promoted_current_missing_rejects"] = 1

        modified_store = root / "verify-current-modified-store"
        shutil.copytree(store, modified_store)
        modified_release = modified_store / "releases" / current_release.name
        modified_receipt = json.loads(
            (modified_release / "promotion-receipt.json").read_text()
        )
        modified_receipt["sequence"] += 1
        write_json(modified_release / "promotion-receipt.json", modified_receipt)
        verify_current(modified_store, authority, modified_release, ok=False)
        counters["promoted_current_modified_rejects"] = 1

        foreign_store = root / "verify-current-foreign-store"
        shutil.copytree(store, foreign_store)
        foreign_release = foreign_store / "releases" / current_release.name
        verify_current(store, authority, foreign_release, ok=False)
        counters["promoted_current_foreign_rejects"] = 1

        stale_store = root / "verify-current-stale-store"
        shutil.copytree(store, stale_store)
        stale_release = stale_store / "releases" / current_release.name
        repo2, revision2 = make_review_repo(root, [], 20)
        stage2 = root / "promoted-current-stage-2"
        prepare(repo2, revision2, stage2, sequence=2)
        sign_stage(stage2, publisher_key)
        promote(stage2, authority, stale_store, ok=True)
        verify_current(stale_store, authority, stale_release, ok=False)
        counters["promoted_current_stale_rejects"] = 1

        store_link = root / "store-link"
        store_link.symlink_to(store, target_is_directory=True)
        resolve_current(store_link, authority, ok=False)
        assert tree_bytes(store) == store_before_resolve
        counters["current_symlink_rejects"] += 1

        symlink_store = root / "symlink-store"
        shutil.copytree(store, symlink_store)
        symlink_release = symlink_store / "releases" / Path(promoted["release"]).name
        symlink_target = root / "symlink-release-target"
        symlink_release.rename(symlink_target)
        symlink_release.symlink_to(symlink_target, target_is_directory=True)
        symlink_before = tree_bytes(symlink_store)
        resolve_current(symlink_store, authority, ok=False)
        assert tree_bytes(symlink_store) == symlink_before
        counters["current_symlink_rejects"] += 1

        receipt_store = root / "receipt-store"
        shutil.copytree(store, receipt_store)
        receipt_release = receipt_store / "releases" / Path(promoted["release"]).name
        bad_receipt = json.loads((receipt_release / "promotion-receipt.json").read_text())
        bad_receipt["sequence"] += 1
        bad_receipt_base = dict(bad_receipt)
        bad_receipt_base.pop("receipt_id")
        bad_receipt["receipt_id"] = digest(canonical(bad_receipt_base))
        write_json(receipt_release / "promotion-receipt.json", bad_receipt)
        receipt_state = json.loads((receipt_store / "release-state.json").read_text())
        receipt_state["channels"]["stable"]["receipt_digest"] = digest(canonical(bad_receipt))
        write_json(receipt_store / "release-state.json", receipt_state)
        receipt_before = tree_bytes(receipt_store)
        resolve_current(receipt_store, authority, ok=False)
        assert tree_bytes(receipt_store) == receipt_before
        counters["current_receipt_rejects"] = 1

        pointer_store = root / "pointer-store"
        shutil.copytree(store, pointer_store)
        bad_pointer = json.loads((pointer_store / "release-state.json").read_text())
        bad_pointer["channels"]["stable"]["sequence"] += 1
        write_json(pointer_store / "release-state.json", bad_pointer)
        pointer_before = tree_bytes(pointer_store)
        resolve_current(pointer_store, authority, ok=False)
        assert tree_bytes(pointer_store) == pointer_before
        counters["current_pointer_rejects"] = 1

        race_store = root / "race-store"
        shutil.copytree(store, race_store)
        race_lock_fd = os.open(race_store / ".promotion.lock", os.O_RDONLY | os.O_CLOEXEC)
        fcntl.flock(race_lock_fd, fcntl.LOCK_EX)
        race_process = subprocess.Popen(
            [
                *CLI_COMMAND, "resolve-current", "--store", str(race_store),
                "--channel", "stable", "--authority", str(authority), "--at", LATER,
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            try:
                race_process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("resolve-current did not wait for the promotion lock")
            raced_pointer = json.loads((race_store / "release-state.json").read_text())
            raced_pointer["channels"]["stable"]["sequence"] += 1
            write_json(race_store / "release-state.json", raced_pointer)
            race_before = tree_bytes(race_store)
        finally:
            fcntl.flock(race_lock_fd, fcntl.LOCK_UN)
            os.close(race_lock_fd)
        race_stdout, race_stderr = race_process.communicate(timeout=10)
        assert race_process.returncode != 0, race_stdout.decode(errors="replace")
        assert b"release-state channel pointer" in race_stderr
        assert tree_bytes(race_store) == race_before
        counters["current_race_rejects"] = 1

        # Reproduce the AST10 in-process race exactly: change a signed output
        # source after the resolver's second authority observation. The handler
        # must never combine the snapshot's old digest with newly parsed bytes.
        signed_mutations = {
            "release.lock": lambda value: value["core"].update({
                "digest": "sha256:" + "a" * 64,
                "revision": "f" * 40,
            }),
            "snapshot.json": lambda value: value.update({"target_profile": "other"}),
            "signature.json": lambda value: value.update({"publisher_id": "publisher-b"}),
        }
        for name, mutate in signed_mutations.items():
            signed_race_store = root / f"signed-race-{name}"
            shutil.copytree(store, signed_race_store)
            signed_race_release = (
                signed_race_store / "releases" / Path(promoted["release"]).name
            )
            target = signed_race_release / name
            before_tree = tree_bytes(signed_race_store)
            module = runpy.run_path(str(CLI))
            handler = module["command_resolve_current"]
            release_error = module["ReleaseError"]
            original_load_authority = handler.__globals__["load_authority"]
            calls = 0

            def mutate_after_final_authority(path: Path) -> tuple[dict[str, object], str]:
                nonlocal calls
                value = original_load_authority(path)
                calls += 1
                if calls == 2:
                    changed = json.loads(target.read_text())
                    mutate(changed)
                    write_json(target, changed)
                return value

            handler.__globals__["load_authority"] = mutate_after_final_authority
            try:
                handler(argparse.Namespace(
                    store=str(signed_race_store), authority=str(authority),
                    channel="stable", at=LATER,
                ))
            except release_error as exc:
                assert "changed while the promotion lock was held" in str(exc)
            else:
                raise AssertionError(f"resolve-current accepted a raced {name}")
            assert calls == 2
            after_tree = tree_bytes(signed_race_store)
            changed_paths = sorted(
                path for path in set(before_tree) | set(after_tree)
                if before_tree.get(path) != after_tree.get(path)
            )
            assert changed_paths == [
                f"releases/{Path(promoted['release']).name}/{name}"
            ]
            counters["current_signed_race_rejects"] += 1

        revoked_for_resolver = membership_value(
            root_key, root_der, publisher_der, publisher_key_id,
            status="revoked", sequence=2,
        )
        set_membership(authority, revoked_for_resolver, root_der)
        revoked_resolve_store_before = tree_bytes(store)
        revoked_resolve_authority_before = tree_bytes(authority)
        resolve_current(store, authority, ok=False)
        verify_current(store, authority, current_release, ok=False)
        assert tree_bytes(store) == revoked_resolve_store_before
        assert tree_bytes(authority) == revoked_resolve_authority_before
        counters["current_revocation_rejects"] = 1
        counters["promoted_current_revocation_rejects"] = 1
        set_membership(authority, membership, root_der)

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

    # Integrated app/platform PRs own their origin/main runtime edits.  Diff
    # through the worktree so this release branch cannot change an unowned
    # installer/ledger path, committed or otherwise.
    unassigned_runtime_paths = unassigned_runtime_edits(ROOT)
    counters["unassigned_runtime_edits"] = len(unassigned_runtime_paths)

    expected_counters = {
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
        "current_resolves": 1,
        "current_closed_shape": 1,
        "current_read_only": 1,
        "current_symlink_rejects": 2,
        "current_receipt_rejects": 1,
        "current_pointer_rejects": 1,
        "current_race_rejects": 1,
        "current_signed_race_rejects": 3,
        "current_revocation_rejects": 1,
        "promoted_current_verifies": 1,
        "promoted_current_closed_shape": 1,
        "promoted_current_missing_rejects": 1,
        "promoted_current_modified_rejects": 1,
        "promoted_current_foreign_rejects": 1,
        "promoted_current_stale_rejects": 1,
        "promoted_current_revocation_rejects": 1,
        "signed_stage_strict": 2,
        "core_measures": 1,
        "core_new_subject_accepts": 1,
        "core_legacy_subject_accepts": 1,
        "core_closed_shape": 1,
        "core_independent_digest": 1,
        "core_clone_equal": 1,
        "core_read_only": 1,
        "core_replace_ignored": 1,
        "core_mutation_changes": 6,
        "core_input_rejects": 6,
        "core_subject_rejects": 2,
        "core_tree_rejects": 4,
        "core_empty_stdout_rejects": 12,
        "unassigned_runtime_edits": 0,
    }
    assert counters == expected_counters, {
        "expected": expected_counters,
        "observed": counters,
        "unassigned_runtime_paths": unassigned_runtime_paths,
    }
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.decode().strip()
    print("managed release fixture: PASS")
    print(f"AC-MAU-R1 | expected: deterministic==1 && receipt==1 && forward_recovery==1 | observed: deterministic={counters['deterministic']},receipt={counters['receipt']},forward_recovery={counters['forward_recovery']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    print(f"AC-MAU-R2 | expected: tamper_rejects==5 && replay_rejects==1 && revoked_rejects==1 && membership_rollback_rejects==1 && membership_equivocation_rejects==1 && invalid_authority_rejects==1 && overcap_rejects==1 && nonmember_rejects==1 && partial_rejects==1 && unassigned_runtime_edits==0 | observed: tamper_rejects={counters['tamper_rejects']},replay_rejects={counters['replay_rejects']},revoked_rejects={counters['revoked_rejects']},membership_rollback_rejects={counters['membership_rollback_rejects']},membership_equivocation_rejects={counters['membership_equivocation_rejects']},invalid_authority_rejects={counters['invalid_authority_rejects']},overcap_rejects={counters['overcap_rejects']},nonmember_rejects={counters['nonmember_rejects']},partial_rejects={counters['partial_rejects']},unassigned_runtime_edits={counters['unassigned_runtime_edits']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    print(f"AC-MAU-U0 | expected: current_resolves==1 && current_closed_shape==1 && current_read_only==1 && current_symlink_rejects==2 && current_receipt_rejects==1 && current_pointer_rejects==1 && current_race_rejects==1 && current_signed_race_rejects==3 && current_revocation_rejects==1 | observed: current_resolves={counters['current_resolves']},current_closed_shape={counters['current_closed_shape']},current_read_only={counters['current_read_only']},current_symlink_rejects={counters['current_symlink_rejects']},current_receipt_rejects={counters['current_receipt_rejects']},current_pointer_rejects={counters['current_pointer_rejects']},current_race_rejects={counters['current_race_rejects']},current_signed_race_rejects={counters['current_signed_race_rejects']},current_revocation_rejects={counters['current_revocation_rejects']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    print(f"AC-MAU-U0P | expected: promoted_current_verifies==1 && promoted_current_closed_shape==1 && promoted_current_missing_rejects==1 && promoted_current_modified_rejects==1 && promoted_current_foreign_rejects==1 && promoted_current_stale_rejects==1 && promoted_current_revocation_rejects==1 && signed_stage_strict==2 | observed: promoted_current_verifies={counters['promoted_current_verifies']},promoted_current_closed_shape={counters['promoted_current_closed_shape']},promoted_current_missing_rejects={counters['promoted_current_missing_rejects']},promoted_current_modified_rejects={counters['promoted_current_modified_rejects']},promoted_current_foreign_rejects={counters['promoted_current_foreign_rejects']},promoted_current_stale_rejects={counters['promoted_current_stale_rejects']},promoted_current_revocation_rejects={counters['promoted_current_revocation_rejects']},signed_stage_strict={counters['signed_stage_strict']} | verdict: PASS | signal: fixture | evidence: install/test-managed-release.py@{revision}")
    print_core_ac(counters, revision)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
