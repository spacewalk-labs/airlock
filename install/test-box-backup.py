#!/usr/bin/env python3
"""Contract tests for bin/airlock-backup (run through python3)."""

from __future__ import annotations

import json
import hashlib
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


SOURCE_ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = SOURCE_ROOT / "bin" / "airlock-backup"
LEDGER_TOOL = SOURCE_ROOT / "bin" / "airlock-ledger"


CONFIG_STUB = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
if os.environ.get("GIT_DIR") or os.environ.get("GIT_WORK_TREE"):
    raise SystemExit(97)
root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(os.environ.get("AIRLOCK_CONFIG_SNAPSHOT")
                      or os.environ.get("AIRLOCK_CONFIG", root / "airlock.toml")).resolve()
cmd = sys.argv[1]
if cmd == "install-snapshot":
    data = source.read_bytes()
    pathlib.Path(sys.argv[2]).write_bytes(data)
    print(json.dumps({"config_path": str(source), "sha256": hashlib.sha256(data).hexdigest()}))
elif cmd == "validate":
    raise SystemExit(0)
elif cmd == "apps":
    print("hub\nnotes")
elif cmd == "package-info":
    print(json.dumps({
        "config_path": str(source),
        "order": ["notes"],
        "packages": {"notes": {
            "dir": str(root / "package-notes"),
            "artifacts": {"units": ["airlock-notes.service"], "fragments": [],
                          "webroot": [], "files": [], "rooted": [],
                          "serve_ports": [], "containers": []},
            "serve_port_values": {}, "serve_mappings": {},
            "unit_scopes": {"airlock-notes.service": "user"},
            "source_class": "shipped", "capabilities": [],
            "lifecycle": {"install": True, "smoke": False, "deactivate": False},
            "deps": [],
        }},
    }))
elif cmd == "adopt-scan":
    raise SystemExit(0)
else:
    raise SystemExit(2)
'''


STATUS_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib
if os.environ.get("GIT_DIR") or os.environ.get("GIT_WORK_TREE"):
    raise SystemExit(97)
root = pathlib.Path(__file__).resolve().parent.parent
state = pathlib.Path(os.environ["AIRLOCK_STATE_DIR"])
config = pathlib.Path(os.environ["AIRLOCK_CONFIG_SNAPSHOT"] if os.environ.get("AIRLOCK_CONFIG_SNAPSHOT") else os.environ["AIRLOCK_CONFIG"])
rc = int(os.environ.get("AIRLOCK_TEST_STATUS_RC", "0"))
try:
    ledger = json.loads((state / "app-ledger.json").read_text())
    lock_ok = ((root / "airlock.lock").read_text() == "notes digest\n"
               or os.environ.get("AIRLOCK_TEST_ALLOW_OVERSIZED_LOCK") == "1")
    healthy = (config.is_file() and lock_ok
               and (state / "plaintext-retirement.json").read_text() == '{"version":1,"entries":[]}\n'
               and bool(ledger["entries"]["notes"]["committed"]))
except Exception:
    healthy = False
if rc == 0 and not healthy:
    rc = 1
verdict = "ok" if rc == 0 else ("incomplete" if rc == 3 else "fail")
print(json.dumps({"schema_version": 1, "verdict": verdict, "exit_code": rc,
                  "checks": [{"id": "fixture", "status": verdict}]}))
raise SystemExit(rc)
'''


