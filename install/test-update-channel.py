#!/usr/bin/env python3
"""UPDATE_CHANNEL scenarios inside the reviewed rootless managed-lifecycle fixture.

`install/test-update.sh --case=managed-app-lifecycle --update-channel` builds the same
private namespace as the A5/A6 lifecycle case and hands this driver the writer seat.
Every observation below is read back from what the real `bin/airlock-update`, the real
installer/ledger and the real managed state/release commands left on disk. A product
mutant is a byte copy of the updater with one planted defect; it runs against the same
restored box so a green verdict cannot be a property of the harness alone.

  setup   outside the namespace: sign extra release variants next to stage-1/2
  run     inside the namespace as the writer: execute scenarios and print AC lines
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

FIXTURE = pathlib.Path("/fixture")
WORK = pathlib.Path("/work")
UPDATER = WORK / "bin/airlock-update"
STATE_CLI = WORK / "bin/airlock-managed-state"
NAMESPACE = pathlib.Path("/var/lib/airlock/managed/1000")
MUTABLE_ROOTS = (
    FIXTURE / "box", FIXTURE / "state", FIXTURE / "data", FIXTURE / "service-state",
    FIXTURE / "app-data", NAMESPACE, pathlib.Path("/etc/nginx"),
)
COMMON_ENV = {
    "AIRLOCK_DIR": "/fixture/box", "AIRLOCK_RELEASE_URL": "/fixture/public",
    "AIRLOCK_CONFIG": "/fixture/box/airlock.toml", "AIRLOCK_STATE_DIR": "/fixture/state",
    "AIRLOCK_WEBROOT": "/fixture/data/webroot", "AIRLOCK_CONFD": "/fixture/data/confd",
    "AIRLOCK_UNIT_DIR_USER": "/fixture/data/units-user",
    "AIRLOCK_UNIT_DIR_SYSTEM": "/fixture/data/units-system",
    "AIRLOCK_AVAILABLE_APP_DATA_ROOT": "/fixture/app-data/available-app",
    "AIRLOCK_TS_FQDN": "box.example.ts.net",
}


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def tree_digest(root: pathlib.Path) -> str:
    """Path, type, mode and bytes of everything below root; absent is its own value."""
    if not root.exists() and not root.is_symlink():
        return "absent"
    digest = hashlib.sha256()
    paths = [root] + sorted(root.rglob("*")) if root.is_dir() else [root]
    for path in paths:
        info = path.lstat()
        relative = path.relative_to(root).as_posix() if path != root else "."
        digest.update(f"{relative}\0{info.st_mode:o}\0".encode())
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
        digest.update(b"\n")
    return "sha256:" + digest.hexdigest()


def box_state() -> dict[str, str]:
    """Every mutable surface an update may touch, one digest per surface."""
    return {str(root): tree_digest(root) for root in MUTABLE_ROOTS}


def snapshot(label: str) -> pathlib.Path:
    target = FIXTURE / "uc/snapshots" / label
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    for index, root in enumerate(MUTABLE_ROOTS):
        destination = target / str(index)
        if root.exists():
            shutil.copytree(root, destination, symlinks=True)
    return target


def restore(saved: pathlib.Path) -> None:
    for index, root in enumerate(MUTABLE_ROOTS):
        source = saved / str(index)
        if root.exists():
            for child in root.iterdir():
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        if source.exists():
            root.mkdir(exist_ok=True)
            shutil.copystat(source, root)
            for child in source.iterdir():
                if child.is_dir() and not child.is_symlink():
                    shutil.copytree(child, root / child.name, symlinks=True)
                else:
                    shutil.copy2(child, root / child.name, follow_symlinks=False)


def run(argv, *, env=None, log: pathlib.Path | None = None) -> int:
    merged = dict(os.environ)
    merged.update(env or {})
    with (open(log, "wb") if log else open(os.devnull, "wb")) as handle:
        return subprocess.run(argv, env=merged, stdout=handle, stderr=subprocess.STDOUT).returncode


def update(label: str, revision: str, *args: str, updater: pathlib.Path = UPDATER) -> tuple[int, str]:
    log = FIXTURE / "uc/logs" / f"{label}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    rc = run(["bash", str(updater), *args],
             env=dict(COMMON_ENV, AIRLOCK_RELEASE_REF=revision), log=log)
    return rc, log.read_text(errors="replace")


def select(label: str, release: str, snapshot_digest: str, rows, sequence: int, at: str) -> None:
    selection = FIXTURE / "uc" / f"selection-{label}.json"
    selection.parent.mkdir(parents=True, exist_ok=True)
    selection.write_bytes(canonical({
        "organization_id": "fixture-org", "schema": "airlock.managed.selection/v1",
        "selections": [{"id": app, "source": source} for app, source in rows],
        "sequence": sequence, "snapshot_digest": snapshot_digest,
    }))
    selection.chmod(0o600)
    rc = run(["python3", str(STATE_CLI), "select",
              "--state", str(NAMESPACE / "managed-state.json"), "--release", release,
              "--authority", str(NAMESPACE / "authority"), "--selection", str(selection),
              "--at", at], log=FIXTURE / "uc/logs" / f"select-{label}.log")
    if rc:
        raise SystemExit(f"fixture selection {label} failed rc={rc}")


def ledger_entry(app: str):
    path = FIXTURE / "state/app-ledger.json"
    if not path.exists():
        return None
    return json.loads(path.read_text()).get("entries", {}).get(app)


def physical_root(variable: str) -> pathlib.Path:
    raw = os.environ[variable]
    path = pathlib.Path(raw)
    if not path.is_absolute() or os.path.normpath(raw) != raw or path.resolve(strict=True) != path:
        raise SystemExit(f"{variable} must be an absolute canonical non-symlink path")
    return path


def command_setup() -> int:
    """Sign the release variants the refusal scenarios need, next to stage-1/2.

    Each variant is the reviewed v2 package tree with one field changed, so the refusal
    it triggers is the only difference from a release that installs.
    """
    import importlib.util

    source_root = physical_root("AIRLOCK_FIXTURE_INPUT_ROOT")
    fixture = physical_root("AIRLOCK_FIXTURE_OUTPUT_ROOT")
    spec = importlib.util.spec_from_file_location(
        "state_fixture", source_root / "install/test-managed-state.py")
    state_fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(state_fixture)
    release_fixture = state_fixture.RF
    release_cli = source_root / "bin/airlock-managed-release"
    reviewed = fixture / "review-2/release-src"
    reviews = fixture.parent / "uc-review"
    reviews.mkdir()

    def variant(name: str, sequence: int, *, catalog_patch=None, lock_patch=None,
                release_patch=None, drop=()):
        review = reviews / name
        source = review / "release-src"
        shutil.copytree(reviewed, source)
        package = source / "packages/available-app"
        for relative in drop:
            (package / relative).unlink()
        files = {
            path.relative_to(package).as_posix(): (path.lstat().st_mode & 0o7777, path.read_bytes())
            for path in sorted(package.rglob("*")) if path.is_file()
        }
        catalog = json.loads((source / "catalog.json").read_text())
        lock = json.loads((source / "release.lock").read_text())
        lock["packages"][0]["digest"] = release_fixture.package_digest(files)
        if catalog_patch:
            catalog_patch(catalog)
        if lock_patch:
            lock_patch(lock)
        if release_patch:
            release_patch(catalog, lock, source)
        (source / "catalog.json").write_bytes(canonical(catalog))
        (source / "release.lock").write_bytes(canonical(lock))
        for argv in (("init", "-q", "-b", "main", "--template="),
                     ("config", "user.name", "managed-e2e"),
                     ("config", "user.email", "managed-e2e@example.invalid"),
                     ("config", "gc.auto", "0"), ("add", "-A")):
            subprocess.run(["git", "-C", str(review), *argv], check=True,
                           stdout=subprocess.DEVNULL)
        fixed = dict(os.environ, GIT_AUTHOR_DATE="2026-09-12T01:00:00Z",
                     GIT_COMMITTER_DATE="2026-09-12T01:00:00Z")
        subprocess.run(["git", "-C", str(review), "commit", "-q", "-m", f"reviewed {name}"],
                       env=fixed, check=True)
        revision = subprocess.run(["git", "-C", str(review), "rev-parse", "HEAD"],
                                  stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
        stage = fixture / f"uc-stage-{name}"
        subprocess.run([
            "python3", str(release_cli), "prepare", "--source-repo", str(review),
            "--revision", revision, "--input-prefix", "release-src",
            "--source-repository", "fixture/e2e", "--organization", "fixture-org",
            "--channel", "stable", "--epoch", "1", "--sequence", str(sequence),
            "--publisher", "publisher-a", "--created-at", "2026-09-12T01:00:00Z",
            "--ci-evidence-digest", "sha256:" + "a" * 64, "--out", str(stage),
        ], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([
            "python3", str(release_cli), "sign", "--stage", str(stage),
            "--publisher-key", str(fixture / "publisher.pem"),
        ], check=True, stdout=subprocess.DEVNULL)
        digest = "sha256:" + hashlib.sha256((stage / "snapshot.json").read_bytes()).hexdigest()
        return {"stage": f"/fixture/{stage.name}", "digest": digest}

    def set_profiles(catalog):
        catalog["apps"][0]["compatibility"]["profiles"] = ["linux-aarch64"]

    def block_and_keep_other(catalog, lock, source):
        # A blocked app is display data only: the publisher tool refuses a lock row
        # for it, and it cannot stage a release with no package at all, so a second,
        # unselected available app carries the release.
        catalog["apps"][0]["policy"] = "blocked"
        keeper = source / "packages/keeper-app"
        (source / "packages/available-app").rename(keeper)
        manifest = keeper / "airlock-app.toml"
        manifest.write_text(manifest.read_text().replace(
            'id = "available-app"', 'id = "keeper-app"'))
        files = {
            path.relative_to(keeper).as_posix(): (path.lstat().st_mode & 0o7777, path.read_bytes())
            for path in sorted(keeper.rglob("*")) if path.is_file()
        }
        row = dict(catalog["apps"][0], id="keeper-app", policy="available")
        catalog["apps"] = sorted([catalog["apps"][0], row], key=lambda item: item["id"])
        package = dict(lock["packages"][0], id="keeper-app", path="packages/keeper-app",
                       digest=release_fixture.package_digest(files))
        lock["packages"] = [package]

    def set_maintenance(lock):
        lock["packages"][0]["data_compatibility"] = "maintenance-required"

    variants = {
        "host-incompatible": variant("host-incompatible", 11, catalog_patch=set_profiles),
        "maintenance": variant("maintenance", 12, lock_patch=set_maintenance),
        "lifecycle-missing": variant("lifecycle-missing", 13, drop=("deactivate.sh",)),
        "blocked": variant("blocked", 14, release_patch=block_and_keep_other),
    }
    shutil.rmtree(reviews)
    (fixture / "uc-meta.json").write_bytes(canonical(
        {"source_revision": os.environ["SOURCE_REVISION"], "variants": variants}))
    return 0


def mutant(name: str, old: str, new: str) -> pathlib.Path:
    """A byte copy of the real updater with exactly one planted defect."""
    target = FIXTURE / "uc/mutants" / name / "airlock-update"
    target.parent.mkdir(parents=True, exist_ok=True)
    source = UPDATER.read_text()
    if source.count(old) != 1:
        raise SystemExit(f"mutant {name}: anchor is not unique ({source.count(old)})")
    target.write_text(source.replace(old, new, 1))
    return target


# Each planted defect is the absence of one product refusal this card added or owns.
PREFLIGHT_CALL = '''    managed_release_preflight \\
      "$managed_context" "$(managed_file_line "$scratch/current-release-path")" \\
      "$managed_current_digest" "$(platform)" "$(uname -m)" \\
      "$scratch/preflight-selected" \\
      || die "managed current release 의 host/policy/lifecycle preflight 에 실패했습니다 — 파일을 바꾸지 않았습니다"'''
COMPATIBILITY_CHECK = '''    if host_os not in compatibility["platforms"] or host_profile not in compatibility["profiles"]:
        fail(f"managed app {app_id!r} is incompatible with measured host facts",
             "app-host-incompatible")'''
MAINTENANCE_CHECK = '''            and package.get("data_compatibility") == "maintenance-required"):
            fail(f"managed app {app_id!r} requires an operator-owned maintenance procedure",
                 "upgrade-maintenance-required")'''
LIFECYCLE_CHECK = '''        executable(lifecycle, f"managed app {app_id!r} lifecycle {lifecycle}")'''
REMOVAL_CHECK = '''            fail(f"managed removal for {app_id!r} is not executed by the updater "
                 f"(catalog policy {policy!r})", reason)'''

MUTANTS = {
    "preflight_skipped": (PREFLIGHT_CALL, "    true"),
    "app_host_incompatible": (COMPATIBILITY_CHECK, "    if False:\n        pass"),
    "upgrade_maintenance_required": (
        MAINTENANCE_CHECK, '''            and package.get("data_compatibility") == "never"):
            pass'''),
    "lifecycle_incomplete": (LIFECYCLE_CHECK, "        pass"),
    "removal_refused": (REMOVAL_CHECK, "            continue"),
}


REFRESH_CALL = '''      managed_capture "$scratch/managed-refresh.json" \\
        python3 "$ROOT/bin/airlock-managed-state" refresh-installed \\
          --source "$managed_release_source" --at "$managed_request_at" \\
        || die "managed local candidate 를 고정된 installed channel 에 반영하지 못했습니다"
      managed_refresh_matches_request \\
        "$scratch/managed-refresh.json" "$managed_snapshot_digest" \\
        || die "managed refresh 결과가 요청한 exact snapshot 과 다릅니다"'''
SELECT_ARGS = '''    managed_installer_args+=("--select-app=$managed_app")
  done <"$scratch/selected-apps"'''
SCOPED_INSTALLER = '''  AIRLOCK_CONFIG="$config_path" bash "$repository/install/airlock-install.sh" \\
    "${managed_installer_args[@]}"'''

# Install/upgrade defects: the requested candidate is never imported, the selection
# is dropped or widened to an unrelated app, or the scoped executor is bypassed.
UC2_MUTANTS = {
    "candidate_not_imported": (REFRESH_CALL, "      :"),
    "selection_dropped": (SELECT_ARGS, "    :\n  done <\"$scratch/selected-apps\""),
    "unrelated_app_selected": (SELECT_ARGS, SELECT_ARGS + '''
  managed_installer_args+=("--select-app=baseapp")'''),
    "scoped_executor_bypassed": (SCOPED_INSTALLER,
        '''  AIRLOCK_CONFIG="$config_path" bash "$repository/install/airlock-install.sh"'''),
}


def lock_digest(release: str, app: str) -> str | None:
    lock = json.loads((pathlib.Path(release) / "release.lock").read_text())
    return next((row["digest"] for row in lock["packages"] if row["id"] == app), None)


def app_surface(app: str) -> dict[str, object]:
    """What the box actually runs for one app: ledger row, files, unit, service state."""
    service = FIXTURE / "service-state"
    return {
        "ledger": ledger_entry(app),
        "webroot": tree_digest(FIXTURE / "data/webroot" / app),
        "unit": tree_digest(FIXTURE / "data/units-user" / f"airlock-{app}.service"),
        "active": (service / f"airlock-{app}.service.active").exists(),
        "enabled": (service / f"airlock-{app}.service.enabled").exists(),
    }


def installed_release(release: str, digest: str, version: str) -> dict[str, object]:
    """Read back whether available-app is installed exactly as the requested release."""
    committed = (ledger_entry("available-app") or {}).get("committed") or {}
    authority = committed.get("managed_authority") or {}
    marker = FIXTURE / "data/webroot/available-app/marker"
    surface = app_surface("available-app")
    return {
        "snapshot_bound": authority.get("snapshot_digest") == digest,
        "package_bound": authority.get("package_digest") == lock_digest(release, "available-app"),
        "source_class": committed.get("source_class"),
        "marker": marker.read_text().strip() if marker.exists() else None,
        "running": bool(surface["active"] and surface["enabled"]),
        "version_ok": marker.exists() and marker.read_text().strip() == version,
    }


def install_case(label: str, base: pathlib.Path, *, release: str, digest: str, version: str,
                 sequence: int, revision: str, source: bool,
                 updater: pathlib.Path) -> dict[str, object]:
    restore(base)
    select(f"{label}-{updater.parent.name}", release, digest,
           [("available-app", "managed")], sequence, f"2026-09-12T06:{sequence:02d}:00Z")
    unrelated_before = app_surface("baseapp")
    arguments = [f"--managed-snapshot-digest={digest}"]
    if source:
        arguments.insert(0, f"--managed-release-source={release}")
    rc, _ = update(f"{label}-{updater.parent.name}", revision, *arguments, updater=updater)
    observed = installed_release(release, digest, version)
    observed.update({"rc": rc, "unrelated_unchanged": app_surface("baseapp") == unrelated_before})
    return observed


def installed_exactly(observed: dict[str, object]) -> bool:
    return (observed["rc"] == 0 and bool(observed["snapshot_bound"])
            and bool(observed["package_bound"]) and observed["source_class"] == "managed"
            and bool(observed["version_ok"]) and bool(observed["running"])
            and bool(observed["unrelated_unchanged"]))


AUTO_RECOVERY = '''      rollback_update "$ROOT" "$machine" "$MACHINE_MARKER" || recovery_rc=$?'''
RECEIPT_DIRECTORY = '''directory = state_dir / "update-channel-receipts"'''
RECEIPT_PREVIOUS = '''    "previous_managed": previous,'''

# Recovery defects: the updater claims recovery without performing it, keeps its
# receipt only in the run directory it deletes, or drops the prior installed release.
UC4_MUTANTS = {
    "recovery_not_performed": (AUTO_RECOVERY, "      :"),
    "receipt_not_durable": (RECEIPT_DIRECTORY,
                            'directory = scratch / "update-channel-receipts"'),
    "receipt_previous_unbound": (RECEIPT_PREVIOUS, '    "previous_managed": {},'),
}


# Store-view defects: a refresh that falls through into an install, a same-release row
# that still offers an update, a hidden cache age, a hidden recovery predecessor.
UC1_MUTANTS = {
    "refresh_falls_through": ('''    return 0
  fi
  local managed_context=""''', '''  fi
  local managed_context=""'''),
    "same_release_offers_update": ("    elif installed_digest != candidate_digest:",
                                   "    elif installed_digest is not None:"),
    "cache_age_hidden": (
        '        "cache_age_seconds": int((moment(at) - moment(refreshed_at)).total_seconds()),',
        '        "cache_age_seconds": None,'),
    "predecessor_hidden": ('    "recovery_predecessor": None if predecessor is None else {',
                           '    "recovery_predecessor": None if True else {'),
}


def store_command(label: str, revision: str, *args: str,
                  updater: pathlib.Path = UPDATER) -> tuple[int, dict | None, str]:
    """Run a store mode; its JSON is stdout, everything it says is stderr."""
    logs = FIXTURE / "uc/logs"
    stdout, stderr = logs / f"{label}.json", logs / f"{label}.log"
    merged = dict(os.environ, **COMMON_ENV, AIRLOCK_RELEASE_REF=revision)
    with open(stdout, "wb") as out, open(stderr, "wb") as err:
        rc = subprocess.run(["bash", str(updater), *args], env=merged,
                            stdout=out, stderr=err).returncode
    raw = stdout.read_bytes()
    try:
        view = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        view = None
    return rc, view if isinstance(view, dict) else None, stderr.read_text(errors="replace")


def row(view: dict | None, app: str) -> dict:
    return next((item for item in (view or {}).get("apps", []) if item.get("id") == app), {})


def git_head(repository: pathlib.Path) -> str:
    return subprocess.run(["git", "-C", str(repository), "rev-parse", "HEAD"],
                          stdout=subprocess.PIPE, text=True, check=True).stdout.strip()


def receipt_names() -> set[str]:
    directory = FIXTURE / "state/update-channel-receipts"
    return {path.name for path in directory.iterdir()} if directory.is_dir() else set()


def new_receipt(before: set[str]) -> dict:
    """The one receipt this run wrote; an older receipt in the box never answers for it."""
    created = sorted(receipt_names() - before)
    if len(created) != 1:
        return {"created": len(created)}
    return json.loads((FIXTURE / "state/update-channel-receipts" / created[0]).read_text())


def failure_case(label: str, base: pathlib.Path, *, meta: dict,
                 updater: pathlib.Path) -> dict[str, object]:
    """Force the app's install to fail after it has already changed services."""
    restore(base)
    select(f"{label}-{updater.parent.name}", meta["stage2"], meta["digest2"],
           [("available-app", "managed")], 20, "2026-09-12T07:20:00Z")
    box = FIXTURE / "box"
    before = {"head": git_head(box), "ledger": (FIXTURE / "state/app-ledger.json").read_bytes(),
              "app": app_surface("available-app"), "unrelated": app_surface("baseapp")}
    data = FIXTURE / "app-data/available-app/preserved.txt"
    existing_receipts = receipt_names()
    (FIXTURE / "fail-next").touch()
    rc, _ = update(f"{label}-{updater.parent.name}", meta["v2"],
                   f"--managed-release-source={meta['stage2']}",
                   f"--managed-snapshot-digest={meta['digest2']}", updater=updater)
    recovered = {
        "rc": rc,
        "checkout_restored": git_head(box) == before["head"],
        "recovery_record_cleared": not (box / ".git/airlock-update-rollback").exists(),
        "ledger_restored": (FIXTURE / "state/app-ledger.json").read_bytes() == before["ledger"],
        "app_restored": app_surface("available-app") == before["app"],
        "unrelated_unchanged": app_surface("baseapp") == before["unrelated"],
        "app_data_preserved": data.is_file() and data.read_text().strip() == "preserved-data",
        "guard_consumed": not (FIXTURE / "fail-next").exists(),
    }
    receipt = new_receipt(existing_receipts)
    previous = (receipt.get("previous_managed") or {}).get("available-app") or {}
    installed = (receipt.get("installed_managed") or {}).get("available-app") or {}
    transaction = receipt.get("transaction") or {}
    recovered["receipt"] = {
        "outcome": receipt.get("outcome"),
        "requested": (receipt.get("requested_release") or {}).get("snapshot_digest") == meta["digest2"],
        "publisher": (receipt.get("requested_release") or {}).get("publisher_id"),
        "previous_bound": previous.get("snapshot_digest") == meta["digest1"],
        "installed_bound": installed.get("snapshot_digest") == meta["digest1"],
        "phase": transaction.get("phase"),
        "app_receipts": sorted((transaction.get("app_receipts") or {})),
        "actor_uid": (receipt.get("actor") or {}).get("uid"),
    }
    return recovered


