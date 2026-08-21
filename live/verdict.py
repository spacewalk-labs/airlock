#!/usr/bin/env python3
"""Extract the live-run verdict from a durable result record."""

import json
import re
import sys


# The acceptance document certifies 25 checks. Raise this when checks are added;
# lowering it is a deliberate act, not a fix for a failing acceptance stage.
MIN_ACCEPTANCE_PASSED = 25
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}\Z")


def is_down(unit):
    if not isinstance(unit, dict):
        return True
    if unit.get("active") == "active":
        return False
    # A oneshot that ran successfully is inactive/dead by design.
    if (unit.get("type") == "oneshot" and unit.get("sub") == "dead"
            and (unit.get("exec_status") or "0") == "0"):
        return False
    return True


def load_record(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def verdict(record):
    if not isinstance(record, dict):
        return 1, "verdict 1: result record is not an object"
    inner = record.get("inner")
    if not isinstance(inner, dict):
        return 1, "verdict 1: inner record is not an object"
    if "error" in inner:
        return 1, f"verdict 1: inner record error: {inner['error']!r}"

    commit = record.get("commit")
    inner_commit = inner.get("commit")
    if not isinstance(commit, str) or FULL_SHA_RE.fullmatch(commit) is None:
        return 1, f"verdict 1: commit must be a full lowercase SHA, got {commit!r}"
    if inner_commit != commit:
        return 1, ("verdict 1: inner.commit must equal result commit "
                   f"{commit}, got {inner_commit!r}")

    requested = record.get("dev_monitor_messages_requested")
    if not isinstance(requested, bool):
        return 1, "verdict 1: dev_monitor_messages_requested must be a boolean"
    if inner.get("dev_monitor_messages_requested") is not requested:
        return 1, "verdict 1: outer and inner dev-monitor message requests disagree"

    if requested:
        gate = inner.get("devmon_no_webhook")
        if not isinstance(gate, dict) or gate.get("rc") != 0:
            return 1, "verdict 1: messages-on/no-webhook collector failed or is missing"
        observation = gate.get("observation")
        expected_states = {
            "slack-urgent": "off: no webhook configured",
            "slack-routine": "off: no webhook configured",
        }
        expected_zero = {
            "watchdog_cards": 0,
            "watchdog_events": 0,
            "watchdog_notice_deliveries": 0,
        }
        expected_delta = {key: 1 for key in expected_zero}
        if not isinstance(observation, dict):
            return 1, "verdict 1: messages-on/no-webhook observation is missing"
        if observation.get("messages_effective") != "on":
            return 1, "verdict 1: requested messages were not effectively on"
        if observation.get("worker_states") != expected_states:
            return 1, "verdict 1: no-webhook worker states were not named as intentionally off"
        requested_seconds = observation.get("observation_requested_seconds")
        elapsed_milliseconds = observation.get("observation_elapsed_milliseconds")
        measured_seconds = observation.get("observation_seconds")
        if (not isinstance(requested_seconds, int) or isinstance(requested_seconds, bool)
                or requested_seconds < 120
                or not isinstance(elapsed_milliseconds, int)
                or isinstance(elapsed_milliseconds, bool)
                or elapsed_milliseconds < requested_seconds * 1000
                or not isinstance(measured_seconds, int)
                or isinstance(measured_seconds, bool)
                or measured_seconds != elapsed_milliseconds // 1000):
            return 1, "verdict 1: messages-on/no-webhook observation was shorter than 120 seconds"
        # Running-service telemetry. The pre-aged off-branch delta below is the
        # discriminator for fall-through whose natural threshold is 1,800 seconds.
        zero = observation.get("zero_snapshot")
        if (not isinstance(zero, dict)
                or any(not isinstance(zero.get(key), int)
                       or isinstance(zero.get(key), bool) for key in expected_zero)
                or zero != expected_zero):
            return 1, "verdict 1: no-webhook watchdog created an incident"
        off_branch = observation.get("off_branch_control") or {}
        off_delta = off_branch.get("delta")
        if (not isinstance(off_delta, dict)
                or any(not isinstance(off_delta.get(key), int)
                       or isinstance(off_delta.get(key), bool) for key in expected_zero)
                or off_delta != expected_zero):
            return 1, "verdict 1: intentionally-off lane fell through to ledger watchdog"
        positive = observation.get("positive_control") or {}
        delta = positive.get("delta")
        if (positive.get("reason_state") != "stalled" or not isinstance(delta, dict)
                or any(not isinstance(delta.get(key), int)
                       or isinstance(delta.get(key), bool) for key in expected_delta)
                or delta != expected_delta):
            return 1, "verdict 1: watchdog positive control did not activate the measured path"

    acceptance = inner.get("acceptance")
    if not isinstance(acceptance, dict):
        return 1, "verdict 1: acceptance stage is missing"

    numeric_fields = (
        ("inner_rc", record.get("inner_rc")),
        ("install_rc", inner.get("install_rc")),
        ("smoke_rc", inner.get("smoke_rc")),
        ("acceptance.rc", acceptance.get("rc")),
        ("acceptance.passed", acceptance.get("passed")),
        ("acceptance.failed", acceptance.get("failed")),
    )
    for name, value in numeric_fields:
        if not (isinstance(value, int) and not isinstance(value, bool)):
            return 1, f"verdict 1: {name} must be an integer, got {value!r}"

    units = inner.get("units_late") or []
    if not isinstance(units, list):
        units = []
    down = sum(1 for unit in units if is_down(unit))
    failures = []
    if record["inner_rc"] != 0:
        failures.append(f"inner_rc={record['inner_rc']}")
    if inner["install_rc"] != 0:
        failures.append(f"install_rc={inner['install_rc']}")
    if down:
        failures.append(f"{down} unit(s) down")
    if not units:
        failures.append("no late unit facts")

    if failures:
        return 1, "verdict 1: " + "; ".join(failures)

    external_packages = inner.get("external_packages")
    if not isinstance(external_packages, list) or not external_packages:
        return 1, "verdict 1: external_packages must be a non-empty list"

    smoke_lines = inner.get("smoke_lines")
    if not isinstance(smoke_lines, list):
        smoke_lines = []
    has_external_gate = any(
        isinstance(package_id, str)
        and any(
            isinstance(line, str) and line.startswith(f"[{package_id} smoke]")
            for line in smoke_lines
        )
        for package_id in external_packages
    )
    if not has_external_gate:
        return 1, "verdict 1: no external package smoke gate line was found"

    if acceptance["failed"] != 0:
        return 1, f"verdict 1: acceptance reported {acceptance['failed']} failed"
    if acceptance["rc"] != 0:
        return 1, f"verdict 1: acceptance exited {acceptance['rc']}"
    if acceptance["passed"] < MIN_ACCEPTANCE_PASSED:
        return 1, f"verdict 1: acceptance reported only {acceptance['passed']} checks"

    smoke_rc = inner["smoke_rc"]
    if smoke_rc == 0:
        return 0, "verdict 0: install, units, external package, and acceptance passed"
    if smoke_rc == 3:
        return 3, "verdict 3: gates passed but ingress was unverified"
    return 1, f"verdict 1: smoke exited {smoke_rc}"


def main():
    result = load_record(sys.argv[1])
    value, reason = verdict(result)
    print(value)
    print(reason, file=sys.stderr)


if __name__ == "__main__":
    main()
