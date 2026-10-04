#!/usr/bin/env python3
"""Fixture contract: nginx fragment inclusion is exact, not a glob.

This used to also cover the explicit-package digest lock (cho 2aeaead5 (b)'s
partial gate trim: malformed-lock handling, lifecycle-scoped confirmation,
--approve-json, lock-finalize). That whole mechanism was deleted outright
(docs/reports/2026-09-27_installer-gate-zero-base-revival.md, family (a)): it
was an admission-control checkpoint, not a security boundary (SECURITY.md,
Package trust), and caused more install failures in two weeks than it ever
prevented. Nothing here replaces those assertions — there is nothing left to
assert once the mechanism does not exist. What remains is the one check in
this file that was never about the lock: render-nginx.sh must include exactly
the fragments of enabled apps, never a directory glob or a hand-placed file.

This suite copies the checkout into scratch and never runs the live
installer, updater, nginx, or hub.
"""
from __future__ import annotations

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
        lines.append(f"[apps.{pid}]\n")
    path.write_text("".join(lines))


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
    confd = scratch / "confd"
    web = scratch / "web"
    state = scratch / "state"
    for path in (confd / "hub-locations.d", confd / "servers.d", web / "assets", state):
        path.mkdir(parents=True, exist_ok=True)

    kept = make_package(scratch / "pkgs", "kept-pkg", "v1\n")
    cfg = scratch / "airlock.toml"
    write_config(cfg, {"kept-pkg": kept})

    write(confd / "hub-locations.d" / "hub.conf", "# canonical hub fragment\n")
    write(confd / "servers.d" / "publish-doc-gate.conf",
          "server { listen 127.0.0.1:19925; }\n")
    write(confd / "servers.d" / "kept-pkg.conf",
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
    env.update(HOME=str(scratch / "home"), XDG_CONFIG_HOME=str(scratch / "xdg"))
    env.pop("AIRLOCK_APP_ID", None)
    env.pop("AIRLOCK_APP_DIR", None)
    seeded = run([sys.executable, "-c", """
from importlib.machinery import SourceFileLoader
import sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("_gate_fixture_ledger", sys.argv[1]).load_module()
ledger.write_installed({"kept-pkg": {"repo": sys.argv[2], "commit": "", "artifacts": []}})
""", str(repo / "bin/airlock-ledger"), str(kept)], env=env)
    if seeded.returncode:
        raise RuntimeError(seeded.stderr)
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
                and f"include {confd}/servers.d/kept-pkg.conf;" in text:
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