def recovered_and_receipted(observed: dict[str, object]) -> bool:
    receipt = observed["receipt"]
    return (observed["rc"] == 73 and observed["checkout_restored"]
            and observed["recovery_record_cleared"] and observed["ledger_restored"]
            and observed["app_restored"] and observed["unrelated_unchanged"]
            and observed["app_data_preserved"]
            and receipt["outcome"] == "recovered" and receipt["requested"]
            and receipt["previous_bound"] and receipt["installed_bound"]
            and receipt["phase"] == "rolled_back"
            and receipt["app_receipts"] == ["available-app"]
            and receipt["actor_uid"] == 1000)


def refusal(label: str, base: pathlib.Path, *, reason: str, release: str, digest: str,
            rows, sequence: int, revision: str, updater: pathlib.Path,
            digest_input: bool) -> dict[str, object]:
    """Run one policy case and report what the product left behind."""
    restore(base)
    at = f"2026-09-12T05:{sequence:02d}:00Z"
    select(f"{label}-{updater.parent.name}", release, digest, rows, sequence, at)
    before = box_state()
    arguments = [f"--managed-snapshot-digest={digest}"] if digest_input else []
    if digest_input and release.startswith("/fixture/uc-stage-"):
        arguments.insert(0, f"--managed-release-source={release}")
    rc, log = update(f"{label}-{updater.parent.name}", revision, *arguments, updater=updater)
    after = box_state()
    return {
        "rc": rc,
        "reason": reason in log,
        "unchanged": before == after,
        "installer_invocations": log.count("설치기를 다시 돌립니다"),
        "changed": sorted(key for key in before if before[key] != after[key]),
    }


