#!/usr/bin/env python3
"""Read-mostly live gate for the installed Hub inbox strip.

The sole mutation is the explicitly selected safe card: it is marked read and run once
through the owner UI.  This script never installs, updates, migrates a database, stops a
service, or retires a producer.  Missing live inputs or a card that cannot safely be run
is reported as NOT RUN, never as a pass.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit


ROOT = Path(__file__).resolve().parents[2]
AC_EXPECTED = (
    "installed_match==1&&owner==1&&strip_match==1&&index_stable==1&&"
    "identity_unique==1&&window_reopened==1&&ran_input_match==1"
)


class NotRun(RuntimeError):
    """A prerequisite was absent before the safe-card mutation started."""


class VerificationFailed(RuntimeError):
    """A measured oracle disagreed with the required live outcome."""


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def source_revision() -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True,
            stderr=subprocess.DEVNULL, timeout=15).strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def normalize_urls(raw: str) -> tuple[str, str]:
    if not raw.strip():
        raise NotRun("DMH_HUB_URL was not supplied")
    parsed = urlsplit(raw.strip())
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise NotRun("hub URL must be an absolute http(s) URL")
    if parsed.username or parsed.password:
        raise NotRun("hub URL must not contain credentials")
    path = parsed.path.rstrip("/")
    if path.endswith("/monitor"):
        hub_path = path[:-len("/monitor")] or "/"
        monitor_path = path
    else:
        hub_path = path or "/"
        monitor_path = ("" if path == "/" else path) + "/monitor"
    hub = urlunsplit((parsed.scheme, parsed.netloc, hub_path, "", "")).rstrip("/") + "/"
    monitor = urlunsplit((parsed.scheme, parsed.netloc, monitor_path, "", "")).rstrip("/")
    return hub, monitor


def installed_revision() -> tuple[str | None, str]:
    command = [sys.executable, str(ROOT / "bin" / "airlock-status"), "--json"]
    try:
        proc = subprocess.run(command, text=True, capture_output=True, timeout=90)
        report = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        return None, "airlock-status did not produce its JSON report: %s" % type(error).__name__
    checks = {item.get("id"): item for item in report.get("checks", [])}
    for check_id in ("install.transaction", "install.drift"):
        check = checks.get(check_id)
        if not check or check.get("status") != "ok":
            return None, "%s: %s" % (check_id,
                                      (check or {}).get("detail", "check is absent"))
    check = checks.get("install.revision")
    if not check or check.get("status") != "ok":
        return None, (check or {}).get("detail", "install.revision is absent")
    return check.get("detail"), "ok"


def db_uri(path: str) -> str:
    if not path.strip():
        raise NotRun("DMH_DB was not supplied")
    resolved = Path(path).expanduser().resolve()
    if not resolved.is_file():
        raise NotRun("message database does not exist")
    return "file:%s?mode=ro" % quote(str(resolved), safe="/")


def database_snapshot(path: str) -> dict:
    with sqlite3.connect(db_uri(path), uri=True) as connection:
        connection.row_factory = sqlite3.Row
        columns = {row[1] for row in connection.execute("PRAGMA table_info(cards)")}
        required = {"card_id", "group", "run", "link", "count", "read_at",
                    "archived_at", "ran_at", "ran_input", "ran_window"}
        if not required.issubset(columns):
            raise NotRun("installed cards schema is missing phase-2 columns")
        rows = [dict(row) for row in connection.execute(
            'SELECT card_id,"group",run,link,count,read_at,archived_at,ran_at,'
            'ran_input,ran_window FROM cards WHERE archived_at IS NULL '
            'ORDER BY last_at DESC,card_id ASC')]
    nonheartbeat = [row for row in rows
                    if row["group"] != "heartbeat" and
                    not row["card_id"].startswith("heartbeat:")]
    identities = set()
    for row in nonheartbeat:
        try:
            decoded_run = json.loads(row["run"]) if row["run"] else None
        except (TypeError, json.JSONDecodeError) as error:
            raise VerificationFailed("an active card has invalid stored run JSON") from error
        identities.add((row["group"], json.dumps(decoded_run, ensure_ascii=False,
                                                  sort_keys=True, separators=(",", ":")),
                        row["link"]))
    return {"rows": rows, "nonheartbeat": nonheartbeat,
            "identity_unique": len(nonheartbeat) == len(identities)}


def expected_strip_ids(preview: dict) -> list[str]:
    seen: set[str] = set()
    selected = []
    for card in list(preview.get("top", [])) + list(preview.get("messages", [])):
        if not isinstance(card, dict):
            continue
        card_id = card.get("card_id")
        heartbeat = (card_id or "").startswith("heartbeat:") or card.get("group") == "heartbeat" \
            or card.get("source") == "heartbeat"
        if not card_id or card.get("read_at") or heartbeat or card_id in seen:
            continue
        seen.add(card_id)
        selected.append(card_id)
        if len(selected) == 3:
            break
    return selected


def browser_json(page, url: str) -> tuple[int, dict]:
    result = page.evaluate("""async url => {
      const response = await fetch(url, {cache: 'no-store'});
      let data = {}; try { data = await response.json(); } catch (_) {}
      return {status: response.status, data};
    }""", url)
    return result["status"], result["data"]


def expected_ran_input(card: dict, values: list[str]) -> str:
    declarations = (card.get("run") or {}).get("params") or []
    if len(values) != len(declarations):
        raise VerificationFailed("run sheet inputs do not match stored declarations")
    params = {declaration["key"]: value
              for declaration, value in zip(declarations, values, strict=True)}
    return json.dumps({"note": "", "params": params}, ensure_ascii=False,
                      sort_keys=True, separators=(",", ":"))


def write_record(directory: str, record: dict) -> Path:
    target = Path(directory)
    target.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = target / ("hub-strip-live-%s.json" % run_id)
    suffix = 1
    while path.exists():
        path = target / ("hub-strip-live-%s-%d.json" % (run_id, suffix))
        suffix += 1
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    return path


def print_result(verdict: str, observed: dict, evidence: str, revision: str,
                 reason: str | None = None) -> int:
    payload = {"verdict": verdict, "observed_at": utc_now(), "observed": observed,
               "evidence": evidence}
    if reason:
        payload["reason"] = reason
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    ac_verdict = "PASS" if verdict == "PASS" else "FAIL" if verdict == "FAIL" else "UNMEASURED"
    values = ",".join("%s=%d" % (name, int(bool(observed.get(name, False))))
                      for name in ("installed_match", "owner", "strip_match", "index_stable",
                                   "identity_unique", "window_reopened", "ran_input_match"))
    print("AC-20 | expected: %s | observed: %s | verdict: %s | signal: live | evidence: %s@%s" %
          (AC_EXPECTED, values, ac_verdict, evidence, revision))
    return 0 if verdict == "PASS" else 2


def verify(args, observed: dict) -> tuple[dict, dict]:
    if not re.fullmatch(r"[0-9a-f]{40}", args.expect_revision or ""):
        raise NotRun("DMH_AIRLOCK_SHA must be the full 40-hex merged revision")
    if not args.card_id.strip():
        raise NotRun("DMH_SAFE_CARD was not supplied")
    hub_url, monitor_url = normalize_urls(args.hub_url)
    installed, detail = installed_revision()
    if installed != args.expect_revision:
        raise NotRun("installed revision mismatch: expected %s, observed %s (%s)" %
                     (args.expect_revision, installed or "absent", detail))
    observed["installed_match"] = True
    snapshot = database_snapshot(args.db)
    observed["identity_unique"] = snapshot["identity_unique"]
    if not snapshot["identity_unique"]:
        raise VerificationFailed("active non-heartbeat cards are not unique by (group, run, link)")

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise NotRun("Python Playwright is unavailable on the operator box") from error

    evidence_dir = Path(args.evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    screenshots = {
        "strip": evidence_dir / ("hub-strip-%s.png" % stamp),
        "message": evidence_dir / ("hub-message-%s.png" % stamp),
        "reopened": evidence_dir / ("hub-reopened-%s.png" % stamp),
    }
    mutation_started = False
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        try:
            response = page.goto(hub_url, wait_until="domcontentloaded", timeout=args.timeout * 1000)
            if response is None or not response.ok:
                raise NotRun("installed Hub URL did not return a successful document")
            owner_status, owner = browser_json(page, hub_url.rstrip("/") + "/whoami")
            if owner_status != 200 or owner.get("role") != "owner":
                raise NotRun("browser session does not have owner execution access")
            observed["owner"] = True
            preview_status, preview = browser_json(
                page, monitor_url + "/api/owner/messages/preview")
            feed_status, feed = browser_json(
                page, monitor_url + "/api/owner/messages?scope=active")
            if preview_status != 200 or feed_status != 200:
                raise NotRun("owner message APIs are not available on the installed target")
            page.wait_for_selector("#msgstrip:not([hidden])", timeout=args.timeout * 1000)
            page.screenshot(path=str(screenshots["strip"]), full_page=True)

            strip_ids = page.locator("#msgstrip .ms-row").evaluate_all(
                "rows => rows.map(row => row.dataset.cardId)")
            expected_ids = expected_strip_ids(preview)
            unread_text = page.locator("#msgstrip .ms-cnt").inner_text()
            strip_match = (strip_ids == expected_ids and
                           str(preview.get("unread_count")) in unread_text)
            observed["strip_match"] = strip_match
            if not strip_match:
                raise VerificationFailed("installed strip card IDs/count differ from the backend preview")
            api_ids = [card.get("card_id") for card in feed.get("messages", [])]
            db_ids = [row["card_id"] for row in snapshot["rows"]]
            if api_ids != db_ids:
                raise VerificationFailed("owner API active card IDs differ from the read-only database")
            safe = next((card for card in preview.get("messages", [])
                         if card.get("card_id") == args.card_id), None)
            if (not safe or args.card_id not in strip_ids or not safe.get("run") or
                    safe.get("ran_at") or safe.get("ran_window")):
                raise NotRun("safe runnable card is absent from the installed strip")
            safe_index = strip_ids.index(args.card_id)

            safe_row = page.locator('#msgstrip .ms-row[data-card-id="%s"]' %
                                    args.card_id.replace('"', '\\"'))
            mutation_started = True
            safe_row.locator(".ms-title").click()
            page.wait_for_selector(".dmc-overlay", timeout=args.timeout * 1000)
            page.wait_for_timeout(300)
            index_after = page.locator("#msgstrip .ms-row").evaluate_all(
                "rows => rows.map(row => row.dataset.cardId)").index(args.card_id)
            index_stable = safe_index == index_after
            observed["index_stable"] = index_stable
            page.screenshot(path=str(screenshots["message"]), full_page=True)
            if not index_stable:
                raise VerificationFailed("marking read changed the selected strip card index")

            page.locator(".dmc-overlay .dmc-button", has_text="Run").last.click()
            page.wait_for_selector(".dmc-overlay .dmc-note textarea",
                                   timeout=args.timeout * 1000)
            values = page.locator(".dmc-overlay .dmc-param select, .dmc-overlay .dmc-param input").evaluate_all(
                "inputs => inputs.map(input => input.value)")
            expected_input = expected_ran_input(safe, values)
            page.locator(".dmc-overlay .dmc-button", has_text="▶ Run").click()
            page.wait_for_selector(".dmc-overlay iframe.dmc-terminal",
                                   timeout=args.timeout * 1000)
            first_devterm = page.locator(".dmc-overlay iframe.dmc-terminal").get_attribute("src")

            page.locator(".dmc-overlay .dmc-button", has_text="← Message").click()
            page.wait_for_selector(".dmc-overlay .dmc-button", timeout=args.timeout * 1000)
            with page.expect_response(lambda item: item.url.endswith("/api/owner/run/window"),
                                      timeout=args.timeout * 1000) as selected:
                page.locator(".dmc-overlay .dmc-button", has_text="▶ Ran · View").click()
            selection = selected.value.json()
            page.wait_for_selector(".dmc-overlay iframe.dmc-terminal",
                                   timeout=args.timeout * 1000)
            reopened_devterm = page.locator(".dmc-overlay iframe.dmc-terminal").get_attribute("src")
            page.screenshot(path=str(screenshots["reopened"]), full_page=True)
        except Exception as error:
            if mutation_started and not isinstance(error, (NotRun, VerificationFailed)):
                raise VerificationFailed("live browser oracle failed: %s" % type(error).__name__) from error
            raise
        finally:
            browser.close()

    after = database_snapshot(args.db)
    stored = next((row for row in after["rows"] if row["card_id"] == args.card_id), None)
    if not stored:
        raise VerificationFailed("safe card disappeared from the active database")
    ran_input_match = stored["ran_input"] == expected_input
    window_reopened = bool(selection.get("ok") and selection.get("state") == "active" and
                           selection.get("window") == stored["ran_window"] and
                           first_devterm and first_devterm == reopened_devterm)
    observed["identity_unique"] = after["identity_unique"]
    observed["window_reopened"] = window_reopened
    observed["ran_input_match"] = ran_input_match
    record = {
        "schema": 1,
        "verdict": "PASS" if all(observed.values()) else "FAIL",
        "observed_at": utc_now(),
        "hub_origin": urlsplit(hub_url).netloc,
        "installed_revision": installed,
        "safe_card_id": args.card_id,
        "strip_card_ids": strip_ids,
        "backend_card_ids": api_ids,
        "active_nonheartbeat_count": len(after["nonheartbeat"]),
        "expected_ran_input_sha256": hashlib.sha256(expected_input.encode()).hexdigest(),
        "stored_ran_input_sha256": hashlib.sha256((stored["ran_input"] or "").encode()).hexdigest(),
        "ran_window": stored["ran_window"],
        "screenshots": {name: str(path) for name, path in screenshots.items()},
        "observed": observed,
    }
    return observed, record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub-url", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--expect-revision", required=True)
    parser.add_argument("--card-id", required=True)
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--timeout", type=int, default=30,
                        help="per-browser-operation timeout in seconds (default: 30)")
    args = parser.parse_args()
    revision = source_revision()
    observed = {name: False for name in ("installed_match", "owner", "strip_match",
                                         "index_stable", "identity_unique",
                                         "window_reopened", "ran_input_match")}
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        observed, record = verify(args, observed)
        path = write_record(args.evidence_dir, record)
        return print_result(record["verdict"], observed, str(path), revision)
    except NotRun as error:
        record = {"schema": 1, "verdict": "NOT RUN", "observed_at": utc_now(),
                  "reason": str(error), "observed": observed}
        path = write_record(args.evidence_dir, record)
        return print_result("NOT RUN", observed, str(path), revision, str(error))
    except VerificationFailed as error:
        record = {"schema": 1, "verdict": "FAIL", "observed_at": utc_now(),
                  "reason": str(error), "observed": observed}
        path = write_record(args.evidence_dir, record)
        return print_result("FAIL", observed, str(path), revision, str(error))


if __name__ == "__main__":
    raise SystemExit(main())
