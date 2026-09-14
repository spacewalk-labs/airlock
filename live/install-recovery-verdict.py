#!/usr/bin/env python3
"""Fail-closed verdict for a disposable installer recovery result."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


FULL_SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
SCENARIOS = {"r1", "r2", "r3-forward", "r3-refuse"}
SEED_IDS = ["recovery-seed-action", "recovery-seed-info"]
CRON_ID = re.compile(r"cron:[0-9a-f]{24}:(?:fail|ok):[A-Za-z0-9_.:-]+\Z")
ACTIVE_UNIT_STATES = {"active"}
INACTIVE_UNIT_STATES = {"inactive", "failed"}


class BadResult(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BadResult(message)


def integer(value: Any, name: str) -> int:
    require(isinstance(value, int) and not isinstance(value, bool), f"{name} must be an integer")
    return value


def mapping(value: Any, name: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{name} must be an object")
    return value


def require_unit_state(value: dict[str, Any], name: str, allowed: set[str]) -> None:
    observation = mapping(value.get("unit_observation"), f"{name}.unit_observation")
    require(set(observation) == {"show_rc", "output"},
            f"{name}.unit_observation has an unexpected shape")
    require(integer(observation.get("show_rc"),
                    f"{name}.unit_observation.show_rc") == 0,
            f"{name} systemctl show failed")
    output = observation.get("output")
    require(isinstance(output, str), f"{name}.unit_observation.output must be a string")
    unit: dict[str, str] = {}
    expected = {"ActiveState", "SubState"}
    for line in output.splitlines():
        key, separator, state = line.partition("=")
        require(separator == "=" and key in expected and key not in unit and state,
                f"{name} unit output is incomplete or malformed")
        unit[key] = state
    require(set(unit) == expected, f"{name} unit output is incomplete or malformed")
    require(unit["ActiveState"] != "unknown" and unit["SubState"] != "unknown",
            f"{name} unit output contains an unknown state")
    require(unit["ActiveState"] in allowed,
            f"{name} ActiveState={unit['ActiveState']!r} is outside the allowed states")


def snapshot(facts: dict[str, Any], name: str, schema: str) -> dict[str, Any]:
    value = mapping(facts.get(name), name)
    require(value.get("schema") == schema, f"{name}.schema must be {schema}")
    require(value.get("integrity") == "ok", f"{name}.integrity must be ok")
    ids = value.get("ids")
    require(isinstance(ids, list) and all(isinstance(item, str) for item in ids),
            f"{name}.ids must be a string list")
    for seed in SEED_IDS:
        require(seed in ids, f"{name} lost seed id {seed}")
    for field in ("raw_sha256", "online_backup_sha256"):
        require(isinstance(value.get(field), str) and DIGEST.fullmatch(value[field]),
                f"{name}.{field} must be a sha256")
    return value


def require_protected(snapshot_value: dict[str, Any], name: str) -> None:
    protected = mapping(snapshot_value.get("protected"), f"{name}.protected")
    expected = {
        "dev-monitor/messages.db.pre-endstate",
        "dev-monitor/messages.db.pre-endstate.manifest.json",
        "dev-monitor/messages.db.pre-endstate.target.json",
    }
    require(set(protected) == expected, f"{name} retained-evidence set is incomplete")
    for path, digest in protected.items():
        require(isinstance(digest, str) and DIGEST.fullmatch(digest),
                f"{name}.protected[{path!r}] must be a sha256")


def common(record: dict[str, Any], bundle: Path | None) -> tuple[str, dict[str, Any]]:
    require(record.get("schema") == 1, "outer schema must be 1")
    commit = record.get("commit")
    require(isinstance(commit, str) and FULL_SHA.fullmatch(commit), "outer commit must be a full SHA")
    integer(record.get("inner_rc"), "inner_rc")
    require(record["inner_rc"] == 0, f"inner_rc={record['inner_rc']}")
    inner = mapping(record.get("inner"), "inner")
    require(inner.get("schema") == 1, "inner schema must be 1")
    scenario = inner.get("scenario")
    require(scenario in SCENARIOS, f"unsupported scenario {scenario!r}")
    require(inner.get("candidate_commit") == commit, "inner candidate does not match outer commit")
    producer = inner.get("producer_commit")
    require(isinstance(producer, str) and FULL_SHA.fullmatch(producer),
            "producer_commit must be a full SHA")
    timezone = mapping(inner.get("timezone"), "timezone")
    require(set(timezone) == {"name", "offset", "metadata", "localtime"},
            "guest timezone evidence has an unexpected shape")
    require(timezone["name"] == "Asia/Seoul", "guest timezone name did not pass")
    require(timezone["offset"] == "+0900", "guest timezone offset did not pass")
    require(timezone["metadata"] in {"Asia/Seoul", "ABSENT"},
            "guest timezone metadata did not pass")
    require(timezone["localtime"] == "/usr/share/zoneinfo/Asia/Seoul",
            "guest timezone localtime target did not pass")
    evidence_sha = inner.get("evidence_sha256")
    require(isinstance(evidence_sha, str) and DIGEST.fullmatch(evidence_sha),
            "evidence_sha256 must be a sha256")
    require(inner.get("evidence_mode") == "0600", "evidence bundle was not mode 0600")
    steps = inner.get("steps")
    require(isinstance(steps, list) and steps, "steps must be a non-empty list")
    for index, step in enumerate(steps):
        value = mapping(step, f"steps[{index}]")
        require(set(value) == {"name", "rc"}, f"steps[{index}] has an unexpected shape")
        require(isinstance(value["name"], str) and value["name"], f"steps[{index}].name missing")
        integer(value["rc"], f"steps[{index}].rc")
    if bundle is not None:
        require(bundle.is_file() and not bundle.is_symlink(), "evidence bundle is missing or unsafe")
        actual = hashlib.sha256(bundle.read_bytes()).hexdigest()
        require(actual == evidence_sha, "evidence bundle hash does not match inner result")
    return scenario, inner


def verdict_r1(inner: dict[str, Any]) -> None:
    facts = mapping(inner.get("facts"), "facts")
    before = snapshot(facts, "before", "legacy")
    after = snapshot(facts, "after", "legacy")
    require(integer(facts.get("install_rc"), "install_rc") == 86, "R1 must fail at rc 86")
    require(before["raw_sha256"] == after["raw_sha256"], "R1 changed legacy DB bytes")
    require(before["online_backup_sha256"] == after["online_backup_sha256"],
            "R1 changed the online-backup witness")
    require(facts.get("tx_phase") == "rolled_back", "R1 transaction did not roll back")
    require(facts.get("restore_status") == "restored", "R1 did not restore dev-monitor")
    require(integer(facts.get("activation_records"), "activation_records") == 0,
            "R1 left an activation record")
    require(integer(facts.get("migration_receipts"), "migration_receipts") == 0,
            "R1 left an old migration receipt")
    require(integer(facts.get("pre_endstate_files"), "pre_endstate_files") == 0,
            "R1 converted the legacy database")
    require_unit_state(after, "R1 restored unit", ACTIVE_UNIT_STATES)
    require(facts.get("unit_fragment_path") == "/opt/airlock-baseline",
            "R1 unit does not point at the baseline package")
    require(integer(facts.get("overview_http"), "overview_http") == 200,
            "R1 restored backend is not healthy")
    require(facts.get("spool_modes") == {"new": "3770", "tmp": "3770"},
            "R1 spool modes are not canonical")
    require(facts.get("late_marker") is True and facts.get("smoke_reached") is False,
            "R1 did not stop at the exact late-package boundary")


def require_seeded_window(before: dict[str, Any], after: dict[str, Any], name: str) -> None:
    """Keep the seeded observation intact while allowing normal cron transitions."""
    before_ids = set(before["ids"])
    after_ids = set(after["ids"])
    require(set(SEED_IDS).issubset(before_ids) and set(SEED_IDS).issubset(after_ids),
            f"{name} lost seeded message ids")
    additions = after_ids - before_ids
    require(all(CRON_ID.fullmatch(item) is not None for item in additions),
            f"{name} added a non-cron message id")


def verdict_r2(inner: dict[str, Any]) -> None:
    facts = mapping(inner.get("facts"), "facts")
    first = snapshot(facts, "after_fault", "canonical")
    resumed = snapshot(facts, "after_resume", "canonical")
    require_protected(first, "after_fault")
    require_protected(resumed, "after_resume")
    require(integer(facts.get("first_rc"), "first_rc") == 1,
            "R2 installer must map the injected start failure to rc 1")
    require(integer(facts.get("resume_rc"), "resume_rc") == 0, "R2 resume did not succeed")
    require(facts.get("first_tx_phase") == "committed", "R2 fault was not post-commit")
    require(facts.get("final_tx_phase") == "committed", "R2 final transaction is not committed")
    require(facts.get("first_activation") is True and facts.get("final_activation") is False,
            "R2 activation debt did not persist then clear")
    require(facts.get("shim") == {
        "argv": "--user start airlock-dev-monitor.service",
        "count": 1,
        "scenario": "r2",
    }, "R2 shim did not prove the exact one-shot boundary")
    require_unit_state(first, "R2 unit after fault", INACTIVE_UNIT_STATES)
    require_unit_state(resumed, "R2 unit after resume", ACTIVE_UNIT_STATES)
    require(integer(facts.get("health_http"), "health_http") == 200
            and integer(facts.get("overview_http"), "overview_http") == 200,
            "R2 resumed backend is not healthy")
    require_seeded_window(first, resumed, "R2 resume")
    require(facts.get("protected_hashes_equal") is True, "R2 changed retained backup evidence")
    require(facts.get("spool_modes") == {"new": "3770", "tmp": "3770"},
            "R2 spool modes are not canonical")


def verdict_r3_forward(inner: dict[str, Any]) -> None:
    facts = mapping(inner.get("facts"), "facts")
    degraded = snapshot(facts, "degraded", "canonical")
    recovered = snapshot(facts, "recovered", "canonical")
    final = snapshot(facts, "final", "canonical")
    require_protected(degraded, "degraded")
    require_protected(recovered, "recovered")
    require(integer(facts.get("producer_rc"), "producer_rc") == 86,
            "R3 producer did not stop at the late package")
    require(facts.get("producer_phase") == "degraded"
            and integer(facts.get("producer_receipts"), "producer_receipts") == 1,
            "R3 producer did not create a real degraded receipt state")
    heartbeat = facts.get("heartbeat_id")
    require(isinstance(heartbeat, str) and heartbeat.startswith("heartbeat:"),
            "R3 production heartbeat witness is missing")
    require(heartbeat in degraded["ids"], "R3 running consumer did not persist the heartbeat")
    require(isinstance(facts.get("forward_check"), str)
            and facts["forward_check"].startswith("forward=1 "),
            "R3 producer state is not forward-classifiable")
    require(integer(facts.get("observe_stop_rc"), "observe_stop_rc") == 2,
            "R3 observation stop did not occur after recovery")
    require(facts.get("recovered_phase") == "rolled_back", "R3 old transaction did not recover")
    require(facts.get("forward_keep_app") == "dev-monitor", "R3 forward decision is missing")
    require(facts.get("restore_status") in {"kept-forward-active", "kept-forward-inactive"},
            "R3 dev-monitor was not kept forward")
    if facts.get("restore_status") == "kept-forward-active":
        require_unit_state(recovered, "R3 recovered unit", ACTIVE_UNIT_STATES)
    else:
        require_unit_state(recovered, "R3 recovered unit", INACTIVE_UNIT_STATES)
    require(integer(facts.get("recovered_receipts"), "recovered_receipts") == 0,
            "R3 recovery did not consume its receipt")
    require(degraded["ids"] == recovered["ids"], "R3 recovery lost message ids")
    require(facts.get("protected_hashes_equal") is True,
            "R3 forward recovery changed retained evidence")
    require(integer(facts.get("final_rc"), "final_rc") == 0
            and facts.get("final_phase") == "committed",
            "R3 final current install did not commit")
    require_unit_state(final, "R3 final unit", ACTIVE_UNIT_STATES)
    require(integer(facts.get("overview_http"), "overview_http") == 200,
            "R3 final current backend is not healthy")
    require_seeded_window(recovered, final, "R3 final install")


def verdict_r3_refuse(inner: dict[str, Any]) -> None:
    facts = mapping(inner.get("facts"), "facts")
    before = snapshot(facts, "before_refusal", "canonical")
    after = snapshot(facts, "after_refusal", "canonical")
    require_protected(before, "before_refusal")
    require_protected(after, "after_refusal")
    require(integer(facts.get("producer_rc"), "producer_rc") == 86,
            "R3 refusal producer did not stop at rc 86")
    require(facts.get("producer_phase") == "degraded", "R3 refusal did not start degraded")
    require(facts.get("sentinel_added") is True, "R3 refusal changed no intent input")
    require(integer(facts.get("recovery_rc"), "recovery_rc") != 0,
            "R3 refusal recovery unexpectedly succeeded")
    require(facts.get("final_phase") == "degraded", "R3 refusal did not remain degraded")
    require(facts.get("forward_keep_present") is False, "R3 refusal minted forward_keep")
    require(integer(facts.get("migration_receipts"), "migration_receipts") == 1,
            "R3 refusal removed its receipt")
    require(before["raw_sha256"] == after["raw_sha256"]
            and before["online_backup_sha256"] == after["online_backup_sha256"],
            "R3 refusal changed database bytes")
    require(before["ids"] == after["ids"], "R3 refusal changed message ids")
    require(facts.get("protected_hashes_equal") is True,
            "R3 refusal changed receipt/backup/marker evidence")
    require(facts.get("candidate_tree_mismatch_logged") is True,
            "R3 refusal did not name the candidate-tree mismatch")
    require_unit_state(after, "R3 refused unit", INACTIVE_UNIT_STATES)


def calculate(record: dict[str, Any], bundle: Path | None = None) -> tuple[int, str]:
    try:
        scenario, inner = common(record, bundle)
        if scenario == "r1":
            verdict_r1(inner)
        elif scenario == "r2":
            verdict_r2(inner)
        elif scenario == "r3-forward":
            verdict_r3_forward(inner)
        else:
            verdict_r3_refuse(inner)
    except BadResult as exc:
        return 1, f"recovery verdict 1: {exc}"
    return 0, f"recovery verdict 0: {scenario} passed its disposable boundary"


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"usage: {sys.argv[0]} RESULT.json [EVIDENCE.tar]", file=sys.stderr)
        return 2
    try:
        record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"recovery verdict 1: cannot read result: {exc}", file=sys.stderr)
        print(1)
        return 0
    value, reason = calculate(record, Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    print(value)
    print(reason, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