def refused_before_mutation(observed: dict[str, object]) -> bool:
    """The updater's own refusal (`die`, rc 1) with its reason, and nothing changed."""
    return (observed["rc"] == 1 and bool(observed["reason"]) and bool(observed["unchanged"])
            and observed["installer_invocations"] == 0)


ACCESS_CHECK = '\n'.join([
    '  managed_access_admits_refresh "$1/access-before-refresh.json" \\',
    '    || die "reason=organization-access-$(managed_access_field "$1/access-before-refresh.json" status) 조직 snapshot 갱신이 허용되지 않는 상태입니다 — 파일을 바꾸지 않았습니다"',
])
UNCACHED_CHECK = '\n'.join([
    '    managed_cached_release_present \\',
    '      "$managed_context" "$managed_snapshot_digest" \\',
    '      || die "reason=bundle-not-cached 요청한 managed bundle 이 이 박스에 캐시되어 있지 않습니다 — 먼저 --managed-refresh 로 받아야 합니다"',
])
LAPSE_ANCHOR = '  local managed_context=""'

# Lapse defects: the updater stops noticing the access state, refuses every managed run
# once access lapses, or stops naming an uncached bundle.
UC5_MUTANTS = {
    "access_ignored": (ACCESS_CHECK, "  true"),
    "lapse_blocks_updates": (LAPSE_ANCHOR, '\n'.join([
        LAPSE_ANCHOR,
        '  if [ -e /etc/airlock/managed-access.json ]; then',
        '    die "mutant: managed access is not active"',
        '  fi',
    ])),
    "uncached_unnamed": (UNCACHED_CHECK, "    true"),
}


