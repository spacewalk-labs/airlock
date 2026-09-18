#!/usr/bin/env python3
"""Boundary tests for the read-only INSTALL_RECOVERY verifier."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-installer-forward-only.py")
SPEC = importlib.util.spec_from_file_location("verify_installer_forward_only", SCRIPT)
verify = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = verify
SPEC.loader.exec_module(verify)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Bundle:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)

    def write(self, name: str, value: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def seal(self, omit: set[str] | None = None) -> str:
        omit = omit or set()
        names = sorted(
            str(path.relative_to(self.root))
            for path in self.root.rglob("*")
            if path.is_file() and path.name != "SHA256SUMS"
            and str(path.relative_to(self.root)) not in omit
        )
        self.write("SHA256SUMS", "".join(
            f"{sha256(self.root / name)}  {name}\n" for name in names
        ))
        return sha256(self.root / "SHA256SUMS")


def source_bundle(root: Path, ref: str) -> tuple[Path, str]:
    bundle = Bundle(root)
    bundle.write("source-ref.txt", ref + "\n")
    bundle.write("public-manifest.rc", "0\n")
    bundle.write("public-manifest.log", "clean: every tracked path is classified\n")
    for cases in verify.SOURCE_CASES.values():
        for case in cases:
            bundle.write(f"{case}.rc", "0\n")
            bundle.write(f"{case}.log", f"ok {case}\n---\npassed=1 failed=0\n")
    return root, bundle.seal()


def live_bundle(
    root: Path, seconds: int = 600, *, health: bool = True,
    activation: bool = False, i4: bool = False,
    live_ref: str | None = None, binding_table_ref: str | None = None,
    binding_verdict_ref: str | None = None,
) -> tuple[Path, str]:
    bundle = Bundle(root)
    first = "2026-09-12T02:21:40Z"
    start = "2026-09-12T02:21:35Z"
    end = f"2026-09-12T02:{21 + seconds // 60:02d}:{40 + seconds % 60:02d}Z"
    # datetime formatting above is intentionally replaced for values crossing an hour.
    import datetime as dt
    end = (dt.datetime.fromisoformat(first.replace("Z", "+00:00"))
           + dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")
    bundle.write("S2-taken-for-S3-timer", first + "\n")
    if health:
        bundle.write("S2-health.txt", "overview_http=200\nairlock_status_rc=0\n")
    bundle.write("S2-state.txt", f"taken_utc={start}\nboot_id=boot2\n")
    bundle.write("S3-state.txt", f"taken_utc={end}\nboot_id=boot2\n")
    bundle.write("verdict-i3-S0-S1.txt", "VERDICT=PASS\n")
    bundle.write("verdict-i3-S0-S3.txt", "VERDICT=PASS\n")
    if live_ref is not None:
        status = json.dumps({
            "checks": [{"id": "install.revision", "detail": live_ref}],
        })
        for stage in ("S1", "S2", "S3"):
            bundle.write(f"{stage}-airlock-status.json", status)
    if binding_table_ref is not None:
        bundle.write("B2-binding.tsv", f"#meta head_install={binding_table_ref}\n")
    if binding_verdict_ref is not None:
        bundle.write(
            "verdict-binding-r2.txt",
            f"required paths: 9, collected rows: 9\n"
            f"install head: {binding_verdict_ref}\nVERDICT=PASS\n",
        )
    if activation:
        bundle.write("I3-activation-live.json", json.dumps({
            "activation_failed": True,
            "next_run_resumed": True,
            "smoke_passed": True,
            "activation_record_cleared": True,
        }))
    if i4:
        bundle.write("I4-live.json", json.dumps({
            "matching_evidence_forwarded": True,
            "mismatch_mutations": 0,
            "mismatch_phase": "degraded",
        }))
    return root, bundle.seal()


def init_repo(root: Path, marker: str = "same") -> str:
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    for path in verify.REQUIRED_PATHS:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"{marker}:{path}\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    env = os.environ.copy()
    env.update({
        "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
        "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
    })
    subprocess.run([
        "git", "-C", str(root), "-c", "core.hooksPath=/dev/null",
        "commit", "-qm", "fixture",
    ], check=True, env=env)
    return subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"], check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def result(evaluation, ac: str):
    return next(item for item in evaluation.results if item.ac == ac)


class VerifyInstallerForwardOnlyTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.private = self.root / "private"
        self.private_ref = init_repo(self.private)
        self.source, self.source_sha = source_bundle(
            self.root / "source", self.private_ref)

    def tearDown(self):
        self.tempdir.cleanup()

    def inputs(self, **overrides):
        values = {
            "private_root": self.private,
            "private_ref": self.private_ref,
            "source_evidence": self.source,
            "source_manifest_sha": self.source_sha,
        }
        values.update(overrides)
        return verify.Inputs(**values)

    def test_source_pass_does_not_become_live_pass(self):
        evaluation = verify.evaluate(self.inputs())
        self.assertEqual(result(evaluation, "AC-AST-I2").verdict, "UNMEASURED")
        self.assertEqual(result(evaluation, "AC-AST-I4").verdict, "UNMEASURED")
        self.assertIn("source=PASS live=UNMEASURED", "\n".join(evaluation.layers))

    def test_no_argument_mode_binds_fixture_rows_to_verifier_checkout(self):
        run = subprocess.run([sys.executable, str(SCRIPT)], check=False,
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        rows = [line for line in run.stdout.splitlines() if line.startswith("AC-AST-")]
        self.assertEqual(len(rows), 5)
        self.assertTrue(all("verdict: PASS" in line for line in rows))
        root_ref = subprocess.run(
            ["git", "-C", str(SCRIPT.parent.parent), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        expected_evidence = f"evidence: live/verify-installer-forward-only.py@{root_ref}"
        self.assertTrue(all("signal: fixture" in line for line in rows))
        self.assertTrue(all(expected_evidence in line for line in rows))

    def test_first_200_without_observation_source_is_unmeasured(self):
        live, live_sha = live_bundle(self.root / "live", health=False)
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        item = result(evaluation, "AC-AST-I3")
        self.assertIsNone(item.observed["first200_to_s3_seconds"])
        self.assertEqual(item.verdict, "UNMEASURED")

    def test_unsealed_first_200_is_unmeasured(self):
        live, _ = live_bundle(self.root / "live")
        live_sha = Bundle(live).seal(omit={"S2-taken-for-S3-timer"})
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        self.assertIsNone(result(evaluation, "AC-AST-I3").observed[
            "first200_to_s3_seconds"])

    def test_599_seconds_fails(self):
        live, live_sha = live_bundle(self.root / "live", 599)
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        item = result(evaluation, "AC-AST-I3")
        self.assertEqual(item.observed["first200_to_s3_seconds"], 599)
        self.assertEqual(item.verdict, "FAIL")

    def test_600_seconds_closes_only_the_time_layer(self):
        live, live_sha = live_bundle(self.root / "live", 600)
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        item = result(evaluation, "AC-AST-I3")
        self.assertEqual(item.observed["first200_to_s3_seconds"], 600)
        self.assertIsNone(item.observed["live_activation_resume"])
        self.assertEqual(item.verdict, "UNMEASURED")

    def test_existing_579_second_shape_always_fails(self):
        live, live_sha = live_bundle(self.root / "live", 579)
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        self.assertEqual(result(evaluation, "AC-AST-I3").verdict, "FAIL")

    def test_snapshot_time_reversal_fails(self):
        live, live_sha = live_bundle(self.root / "live", -1)
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        item = result(evaluation, "AC-AST-I3")
        self.assertLess(item.observed["first200_to_s3_seconds"], 0)
        self.assertEqual(item.verdict, "FAIL")

    def test_missing_run1_log_and_raw_b2_stay_unmeasured(self):
        live, live_sha = live_bundle(self.root / "live", 600)
        Bundle(live).write(
            "install-run.txt",
            "run1: unit unit-one · exit 1 · tx deadbeef rolled_back · cause fixture\n",
        )
        Bundle(live).write("B2-binding.tsv", "#meta head_install=run2\n")
        Bundle(live).write("B2-binding-r2.tsv", "#meta head_install=run2\n")
        live_sha = Bundle(live).seal()
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        item = result(evaluation, "AC-AST-I2")
        self.assertIsNone(item.observed["live_run1_log"])
        self.assertIsNone(item.observed["live_run1_binding"])
        self.assertEqual(item.verdict, "UNMEASURED")

    def test_unresolvable_full_ref_fails_i1(self):
        bad_ref = "f" * 40
        evaluation = verify.evaluate(self.inputs(private_ref=bad_ref))
        self.assertEqual(result(evaluation, "AC-AST-I1").verdict, "FAIL")

    def test_public_blob_mismatch_fails_i1(self):
        public = self.root / "public"
        public_ref = init_repo(public, marker="different")
        evaluation = verify.evaluate(self.inputs(
            public_root=public, public_ref=public_ref))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["projection_blobs"], 0)
        self.assertEqual(item.verdict, "FAIL")

    def test_matching_public_fixture_does_not_claim_installed(self):
        public = self.root / "public"
        public_ref = init_repo(public)
        evaluation = verify.evaluate(self.inputs(
            public_root=public, public_ref=public_ref))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["projection_blobs"], 1)
        self.assertIsNone(item.observed["installed_ref"])
        self.assertEqual(item.verdict, "UNMEASURED")

    def test_matching_installed_binding_and_live_revision_pass_i1(self):
        public = self.root / "public"
        public_ref = init_repo(public)
        live, live_sha = live_bundle(
            self.root / "live", live_ref=self.private_ref,
            binding_table_ref=self.private_ref,
            binding_verdict_ref=self.private_ref,
        )
        evaluation = verify.evaluate(self.inputs(
            public_root=public, public_ref=public_ref,
            installed_root=self.private, installed_ref=self.private_ref,
            live_evidence=live, live_manifest_sha=live_sha,
        ))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["sealed_binding"], 1)
        self.assertEqual(item.verdict, "PASS")
        self.assertTrue(item.evidence.endswith("@" + self.private_ref))

    def test_installed_ref_mismatch_fails_and_preserves_measured_label(self):
        public = self.root / "public"
        public_ref = init_repo(public)
        measured_ref = "1" * 40
        live, live_sha = live_bundle(
            self.root / "live", live_ref=measured_ref,
            binding_table_ref=measured_ref,
            binding_verdict_ref=measured_ref,
        )
        evaluation = verify.evaluate(self.inputs(
            public_root=public, public_ref=public_ref,
            installed_root=self.private, installed_ref=self.private_ref,
            live_evidence=live, live_manifest_sha=live_sha,
        ))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["installed_blobs"], 1)
        self.assertEqual(item.observed["sealed_binding"], 0)
        self.assertEqual(item.verdict, "FAIL")
        self.assertTrue(item.evidence.endswith("@" + measured_ref))

    def test_missing_binding_report_fails_closed(self):
        live, live_sha = live_bundle(
            self.root / "live", live_ref=self.private_ref,
            binding_table_ref=self.private_ref,
        )
        evaluation = verify.evaluate(self.inputs(
            installed_root=self.private, installed_ref=self.private_ref,
            live_evidence=live, live_manifest_sha=live_sha,
        ))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["sealed_binding"], 0)
        self.assertEqual(item.verdict, "FAIL")

    def test_binding_reports_that_disagree_fail_closed(self):
        live, live_sha = live_bundle(
            self.root / "live", live_ref=self.private_ref,
            binding_table_ref=self.private_ref,
            binding_verdict_ref="2" * 40,
        )
        evaluation = verify.evaluate(self.inputs(
            installed_root=self.private, installed_ref=self.private_ref,
            live_evidence=live, live_manifest_sha=live_sha,
        ))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["sealed_binding"], 0)
        self.assertEqual(item.verdict, "FAIL")

    def test_conflicting_live_revisions_fail_closed(self):
        live, _ = live_bundle(
            self.root / "live", live_ref=self.private_ref,
            binding_table_ref=self.private_ref,
            binding_verdict_ref=self.private_ref,
        )
        Bundle(live).write("S3-airlock-status.json", json.dumps({
            "checks": [{"id": "install.revision", "detail": "3" * 40}],
        }))
        live_sha = Bundle(live).seal()
        evaluation = verify.evaluate(self.inputs(
            installed_root=self.private, installed_ref=self.private_ref,
            live_evidence=live, live_manifest_sha=live_sha,
        ))
        item = result(evaluation, "AC-AST-I1")
        self.assertEqual(item.observed["sealed_binding"], 0)
        self.assertEqual(item.verdict, "FAIL")
        self.assertTrue(item.evidence.endswith("@UNMEASURED"))

    def test_corrupt_source_manifest_fails_source_layers(self):
        (self.source / "devmon-nginx-failure.log").write_text("changed", encoding="utf-8")
        evaluation = verify.evaluate(self.inputs())
        self.assertEqual(result(evaluation, "AC-AST-I2").verdict, "FAIL")
        self.assertEqual(result(evaluation, "AC-AST-I4").verdict, "FAIL")

    def test_corrupt_live_manifest_fails_replay_layers(self):
        live, live_sha = live_bundle(self.root / "live", 600)
        (live / "S3-state.txt").write_text("changed", encoding="utf-8")
        evaluation = verify.evaluate(self.inputs(
            live_evidence=live, live_manifest_sha=live_sha))
        self.assertEqual(result(evaluation, "AC-AST-I3").verdict, "FAIL")
        self.assertEqual(result(evaluation, "AC-AST-I5").verdict, "FAIL")

    def test_exactly_five_unique_ac_rows(self):
        evaluation = verify.evaluate(self.inputs())
        rows = [item.row() for item in evaluation.results]
        self.assertEqual(len(rows), 5)
        self.assertEqual(len({row.split(" |", 1)[0] for row in rows}), 5)
        self.assertTrue(all("evidence:" in row and "@" in row for row in rows))


if __name__ == "__main__":
    unittest.main()
