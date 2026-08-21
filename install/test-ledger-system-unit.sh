#!/usr/bin/env bash
# Focused mutation tests for the store-v4 system-unit claim boundary.
#
# These cases deliberately import bin/airlock-ledger and call internal
# functions with hand-built values.  The normal store validator is therefore
# bypassed: expansion, committed-artifact resolution, aggregate teardown, and
# the command funnels must each defend their own side-effect boundary.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LEDGER="$ROOT/bin/airlock-ledger"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"
UU="$TMP/unit-user"
US="$TMP/unit-system"
CONFD="$TMP/confd"
WEB="$TMP/web/hub"
FAKEHOME="$TMP/home"
SHIM="$TMP/shim"
mkdir -p "$STATE" "$UU" "$US" "$CONFD" "$WEB" "$FAKEHOME" "$SHIM"

export AIRLOCK_STATE_DIR="$STATE"
export AIRLOCK_UNIT_DIR_USER="$UU"
export AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_CONFD="$CONFD"
export AIRLOCK_WEBROOT="$WEB"
export HOME="$FAKEHOME"
export AIRLOCK_TEST_TMP="$TMP"

cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
STUB
cat >"$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AIRLOCK_TEST_TMP/systemctl.log"
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
detail() { printf '%s\n' "$1" | sed 's/^/    /' | tail -n 12; }

reset_case() {
  rm -rf "$STATE" "$UU" "$US" "$CONFD" "$WEB" "$FAKEHOME"
  mkdir -p "$STATE" "$UU" "$US" "$CONFD" "$WEB" "$FAKEHOME"
  : >"$TMP/systemctl.log"
  rm -f "$TMP/deactivated"
}

# One driver keeps the hand-built record shapes identical across mutations.
# A future green implementation must raise LedgerError in every negative case;
# an unexpected traceback is still a test failure because the message contract
# below will not match.
direct_case() {
  python3 - "$LEDGER" "$1" "$TMP" <<'PY'
import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

tool, case, tmp_raw = sys.argv[1:]
tmp = Path(tmp_raw)
loader = SourceFileLoader("_airlock_ledger_system_unit_test", tool)
spec = importlib.util.spec_from_loader(loader.name, loader)
ledger = importlib.util.module_from_spec(spec)
loader.exec_module(ledger)

uu = Path(os.environ["AIRLOCK_UNIT_DIR_USER"])
us = Path(os.environ["AIRLOCK_UNIT_DIR_SYSTEM"])
roots = {
    "unit_user": str(uu),
    "unit_system": str(us),
    "confd": os.environ["AIRLOCK_CONFD"],
    "webroot": os.environ["AIRLOCK_WEBROOT"],
    "home": os.environ["HOME"],
}

def artifacts(*, units):
    return {
        "units": list(units),
        "fragments": [],
        "webroot": [],
        "files": [],
        "rooted": [],
        "serve_ports": [],
    }

def common(path, *, deactivate=False, capabilities=None):
    return {
        "path": str(path),
        "digest": "f" * 64,
        "lifecycle": {"install": False, "smoke": False, "deactivate": deactivate},
        "deps": [],
        "serve_mappings": {},
        "order": None,
        "source_class": "explicit",
        "capabilities": list(capabilities or []),
    }

def intent(path, unit_name, scope, *, capabilities=None):
    return dict(
        common(path, capabilities=capabilities),
        artifacts_declared=artifacts(units=[unit_name]),
        serve_port_values={},
        unit_scopes={unit_name: scope},
        roots=dict(roots),
        anchors={},
    )

def committed(path, unit_path, scope, *, deactivate=False, capabilities=None):
    record = dict(
        common(path, deactivate=deactivate, capabilities=capabilities),
        artifacts=artifacts(units=[str(unit_path)]),
        unit_scopes={Path(unit_path).name: scope},
        roots=dict(roots),
    )
    if Path(path).is_dir():
        record["digest"] = ledger.digest_tree(str(path))
    return record

if case == "expand":
    (us / "system.service").touch()
    ledger.expand_declared(
        artifacts(units=["system.service"]), {}, roots,
        unit_scopes={"system.service": "system"}, capabilities=[])

elif case == "committed":
    unit = us / "system.service"
    unit.touch()
    ledger._committed_artifacts(
        committed("/nonexistent/pkg", unit, "user", capabilities=[]))

elif case == "unit-direct":
    system = us / "system-direct.service"
    system.touch()
    ledger._teardown_unit(str(system), False, [])

elif case == "mixed-teardown":
    user = uu / "a-user.service"
    system = us / "z-system.service"
    user.touch(); system.touch()
    ledger.teardown_artifacts(
        artifacts(units=[str(user), str(system)]), set(), False, {},
        capabilities=[])

elif case in {"command-teardown", "command-remove"}:
    package = tmp / f"{case}-pkg"
    package.mkdir()
    (package / "deactivate.sh").write_text(
        "#!/usr/bin/env bash\ntouch \"$AIRLOCK_TEST_TMP/deactivated\"\n",
        encoding="utf-8")
    (package / "deactivate.sh").chmod(0o755)
    user = uu / "a-user.service"
    system = us / "z-system.service"
    user.touch(); system.touch()
    committed_record = committed(
        package, user, "user", deactivate=(case == "command-remove"),
        capabilities=[])
    intent_record = intent(package, system.name, "system", capabilities=[])
    store = {"version": 4, "entries": {"mixed": {
        "committed": committed_record,
        "intent": intent_record,
    }}}
    if case == "command-remove":
        ledger.command_remove(store, {"packages": {}}, "mixed", False, None)
    else:
        ledger.command_teardown(store, {"packages": {}}, "mixed", None)

elif case == "rooted-late":
    package = tmp / "rooted-late-pkg"
    package.mkdir()
    (package / "deactivate.sh").write_text(
        "#!/usr/bin/env bash\ntouch \"$AIRLOCK_TEST_TMP/deactivated\"\n",
        encoding="utf-8")
    (package / "deactivate.sh").chmod(0o755)
    ordinary = tmp / "ordinary-marker"
    ordinary.touch()
    outside = tmp / "outside-rooted-marker"
    outside.touch()
    record = committed(
        package, uu / "unused.service", "user", deactivate=True,
        capabilities=["rooted-artifact"])
    record["artifacts"] = artifacts(units=[])
    record["artifacts"]["files"] = [str(ordinary)]
    record["artifacts"]["rooted"] = [str(outside)]
    record["unit_scopes"] = {}
    store = {"version": 4, "entries": {"rooted-late": {"committed": record}}}
    # This is a valid v4 record: its stored claim and rooted artifact agree.
    # The refusal is execution-time because the path lies outside the LIVE
    # rooted allowlist, which may have changed since commit.
    ledger._validate_store(store, ledger.ledger_path())
    ledger.command_remove(store, {"packages": {}}, "rooted-late", False, None)

else:
    raise AssertionError(f"unknown case: {case}")
PY
}