UNRELATED_DAMAGE_ANCHOR = '  say "설치기를 다시 돌립니다 (managed channel)…"'
UC5_MUTANTS["unrelated_damaged"] = (UNRELATED_DAMAGE_ANCHOR, '\n'.join([
    UNRELATED_DAMAGE_ANCHOR,
    '  printf "damaged\\n" >"${AIRLOCK_WEBROOT:?}/baseapp/marker"',
]))

ACCESS_PRE_STATE = FIXTURE / "uc/access-pre-state.json"


def access_context(status: str) -> tuple[dict, dict, str, pathlib.Path]:
    meta = json.loads((FIXTURE / "meta.json").read_text())
    uc_meta = json.loads((FIXTURE / "uc-meta.json").read_text())
    evidence = f"install/test-update-channel.py@{uc_meta['source_revision']}"
    return meta, uc_meta["variants"], evidence, FIXTURE / f"uc/uc5-{status}-observation.json"


def preserved_since_pre_state() -> dict[str, object]:
    """Compare the live box, before any restore, with the state before the transition."""
    expected = json.loads(ACCESS_PRE_STATE.read_text())
    live = box_state()
    return {"preserved": live == expected,
            "changed": sorted(key for key in expected if live.get(key) != expected[key])}


def access_phase(status: str) -> int:
    """Scenarios that only hold once the organisation access is no longer active.

    The first observation is the box exactly as the root transition left it: nothing
    is restored before its trees are compared with the state recorded right before the
    transition, so a transition that damaged apps, ledger or cache cannot be hidden.
    """
    meta, variants, evidence, report_path = access_context(status)
    base = FIXTURE / "uc/snapshots/access-base"
    transition = preserved_since_pre_state()
    mutants = {name: mutant(f"{status}-{name}", old, new)
               for name, (old, new) in UC5_MUTANTS.items()}
    uncached = variants["host-incompatible"]["digest"]

    def refresh_refused(label, updater=UPDATER):
        restore(base)
        before = box_state()
        rc, _, log = store_command(label, meta["v2"],
                                   f"--managed-refresh={variants['maintenance']['stage']}",
                                   updater=updater)
        return {"rc": rc, "unchanged": before == box_state(),
                "reason": f"reason=organization-access-{status}" in log}

    def cached_install(label, updater=UPDATER):
        restore(base)
        unrelated_before = app_surface("baseapp")
        rc, _ = update(label, meta["v2"], f"--managed-snapshot-digest={meta['digest2']}",
                       updater=updater)
        observed = installed_release(meta["stage2"], meta["digest2"], "v2")
        observed["rc"] = rc
        observed["unrelated_unchanged"] = app_surface("baseapp") == unrelated_before
        return observed

    def uncached_refused(label, updater=UPDATER):
        restore(base)
        before = box_state()
        rc, log = update(label, meta["v2"], f"--managed-snapshot-digest={uncached}",
                         updater=updater)
        return {"rc": rc, "unchanged": before == box_state(),
                "reason": "reason=bundle-not-cached" in log}

    _, view, _ = store_command(f"uc5-{status}-status", meta["v2"], "--managed-status")
    access = (view or {}).get("access") or {}
    predecessor = (view or {}).get("recovery_predecessor") or {}
    report: dict[str, object] = {
        "transition": transition,
        "status": {
            "access": access,
            "predecessor_cached": predecessor.get("cached") is True
            and predecessor.get("snapshot_digest") == meta["digest1"],
        },
        "refresh": refresh_refused(f"uc5-{status}-refresh"),
        "cached_install": cached_install(f"uc5-{status}-cached-install"),
        "uncached": uncached_refused(f"uc5-{status}-uncached"),
        "mutants": {},
    }
    restore(base)
    plain_rc, _ = update(f"uc5-{status}-plain", meta["v2"])
    report["plain_update"] = {"rc": plain_rc,
                              "app_running": bool(app_surface("available-app")["active"])}
    report["mutants"]["access_ignored"] = refresh_refused(
        f"uc5-{status}-m-access", updater=mutants["access_ignored"])
    report["mutants"]["lapse_blocks_updates"] = cached_install(
        f"uc5-{status}-m-blocks", updater=mutants["lapse_blocks_updates"])
    report["mutants"]["uncached_unnamed"] = uncached_refused(
        f"uc5-{status}-m-uncached", updater=mutants["uncached_unnamed"])
    damaged = cached_install(f"uc5-{status}-m-unrelated", updater=mutants["unrelated_damaged"])
    report["mutants"]["unrelated_damaged"] = damaged
    # Counterexample (b) as it was: the same observation with the old constant.
    report["repro_unrelated_constant_flipped"] = not installed_exactly(
        dict(damaged, unrelated_unchanged=True))
    restore(base)
    report_path.write_bytes(canonical(report))
    return 0


