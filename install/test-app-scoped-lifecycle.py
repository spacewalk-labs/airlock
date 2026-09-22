#!/usr/bin/env python3
"""Isolated A1/A2/A3 fixture for app-scoped lifecycle planning and results.

The fixture writes only below a temporary directory. It invokes the real config
validator for global candidate checks, feeds synthetic edge cases to the pure planner,
and runs the real ledger producer and installer against a scratch box with command
shims. Recorded install/restart calls are fixture observations, not service or live-box
execution.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "bin/airlock-config"
LEDGER = ROOT / "bin/airlock-ledger"
INSTALLER = ROOT / "install/airlock-install.sh"
PLANNER = ROOT / "install/app-scoped-plan.py"


def run(*args: str, env: dict[str, str] | None = None,
        stdin: bytes | None = None, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        args,
        env=env,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if ok and result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"{result.stderr.decode(errors='replace')}"
        )
    if not ok and result.returncode == 0:
        raise AssertionError(
            f"command unexpectedly passed: {' '.join(args)}\n"
            f"{result.stdout.decode(errors='replace')}"
        )
    return result


def package_manifest(app_id: str, *, port: int, webroot: str,
                     deps: tuple[str, ...] = (), ingress: bool = False,
                     claim_port: bool = True, unit: str | None = None,
                     container: str | None = None) -> str:
    dependency = ""
    if deps:
        dependency = "\n[dependencies]\napps = " + json.dumps(list(deps)) + "\n"
    extra_artifacts = ""
    if unit is not None:
        extra_artifacts += f'units = [{{name = "{unit}", scope = "user"}}]\n'
    if container is not None:
        extra_artifacts += f'containers = ["{container}"]\n'
    if ingress:
        return (
            f'contract = 1\nid = "{app_id}"\n'
            f'[config.defaults]\nhttps_port = {port}\nbackend_port = {port + 100}\n'
            f'[artifacts]\nwebroot = ["{webroot}"]\n{extra_artifacts}'
            f'serve_ports = ["https_port"]\n'
            f'[serve.https]\nhttps_port = "backend_port"\n'
            f'{dependency}'
        )
    artifacts = f'[artifacts]\nwebroot = ["{webroot}"]\n{extra_artifacts}'
    if claim_port:
        artifacts += 'serve_ports = ["backend_port"]\n'
    return (
        f'contract = 1\nid = "{app_id}"\n'
        f'[config.defaults]\nbackend_port = {port}\n'
        f'{artifacts}'
        f'{dependency}'
    )


def write_package(root: Path, app_id: str, *, port: int, webroot: str,
                  deps: tuple[str, ...] = (), ingress: bool = False,
                  claim_port: bool = True) -> Path:
    package = root / app_id
    package.mkdir(parents=True)
    (package / "airlock-app.toml").write_text(
        package_manifest(
            app_id, port=port, webroot=webroot, deps=deps, ingress=ingress,
            claim_port=claim_port,
        ),
        encoding="utf-8",
    )
    env_id = app_id.upper().replace("-", "_")
    reads = [
        f'fixture_backend="${{AIRLOCK_{env_id}_BACKEND_PORT:?}}"',
        'test "$fixture_backend" -gt 0',
    ]
    if ingress:
        reads.extend([
            f'fixture_https="${{AIRLOCK_{env_id}_HTTPS_PORT:?}}"',
            'test "$fixture_https" -gt 0',
        ])
    for name in ("install.sh", "smoke.sh", "deactivate.sh"):
        script = package / name
        script.write_text(
            "#!/usr/bin/env bash\n" + "\n".join(reads) + "\nexit 0\n",
            encoding="utf-8",
        )
        script.chmod(0o755)
    return package


def write_config(path: Path, packages: list[tuple[str, Path, int]]) -> None:
    rows = [
        '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"',
        "[apps.hub]",
    ]
    for app_id, package, port in packages:
        rows.extend([
            f"[apps.{app_id}]\nbackend_port = {port}",
            f'[packages.{app_id}]\npath = "{package}"',
        ])
    path.write_text("\n\n".join(rows) + "\n", encoding="utf-8")


def config_env(root: Path, config: Path) -> dict[str, str]:
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    marker = root / ".airlock-live-box-fixture-v1"
    marker.write_text("airlock.live-box-fixture/v1\n", encoding="ascii")
    marker.chmod(0o600)
    return dict(
        os.environ,
        AIRLOCK_CONFIG=str(config),
        AIRLOCK_STATE_DIR=str(root / "state"),
        AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR=str(root / "airlock-live-box"),
        AIRLOCK_WEBROOT=str(root / "webroot"),
        AIRLOCK_CONFD=str(root / "confd"),
        AIRLOCK_UNIT_DIR_USER=str(root / "units-user"),
        AIRLOCK_UNIT_DIR_SYSTEM=str(root / "units-system"),
        AIRLOCK_TS_FQDN="fixture.example.ts.net",
        HOME=str(root / "home"),
    )


def package_info(root: Path, config: Path, *, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    return run(sys.executable, str(CONFIG), "package-info", env=config_env(root, config), ok=ok)


def config_check(root: Path, config: Path, *, ok: bool = True) -> subprocess.CompletedProcess[bytes]:
    return run(sys.executable, str(CONFIG), "validate", env=config_env(root, config), ok=ok)


def invoke_planner(package_info_raw: bytes, ledger_plan: Path, *, selected: tuple[str, ...],
                   ok: bool = True, extra: tuple[str, ...] = (),
                   mode: str = "selected",
                   ledger_dependencies: Path | None = None) -> subprocess.CompletedProcess[bytes]:
    semantic_info = json.loads(package_info_raw)
    candidate_digest = hashlib.sha256(
        (json.dumps(semantic_info, sort_keys=True, separators=(",", ":")) + "\n").encode()
    ).hexdigest()
    args = [
        sys.executable,
        str(PLANNER),
        "--package-info", "-",
        "--ledger-plan", str(ledger_plan),
        "--candidate-preflight-digest", candidate_digest,
        "--mode", mode,
    ]
    if ledger_dependencies is not None:
        args.extend(("--ledger-dependencies", str(ledger_dependencies)))
    for app_id in selected:
        args.extend(("--select", app_id))
    args.extend(extra)
    return run(*args, stdin=package_info_raw, ok=ok)


def write_ledger_dependencies(
        path: Path, rows: list[tuple[str, tuple[str, ...], str]], ledger_plan: Path) -> None:
    actions = [line.split("\t") for line in ledger_plan.read_text(encoding="utf-8").splitlines()]
    path.write_text(
        json.dumps({
            "schema": "airlock.ledger-dependencies/v2",
            "rows": [
                {"app_id": app_id, "deps": list(deps), "record_kind": record_kind}
                for app_id, deps, record_kind in rows
            ],
            "candidate_serve_mappings": [
                {"app_id": app_id, "matches_committed": action == "reinstall"}
                for action, app_id in actions
                if action in {"fresh", "reinstall", "upgrade-diff", "upgrade-deactivate"}
            ],
        }) + "\n",
        encoding="utf-8",
    )


def write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def write_installer_package(root: Path, app_id: str, *, port: int,
                            action_log: Path, deps: tuple[str, ...] = (),
                            resource_rich: bool = False,
                            fail_apply: bool = False,
                            fail_smoke: bool = False,
                            regress_after_verify: bool = False) -> Path:
    package = root / app_id
    package.mkdir(parents=True)
    (package / "airlock-app.toml").write_text(
        package_manifest(
            app_id, port=port, webroot=f"{app_id}/", deps=deps,
            ingress=resource_rich,
            unit=f"airlock-{app_id}.service" if resource_rich else None,
            container=f"airlock-{app_id}-*" if resource_rich else None,
        ),
        encoding="utf-8",
    )
    quoted_log = shlex.quote(str(action_log))
    quoted_id = shlex.quote(app_id)
    env_id = app_id.upper().replace("-", "_")
    resource_apply = ""
    if resource_rich:
        resource_apply = f"""
mkdir -p "$AIRLOCK_UNIT_DIR_USER"
printf '[Service]\\nExecStart=/bin/true\\n' > "$AIRLOCK_UNIT_DIR_USER/airlock-{app_id}.service"
systemctl --user enable "airlock-{app_id}.service"
systemctl --user start "airlock-{app_id}.service"
[ -z "${{AIRLOCK_TEST_UNIT_READY:-}}" ] \
  || : > "$AIRLOCK_TEST_UNIT_READY.airlock-{app_id}.service.pending"
python3 - "$AIRLOCK_TEST_DOCKER_STATE" "$AIRLOCK_INSTALL_NONCE" <<'PY_RESOURCE_DOCKER'
import json
import sys
path, nonce = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    objects = json.load(handle)
objects.append({{
    "Id": "b" * 64,
    "Name": "/airlock-{app_id}-one",
    "Config": {{"Labels": {{
        "io.airlock.package": "{app_id}",
        "io.airlock.install-nonce": nonce,
    }}}},
}})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(objects, handle, sort_keys=True)
    handle.write("\\n")
PY_RESOURCE_DOCKER
"""
    failure = "exit 73\n" if fail_apply else ""
    smoke_failure = "exit 74\n" if fail_smoke else ""
    readiness = ""
    if resource_rich:
        readiness = f"""
test -e "$AIRLOCK_TEST_UNIT_READY.airlock-{app_id}.service.pending"
rm -f "$AIRLOCK_TEST_UNIT_READY.airlock-{app_id}.service.pending"
printf 'unit-ready\\t%s\\n' {quoted_id} >> {quoted_log}
"""
        if regress_after_verify:
            readiness += f"""
: > "$AIRLOCK_TEST_UNIT_READY.airlock-{app_id}.service.regress"
printf 'unit-regression-armed\\t%s\\n' {quoted_id} >> {quoted_log}
"""
    write_executable(package / "install.sh", f"""#!/usr/bin/env bash
set -euo pipefail
. "$AIRLOCK_ROOT/install/lib.sh"
airlock_load "$AIRLOCK_APP_ID"
fixture_port="${{AIRLOCK_{env_id}_BACKEND_PORT:?}}"
test "$fixture_port" -gt 0
printf 'install\\t%s\\nrestart\\t%s\\n' {quoted_id} {quoted_id} >> {quoted_log}
mkdir -p "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID"
printf 'installed\\n' > "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID/marker"
{resource_apply}{failure}
""")
    write_executable(package / "smoke.sh", f"""#!/usr/bin/env bash
set -euo pipefail
printf 'smoke\\t%s\\n' {quoted_id} >> {quoted_log}
test -f "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID/marker"
{smoke_failure}{readiness}
""")
    write_executable(package / "deactivate.sh", f"""#!/usr/bin/env bash
set -euo pipefail
printf 'deactivate\\t%s\\n' {quoted_id} >> {quoted_log}
rm -f "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID/marker"
rmdir "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID" 2>/dev/null || true
""")
    return package


def write_installer_shims(root: Path, mutation_log: Path) -> Path:
    shims = root / "shims"
    shims.mkdir()
    quoted_mutations = shlex.quote(str(mutation_log))
    tailscale_state = root / "tailscale-state.json"
    tailscale_state.write_text('{"TCP":{},"Web":{}}\n', encoding="utf-8")
    quoted_tailscale_state = shlex.quote(str(tailscale_state))
    docker_state = root / "docker-state.json"
    docker_state.write_text("[]\n", encoding="utf-8")
    write_executable(shims / "sudo", f"""#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
case "${{1:-}}" in mkdir|chown|cp|install|mv|rm) printf 'sudo\\t%s\\n' "$*" >> {quoted_mutations} ;; esac
exec "$@"
""")
    write_executable(shims / "systemctl", f"""#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *list-timers*) printf '%s\\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;;
  *is-active*)
    _unit="${{!#}}"
    _unit_state="${{AIRLOCK_TEST_UNIT_READY:-/nonexistent}}.$_unit"
    [ ! -e "$_unit_state.pending" ] || exit 3
    if [ -e "$_unit_state.regress" ]; then
      [ ! -e "$_unit_state.verified" ] || exit 3
      : > "$_unit_state.verified"
    fi
    printf '%s\\n' active ;;
  *show*) printf 'LoadState=loaded\\nActiveState=inactive\\nMainPID=0\\nControlPID=0\\n' ;;
esac
if [ "${{AIRLOCK_TEST_SYSTEMCTL_RESTORE_FAIL:-0}}" = 1 ]; then
  case " $* " in *' stop '*|*' disable '*) exit 41 ;; esac
fi
case " $* " in
  *' start '*|*' stop '*|*' restart '*|*' enable '*|*' disable '*|*' daemon-reload '*|*' reload '*)
    printf 'systemctl\\t%s\\n' "$*" >> {quoted_mutations} ;;
