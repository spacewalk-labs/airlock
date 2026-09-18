#!/usr/bin/env bash
# Durable checkpoint/recovery primitive tests. All roots and command effects are scratch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

case_name=all emit_ac=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --case) case_name="${2:-}"; shift 2 ;;
    --emit-ac) emit_ac=1; shift ;;
    *) case_name="$1"; shift ;;
  esac
done
shared_root_restore=0 owner_drift_reject=0

setup_case() {
  local name="$1"
  CASE="$TMP/$name" STATE="$TMP/$name/state" WEB="$TMP/$name/web"
  CONFD="$TMP/$name/confd" UU="$TMP/$name/user-units" US="$TMP/$name/system-units"
  FAKEHOME="$TMP/$name/home" ETC="$TMP/$name/platform-etc" OPT="$TMP/$name/platform-opt"
  SHIM="$TMP/$name/shim"
  mkdir -p "$STATE" "$WEB/app/tree" "$CONFD/servers.d" "$UU" "$US" \
    "$FAKEHOME/files" "$ETC" "$OPT" "$SHIM" "$CASE/pkg"
  chmod 700 "$STATE"
  export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
  export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
  export AIRLOCK_PLATFORM_ETC="$ETC" AIRLOCK_PLATFORM_OPT="$OPT" HOME="$FAKEHOME"
  export AIRLOCK_TEST_CASE="$CASE" AIRLOCK_TEST_LEDGER="$ROOT/bin/airlock-ledger"
  unset AIRLOCK_TEST_PRIVILEGED_PATH AIRLOCK_TEST_SUDO_DENY
  export AIRLOCK_CONFIG_SNAPSHOT_SHA256="$(printf 'a%.0s' {1..64})"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf 'b%.0s' {1..64})"
  cat > "$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_CASE/sudo.log"
if [ "${1:-}" = "$AIRLOCK_TEST_LEDGER" ] \
    && [ "${2:-}" = _checkpoint-helper ] \
    && [ "${3:-}" = archive ] \
    && [ "${8:-}" = "${AIRLOCK_TEST_PRIVILEGED_PATH:-}" ]; then
  [ "${AIRLOCK_TEST_SUDO_DENY:-0}" != 1 ] || exit 77
  if [ -e "$8" ]; then
    mode="$(stat -c %a -- "$8")" || exit
    if [ -d "$8" ]; then chmod 700 -- "$8"; else chmod 600 -- "$8"; fi
  else
    mode=""
  fi
  "$@"
  rc=$?
  [ -z "$mode" ] || chmod "$mode" -- "$8"
  exit "$rc"
fi
exec "$@"
STUB
  cat > "$SHIM/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/systemctl.log"
case "\$*" in
  *is-active*) exit 0 ;;
  *is-enabled*) exit 0 ;;
  *show*)
    printf '%s\n' 'LoadState=loaded' 'ActiveState=inactive' 'MainPID=0' 'ControlPID=0'
    exit 0 ;;
esac
exit 0
EOF
  cat > "$SHIM/tailscale" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/tailscale.log"
