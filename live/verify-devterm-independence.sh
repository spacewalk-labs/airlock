#!/usr/bin/env bash
# Grade DEVTERM_INDEPENDENCE phase-5 evidence without installing or stopping services.
#
# The live collector runs separately in a disposable guest.  This verifier only reads
# exact git revisions and sealed evidence copied out of that guest.  --fixture exercises
# the same observers and predicates, including one destructive mutation per AC, entirely
# below TMPDIR.
set -euo pipefail

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import operator
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


FULL_SHA = re.compile(r"[0-9a-f]{40}\Z")
FULL_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
RELEASE_SOURCE = re.compile(
    r"(?:release from [a-z0-9][a-z0-9._-]{0,63}\s*@\s*|"
    r"source(?:-ref)?[=: ]+)([0-9a-f]{7,40})",
    re.I,
)
STALE_ENV = re.compile(r"(?:AIRLOCK_)?DEVTERM_(?:ACCOUNTS|XAI)(?:=|_)")

ASSETS = (
    "hub/assets/accounts/panel.html",
    "hub/assets/accounts/accounts.js",
    "hub/assets/accounts/secretdrop.js",
)
STALE_ALIASES = (
    "/home/airlock/.local/share/airlock-devterm/web/panel.html",
    "/home/airlock/.local/share/airlock-devterm/web/accounts.js",
    "/home/airlock/.local/share/airlock-devterm/web/platform-account-control.js",
)
INSTALLED_ASSETS = tuple(f"/opt/airlock/{path}" for path in ASSETS)
ACCOUNT_UNIT = "/home/airlock/.config/systemd/user/airlock-accounts-api.service"
REQUIRED_CALL_SOURCES = {
    "panel.html": "panel_auto",
    "accounts": "panel_auto",
    "acct-alert": "panel_auto",
    # A fresh box has no fleet usage store for accounts.js to consume.  The observer
    # therefore probes this read from the already authenticated hub page and labels it;
    # counting it as a UI-initiated request would overstate what the browser showed.
    "claude-usage-store": "manual_probe",
}

PREDICATES = {
    "AC-DTI-P5A": (
        "public_ref_bound==1 && public_release_maps_private==1 && "
        "public_projection_blobs_match==1 && public_contains_phase4_verifier==1 && "
        "public_manifest==1 && fresh_install==1 && update_install==1 && "
        "rollback_install==1 && account_unit==1 && account_assets==3 && "
        "stale_aliases==0 && stale_account_env==0 && negative_control==1"
    ),
    "AC-DTI-P5B": (
        "devterm_units_stopped==2 && hub_active==1 && account_api_active==1 && "
        "panel_200==1 && accounts_200==1 && alert_200==1 && "
        "devterm_root_unavailable==1 && secret_ui_unavailable==1 && "
        "devterm_units_restored==2 && terminal_session_restored==1 && negative_control==1"
    ),
    "AC-DTI-P5C": (
        "observer_independent==1 && installed_ref_bound==1 && devterm_stopped==1 && "
        "subscription_click==1 && account_rows_ge1==1 && hub_prefix_calls==1 && "
        "backend_19904_bound==1 && terminal_after_restart==1 && negative_control==1"
    ),
}

TERM = re.compile(r"([a-z][a-z0-9_]*)\s*(==|!=|>=|<=|>|<)\s*(-?[0-9]+)\Z")
OPS = {"==": operator.eq, "!=": operator.ne, ">=": operator.ge,
       "<=": operator.le, ">": operator.gt, "<": operator.lt}


class EvidenceError(RuntimeError):
    pass


@dataclass
class Row:
    name: str
    expected: str
    observed: dict[str, int]
    verdict: str
    signal: str
    evidence: str

    def render(self) -> str:
        values = ",".join(f"{key}={value}" for key, value in self.observed.items())
        return (f"{self.name} | expected: {self.expected} | observed: {values} | "
                f"verdict: {self.verdict} | signal: {self.signal} | evidence: {self.evidence}")