esac
exit 0
""")
    write_executable(shims / "systemd-run", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(shims / "tailscale", f"""#!/usr/bin/env bash
set -euo pipefail
if [ "${{1:-}}" = status ] && [ "${{2:-}}" = --json ]; then
  printf '{{"BackendState":"Running","CertDomains":["example.ts.net"],"Self":{{"DNSName":"box.example.ts.net."}},"Health":[]}}\\n'
  exit 0
fi
if [ "${{1:-}}" = serve ] && [ "${{2:-}}" = status ]; then
  cat {quoted_tailscale_state}
  exit 0
fi
printf 'tailscale\\t%s\\n' "$*" >> {quoted_mutations}
if [ "${{1:-}}" = serve ]; then
  mode=""; listen=""; target=""
  shift
  for argument in "$@"; do
    case "$argument" in
      --bg) ;;
      --https=*) mode=https; listen="${{argument#*=}}" ;;
      --http=*) mode=http; listen="${{argument#*=}}" ;;
      off) target=off ;;
      http://*) target="$argument" ;;
    esac
  done
  if [ -n "$mode" ] && [ -n "$listen" ]; then
    [ "${{AIRLOCK_TEST_TAILSCALE_WRONG_TARGET:-0}}" != 1 ] \
      || target=http://127.0.0.1:1
    python3 - {quoted_tailscale_state} "$mode" "$listen" "$target" <<'PY_TS_STATE'
import json
import sys

path, mode, listen, target = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
address = f"box.example.ts.net:{{listen}}"
if target == "off":
    state.setdefault("TCP", {{}}).pop(listen, None)
    state.setdefault("Web", {{}}).pop(address, None)
else:
    state.setdefault("TCP", {{}})[listen] = {{"HTTPS": mode == "https"}}
    state.setdefault("Web", {{}})[address] = {{"Handlers": {{"/": {{"Proxy": target}}}}}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True)
    handle.write("\\n")
PY_TS_STATE
  fi
fi
exit 0
""")
    write_executable(shims / "docker", f"""#!{sys.executable}
import json
import sys

state_path = {str(docker_state)!r}
with open(state_path, encoding="utf-8") as handle:
    objects = json.load(handle)
args = sys.argv[1:]
if not args:
    raise SystemExit(2)
if args[0] == "info":
    if "--format" in args:
        print("fixture-daemon")
    raise SystemExit(0)
if args[0] == "ps":
    filters = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--filter"]
    for obj in objects:
        labels = obj["Config"].get("Labels") or {{}}
        if all(value.startswith("label=") and labels.get(value[6:].split("=", 1)[0])
               == value[6:].split("=", 1)[1] for value in filters):
            print(obj["Id"])
    raise SystemExit(0)
if args[0] == "inspect" and len(args) == 2:
    selected = [obj for obj in objects if obj["Id"] == args[1]]
    if not selected:
        raise SystemExit(1)
    print(json.dumps(selected))
    raise SystemExit(0)
if args[:2] == ["rm", "-f"] and len(args) == 3:
    objects = [obj for obj in objects if obj["Id"] != args[2]]
    with open(state_path, "w", encoding="utf-8") as handle:
        json.dump(objects, handle, sort_keys=True)
        handle.write("\\n")
    print(args[2])
    raise SystemExit(0)
raise SystemExit(2)
""")
    write_executable(shims / "nginx", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(shims / "curl", """#!/usr/bin/env bash
case "$*" in *http_code*) printf 200 ;; esac
exit 0
""")
    write_executable(shims / "loginctl", f"""#!/usr/bin/env bash
if [ "${{1:-}}" = show-user ]; then printf 'Linger=yes\\n'; exit 0; fi
printf 'loginctl\\t%s\\n' "$*" >> {quoted_mutations}
exit 0
""")
    real_python = shlex.quote(sys.executable)
    quoted_planner = shlex.quote(str(PLANNER))
    write_executable(shims / "python3", f"""#!/usr/bin/env bash
set -euo pipefail
real_python={real_python}
planner={quoted_planner}
if [ "${{1:-}}" = "$planner" ] && [ -n "${{AIRLOCK_TEST_SCOPED_SNAPSHOT_TAMPER:-}}" ]; then
  dependency_file=""
  index=1
  while [ "$index" -le "$#" ]; do
    eval "argument=\\${{$index}}"
    if [ "$argument" = --ledger-dependencies ]; then
      index=$((index + 1)); eval "dependency_file=\\${{$index}}"; break
    fi
    index=$((index + 1))
  done
  [ -n "$dependency_file" ] || exit 97
  if [ "$AIRLOCK_TEST_SCOPED_SNAPSHOT_TAMPER" = missing ]; then
    rm -f -- "$dependency_file"
    exec "$real_python" "$@"
  fi
  "$real_python" "$@"
  rc=$?
  [ "$rc" = 0 ] || exit "$rc"
  if [ "$AIRLOCK_TEST_SCOPED_SNAPSHOT_TAMPER" = mismatch ]; then
    "$real_python" - "$dependency_file" <<'PY_TAMPER'
import json, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as handle:
    value = json.load(handle)
for row in value['rows']:
    if row['app_id'] == 'olddep':
        row['deps'] = []
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write('\\n')
PY_TAMPER
  fi
  exit 0
fi
if [ "${{1:-}}" = {shlex.quote(str(LEDGER))} ] \
    && [ "${{2:-}}" = transaction-resource-result ] \
    && [ "${{3:-}}" = verify ] \
    && [ -n "${{AIRLOCK_TEST_RESOURCE_RESULT_TAMPER:-}}" ]; then
  "$real_python" "$@" >/dev/null
  "$real_python" - "$AIRLOCK_STATE_DIR/install-transaction.json" \
      "$AIRLOCK_TEST_RESOURCE_RESULT_TAMPER" "${{4:-}}" <<'PY_RESULT_TAMPER'
import hashlib
import json
import sys

transaction_path, tamper, app_id = sys.argv[1:]
with open(transaction_path, encoding="utf-8") as handle:
    transaction = json.load(handle)
value = transaction["resource_results"][app_id]["verify"]
if tamper == "wrong-binding":
    value["binding"]["plan_sha256"] = "d" * 64
elif tamper == "ownership-expansion":
    value["classes"]["filesystem"]["owned"].append({{
        "class": "files", "path": "/tmp/not-owned-by-airlock",
    }})
else:
    raise SystemExit(f"unknown resource result tamper: {{tamper}}")
body = dict(value)
body.pop("result_digest", None)
value["result_digest"] = hashlib.sha256(
    (json.dumps(body, sort_keys=True, separators=(",", ":")) + "\\n").encode()
).hexdigest()
transaction["resource_results"][app_id]["verify"] = value
with open(transaction_path, "w", encoding="utf-8") as handle:
    json.dump(transaction, handle, indent=2, sort_keys=True)
    handle.write("\\n")
PY_RESULT_TAMPER
  exit 0
