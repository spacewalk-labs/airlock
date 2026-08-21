#!/usr/bin/env python3
"""Render a tracked, allowlisted live result directly from the runner record."""

import json
import re
import sys

from verdict import is_down, verdict


def main() -> None:
    source_path, output_path = sys.argv[1:3]
    with open(source_path, encoding="utf-8") as source:
        record = json.load(source)
    inner = record.get("inner") or {}
    observation = (inner.get("devmon_no_webhook") or {}).get("observation") or {}
    units = inner.get("units_late") or []
    acceptance = inner.get("acceptance") or {}
    requested = observation.get("observation_requested_seconds", inner.get("soak_seconds"))
    messages_requested = record.get("dev_monitor_messages_requested") is True

    def counters(value):
        value = value if isinstance(value, dict) else {}
        return {
            "watchdog_cards": value.get("watchdog_cards"),
            "watchdog_events": value.get("watchdog_events"),
            "watchdog_notice_deliveries": value.get("watchdog_notice_deliveries"),
        }

    worker_states = observation.get("worker_states") or {}
    off_branch = observation.get("off_branch_control") or {}
    positive = observation.get("positive_control") or {}
    image_fingerprint = record.get("image_fingerprint")
    commit = record.get("commit")
    reproducible_image = (
        image_fingerprint if isinstance(image_fingerprint, str)
        and re.fullmatch(r"[0-9a-f]{64}", image_fingerprint) else None)
    reproducible_commit = (
        commit if isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit)
        else None)
    if reproducible_image is None or reproducible_commit is None:
        reproduction = (
            "unavailable: result lacks a full immutable image fingerprint or commit")
    else:
        reproduction = (
            "set -a; . ~/.config/airlock-live/env; set +a; "
            "test \"$(git rev-parse HEAD)\" = %s && "
            "ssh -o BatchMode=yes \"$AIRLOCK_LIVE_SSH\" "
            "\"lxc image info %s >/dev/null\" && "
            "AIRLOCK_LIVE_IMAGE=%s AIRLOCK_LIVE_DEVMON_MESSAGES=%s "
            "AIRLOCK_LIVE_SOAK=%s AIRLOCK_LIVE_EVIDENCE_DIR="
            "docs/tasks/active/dev-monitor-lanes.logs bash live/verify.sh"
            % (reproducible_commit, reproducible_image, reproducible_image,
               str(messages_requested).lower(), requested)
        )

    public = {
        "schema": 2,
        "run_id": record.get("run_id"),
        "commit": commit,
        "started_utc": record.get("started_utc"),
        "ended_utc": record.get("ended_utc"),
        "image_fingerprint": image_fingerprint,
        "reproduction_scope": (
            "host-local: requires operator-supplied, untracked "
            "~/.config/airlock-live/env, a checkout at the recorded commit, and the exact "
            "image fingerprint already cached on AIRLOCK_LIVE_SSH; reproduction "
            "preflights both immutable inputs and fails otherwise"
        ),
        "reproduction": reproduction,
        "result": {
            "inner_rc": record.get("inner_rc"),
            "install_rc": inner.get("install_rc"),
            "smoke_rc": inner.get("smoke_rc"),
            "unit_count": len(units),
            "units_down": sum(1 for unit in units if is_down(unit)),
            "units_with_restarts": sum(
                1 for unit in units
                if (unit.get("restarts") or "0") not in ("0", "")),
            "acceptance": {
                "rc": acceptance.get("rc"),
                "passed": acceptance.get("passed"),
                "failed": acceptance.get("failed"),
            },
            "verdict": verdict(record)[0],
            "verdict_provenance": (
                "recomputed from the full local runner record; inputs required to "
                "derive it are intentionally absent from this redacted projection"
            ),
            "cleanup_ok": record.get("cleanup_ok"),
        },
        "dev_monitor_no_webhook": {
            "messages_requested": messages_requested,
            "messages_effective": observation.get("messages_effective"),
            "observation_requested_seconds": observation.get(
                "observation_requested_seconds"),
            "observation_elapsed_milliseconds": observation.get(
                "observation_elapsed_milliseconds"),
            "observation_seconds": observation.get("observation_seconds"),
            "worker_states": {
                "slack-urgent": worker_states.get("slack-urgent"),
                "slack-routine": worker_states.get("slack-routine"),
            },
            "zero_snapshot": counters(observation.get("zero_snapshot")),
            "off_branch_control": {
                "delta": counters(off_branch.get("delta")),
            },
            "positive_control": {
                "reason_state": positive.get("reason_state"),
                "delta": counters(positive.get("delta")),
            },
        },
        "redaction": {
            "excluded": [
                "execution host",
                "container network identity",
                "owner identity",
                "free-form logs",
                "credential and webhook values",
            ]
        },
    }
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump(public, output, indent=2, sort_keys=True)
        output.write("\n")


if __name__ == "__main__":
    main()
