#!/usr/bin/env python3
"""Grade sealed INSTALL_RECOVERY evidence without running product code.

The verifier reads caller-supplied git refs and evidence directories.  It never
checks out a ref, invokes an installer, opens a database, or probes a service.
Its five AC rows deliberately keep source/fixture, projection, replay, and live
layers separate: a fixture PASS cannot manufacture a live PASS.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Callable


FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}\Z")
FULL_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
TX_LINE = re.compile(
    r"run(?P<run>[12]): unit (?P<unit>\S+) .* exit (?P<exit>[0-9]+) .* "
    r"tx (?P<tx>[0-9a-f]+) (?P<phase>\S+)(?: .* head (?P<head>[0-9a-f]+))?"
)

REQUIRED_PATHS = (
    "install/airlock-install.sh",
    "install/test-installer-transaction.sh",
    "apps/dev-monitor/install.sh",
    "apps/dev-monitor/migration-lifecycle.sh",
    "apps/dev-monitor/activation-record.py",
    "apps/dev-monitor/migrate-legacy-state.py",
    "apps/dev-monitor/backend/devmon_messages.py",
    "bin/airlock-ledger",
    "bin/airlock-status",
)

SOURCE_CASES = {
    "i2": (
        "devmon-nginx-failure",
        "devmon-later-app-fails",
    ),
    "i3": (
        "devmon-activation-resume",
        "devmon-activation-record",
        "devmon-fence-recovery",
    ),
    "i4": (
        "devmon-receipt-forward-keep",
        "devmon-receipt-degraded-reentry",
        "devmon-receipt-refuses-unsound",
        "devmon-keep-forward-bound",
        "devmon-keep-forward-evidence",
    ),
}


class VerificationError(RuntimeError):
    """Supplied evidence was measured and is invalid."""


@dataclasses.dataclass
class Result:
    ac: str
    expected: str
    observed: dict[str, int | None]
    verdict: str
    signal: str
    evidence: str

    def row(self) -> str:
        measured = ",".join(
            f"{key}={value}" for key, value in self.observed.items()
            if value is not None
        )
        return (
            f"{self.ac} | expected: {self.expected} | observed: {measured} | "
            f"verdict: {self.verdict} | signal: {self.signal} | "
            f"evidence: {self.evidence}"
        )


@dataclasses.dataclass
class Evaluation:
    results: list[Result]
    layers: list[str]

    @property
    def exit_code(self) -> int:
        if any(result.verdict == "FAIL" for result in self.results):
            return 1
        if any(result.verdict == "UNMEASURED" for result in self.results):
            return 2
        return 0


@dataclasses.dataclass
class Inputs:
    private_root: Path | None = None
    private_ref: str | None = None
    public_root: Path | None = None
    public_ref: str | None = None
    installed_root: Path | None = None
    installed_ref: str | None = None
    source_evidence: Path | None = None
    source_manifest_sha: str | None = None
    live_evidence: Path | None = None
    live_manifest_sha: str | None = None


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_bytes(path: Path) -> bytes:
    if not path.is_file() or path.is_symlink():
        raise VerificationError(f"not a sealed regular file: {path}")
    return path.read_bytes()


def verify_manifest(root: Path, expected_sha: str | None) -> set[str]:
    if expected_sha is None or FULL_SHA256.fullmatch(expected_sha) is None:
        raise VerificationError("manifest SHA must be a full lowercase SHA256")
    manifest = root / "SHA256SUMS"
    raw = read_bytes(manifest)
    actual = sha256_bytes(raw)
    if actual != expected_sha:
        raise VerificationError(
            f"manifest SHA mismatch: expected {expected_sha}, observed {actual}")
    sealed: set[str] = set()
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise VerificationError(f"malformed SHA256SUMS line {number}")
        digest, name = match.groups()
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or name in sealed:
            raise VerificationError(f"unsafe or duplicate manifest path: {name!r}")
        path = root / pure
        if sha256_bytes(read_bytes(path)) != digest:
            raise VerificationError(f"sealed file digest mismatch: {name}")
        sealed.add(name)
    if not sealed:
        raise VerificationError("empty SHA256SUMS")
    return sealed


def sealed_text(root: Path, sealed: set[str], name: str) -> str:
    if name not in sealed:
        raise KeyError(name)
    return read_bytes(root / name).decode("utf-8")


def git_blobs(root: Path | None, ref: str | None, label: str) -> dict[str, str] | None:
    if root is None and ref is None:
        return None
    if root is None or ref is None:
        raise VerificationError(f"{label} root and ref must be supplied together")
    if FULL_GIT_SHA.fullmatch(ref) is None:
        raise VerificationError(f"{label} ref must be a full lowercase git SHA")
    try:
        resolved = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--verify", f"{ref}^{{commit}}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise VerificationError(f"cannot resolve {label} ref {ref}") from exc
    if resolved != ref:
        raise VerificationError(f"{label} ref resolved to a different commit: {resolved}")
    blobs: dict[str, str] = {}
    for path in REQUIRED_PATHS:
        try:
            data = subprocess.run(
                ["git", "-C", str(root), "show", f"{ref}:{path}"],
                check=True, capture_output=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            raise VerificationError(f"{label} ref lacks required path: {path}") from exc
        blobs[path] = sha256_bytes(data)
    return blobs


def decide(
    observed: dict[str, int | None],
    predicates: dict[str, Callable[[int], bool]],
) -> str:
    for name, predicate in predicates.items():
        value = observed.get(name)
        if value is not None and not predicate(value):
            return "FAIL"
    if any(observed.get(name) is None for name in predicates):
        return "UNMEASURED"
    return "PASS"


def source_counts(
    root: Path | None, expected_manifest: str | None, expected_ref: str | None,
) -> tuple[dict[str, int | None], set[str] | None, str | None]:
    empty = {name: None for name in SOURCE_CASES}
    if root is None:
        return empty, None, None
    try:
        sealed = verify_manifest(root, expected_manifest)
        source_ref = sealed_text(root, sealed, "source-ref.txt").strip()
        if FULL_GIT_SHA.fullmatch(source_ref) is None:
            raise VerificationError("source-ref.txt is not a full git SHA")
        if expected_ref is not None and source_ref != expected_ref:
            raise VerificationError("source evidence ref differs from private ref")
        manifest_rc = sealed_text(root, sealed, "public-manifest.rc").strip()
        manifest_log = sealed_text(root, sealed, "public-manifest.log")
        if manifest_rc != "0" or "clean: every tracked path is classified" not in manifest_log:
            raise VerificationError("public manifest fixture did not pass")
        counts: dict[str, int | None] = {}
        for group, cases in SOURCE_CASES.items():
            passed = 0
            for case in cases:
                rc = sealed_text(root, sealed, f"{case}.rc").strip()
                log = sealed_text(root, sealed, f"{case}.log")
                if rc != "0" or "passed=1 failed=0" not in log:
                    raise VerificationError(f"source fixture did not pass: {case}")
                passed += 1
            counts[group] = passed
        return counts, sealed, source_ref
    except (KeyError, UnicodeDecodeError, VerificationError):
        return {name: 0 for name in SOURCE_CASES}, set(), None


def parse_state(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        for match in re.finditer(r"(?<!\S)([A-Za-z0-9_]+)=([^ ]+)", line):
            values[match.group(1)] = match.group(2)
    return values


def parse_utc(value: str) -> dt.datetime:
    if not value.endswith("Z"):
        raise ValueError("timestamp is not UTC-suffixed")
    parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    if parsed.tzinfo is None:
        raise ValueError("timestamp is naive")
    return parsed


def read_live(
    root: Path | None, expected_manifest: str | None,
) -> tuple[set[str] | None, bool | None]:
    if root is None:
        return None, None
    try:
        return verify_manifest(root, expected_manifest), True
    except VerificationError:
        return set(), False


def run1_layers(root: Path, sealed: set[str]) -> tuple[int | None, int | None]:
    try:
        record = sealed_text(root, sealed, "install-run.txt")
    except (KeyError, UnicodeDecodeError):
        return None, None
    run1 = next((m for line in record.splitlines() if (m := TX_LINE.search(line))
                 and m.group("run") == "1"), None)
    if run1 is None:
        return None, None
    log_ok = None
    for name in sealed:
        if not name.endswith(".log"):
            continue
        try:
            text = sealed_text(root, sealed, name)
        except UnicodeDecodeError:
            continue
        if (run1.group("unit") in text and run1.group("tx") in text
                and "rolled_back" in text):
            log_ok = 1
            break

    raw_b2 = None
    if "B2-binding-run1.tsv" in sealed:
        text = sealed_text(root, sealed, "B2-binding-run1.tsv")
        verdict = sealed_text(root, sealed, "verdict-binding.txt") \
            if "verdict-binding.txt" in sealed else ""
        match = re.search(r"install head: ([0-9a-f]{40})", verdict)
        raw_b2 = int(match is not None and f"#meta head_install={match.group(1)}" in text)
    return log_ok, raw_b2


def i3_live_layers(root: Path, sealed: set[str]) -> tuple[int | None, int | None, int | None]:
    try:
        first_text = sealed_text(root, sealed, "S2-taken-for-S3-timer").strip()
        health = sealed_text(root, sealed, "S2-health.txt")
        s2 = parse_state(sealed_text(root, sealed, "S2-state.txt"))
        s3 = parse_state(sealed_text(root, sealed, "S3-state.txt"))
    except (KeyError, UnicodeDecodeError):
        seconds = None
    else:
        if "overview_http=200" not in health:
            seconds = None
        else:
            try:
                first = parse_utc(first_text)
                s2_taken = parse_utc(s2["taken_utc"])
                last = parse_utc(s3["taken_utc"])
                seconds = int((last - first).total_seconds())
                if first < s2_taken:
                    seconds = -1
            except (KeyError, ValueError, TypeError):
                seconds = None

    loss = None
    required = ("verdict-i3-S0-S1.txt", "verdict-i3-S0-S3.txt")
    if all(name in sealed for name in required):
        loss = sum(
            "VERDICT=PASS" in sealed_text(root, sealed, name) for name in required
        )

    activation = None
    if "I3-activation-live.json" in sealed:
        try:
            data = json.loads(sealed_text(root, sealed, "I3-activation-live.json"))
            activation = int(
                data.get("activation_failed") is True
                and data.get("next_run_resumed") is True
                and data.get("smoke_passed") is True
                and data.get("activation_record_cleared") is True
            )
        except (json.JSONDecodeError, AttributeError):
            activation = 0
    return loss, seconds, activation


def i4_live_layer(root: Path, sealed: set[str]) -> int | None:
    if "I4-live.json" not in sealed:
        return None
    try:
        data = json.loads(sealed_text(root, sealed, "I4-live.json"))
        return int(
            data.get("matching_evidence_forwarded") is True
            and data.get("mismatch_mutations") == 0
            and data.get("mismatch_phase") == "degraded"
        )
    except (json.JSONDecodeError, AttributeError):
        return 0


def i5_live_layer(root: Path, sealed: set[str]) -> int | None:
    required = {
        "install-run.txt",
        *(f"{stage}-state.txt" for stage in ("S0", "S1", "S2", "S3")),
        *(f"{stage}-health.txt" for stage in ("S1", "S2", "S3")),
        *(f"{stage}-db.json" for stage in ("S1", "S2", "S3")),
        *(f"{stage}-airlock-status.json" for stage in ("S1", "S2", "S3")),
        *(f"{stage}-preserved.sha256" for stage in ("S0", "S1", "S2", "S3")),
        "S2-units.txt",
        "S3-units.txt",
    }
    if not required.issubset(sealed):
        return None
    try:
        run = sealed_text(root, sealed, "install-run.txt")
        run2_ok = any(
            (match := TX_LINE.search(line)) is not None
            and match.group("run") == "2"
            and match.group("exit") == "0"
            and match.group("phase") == "committed"
            and match.group("head") is not None
            for line in run.splitlines()
        )
        states = {
            stage: parse_state(sealed_text(root, sealed, f"{stage}-state.txt"))
            for stage in ("S0", "S1", "S2", "S3")
        }
        state_ok = all(
            states[stage].get("tx_phase") == "committed"
            and states[stage].get("activation_record") == "absent"
            and states[stage].get("migration_receipts") == "0"
            and states[stage].get("schema_state") == "canonical"
            and states[stage].get("snap_rc") == "0"
            for stage in ("S1", "S2", "S3")
        )
        boot_ok = (
            states["S1"].get("boot_id") != states["S2"].get("boot_id")
            and states["S2"].get("boot_id") == states["S3"].get("boot_id")
        )
        health_ok = all(
            "overview_http=200" in sealed_text(root, sealed, f"{stage}-health.txt")
            and "airlock_status_rc=0" in sealed_text(root, sealed, f"{stage}-health.txt")
            for stage in ("S1", "S2", "S3")
        )
        db_ok = all(
            json.loads(sealed_text(root, sealed, f"{stage}-db.json")).get("integrity") == "ok"
            for stage in ("S1", "S2", "S3")
        )
        status_ok = all(
            json.loads(sealed_text(root, sealed, f"{stage}-airlock-status.json")).get("verdict") == "ok"
            for stage in ("S1", "S2", "S3")
        )
        preserved = {
            sealed_text(root, sealed, f"{stage}-preserved.sha256")
            for stage in ("S0", "S1", "S2", "S3")
        }
        units2 = sealed_text(root, sealed, "S2-units.txt")
        units3 = sealed_text(root, sealed, "S3-units.txt")
        units_ok = (
            "ActiveState=active" in units2
            and "ActiveState=active" in units3
            and "NRestarts=0" in units2
            and "NRestarts=0" in units3
        )
        return int(all((run2_ok, state_ok, boot_ok, health_ok, db_ok,
                        status_ok, len(preserved) == 1, units_ok)))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        return 0


def binding_revision(root: Path, sealed: set[str]) -> str | None:
    """Return the install ref only when both sealed binding reports agree."""
    try:
        table = sealed_text(root, sealed, "B2-binding.tsv")
        verdict = sealed_text(root, sealed, "verdict-binding-r2.txt")
    except (KeyError, UnicodeDecodeError):
        return None
    table_refs = [
        match.group(1) for line in table.splitlines()
        if (match := re.fullmatch(r"#meta head_install=([0-9a-f]{40})", line))
    ]
    verdict_refs = re.findall(
        r"\binstall head: ([0-9a-f]{40})(?=\s|\Z)", verdict)
    if (len(table_refs) != 1 or len(verdict_refs) != 1
            or table_refs[0] != verdict_refs[0]
            or "VERDICT=PASS" not in verdict.splitlines()):
        return None
    return table_refs[0]


def live_revision(root: Path | None, sealed: set[str] | None) -> str | None:
    if root is None or sealed is None:
        return None
    revisions: list[str] = []
    for name in ("S1-airlock-status.json", "S2-airlock-status.json", "S3-airlock-status.json"):
        if name not in sealed:
            continue
        try:
            data = json.loads(sealed_text(root, sealed, name))
            found = [
                check.get("detail") for check in data.get("checks", [])
                if check.get("id") == "install.revision"
            ]
            if (len(found) != 1 or not isinstance(found[0], str)
                    or FULL_GIT_SHA.fullmatch(found[0]) is None):
                return None
            revisions.append(found[0])
        except (json.JSONDecodeError, AttributeError, UnicodeDecodeError):
            return None
    return revisions[0] if revisions and len(set(revisions)) == 1 else None


def evidence_label(path: Path | None, revision: str | None) -> str:
    safe_path = str(path or "none").replace(" ", "%20")
    return f"{safe_path}@{revision or 'UNMEASURED'}"


def evaluate(inputs: Inputs) -> Evaluation:
    layers: list[str] = []
    tree_error = False
    try:
        private = git_blobs(inputs.private_root, inputs.private_ref, "private")
        public = git_blobs(inputs.public_root, inputs.public_ref, "public")
        installed = git_blobs(inputs.installed_root, inputs.installed_ref, "installed")
    except VerificationError as exc:
        private = public = installed = None
        tree_error = True
        layers.append(f"LAYER AC-AST-I1 refs=FAIL reason={str(exc).replace(' ', '_')}")

    source, _source_sealed, source_ref = source_counts(
        inputs.source_evidence, inputs.source_manifest_sha, inputs.private_ref)
    live_sealed, live_manifest_ok = read_live(
        inputs.live_evidence, inputs.live_manifest_sha)
    measured_live_ref = live_revision(inputs.live_evidence, live_sealed)

    private_ok = 0 if tree_error else (1 if private is not None else None)
    public_ok = 0 if tree_error else (1 if public is not None else None)
    installed_ok = 0 if tree_error else (1 if installed is not None else None)
    projection_match = None
    installed_match = None
    if private is not None and public is not None:
        projection_match = int(private == public)
    if private is not None and installed is not None:
        installed_match = int(private == installed)
    binding = None
    if live_manifest_ok is False:
        binding = 0
    elif live_sealed is not None and installed is not None:
        report_ref = binding_revision(inputs.live_evidence, live_sealed)
        binding = int(
            report_ref is not None
            and measured_live_ref is not None
            and report_ref == inputs.installed_ref == measured_live_ref
        )
    i1_observed = {
        "private_ref": private_ok,
        "public_ref": public_ok,
        "installed_ref": installed_ok,
        "projection_blobs": projection_match,
        "installed_blobs": installed_match,
        "sealed_binding": binding,
    }
    i1_verdict = decide(i1_observed, {name: lambda value: value == 1 for name in i1_observed})
    layers.append(
        "LAYER AC-AST-I1 "
        f"private={'PASS' if private_ok == 1 else ('FAIL' if private_ok == 0 else 'UNMEASURED')} "
        f"public_projection={'PASS' if projection_match == 1 else ('FAIL' if projection_match == 0 else 'UNMEASURED')} "
        f"installed={'PASS' if installed_match == 1 else ('FAIL' if installed_match == 0 else 'UNMEASURED')} "
        f"live_binding={'PASS' if binding == 1 else ('FAIL' if binding == 0 else 'UNMEASURED')}"
    )

    run1_log = raw_b2 = None
    loss = seconds = activation_live = i4_live = i5 = None
    if live_manifest_ok is False:
        run1_log = raw_b2 = loss = seconds = activation_live = i4_live = i5 = 0
    elif live_sealed is not None and inputs.live_evidence is not None:
        run1_log, raw_b2 = run1_layers(inputs.live_evidence, live_sealed)
        loss, seconds, activation_live = i3_live_layers(inputs.live_evidence, live_sealed)
        i4_live = i4_live_layer(inputs.live_evidence, live_sealed)
        i5 = i5_live_layer(inputs.live_evidence, live_sealed)

    i2_observed = {
        "source_cases": source["i2"], "live_run1_log": run1_log,
        "live_run1_binding": raw_b2,
    }
    i2_verdict = decide(i2_observed, {
        "source_cases": lambda value: value >= 2,
        "live_run1_log": lambda value: value == 1,
        "live_run1_binding": lambda value: value == 1,
    })
    layers.append(
        "LAYER AC-AST-I2 "
        f"source={'PASS' if source['i2'] == 2 else ('FAIL' if source['i2'] == 0 else 'UNMEASURED')} "
        f"live={'PASS' if run1_log == raw_b2 == 1 else ('FAIL' if 0 in (run1_log, raw_b2) else 'UNMEASURED')}"
    )

    i3_observed = {
        "source_activation_cases": source["i3"],
        "live_loss_windows": loss,
        "first200_to_s3_seconds": seconds,
        "live_activation_resume": activation_live,
    }
    i3_verdict = decide(i3_observed, {
        "source_activation_cases": lambda value: value >= 3,
        "live_loss_windows": lambda value: value >= 2,
        "first200_to_s3_seconds": lambda value: value >= 600,
        "live_activation_resume": lambda value: value == 1,
    })
    time_layer = (
        "UNMEASURED" if seconds is None else "PASS" if seconds >= 600 else "FAIL"
    )
    layers.append(
        "LAYER AC-AST-I3 "
        f"source_activation={'PASS' if source['i3'] == 3 else ('FAIL' if source['i3'] == 0 else 'UNMEASURED')} "
        f"live_loss={'PASS' if loss == 2 else ('UNMEASURED' if loss is None else 'FAIL')} "
        f"live_time={time_layer} live_activation={'PASS' if activation_live == 1 else ('FAIL' if activation_live == 0 else 'UNMEASURED')}"
    )

    i4_observed = {"source_cases": source["i4"], "live_degraded": i4_live}
    i4_verdict = decide(i4_observed, {
        "source_cases": lambda value: value >= 5,
        "live_degraded": lambda value: value == 1,
    })
    layers.append(
        "LAYER AC-AST-I4 "
        f"source={'PASS' if source['i4'] == 5 else ('FAIL' if source['i4'] == 0 else 'UNMEASURED')} "
        f"live={'PASS' if i4_live == 1 else ('FAIL' if i4_live == 0 else 'UNMEASURED')}"
    )

    i5_observed = {"canonical_live_replay": i5}
    i5_verdict = decide(i5_observed, {
        "canonical_live_replay": lambda value: value == 1,
    })
    layers.append(
        "LAYER AC-AST-I5 canonical_live="
        f"{'PASS' if i5 == 1 else ('FAIL' if i5 == 0 else 'UNMEASURED')} "
        "scope=canonical_non_activation_only"
    )

    revision = inputs.private_ref or source_ref
    source_label = evidence_label(inputs.source_evidence, revision)
    live_label_ref = measured_live_ref if inputs.live_evidence is not None \
        else inputs.installed_ref or revision
    live_label = evidence_label(inputs.live_evidence, live_label_ref)
    results = [
        Result("AC-AST-I1",
               "private_ref == 1 && public_ref == 1 && installed_ref == 1 && projection_blobs == 1 && installed_blobs == 1 && sealed_binding == 1",
               i1_observed, i1_verdict, "projection", live_label),
        Result("AC-AST-I2",
               "source_cases >= 2 && live_run1_log == 1 && live_run1_binding == 1",
               i2_observed, i2_verdict, "fixture", source_label),
        Result("AC-AST-I3",
               "source_activation_cases >= 3 && live_loss_windows >= 2 && first200_to_s3_seconds >= 600 && live_activation_resume == 1",
               i3_observed, i3_verdict, "replay", live_label),
        Result("AC-AST-I4",
               "source_cases >= 5 && live_degraded == 1",
               i4_observed, i4_verdict, "fixture", source_label),
        Result("AC-AST-I5",
               "canonical_live_replay == 1",
               i5_observed, i5_verdict, "replay", live_label),
    ]
    return Evaluation(results=results, layers=layers)


def paired(parser: argparse.ArgumentParser, args: argparse.Namespace, left: str, right: str) -> None:
    if (getattr(args, left) is None) != (getattr(args, right) is None):
        parser.error(f"--{left.replace('_', '-')} and --{right.replace('_', '-')} must be supplied together")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", type=Path)
    parser.add_argument("--private-ref")
    parser.add_argument("--public-root", type=Path)
    parser.add_argument("--public-ref")
    parser.add_argument("--installed-root", type=Path)
    parser.add_argument("--installed-ref")
    parser.add_argument("--source-evidence", type=Path)
    parser.add_argument("--source-manifest-sha")
    parser.add_argument("--live-evidence", type=Path)
    parser.add_argument("--live-manifest-sha")
    args = parser.parse_args(argv)
    for pair in (("private_root", "private_ref"), ("public_root", "public_ref"),
                 ("installed_root", "installed_ref"),
                 ("source_evidence", "source_manifest_sha"),
                 ("live_evidence", "live_manifest_sha")):
        paired(parser, args, *pair)
    evaluation = evaluate(Inputs(**vars(args)))
    print("\n".join((*evaluation.layers, *(result.row() for result in evaluation.results))))
    return evaluation.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
