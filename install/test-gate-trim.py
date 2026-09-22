#!/usr/bin/env python3
"""Fixture contracts for cho 2aeaead5 (b): ceremonial gates are removed.

Each KEEP/MERGE/REMOVE is a real blocking failure. This suite copies the
checkout into scratch and never runs the live installer, updater, nginx, or hub.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]


def run(cmd, *, env, cwd=None, check=False):
    return subprocess.run(
        cmd, env=env, cwd=cwd, text=True, capture_output=True, check=check,
    )


def write(path: Path, text: str, mode=0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    os.chmod(path, mode)


def make_package(root: Path, pid: str, payload: str) -> Path:
    package = root / pid
    write(package / "airlock-app.toml", f'contract = 1\nid = "{pid}"\n')
    write(package / "install.sh", "#!/bin/sh\nexit 0\n", 0o755)
    write(package / "smoke.sh", "#!/bin/sh\nexit 0\n", 0o755)
    write(package / "deactivate.sh", "#!/bin/sh\nexit 0\n", 0o755)
    write(package / "payload.txt", payload)
    return package


def write_config(path: Path, packages: dict[str, Path]) -> None:
    lines = [
        "[airlock]\nconfig_version = 2\n",
        '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n',
        "[apps.hub]\n",
    ]
    for pid, package in packages.items():
        lines.append(f"[apps.{pid}]\n[packages.{pid}]\npath = \"{package}\"\n")
    path.write_text("".join(lines))


def digest_tree(ledger: Path, package: Path) -> str:
    proc = run(
        [sys.executable, "-c",
         "import importlib.machinery, importlib.util, sys\n"
         "loader = importlib.machinery.SourceFileLoader('ledger', sys.argv[1])\n"
         "spec = importlib.util.spec_from_loader(loader.name, loader)\n"
         "mod = importlib.util.module_from_spec(spec)\n"
         "loader.exec_module(mod)\n"
         "print(mod.digest_tree(sys.argv[2]))\n",
         str(ledger), str(package)],
        env=os.environ.copy(),
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr)
    return proc.stdout.strip()


def write_lock(path: Path, entries: dict[str, str]) -> None:
    blocks = [f'[{pid}]\ndigest = "{digest}"\n' for pid, digest in sorted(entries.items())]
    path.write_text("\n".join(blocks))


def config_cmd(repo: Path, cfg: Path, args: list[str], extra_env=None):
    env = os.environ.copy()
    env["AIRLOCK_CONFIG"] = str(cfg)
    env["AIRLOCK_WEBROOT"] = str(repo.parent / "web")
    env["AIRLOCK_CONFD"] = str(repo.parent / "confd")
    env["AIRLOCK_STATE_DIR"] = str(repo.parent / "state")
    env["AIRLOCK_TS_FQDN"] = "box.example.ts.net"
    if extra_env:
        env.update(extra_env)
    return run([sys.executable, str(repo / "bin/airlock-config"), *args], env=env)


def main() -> int:
    fail = 0
    scratch = Path(tempfile.mkdtemp(prefix="airlock-gate-trim-"))
    repo = scratch / "repo"
    repo.mkdir()
    copied = subprocess.run(
        ["tar", "-C", str(SOURCE), "--exclude=./.git", "--exclude=./airlock.lock",
         "-cf", "-", "."],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if copied.returncode != 0:
        print("FAIL could not archive checkout")
        shutil.rmtree(scratch)
        return 1
    extracted = subprocess.run(
        ["tar", "-C", str(repo), "-xf", "-"],
        input=copied.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=False,
    )
    if extracted.returncode != 0:
        print("FAIL could not create scratch repository")
        shutil.rmtree(scratch)
        return 1
    cfg_bin = repo / "bin/airlock-config"
    ledger = repo / "bin/airlock-ledger"
    lock = repo / "airlock.lock"
    confd = scratch / "confd"
    web = scratch / "web"
    state = scratch / "state"
    for path in (confd / "hub-locations.d", confd / "servers.d", web / "assets", state):
        path.mkdir(parents=True, exist_ok=True)

    stale = make_package(scratch / "pkgs", "stale-pkg", "stale-v1\n")
    target = make_package(scratch / "pkgs", "target-pkg", "target-v1\n")
    cfg = scratch / "airlock.toml"
    write_config(cfg, {"stale-pkg": stale, "target-pkg": target})
    stale_digest = digest_tree(ledger, stale)
    target_digest = digest_tree(ledger, target)
    write_lock(lock, {"stale-pkg": stale_digest, "target-pkg": target_digest})
    write(stale / "payload.txt", "stale-v2\n")
    stale_new = digest_tree(ledger, stale)
    if stale_new == stale_digest:
        print("FAIL fixture could not create a digest mismatch")
        shutil.rmtree(scratch)
        return 1

    write_lock(lock, {"stale-pkg": "not-a-digest"})
    malformed = config_cmd(repo, cfg, ["validate"])
    info_malformed = config_cmd(repo, cfg, ["package-info"])
    if malformed.returncode == 0 and info_malformed.returncode != 0 \
            and "package lock" in info_malformed.stderr:
        print("ok   KEEP malformed lock: lifecycle reads it, validate does not")
    else:
        print("FAIL KEEP malformed lock split")
        print(malformed.stderr)
        print(info_malformed.stderr)
        fail += 1
    write_lock(lock, {"stale-pkg": stale_digest, "target-pkg": target_digest})

    validate = config_cmd(repo, cfg, ["validate"])
    if validate.returncode == 0:
        print("ok   REMOVE global lock: validate ignores unrelated digest mismatch")
    else:
        print("FAIL REMOVE global lock: validate still blocked")
        print(validate.stderr)
        fail += 1

    webjson = config_cmd(repo, cfg, ["webjson"])
    if webjson.returncode == 0:
        print("ok   REMOVE global lock: webjson ignores unrelated digest mismatch")
    else:
        print("FAIL REMOVE global lock: webjson still blocked")
        print(webjson.stderr)
        fail += 1

    info_all = config_cmd(repo, cfg, ["package-info"])
    if info_all.returncode != 0 and "package 'stale-pkg': package lock digest mismatch" in info_all.stderr:
        print("ok   KEEP lifecycle lock: package-info still refuses the mismatched target set")
    else:
        print("FAIL KEEP lifecycle lock: package-info did not refuse stale-pkg")
        print(info_all.stderr)
        fail += 1

    info_target = config_cmd(
        repo, cfg, ["package-info", "--lifecycle-targets=target-pkg"])
    if info_target.returncode == 0:
        print("ok   MERGE lifecycle targets: only the named package is confirmed")
    else:
        print("FAIL MERGE lifecycle targets: targeted package-info failed")
        print(info_target.stderr)
        fail += 1

    installer = (repo / "install/airlock-install.sh").read_text(encoding="utf-8")
    targeted_calls = installer.count(
        'airlock_config package-info "${_airlock_package_info_args[@]}"'
    )
    if (targeted_calls == 2
            and '--lifecycle-targets=$_airlock_selected_csv' in installer):
        print("ok   MERGE selected install: package-info receives only lifecycle targets")
    else:
        print("FAIL MERGE selected install: lifecycle targets are not wired to both package-info reads")
        fail += 1

    info_stale = config_cmd(
        repo, cfg, ["package-info", "--lifecycle-targets=stale-pkg"])
    if info_stale.returncode != 0 and "package lock digest mismatch" in info_stale.stderr:
        print("ok   KEEP lifecycle lock: the actual target still fails closed")
    else:
        print("FAIL KEEP lifecycle lock: targeted stale package was admitted")
        print(info_stale.stderr)
        fail += 1

    approval = {
        "id": "stale-pkg",
        "path": str(stale),
        "digest": stale_new,
        "grants": [],
    }
    grant_bump = dict(approval)
    grant_bump["grants"] = ["system-unit"]
    bumped = config_cmd(
        repo, cfg,
        [f"--approve-json={json.dumps(grant_bump)}",
         "package-info", "--lifecycle-targets=stale-pkg"],
    )
    if bumped.returncode != 0:
        print("ok   KEEP grant boundary: approval cannot smuggle extra grants")
    else:
        print("FAIL KEEP grant boundary: extra grants were admitted")
        fail += 1

    approved = config_cmd(
        repo, cfg,
        [f"--approve-json={json.dumps(approval)}",
         "package-info", "--lifecycle-targets=stale-pkg"],
    )
    if approved.returncode == 0:
        print("ok   MERGE approval object: one JSON object admits the digest change")
    else:
        print("FAIL MERGE approval object: --approve-json did not admit stale-pkg")
        print(approved.stderr)
        fail += 1

    preview = config_cmd(repo, cfg, ["package-preview", str(stale)])
    if preview.returncode == 0:
        payload = json.loads(preview.stdout)
        if payload.get("requires_reapproval") is True and payload.get("digest") == stale_new:
            print("ok   MERGE preview is observation, not a required prior gate")
        else:
            print("FAIL MERGE preview shape drifted")
            fail += 1
    else:
        print("FAIL MERGE preview still blocked by sibling lock")
        print(preview.stderr)
        fail += 1

    before_lock = lock.read_bytes()
    finalize = config_cmd(
        repo, cfg, [f"--approve-json={json.dumps(approval)}", "lock-finalize"])
    if finalize.returncode == 0 and lock.read_text().find(stale_new) != -1 \
            and "package-lock-approve" in finalize.stderr \
            and not (repo / "airlock-live-box" / "live-box-lease.json").exists():
        print("ok   MERGE lease: lock-finalize is box flock+audit, not lease metadata")
    else:
        print("FAIL MERGE lease: lock-finalize did not update under flock+audit")
        print(finalize.stderr)
        fail += 1
    if before_lock == lock.read_bytes():
        print("FAIL MERGE approval object: lock bytes were not updated")
        fail += 1

    write(confd / "hub-locations.d" / "hub.conf", "# canonical hub fragment\n")
    write(confd / "servers.d" / "publish-doc-gate.conf",
          "server { listen 127.0.0.1:19925; }\n")
    write(confd / "servers.d" / "stale-pkg.conf",
          "server { listen 127.0.0.1:19999; }\n")
    env = os.environ.copy()
    env.update({
        "AIRLOCK_CONFIG": str(cfg),
        "AIRLOCK_WEBROOT": str(web),
        "AIRLOCK_CONFD": str(confd),
        "AIRLOCK_STATE_DIR": str(state),
        "AIRLOCK_TS_FQDN": "box.example.ts.net",
        "AIRLOCK_NGINX_SITE": str(scratch / "nginx-site.conf"),
        "PATH": env.get("PATH", ""),
    })
    rendered = run(["bash", str(repo / "install/render-nginx.sh")], env=env)
    if rendered.returncode != 0:
        print("FAIL REMOVE fragment wall: render-nginx failed")
        print(rendered.stderr)
        fail += 1
    else:
        text = rendered.stdout
        extra = f"include {confd}/servers.d/publish-doc-gate.conf;"
        if extra in text or "servers.d/*.conf" in text or "hub-locations.d/*.conf" in text:
            print("FAIL REMOVE fragment wall: glob or manual listener still included")
            fail += 1
        elif f"include {confd}/hub-locations.d/hub.conf;" in text \
                and f"include {confd}/servers.d/stale-pkg.conf;" in text:
            print("ok   REMOVE fragment wall: only enabled-app fragments are included")
        else:
            print("FAIL REMOVE fragment wall: canonical includes missing")
            print(text[-800:])
            fail += 1

    shutil.rmtree(scratch)
    print(f"{'PASS' if fail == 0 else 'FAIL'} gate-trim {fail} failing assertion(s)")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