INSTALL_STUB = r'''#!/usr/bin/env bash
set -euo pipefail
[ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] || exit 97
if [ "${AIRLOCK_TEST_REQUIRE_INHERITED_LOCK:-0}" = 1 ]; then
  python3 - "$AIRLOCK_STATE_DIR/app-ledger.lock" "${AIRLOCK_LEDGER_LOCK_FD:-}" <<'PY'
import fcntl, os, sys
path, raw_fd = sys.argv[1:]
if not raw_fd.isdigit():
    raise SystemExit(78)
inherited = int(raw_fd)
inherited_stat, path_stat = os.fstat(inherited), os.stat(path)
if (inherited_stat.st_dev, inherited_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
    raise SystemExit(79)
fcntl.flock(inherited, fcntl.LOCK_EX | fcntl.LOCK_NB)
contender = os.open(path, os.O_RDWR)
try:
    try:
        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise SystemExit(80)
finally:
    os.close(contender)
PY
fi
mkdir -p "$AIRLOCK_STATE_DIR"
if [ "${AIRLOCK_TEST_INSTALL_FAIL:-0}" = 1 ]; then
  printf '%s\n' '{"version":1,"entries":{"notes":{"committed":{"path":"/partial","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}' >"$AIRLOCK_STATE_DIR/app-ledger.json"
  : >"$AIRLOCK_STATE_DIR/app-ledger.lock"
  exit 42
fi
printf '%s\n' '{"version":1,"entries":{"notes":{"committed":{"path":"/fresh","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}' >"$AIRLOCK_STATE_DIR/app-ledger.json"
printf '%s\n' '{"version":1,"entries":[]}' >"$AIRLOCK_STATE_DIR/plaintext-retirement.json"
: >"$AIRLOCK_STATE_DIR/app-ledger.lock"
'''


CONFIG = '''\
[airlock]
config_version = 2
[site]
name = "Backup Fixture"
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.hub]
https_port = 443
[packages.notes]
path = "./package-notes"
[apps.notes]
token_env = "AIRLOCK_NOTES_TOKEN"
token_freshness = true
token_freshness_warn_hours = 24
token_freshness_stale_hours = 24
# secret_ttl_sec = 300
'''


LEDGER = '{"version":1,"entries":{"notes":{"committed":{"path":"/source","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n'
RETIREMENT = '{"version":1,"entries":[]}\n'


class Case:
    def __init__(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="airlock-backup-test-"))
        self.root = self.temp / "repo"
        self.archive = self.temp / "box.airlock-backup"
        self.source_state = self.temp / "source-state"
        self.restore_state = self.temp / "restore-state"
        self.stub = self.temp / "stub-bin"
        self.stub.mkdir()
        (self.root / "bin").mkdir(parents=True)
        (self.root / "install").mkdir()
        shutil.copy2(TOOL, self.root / "bin" / "airlock-backup")
        shutil.copy2(LEDGER_TOOL, self.root / "bin" / "airlock-ledger")
        self.write(self.root / "bin" / "airlock-config", CONFIG_STUB)
        self.write(self.root / "bin" / "airlock-status", STATUS_STUB)
        self.write(self.root / "install" / "airlock-install.sh", INSTALL_STUB)
        self.write(self.stub / "tailscale", r'''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] != ["serve", "status", "--json"]:
    raise SystemExit(2)
print(json.dumps({"TCP": {"443": {}}} if os.environ.get("AIRLOCK_TEST_SERVE_BUSY") else {}))
''')
        (self.stub / "tailscale").chmod(0o755)
        (self.root / "package-notes").mkdir()
        self.write(self.root / "package-notes" / "README.md", "fixture package\n")
        self.write(self.root / "tracked.txt", "fixture\n")
        self.write(self.root / ".gitignore", "airlock.toml\nhub/assets/.env\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.com",
                 "commit", "-q", "-m", "fixture")
        self.seed_source()

    def cleanup(self):
        shutil.rmtree(self.temp)

    @staticmethod
    def write(path: pathlib.Path, text: str):
        path.write_text(text)
        path.chmod(0o644)

    def git(self, *args):
        subprocess.run(["git", "-C", self.root, *args], check=True)

    def seed_source(self):
        self.source_state.mkdir(exist_ok=True)
        self.write(self.root / "airlock.toml", CONFIG)
        self.write(self.root / "airlock.lock", "notes digest\n")
        self.write(self.source_state / "app-ledger.json", LEDGER)
        self.write(self.source_state / "plaintext-retirement.json", RETIREMENT)

    def fresh_target(self):
        (self.root / "airlock.toml").unlink(missing_ok=True)
        (self.root / "airlock.lock").unlink(missing_ok=True)
        shutil.rmtree(self.source_state, ignore_errors=True)
        shutil.rmtree(self.restore_state, ignore_errors=True)

    def run(self, *args, env=None):
        selected = os.environ.copy()
        selected.update({
            "PATH": str(self.stub) + os.pathsep + selected["PATH"],
            "AIRLOCK_WEBROOT": str(self.temp / "platform" / "hub"),
            "AIRLOCK_CONFD": str(self.temp / "platform" / "nginx"),
            "AIRLOCK_NGINX_SITE": str(self.temp / "platform" / "airlock.conf"),
            "AIRLOCK_UNIT_DIR_USER": str(self.temp / "platform" / "units"),
        })
        if env:
            selected.update(env)
        return subprocess.run([sys.executable, self.root / "bin" / "airlock-backup", *map(str, args)],
                              cwd=self.root, env=selected, capture_output=True, text=True)