def access_verdict(status: str) -> int:
    """Judge the phase after the destructive transition mutant has run as root."""
    meta, _variants, evidence, report_path = access_context(status)
    base = FIXTURE / "uc/snapshots/access-base"
    if not report_path.is_file():
        print(f"AC-MAU-UC5-{status.upper()} | expected: access_phase==1 | observed: access_phase=0 "
              f"| verdict: FAIL | signal: fixture | evidence: {evidence}", flush=True)
        return 1
    report = json.loads(report_path.read_text())
    destroyed = preserved_since_pre_state()
    restore(base)
    # Counterexample (a) as it was: the old predicate reads the view after a restore.
    _, view, _ = store_command(f"uc5-{status}-destroyed-restored-status", meta["v2"],
                               "--managed-status")
    predecessor = (view or {}).get("recovery_predecessor") or {}
    access_after = (view or {}).get("access") or {}
    report["mutants"]["transition_destroys_apps_and_cache"] = destroyed
    report["repro_restored_view_flipped"] = not (
        predecessor.get("cached") is True and predecessor.get("snapshot_digest") == meta["digest1"]
        and access_after.get("running_apps_preserved") is True
        and access_after.get("recovery_bundles_preserved") is True)
    restore(base)
    report_path.write_bytes(canonical(report))
    print(f"UC5-{status.upper()}-OBSERVATION " + json.dumps(report, sort_keys=True, default=list),
          flush=True)

    access = report["status"]["access"]
    values = {
        "snapshots_stopped": int(access.get("status") == status
                                 and access.get("organization_snapshots_allowed") is False
                                 and access.get("fleet_evidence_allowed") is False),
        "apps_and_cache_preserved": int(bool(report["transition"]["preserved"])
                                        and bool(report["status"]["predecessor_cached"])
                                        and access.get("running_apps_preserved") is True
                                        and access.get("recovery_bundles_preserved") is True),
        "refresh_refused_unchanged": int(report["refresh"]["rc"] == 1
                                         and bool(report["refresh"]["reason"])
                                         and bool(report["refresh"]["unchanged"])),
        "cached_install_allowed": int(installed_exactly(report["cached_install"])),
        "uncached_refused_named": int(report["uncached"]["rc"] == 1
                                      and bool(report["uncached"]["reason"])
                                      and bool(report["uncached"]["unchanged"])),
        "public_local_update_ok": int(report["plain_update"]["rc"] == 0
                                      and bool(report["plain_update"]["app_running"])),
        "mutants_flipped": int(not report["mutants"]["access_ignored"]["reason"])
        + int(not installed_exactly(report["mutants"]["lapse_blocks_updates"]))
        + int(not report["mutants"]["uncached_unnamed"]["reason"])
        + int(not installed_exactly(report["mutants"]["unrelated_damaged"]))
        + int(not destroyed["preserved"]),
    }
    expected = {"snapshots_stopped": 1, "apps_and_cache_preserved": 1,
                "refresh_refused_unchanged": 1, "cached_install_allowed": 1,
                "uncached_refused_named": 1, "public_local_update_ok": 1,
                "mutants_flipped": len(UC5_MUTANTS) + 1}
    passed = values == expected
    print(f"AC-MAU-UC5-{status.upper()} | expected: "
          + " && ".join(f"{k}=={v}" for k, v in expected.items())
          + " | observed: " + ",".join(f"{k}={v}" for k, v in values.items())
          + f" | verdict: {'PASS' if passed else 'FAIL'} | signal: fixture | evidence: {evidence}",
          flush=True)
    return 0 if passed else 1


