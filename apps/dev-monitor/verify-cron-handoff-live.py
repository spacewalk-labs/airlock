#!/usr/bin/env python3
"""Evidence gate for the Cron-card replacement handoff.

This tool observes only.  It never starts a job, changes a database, disables the old
producer, or posts to Slack.  ``before`` must pass before the companion retirement
change is applied; ``after`` consumes that receipt and proves the replacement continued.
Run it from the installed Airlock checkout: the sibling ``bin/airlock-status`` report is
the authority for the completed transaction, config/ledger agreement, and exact revision.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_TIMEOUT = 16 * 60
POLL_SECONDS = 30
ROOT = Path(__file__).resolve().parents[2]
SHA_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
AFTER_AC_FIELDS = (
    "record_stage_after", "record_observed_at_valid", "source_installed_match",
    "companion_receipt_match", "companion_bytes_match", "producer_off",
    "same_job", "job_requires_attention", "same_card",
    "post_transition_receipts", "count_delta", "receipt_count_match",
    "last_at_advanced", "last_receipt_match", "receipt_body_match",
)
AFTER_AC_EXPECTED = (
    "record_stage_after==1&&record_observed_at_valid==1&&source_installed_match==1"
    "&&companion_receipt_match==1&&companion_bytes_match==1"
    "&&producer_off==1&&same_job==1&&job_requires_attention==1&&same_card==1"
    "&&post_transition_receipts>=1&&count_delta>=1&&receipt_count_match==1"
    "&&last_at_advanced==1&&last_receipt_match==1&&receipt_body_match==1"
)


def job_key(job: str) -> str:
    return hashlib.sha256(job.encode("utf-8")).hexdigest()[:24]


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_now_datetime() -> datetime:
    return datetime.now(timezone.utc)


def parse_utc(value: object, field: str) -> tuple[datetime | None, str | None]:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None, "%s must be a UTC RFC3339 timestamp ending in Z" % field
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None, "%s must be a valid UTC RFC3339 timestamp" % field
    return parsed.astimezone(timezone.utc), None


def fetch_json(url: str) -> tuple[dict, dict]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:  # nosec B310: operator URL
        body = json.loads(response.read().decode("utf-8"))
        return body, dict(response.headers.items())


def installed_airlock_revision(expected: str) -> tuple[str | None, dict, str | None]:
    """Read the normal install receipt instead of inventing a health-API contract."""
    if not SHA_RE.fullmatch(expected):
        return None, {}, "expected airlock revision must be a full lowercase 40-hex SHA"
    command = [sys.executable, str(ROOT / "bin" / "airlock-status"), "--json"]
    try:
        proc = subprocess.run(command, text=True, capture_output=True, timeout=90)
        report = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return None, {}, ("airlock-status did not produce its installed-state report: %s" %
                          type(error).__name__)
    if not isinstance(report, dict) or not isinstance(report.get("checks"), list):
        return None, {}, "airlock-status installed-state report has no checks list"
    checks = {item.get("id"): item for item in report["checks"]
              if isinstance(item, dict)}
    evidence = {}
    for check_id in ("install.transaction", "install.drift", "install.revision"):
        check = checks.get(check_id) or {}
        evidence[check_id] = {"status": check.get("status"), "detail": check.get("detail")}
        if check.get("status") != "ok":
            return None, evidence, "%s is not ok: %s" % (
                check_id, check.get("detail", "check is absent"))
    observed = evidence["install.revision"]["detail"]
    if not isinstance(observed, str) or not SHA_RE.fullmatch(observed):
        return None, evidence, "install.revision did not report a full lowercase 40-hex SHA"
    if observed != expected:
        return observed, evidence, "installed airlock revision mismatches the approved expectation"
    return observed, evidence, None


def installed_companion_receipt(expected: str, receipt_path: str) -> tuple[dict, str | None]:
    """Bind an independently approved infra revision to its installed script bytes."""
    evidence = {"receipt": str(Path(receipt_path).resolve())}
    if not SHA_RE.fullmatch(expected):
        return evidence, "expected infra revision must be a full lowercase 40-hex SHA"
    try:
        receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return evidence, "companion receipt could not be read: %s" % type(error).__name__
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
        return evidence, "companion receipt schema_version must be 1"
    evidence.update({key: receipt.get(key) for key in (
        "producer", "box", "producer_off", "infra_revision", "installed_script",
        "installed_script_sha256", "applied_at",
    )})
    if receipt.get("producer") != "cron-silence" or receipt.get("producer_off") is not True:
        return evidence, "companion receipt does not prove cron-silence producer_off=true"
    if not isinstance(receipt.get("box"), str) or not receipt["box"].strip():
        return evidence, "companion receipt box must be nonempty text"
    revision = receipt.get("infra_revision")
    if not isinstance(revision, str) or not SHA_RE.fullmatch(revision):
        return evidence, "companion receipt infra_revision must be a full lowercase 40-hex SHA"
    if revision != expected:
        return evidence, "companion receipt revision mismatches the approved expectation"
    applied_at, error = parse_utc(receipt.get("applied_at"), "companion receipt applied_at")
    if error:
        return evidence, error
    script_value = receipt.get("installed_script")
    expected_hash = receipt.get("installed_script_sha256")
    if not isinstance(script_value, str) or not Path(script_value).is_absolute():
        return evidence, "companion receipt installed_script must be an absolute path"
    if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
        return evidence, "companion receipt installed_script_sha256 must be lowercase 64-hex"
    script = Path(script_value)
    try:
        actual_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    except OSError as error:
        return evidence, "installed companion script could not be read: %s" % type(error).__name__
    evidence["observed_script_sha256"] = actual_hash
    evidence["resolved_installed_script"] = str(script.resolve())
    if actual_hash != expected_hash:
        return evidence, "installed companion script bytes mismatch the deployment receipt"
    evidence["applied_at"] = applied_at.strftime("%Y-%m-%dT%H:%M:%SZ")
    return evidence, None


def open_card(db: str, group: str) -> dict | None:
    uri = "file:%s?mode=ro" % Path(db).resolve()
    with sqlite3.connect(uri, uri=True) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT card_id, \"group\", count, sent_at, archived_at, last_at FROM cards "
            "WHERE \"group\"=? AND archived_at IS NULL ORDER BY last_at DESC LIMIT 1", (group,)
        ).fetchone()
    return dict(row) if row else None


def cron_receipts_since(db: str, group: str, baseline: datetime) -> tuple[list[dict], str | None]:
    """Return only producer-shaped cron ledger receipts created after the after baseline."""
    uri = "file:%s?mode=ro" % Path(db).resolve()
    with sqlite3.connect(uri, uri=True) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, source, received_at, payload FROM ledger "
            "WHERE \"group\"=? AND source='cron' ORDER BY received_at,id", (group,)
        ).fetchall()
    receipts = []
    for row in rows:
        received_at, error = parse_utc(row["received_at"], "cron ledger received_at")
        if error:
            return [], error
        if received_at <= baseline:
            continue
        try:
            payload = json.loads(row["payload"])
        except (TypeError, json.JSONDecodeError):
            return [], "fresh cron ledger payload is not valid JSON"
        if not isinstance(payload, dict):
            return [], "fresh cron ledger payload must be an object"
        created_at, error = parse_utc(payload.get("created_at"), "fresh cron payload created_at")
        if error:
            return [], error
        event_id = payload.get("id")
        prefix = group + ":"
        if (row["id"] != event_id or payload.get("group") != group
                or payload.get("source") != "cron" or not isinstance(event_id, str)
                or not event_id.startswith(prefix) or not event_id[len(prefix):].isdigit()):
            return [], "fresh cron ledger receipt does not match the periodic producer shape"
        if created_at <= baseline or int(created_at.timestamp()) != int(event_id[len(prefix):]):
            return [], "fresh cron ledger receipt was not created after the after baseline"
        if created_at > received_at:
            return [], "fresh cron ledger receipt was received before its producer timestamp"
        receipts.append({
            "id": row["id"], "received_at": row["received_at"],
            "created_at": payload["created_at"], "body": payload.get("body"),
        })
    return receipts, None


def write_evidence(directory: str, stage: str, record: dict) -> Path:
    target = Path(directory)
    target.mkdir(parents=True, exist_ok=True)
    path = target / ("cron-handoff-%s.json" % stage)
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def after_acceptance_axes(record: object, source_install: object = None,
                          companion_install: object = None,
                          expected_infra_revision: str | None = None) -> dict:
    """Recompute AC21 from a saved after record without touching live state."""
    axes = {field: 0 for field in AFTER_AC_FIELDS}
    if not isinstance(record, dict):
        return axes
    axes["record_stage_after"] = int(record.get("stage") == "after")
    record_observed_at, record_observed_error = parse_utc(
        record.get("observed_at"), "record observed_at")
    install = record.get("install_evidence")
    if not isinstance(install, dict) and isinstance(source_install, dict):
        install = source_install.get("install_evidence", source_install)
    revision = record.get("airlock_revision")
    if isinstance(install, dict):
        revision_check = install.get("install.revision")
        axes["source_installed_match"] = int(
            isinstance(revision, str) and bool(SHA_RE.fullmatch(revision))
            and all(isinstance(install.get(name), dict)
                    and install[name].get("status") == "ok"
                    for name in ("install.transaction", "install.drift", "install.revision"))
            and revision_check.get("detail") == revision)

    companion = record.get("companion_install")
    if not isinstance(companion, dict) and isinstance(companion_install, dict):
        companion = companion_install
    baseline = record.get("baseline")
    card = record.get("card")
    receipts = record.get("maintenance_receipts")
    if not isinstance(companion, dict):
        companion = {}
    if not isinstance(baseline, dict):
        baseline = {}
    if not isinstance(card, dict):
        card = {}
    if not isinstance(receipts, list):
        receipts = []

    receipt_hash = companion.get("installed_script_sha256")
    observed_hash = companion.get("observed_script_sha256")
    axes["companion_bytes_match"] = int(
        isinstance(receipt_hash, str) and bool(SHA256_RE.fullmatch(receipt_hash))
        and receipt_hash == observed_hash)
    axes["producer_off"] = int(companion.get("producer_off") is True)
    applied_at, applied_error = parse_utc(companion.get("applied_at"), "applied_at")
    baseline_at, baseline_error = parse_utc(baseline.get("observed_at"), "baseline observed_at")
    axes["companion_receipt_match"] = int(
        companion.get("producer") == "cron-silence"
        and isinstance(companion.get("infra_revision"), str)
        and bool(SHA_RE.fullmatch(companion["infra_revision"]))
        and (expected_infra_revision is None
             or (isinstance(expected_infra_revision, str)
                 and bool(SHA_RE.fullmatch(expected_infra_revision))
                 and companion["infra_revision"] == expected_infra_revision))
        and isinstance(companion.get("receipt"), str) and bool(companion["receipt"])
        and isinstance(companion.get("installed_script"), str)
        and Path(companion["installed_script"]).is_absolute()
        and applied_error is None and baseline_error is None and applied_at < baseline_at
        and axes["companion_bytes_match"] == 1 and axes["producer_off"] == 1)

    job = record.get("job")
    group = record.get("group")
    axes["same_job"] = int(
        isinstance(job, str) and bool(job) and baseline.get("job") == job
        and group == "cron:" + job_key(job) and baseline.get("group") == group
        and card.get("group") == group)
    axes["same_card"] = int(
        isinstance(baseline.get("card_id"), str)
        and baseline.get("card_id") == card.get("card_id"))

    valid_receipts = []
    for receipt in receipts:
        if not isinstance(receipt, dict):
            continue
        created_at, created_error = parse_utc(receipt.get("created_at"), "receipt created_at")
        received_at, received_error = parse_utc(receipt.get("received_at"), "receipt received_at")
        event_id = receipt.get("id")
        prefix = str(group) + ":"
        if (created_error is None and received_error is None and baseline_error is None
                and created_at > baseline_at and received_at > baseline_at
                and created_at <= received_at and isinstance(event_id, str)
                and event_id.startswith(prefix) and event_id[len(prefix):].isdigit()
                and int(created_at.timestamp()) == int(event_id[len(prefix):])):
            valid_receipts.append(receipt)
    axes["post_transition_receipts"] = len(valid_receipts)
    baseline_count, card_count = baseline.get("count"), card.get("count")
    axes["count_delta"] = (card_count - baseline_count
                           if isinstance(baseline_count, int) and isinstance(card_count, int)
                           else -1)
    axes["receipt_count_match"] = int(
        axes["count_delta"] > 0 and len(valid_receipts) == len(receipts)
        and axes["count_delta"] == len(valid_receipts))
    baseline_last, baseline_last_error = parse_utc(baseline.get("last_at"), "baseline last_at")
    card_last, card_last_error = parse_utc(card.get("last_at"), "card last_at")
    axes["last_at_advanced"] = int(
        baseline_last_error is None and card_last_error is None and baseline_error is None
        and card_last > baseline_last and card_last > baseline_at)
    axes["last_receipt_match"] = int(
        bool(valid_receipts) and valid_receipts[-1].get("received_at") == card.get("last_at"))
    axes["receipt_body_match"] = int(
        bool(valid_receipts) and all(
            isinstance(item.get("body"), str)
            and ("lastResult=failed" in item["body"] or "timeliness=late" in item["body"])
            for item in valid_receipts))
    axes["job_requires_attention"] = axes["receipt_body_match"]
    latest_received, latest_received_error = (parse_utc(
        valid_receipts[-1].get("received_at"), "latest receipt received_at")
        if valid_receipts else (None, "no valid receipt"))
    axes["record_observed_at_valid"] = int(
        record_observed_error is None and latest_received_error is None
        and record_observed_at >= latest_received)
    return axes


def after_acceptance_line(record: object, evidence: Path, source_install: object = None,
                          companion_install: object = None,
                          expected_infra_revision: str | None = None) -> str:
    axes = after_acceptance_axes(
        record, source_install, companion_install, expected_infra_revision)
    revision = record.get("airlock_revision") if isinstance(record, dict) else None
    evidence_revision = revision if isinstance(revision, str) and SHA_RE.fullmatch(revision) \
        else "unverified"
    observed = ",".join("%s=%d" % (field, axes[field]) for field in AFTER_AC_FIELDS)
    declared = "PASS" if isinstance(record, dict) and record.get("verdict") == "PASS" else "FAIL"
    return ("AC-21-AFTER | expected: %s | observed: %s | verdict: %s "
            "| signal: live | evidence: %s@%s" % (
                AFTER_AC_EXPECTED, observed, declared, evidence, evidence_revision))


def result(stage: str, verdict: str, **fields) -> int:
    record = {"stage": stage, "verdict": verdict, "observed_at": utc_now(), **fields}
    path = write_evidence(fields["evidence_dir"], stage, record)
    print(json.dumps({**record, "evidence": str(path)}, ensure_ascii=False, sort_keys=True),
          flush=True)
    if stage == "after":
        # Keep stdout as the single JSON result.  accept-card combines stderr with stdout,
        # so the live AC row remains machine-visible without breaking JSON consumers.
        print(after_acceptance_line(record, path), file=sys.stderr, flush=True)
    return 0 if verdict == "PASS" else 2


def wait_for_before(args, expected_revision: str) -> int:
    installed, install_evidence, install_error = installed_airlock_revision(expected_revision)
    if install_error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason=install_error, expected_airlock_revision=expected_revision,
                      observed_airlock_revision=installed, install_evidence=install_evidence)
    deadline = time.monotonic() + args.timeout
    group = "cron:" + job_key(args.job)
    last_error = None
    while time.monotonic() <= deadline:
        try:
            fetch_json(args.hub_url.rstrip("/") + "/api/health")
            cron, _ = fetch_json(args.hub_url.rstrip("/") + "/api/cron/jobs")
            job = next((item for item in cron.get("jobs", []) if item.get("id") == args.job), None)
            if not job or not (job.get("lastResult") == "failed" or job.get("timeliness") == "late"):
                return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                              reason="named job is not currently failed or late", job=args.job)
            card = open_card(args.db, group)
            if card and card["sent_at"]:
                final_installed, final_evidence, final_error = installed_airlock_revision(
                    expected_revision)
                if final_error:
                    return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                                  reason=final_error,
                                  expected_airlock_revision=expected_revision,
                                  observed_airlock_revision=final_installed,
                                  install_evidence=final_evidence)
                return result(args.stage, "PASS", evidence_dir=args.evidence_dir, group=group,
                              job=args.job, card=card, airlock_revision=final_installed,
                              install_evidence=final_evidence)
            last_error = "replacement card has not reached Slack (sent_at still absent)"
        except (OSError, ValueError, sqlite3.Error, urllib.error.URLError, urllib.error.HTTPError) as error:
            last_error = "%s: %s" % (type(error).__name__, error)
        time.sleep(POLL_SECONDS)
    return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir, group=group,
                  job=args.job, reason=last_error or "16-minute observation timeout")


def before_contract(before: object, job: str, expected_revision: str) -> tuple[dict, str | None]:
    group = "cron:" + job_key(job)
    if not isinstance(before, dict) or before.get("stage") != "before" or before.get("verdict") != "PASS":
        return {}, "before-stage did not prove a delivered replacement card"
    if before.get("job") != job or before.get("group") != group:
        return {}, "before-stage job or group does not match the requested job"
    if before.get("airlock_revision") != expected_revision:
        return {}, "before-stage airlock revision does not match the approved expectation"
    card = before.get("card")
    if (not isinstance(card, dict) or not isinstance(card.get("card_id"), str)
            or not card["card_id"].startswith(group + ":")):
        return {}, "before-stage card identity is missing"
    if not isinstance(card.get("count"), int) or card["count"] < 1:
        return {}, "before-stage card count is invalid"
    last_at, error = parse_utc(card.get("last_at"), "before-stage card last_at")
    if error:
        return {}, error
    observed_at, error = parse_utc(before.get("observed_at"), "before-stage observed_at")
    if error:
        return {}, error
    return {
        "group": group, "job": job, "card_id": card["card_id"], "count": card["count"],
        "last_at": card["last_at"], "observed_at": before["observed_at"],
        "_last_at_datetime": last_at, "_observed_at_datetime": observed_at,
    }, None


def card_matches_baseline(card: dict | None, baseline: dict) -> str | None:
    if not card or card.get("card_id") != baseline["card_id"] or card.get("group") != baseline["group"]:
        return "replacement card identity changed after retirement"
    if card.get("archived_at") is not None:
        return "replacement card was archived after retirement"
    if not isinstance(card.get("count"), int) or card["count"] < baseline["count"]:
        return "replacement card count moved backwards after retirement"
    last_at, error = parse_utc(card.get("last_at"), "replacement card last_at")
    if error:
        return error
    if last_at < baseline["_last_at_datetime"]:
        return "replacement card last_at moved backwards after retirement"
    return None


def wait_for_after(args, expected_revision: str, before: dict) -> int:
    installed, install_evidence, install_error = installed_airlock_revision(expected_revision)
    if install_error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason=install_error, expected_airlock_revision=expected_revision,
                      observed_airlock_revision=installed, install_evidence=install_evidence)
    companion, companion_error = installed_companion_receipt(
        args.expect_infra_revision, args.infra_receipt)
    if companion_error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason=companion_error, companion_install=companion)
    before_state, contract_error = before_contract(before, args.job, expected_revision)
    if contract_error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason=contract_error)
    applied_at, _ = parse_utc(companion["applied_at"], "companion receipt applied_at")
    if applied_at <= before_state["_observed_at_datetime"]:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason="companion retirement was not applied after the before observation",
                      companion_install=companion)
    try:
        initial = open_card(args.db, before_state["group"])
    except sqlite3.Error as error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason="%s: %s" % (type(error).__name__, error))
    initial_error = card_matches_baseline(initial, before_state)
    if initial_error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason=initial_error, card=initial)
    baseline_at = utc_now_datetime()
    if applied_at > baseline_at:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason="companion retirement was not applied before the after baseline",
                      companion_install=companion)
    baseline_last_at, _ = parse_utc(initial["last_at"], "replacement card last_at")
    baseline = {
        "observed_at": baseline_at.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "group": before_state["group"], "job": args.job, "card_id": initial["card_id"],
        "count": initial["count"], "last_at": initial["last_at"],
    }
    baseline_state = {**baseline, "_last_at_datetime": baseline_last_at}
    deadline = time.monotonic() + args.timeout
    last_error = None
    while time.monotonic() <= deadline:
        try:
            # Reachability is the health endpoint's only role.  A response header is not an
            # installation receipt for the separate companion repository.
            fetch_json(args.hub_url.rstrip("/") + "/api/health")
            cron, _ = fetch_json(args.hub_url.rstrip("/") + "/api/cron/jobs")
            job = next((item for item in cron.get("jobs", []) if item.get("id") == args.job), None)
            if not job or not (job.get("lastResult") == "failed" or job.get("timeliness") == "late"):
                return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                              reason="named job is not currently failed or late", job=args.job,
                              baseline=baseline)
            card = open_card(args.db, before_state["group"])
            identity_error = card_matches_baseline(card, baseline_state)
            if identity_error:
                return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                              reason=identity_error, baseline=baseline, card=card)
            receipts, receipt_error = cron_receipts_since(args.db, baseline["group"], baseline_at)
            if receipt_error:
                return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                              reason=receipt_error, baseline=baseline, card=card)
            count_delta = card["count"] - baseline["count"]
            card_last_at, _ = parse_utc(card["last_at"], "replacement card last_at")
            axes = []
            if job.get("lastResult") == "failed":
                axes.append("lastResult=failed")
            if job.get("timeliness") == "late":
                axes.append("timeliness=late")
            latest_body = receipts[-1].get("body") if receipts else None
            if (count_delta > 0 and count_delta == len(receipts)
                    and card_last_at > baseline_last_at and card_last_at > baseline_at
                    and receipts[-1]["received_at"] == card["last_at"]
                    and isinstance(latest_body, str) and all(axis in latest_body for axis in axes)):
                final_installed, final_evidence, final_error = installed_airlock_revision(
                    expected_revision)
                final_companion, final_companion_error = installed_companion_receipt(
                    args.expect_infra_revision, args.infra_receipt)
                if final_error or final_companion_error or final_companion != companion:
                    return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                                  reason=final_error or final_companion_error or
                                  "companion installation receipt changed during observation",
                                  expected_airlock_revision=expected_revision,
                                  observed_airlock_revision=final_installed,
                                  install_evidence=final_evidence,
                                  companion_install=final_companion, baseline=baseline)
                return result(args.stage, "PASS", evidence_dir=args.evidence_dir,
                              job=args.job, group=baseline["group"], baseline=baseline,
                              card=card, maintenance_receipts=receipts,
                              airlock_revision=final_installed,
                              install_evidence=final_evidence,
                              companion_install=final_companion)
            last_error = ("card increment is not exactly backed by fresh periodic cron receipts "
                          "after the post-retirement baseline")
        except (OSError, ValueError, sqlite3.Error, urllib.error.URLError,
                urllib.error.HTTPError) as error:
            last_error = "%s: %s" % (type(error).__name__, error)
        time.sleep(POLL_SECONDS)
    return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                  job=args.job, group=baseline["group"], baseline=baseline,
                  companion_install=companion,
                  reason=last_error or "16-minute observation timeout")


def after(args, expected_revision: str) -> int:
    before_path = Path(args.evidence_dir) / "cron-handoff-before.json"
    if not before_path.exists():
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason="before-stage evidence is missing")
    try:
        before = json.loads(before_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return result(args.stage, "NOT RUN", evidence_dir=args.evidence_dir,
                      reason="before-stage evidence could not be read: %s" % type(error).__name__)
    return wait_for_after(args, expected_revision, before)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=("before", "after"), required=True)
    parser.add_argument("--hub-url", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--expect-airlock-revision", required=True)
    parser.add_argument("--expect-infra-revision")
    parser.add_argument("--infra-receipt")
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.stage == "after" and (not args.expect_infra_revision or not args.infra_receipt):
        parser.error("after requires --expect-infra-revision and --infra-receipt")
    return (after(args, args.expect_airlock_revision) if args.stage == "after"
            else wait_for_before(args, args.expect_airlock_revision))


if __name__ == "__main__":
    raise SystemExit(main())