expect_refusal() {
  local label="$1" case="$2" fragment="$3" out rc=0
  shift 3
  out="$(direct_case "$case" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && grep -Fq "$fragment" <<<"$out" && "$@"; then
    ok "$label"
  else
    bad "$label (rc=$rc)"
    detail "$out"
  fi
}

reset_case
expect_refusal \
  "system-unit belt: declaration expansion refuses a system scope without a claim" \
  expand "does not claim 'system-unit'" true

reset_case
expect_refusal \
  "system-unit belt: committed artifact resolution refuses a recorded system path without a claim" \
  committed "does not claim 'system-unit'" true

reset_case
expect_refusal \
  "system-unit belt: direct unit teardown refuses a system path without a claim" \
  unit-direct "does not claim 'system-unit'" \
  test -e "$US/system-direct.service" -a ! -s "$TMP/systemctl.log"

reset_case
expect_refusal \
  "system-unit preflight: a late system unit cannot follow partial user-unit teardown" \
  mixed-teardown "does not claim 'system-unit'" \
  test -e "$UU/a-user.service" -a -e "$US/z-system.service" -a ! -s "$TMP/systemctl.log"

reset_case
expect_refusal \
  "system-unit preflight: committed and intent artifacts resolve before either teardown starts" \
  command-teardown "does not claim 'system-unit'" \
  test -e "$UU/a-user.service" -a -e "$US/z-system.service" -a ! -s "$TMP/systemctl.log"

reset_case
expect_refusal \
  "system-unit preflight: invalid intent is rejected before a committed deactivator runs" \
  command-remove "does not claim 'system-unit'" \
  test ! -e "$TMP/deactivated" -a -e "$UU/a-user.service" -a -e "$US/z-system.service" -a ! -s "$TMP/systemctl.log"

reset_case
expect_refusal \
  "artifact preflight: rooted live-policy refusal precedes deactivator and ordinary removal" \
  rooted-late "outside the rooted allowlist" \
  test ! -e "$TMP/deactivated" -a -e "$TMP/ordinary-marker" -a -e "$TMP/outside-rooted-marker"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