fi
exec "$real_python" "$@"
""")
    return shims


def tree_digest(paths: list[Path]) -> str:
    digest_state = hashlib.sha256()
    for root in paths:
        if not root.exists():
            digest_state.update(f"missing:{root.name}\n".encode())
            continue
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            digest_state.update(f"{root.name}/{relative}\0".encode())
            if path.is_file() and not path.is_symlink():
                digest_state.update(path.read_bytes())
    return digest_state.hexdigest()


def resource_result_digest(value: dict[str, Any]) -> str:
    body = dict(value)
    body.pop("result_digest", None)
    return hashlib.sha256(
        (json.dumps(body, sort_keys=True, separators=(",", ":")) + "\n").encode()
    ).hexdigest()


def assert_resource_result(value: dict[str, Any], operation: str, app_id: str,
                           verdict: str) -> None:
    if (value.get("schema") != "airlock.resource-result/v1"
            or value.get("operation") != operation
            or value.get("app_id") != app_id
            or value.get("verdict") != verdict
            or set(value.get("classes") or {}) != {
                "filesystem", "systemd", "docker", "ingress"
            }
            or value.get("result_digest") != resource_result_digest(value)):
        raise AssertionError(f"invalid {operation} resource result: {value!r}")


def exercise_installer_flow(root: Path, counts: dict[str, int]) -> None:
    """Run the real ledger producer and installer against a scratch box."""

    noarg_result_checked = False

    def prepare(name: str, *, with_intent: bool = False) -> tuple[
            Path, Path, dict[str, str], Path, Path, list[Path]]:
        nonlocal noarg_result_checked
        scenario = root / name
        state = scenario / "state"
        webroot = scenario / "webroot"
        confd = scenario / "confd"
        units_user = scenario / "units-user"
        units_system = scenario / "units-system"
        home = scenario / "home"
        packages = scenario / "packages"
        action_log = scenario / "actions.log"
        mutation_log = scenario / "mutations.log"
        for directory in (state, webroot / "assets", confd / "hub-locations.d",
                          confd / "servers.d", units_user, units_system, home, packages):
            directory.mkdir(parents=True, exist_ok=True)
        shims = write_installer_shims(scenario, mutation_log)
        selfkill = scenario / "cgroup"
        selfkill.write_text(
            "0::/user.slice/user-1000.slice/session-fixture.scope\n", encoding="utf-8"
        )
        base = write_installer_package(
            packages, "base", port=23101, action_log=action_log
        )
        olddep = write_installer_package(
            packages, "olddep", port=23102, action_log=action_log, deps=("base",)
        )
        isolated = write_installer_package(
            packages, "isolated", port=23103, action_log=action_log
        )
        dev_monitor = write_installer_package(
            packages, "dev-monitor", port=23107, action_log=action_log
        )
        config = scenario / "airlock.toml"
        write_config(config, [
            ("olddep", olddep, 23102),
            ("isolated", isolated, 23103),
            ("dev-monitor", dev_monitor, 23107),
            ("base", base, 23101),
        ])
        env = dict(
            os.environ,
            HOME=str(home),
            PATH=f"{shims}:{os.environ['PATH']}",
            AIRLOCK_CONFIG=str(config),
            AIRLOCK_STATE_DIR=str(state),
            AIRLOCK_WEBROOT=str(webroot),
            AIRLOCK_CONFD=str(confd),
            AIRLOCK_UNIT_DIR_USER=str(units_user),
            AIRLOCK_UNIT_DIR_SYSTEM=str(units_system),
            AIRLOCK_NGINX_SITE=str(scenario / "nginx-site.conf"),
            AIRLOCK_TS_FQDN="box.example.ts.net",
            AIRLOCK_PASEO_MEM_CAP_BYTES="34359738368",
            AIRLOCK_SELFKILL_CGROUP_FILE=str(selfkill),
            AIRLOCK_TEST_DOCKER_STATE=str(scenario / "docker-state.json"),
            AIRLOCK_TEST_UNIT_READY=str(scenario / "unit-ready"),
        )
        first = run("bash", str(INSTALLER), env=env)
        if b"done" not in first.stderr and b"done" not in first.stdout:
            raise AssertionError("full installer setup did not reach its completion marker")
        if not noarg_result_checked:
            transaction = json.loads(
                (state / "install-transaction.json").read_bytes()
            )
            if "resource_results" in transaction:
                raise AssertionError("argument-free transaction acquired selected results")
            counts["noarg_resource_unchanged"] += 1
            noarg_result_checked = True
        if with_intent:
            intent_only = write_installer_package(
                scenario / "intent-package", "intentonly", port=23104,
                action_log=action_log, deps=("isolated",),
            )
            write_config(config, [
                ("olddep", olddep, 23102),
                ("isolated", isolated, 23103),
                ("dev-monitor", dev_monitor, 23107),
                ("base", base, 23101),
                ("intentonly", intent_only, 23104),
            ])
            intent_info = package_info(scenario, config).stdout
            run(sys.executable, str(LEDGER), "intent", "intentonly", env=env,
                stdin=intent_info)
        action_log.write_text("", encoding="utf-8")
        mutation_log.write_text("", encoding="utf-8")
        base_v2 = write_installer_package(
            scenario / "packages-v2", "base", port=23101, action_log=action_log
        )
        write_config(config, [
            ("isolated", isolated, 23103),
            ("dev-monitor", dev_monitor, 23107),
            ("base", base_v2, 23101),
        ])
        return scenario, config, env, action_log, mutation_log, [webroot, confd, units_user,
                                                                 units_system]

    def rejection_oracle(scenario: Path, action_log: Path, mutation_log: Path,
                         roots: list[Path]) -> dict[str, Any]:
        state = scenario / "state"
        nginx_site = scenario / "nginx-site.conf"
        hub_manifest = scenario / "webroot/__airlock.json"
        return {
            "state": tree_digest([state]),
            "roots": tree_digest(roots),
            "nginx": nginx_site.read_bytes() if nginx_site.exists() else None,
            "hub": hub_manifest.read_bytes() if hub_manifest.exists() else None,
            "actions": action_log.read_bytes(),
            "mutations": mutation_log.read_bytes(),
        }

    def assert_rejection_preserved(
            before: dict[str, Any], scenario: Path, action_log: Path,
            mutation_log: Path, roots: list[Path], label: str) -> None:
        after = rejection_oracle(scenario, action_log, mutation_log, roots)
        if after != before:
            changed = sorted(key for key in before if before[key] != after[key])
            raise AssertionError(f"{label} changed pre-mutation oracle(s): {changed!r}")

    def add_resource_candidate(
            scenario: Path, config: Path, action_log: Path, app_id: str,
            *, fail_apply: bool = False, fail_smoke: bool = False,
            regress_after_verify: bool = False) -> Path:
        candidate = write_installer_package(
            scenario / "packages-resource", app_id, port=23108,
            action_log=action_log, resource_rich=True, fail_apply=fail_apply,
            fail_smoke=fail_smoke, regress_after_verify=regress_after_verify,
        )
        write_config(config, [
            ("olddep", scenario / "packages/olddep", 23102),
            ("isolated", scenario / "packages/isolated", 23103),
            ("dev-monitor", scenario / "packages/dev-monitor", 23107),
            ("base", scenario / "packages/base", 23101),
            (app_id, candidate, 23208),
        ])
        return candidate

    def unrelated_state(scenario: Path) -> dict[str, Any]:
        app_ids = ("olddep", "isolated", "dev-monitor", "base")
        entries = json.loads(
            (scenario / "state/app-ledger.json").read_bytes()
        )["entries"]
        hub = json.loads((scenario / "webroot/__airlock.json").read_bytes())["apps"]
        return {
            "ledger": {app_id: entries.get(app_id) for app_id in app_ids},
            "hub": {app_id: hub.get(app_id) for app_id in app_ids},
        }

    def assert_resource_isolated(
            scenario: Path, action_log: Path, app_id: str,
            before: dict[str, Any]) -> dict[str, Any]:
        actions = action_log.read_text(encoding="utf-8").splitlines()
        unrelated = [
            line for line in actions
            if any(line.endswith(f"\t{other}") for other in (
                "olddep", "isolated", "dev-monitor", "base"
            ))
        ]
        transaction = json.loads(
            (scenario / "state/install-transaction.json").read_bytes()
        )
        if unrelated:
            raise AssertionError(f"resource transaction called unrelated app: {unrelated!r}")
        if set(transaction.get("resource_results") or {}) - {app_id}:
            raise AssertionError(
                f"resource results escaped selected app: {transaction['resource_results']!r}"
            )
        if unrelated_state(scenario) != before:
            raise AssertionError("resource transaction changed unrelated ledger/hub state")
        counts["resource_unrelated_zero"] += 1
        return transaction

    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "selected-success", with_intent=True
    )
    package_raw = package_info(scenario, config).stdout
    producer_plan = scenario / "producer-plan.tsv"
    producer_snapshot = scenario / "producer-dependencies.json"
    produced = run(
        sys.executable,
        str(LEDGER),
        "plan",
        "--dependency-snapshot",
        str(producer_snapshot),
        env=env,
        stdin=package_raw,
    )
    producer_plan.write_bytes(produced.stdout)
    rows = [line.split("\t") for line in produced.stdout.decode().splitlines()]
    destructive_rows = [row for row in rows if row[0] in {
        "remove", "teardown-intent", "upgrade-deactivate"
    }]
    if ({tuple(row) for row in destructive_rows} != {
            ("remove", "olddep"), ("teardown-intent", "intentonly"),
            ("upgrade-deactivate", "base")}
            or [row[1] for row in destructive_rows].index("olddep")
            >= [row[1] for row in destructive_rows].index("base")):
        raise AssertionError(f"real ledger destructive order changed: {destructive_rows!r}")
    dependency_rows = json.loads(producer_snapshot.read_bytes())["rows"]
    expected_rows = [
        {"app_id": "base", "deps": [], "record_kind": "committed"},
        {"app_id": "intentonly", "deps": ["isolated"], "record_kind": "intent"},
        {"app_id": "olddep", "deps": ["base"], "record_kind": "committed"},
    ]
    if dependency_rows != expected_rows:
        raise AssertionError(f"real ledger dependency snapshot changed: {dependency_rows!r}")
    counts["ledger_snapshot"] += 1

    # The direct producer assertion above retains intent-record coverage. A
    # selected transaction may proceed only once unrelated pending work is no
    # longer part of the candidate; clean it through the real ledger before
    # measuring the successful selected path.
    run(sys.executable, str(LEDGER), "remove", "intentonly", env=env,
        stdin=package_raw)
    action_log.write_text("", encoding="utf-8")
    _mutation_log.write_text("", encoding="utf-8")

    dry_before = rejection_oracle(scenario, action_log, _mutation_log, _roots)
    dry_env = dict(env, AIRLOCK_DRY_RUN="1")
    dry_env.pop("AIRLOCK_TS_FQDN")
    run("bash", str(INSTALLER), "--select-app=base", env=dry_env)
    assert_rejection_preserved(
        dry_before, scenario, action_log, _mutation_log, _roots,
        "selected dry-run live discovery baseline",
    )

    selected = run("bash", str(INSTALLER), "--select-app=base", env=env)
    actions = action_log.read_text(encoding="utf-8").splitlines()
    required = ["deactivate\tolddep", "deactivate\tbase", "install\tbase",
                "restart\tbase", "smoke\tbase"]
    positions = []
    for action in required:
        if action not in actions:
            raise AssertionError(f"selected installer omitted {action!r}: {actions!r}")
        positions.append(actions.index(action))
    if positions != sorted(positions):
        raise AssertionError(f"selected destructive/install order changed: {actions!r}")
    unrelated_calls = [
        line for line in actions
        if (line.endswith("\tisolated") or line.endswith("\tintentonly")
            or line.endswith("\tdev-monitor"))
    ]
    if unrelated_calls:
        raise AssertionError(f"selected installer called unrelated app: {unrelated_calls!r}")
    if b"app-scoped install transaction prepared" not in selected.stderr:
        raise AssertionError("selected installer did not use the app-scoped transaction path")
    transaction = json.loads((scenario / "state/install-transaction.json").read_bytes())
    binding = transaction.get("app_scoped_plan")
    if (not isinstance(binding, dict)
            or any(len(binding.get(key, "")) != 64
                   for key in ("plan_sha256", "dependency_snapshot_sha256"))):
        raise AssertionError(f"transaction omitted app-scoped binding: {transaction!r}")
    installed_state = json.loads((scenario / "state/app-ledger.json").read_bytes())["entries"]
    if ("olddep" in installed_state
            or "committed" not in installed_state.get("base", {})
            or "committed" not in installed_state.get("isolated", {})
            or "committed" not in installed_state.get("dev-monitor", {})
            or "intentonly" in installed_state):
        raise AssertionError(
            f"selected installer changed an unrelated ledger entry: {installed_state!r}"
        )
    counts["bound_transaction"] += 1
    counts["installer_destructive_order"] += 1
    counts["installer_selected_apps"] += 1
    counts["installer_unrelated_calls"] += len(unrelated_calls)

    # A3: the existing installer and ledger primitives produce one canonical,
    # digest-bound result for each exact resource class. This is a fresh app so
    # all four owned inventories are independently non-empty.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-four-class"
    )
    add_resource_candidate(scenario, config, action_log, "rich")
    before_unrelated = unrelated_state(scenario)
    run("bash", str(INSTALLER), "--select-app=rich", env=env)
    transaction = assert_resource_isolated(
        scenario, action_log, "rich", before_unrelated
    )
    results = transaction["resource_results"]["rich"]
    for operation, status in (("apply", "applied"), ("verify", "verified")):
        result = results[operation]
        assert_resource_result(result, operation, "rich", "passed")
        for resource_class in ("filesystem", "systemd", "docker", "ingress"):
            class_result = result["classes"][resource_class]
            if (class_result["status"] != status or not class_result["owned"]):
                raise AssertionError(
                    f"{operation} did not own {resource_class}: {class_result!r}"
                )
    rich_actions = action_log.read_text(encoding="utf-8").splitlines()
    unit_observations = results["verify"]["classes"]["systemd"]["observations"]
    if ("unit-ready\trich" not in rich_actions
            or (scenario / "unit-ready.airlock-rich.service.pending").exists()
            or len(unit_observations) != 1
            or unit_observations[0]["active"] is not True):
        raise AssertionError(
            "resource verify did not observe the post-smoke unit-ready state"
        )
    committed = json.loads(
        (scenario / "state/app-ledger.json").read_bytes()
    )["entries"]["rich"]["committed"]
    binding = results["verify"]["binding"]
    expected_binding = {
        "transaction_id": transaction["id"],
        "app_id": "rich",
        "action": transaction["actions"]["rich"],
        "config_sha256": transaction["config_sha256"],
        "package_sha256": transaction["package_sha256"],
        "source_sha256": committed["digest"],
        "plan_sha256": transaction["app_scoped_plan"]["plan_sha256"],
        "dependency_snapshot_sha256": transaction["app_scoped_plan"][
            "dependency_snapshot_sha256"
        ],
    }
    if binding != expected_binding:
        raise AssertionError(f"resource result binding drifted: {binding!r}")
    counts["resource_four_class"] += 1
    counts["resource_digest_bound"] += 1
    counts["resource_unit_ready_transition"] += 1

    # The final verify is still a strict, live commit gate. If the unit regresses
    # after that observation, commit's fresh derivation rejects the changed
    # observation and the existing restore compensates the selected app.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-unit-regression"
    )
    add_resource_candidate(
        scenario, config, action_log, "unitregress", regress_after_verify=True
    )
    before_unrelated = unrelated_state(scenario)
    rejected = run(
        "bash", str(INSTALLER), "--select-app=unitregress", env=env, ok=False
    )
    assert_rejected(rejected, "stale or its ownership/binding changed")
    transaction = assert_resource_isolated(
        scenario, action_log, "unitregress", before_unrelated
    )
    results = transaction["resource_results"]["unitregress"]
    assert_resource_result(results["apply"], "apply", "unitregress", "passed")
    assert_resource_result(results["verify"], "verify", "unitregress", "passed")
    assert_resource_result(
        results["compensate"], "compensate", "unitregress", "passed"
    )
    if (transaction["phase"] != "rolled_back"
            or "unit-regression-armed\tunitregress" not in
            action_log.read_text(encoding="utf-8").splitlines()):
        raise AssertionError("post-verify unit regression was not rejected")
    counts["resource_unit_regression_reject"] += 1
    counts["resource_compensation_success"] += 1

    # A failed smoke never obtains a final verify or commit result. The failed
    # selected transaction keeps its apply evidence and is compensated by the
    # same restore path.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-smoke-failure"
    )
    add_resource_candidate(
        scenario, config, action_log, "smokefail", fail_smoke=True
    )
    before_unrelated = unrelated_state(scenario)
    run("bash", str(INSTALLER), "--select-app=smokefail", env=env, ok=False)
    transaction = assert_resource_isolated(
        scenario, action_log, "smokefail", before_unrelated
    )
    results = transaction["resource_results"]["smokefail"]
    assert_resource_result(results["apply"], "apply", "smokefail", "passed")
    assert_resource_result(
        results["compensate"], "compensate", "smokefail", "passed"
    )
    if "verify" in results or transaction["phase"] != "rolled_back":
        raise AssertionError("smoke failure reached verify/commit or escaped restore")
    counts["resource_smoke_failure_reject"] += 1
    counts["resource_compensation_success"] += 1

    # Provider apply failure is recorded before the existing transaction restore
    # runs. The restore then records a separate successful compensation result.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-apply-failure"
    )
    add_resource_candidate(
        scenario, config, action_log, "applyfail", fail_apply=True
    )
    before_unrelated = unrelated_state(scenario)
    run("bash", str(INSTALLER), "--select-app=applyfail", env=env, ok=False)
    transaction = assert_resource_isolated(
        scenario, action_log, "applyfail", before_unrelated
    )
    results = transaction["resource_results"]["applyfail"]
    assert_resource_result(results["apply"], "apply", "applyfail", "failed")
    assert_resource_result(
        results["compensate"], "compensate", "applyfail", "passed"
    )
    if (transaction["phase"] != "rolled_back"
            or (scenario / "webroot/applyfail/marker").exists()
            or (scenario / "units-user/airlock-applyfail.service").exists()
            or json.loads((scenario / "docker-state.json").read_bytes())):
        raise AssertionError("apply failure did not compensate its owned resources")
    counts["resource_apply_failure"] += 1
    counts["resource_compensation_success"] += 1

    # Verification failure is measured independently from apply. The Tailscale
    # shim records an exact wrong proxy target; verify refuses it and restore
    # compensates the touched app.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-verify-failure"
    )
    add_resource_candidate(scenario, config, action_log, "verifyfail")
    before_unrelated = unrelated_state(scenario)
    failed_env = dict(env, AIRLOCK_TEST_TAILSCALE_WRONG_TARGET="1")
    run("bash", str(INSTALLER), "--select-app=verifyfail", env=failed_env, ok=False)
    transaction = assert_resource_isolated(
        scenario, action_log, "verifyfail", before_unrelated
    )
    results = transaction["resource_results"]["verifyfail"]
    assert_resource_result(results["apply"], "apply", "verifyfail", "passed")
    assert_resource_result(results["verify"], "verify", "verifyfail", "failed")
    assert_resource_result(
        results["compensate"], "compensate", "verifyfail", "passed"
    )
    if transaction["phase"] != "rolled_back":
        raise AssertionError("verify failure did not roll back the selected transaction")
    counts["resource_verify_failure"] += 1
    counts["resource_compensation_success"] += 1

    # A teardown provider failure is not relabeled as successful compensation.
    # Existing recovery debt remains recorded by the existing degraded phase.
    scenario, config, env, action_log, _mutation_log, _roots = prepare(
        "resource-compensation-failure"
    )
    add_resource_candidate(
        scenario, config, action_log, "compfail", fail_apply=True
    )
    before_unrelated = unrelated_state(scenario)
    failed_env = dict(env, AIRLOCK_TEST_SYSTEMCTL_RESTORE_FAIL="1")
    run("bash", str(INSTALLER), "--select-app=compfail", env=failed_env, ok=False)
    transaction = assert_resource_isolated(
        scenario, action_log, "compfail", before_unrelated
    )
    results = transaction["resource_results"]["compfail"]
    assert_resource_result(results["apply"], "apply", "compfail", "failed")
    assert_resource_result(
        results["compensate"], "compensate", "compfail", "failed"
    )
    if transaction["phase"] != "degraded":
        raise AssertionError("compensation failure did not retain degraded recovery debt")
    counts["resource_compensation_failure"] += 1

    # Commit consumes the exact verify result already stored by the transaction.
    # Even a self-consistent replacement digest cannot widen ownership or change
    # a binding: both mutations fail commit and enter the existing restore path.
    for tamper in ("wrong-binding", "ownership-expansion"):
        scenario, config, env, action_log, _mutation_log, _roots = prepare(
            f"resource-{tamper}"
        )
        app_id = tamper.replace("-", "")
        add_resource_candidate(scenario, config, action_log, app_id)
        before_unrelated = unrelated_state(scenario)
        tampered_env = dict(env, AIRLOCK_TEST_RESOURCE_RESULT_TAMPER=tamper)
        rejected = run(
            "bash", str(INSTALLER), f"--select-app={app_id}",
            env=tampered_env, ok=False,
        )
        assert_rejected(rejected, "stale or its ownership/binding changed")
        transaction = assert_resource_isolated(
            scenario, action_log, app_id, before_unrelated
        )
        if transaction["phase"] != "rolled_back":
            raise AssertionError(f"{tamper} did not enter the restore path")
        counts[f"resource_{tamper.replace('-', '_')}_reject"] += 1

    # The Opus review counterexample: adding a fresh disconnected package while
    # selecting only base used to publish its global port and launcher entry
    # without install, smoke, commit, or a webroot. The planner now refuses the
    # unsafe candidate before transaction creation or any global mutation.
    scenario, config, env, action_log, mutation_log, roots = prepare(
        "reject-unselected-fresh"
    )
    newapp = write_installer_package(
        scenario / "packages-new", "newapp", port=23105, action_log=action_log
    )
    write_config(config, [
        ("isolated", scenario / "packages/isolated", 23103),
        ("dev-monitor", scenario / "packages/dev-monitor", 23107),
        ("base", scenario / "packages-v2/base", 23101),
        ("newapp", newapp, 23105),
    ])
    before = rejection_oracle(scenario, action_log, mutation_log, roots)
    rejected = run("bash", str(INSTALLER), "--select-app=base", env=env, ok=False)
    assert_rejected(rejected, "newapp (fresh; serve mapping differs)")
    assert_rejection_preserved(
        before, scenario, action_log, mutation_log, roots, "unselected fresh package"
    )
    hub_apps = json.loads((scenario / "webroot/__airlock.json").read_bytes())["apps"]
    ledger_entries = json.loads(
        (scenario / "state/app-ledger.json").read_bytes()
    )["entries"]
    if ("newapp" in hub_apps or "newapp" in ledger_entries
            or (scenario / "webroot/newapp").exists()
            or b"23105" in mutation_log.read_bytes()):
        raise AssertionError("fresh rejection left an uninstalled publication surface")
    counts["publication_reject"] += 1
    counts["publication_mutation_zero"] += 1

    # Full mode remains the control: the same new package is installed, smoked,
    # committed and only then observed in the global discovery/port surfaces.
    scenario, config, env, action_log, mutation_log, _roots = prepare(
        "full-newapp-control"
    )
    newapp = write_installer_package(
        scenario / "packages-new", "newapp", port=23105, action_log=action_log
    )
    write_config(config, [
        ("isolated", scenario / "packages/isolated", 23103),
        ("dev-monitor", scenario / "packages/dev-monitor", 23107),
        ("base", scenario / "packages-v2/base", 23101),
        ("newapp", newapp, 23105),
    ])
    run("bash", str(INSTALLER), env=env)
    actions = action_log.read_text(encoding="utf-8").splitlines()
    full_required = {"install\tnewapp", "restart\tnewapp", "smoke\tnewapp"}
    full_ledger = json.loads(
        (scenario / "state/app-ledger.json").read_bytes()
    )["entries"]
    full_hub = json.loads((scenario / "webroot/__airlock.json").read_bytes())["apps"]
    if (not full_required <= set(actions)
            or "committed" not in full_ledger.get("newapp", {})
            or "newapp" not in full_hub
            or not (scenario / "webroot/newapp/marker").is_file()
            or b"23105" not in mutation_log.read_bytes()):
        raise AssertionError("full control published newapp before its install contract held")
    counts["full_newapp_published"] += 1

    # A same-tree unrelated package with a changed resolved serve mapping still
    # has the legacy reinstall action. The bound sidecar names that mapping
    # difference, allowing selected planning to reject it before publication.
    scenario, config, env, action_log, mutation_log, roots = prepare(
        "reject-unselected-port-change"
    )
    write_config(config, [
        ("isolated", scenario / "packages/isolated", 23106),
        ("dev-monitor", scenario / "packages/dev-monitor", 23107),
        ("base", scenario / "packages-v2/base", 23101),
    ])
    legacy_mapping_plan = run(
        sys.executable, str(LEDGER), "plan", env=env,
        stdin=package_info(scenario, config).stdout,
    )
    legacy_mapping_actions = {
        app_id: action
        for action, app_id in (
            line.split("\t")
            for line in legacy_mapping_plan.stdout.decode().splitlines()
        )
    }
    if legacy_mapping_actions.get("isolated") != "reinstall":
        raise AssertionError(
            f"snapshot-free full action changed: {legacy_mapping_actions!r}"
        )
    counts["full_mapping_action_unchanged"] += 1
    before = rejection_oracle(scenario, action_log, mutation_log, roots)
    rejected = run("bash", str(INSTALLER), "--select-app=base", env=env, ok=False)
    assert_rejected(rejected, "isolated (reinstall; serve mapping differs)")
    assert_rejection_preserved(
        before, scenario, action_log, mutation_log, roots,
        "unselected committed port change",
    )
    counts["publication_reject"] += 1
    counts["publication_mutation_zero"] += 1

    # The platform hub is an existing app outside the package transaction and
    # therefore absent from the ledger's lifecycle classification. The
    # installed-vs-candidate discovery oracle is the independent backstop for
    # its publication change.
    scenario, config, env, action_log, mutation_log, roots = prepare(
        "reject-unselected-discovery-change"
    )
    config.write_text(
        config.read_text(encoding="utf-8").replace(
            "[apps.hub]",
            "[apps.hub]\nhttps_port = 444",
        ),
        encoding="utf-8",
    )
    before = rejection_oracle(scenario, action_log, mutation_log, roots)
    rejected = run("bash", str(INSTALLER), "--select-app=base", env=env, ok=False)
    assert_rejected(rejected, "unselected discovery projection differs")
    assert_rejection_preserved(
        before, scenario, action_log, mutation_log, roots,
        "unselected existing hub discovery change",
    )
    counts["publication_reject"] += 1
    counts["publication_mutation_zero"] += 1

    # A prior committed dev-monitor activation debt is recovery state, not
    # authority to escape the new selection. Keep the record byte-identical and
    # refuse before the selected transaction exists when dev-monitor is outside
    # the chosen safety group.
    scenario, config, env, action_log, mutation_log, roots = prepare(
        "reject-unselected-devmon-owed"
    )
    activation = scenario / "state/dev-monitor-activation.json"
    activation.write_text(json.dumps({
        "version": 1,
        "transaction_id": "a" * 32,
        "database": str(scenario / "home/.local/state/airlock/dev-monitor/messages.db"),
        "writer_user": "fixture_writer",
        "backend_port": 23107,
        "app_id": "dev-monitor",
    }, sort_keys=True) + "\n", encoding="utf-8")
    activation.chmod(0o600)
    before = rejection_oracle(scenario, action_log, mutation_log, roots)
    rejected = run("bash", str(INSTALLER), "--select-app=base", env=env, ok=False)
    assert_rejected(rejected, "excludes owed activation for 'dev-monitor'")
    assert_rejection_preserved(
        before, scenario, action_log, mutation_log, roots,
        "unselected dev-monitor activation debt",
    )
    counts["owed_activation_reject"] += 1
    counts["owed_activation_mutation_zero"] += 1

    for tamper, expected_error in (
        ("missing", "app-scoped plan refused the locked candidate"),
        ("mismatch", "cannot verify app-scoped plan binding"),
    ):
        scenario, config, env, action_log, mutation_log, roots = prepare(f"reject-{tamper}")
        state = scenario / "state"
        before_ledger = (state / "app-ledger.json").read_bytes()
        before_transaction = (state / "install-transaction.json").read_bytes()
        before_roots = tree_digest(roots)
        rejected_env = dict(env, AIRLOCK_TEST_SCOPED_SNAPSHOT_TAMPER=tamper)
        rejected = run(
            "bash", str(INSTALLER), "--select-app=base", env=rejected_env, ok=False
        )
        message = rejected.stderr.decode(errors="replace")
        if expected_error not in message:
            raise AssertionError(
                f"{tamper} snapshot rejection had the wrong error:\n{message}"
            )
        if ((state / "app-ledger.json").read_bytes() != before_ledger
                or (state / "install-transaction.json").read_bytes() != before_transaction
                or tree_digest(roots) != before_roots
                or action_log.read_text(encoding="utf-8")
                or mutation_log.read_text(encoding="utf-8")):
            raise AssertionError(f"{tamper} snapshot rejection mutated the scratch box")
        counts["evidence_reject"] += 1
        counts["mutation_zero"] += 1


def assert_rejected(result: subprocess.CompletedProcess[bytes], needle: str) -> None:
    message = result.stderr.decode(errors="replace")
    if needle not in message:
        raise AssertionError(f"expected rejection containing {needle!r}, got:\n{message}")


def canonical_reordered(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: canonical_reordered(value[key]) for key in reversed(list(value))}
    if isinstance(value, list):
        return [canonical_reordered(item) for item in value]
    return value


def release_package_digest(root: Path) -> str:
    """Fixture copy of the public release.lock package digest ABI."""
    rows = []
    for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(item.relative_to(root))):
        relative = path.relative_to(root).as_posix()
        if path.is_dir():
            continue
        if path.is_symlink():
            rows.append({
                "mode": "0777", "path": relative,
                "target": os.readlink(path), "type": "symlink",
            })
        else:
            rows.append({
                "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
                "mode": f"{path.stat().st_mode & 0o7777:04o}",
                "path": relative, "type": "file",
            })
    raw = (json.dumps(
        rows, ensure_ascii=False, separators=(",", ":"), sort_keys=True,
    ) + "\n").encode()
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def exercise_managed_ledger_binding(root: Path, counts: dict[str, int]) -> None:
    """Prove the v7 persistence slice without claiming issuer authentication.

    The future installer adapter supplies the already-authenticated sidecar. This
    fixture proves the ledger accepts it only when its SHA, transaction bindings,
    package-info source/digest/capabilities and package tree all agree.
    """

    def setup(name: str) -> tuple[Path, dict[str, str], bytes, bytes, dict[str, Any]]:
        scenario = root / name
        scenario.mkdir(parents=True)
        scenario.chmod(0o700)
        package = write_package(
            scenario / "packages", "managedapp", port=24101, webroot="managedapp/",
            claim_port=False,
        )
        (scenario / "webroot/managedapp").mkdir(parents=True)
        config = scenario / "airlock.toml"
        write_config(config, [("managedapp", package, 24101)])
        env = config_env(scenario, config)
        explicit_raw = package_info(scenario, config).stdout
        digest_result = run(
            sys.executable, str(LEDGER), "intent", "managedapp",
            env=env, stdin=explicit_raw,
        )
        package_digest = digest_result.stdout.decode().strip()
        signed_package_digest = release_package_digest(package)
        if signed_package_digest == "sha256:" + package_digest:
            raise AssertionError("fixture failed to distinguish release and ledger digest ABIs")
        (scenario / "state/app-ledger.json").unlink()
        info = json.loads(explicit_raw)
        package_row = info["packages"]["managedapp"]
        package_row["source_class"] = "managed"
        package_row["signed_package_digest"] = signed_package_digest
        managed_raw = (
            json.dumps(info, indent=2, sort_keys=True) + "\n"
        ).encode()
        authority = {
            "anchor_sha256": "1" * 64,
            "authority_membership_digest": "sha256:" + "2" * 64,
            "authority_sequence": 7,
            "capabilities": list(package_row["capabilities"]),
            "channel_id": "stable",
            "config_sha256": "3" * 64,
            "core_digest": "sha256:" + "4" * 64,
            "core_revision": "5" * 40,
            "enrollment_digest": "sha256:" + "6" * 64,
            "epoch": 2,
            "fetched_public_revision": "7" * 40,
            "installed_measurer_sha256": "8" * 64,
            "lock_digest": "sha256:" + "9" * 64,
            "next_measurer_sha256": "a" * 64,
            "organization_id": "fixture-org",
            "package_digest": signed_package_digest,
            "promotion_receipt_digest": "sha256:" + "b" * 64,
            "public_tree": "c" * 40,
            "publisher_key_id": "sha256:" + "d" * 64,
            "receipt_sha256": "e" * 64,
            "root_key_id": "sha256:" + "f" * 64,
            "schema": "airlock.managed.intent-authority/v1",
            "selection_digest": "sha256:" + "1" * 64,
            "selection_sequence": 5,
            "sequence": 11,
            "snapshot_digest": "sha256:" + "2" * 64,
            "state_digest": "sha256:" + "3" * 64,
            "target_profile": "linux-x86_64",
        }
        return scenario, env, explicit_raw, managed_raw, authority

    def transaction_env(env: dict[str, str], package_raw: bytes) -> dict[str, str]:
        return dict(
            env,
            AIRLOCK_CONFIG_SNAPSHOT_SHA256="3" * 64,
            AIRLOCK_INSTALL_PKG_INFO_SHA256=hashlib.sha256(package_raw).hexdigest(),
            AIRLOCK_APP_SCOPED_PLAN_SHA256="4" * 64,
            AIRLOCK_LEDGER_DEPENDENCIES_SHA256="5" * 64,
        )

    def sidecar(scenario: Path, authority: dict[str, Any], *,
                name: str = "managed-authorities.json") -> tuple[Path, str]:
        run_dir = scenario / "run"
        run_dir.mkdir(exist_ok=True)
        run_dir.chmod(0o700)
        path = run_dir / name
        raw = (
            json.dumps({
                "authorities": {"managedapp": authority},
                "schema": "airlock.managed.run-authorities/v1",
            }, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()
        path.write_bytes(raw)
        path.chmod(0o600)
        return path, hashlib.sha256(raw).hexdigest()

    def begin(env: dict[str, str], package_raw: bytes | None = None,
              path: Path | None = None, digest: str | None = None, *,
              ok: bool = True) -> subprocess.CompletedProcess[bytes]:
        args = [sys.executable, str(LEDGER), "transaction-begin"]
        if path is not None:
            args.extend((
                f"--managed-authority-file={path}",
                f"--managed-authority-sha256={digest}",
            ))
        args.append("fresh:managedapp")
        return run(*args, env=env, stdin=package_raw, ok=ok)

    # Positive: the exact sidecar is made durable in the existing transaction,
    # then copied into intent and committed without recomputation.
    scenario, env, _explicit_raw, managed_raw, authority = setup("bound")
    bound_env = transaction_env(env, managed_raw)
    authority_path, authority_sha = sidecar(scenario, authority)
    begin(bound_env, managed_raw, authority_path, authority_sha)
    transaction = json.loads(
        (scenario / "state/install-transaction.json").read_bytes()
    )
    if (transaction.get("managed_authorities") != {"managedapp": authority}
            or transaction.get("managed_authority_sha256") != authority_sha):
        raise AssertionError("transaction did not persist the exact managed authority")
    run(sys.executable, str(LEDGER), "intent", "managedapp",
        env=bound_env, stdin=managed_raw)
    intent = json.loads(
        (scenario / "state/app-ledger.json").read_bytes()
    )["entries"]["managedapp"]["intent"]
    if intent.get("managed_authority") != authority:
        raise AssertionError("intent did not copy the transaction managed authority")
    run(sys.executable, str(LEDGER), "transaction-touch", "managedapp", env=bound_env)
    for operation in ("apply", "verify"):
        run(sys.executable, str(LEDGER), "transaction-resource-result",
            operation, "managedapp", "passed", env=bound_env)
    run(sys.executable, str(LEDGER), "commit", "managedapp",
        env=bound_env, stdin=managed_raw)
    committed = json.loads(
        (scenario / "state/app-ledger.json").read_bytes()
    )["entries"]["managedapp"]["committed"]
    if committed.get("managed_authority") != authority:
        raise AssertionError("commit did not copy the intent managed authority")
    rejected = run(sys.executable, str(LEDGER), "transaction-finish", "committed",
                   env=bound_env, ok=False)
    assert_rejected(rejected, "requires an owed trusted measurer activation")
    run(sys.executable, str(LEDGER), "transaction-trusted-measurer-owed", env=bound_env)
    transaction = json.loads(
        (scenario / "state/install-transaction.json").read_bytes()
    )
    activation = transaction.get("trusted_measurer_activation")
    if (not isinstance(activation, dict) or activation.get("state") != "owed"
            or activation.get("old_sha256") != authority["installed_measurer_sha256"]
            or activation.get("new_sha256") != authority["next_measurer_sha256"]
            or transaction["id"] not in activation.get("old_path", "")
            or transaction["id"] not in activation.get("new_path", "")):
        raise AssertionError("transaction did not bind the exact owed measurer activation")
    run(sys.executable, str(LEDGER), "transaction-finish", "committed", env=bound_env)
    rejected = begin(bound_env, managed_raw, authority_path, authority_sha, ok=False)
    assert_rejected(rejected, "still owes trusted measurer activation")
    run(sys.executable, str(LEDGER), "transaction-trusted-measurer-durable", env=bound_env)
    run(sys.executable, str(LEDGER), "transaction-show", env=bound_env)
    counts["managed_sidecar_bound"] += 1
    counts["managed_intent_commit_copy"] += 1
    counts["managed_signed_tree_digest"] += 1
    counts["managed_recovery_valid"] += 1
    counts["trusted_measurer_owed_durable"] += 1
    counts["trusted_measurer_next_transaction_reject"] += 1

    # Managed authority can bind only capabilities already grantable under the
    # public ledger contract. A wider receipt surface is not a ledger grant:
    # both a shipped-only name and an unknown name fail before transaction
    # admission, so neither can become a durable intent or commit.
    for scenario_name, capability, count_key in (
        ("nongrantable-capability", "plaintext-redirect",
         "managed_nongrantable_capability_reject"),
        ("unknown-capability", "not-a-capability",
         "managed_unknown_capability_reject"),
    ):
        scenario, env, _explicit_raw, managed_raw, authority = setup(scenario_name)
        info = json.loads(managed_raw)
        info["packages"]["managedapp"]["capabilities"] = [capability]
        rejected_raw = (
            json.dumps(info, indent=2, sort_keys=True) + "\n"
        ).encode()
        rejected_authority = copy.deepcopy(authority)
        rejected_authority["capabilities"] = [capability]
        rejected_path, rejected_sha = sidecar(scenario, rejected_authority)
        rejected = begin(
            transaction_env(env, rejected_raw), rejected_raw,
            rejected_path, rejected_sha, ok=False,
        )
        assert_rejected(rejected, "unknown capability")
        if (scenario / "state/install-transaction.json").exists():
            raise AssertionError(
                f"managed {capability} capability entered a durable transaction"
            )
        if (scenario / "state/app-ledger.json").exists():
            raise AssertionError(
                f"managed {capability} capability wrote a ledger record"
            )
        counts[count_key] += 1

    # Commit re-hashes the package tree: a correct intent/sidecar cannot carry
    # later candidate bytes into a committed managed record.
    scenario, env, _explicit_raw, managed_raw, authority = setup("commit-tree-change")
    changed_env = transaction_env(env, managed_raw)
    changed_path, changed_sha = sidecar(scenario, authority)
    begin(changed_env, managed_raw, changed_path, changed_sha)
    run(sys.executable, str(LEDGER), "intent", "managedapp",
        env=changed_env, stdin=managed_raw)
    package_script = scenario / "packages/managedapp/install.sh"
    package_script.write_text(
        package_script.read_text(encoding="utf-8") + "# changed after intent\n",
        encoding="utf-8",
    )
    rejected = run(sys.executable, str(LEDGER), "commit", "managedapp",
                   env=changed_env, stdin=managed_raw, ok=False)
    assert_rejected(rejected, "tree changed between intent and commit")
    changed_store = json.loads((scenario / "state/app-ledger.json").read_bytes())
    if "committed" in changed_store["entries"]["managedapp"]:
        raise AssertionError("changed managed package tree was committed")
    counts["managed_commit_tree_reject"] += 1

    # Enum-only managed input has no grant: even a scoped transaction is not a
    # substitute for the paired sidecar and exact package binding.
    scenario, env, _explicit_raw, managed_raw, _authority = setup("enum-only")
    unbound_env = transaction_env(env, managed_raw)
    begin(unbound_env)
    rejected = run(sys.executable, str(LEDGER), "intent", "managedapp",
                   env=unbound_env, stdin=managed_raw, ok=False)
    assert_rejected(rejected, "no transaction-bound authority")
    if (scenario / "state/app-ledger.json").exists():
        raise AssertionError("enum-only managed input wrote a ledger intent")
    counts["managed_enum_only_reject"] += 1

    # A structurally valid, re-hashed sidecar is still not authority when its
    # package digest disagrees with authenticated package-info and actual bytes.
    scenario, env, _explicit_raw, managed_raw, authority = setup("forged-binding")
    forged = copy.deepcopy(authority)
    forged["package_digest"] = "sha256:" + "0" * 64
    forged_path, forged_sha = sidecar(scenario, forged)
    forged_env = transaction_env(env, managed_raw)
    rejected = begin(forged_env, managed_raw, forged_path, forged_sha, ok=False)
    assert_rejected(rejected, "differs from signed package digest")
    if (scenario / "state/install-transaction.json").exists():
        raise AssertionError("forged managed binding created a transaction")
    counts["managed_forged_sidecar_reject"] += 1

    # Sidecar SHA and transaction config binding fail before a transaction is
    # created. A sidecar also cannot relabel an explicit package as managed.
    scenario, env, explicit_raw, managed_raw, authority = setup("sidecar-refusals")
    valid_path, valid_sha = sidecar(scenario, authority)
    tx_env = transaction_env(env, managed_raw)
    rejected = begin(tx_env, managed_raw, valid_path, "0" * 64, ok=False)
    assert_rejected(rejected, "differs from its supplied SHA-256")
    if (scenario / "state/install-transaction.json").exists():
        raise AssertionError("wrong sidecar digest created a transaction")
    counts["managed_forged_sidecar_reject"] += 1

    wrong_config = copy.deepcopy(authority)
    wrong_config["config_sha256"] = "0" * 64
    wrong_path, wrong_sha = sidecar(scenario, wrong_config, name="wrong-config.json")
    rejected = begin(tx_env, managed_raw, wrong_path, wrong_sha, ok=False)
    assert_rejected(rejected, "differs from config binding")
    if (scenario / "state/install-transaction.json").exists():
        raise AssertionError("wrong config binding created a transaction")
    counts["managed_forged_sidecar_reject"] += 1

    rejected = begin(
        transaction_env(env, explicit_raw), explicit_raw, valid_path, valid_sha,
        ok=False,
    )
    assert_rejected(rejected, "differ from planned managed packages")
    if (scenario / "state/app-ledger.json").exists():
        raise AssertionError("managed sidecar relabelled an explicit package")
    counts["managed_forged_sidecar_reject"] += 1

    # Existing restore uses its pre-run ledger snapshot; managed authority does
    # not survive a failed fresh transaction as an orphaned grant.
    scenario, env, _explicit_raw, managed_raw, authority = setup("restore")
    restore_env = transaction_env(env, managed_raw)
    restore_path, restore_sha = sidecar(scenario, authority)
    begin(restore_env, managed_raw, restore_path, restore_sha)
    run(sys.executable, str(LEDGER), "intent", "managedapp",
        env=restore_env, stdin=managed_raw)
    run(sys.executable, str(LEDGER), "transaction-touch", "managedapp", env=restore_env)
    run(sys.executable, str(LEDGER), "transaction-trusted-measurer-owed", env=restore_env)
    rejected = run(sys.executable, str(LEDGER), "transaction-restore",
                   env=restore_env, ok=False)
    assert_rejected(rejected, "must be restored and cleared")
    run(sys.executable, str(LEDGER), "transaction-trusted-measurer-clear", env=restore_env)
    run(sys.executable, str(LEDGER), "transaction-fail", "fixture", "managedapp",
        env=restore_env)
    run(sys.executable, str(LEDGER), "transaction-restore", env=restore_env)
    restored = json.loads((scenario / "state/app-ledger.json").read_bytes())
    restored_tx = json.loads(
        (scenario / "state/install-transaction.json").read_bytes()
    )
    if restored["entries"] or restored_tx["phase"] != "rolled_back":
        raise AssertionError("managed rollback did not restore the pre-run ledger")
    counts["managed_restore"] += 1
    counts["trusted_measurer_restore_gate"] += 1

    # Recovery/load rejects a corrupt durable authority rather than silently
    # dropping it. The healthy transaction-show case was measured above.
    transaction_path = scenario.parent / "bound/state/install-transaction.json"
    corrupt = json.loads(transaction_path.read_bytes())
    corrupt["managed_authorities"]["managedapp"]["capabilities"] = ["not-a-capability"]
    transaction_path.write_text(
        json.dumps(corrupt, indent=2, sort_keys=True) + "\n", encoding="utf-8",
    )
    rejected = run(sys.executable, str(LEDGER), "transaction-show",
                   env=transaction_env(
                       config_env(scenario.parent / "bound", scenario.parent / "bound/airlock.toml"),
                       managed_raw,
                   ), ok=False)
    assert_rejected(rejected, "unknown capability")
    counts["managed_recovery_corrupt_reject"] += 1

    # Every prior ledger version normalises to v7 with null authority and keeps
    # its actual legacy source classification. The write is triggered through
    # the existing ordinary explicit intent path, not a migration-only command.
    seed, seed_env, explicit_raw, _managed_raw, _authority = setup("migration-seed")
    run(sys.executable, str(LEDGER), "intent", "managedapp",
        env=seed_env, stdin=explicit_raw)
    run(sys.executable, str(LEDGER), "commit", "managedapp",
        env=seed_env, stdin=explicit_raw)
    run(sys.executable, str(LEDGER), "intent", "managedapp",
        env=seed_env, stdin=explicit_raw)
    current = json.loads((seed / "state/app-ledger.json").read_bytes())

    def as_legacy(version: int) -> dict[str, Any]:
        legacy = copy.deepcopy(current)
        legacy["version"] = version
        if version < 5:
            legacy.pop("events", None)
        for entry in legacy["entries"].values():
            for kind in ("committed", "intent"):
                record = entry.get(kind)
                if record is None:
                    continue
                record.pop("managed_authority", None)
                if version < 6:
                    record.pop("container_runtime", None)
                if version < 4:
                    record.pop("capabilities", None)
                if version < 3:
                    record.pop("serve_mappings", None)
                    record.pop("unit_scopes", None)
                    record.pop("order", None)
                    record.pop("source_class", None)
                    artifacts = (record["artifacts_declared"] if kind == "intent"
                                 else record["artifacts"])
                    artifacts.pop("rooted", None)
                    if kind == "committed":
                        record.pop("roots", None)
                else:
                    record["source_class"] = "shipped"
                if version < 2:
                    record.pop("deps", None)
                    if kind == "intent":
                        record.pop("anchors", None)
        return legacy

    for version in range(1, 7):
        migration = root / f"migration-v{version}"
        state = migration / "state"
        state.mkdir(parents=True)
        state.chmod(0o700)
        ledger_path = state / "app-ledger.json"
        ledger_path.write_text(
            json.dumps(as_legacy(version), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        migration_env = dict(seed_env, AIRLOCK_STATE_DIR=str(state))
        run(sys.executable, str(LEDGER), "intent", "managedapp",
            env=migration_env, stdin=explicit_raw)
        migrated = json.loads(ledger_path.read_bytes())
        expected_committed_source = "explicit" if version < 3 else "shipped"
        records = migrated["entries"]["managedapp"]
        if (migrated["version"] != 7
                or records["committed"]["source_class"] != expected_committed_source
                or records["intent"]["source_class"] != "explicit"
                or any(record.get("managed_authority", "missing") is not None
                       for record in records.values())):
            raise AssertionError(f"v{version} did not migrate conservatively: {migrated!r}")
        counts["managed_migration"] += 1


def exercise_trusted_measurer_activation(root: Path, counts: dict[str, int]) -> None:
    """Execute the installer's real bounded root helper in a private mount namespace."""
    root.mkdir(parents=True)
    libexec = root / "libexec"
    libexec.mkdir(mode=0o755)
    old = b"#!/usr/bin/env python3\nprint('old trusted measurer')\n"
    new = b"#!/usr/bin/env python3\nprint('new trusted measurer')\n"
    (libexec / "airlock-managed-release").write_bytes(old)
    (libexec / "airlock-managed-release").chmod(0o555)
    next_path = root / "next-airlock-managed-release"
    next_path.write_bytes(new)
    next_path.chmod(0o600)
    old_sha = hashlib.sha256(old).hexdigest()
    new_sha = hashlib.sha256(new).hexdigest()
    txid = "1" * 32

    installer = INSTALLER.read_text(encoding="utf-8")
    start = installer.index("_airlock_trusted_measurer_root() {")
    end = installer.index("\nPY\n}\n", start) + len("\nPY\n}")
    helper = installer[start:end]
    script = root / "exercise-root-helper.sh"
    script.write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        "airlock_run() { [ \"$1\" != sudo ] || shift; \"$@\"; }\n"
        + helper + "\n"
        + "mount --bind \"$1\" /opt/airlock/libexec\n"
        + "target=/opt/airlock/libexec/airlock-managed-release\n"
        + "tx=$2; old=$3; new=$4; next=$5\n"
        + "_airlock_trusted_measurer_root stage \"$tx\" \"$old\" \"$new\" \"$next\"\n"
        + "test \"$(sha256sum \"$target\" | awk '{print $1}')\" = \"$old\"\n"
        + "_airlock_trusted_measurer_root forward \"$tx\" \"$old\" \"$new\"\n"
        + "_airlock_trusted_measurer_root forward \"$tx\" \"$old\" \"$new\"\n"
        + "test \"$(sha256sum \"$target\" | awk '{print $1}')\" = \"$new\"\n"
        + "_airlock_trusted_measurer_root rollback \"$tx\" \"$old\" \"$new\"\n"
        + "_airlock_trusted_measurer_root rollback \"$tx\" \"$old\" \"$new\"\n"
        + "test \"$(sha256sum \"$target\" | awk '{print $1}')\" = \"$old\"\n"
        + "_airlock_trusted_measurer_root cleanup-old \"$tx\" \"$old\" \"$new\"\n"
        + "test ! -e /opt/airlock/libexec/.airlock-managed-release.${tx}.old\n"
        + "test ! -e /opt/airlock/libexec/.airlock-managed-release.${tx}.new\n"
        + "if _airlock_trusted_measurer_root stage \"$tx\" \"$(printf 0%.0s {1..64})\" \"$new\" \"$next\"; then exit 91; fi\n"
        + "test \"$(sha256sum \"$target\" | awk '{print $1}')\" = \"$old\"\n"
        + "_airlock_trusted_measurer_root stage \"$tx\" \"$old\" \"$new\" \"$next\"\n"
        + "_airlock_trusted_measurer_root forward \"$tx\" \"$old\" \"$new\"\n"
        + "printf malformed > /opt/airlock/libexec/.airlock-managed-release.${tx}.old\n"
        + "chmod 0555 /opt/airlock/libexec/.airlock-managed-release.${tx}.old\n"
        + "if _airlock_trusted_measurer_root rollback \"$tx\" \"$old\" \"$new\"; then exit 92; fi\n"
        + "test \"$(sha256sum \"$target\" | awk '{print $1}')\" = \"$new\"\n"
        + "printf 'root-helper-positive-and-refusals=PASS\\n'\n",
        encoding="utf-8",
    )
    script.chmod(0o700)
    result = run(
        "unshare", "-Urnm", "bash", str(script), str(libexec), txid,
        old_sha, new_sha, str(next_path),
    )
    if b"root-helper-positive-and-refusals=PASS" not in result.stdout:
        raise AssertionError("trusted measurer root helper did not emit its positive control")
    counts["trusted_measurer_forward_retry"] += 1
    counts["trusted_measurer_rollback_retry"] += 1
    counts["trusted_measurer_wrong_binding_reject"] += 1
    counts["trusted_measurer_malformed_old_reject"] += 1