def command_run() -> int:
    for relative in ("uc/logs", "uc/snapshots", "uc/mutants"):
        (FIXTURE / relative).mkdir(parents=True, exist_ok=True)
    meta = json.loads((FIXTURE / "meta.json").read_text())
    uc_meta = json.loads((FIXTURE / "uc-meta.json").read_text())
    variants = uc_meta["variants"]
    evidence = f"install/test-update-channel.py@{uc_meta['source_revision']}"
    mutants = {name: mutant(name, old, new) for name, (old, new) in MUTANTS.items()}
    uc2_mutants = {name: mutant(name, old, new) for name, (old, new) in UC2_MUTANTS.items()}

    # UC2 — first install of an absent available app, then a clean digest upgrade, both
    # through the real updater and scoped installer, with an unrelated app watched.
    absent_before = ledger_entry("available-app") is None and app_surface("available-app")["webroot"] == "absent"
    absent = snapshot("absent")
    v1_case = {"release": meta["stage1"], "digest": meta["digest1"], "version": "v1",
               "sequence": 2, "revision": meta["v1"], "source": False}
    v1 = install_case("uc2-v1", absent, updater=UPDATER, **v1_case)
    base = snapshot("installed-v1")
    v2_case = {"release": meta["stage2"], "digest": meta["digest2"], "version": "v2",
               "sequence": 3, "revision": meta["v2"], "source": True}
    v2 = install_case("uc2-v2", base, updater=UPDATER, **v2_case)
    uc2_report: dict[str, object] = {"absent_before": absent_before, "v1": v1, "v2": v2,
                                     "mutants": {}}
    uc2_flipped = 0
    for name, start, case in (
        ("selection_dropped", absent, v1_case),
        ("candidate_not_imported", base, v2_case),
        ("unrelated_app_selected", base, v2_case),
        ("scoped_executor_bypassed", base, v2_case),
    ):
        observed = install_case(f"uc2-{name}", start, updater=uc2_mutants[name], **case)
        uc2_report["mutants"][name] = observed
        uc2_flipped += not installed_exactly(observed)
    (FIXTURE / "uc/uc2-observation.json").write_bytes(canonical(uc2_report))
    print("UC2-OBSERVATION " + json.dumps(uc2_report, sort_keys=True, default=list), flush=True)
    uc2_values = {
        "absent_before": int(absent_before),
        "v1_installed_exactly": int(installed_exactly(v1)),
        "v2_upgraded_exactly": int(installed_exactly(v2)),
        "unrelated_unchanged": int(bool(v1["unrelated_unchanged"])) + int(bool(v2["unrelated_unchanged"])),
        "mutants_flipped": uc2_flipped,
    }
    uc2_expected = {"absent_before": 1, "v1_installed_exactly": 1, "v2_upgraded_exactly": 1,
                    "unrelated_unchanged": 2, "mutants_flipped": len(UC2_MUTANTS)}
    uc2_pass = uc2_values == uc2_expected
    print("AC-MAU-UC2 | expected: " + " && ".join(f"{k}=={v}" for k, v in uc2_expected.items())
          + " | observed: " + ",".join(f"{k}={v}" for k, v in uc2_values.items())
          + f" | verdict: {'PASS' if uc2_pass else 'FAIL'} | signal: fixture | evidence: {evidence}",
          flush=True)
    # UC1 — a verified refresh changes only the managed cache, and the store view says
    # what is installed, what is offered, how old the cache is and what it can fall
    # back to. Partial and tampered sources leave everything byte-identical.
    uc1_mutants = {name: mutant(name, old, new) for name, (old, new) in UC1_MUTANTS.items()}
    v1_lock, v2_lock = (lock_digest(meta["stage1"], "available-app"),
                        lock_digest(meta["stage2"], "available-app"))

    def refresh(label, source, updater=UPDATER):
        before = box_state()
        rc, view, log = store_command(label, meta["v2"], f"--managed-refresh={source}",
                                      updater=updater)
        after = box_state()
        changed = sorted(key for key in before if before[key] != after[key])
        return {"rc": rc, "changed": changed, "view": view,
                "installer_invocations": log.count("설치기를 다시 돌립니다"),
                "reason": "reason=refresh-refused" in log}

    def refreshed_only_cache(observed):
        return (observed["rc"] == 0 and observed["changed"] == [str(NAMESPACE)]
                and observed["installer_invocations"] == 0)

    def same_release_quiet(view):
        item = row(view, "available-app")
        return (item.get("action") == "none" and item.get("installed_digest") == v1_lock
                and item.get("candidate_digest") == v1_lock
                and (view or {}).get("current", {}).get("snapshot_digest") == meta["digest1"])

    def cache_age_shown(view):
        current = (view or {}).get("current", {})
        return isinstance(current.get("cache_age_seconds"), int) and current["cache_age_seconds"] >= 0 \
            and isinstance(current.get("refreshed_at"), str)

    def update_offered_with_predecessor(view):
        item = row(view, "available-app")
        predecessor = (view or {}).get("recovery_predecessor") or {}
        return (item.get("action") == "update" and item.get("installed_digest") == v1_lock
                and item.get("candidate_digest") == v2_lock and item.get("bundle_cached") is True
                and (view or {}).get("current", {}).get("snapshot_digest") == meta["digest2"]
                and predecessor.get("snapshot_digest") == meta["digest1"]
                and predecessor.get("cached") is True)

    def refused_unchanged(observed):
        return observed["rc"] == 1 and observed["reason"] and observed["changed"] == []

    restore(base)
    status_rc, view_before, _ = store_command("uc1-status-before", meta["v1"], "--managed-status")
    refreshed = refresh("uc1-refresh", meta["stage2"])
    status_after_rc, view_after, _ = store_command("uc1-status-after", meta["v2"], "--managed-status")
    maintenance = pathlib.Path(variants["maintenance"]["stage"])
    partial = FIXTURE / "uc/partial-release"
    shutil.rmtree(partial, ignore_errors=True)
    shutil.copytree(maintenance, partial)
    (partial / "bundle.tar").unlink()
    partial_observed = refresh("uc1-partial", str(partial))
    tampered = FIXTURE / "uc/tampered-release"
    shutil.rmtree(tampered, ignore_errors=True)
    shutil.copytree(maintenance, tampered)
    catalog = json.loads((tampered / "catalog.json").read_text())
    catalog["apps"][0]["metadata"]["name"] = "Tampered app"
    (tampered / "catalog.json").write_bytes(canonical(catalog))
    tampered_observed = refresh("uc1-tampered", str(tampered))

    uc1_report: dict[str, object] = {
        "status_before": {"rc": status_rc, "view": view_before},
        "refresh": refreshed, "status_after": {"rc": status_after_rc, "view": view_after},
        "partial": partial_observed, "tampered": tampered_observed, "mutants": {},
    }
    uc1_flipped = 0
    restore(base)
    observed = refresh("uc1-m-refresh_falls_through", meta["stage2"],
                       updater=uc1_mutants["refresh_falls_through"])
    uc1_report["mutants"]["refresh_falls_through"] = observed
    uc1_flipped += not refreshed_only_cache(observed)
    restore(base)
    _, view, _ = store_command("uc1-m-same_release", meta["v1"], "--managed-status",
                               updater=uc1_mutants["same_release_offers_update"])
    uc1_report["mutants"]["same_release_offers_update"] = view
    uc1_flipped += view is not None and not same_release_quiet(view)
    _, view, _ = store_command("uc1-m-cache_age", meta["v1"], "--managed-status",
                               updater=uc1_mutants["cache_age_hidden"])
    uc1_report["mutants"]["cache_age_hidden"] = view
    uc1_flipped += view is not None and not cache_age_shown(view)
    refresh("uc1-m-predecessor-refresh", meta["stage2"])
    _, view, _ = store_command("uc1-m-predecessor", meta["v2"], "--managed-status",
                               updater=uc1_mutants["predecessor_hidden"])
    uc1_report["mutants"]["predecessor_hidden"] = view
    uc1_flipped += view is not None and not update_offered_with_predecessor(view)
    restore(base)
    (FIXTURE / "uc/uc1-observation.json").write_bytes(canonical(uc1_report))
    print("UC1-OBSERVATION " + json.dumps(uc1_report, sort_keys=True, default=list), flush=True)
    uc1_values = {
        "same_release_quiet": int(status_rc == 0 and same_release_quiet(view_before)),
        "cache_age_shown": int(cache_age_shown(view_before) and cache_age_shown(view_after)),
        "refresh_only_cache": int(refreshed_only_cache(refreshed)),
        "update_offered_with_predecessor": int(status_after_rc == 0
                                               and update_offered_with_predecessor(view_after)),
        "partial_refused_unchanged": int(refused_unchanged(partial_observed)),
        "tampered_refused_unchanged": int(refused_unchanged(tampered_observed)),
        "mutants_flipped": uc1_flipped,
    }
    uc1_expected = {"same_release_quiet": 1, "cache_age_shown": 1, "refresh_only_cache": 1,
                    "update_offered_with_predecessor": 1, "partial_refused_unchanged": 1,
                    "tampered_refused_unchanged": 1, "mutants_flipped": len(UC1_MUTANTS)}
    uc1_pass = uc1_values == uc1_expected
    print("AC-MAU-UC1 | expected: " + " && ".join(f"{k}=={v}" for k, v in uc1_expected.items())
          + " | observed: " + ",".join(f"{k}={v}" for k, v in uc1_values.items())
          + f" | verdict: {'PASS' if uc1_pass else 'FAIL'} | signal: fixture | evidence: {evidence}",
          flush=True)

    # UC4 — a forced failure after service mutation recovers and verifies by itself,
    # and the run leaves a durable receipt bound to the release and the actor.
    uc4_mutants = {name: mutant(name, old, new) for name, (old, new) in UC4_MUTANTS.items()}
    uc4 = failure_case("uc4", base, meta=meta, updater=UPDATER)
    before_retry = receipt_names()
    retry_rc, _ = update("uc4-retry", meta["v2"], f"--managed-snapshot-digest={meta['digest2']}")
    retry = installed_release(meta["stage2"], meta["digest2"], "v2")
    retry_receipt = new_receipt(before_retry)
    retry["rc"] = retry_rc
    retry["receipt_outcome"] = retry_receipt.get("outcome")
    uc4_report: dict[str, object] = {"recovered": uc4, "retry": retry, "mutants": {}}
    uc4_flipped = 0
    for name in UC4_MUTANTS:
        observed = failure_case(f"uc4-{name}", base, meta=meta, updater=uc4_mutants[name])
        uc4_report["mutants"][name] = observed
        uc4_flipped += not recovered_and_receipted(observed)
    restore(base)
    (FIXTURE / "uc/uc4-observation.json").write_bytes(canonical(uc4_report))
    print("UC4-OBSERVATION " + json.dumps(uc4_report, sort_keys=True, default=list), flush=True)
    uc4_values = {
        "recovered_and_receipted": int(recovered_and_receipted(uc4)),
        "retry_installed_exactly": int(retry["rc"] == 0 and bool(retry["version_ok"])
                                       and bool(retry["snapshot_bound"])
                                       and retry["receipt_outcome"] == "installed"),
        "mutants_flipped": uc4_flipped,
    }
    uc4_expected = {"recovered_and_receipted": 1, "retry_installed_exactly": 1,
                    "mutants_flipped": len(UC4_MUTANTS)}
    uc4_pass = uc4_values == uc4_expected
    print("AC-MAU-UC4 | expected: " + " && ".join(f"{k}=={v}" for k, v in uc4_expected.items())
          + " | observed: " + ",".join(f"{k}={v}" for k, v in uc4_values.items())
          + f" | verdict: {'PASS' if uc4_pass else 'FAIL'} | signal: fixture | evidence: {evidence}",
          flush=True)

    # The access phases run after a root transition, so freeze the state they start
    # from: v1 installed, v2 refreshed and selected, v1 kept as the predecessor.
    restore(base)
    store_command("uc5-access-refresh", meta["v2"], f"--managed-refresh={meta['stage2']}")
    select("uc5-access", meta["stage2"], meta["digest2"], [("available-app", "managed")], 30,
           "2026-09-12T08:30:00Z")
    access_base = snapshot("access-base")

    if not installed_exactly(v1):
        print("AC-MAU-UC3 | expected: precondition==1 | observed: precondition=0 "
              f"| verdict: UNMEASURED | signal: fixture | evidence: {evidence}", flush=True)
        return 1

    # One case per refusal class the updater owns, each with the product mutant that
    # removes exactly that refusal.
    cases = {
        "no_digest_removal": {
            "reason": "reason=removal-deselected", "release": meta["stage1"],
            "digest": meta["digest1"], "rows": [], "sequence": 10,
            "revision": meta["v1"], "digest_input": False,
            "mutants": ["preflight_skipped", "removal_refused"],
        },
        "host_incompatible": {
            "reason": "reason=app-host-incompatible",
            "release": variants["host-incompatible"]["stage"],
            "digest": variants["host-incompatible"]["digest"],
            "rows": [("available-app", "managed")], "sequence": 11,
            "revision": meta["v2"], "digest_input": True,
            "mutants": ["app_host_incompatible"],
        },
        "maintenance_upgrade": {
            "reason": "reason=upgrade-maintenance-required",
            "release": variants["maintenance"]["stage"],
            "digest": variants["maintenance"]["digest"],
            "rows": [("available-app", "managed")], "sequence": 12,
            "revision": meta["v2"], "digest_input": True,
            "mutants": ["upgrade_maintenance_required"],
        },
        "lifecycle_missing": {
            "reason": "reason=lifecycle-incomplete",
            "release": variants["lifecycle-missing"]["stage"],
            "digest": variants["lifecycle-missing"]["digest"],
            "rows": [("available-app", "managed")], "sequence": 13,
            "revision": meta["v2"], "digest_input": True,
            "mutants": ["lifecycle_incomplete"],
        },
        "blocked_policy": {
            "reason": "reason=removal-blocked-policy",
            "release": variants["blocked"]["stage"],
            "digest": variants["blocked"]["digest"], "rows": [], "sequence": 14,
            "revision": meta["v2"], "digest_input": True,
            "mutants": ["removal_refused"],
        },
    }
    report: dict[str, object] = {}
    refused = 0
    flipped = 0
    product_installer_invocations = 0
    for label, case in cases.items():
        arguments = {key: case[key] for key in
                     ("reason", "release", "digest", "rows", "sequence", "revision",
                      "digest_input")}
        product = refusal(label, base, updater=UPDATER, **arguments)
        report[label] = {"product": product, "mutants": {}}
        product_installer_invocations += product["installer_invocations"]
        if refused_before_mutation(product):
            refused += 1
        for name in case["mutants"]:
            observed = refusal(label, base, updater=mutants[name], **arguments)
            report[label]["mutants"][name] = observed
            if not refused_before_mutation(observed):
                flipped += 1
    restore(base)
    mutant_runs = sum(len(case["mutants"]) for case in cases.values())
    (FIXTURE / "uc/uc3-observation.json").write_bytes(canonical(report))
    print("UC3-OBSERVATION " + json.dumps(report, sort_keys=True, default=list), flush=True)
    predicate = (f"refusals=={len(cases)} && mutants_flipped=={mutant_runs} "
                 f"&& installer_invocations==0")
    passed = (refused == len(cases) and flipped == mutant_runs
              and product_installer_invocations == 0)
    print(f"AC-MAU-UC3 | expected: {predicate} | observed: refusals={refused},"
          f"mutants_flipped={flipped},installer_invocations={product_installer_invocations} "
          f"| verdict: {'PASS' if passed else 'FAIL'} "
          f"| signal: fixture | evidence: {evidence}", flush=True)
    # The root access transition runs right after this phase exits, so leave the box
    # exactly at the access base and record that state as the transition's baseline.
    restore(access_base)
    ACCESS_PRE_STATE.write_bytes(canonical(box_state()))
    return 0 if passed and uc1_pass and uc2_pass and uc4_pass else 1


def main() -> int:
    if sys.argv[1:] == ["run"]:
        return command_run()
    if sys.argv[1:] == ["setup"]:
        return command_setup()
    if len(sys.argv) == 3 and sys.argv[1] == "access" and sys.argv[2] in {"lapsed", "unenrolled"}:
        return access_phase(sys.argv[2])
    if len(sys.argv) == 3 and sys.argv[1] == "access-verdict" and sys.argv[2] in {"lapsed", "unenrolled"}:
        return access_verdict(sys.argv[2])
    print("usage: test-update-channel.py setup|run|access|access-verdict <lapsed|unenrolled>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