def run(*args: str, cwd: Path | None = None) -> str:
    try:
        return subprocess.run(args, cwd=cwd, check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise EvidenceError(f"command failed: {' '.join(args)}: {detail.strip()}") from exc


def decide(expected: str, observed: dict[str, int]) -> str:
    for raw in expected.split("&&"):
        match = TERM.fullmatch(raw.strip())
        if match is None:
            raise EvidenceError(f"unsupported predicate term: {raw.strip()}")
        key, operation, literal = match.groups()
        if key not in observed or not OPS[operation](observed[key], int(literal)):
            return "FAIL"
    return "PASS"


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read JSON evidence: {path}") from exc
    if not isinstance(value, dict):
        raise EvidenceError(f"JSON evidence is not an object: {path}")
    return value


def boolint(value: object) -> int:
    return int(value is True or value == 1)


def regular_bytes(path: Path) -> bytes:
    if not path.is_file() or path.is_symlink():
        raise EvidenceError(f"not a sealed regular file: {path}")
    return path.read_bytes()


def verify_seal(root: Path) -> str:
    manifest = root / "SHA256SUMS"
    raw = regular_bytes(manifest)
    listed: set[str] = set()
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise EvidenceError(f"malformed SHA256SUMS line {number}")
        digest, name = match.groups()
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or name in listed:
            raise EvidenceError(f"unsafe or duplicate sealed path: {name}")
        actual = hashlib.sha256(regular_bytes(root / pure)).hexdigest()
        if actual != digest:
            raise EvidenceError(f"sealed digest mismatch: {name}")
        listed.add(name)
    required = {"meta.json", "lifecycle.json", "systemd.json", "http.json", "recovery.json",
                "installed-inventory.json"}
    if not required <= listed:
        raise EvidenceError(f"seal lacks required evidence: {sorted(required - listed)}")
    present = {path.relative_to(root).as_posix() for path in root.rglob("*")
               if path.is_file() and not path.is_symlink() and path != manifest}
    if present != listed:
        raise EvidenceError(f"sealed file set differs: extra={sorted(present - listed)}, "
                            f"missing={sorted(listed - present)}")
    return hashlib.sha256(raw).hexdigest()


def write_seal(root: Path) -> None:
    names = sorted(path.relative_to(root).as_posix() for path in root.rglob("*")
                   if path.is_file() and not path.is_symlink() and path.name != "SHA256SUMS")
    lines = [f"{hashlib.sha256(regular_bytes(root / name)).hexdigest()}  {name}"
             for name in names]
    (root / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def git_ref(root: Path, ref: str, label: str) -> None:
    if FULL_SHA.fullmatch(ref) is None:
        raise EvidenceError(f"{label} ref must be a full lowercase git SHA")
    if run("git", "-C", str(root), "rev-parse", "--verify", f"{ref}^{{commit}}") != ref:
        raise EvidenceError(f"{label} ref does not resolve exactly")


def git_files(root: Path, ref: str) -> list[str]:
    output = run("git", "-C", str(root), "-c", "core.quotePath=false",
                 "ls-tree", "-r", "--name-only", ref)
    return output.splitlines() if output else []


def blob(root: Path, ref: str, path: str) -> bytes:
    try:
        return subprocess.run(["git", "-C", str(root), "show", f"{ref}:{path}"],
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise EvidenceError(f"missing git blob {ref}:{path}") from exc


def classify_private(private_root: Path, private_ref: str) -> dict[str, bytes]:
    """Build the exact public projection in a temporary archive using its own manifest."""
    with tempfile.TemporaryDirectory(prefix="airlock-p5-projection-") as raw:
        tree = Path(raw)
        archive = subprocess.Popen(
            ["git", "-C", str(private_root), "archive", private_ref], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        untar = subprocess.run(["tar", "-x", "-C", str(tree)], stdin=archive.stdout,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        archive.stdout.close()
        archive_rc = archive.wait()
        if archive_rc or untar.returncode:
            raise EvidenceError("cannot materialize private ref for projection")
        manifest = tree / "install/public-manifest.sh"
        checked = subprocess.run(["bash", str(manifest), "--check", "--dir", str(tree)],
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if checked.returncode:
            raise EvidenceError(f"private manifest failed: {(checked.stdout + checked.stderr).strip()}")
        pruned = subprocess.run(["bash", str(manifest), "--prune-list", "--dir", str(tree)],
                                check=True, text=True, stdout=subprocess.PIPE).stdout.splitlines()
        for name in pruned:
            target = tree / name
            if target.is_file() or target.is_symlink():
                target.unlink()
        return {path.relative_to(tree).as_posix(): path.read_bytes()
                for path in tree.rglob("*") if path.is_file() and not path.is_symlink()}


def projection_facts(private_root: Path, private_ref: str,
                     public_root: Path, public_ref: str) -> dict[str, int]:
    git_ref(private_root, private_ref, "private")
    git_ref(public_root, public_ref, "public")
    public_head = run("git", "-C", str(public_root), "rev-parse", "HEAD")
    public_clean = not run("git", "-C", str(public_root), "status", "--porcelain",
                           "--untracked-files=no")
    main_candidates = ("refs/remotes/origin/main", "refs/heads/main")
    on_main = 0
    for candidate in main_candidates:
        test = subprocess.run(["git", "-C", str(private_root), "merge-base", "--is-ancestor",
                               private_ref, candidate], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        if test.returncode == 0:
            on_main = 1
            break
    message = run("git", "-C", str(public_root), "show", "-s", "--format=%B", public_ref)
    mapped = any(private_ref.startswith(match.group(1).lower())
                 for match in RELEASE_SOURCE.finditer(message))
    expected = classify_private(private_root, private_ref)
    actual = {path: blob(public_root, public_ref, path)
              for path in git_files(public_root, public_ref)}
    phase4 = "apps/devterm/test-accounts.py"
    return {
        "private_ref_on_main": on_main,
        "public_ref_bound": int(public_head == public_ref and public_clean),
        "public_release_maps_private": int(mapped),
        "public_projection_blobs_match": int(expected == actual),
        "public_contains_phase4_verifier": int(
            phase4 in actual and b'evaluate_ac("DTI-P4D"' in actual[phase4]),
        "public_manifest": 1,
    }


def observe_a(evidence: Path, public_tree: Path, projection: dict[str, int]) -> dict[str, int]:
    lifecycle = load_json(evidence / "lifecycle.json")
    inventory_raw = load_json(evidence / "installed-inventory.json").get("files", [])
    if isinstance(inventory_raw, dict):
        inventory = inventory_raw
    elif isinstance(inventory_raw, list) and all(
            isinstance(item, dict) and set(item) == {"path", "sha256"}
            for item in inventory_raw):
        inventory = {item["path"]: item["sha256"] for item in inventory_raw}
    else:
        inventory = {}
    if len(inventory) != len(inventory_raw) or not all(
            isinstance(name, str) and name.startswith("/") and
            isinstance(digest, str) and FULL_SHA256.fullmatch(digest)
            for name, digest in inventory.items()):
        raise EvidenceError("installed inventory must bind absolute paths to SHA-256 digests")
    installed = evidence / "installed"
    assets = 0
    for source, target in zip(ASSETS, INSTALLED_ASSETS):
        source_path = public_tree / source
        if source_path.is_file() and inventory.get(target) == hashlib.sha256(source_path.read_bytes()).hexdigest():
            assets += 1
    aliases = sum(path in inventory for path in STALE_ALIASES)
    stale_env = 0
    units = installed / "systemd/user"
    if units.is_dir():
        for path in units.glob("airlock-devterm*.service"):
            stale_env += len(STALE_ENV.findall(path.read_text(encoding="utf-8", errors="replace")))
    public_assets = sum((public_tree / path).is_file() for path in ASSETS)
    values = {
        "public_ref_bound": projection.get("public_ref_bound", 0),
        "public_release_maps_private": projection.get("public_release_maps_private", 0),
        "public_projection_blobs_match": projection.get("public_projection_blobs_match", 0),
        "public_contains_phase4_verifier": projection.get("public_contains_phase4_verifier", 0),
        "public_manifest": projection.get("public_manifest", 0),
        "fresh_install": boolint(lifecycle.get("fresh_install")),
        "update_install": boolint(lifecycle.get("update_install")),
        "rollback_install": boolint(lifecycle.get("rollback_install")),
        "account_unit": int(ACCOUNT_UNIT in inventory),
        "account_assets": min(assets, public_assets),
        "stale_aliases": aliases,
        "stale_account_env": stale_env,
        "negative_control": 0,
    }
    return values


def observe_b(evidence: Path) -> dict[str, int]:
    systemd = load_json(evidence / "systemd.json")
    http = load_json(evidence / "http.json")
    recovery = load_json(evidence / "recovery.json")
    stopped = systemd.get("while_stopped", {})
    restored = systemd.get("after_restore", {})
    return {
        "devterm_units_stopped": sum(stopped.get(name) == "inactive" for name in
                                     ("airlock-devterm.service", "airlock-devterm-gate.service")),
        # The hub is nginx platform core, not an app-owned user unit.
        "hub_active": boolint(stopped.get("nginx.service") == "active"),
        "account_api_active": boolint(stopped.get("airlock-accounts-api.service") == "active"),
        "panel_200": boolint(http.get("panel") == 200),
        "accounts_200": boolint(http.get("accounts") == 200),
        "alert_200": boolint(http.get("alert") == 200),
        "devterm_root_unavailable": boolint(http.get("devterm_root") in (0, 404, 502, 503)),
        "secret_ui_unavailable": boolint(http.get("secret_ui") in (0, 404, 502, 503)),
        "devterm_units_restored": sum(restored.get(name) == "active" for name in
                                      ("airlock-devterm.service", "airlock-devterm-gate.service")),
        "terminal_session_restored": boolint(recovery.get("terminal_session_restored")),
        "negative_control": 0,
    }


def observe_c(evidence: Path, browser_path: Path) -> dict[str, int]:
    meta = load_json(evidence / "meta.json")
    systemd = load_json(evidence / "systemd.json")
    guest_http = load_json(evidence / "http.json")
    browser = load_json(browser_path)
    calls = browser.get("hub_prefix_calls", [])
    try:
        stopped_at = dt.datetime.fromisoformat(str(meta["stopped_at"]).replace("Z", "+00:00"))
        restored_at = dt.datetime.fromisoformat(str(meta["restored_at"]).replace("Z", "+00:00"))
        stopped_capture_at = dt.datetime.fromisoformat(
            str(browser["stopped_capture_at"]).replace("Z", "+00:00"))
        terminal_capture_at = dt.datetime.fromisoformat(
            str(browser["terminal_capture_at"]).replace("Z", "+00:00"))
        times_bound = (stopped_at.tzinfo is not None and restored_at.tzinfo is not None and
                       stopped_at <= stopped_capture_at < restored_at <= terminal_capture_at)
    except (KeyError, TypeError, ValueError):
        times_bound = False
    screenshot_hashes = browser.get("screenshot_sha256", [])
    if isinstance(screenshot_hashes, dict):
        screenshot_hashes = list(screenshot_hashes.values())
    screenshots_bound = (isinstance(screenshot_hashes, list) and len(screenshot_hashes) >= 5 and
                         all(isinstance(value, str) and FULL_SHA256.fullmatch(value)
                             for value in screenshot_hashes))
    network_hash = browser.get("network_capture_sha256")
    observed_sources = ({item.get("name"): item.get("source") for item in calls
                         if isinstance(item, dict)} if isinstance(calls, list) else {})
    good_calls = (isinstance(calls, list) and
                  observed_sources == REQUIRED_CALL_SOURCES and
                  all(isinstance(item, dict) and item.get("path", "").startswith("/airlock-accounts/")
                      and item.get("status") == 200 for item in calls))
    stopped = systemd.get("while_stopped", {})
    installed = browser.get("installed_ref")
    browser_public_ref = installed.get("public") if isinstance(installed, dict) else installed
    clicked = browser.get("subscription_click")
    clicked_ok = clicked.get("ok") if isinstance(clicked, dict) else clicked
    account_rows = browser.get("account_rows")
    account_count = account_rows.get("count") if isinstance(account_rows, dict) else account_rows
    terminal = browser.get("terminal_after_restart")
    terminal_ok = terminal.get("ok") if isinstance(terminal, dict) else terminal
    # The remote browser deliberately reports null here: it cannot see loopback.  The
    # listener is measured in the sealed guest evidence and the null keeps the sources
    # distinguishable instead of laundering an implementer observation into a browser one.
    listener_bound = (browser.get("backend_listener") is None and
                      guest_http.get("backend_listener") == "127.0.0.1:19904")
    return {
        "observer_independent": int(bool(browser.get("observer_id")) and
                                    browser.get("observer_id") != meta.get("implementer_id") and
                                    browser.get("nonce") == meta.get("nonce")),
        "installed_ref_bound": int(browser_public_ref == meta.get("installed_ref") ==
                                   meta.get("public_ref")),
        "devterm_stopped": int(times_bound and all(stopped.get(name) == "inactive" for name in
                                   ("airlock-devterm.service", "airlock-devterm-gate.service"))),
        "subscription_click": int(boolint(clicked_ok) and screenshots_bound),
        "account_rows_ge1": int(isinstance(account_count, int) and account_count >= 1),
        "hub_prefix_calls": int(bool(good_calls) and isinstance(network_hash, str) and
                                FULL_SHA256.fullmatch(network_hash) is not None),
        "backend_19904_bound": int(listener_bound),
        "terminal_after_restart": int(boolint(terminal_ok) and times_bound),
        "negative_control": 0,
    }


def fixture(root: Path) -> tuple[Path, Path, Path, dict[str, int]]:
    evidence = root / "evidence"
    public = root / "public"
    evidence.mkdir(parents=True)
    for base in (public, evidence / "installed"):
        for name in ASSETS:
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"fixture {name}\n", encoding="utf-8")
    unit_dir = evidence / "installed/systemd/user"
    unit_dir.mkdir(parents=True, exist_ok=True)
    (unit_dir / "airlock-accounts-api.service").write_text("[Service]\n", encoding="utf-8")
    for name in ("airlock-devterm.service", "airlock-devterm-gate.service"):
        (unit_dir / name).write_text("[Service]\nEnvironment=DEVTERM_FLEET_READ_DOMAIN=example.test\n",
                                     encoding="utf-8")
    data = {
        "meta.json": {"private_ref": "1" * 40, "public_ref": "2" * 40,
                      "installed_ref": "2" * 40, "implementer_id": "implementer-fixture",
                      "nonce": "fixture-nonce", "stopped_at": "2026-09-13T23:00:00Z",
                      "restored_at": "2026-09-13T23:05:00Z"},
        "lifecycle.json": {"fresh_install": True, "update_install": True,
                           "rollback_install": True},
        "systemd.json": {
            "while_stopped": {"airlock-devterm.service": "inactive",
                              "airlock-devterm-gate.service": "inactive",
                              "nginx.service": "active",
                              "airlock-accounts-api.service": "active"},
            "after_restore": {"airlock-devterm.service": "active",
                              "airlock-devterm-gate.service": "active"}},
        "http.json": {"panel": 200, "accounts": 200, "alert": 200,
                      "devterm_root": 503, "secret_ui": 503,
                      "backend_listener": "127.0.0.1:19904"},
        "recovery.json": {"terminal_session_restored": True},
    }
    for name, value in data.items():
        (evidence / name).write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    inventory = {ACCOUNT_UNIT: hashlib.sha256(b"[Service]\n").hexdigest()}
    inventory.update({target: hashlib.sha256(
        (public / source).read_bytes()).hexdigest()
                      for source, target in zip(ASSETS, INSTALLED_ASSETS)})
    (evidence / "installed-inventory.json").write_text(json.dumps({"files": [
        {"sha256": digest, "path": path} for path, digest in sorted(inventory.items())
    ]}, sort_keys=True) + "\n", encoding="utf-8")
    write_seal(evidence)
    browser = root / "browser-evidence.json"
    browser.write_text(json.dumps({
        "observer_id": "independent-fixture", "installed_ref": "2" * 40,
        "nonce": "fixture-nonce", "stopped_capture_at": "2026-09-13T23:02:00Z",
        "terminal_capture_at": "2026-09-13T23:06:00Z",
        "subscription_click": True, "account_rows": 2,
        "hub_prefix_calls": [
            {"name": name, "path": f"/airlock-accounts/{name}", "status": 200,
             "source": source}
            for name, source in REQUIRED_CALL_SOURCES.items()
        ],
        "backend_listener": None, "terminal_after_restart": True,
        "screenshot_sha256": [character * 64 for character in "abcde"],
        "network_capture_sha256": "d" * 64,
    }, sort_keys=True) + "\n", encoding="utf-8")
    projection = {"private_ref_on_main": 1, "public_ref_bound": 1,
                  "public_release_maps_private": 1, "public_projection_blobs_match": 1,
                  "public_contains_phase4_verifier": 1, "public_manifest": 1}
    return evidence, public, browser, projection


def evaluate(evidence: Path, public: Path, browser: Path, projection: dict[str, int],
             signal: str, evidence_label: str) -> tuple[list[Row], list[Row]]:
    a = observe_a(evidence, public, projection)
    b = observe_b(evidence)
    c = observe_c(evidence, browser)

    # Each negative control mutates a temporary copy of the measured input, then invokes
    # the same observer and predicate as the AC.  A product/evidence mutation that still
    # passes leaves negative_control=0 and therefore also fails the baseline row.
    with tempfile.TemporaryDirectory(prefix="airlock-p5-mutations-") as raw:
        mutations = Path(raw)
        public_bad = mutations / "public-no-accounts-js"
        shutil.copytree(public, public_bad)
        (public_bad / "hub/assets/accounts/accounts.js").unlink()
        a_bad = observe_a(evidence, public_bad, projection)
        a_negative = decide(PREDICATES["AC-DTI-P5A"].replace(" && negative_control==1", ""), a_bad)
        a["negative_control"] = int(a_negative == "FAIL")

        evidence_bad = mutations / "evidence-api-stopped"
        shutil.copytree(evidence, evidence_bad)
        state = load_json(evidence_bad / "systemd.json")
        state["while_stopped"]["airlock-accounts-api.service"] = "inactive"
        (evidence_bad / "systemd.json").write_text(json.dumps(state, sort_keys=True) + "\n",
                                                   encoding="utf-8")
        b_bad = observe_b(evidence_bad)
        b_negative = decide(PREDICATES["AC-DTI-P5B"].replace(" && negative_control==1", ""), b_bad)
        b["negative_control"] = int(b_negative == "FAIL")

        browser_bad = mutations / "browser-404.json"
        browser_data = load_json(browser)
        browser_data["hub_prefix_calls"][0]["status"] = 404
        browser_bad.write_text(json.dumps(browser_data, sort_keys=True) + "\n", encoding="utf-8")
        c_bad = observe_c(evidence, browser_bad)
        c_negative = decide(PREDICATES["AC-DTI-P5C"].replace(" && negative_control==1", ""), c_bad)
        c["negative_control"] = int(c_negative == "FAIL")

    rows = [Row(name, PREDICATES[name], values, decide(PREDICATES[name], values),
                signal, evidence_label)
            for name, values in (("AC-DTI-P5A", a), ("AC-DTI-P5B", b), ("AC-DTI-P5C", c))]
    mutation_rows = [
        Row("MUTATION-DTI-P5A", PREDICATES["AC-DTI-P5A"].replace(" && negative_control==1", ""),
            a_bad, a_negative, f"{signal}-mutation", "copied public artifact: accounts.js removed"),
        Row("MUTATION-DTI-P5B", PREDICATES["AC-DTI-P5B"].replace(" && negative_control==1", ""),
            b_bad, b_negative, f"{signal}-mutation", "copied guest evidence: account API inactive"),
        Row("MUTATION-DTI-P5C", PREDICATES["AC-DTI-P5C"].replace(" && negative_control==1", ""),
            c_bad, c_negative, f"{signal}-mutation", "copied browser evidence: hub response 200 to 404"),
    ]
    return rows, mutation_rows


def main() -> int:
    parser = argparse.ArgumentParser(description="grade DEVTERM_INDEPENDENCE phase-5 evidence")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fixture", action="store_true", help="exercise predicates without live changes")
    mode.add_argument("--preflight", action="store_true",
                      help="verify exact release mapping/projection without live changes")
    parser.add_argument("--emit-ac", action="store_true", help="print AC and mutation rows")
    parser.add_argument("--private-root", type=Path)
    parser.add_argument("--private-ref")
    parser.add_argument("--public-root", type=Path)
    parser.add_argument("--public-ref")
    parser.add_argument("--live-env", type=Path, help="sealed evidence directory copied from guest")
    parser.add_argument("--browser-evidence", type=Path,
                        help="JSON captured by a session other than the implementer")
    args = parser.parse_args()
    if not args.emit_ac:
        parser.error("--emit-ac is required")

    try:
        if args.fixture:
            if any((args.private_root, args.private_ref, args.public_root, args.public_ref,
                    args.live_env, args.browser_evidence)):
                parser.error("--fixture cannot be combined with live evidence arguments")
            with tempfile.TemporaryDirectory(prefix="airlock-p5-fixture-") as raw:
                evidence, public, browser, projection = fixture(Path(raw))
                verify_seal(evidence)
                rows, mutations = evaluate(evidence, public, browser, projection,
                                           "fixture", "generated fixture")
        elif args.preflight:
            if any((args.live_env, args.browser_evidence)):
                parser.error("--preflight does not accept live evidence")
            if any(value is None for value in
                   (args.private_root, args.private_ref, args.public_root, args.public_ref)):
                parser.error("--preflight requires both roots and refs")
            assert args.private_root and args.private_ref and args.public_root and args.public_ref
            projection = projection_facts(args.private_root, args.private_ref,
                                          args.public_root, args.public_ref)
            expected = ("private_ref_on_main==1 && public_ref_bound==1 && "
                        "public_release_maps_private==1 && public_projection_blobs_match==1 && "
                        "public_contains_phase4_verifier==1 && public_manifest==1")
            verdict = decide(expected, projection)
            print(Row("PREFLIGHT-DTI-P5", expected, projection, verdict, "projection",
                      f"private:{args.private_ref},public:{args.public_ref}").render())
            return int(verdict != "PASS")
        else:
            required = (args.private_root, args.private_ref, args.public_root, args.public_ref,
                        args.live_env, args.browser_evidence)
            if any(value is None for value in required):
                parser.error("live grading requires both roots/refs, --live-env and --browser-evidence")
            assert args.private_root and args.private_ref and args.public_root and args.public_ref
            assert args.live_env and args.browser_evidence
            seal = verify_seal(args.live_env)
            meta = load_json(args.live_env / "meta.json")
            if meta.get("private_ref") != args.private_ref or meta.get("public_ref") != args.public_ref:
                raise EvidenceError("sealed evidence refs differ from command refs")
            browser_sha = hashlib.sha256(regular_bytes(args.browser_evidence)).hexdigest()
            if meta.get("browser_sha256") != browser_sha:
                raise EvidenceError("browser evidence is not bound by the sealed guest evidence")
            projection = projection_facts(args.private_root, args.private_ref,
                                          args.public_root, args.public_ref)
            if projection["private_ref_on_main"] != 1:
                raise EvidenceError("private ref is not on main")
            rows, mutations = evaluate(args.live_env, args.public_root, args.browser_evidence,
                                       projection, "live", f"sealed:{seal}")
    except EvidenceError as exc:
        print(f"verify-devterm-independence: {exc}", file=sys.stderr)
        return 2

    for row in rows + mutations:
        print(row.render())
    return int(any(row.verdict != "PASS" for row in rows) or
               any(row.verdict != "FAIL" for row in mutations))


if __name__ == "__main__":
    raise SystemExit(main())
PY