passed = 0
failed = 0


def check(condition: bool, label: str, detail: str = ""):
    global passed, failed
    if condition:
        passed += 1
        print(f"ok {passed} - {label}")
    else:
        failed += 1
        print(f"not ok - {label}{': ' + detail if detail else ''}")


def tracked_mode(path: pathlib.Path) -> str:
    relative = path.resolve().relative_to(SOURCE_ROOT)
    line = subprocess.check_output(
        ["git", "-C", SOURCE_ROOT, "ls-files", "-s", "--", relative], text=True).strip()
    return line.split()[0] if line else ""


case = Case()
try:
    created = case.run("create", case.archive, "--state-dir", case.source_state,
                       env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(created.returncode == 0 and "status_rc=0" in created.stdout,
          "healthy source creates a backup with an exact status verdict", created.stderr)
    check(stat.S_IMODE(case.archive.stat().st_mode) == 0o600,
          "backup archive is private mode 0600")
    with zipfile.ZipFile(case.archive) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        archived_config = archive.read("config.toml")
    check(names == {"manifest.json", "config.toml", "status.json",
                    "records/app-ledger.json", "records/plaintext-retirement.json",
                    "records/airlock.lock"},
          "archive contains only the fixed config/install-record set", repr(sorted(names)))
    check("airlock.lock" not in names,
          "untracked package lock is captured only through its fixed record member")
    check(manifest["excluded"] == ["app-created-data", "home-directory",
                                    "secret-environment-files", "tokens-and-credentials"],
          "manifest pins the rejected home/app-data/secret scope")
    check(b"secret_ttl_sec = 300" in archived_config,
          "credential-lifetime metadata is not mistaken for credential material")

    ambient_snapshot = case.temp / "ambient-snapshot.toml"
    case.write(ambient_snapshot, "not valid TOML = [\n")
    ambient_archive = case.temp / "ambient-authority.airlock-backup"
    ambient_result = case.run(
        "create", ambient_archive, "--state-dir", case.source_state,
        env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml"),
             "AIRLOCK_CONFIG_SNAPSHOT": str(ambient_snapshot),
             "AIRLOCK_CONFIG_SNAPSHOT_SHA256": "0" * 64,
             "AIRLOCK_DRY_RUN": "1", "AIRLOCK_LEDGER_LOCK_HELD": "1"})
    with zipfile.ZipFile(ambient_archive) as archive:
        ambient_config = archive.read("config.toml")
    check(ambient_result.returncode == 0 and ambient_config == CONFIG.encode(),
          "ambient internal authority cannot redirect or weaken backup children",
          ambient_result.stderr)

    ignored = case.root / "hub" / "assets" / ".env"
    ignored.parent.mkdir(parents=True)
    case.write(ignored, "ignored content that could change installed output\n")
    ignored_archive = case.temp / "ignored.airlock-backup"
    ignored_result = case.run("create", ignored_archive, "--state-dir", case.source_state,
                              env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(ignored_result.returncode != 0 and not ignored_archive.exists()
          and "untracked/ignored" in ignored_result.stderr,
          "ignored checkout content that can affect install output blocks backup")
    shutil.rmtree(case.root / "hub")
    overlap = case.run("create", case.source_state / "backup.zip", "--state-dir", case.source_state,
                       env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(overlap.returncode != 0 and not (case.source_state / "backup.zip").exists()
          and "outside the Airlock installed-state" in overlap.stderr,
          "backup output cannot mutate the protected installed-state directory")

    oversized_archive = case.temp / "oversized.airlock-backup"
    (case.root / "airlock.lock").write_bytes(b"x" * (32 * 1024 * 1024 + 1))
    oversized = case.run(
        "create", oversized_archive, "--state-dir", case.source_state,
        env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml"),
             "AIRLOCK_TEST_ALLOW_OVERSIZED_LOCK": "1"})
    check(oversized.returncode != 0 and not oversized_archive.exists()
          and "oversized member" in oversized.stderr,
          "create refuses a member that its own verifier would reject")
    case.write(case.root / "airlock.lock", "notes digest\n")

    case.fresh_target()
    platform_hub = case.temp / "platform" / "hub"
    platform_hub.mkdir(parents=True)
    not_fresh = case.run("restore", case.archive, "--state-dir", case.restore_state)
    check(not_fresh.returncode != 0 and "existing Airlock platform artifact" in not_fresh.stderr,
          "fresh-box preflight rejects an existing platform artifact")
    shutil.rmtree(case.temp / "platform")

    configured_unit = case.temp / "platform" / "units" / "airlock-notes.service"
    configured_unit.parent.mkdir(parents=True)
    case.write(configured_unit, "existing configured app artifact\n")
    configured_artifact = case.run("restore", case.archive, "--state-dir", case.restore_state)
    check(configured_artifact.returncode != 0
          and "configured-app artifacts" in configured_artifact.stderr,
          "fresh-box preflight rejects artifacts of apps present in the restore config")
    shutil.rmtree(case.temp / "platform")

    busy_serve = case.run("restore", case.archive, "--state-dir", case.restore_state,
                          env={"AIRLOCK_TEST_SERVE_BUSY": "1"})
    check(busy_serve.returncode != 0 and "existing Tailscale serve mappings" in busy_serve.stderr,
          "fresh-box preflight rejects existing ingress mappings")

    relocated = case.run("restore", case.archive, "--state-dir", case.restore_state,
                         "--config", case.temp / "relocated" / "airlock.toml")
    check(relocated.returncode != 0 and "relative package paths" in relocated.stderr,
          "relative package inputs keep the config parent identity")

    overlap_config = case.run("restore", case.archive, "--state-dir", case.restore_state,
                              "--config", case.root / "airlock.lock")
    check(overlap_config.returncode != 0 and "restore paths overlap" in overlap_config.stderr
          and not case.restore_state.exists(),
          "config cannot alias package-lock or create partial restore state")

    overlap_state = case.run("restore", case.archive,
                             "--state-dir", case.root / "airlock.lock" / "state")
    check(overlap_state.returncode != 0 and "outside the checkout" in overlap_state.stderr,
          "installed-state cannot nest under the package-lock sink")

    checkout_state = case.run("restore", case.archive,
                              "--state-dir", case.root / "ignored-state")
    check(checkout_state.returncode != 0 and "outside the checkout" in checkout_state.stderr
          and not (case.root / "ignored-state").exists(),
          "restore refuses installed state inside the checkout before any write")

    failed_restore = case.run("restore", case.archive, "--state-dir", case.restore_state,
                              env={"AIRLOCK_TEST_INSTALL_FAIL": "1"})
    receipt = case.restore_state / "restore-in-progress.json"
    check(failed_restore.returncode != 0 and receipt.is_file() and "--resume" in failed_restore.stderr,
          "installer failure leaves a scoped receipt and an explicit retry path", failed_restore.stderr)
    prepared = json.loads(receipt.read_text())
    prepared["phase"] = "prepared"
    case.write(receipt, json.dumps(prepared, sort_keys=True, separators=(",", ":")) + "\n")
    (case.restore_state / "app-ledger.json").unlink()
    (case.restore_state / "plaintext-retirement.json").unlink(missing_ok=True)
    (case.root / "airlock.toml").unlink()
    (case.root / "airlock.lock").unlink()
    incomplete_resume = case.run("restore", "--resume", case.archive,
                                 "--state-dir", case.restore_state,
                                 env={"AIRLOCK_TEST_STATUS_RC": "3",
                                      "AIRLOCK_TEST_REQUIRE_INHERITED_LOCK": "1"})
    check(incomplete_resume.returncode == 3 and receipt.is_file()
          and (case.root / "airlock.toml").is_file() and (case.root / "airlock.lock").is_file()
          and json.loads(receipt.read_text())["phase"] == "installing"
          and "restore=ok" not in incomplete_resume.stdout,
          "negative control: prepared resume holds one writer lock through installer handoff")
    restored = case.run("restore", "--resume", case.archive, "--state-dir", case.restore_state,
                        env={"AIRLOCK_TEST_REQUIRE_INHERITED_LOCK": "1"})
    check(restored.returncode == 0 and "status_rc=0" in restored.stdout,
          "receipt-bound retry restores, installs, and reaches exact status rc=0", restored.stderr)
    check(not receipt.exists(), "successful restore removes the retry receipt")
    check((case.root / "airlock.toml").read_text() == CONFIG
          and (case.root / "airlock.lock").read_text() == "notes digest\n",
          "restore reproduces exact config and package lock bytes")
    check(json.loads((case.restore_state / "app-ledger.json").read_text())
          ["entries"]["notes"]["committed"]["path"] == "/fresh",
          "restore creates a fresh ledger instead of transplanting source teardown authority")
    alternate = case.temp / "alternate-git"
    alternate.mkdir()
    (alternate / "tracked.txt").write_text("alternate\n")
    subprocess.run(["git", "-C", alternate, "init", "-q"], check=True)
    subprocess.run(["git", "-C", alternate, "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", alternate, "-c", "user.name=fixture",
                    "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "alternate"],
                   check=True)
    verified = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(verified.returncode == 0 and "restore-verdict=ok" in verified.stdout,
          "verification command checks archive bytes, app set, and status", verified.stderr)
    redirected_clean = case.run("verify", case.archive, "--state-dir", case.restore_state,
                                env={"GIT_DIR": str(alternate / ".git"),
                                     "GIT_WORK_TREE": str(alternate)})
    check(redirected_clean.returncode == 0 and "restore-verdict=ok" in redirected_clean.stdout,
          "ambient Git authority is stripped from status/config child processes")

    status_failed = case.run("verify", case.archive, "--state-dir", case.restore_state,
                             env={"AIRLOCK_TEST_STATUS_RC": "1"})
    check(status_failed.returncode == 1 and "restore-verdict=ok" not in status_failed.stdout,
          "negative control: status rc=1 can never become restore success")

    case.write(case.root / "airlock.toml", CONFIG + "# harmless change\n")
    config_mismatch = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(config_mismatch.returncode != 0 and "config bytes differ" in config_mismatch.stderr,
          "negative control: config byte mismatch cannot verify green")
    case.write(case.root / "airlock.toml", CONFIG)

    case.write(case.root / "airlock.lock", "different digest\n")
    lock_mismatch = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(lock_mismatch.returncode != 0 and "package lock differs" in lock_mismatch.stderr,
          "negative control: package-lock mismatch cannot verify green")
    case.write(case.root / "airlock.lock", "notes digest\n")

    ledger_path = case.restore_state / "app-ledger.json"
    restored_ledger = ledger_path.read_text()
    case.write(ledger_path, LEDGER.replace('"notes"', '"other"').replace('/source', '/fresh'))
    app_mismatch = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(app_mismatch.returncode != 0 and "app set differs" in app_mismatch.stderr,
          "negative control: restored app-set mismatch cannot verify green")
    case.write(ledger_path, restored_ledger)

    retirement_path = case.restore_state / "plaintext-retirement.json"
    case.write(retirement_path, '{"version":1,"entries":[{"listen":1234}]}\n')
    retirement_mismatch = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(retirement_mismatch.returncode != 0 and "retirement" in retirement_mismatch.stderr,
          "negative control: retirement-record mismatch cannot verify green")
    case.write(retirement_path, RETIREMENT)

    case.write(case.root / "tracked.txt", "dirty fixture\n")
    dirty = case.run("verify", case.archive, "--state-dir", case.restore_state,
                     env={"GIT_DIR": str(alternate / ".git"),
                          "GIT_WORK_TREE": str(alternate)})
    check(dirty.returncode != 0 and "clean tracked Airlock checkout" in dirty.stderr,
          "negative control: ambient Git indirection cannot hide a dirty checkout")
    case.write(case.root / "tracked.txt", "fixture\n")

    incomplete = case.run("verify", case.archive, "--state-dir", case.restore_state,
                          env={"AIRLOCK_TEST_STATUS_RC": "3"})
    check(incomplete.returncode == 3 and "restore-verdict=ok" not in incomplete.stdout
          and "rc=3 is not success" in incomplete.stderr,
          "negative control: status rc=3 can never become restore success")

    existing_ledger = case.restore_state / "app-ledger.json"
    before = existing_ledger.read_bytes()
    refused = case.run("restore", case.archive, "--state-dir", case.restore_state)
    check(refused.returncode != 0 and existing_ledger.read_bytes() == before
          and "fresh restore refuses" in refused.stderr,
          "restore refuses to overwrite an existing installation")

    broken = case.temp / "broken.airlock-backup"
    with zipfile.ZipFile(case.archive) as source, zipfile.ZipFile(broken, "w") as target:
        for info in source.infolist():
            data = source.read(info.filename)
            target.writestr(info.filename, data + b"tampered" if info.filename == "config.toml" else data)
    broken_verify = case.run("verify", broken, "--state-dir", case.restore_state)
    check(broken_verify.returncode != 0 and "digest mismatch" in broken_verify.stderr,
          "payload corruption without a matching manifest update is detected")

    record_secret_value = "must-not-appear-in-diagnostics"
    secret_record = case.temp / "secret-record.airlock-backup"
    with zipfile.ZipFile(case.archive) as source:
        payload = {info.filename: source.read(info.filename) for info in source.infolist()}
    retirement_secret = json.dumps({"version": 1, "entries": {
        "credential": record_secret_value,
    }}, separators=(",", ":")).encode() + b"\n"
    manifest_secret = json.loads(payload["manifest.json"])
    manifest_secret["files"]["plaintext-retirement.json"]["sha256"] = hashlib.sha256(retirement_secret).hexdigest()
    payload["records/plaintext-retirement.json"] = retirement_secret
    payload["manifest.json"] = (json.dumps(manifest_secret, sort_keys=True,
                                            separators=(",", ":")) + "\n").encode()
    with zipfile.ZipFile(secret_record, "w") as target:
        for name, data in payload.items():
            target.writestr(name, data)
    unsafe_record = case.run("verify", secret_record, "--state-dir", case.restore_state)
    check(unsafe_record.returncode != 0 and "plaintext-retirement.json" in unsafe_record.stderr
          and record_secret_value not in unsafe_record.stderr,
          "install-record members reject secret-shaped data without printing values")

    bad_ledger_archive = case.temp / "bad-ledger-shape.airlock-backup"
    with zipfile.ZipFile(case.archive) as source:
        payload = {info.filename: source.read(info.filename) for info in source.infolist()}
    bad_ledger = b'{"version":999,"entries":{},"events":[]}\n'
    bad_manifest = json.loads(payload["manifest.json"])
    bad_manifest["files"]["app-ledger.json"]["sha256"] = hashlib.sha256(bad_ledger).hexdigest()
    payload["records/app-ledger.json"] = bad_ledger
    payload["manifest.json"] = (json.dumps(bad_manifest, sort_keys=True,
                                            separators=(",", ":")) + "\n").encode()
    with zipfile.ZipFile(bad_ledger_archive, "w") as target:
        for name, data in payload.items():
            target.writestr(name, data)
    bad_ledger_result = case.run("verify", bad_ledger_archive,
                                 "--state-dir", case.restore_state)
    check(bad_ledger_result.returncode != 0 and "canonical install-ledger shape" in bad_ledger_result.stderr,
          "install ledger must satisfy the canonical versioned record grammar")

    bad_retirement_archive = case.temp / "bad-retirement-shape.airlock-backup"
    with zipfile.ZipFile(case.archive) as source:
        payload = {info.filename: source.read(info.filename) for info in source.infolist()}
    bad_retirement = b'{"version":1,"entries":{}}\n'
    bad_manifest = json.loads(payload["manifest.json"])
    bad_manifest["files"]["plaintext-retirement.json"]["sha256"] = hashlib.sha256(bad_retirement).hexdigest()
    payload["records/plaintext-retirement.json"] = bad_retirement
    payload["manifest.json"] = (json.dumps(bad_manifest, sort_keys=True,
                                            separators=(",", ":")) + "\n").encode()
    with zipfile.ZipFile(bad_retirement_archive, "w") as target:
        for name, data in payload.items():
            target.writestr(name, data)
    bad_retirement_result = case.run("verify", bad_retirement_archive,
                                     "--state-dir", case.restore_state)
    check(bad_retirement_result.returncode != 0 and "entries must be a list" in bad_retirement_result.stderr,
          "retirement record must satisfy its exact list-entry grammar")

    case.write(case.root / "tracked.txt", "different clean tree\n")
    case.git("add", "tracked.txt")
    case.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.com",
             "commit", "-q", "-m", "different tree")
    different_tree = case.run("verify", case.archive, "--state-dir", case.restore_state)
    check(different_tree.returncode != 0 and "checkout tree differs" in different_tree.stderr,
          "same-purpose checkout with different tracked content cannot verify green")

    case.fresh_target()
    case.seed_source()
    case.archive.unlink()
    not_checked = case.run("create", case.archive, "--state-dir", case.source_state,
                           env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml"),
                                "AIRLOCK_TEST_STATUS_RC": "3"})
    check(not_checked.returncode == 3 and not case.archive.exists()
          and "rc=3 is not success" in not_checked.stderr,
          "negative control: an incompletely checked source produces no backup")

    secret_value = "do-not-print-this-value"
    (case.root / "airlock.toml").write_text(CONFIG + f'# api_token = {secret_value}\n')
    secret_archive = case.temp / "secret.airlock-backup"
    secret = case.run("create", secret_archive, "--state-dir", case.source_state,
                      env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(secret.returncode != 0 and not secret_archive.exists()
          and "comment-line" in secret.stderr and secret_value not in secret.stderr,
          "possible secrets in config comments are refused without printing the value")

    quoted_numeric = "1234567890"
    (case.root / "airlock.toml").write_text(CONFIG + f'# secret_ttl_sec = "{quoted_numeric}"\n')
    quoted_archive = case.temp / "quoted-secret.airlock-backup"
    quoted = case.run("create", quoted_archive, "--state-dir", case.source_state,
                      env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(quoted.returncode != 0 and not quoted_archive.exists()
          and "comment-line" in quoted.stderr and quoted_numeric not in quoted.stderr,
          "quoted numeric secret-like values are not admitted as integer metadata")

    metadata_misuse = "must-not-print-this-value"
    (case.root / "airlock.toml").write_text(
        CONFIG + f'secret_ttl_sec = "{metadata_misuse}"\n')
    metadata_archive = case.temp / "metadata-misuse.airlock-backup"
    unsafe_metadata = case.run("create", metadata_archive, "--state-dir", case.source_state,
                               env={"AIRLOCK_CONFIG": str(case.root / "airlock.toml")})
    check(unsafe_metadata.returncode != 0 and not metadata_archive.exists()
          and "secret_ttl_sec" in unsafe_metadata.stderr
          and metadata_misuse not in unsafe_metadata.stderr,
          "safe metadata names accept only their exact non-secret value type")

finally:
    case.cleanup()

check(tracked_mode(TOOL) == "100644",
      "production backup tool remains mode 100644 and is invoked through python3")
check(tracked_mode(pathlib.Path(__file__)) == "100644",
      "new install test remains mode 100644 and is invoked through python3")

print(f"passed={passed} failed={failed}")
raise SystemExit(0 if failed == 0 else 1)