exit 0
EOF
  chmod +x "$SHIM"/*
  PATH="$SHIM:$PATH"; export PATH

  printf 'unit-v1\n' > "$UU/airlock-fixture.service"
  chmod 0640 "$UU/airlock-fixture.service"
  printf 'fragment-v1\n' > "$CONFD/servers.d/fixture.conf"
  printf 'web-v1\n' > "$WEB/app/tree/index.html"
  printf 'file-v1\n' > "$FAKEHOME/files/target"
  ln -s "$FAKEHOME/files/target" "$FAKEHOME/files/link"
  printf 'rooted-v1\n' > "$ETC/fixture.conf"
  printf 'package\n' > "$CASE/pkg/content"
  python3 - "$STATE/app-ledger.json" "$CASE/pkg" "$UU" "$US" "$CONFD" "$WEB" \
    "$FAKEHOME" "$ETC/fixture.conf" <<'PY'
import json, os, sys
ledger, pkg, uu, us, confd, web, home, rooted = sys.argv[1:]
artifacts = {
    "units": [os.path.join(uu, "airlock-fixture.service")],
    "fragments": [os.path.join(confd, "servers.d/fixture.conf")],
    "webroot": [os.path.join(web, "app/tree")],
    "files": [os.path.join(home, "files/link")],
    "rooted": [rooted],
    "serve_ports": [19443],
}
record = {
    "path": pkg, "digest": "c" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": artifacts, "deps": [],
    "serve_mappings": {"https_port": {"listen": 19443, "mode": "https", "target": 19444}},
    "unit_scopes": {"airlock-fixture.service": "user"}, "order": 1,
    "roots": {"unit_user": uu, "unit_system": us, "confd": confd,
              "webroot": web, "home": home},
    "source_class": "shipped", "capabilities": ["rooted-artifact"],
    "container_runtime": None,
}
with open(ledger, "w", encoding="utf-8") as fh:
    json.dump({"version": 6, "entries": {"fixture": {"committed": record}}, "events": []}, fh)
PY
  chmod 600 "$STATE/app-ledger.json"
}

begin_fixture() {
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture >/dev/null
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  "$ROOT/bin/airlock-ledger" transaction-deactivated fixture
}

candidate_package_info() {
  python3 - "$CASE/pkg" <<'PY'
import json, sys
pkg, = sys.argv[1:]
print(json.dumps({"packages": {"fixture": {
    "dir": pkg,
    "artifacts": {
        "units": [],
        "fragments": ["servers.d/fixture.conf"],
        "webroot": ["app/tree"],
        "files": ["~/files/link", "~/files/candidate"],
        "rooted": [], "serve_ports": ["https_port"], "containers": [],
    },
    "serve_port_values": {"https_port": 19443},
    "serve_mappings": {"https_port": {"listen": 19443, "mode": "https", "target": 19444}},
    "unit_scopes": {},
    "source_class": "shipped", "capabilities": [],
    "lifecycle": {"install": True, "smoke": True, "deactivate": True}, "deps": [],
}}}, sort_keys=True))
PY
}

checkpoint_archive_for_path() {
  python3 - "$STATE/install-transaction.json" "$1" "$STATE/install-checkpoints" <<'PY'
import json, os, sys
transaction, wanted, root = sys.argv[1:]
value = json.load(open(transaction, encoding="utf-8"))
for checkpoint in value["checkpoints"].values():
    for item in checkpoint["artifacts"]:
        if item["path"] == wanted:
            print(os.path.join(root, value["id"], item["archive"]))
            raise SystemExit
raise SystemExit(f"no checkpoint receipt for {wanted}")
PY
}

direct_read_fails() {
  ! python3 - "$1" 2>/dev/null <<'PY'
import sys
with open(sys.argv[1], "rb") as fh:
    fh.read(1)
PY
}

make_socket() {
  python3 - "$1" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY
}

containerize_fixture() {
  local runtime="$FAKEHOME/files/runtime"
  AIRLOCK_TEST_CONTAINER_ID="$(printf 'd%.0s' {1..64})"
  export AIRLOCK_TEST_CONTAINER_ID
  export AIRLOCK_TEST_CONTAINER_NONCE="fixture_nonce_0001"
  export AIRLOCK_TEST_CONTAINER_NAME="airlock-fixture-old"
  mkdir -p "$runtime/sockets"
  printf 'runtime-v1\n' > "$runtime/state"
  make_socket "$runtime/sockets/fpm.sock"
  python3 - "$STATE/app-ledger.json" "$runtime" \
    "$AIRLOCK_TEST_CONTAINER_ID" "$AIRLOCK_TEST_CONTAINER_NONCE" \
    "$AIRLOCK_TEST_CONTAINER_NAME" <<'PY'
import json, sys
ledger, runtime, object_id, nonce, name = sys.argv[1:]
value = json.load(open(ledger, encoding="utf-8"))
record = value["entries"]["fixture"]["committed"]
record["artifacts"]["files"] = [runtime]
record["container_runtime"] = {
    "runtime": "docker", "daemon_identity": "docker:fixture-daemon",
    "install_nonce": nonce, "declarations": ["airlock-fixture-*"],
    "objects": [{"id": object_id, "name": name}],
}
with open(ledger, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  cat > "$SHIM/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_CASE/docker.log"
case "${1:-}" in
  info)
    [ "${2:-}" != --format ] || printf '%s\n' fixture-daemon
    exit 0
    ;;
  ps)
    printf '%s\n' "$AIRLOCK_TEST_CONTAINER_ID"
    exit 0
    ;;
  inspect)
    [ "${2:-}" = "$AIRLOCK_TEST_CONTAINER_ID" ] || exit 91
    printf '[{"Id":"%s","Name":"/%s","Config":{"Labels":{"io.airlock.package":"fixture","io.airlock.install-nonce":"%s"}}}]\n' \
      "$AIRLOCK_TEST_CONTAINER_ID" "$AIRLOCK_TEST_CONTAINER_NAME" \
      "$AIRLOCK_TEST_CONTAINER_NONCE"
    exit 0
    ;;
esac
exit 91
STUB
  chmod +x "$SHIM/docker"
}

add_transient_intent() {
  python3 - "$STATE/app-ledger.json" <<'PY'
import copy, json, sys
ledger = sys.argv[1]
value = json.load(open(ledger, encoding="utf-8"))
committed = value["entries"]["fixture"]["committed"]
runtime = committed["container_runtime"]
value["entries"]["fixture"]["intent"] = {
    "path": committed["path"], "digest": committed["digest"],
    "artifacts_declared": {
        "units": ["airlock-fixture.service"],
        "fragments": ["servers.d/fixture.conf"],
        "webroot": ["app/tree"],
        "files": ["~/files/runtime"],
        "rooted": [committed["artifacts"]["rooted"][0]],
        "serve_ports": ["https_port"],
    },
    "serve_port_values": {"https_port": 19443},
    "lifecycle": copy.deepcopy(committed["lifecycle"]),
    "roots": copy.deepcopy(committed["roots"]), "deps": [], "anchors": {},
    "serve_mappings": copy.deepcopy(committed["serve_mappings"]),
    "unit_scopes": {"airlock-fixture.service": "user"}, "order": 1,
    "source_class": "shipped", "capabilities": copy.deepcopy(committed["capabilities"]),
    "container_runtime": {key: copy.deepcopy(runtime[key]) for key in
                          ("runtime", "daemon_identity", "install_nonce", "declarations")},
}
with open(ledger, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
}

mutate_fixture() {
  printf 'unit-v2\n' > "$UU/airlock-fixture.service"
  rm -f "$CONFD/servers.d/fixture.conf"
  printf 'web-v2\n' > "$WEB/app/tree/index.html"
  rm -f "$FAKEHOME/files/link"; ln -s /tmp/not-the-old-target "$FAKEHOME/files/link"
  printf 'rooted-v2\n' > "$ETC/fixture.conf"
}

roundtrip() {
  setup_case roundtrip
  begin_fixture || { bad "roundtrip: checkpoint creation failed"; return; }
  mutate_fixture
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase link mode
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  link="$(readlink "$FAKEHOME/files/link" 2>/dev/null || true)"
  mode="$(stat -c %a "$UU/airlock-fixture.service" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] \
      && grep -qx unit-v1 "$UU/airlock-fixture.service" \
      && grep -qx fragment-v1 "$CONFD/servers.d/fixture.conf" \
      && grep -qx web-v1 "$WEB/app/tree/index.html" \
      && [ "$link" = "$FAKEHOME/files/target" ] \
      && grep -qx rooted-v1 "$ETC/fixture.conf" && [ "$mode" = 640 ] \
      && grep -Fqx "$ROOT/bin/airlock-ledger _checkpoint-helper archive fixture rooted - $STATE $ETC/fixture.conf" \
        "$CASE/sudo.log" \
      && grep -q 'enable airlock-fixture.service' "$CASE/systemctl.log" \
      && grep -q -- '--https=19443 http://127.0.0.1:19444' "$CASE/tailscale.log"; then
    ok "roundtrip: rooted class selects sudo; all bytes/modes/unit state/mapping restore"
  else
    bad "roundtrip: restore oracle failed (rc=$rc phase=${phase:-none} link=${link:-none} mode=${mode:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

candidate_user_file_roundtrip() {
  setup_case candidate-user-file
  printf 'candidate-v1\n' > "$FAKEHOME/files/candidate"
  chmod 0640 "$FAKEHOME/files/candidate"
  python3 - "$STATE/app-ledger.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
record = value["entries"]["fixture"]["committed"]
record["artifacts"]["units"] = []
record["unit_scopes"] = {}
record["artifacts"]["rooted"] = []
record["capabilities"] = []
with open(path, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  local package_sha archive rc phase mode receipt_bound
  package_sha="$(candidate_package_info | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$package_sha"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256
  candidate_package_info | "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture >/dev/null \
    || { bad "candidate-user-file: checkpoint creation failed"; return; }
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  "$ROOT/bin/airlock-ledger" transaction-deactivated fixture
  archive="$(checkpoint_archive_for_path "$FAKEHOME/files/candidate" 2>/dev/null || true)"
  receipt_bound="$(python3 - "$STATE/install-transaction.json" "$FAKEHOME/files/candidate" "$package_sha" <<'PY'
import json, sys
path, candidate, package_sha = sys.argv[1:]
tx = json.load(open(path, encoding="utf-8"))
print(int(tx.get("package_sha256") == package_sha
          and tx.get("candidate_user_files", {}).get("fixture") == [candidate]))
PY
)"
  candidate_package_info | "$ROOT/bin/airlock-ledger" intent fixture >/dev/null \
    || { bad "candidate-user-file: candidate intent admission failed"; return; }
  "$ROOT/bin/airlock-ledger" teardown fixture >/dev/null \
    || { bad "candidate-user-file: candidate teardown failed"; return; }
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  rc=$?
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  mode="$(stat -c %a "$FAKEHOME/files/candidate" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] && [ "$receipt_bound" = 1 ] && [ -f "$archive" ] \
      && grep -qx candidate-v1 "$FAKEHOME/files/candidate" && [ "$mode" = 640 ]; then
    ok "candidate-user-file: newly declared pre-existing file survives teardown and rollback with bytes/mode"
  else
    bad "candidate-user-file: rollback oracle failed (rc=$rc phase=${phase:-none} mode=${mode:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

candidate_user_file_action_roundtrip() {
  local action="$1" name="$2"
  setup_case "$name"
  printf 'candidate-v1\n' > "$FAKEHOME/files/candidate"
  chmod 0640 "$FAKEHOME/files/candidate"
  python3 - "$STATE/app-ledger.json" "$action" <<'PY'
import json, sys
path, action = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
record = value["entries"]["fixture"]["committed"]
record["artifacts"]["units"] = []
record["unit_scopes"] = {}
record["artifacts"]["rooted"] = []
record["capabilities"] = []
if action == "fresh":
    value["entries"] = {}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  local package_sha rc phase mode
  package_sha="$(candidate_package_info | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$package_sha"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256
  candidate_package_info | "$ROOT/bin/airlock-ledger" transaction-begin "$action:fixture" >/dev/null \
    || { bad "$name: checkpoint creation failed"; return; }
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  candidate_package_info | "$ROOT/bin/airlock-ledger" intent fixture >/dev/null \
    || { bad "$name: candidate intent admission failed"; return; }
  "$ROOT/bin/airlock-ledger" teardown fixture >/dev/null \
    || { bad "$name: candidate teardown failed"; return; }
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  rc=$?
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  mode="$(stat -c %a "$FAKEHOME/files/candidate" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] \
      && grep -qx candidate-v1 "$FAKEHOME/files/candidate" && [ "$mode" = 640 ]; then
    ok "$name: candidate user file survives teardown and forced rollback"
  else
    bad "$name: rollback oracle failed (rc=$rc phase=${phase:-none} mode=${mode:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

candidate_user_file_other_actions() {
  candidate_user_file_action_roundtrip reinstall candidate-user-file-reinstall
  candidate_user_file_action_roundtrip upgrade-diff candidate-user-file-upgrade-diff
  candidate_user_file_action_roundtrip fresh candidate-user-file-fresh
}

forged_candidate_user_file_receipt() {
  setup_case forged-candidate-user-file
  printf 'candidate-v1\n' > "$FAKEHOME/files/candidate"
  printf 'outside-v1\n' > "$ETC/forged"
  python3 - "$STATE/app-ledger.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
record = value["entries"]["fixture"]["committed"]
record["artifacts"]["units"] = []
record["unit_scopes"] = {}
record["artifacts"]["rooted"] = []
record["capabilities"] = []
with open(path, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  local package_sha rc phase
  package_sha="$(candidate_package_info | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$package_sha"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256
  candidate_package_info | "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture >/dev/null \
    || { bad "forged-candidate-user-file: checkpoint creation failed"; return; }
  python3 - "$STATE/install-transaction.json" "$FAKEHOME/files/candidate" "$ETC/forged" <<'PY'
import json, sys
path, original, forged = sys.argv[1:]
tx = json.load(open(path, encoding="utf-8"))
tx["candidate_user_files"]["fixture"] = [forged]
for item in tx["checkpoints"]["fixture"]["artifacts"]:
    if item["path"] == original:
        item["path"] = forged
        break
with open(path, "w", encoding="utf-8") as fh:
    json.dump(tx, fh)
PY
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  rc=$?
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  if [ "$rc" != 0 ] && [ "$phase" = degraded ] \
      && grep -qx outside-v1 "$ETC/forged" \
      && grep -q 'candidate user-file checkpoint escapes committed home' "$CASE/restore.log"; then
    ok "forged-candidate-user-file: matching archive cannot restore an outside receipt path"
  else
    bad "forged-candidate-user-file: forged receipt was accepted or mutated outside path (rc=$rc phase=${phase:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

corrupt() {
  setup_case corrupt
  begin_fixture || { bad "corrupt: checkpoint creation failed"; return; }
  mutate_fixture
  local archive
  archive="$(find "$STATE/install-checkpoints" -name '*.tar' -print -quit)"
  printf 'corrupt\n' >> "$archive"
  "$ROOT/bin/airlock-ledger" transaction-restore >/dev/null 2>&1
  local rc=$? phase
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  if [ "$rc" != 0 ] && [ "$phase" = degraded ] && grep -qx unit-v2 "$UU/airlock-fixture.service"; then
    ok "corrupt: digest mismatch is visible and no restore mutation begins"
  else
    bad "corrupt: expected degraded/no-mutation (rc=$rc phase=${phase:-none})"
  fi
}

permission_denied() {
  setup_case permission
  chmod 000 "$WEB/app/tree/index.html"
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$?
  chmod 0644 "$WEB/app/tree/index.html"
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -q 'checkpoint artifact is unreadable' "$CASE/checkpoint.log" \
      && grep -qx web-v1 "$WEB/app/tree/index.html"; then
    ok "permission: unreadable artifact refuses checkpoint before transaction publication"
  else
    bad "permission: checkpoint did not fail closed (rc=$rc)"
  fi
}

space_denied() {
  setup_case space
  dd if=/dev/zero of="$WEB/app/tree/large" bs=4096 count=1 status=none
  (ulimit -f 1; "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1)
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -Eq 'File too large|File size limit exceeded|cannot create checkpoint archive' \
        "$CASE/checkpoint.log" \
      && grep -qx web-v1 "$WEB/app/tree/index.html"; then
    ok "space: archive write limit refuses checkpoint before mutation"
  else
    bad "space: checkpoint unexpectedly published (rc=$rc)"
  fi
}

symlink_redirect() {
  setup_case redirect
  mv "$CONFD/servers.d" "$CONFD/real-servers.d"
  ln -s "$CONFD/real-servers.d" "$CONFD/servers.d"
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -q 'is now a symlink' "$CASE/checkpoint.log" \
      && grep -qx fragment-v1 "$CONFD/real-servers.d/fixture.conf"; then
    ok "symlink-redirect: existing containment gate refuses redirected ancestor"
  else
    bad "symlink-redirect: checkpoint did not fail closed (rc=$rc)"
  fi
}

privileged_redirect() {
  setup_case privileged-redirect
  mkdir -p "$OPT/real-tree"
  printf 'redirected\n' > "$OPT/real-tree/file"
  ln -s "$OPT/real-tree" "$OPT/link-tree"
  python3 - "$STATE/app-ledger.json" "$OPT/link-tree/file" <<'PY'
import json, sys
ledger, path = sys.argv[1:]
value = json.load(open(ledger, encoding="utf-8"))
value["entries"]["fixture"]["committed"]["artifacts"]["rooted"] = [path]
with open(ledger, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  export AIRLOCK_TEST_PRIVILEGED_PATH="$OPT/link-tree/file"
  # The caller intentionally owns the output file; sudo only reads the source.
  # shellcheck disable=SC2024
  sudo "$ROOT/bin/airlock-ledger" _checkpoint-helper archive \
    fixture rooted - "$STATE" "$OPT/link-tree/file" \
    >"$CASE/archive.tar" 2>"$CASE/checkpoint.log"
  local rc=$?
  if [ "$rc" != 0 ] && grep -q 'redirected' "$CASE/checkpoint.log"; then
    ok "privileged-redirect: sudo helper refuses a redirected ancestor"
  else
    bad "privileged-redirect: helper followed a redirected ancestor (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

privileged_file() {
  setup_case privileged-file
  chmod 000 "$ETC/fixture.conf"
  export AIRLOCK_TEST_PRIVILEGED_PATH="$ETC/fixture.conf"
  direct_read_fails "$ETC/fixture.conf" || {
    bad "privileged-file: fixture is readable without sudo"
    return
  }
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$? archive=""
  archive="$(checkpoint_archive_for_path "$ETC/fixture.conf" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ -n "$archive" ] \
      && tar -xOf "$archive" payload 2>/dev/null | grep -qx rooted-v1 \
      && grep -Fqx "$ROOT/bin/airlock-ledger _checkpoint-helper archive fixture rooted - $STATE $ETC/fixture.conf" \
        "$CASE/sudo.log"; then
    ok "privileged-file: unreadable rooted artifact is checkpointed through the sudo helper"
  else
    bad "privileged-file: checkpoint failed or bypassed sudo (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

privileged_directory() {
  setup_case privileged-directory
  mkdir -p "$OPT/private-tree"
  printf 'private-child\n' > "$OPT/private-tree/child"
  python3 - "$STATE/app-ledger.json" "$OPT/private-tree" <<'PY'
import json, sys
path, rooted = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
value["entries"]["fixture"]["committed"]["artifacts"]["rooted"] = [rooted]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  chmod 000 "$OPT/private-tree"
  export AIRLOCK_TEST_PRIVILEGED_PATH="$OPT/private-tree"
  if python3 - "$OPT/private-tree" 2>/dev/null <<'PY'
import os, sys
next(os.scandir(sys.argv[1]), None)
PY
  then
    bad "privileged-directory: fixture can be enumerated without sudo"
    return
  fi
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$? archive=""
  archive="$(checkpoint_archive_for_path "$OPT/private-tree" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ -n "$archive" ] \
      && tar -xOf "$archive" payload/child 2>/dev/null | grep -qx private-child \
      && grep -Fqx "$ROOT/bin/airlock-ledger _checkpoint-helper archive fixture rooted - $STATE $OPT/private-tree" \
        "$CASE/sudo.log"; then
    ok "privileged-directory: unreadable rooted directory is enumerated through the sudo helper"
  else
    bad "privileged-directory: checkpoint failed or bypassed sudo (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

privileged_system_unit() {
  setup_case privileged-system-unit
  mv "$UU/airlock-fixture.service" "$US/airlock-fixture.service"
  python3 - "$STATE/app-ledger.json" "$US/airlock-fixture.service" <<'PY'
import json, sys
path, unit = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
record = value["entries"]["fixture"]["committed"]
record["artifacts"]["units"] = [unit]
record["unit_scopes"] = {"airlock-fixture.service": "system"}
record["capabilities"].append("system-unit")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(value, fh)
PY
  chmod 000 "$US/airlock-fixture.service"
  export AIRLOCK_TEST_PRIVILEGED_PATH="$US/airlock-fixture.service"
  direct_read_fails "$US/airlock-fixture.service" || {
    bad "privileged-system-unit: fixture is readable without sudo"
    return
  }
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$? archive=""
  archive="$(checkpoint_archive_for_path "$US/airlock-fixture.service" 2>/dev/null || true)"
  if [ "$rc" = 0 ] && [ -n "$archive" ] \
      && tar -xOf "$archive" payload 2>/dev/null | grep -qx unit-v1 \
      && grep -Fqx "$ROOT/bin/airlock-ledger _checkpoint-helper archive fixture units system $STATE $US/airlock-fixture.service" \
        "$CASE/sudo.log"; then
    ok "privileged-system-unit: unreadable system unit is checkpointed through sudo"
  else
    bad "privileged-system-unit: checkpoint failed or bypassed sudo (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

privileged_denied() {
  setup_case privileged-denied
  chmod 000 "$ETC/fixture.conf"
  export AIRLOCK_TEST_PRIVILEGED_PATH="$ETC/fixture.conf" AIRLOCK_TEST_SUDO_DENY=1
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -q 'sudo could not capture checkpoint artifact' "$CASE/checkpoint.log"; then
    ok "privileged-denied: sudo read failure refuses checkpoint"
  else
    bad "privileged-denied: checkpoint did not fail closed (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

missing_recorded() {
  setup_case missing-recorded
  rm -f "$ETC/fixture.conf"
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -q 'checkpoint artifact is missing' "$CASE/checkpoint.log"; then
    ok "missing-recorded: absent committed artifact refuses checkpoint"
  else
    bad "missing-recorded: absence was accepted or misclassified (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

privileged_arbitrary_path() {
  setup_case privileged-arbitrary
  printf 'not-recorded\n' > "$OPT/not-recorded"
  export AIRLOCK_TEST_PRIVILEGED_PATH="$OPT/not-recorded"
  # The caller intentionally owns the output file; sudo only reads the source.
  # shellcheck disable=SC2024
  sudo "$ROOT/bin/airlock-ledger" _checkpoint-helper archive \
    fixture rooted - "$STATE" "$OPT/not-recorded" \
    >"$CASE/archive.tar" 2>"$CASE/checkpoint.log"
  local rc=$?
  if [ "$rc" != 0 ] \
      && grep -q 'not an exact committed artifact' "$CASE/checkpoint.log"; then
    ok "privileged-arbitrary: sudo helper refuses a path absent from the committed class"
  else
    bad "privileged-arbitrary: helper accepted an uncommitted path (rc=$rc)"
  fi
}

top_level_socket() {
  setup_case top-level-socket
  rm -f "$FAKEHOME/files/link"
  make_socket "$FAKEHOME/files/link"
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture \
    >"$CASE/checkpoint.log" 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -q 'top-level Unix socket' "$CASE/checkpoint.log"; then
    ok "top-level-socket: a socket declared directly remains unsupported"
  else
    bad "top-level-socket: direct socket was accepted (rc=$rc)"
  fi
}

unsupported_special() {
  setup_case unsupported-special
  mkfifo "$WEB/app/tree/live.fifo"
  python3 - "$ROOT/bin/airlock-ledger" "$WEB/app/tree" "$CASE" <<'PY' \
    >"$CASE/checkpoint.log" 2>&1
import pathlib, runpy, sys, tarfile
ledger_path, fifo_tree, output = sys.argv[1:]
ledger = runpy.run_path(ledger_path)
cases = (("descendant FIFO", fifo_tree), ("device node", "/dev/null"))
for index, (label, source) in enumerate(cases):
    try:
        with tarfile.open(pathlib.Path(output) / f"special-{index}.tar", "x") as bundle:
            ledger["_capture_checkpoint_tree"](bundle, source, privileged=True)
    except ledger["LedgerError"] as exc:
        if "unsupported checkpoint artifact type" in str(exc):
            continue
        print(f"{label}: wrong refusal: {exc}")
    else:
        print(f"{label}: accepted")
    raise SystemExit(23)
PY
  local rc=$?
  if [ "$rc" = 0 ]; then
    ok "unsupported-special: descendant FIFO and device node remain refused by one type guard"
  else
    bad "unsupported-special: FIFO/device table found an unguarded type (rc=$rc); $(tr '\n' ';' < "$CASE/checkpoint.log")"
  fi
}

container_intact_after_intent() {
  setup_case container-intact
  containerize_fixture
  local socket_before
  socket_before="$(stat -c '%d:%i' "$FAKEHOME/files/runtime/sockets/fpm.sock")"
  "$ROOT/bin/airlock-ledger" transaction-begin reinstall:fixture \
    >"$CASE/checkpoint.log" 2>&1 || {
      bad "container-intact: checkpoint creation failed; $(tr '\n' ';' < "$CASE/checkpoint.log")"
      return
    }
  local receipt
  receipt="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c \
    'import json,sys; tx=json.load(sys.stdin); print(tx["checkpoints"]["fixture"]["artifacts"][3]["ephemeral_sockets"][0])' \
    2>/dev/null || true)"
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  add_transient_intent
  "$ROOT/bin/airlock-ledger" transaction-fail install fixture
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase intent_present committed_id
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  read -r intent_present committed_id < <(python3 - "$STATE/app-ledger.json" <<'PY'
import json, sys
entry=json.load(open(sys.argv[1],encoding="utf-8"))["entries"]["fixture"]
print("yes" if "intent" in entry else "no", entry["committed"]["container_runtime"]["objects"][0]["id"])
PY
)
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] \
      && [ "$receipt" = sockets/fpm.sock ] && [ -S "$FAKEHOME/files/runtime/sockets/fpm.sock" ] \
      && [ "$(stat -c '%d:%i' "$FAKEHOME/files/runtime/sockets/fpm.sock")" = "$socket_before" ] \
      && [ "$intent_present" = no ] && [ "$committed_id" = "$AIRLOCK_TEST_CONTAINER_ID" ] \
      && ! grep -Eq '^(rm|stop|kill) ' "$CASE/docker.log"; then
    ok "container-intact: transient intent rollback preserves exact old container and socket"
  else
    bad "container-intact: intact fast path failed (rc=$rc phase=${phase:-none} receipt=${receipt:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

container_regular_changed() {
  setup_case container-changed
  containerize_fixture
  "$ROOT/bin/airlock-ledger" transaction-begin reinstall:fixture \
    >"$CASE/checkpoint.log" 2>&1 || {
      bad "container-changed: checkpoint creation failed; $(tr '\n' ';' < "$CASE/checkpoint.log")"
      return
    }
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  add_transient_intent
  printf 'runtime-v2\n' > "$FAKEHOME/files/runtime/state"
  "$ROOT/bin/airlock-ledger" transaction-fail install fixture
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  if [ "$rc" != 0 ] && [ "$phase" = degraded ] \
      && grep -qx runtime-v2 "$FAKEHOME/files/runtime/state" \
      && [ -S "$FAKEHOME/files/runtime/sockets/fpm.sock" ] \
      && grep -q 'existing runtime was preserved for manual recovery' "$CASE/restore.log" \
      && ! grep -Eq '^(rm|stop|kill) ' "$CASE/docker.log"; then
    ok "container-changed: non-socket drift degrades before destroying old runtime"
  else
    bad "container-changed: drift was reported as restored or runtime was touched (rc=$rc phase=${phase:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

container_identity_changed() {
  setup_case container-identity-changed
  containerize_fixture
  "$ROOT/bin/airlock-ledger" transaction-begin reinstall:fixture \
    >"$CASE/checkpoint.log" 2>&1 || {
      bad "container-identity-changed: checkpoint creation failed; $(tr '\n' ';' < "$CASE/checkpoint.log")"
      return
    }
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  add_transient_intent
  AIRLOCK_TEST_CONTAINER_ID="$(printf 'e%.0s' {1..64})"
  export AIRLOCK_TEST_CONTAINER_ID
  "$ROOT/bin/airlock-ledger" transaction-fail install fixture
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  if [ "$rc" != 0 ] && [ "$phase" = degraded ] \
      && grep -qx runtime-v1 "$FAKEHOME/files/runtime/state" \
      && [ -S "$FAKEHOME/files/runtime/sockets/fpm.sock" ] \
      && grep -q 'existing runtime was preserved for manual recovery' "$CASE/restore.log" \
      && ! grep -Eq '^(rm|stop|kill) ' "$CASE/docker.log"; then
    ok "container-identity-changed: exact ID mismatch degrades before runtime teardown"
  else
    bad "container-identity-changed: mismatch touched runtime or claimed restore (rc=$rc phase=${phase:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

shared_root_container_restore() {
  setup_case shared-root-container
  local shared="$FAKEHOME/.local/opt/airlock-notes"
  local notes_id
  notes_id="$(printf 'd%.0s' {1..64})"
  mkdir -p "$shared/perlite-old" "$shared/silverbullet-old" \
    "$CASE/pkg-notes" "$CASE/pkg-perlite" "$CASE/pkg-silverbullet"
  printf 'notes-owned\n' > "$shared/notes.conf"
  printf 'perlite-v1\n' > "$shared/perlite-old/index.php"
  printf 'silverbullet-v1\n' > "$shared/silverbullet-old/silverbullet"
  printf 'package\n' > "$CASE/pkg-notes/content"
  printf 'package\n' > "$CASE/pkg-perlite/content"
  printf 'package\n' > "$CASE/pkg-silverbullet/content"
  python3 - "$STATE/app-ledger.json" "$shared" "$CASE" "$UU" "$US" \
    "$CONFD" "$WEB" "$FAKEHOME" "$notes_id" <<'PY'
import json, os, sys
ledger, shared, case, uu, us, confd, web, home, notes_id = sys.argv[1:]

def record(app_id, path, order, runtime=None):
    artifacts = {name: [] for name in
                 ("units", "fragments", "webroot", "files", "rooted", "serve_ports")}
    artifacts["files"] = [path]
    return {
        "path": os.path.join(case, f"pkg-{app_id}"), "digest": "c" * 64,
        "lifecycle": {"install": True, "smoke": True, "deactivate": True},
        "artifacts": artifacts, "deps": [], "serve_mappings": {},
        "unit_scopes": {}, "order": order,
        "roots": {"unit_user": uu, "unit_system": us, "confd": confd,
                  "webroot": web, "home": home},
        "source_class": "shipped", "capabilities": [],
        "container_runtime": runtime,
    }

runtime = {
    "runtime": "docker", "daemon_identity": "docker:fixture-daemon",
    "install_nonce": "notes_nonce_0001", "declarations": ["airlock-notes-*"],
    "objects": [{"id": notes_id, "name": "airlock-notes-router"}],
}
entries = {
    "notes": {"committed": record("notes", shared, 1, runtime)},
    "perlite": {"committed": record("perlite", os.path.join(shared, "perlite-old"), 2)},
    "silverbullet": {"committed": record("silverbullet", os.path.join(shared, "silverbullet-old"), 3)},
}
with open(ledger, "w", encoding="utf-8") as fh:
    json.dump({"version": 6, "entries": entries, "events": []}, fh)
PY
  chmod 600 "$STATE/app-ledger.json"
  cat > "$SHIM/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_CASE/docker.log"
case "${1:-}" in
  info)
    [ "${2:-}" != --format ] || printf '%s\n' fixture-daemon
    exit 0
    ;;
  ps)
    printf '%s\n' "$AIRLOCK_TEST_NOTES_CONTAINER_ID"
    exit 0
    ;;
  inspect)
    [ "${2:-}" = "$AIRLOCK_TEST_NOTES_CONTAINER_ID" ] || exit 91
    printf '[{"Id":"%s","Name":"/airlock-notes-router","Config":{"Labels":{"io.airlock.package":"notes","io.airlock.install-nonce":"notes_nonce_0001"}}}]\n' \
      "$AIRLOCK_TEST_NOTES_CONTAINER_ID"
    exit 0
    ;;
esac
exit 91
STUB
  chmod +x "$SHIM/docker"
  AIRLOCK_TEST_NOTES_CONTAINER_ID="$notes_id"; export AIRLOCK_TEST_NOTES_CONTAINER_ID

  "$ROOT/bin/airlock-ledger" transaction-begin \
    reinstall:notes upgrade-deactivate:perlite upgrade-deactivate:silverbullet \
    >"$CASE/checkpoint.log" 2>&1 || {
      bad "shared-root-container: checkpoint creation failed; $(tr '\n' ';' < "$CASE/checkpoint.log")"
      return
    }
  "$ROOT/bin/airlock-ledger" transaction-touch notes
  "$ROOT/bin/airlock-ledger" transaction-deactivated perlite
  "$ROOT/bin/airlock-ledger" transaction-deactivated silverbullet
  printf 'perlite-v2\n' > "$shared/perlite-old/index.php"
  printf 'silverbullet-v2\n' > "$shared/silverbullet-old/silverbullet"
  "$ROOT/bin/airlock-ledger" transaction-fail install silverbullet
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase notes_status
  read -r phase notes_status < <(
    "$ROOT/bin/airlock-ledger" transaction-show | python3 -c \
      'import json,sys; tx=json.load(sys.stdin); print(tx["phase"], tx["restore_results"].get("notes",{}).get("status","missing"))')
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] && [ "$notes_status" = restored ] \
      && grep -qx perlite-v1 "$shared/perlite-old/index.php" \
      && grep -qx silverbullet-v1 "$shared/silverbullet-old/silverbullet" \
      && grep -qx notes-owned "$shared/notes.conf" \
      && ! grep -Eq '^(rm|stop|kill) ' "$CASE/docker.log"; then
    shared_root_restore=1
    ok "shared-root-container: sibling restores cannot invalidate the intact shared-root owner"
  else
    bad "shared-root-container: sibling restore wedged the shared-root owner (rc=$rc phase=${phase:-none} notes=${notes_status:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
    return
  fi

  "$ROOT/bin/airlock-ledger" transaction-begin \
    reinstall:notes upgrade-deactivate:perlite upgrade-deactivate:silverbullet \
    >"$CASE/drift-checkpoint.log" 2>&1 || {
      bad "shared-root-container-drift: checkpoint creation failed; $(tr '\n' ';' < "$CASE/drift-checkpoint.log")"
      return
    }
  "$ROOT/bin/airlock-ledger" transaction-touch notes
  "$ROOT/bin/airlock-ledger" transaction-deactivated perlite
  "$ROOT/bin/airlock-ledger" transaction-deactivated silverbullet
  printf 'notes-owned-v2\n' > "$shared/notes.conf"
  printf 'perlite-v2\n' > "$shared/perlite-old/index.php"
  printf 'silverbullet-v2\n' > "$shared/silverbullet-old/silverbullet"
  "$ROOT/bin/airlock-ledger" transaction-fail install silverbullet
  "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/drift-restore.log" 2>&1
  rc=$?
  read -r phase notes_status < <(
    "$ROOT/bin/airlock-ledger" transaction-show | python3 -c \
      'import json,sys; tx=json.load(sys.stdin); print(tx["phase"], tx["restore_results"].get("notes",{}).get("status","missing"))')
  if [ "$rc" != 0 ] && [ "$phase" = degraded ] && [ "$notes_status" = failed ] \
      && grep -qx notes-owned-v2 "$shared/notes.conf" \
      && grep -qx perlite-v1 "$shared/perlite-old/index.php" \
      && grep -qx silverbullet-v1 "$shared/silverbullet-old/silverbullet" \
      && grep -q 'existing runtime was preserved for manual recovery' "$CASE/drift-restore.log" \
      && ! grep -Eq '^(rm|stop|kill) ' "$CASE/docker.log"; then
    owner_drift_reject=1
    ok "shared-root-container-drift: parent-owned drift still fails closed"
  else
    bad "shared-root-container-drift: nested exclusion hid owner drift (rc=$rc phase=${phase:-none} notes=${notes_status:-none}); $(tr '\n' ';' < "$CASE/drift-restore.log")"
  fi
}

checkpoint_parent_redirect() {
  setup_case checkpoint-parent-redirect
  local outside="$TMP/checkpoint-outside"
  mkdir -p "$outside"
  ln -s "$outside" "$STATE/install-checkpoints"
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture >/dev/null 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]; then
    ok "checkpoint-parent-redirect: redirected checkpoint root is refused before external writes"
  else
    bad "checkpoint-parent-redirect: redirected checkpoint root was touched (rc=$rc)"
  fi
}

crash_reenter() {
  setup_case crash
  begin_fixture || { bad "crash-reenter: checkpoint creation failed"; return; }
  mutate_fixture
  "$ROOT/bin/airlock-ledger" transaction-fail install fixture
  local failed_phase failed_error degraded_commit_rc degraded_touch_rc
  read -r failed_phase failed_error < <(
    "$ROOT/bin/airlock-ledger" transaction-show | python3 -c \
      'import json,sys; tx=json.load(sys.stdin); print(tx["phase"], tx["error"]["phase"])')
  "$ROOT/bin/airlock-ledger" transaction-finish committed \
    >"$CASE/degraded-commit.log" 2>&1
  degraded_commit_rc=$?
  "$ROOT/bin/airlock-ledger" transaction-touch fixture \
    >"$CASE/degraded-touch.log" 2>&1
  degraded_touch_rc=$?
  # A new process, with no shell-local state, consumes the durable degraded record.
  env AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD" \
    AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US" \
    AIRLOCK_PLATFORM_ETC="$ETC" AIRLOCK_PLATFORM_OPT="$OPT" HOME="$FAKEHOME" \
    PATH="$PATH" "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase committed_fail_rc committed_restore_rc
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  "$ROOT/bin/airlock-ledger" transaction-begin reinstall:fixture >/dev/null
  "$ROOT/bin/airlock-ledger" transaction-finish committed >/dev/null
  "$ROOT/bin/airlock-ledger" transaction-fail smoke fixture \
    >"$CASE/committed-fail.log" 2>&1
  committed_fail_rc=$?
  "$ROOT/bin/airlock-ledger" transaction-restore \
    >"$CASE/committed-restore.log" 2>&1
  committed_restore_rc=$?
  if [ "$failed_phase" = degraded ] && [ "$failed_error" = install ] \
      && [ "$degraded_commit_rc" != 0 ] && [ "$degraded_touch_rc" != 0 ] \
      && [ "$rc" = 0 ] && [ "$phase" = rolled_back ] \
      && grep -qx web-v1 "$WEB/app/tree/index.html" \
      && [ "$committed_fail_rc" != 0 ] && [ "$committed_restore_rc" != 0 ]; then
    ok "crash-reenter: fail is durably degraded, fresh restore works, terminal transitions stay closed"
  else
    bad "crash-reenter: failure transition contract broke (failed=${failed_phase:-none} restore=$rc/$phase committed=$committed_fail_rc/$committed_restore_rc); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

case "$case_name" in
  roundtrip) roundtrip ;;
  candidate-user-file) candidate_user_file_roundtrip ;;
  candidate-user-file-other-actions) candidate_user_file_other_actions ;;
  forged-candidate-user-file) forged_candidate_user_file_receipt ;;
  corrupt) corrupt ;;
  permission) permission_denied ;;
  space) space_denied ;;
  symlink-redirect) symlink_redirect ;;
  checkpoint-parent-redirect) checkpoint_parent_redirect ;;
  privileged-file) privileged_file ;;
  privileged-directory) privileged_directory ;;
  privileged-system-unit) privileged_system_unit ;;
  privileged-redirect) privileged_redirect ;;
  privileged-denied) privileged_denied ;;
  missing-recorded) missing_recorded ;;
  privileged-arbitrary) privileged_arbitrary_path ;;
  top-level-socket) top_level_socket ;;
  fifo-descendant|device-top-level|unsupported-special) unsupported_special ;;
  container-intact) container_intact_after_intent ;;
  container-changed) container_regular_changed ;;
  container-identity-changed) container_identity_changed ;;
  shared-root-container) shared_root_container_restore ;;
  crash-reenter) crash_reenter ;;
  all)
    roundtrip
    candidate_user_file_roundtrip
    candidate_user_file_other_actions
    forged_candidate_user_file_receipt
    corrupt
    permission_denied
    space_denied
    symlink_redirect
    checkpoint_parent_redirect
    privileged_file
    privileged_directory
    privileged_system_unit
    privileged_redirect
    privileged_denied
    missing_recorded
    privileged_arbitrary_path
    top_level_socket
    unsupported_special
    container_intact_after_intent
    container_regular_changed
    container_identity_changed
    shared_root_container_restore
    crash_reenter
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' '---' "passed=$pass failed=$fail"
if [ "$emit_ac" = 1 ] && { [ "$case_name" = all ] || [ "$case_name" = shared-root-container ]; }; then
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  verdict=FAIL
  [ "$shared_root_restore" = 1 ] && [ "$owner_drift_reject" = 1 ] && verdict=PASS
  printf 'AC-MAU-A5-G | expected: shared_root_restore == 1 && owner_drift_reject == 1 | observed: shared_root_restore=%s,owner_drift_reject=%s | verdict: %s | signal: fixture | evidence: install/test-install-transaction-primitive.sh@%s\n' \
    "$shared_root_restore" "$owner_drift_reject" "$verdict" "$revision"
fi
[ "$fail" -eq 0 ]