def exercise(emit_ac: bool) -> None:
    counts = {
        "global_valid": 0,
        "port_reject": 0,
        "path_reject": 0,
        "ingress_reject": 0,
        "cycle_reject": 0,
        "stable_groups": 0,
        "handoff_group": 0,
        "full_contract": 0,
        "destructive_order": 0,
        "committed_dependency_group": 0,
        "related_misclassified": 0,
        "two_removed_dependents": 0,
        "interleaved_full_order": 0,
        "fail_closed": 0,
        "selected_apps": 0,
        "selected_calls": 0,
        "unrelated_apps": 0,
        "unrelated_calls": 0,
        "ledger_snapshot": 0,
        "bound_transaction": 0,
        "evidence_reject": 0,
        "mutation_zero": 0,
        "installer_destructive_order": 0,
        "installer_selected_apps": 0,
        "installer_unrelated_calls": 0,
        "publication_reject": 0,
        "publication_mutation_zero": 0,
        "full_newapp_published": 0,
        "full_mapping_action_unchanged": 0,
        "owed_activation_reject": 0,
        "owed_activation_mutation_zero": 0,
        "resource_four_class": 0,
        "resource_digest_bound": 0,
        "resource_unit_ready_transition": 0,
        "resource_unit_regression_reject": 0,
        "resource_smoke_failure_reject": 0,
        "resource_apply_failure": 0,
        "resource_verify_failure": 0,
        "resource_compensation_success": 0,
        "resource_compensation_failure": 0,
        "resource_wrong_binding_reject": 0,
        "resource_ownership_expansion_reject": 0,
        "resource_unrelated_zero": 0,
        "noarg_resource_unchanged": 0,
        "managed_migration": 0,
        "managed_sidecar_bound": 0,
        "managed_intent_commit_copy": 0,
        "managed_signed_tree_digest": 0,
        "managed_restore": 0,
        "managed_enum_only_reject": 0,
        "managed_forged_sidecar_reject": 0,
        "managed_recovery_valid": 0,
        "managed_recovery_corrupt_reject": 0,
        "managed_commit_tree_reject": 0,
        "managed_nongrantable_capability_reject": 0,
        "managed_unknown_capability_reject": 0,
        "trusted_measurer_owed_durable": 0,
        "trusted_measurer_next_transaction_reject": 0,
        "trusted_measurer_restore_gate": 0,
        "trusted_measurer_forward_retry": 0,
        "trusted_measurer_rollback_retry": 0,
        "trusted_measurer_wrong_binding_reject": 0,
        "trusted_measurer_malformed_old_reject": 0,
    }
    with tempfile.TemporaryDirectory(prefix="airlock-app-scoped-lifecycle-") as temporary:
        root = Path(temporary)
        package_root = root / "packages"
        base = write_package(package_root, "base", port=22101, webroot="base/")
        changed = write_package(
            package_root, "changed", port=22102, webroot="changed/", deps=("base",)
        )
        # Shares base with changed, but is not a prerequisite of changed. Selected
        # execution must not walk backward through base and reinstall this sibling.
        isolated = write_package(
            package_root, "isolated", port=22103, webroot="isolated/", deps=("base",)
        )
        config = root / "airlock.toml"
        write_config(config, [
            ("changed", changed, 22102),
            ("isolated", isolated, 22103),
            ("base", base, 22101),
        ])
        config_check(root, config)
        good = package_info(root, config)
        counts["global_valid"] += 1
        info = json.loads(good.stdout)
        if info["order"].index("base") >= info["order"].index("changed"):
            raise AssertionError("real package-info did not place a dependency first")

        ledger_plan = root / "ledger-plan.tsv"
        ledger_plan.write_text(
            "remove\toldowner\nreinstall\tbase\nupgrade-deactivate\tchanged\n"
            "reinstall\tisolated\n",
            encoding="utf-8",
        )
        ledger_dependencies = root / "ledger-dependencies.json"
        write_ledger_dependencies(ledger_dependencies, [
            ("oldowner", (), "committed"),
            ("changed", ("base",), "committed"),
        ], ledger_plan)
        handoff = ("--handoff", "oldowner:changed")
        first_raw = invoke_planner(
            good.stdout, ledger_plan, selected=("changed",), extra=handoff,
            ledger_dependencies=ledger_dependencies,
        ).stdout
        plan = json.loads(first_raw)
        digest_body = dict(plan)
        observed_digest = digest_body.pop("plan_digest")
        expected_digest = hashlib.sha256(
            (json.dumps(digest_body, sort_keys=True, separators=(",", ":")) + "\n").encode()
        ).hexdigest()
        if observed_digest != expected_digest:
            raise AssertionError("plan digest does not bind the canonical output")
        if len(plan["groups"]) != 1:
            raise AssertionError(f"expected one selected safety group, got {plan['groups']!r}")
        group = plan["groups"][0]
        if group["install_order"] != ["base", "changed"]:
            raise AssertionError(f"wrong safety-group install order: {group['install_order']!r}")
        if group["remove_order"] != ["oldowner"]:
            raise AssertionError(f"resource handoff was not grouped: {group['remove_order']!r}")
        expected_execution = {
            "actions": [
                {"app_id": "oldowner", "action": "remove"},
                {"app_id": "base", "action": "reinstall"},
                {"app_id": "changed", "action": "upgrade-deactivate"},
            ],
            "destructive_order": ["oldowner", "changed"],
            "install_order": ["base", "changed"],
            "remove_order": ["oldowner"],
        }
        if plan.get("execution") != expected_execution:
            raise AssertionError(f"wrong closed execution contract: {plan.get('execution')!r}")
        counts["handoff_group"] += 1
        if plan["unrelated_apps"] != ["isolated"]:
            raise AssertionError(f"wrong unrelated set: {plan['unrelated_apps']!r}")

        # Source bytes may advance for an unrelated app between two selected
        # installs.  That is safe to leave pending when its committed serve
        # mapping and the separately checked discovery projection are unchanged.
        unrelated_upgrade_plan = root / "ledger-plan-unrelated-upgrade.tsv"
        unrelated_upgrade_plan.write_text(
            "reinstall\tbase\nreinstall\tchanged\nupgrade-deactivate\tisolated\n",
            encoding="utf-8",
        )
        unrelated_upgrade_dependencies = root / "ledger-dependencies-unrelated-upgrade.json"
        write_ledger_dependencies(
            unrelated_upgrade_dependencies,
            [("isolated", (), "committed")],
            unrelated_upgrade_plan,
        )
        unrelated_snapshot = json.loads(
            unrelated_upgrade_dependencies.read_text(encoding="utf-8")
        )
        for row in unrelated_snapshot["candidate_serve_mappings"]:
            if row["app_id"] == "isolated":
                row["matches_committed"] = True
        unrelated_upgrade_dependencies.write_text(
            json.dumps(unrelated_snapshot) + "\n", encoding="utf-8"
        )
        pending_plan = json.loads(invoke_planner(
            good.stdout,
            unrelated_upgrade_plan,
            selected=("base",),
            ledger_dependencies=unrelated_upgrade_dependencies,
        ).stdout)
        if (pending_plan["unrelated_apps"] != ["changed", "isolated"]
                or any(row["app_id"] in {"changed", "isolated"}
                       for row in pending_plan["execution"]["actions"])):
            raise AssertionError(
                f"unrelated upgrade entered selected execution: {pending_plan!r}"
            )

        reordered_raw = (json.dumps(canonical_reordered(info), separators=(",", ":")) + "\n").encode()
        second_raw = invoke_planner(
            reordered_raw, ledger_plan, selected=("changed",), extra=handoff,
            ledger_dependencies=ledger_dependencies,
        ).stdout
        if first_raw != second_raw:
            raise AssertionError("semantic package-info key order changed canonical plan bytes")
        counts["stable_groups"] += 1

        full = json.loads(invoke_planner(
            good.stdout, ledger_plan, selected=(), extra=handoff, mode="full",
            ledger_dependencies=ledger_dependencies,
        ).stdout)
        if full["requested_apps"] != ["oldowner", "base", "changed", "isolated"]:
            raise AssertionError(f"full mode narrowed its requested set: {full['requested_apps']!r}")
        if full["unrelated_apps"]:
            raise AssertionError(f"full mode left unrelated apps: {full['unrelated_apps']!r}")
        counts["full_contract"] += 1

        # The ledger's old committed dependency snapshot is the only evidence
        # that a removed app depends on a desired app whose old version will be
        # deactivated. App ids vary so a hash/name ordering cannot make this
        # accidentally green. Both full and selected plans must keep the
        # dependent in the same safety group and retain the ledger order.
        for old_id in ("olddep", "alpha", "zeta"):
            dependency_plan = root / f"ledger-plan-{old_id}.tsv"
            dependency_plan.write_text(
                f"remove\t{old_id}\nupgrade-deactivate\tbase\n"
                "reinstall\tchanged\nreinstall\tisolated\n",
                encoding="utf-8",
            )
            dependency_snapshot = root / f"ledger-dependencies-{old_id}.json"
            write_ledger_dependencies(dependency_snapshot, [
                (old_id, ("base",), "committed"),
                ("base", (), "committed"),
            ], dependency_plan)
            selected_plan = json.loads(invoke_planner(
                good.stdout, dependency_plan, selected=("base",),
                ledger_dependencies=dependency_snapshot,
            ).stdout)
            selected_group = next(
                item for item in selected_plan["groups"] if "base" in item["requested_apps"]
            )
            if old_id not in selected_group["members"]:
                raise AssertionError(
                    f"committed dependent {old_id} was omitted from base safety group"
                )
            if old_id in selected_plan["unrelated_apps"]:
                counts["related_misclassified"] += 1
            if selected_group["destructive_order"] != [old_id, "base"]:
                raise AssertionError(
                    f"selected destructive order changed for {old_id}: "
                    f"{selected_group['destructive_order']!r}"
                )
            selected_calls = [("remove", app_id)
                              for app_id in selected_group["destructive_order"]]
            if any(app_id in selected_plan["unrelated_apps"]
                   for _operation, app_id in selected_calls):
                raise AssertionError("a related destructive call was classified as unrelated")
            counts["committed_dependency_group"] += 1

            full_dependency_plan = json.loads(invoke_planner(
                good.stdout, dependency_plan, selected=(), mode="full",
                ledger_dependencies=dependency_snapshot,
            ).stdout)
            observed = [app_id for item in full_dependency_plan["groups"]
                        for app_id in item["destructive_order"]]
            if observed != [old_id, "base"]:
                raise AssertionError(
                    f"full destructive order changed for {old_id}: {observed!r}"
                )
            counts["destructive_order"] += 1
            full_without_snapshot = json.loads(invoke_planner(
                good.stdout, dependency_plan, selected=(), mode="full",
            ).stdout)
            observed = [app_id for item in full_without_snapshot["groups"]
                        for app_id in item["destructive_order"]]
            if observed != [old_id, "base"]:
                raise AssertionError(
                    f"snapshot-free full destructive order changed for {old_id}: {observed!r}"
                )
            counts["destructive_order"] += 1

        # Two removed apps have no package-info edge. Their committed snapshot
        # must supply it; selected mode may not call the dependency unrelated,
        # and full mode must preserve the ledger producer's reverse-topological
        # sequence for either lexical naming direction.
        for dependent, dependency in (
                ("alpha", "zeta"), ("zeta", "alpha"),
                ("removed-dependent", "removed-base")):
            removed_plan = root / f"removed-plan-{dependent}-{dependency}.tsv"
            removed_plan.write_text(
                f"remove\t{dependent}\nremove\t{dependency}\n"
                "reinstall\tbase\nreinstall\tchanged\nreinstall\tisolated\n",
                encoding="utf-8",
            )
            removed_snapshot = root / f"removed-dependencies-{dependent}-{dependency}.json"
            write_ledger_dependencies(removed_snapshot, [
                (dependent, (dependency,), "committed"),
                (dependency, (), "committed"),
            ], removed_plan)
            selected_removed = json.loads(invoke_planner(
                good.stdout, removed_plan, selected=(dependency,),
                ledger_dependencies=removed_snapshot,
            ).stdout)
            selected_group = selected_removed["groups"][0]
            if selected_group["remove_order"] != [dependent, dependency]:
                raise AssertionError(
                    "selected removed dependency order changed: "
                    f"{selected_group['remove_order']!r}"
                )
            if dependent in selected_removed["unrelated_apps"]:
                counts["related_misclassified"] += 1
            full_removed = json.loads(invoke_planner(
                good.stdout, removed_plan, selected=(), mode="full",
                ledger_dependencies=removed_snapshot,
            ).stdout)
            observed = [app_id for item in full_removed["groups"]
                        for app_id in item["destructive_order"]]
            if observed != [dependent, dependency]:
                raise AssertionError(
                    f"full removed order changed: {observed!r}"
                )
            counts["two_removed_dependents"] += 1
            counts["destructive_order"] += 1
            full_removed_without_snapshot = json.loads(invoke_planner(
                good.stdout, removed_plan, selected=(), mode="full",
            ).stdout)
            observed = [app_id for item in full_removed_without_snapshot["groups"]
                        for app_id in item["destructive_order"]]
            if observed != [dependent, dependency]:
                raise AssertionError(
                    f"snapshot-free full removed order changed: {observed!r}"
                )
            counts["destructive_order"] += 1

        # A disconnected destructive row may sit between two members of one
        # dependency component in the ledger order. Full mode coalesces the
        # overlapping intervals to retain that total order. Selected mode must
        # refuse the disconnected candidate change: the global renderer cannot
        # safely publish a removal this transaction did not execute.
        interleaved_plan = root / "interleaved-plan.tsv"
        interleaved_plan.write_text(
            "remove\tolddep\nremove\tmiddle\nupgrade-deactivate\tbase\n"
            "reinstall\tchanged\nreinstall\tisolated\n",
            encoding="utf-8",
        )
        interleaved_snapshot = root / "interleaved-dependencies.json"
        write_ledger_dependencies(interleaved_snapshot, [
            ("olddep", ("base",), "committed"),
            ("middle", (), "committed"),
            ("base", (), "committed"),
        ], interleaved_plan)
        interleaved_full = json.loads(invoke_planner(
            good.stdout, interleaved_plan, selected=(), mode="full",
            ledger_dependencies=interleaved_snapshot,
        ).stdout)
        observed = [app_id for item in interleaved_full["groups"]
                    for app_id in item["destructive_order"]]
        if observed != ["olddep", "middle", "base"]:
            raise AssertionError(f"interleaved full order changed: {observed!r}")
        interleaved_selected = invoke_planner(
            good.stdout, interleaved_plan, selected=("base",),
            ledger_dependencies=interleaved_snapshot, ok=False,
        )
        assert_rejected(interleaved_selected, "middle (remove; serve mapping differs)")
        counts["interleaved_full_order"] += 1

        calls: list[tuple[str, str]] = []
        for app_id in group["install_order"]:
            calls.append(("install", app_id))
            calls.append(("restart", app_id))
        counts["selected_apps"] = len(group["install_order"])
        counts["selected_calls"] = len(calls)
        counts["unrelated_apps"] = len(plan["unrelated_apps"])
        counts["unrelated_calls"] = sum(
            1 for _operation, app_id in calls if app_id in plan["unrelated_apps"]
        )

        # The real global producer rejects each unsafe candidate before the selection
        # planner can emit a transaction set.
        cases = []

        port_root = root / "port-collision"
        port_a = write_package(
            port_root, "porta", port=19901, webroot="porta/", claim_port=False
        )
        port_config = port_root / "airlock.toml"
        write_config(port_config, [("porta", port_a, 19901)])
        cases.append(("port_reject", config_check(port_root, port_config, ok=False),
                      "used twice"))

        path_root = root / "path-collision"
        path_a = write_package(path_root, "patha", port=22301, webroot="shared/")
        path_b = write_package(path_root, "pathb", port=22302, webroot="shared/")
        path_config = path_root / "airlock.toml"
        write_config(path_config, [("patha", path_a, 22301), ("pathb", path_b, 22302)])
        cases.append(("path_reject", config_check(path_root, path_config, ok=False),
                      "overlapping artifacts"))

        ingress_root = root / "ingress-collision"
        ingress_a = write_package(
            ingress_root, "ingressa", port=22401, webroot="ingressa/", ingress=True
        )
        ingress_b = write_package(
            ingress_root, "ingressb", port=22401, webroot="ingressb/", ingress=True
        )
        ingress_config = ingress_root / "airlock.toml"
        ingress_config.write_text(
            '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n\n'
            '[apps.hub]\n\n'
            '[apps.ingressa]\nhttps_port = 22401\nbackend_port = 22501\n\n'
            f'[packages.ingressa]\npath = "{ingress_a}"\n\n'
            '[apps.ingressb]\nhttps_port = 22401\nbackend_port = 22502\n\n'
            f'[packages.ingressb]\npath = "{ingress_b}"\n',
            encoding="utf-8",
        )
        cases.append(("ingress_reject", config_check(ingress_root, ingress_config, ok=False),
                      "claim serve port"))

        cycle_root = root / "dependency-cycle"
        cycle_a = write_package(
            cycle_root, "cyclea", port=22501, webroot="cyclea/", deps=("cycleb",)
        )
        cycle_b = write_package(
            cycle_root, "cycleb", port=22502, webroot="cycleb/", deps=("cyclea",)
        )
        cycle_config = cycle_root / "airlock.toml"
        write_config(cycle_config, [
            ("cyclea", cycle_a, 22501),
            ("cycleb", cycle_b, 22502),
        ])
        cases.append(("cycle_reject", config_check(cycle_root, cycle_config, ok=False),
                      "dependency cycle"))

        for counter, result, needle in cases:
            assert_rejected(result, needle)
            counts[counter] += 1

        unknown = invoke_planner(good.stdout, ledger_plan, selected=("absent",), ok=False)
        assert_rejected(unknown, "no actionable ledger row")
        counts["fail_closed"] += 1

        no_dependency_evidence = invoke_planner(
            good.stdout, ledger_plan, selected=("changed",), extra=handoff, ok=False
        )
        assert_rejected(no_dependency_evidence, "without a complete ledger dependency snapshot")
        counts["fail_closed"] += 1

        incomplete_dependencies = root / "incomplete-ledger-dependencies.json"
        write_ledger_dependencies(incomplete_dependencies, [
            ("oldowner", (), "committed"),
        ], ledger_plan)
        incomplete = invoke_planner(
            good.stdout, ledger_plan, selected=("changed",), extra=handoff, ok=False,
            ledger_dependencies=incomplete_dependencies,
        )
        assert_rejected(incomplete, "missing changed")
        counts["fail_closed"] += 1

        bad_order = dict(info)
        bad_order["order"] = [
            app_id for app_id in info["order"] if app_id not in {"base", "changed"}
        ] + ["changed", "base"]
        invalid_order = invoke_planner(
            (json.dumps(bad_order) + "\n").encode(), ledger_plan,
            selected=("changed",), ok=False, ledger_dependencies=ledger_dependencies,
        )
        assert_rejected(invalid_order, "not dependency-topological")
        counts["fail_closed"] += 1

        duplicate_plan = root / "duplicate-plan.tsv"
        duplicate_plan.write_text(ledger_plan.read_text() + "fresh\tchanged\n", encoding="utf-8")
        duplicate = invoke_planner(good.stdout, duplicate_plan, selected=("changed",), ok=False,
                                   ledger_dependencies=ledger_dependencies)
        assert_rejected(duplicate, "duplicate app id")
        counts["fail_closed"] += 1

        partial_plan = root / "partial-plan.tsv"
        partial_plan.write_text("upgrade-deactivate\tchanged\nreinstall\tisolated\n", encoding="utf-8")
        partial = invoke_planner(good.stdout, partial_plan, selected=("changed",), ok=False,
                                 ledger_dependencies=None)
        assert_rejected(partial, "omits configured package base")
        counts["fail_closed"] += 1

        exercise_installer_flow(root / "installer-flow", counts)
        exercise_managed_ledger_binding(root / "managed-ledger", counts)
        exercise_trusted_measurer_activation(root / "trusted-measurer", counts)

    revision = run("git", "rev-parse", "--short=12", "HEAD").stdout.decode().strip()
    if emit_ac:
        print(
            "AC-MAU-A1 | expected: global_valid == 1 && port_reject == 1 && "
            "path_reject == 1 && ingress_reject == 1 && cycle_reject == 1 && "
            "stable_groups == 1 && handoff_group == 1 && full_contract == 1 && "
            "destructive_order == 12 && committed_dependency_group == 3 && "
            "two_removed_dependents == 3 && interleaved_full_order == 1 && "
            "fail_closed == 6 && ledger_snapshot == 1 && bound_transaction == 1 && "
            "evidence_reject == 2 | observed: "
            f"global_valid={counts['global_valid']},port_reject={counts['port_reject']},"
            f"path_reject={counts['path_reject']},ingress_reject={counts['ingress_reject']},"
            f"cycle_reject={counts['cycle_reject']},stable_groups={counts['stable_groups']},"
            f"handoff_group={counts['handoff_group']},full_contract={counts['full_contract']},"
            f"destructive_order={counts['destructive_order']},"
            f"committed_dependency_group={counts['committed_dependency_group']},"
            f"two_removed_dependents={counts['two_removed_dependents']},"
            f"interleaved_full_order={counts['interleaved_full_order']},"
            f"fail_closed={counts['fail_closed']},"
            f"ledger_snapshot={counts['ledger_snapshot']},"
            f"bound_transaction={counts['bound_transaction']},"
            f"evidence_reject={counts['evidence_reject']} | "
            "verdict: PASS | signal: fixture | "
            f"evidence: install/test-app-scoped-lifecycle.py@{revision}"
        )
        print(
            "AC-MAU-A2 | expected: selected_apps == 2 && selected_calls == 4 && "
            "unrelated_apps == 1 && unrelated_calls == 0 && related_misclassified == 0 && "
            "installer_selected_apps == 1 && installer_unrelated_calls == 0 && "
            "installer_destructive_order == 1 && mutation_zero == 2 && "
            "publication_reject == 3 && publication_mutation_zero == 3 && "
            "full_newapp_published == 1 && full_mapping_action_unchanged == 1 && "
            "owed_activation_reject == 1 && "
            "owed_activation_mutation_zero == 1 | observed: "
            f"selected_apps={counts['selected_apps']},selected_calls={counts['selected_calls']},"
            f"unrelated_apps={counts['unrelated_apps']},unrelated_calls={counts['unrelated_calls']},"
            f"related_misclassified={counts['related_misclassified']},"
            f"installer_selected_apps={counts['installer_selected_apps']},"
            f"installer_unrelated_calls={counts['installer_unrelated_calls']},"
            f"installer_destructive_order={counts['installer_destructive_order']},"
            f"mutation_zero={counts['mutation_zero']},"
            f"publication_reject={counts['publication_reject']},"
            f"publication_mutation_zero={counts['publication_mutation_zero']},"
            f"full_newapp_published={counts['full_newapp_published']},"
            f"full_mapping_action_unchanged={counts['full_mapping_action_unchanged']},"
            f"owed_activation_reject={counts['owed_activation_reject']},"
            f"owed_activation_mutation_zero={counts['owed_activation_mutation_zero']} "
            "| verdict: PASS | signal: fixture | "
            f"evidence: install/test-app-scoped-lifecycle.py@{revision}"
        )
        print(
            "AC-MAU-A3 | expected: resource_four_class == 1 && "
            "resource_digest_bound == 1 && resource_apply_failure == 1 && "
            "resource_verify_failure == 1 && resource_unit_ready_transition == 1 && "
            "resource_unit_regression_reject == 1 && "
            "resource_smoke_failure_reject == 1 && "
            "resource_compensation_success == 4 && "
            "resource_compensation_failure == 1 && "
            "resource_wrong_binding_reject == 1 && "
            "resource_ownership_expansion_reject == 1 && "
            "resource_unrelated_zero == 8 && noarg_resource_unchanged == 1 | observed: "
            f"resource_four_class={counts['resource_four_class']},"
            f"resource_digest_bound={counts['resource_digest_bound']},"
            f"resource_apply_failure={counts['resource_apply_failure']},"
            f"resource_verify_failure={counts['resource_verify_failure']},"
            "resource_unit_ready_transition="
            f"{counts['resource_unit_ready_transition']},"
            "resource_unit_regression_reject="
            f"{counts['resource_unit_regression_reject']},"
            "resource_smoke_failure_reject="
            f"{counts['resource_smoke_failure_reject']},"
            f"resource_compensation_success={counts['resource_compensation_success']},"
            f"resource_compensation_failure={counts['resource_compensation_failure']},"
            f"resource_wrong_binding_reject={counts['resource_wrong_binding_reject']},"
            "resource_ownership_expansion_reject="
            f"{counts['resource_ownership_expansion_reject']},"
            f"resource_unrelated_zero={counts['resource_unrelated_zero']},"
            f"noarg_resource_unchanged={counts['noarg_resource_unchanged']} "
            "| verdict: PASS | signal: fixture | "
            f"evidence: install/test-app-scoped-lifecycle.py@{revision}"
        )
        print(
            "AC-MAU-A3L | expected: managed_migration == 6 && "
            "managed_sidecar_bound == 1 && managed_intent_commit_copy == 1 && "
            "managed_signed_tree_digest == 1 && "
            "managed_restore == 1 && managed_enum_only_reject == 1 && "
            "managed_forged_sidecar_reject == 4 && managed_recovery_valid == 1 && "
            "managed_recovery_corrupt_reject == 1 && managed_commit_tree_reject == 1 && "
            "managed_nongrantable_capability_reject == 1 && "
            "managed_unknown_capability_reject == 1 && "
            "trusted_measurer_owed_durable == 1 && "
            "trusted_measurer_next_transaction_reject == 1 && "
            "trusted_measurer_restore_gate == 1 && "
            "trusted_measurer_forward_retry == 1 && "
            "trusted_measurer_rollback_retry == 1 && "
            "trusted_measurer_wrong_binding_reject == 1 && "
            "trusted_measurer_malformed_old_reject == 1 | observed: "
            f"managed_migration={counts['managed_migration']},"
            f"managed_sidecar_bound={counts['managed_sidecar_bound']},"
            f"managed_intent_commit_copy={counts['managed_intent_commit_copy']},"
            f"managed_signed_tree_digest={counts['managed_signed_tree_digest']},"
            f"managed_restore={counts['managed_restore']},"
            f"managed_enum_only_reject={counts['managed_enum_only_reject']},"
            "managed_forged_sidecar_reject="
            f"{counts['managed_forged_sidecar_reject']},"
            f"managed_recovery_valid={counts['managed_recovery_valid']},"
            "managed_recovery_corrupt_reject="
            f"{counts['managed_recovery_corrupt_reject']},"
            f"managed_commit_tree_reject={counts['managed_commit_tree_reject']},"
            "managed_nongrantable_capability_reject="
            f"{counts['managed_nongrantable_capability_reject']},"
            "managed_unknown_capability_reject="
            f"{counts['managed_unknown_capability_reject']},"
            "trusted_measurer_owed_durable="
            f"{counts['trusted_measurer_owed_durable']},"
            "trusted_measurer_next_transaction_reject="
            f"{counts['trusted_measurer_next_transaction_reject']},"
            "trusted_measurer_restore_gate="
            f"{counts['trusted_measurer_restore_gate']},"
            "trusted_measurer_forward_retry="
            f"{counts['trusted_measurer_forward_retry']},"
            "trusted_measurer_rollback_retry="
            f"{counts['trusted_measurer_rollback_retry']},"
            "trusted_measurer_wrong_binding_reject="
            f"{counts['trusted_measurer_wrong_binding_reject']},"
            "trusted_measurer_malformed_old_reject="
            f"{counts['trusted_measurer_malformed_old_reject']} | "
            "verdict: PASS | "
            "signal: fixture | scope: ledger-and-adapter-transaction-contract; live UNVERIFIED | "
            f"evidence: install/test-app-scoped-lifecycle.py@{revision}"
        )
    else:
        print("app-scoped lifecycle fixture: planner and installer-flow checks passed "
              "(fixture only; live UNVERIFIED)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-ac", action="store_true")
    args = parser.parse_args(argv)
    exercise(args.emit_ac)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
