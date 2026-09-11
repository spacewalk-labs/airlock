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

case_name="${2:-${1:-all}}"
if [ "${1:-}" = --case ]; then case_name="${2:-}"; fi

setup_case() {
  local name="$1"
  CASE="$TMP/$name" STATE="$TMP/$name/state" WEB="$TMP/$name/web"
  CONFD="$TMP/$name/confd" UU="$TMP/$name/user-units" US="$TMP/$name/system-units"
  FAKEHOME="$TMP/$name/home" ETC="$TMP/$name/platform-etc" OPT="$TMP/$name/platform-opt"
  SHIM="$TMP/$name/shim"
  mkdir -p "$STATE" "$WEB/app/tree" "$CONFD/servers.d" "$UU" "$US" \
    "$FAKEHOME/files" "$ETC" "$OPT" "$SHIM" "$CASE/pkg"
  export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
  export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
  export AIRLOCK_PLATFORM_ETC="$ETC" AIRLOCK_PLATFORM_OPT="$OPT" HOME="$FAKEHOME"
  export AIRLOCK_CONFIG_SNAPSHOT_SHA256="$(printf 'a%.0s' {1..64})"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf 'b%.0s' {1..64})"
  printf '#!/usr/bin/env bash\nexec "$@"\n' > "$SHIM/sudo"
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
}

begin_fixture() {
  "$ROOT/bin/airlock-ledger" transaction-begin upgrade-deactivate:fixture >/dev/null
  "$ROOT/bin/airlock-ledger" transaction-touch fixture
  "$ROOT/bin/airlock-ledger" transaction-deactivated fixture
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
      && grep -q 'enable airlock-fixture.service' "$CASE/systemctl.log" \
      && grep -q -- '--https=19443 http://127.0.0.1:19444' "$CASE/tailscale.log"; then
    ok "roundtrip: units/fragments/webroot/files/symlink/rooted/mode/unit state/mapping restore"
  else
    bad "roundtrip: restore oracle failed (rc=$rc phase=${phase:-none} link=${link:-none} mode=${mode:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
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
  "$ROOT/bin/airlock-ledger" transaction-begin fixture >/dev/null 2>&1
  local rc=$?
  chmod 0644 "$WEB/app/tree/index.html"
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -qx web-v1 "$WEB/app/tree/index.html"; then
    ok "permission: unreadable artifact refuses checkpoint before transaction publication"
  else
    bad "permission: checkpoint did not fail closed (rc=$rc)"
  fi
}

space_denied() {
  setup_case space
  dd if=/dev/zero of="$WEB/app/tree/large" bs=4096 count=1 status=none
  (ulimit -f 1; "$ROOT/bin/airlock-ledger" transaction-begin fixture >/dev/null 2>&1)
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
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
  "$ROOT/bin/airlock-ledger" transaction-begin fixture >/dev/null 2>&1
  local rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$STATE/install-transaction.json" ] \
      && grep -qx fragment-v1 "$CONFD/real-servers.d/fixture.conf"; then
    ok "symlink-redirect: existing containment gate refuses redirected ancestor"
  else
    bad "symlink-redirect: checkpoint did not fail closed (rc=$rc)"
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
  # A new process, with no shell-local state, consumes only the durable record.
  env AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD" \
    AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US" \
    AIRLOCK_PLATFORM_ETC="$ETC" AIRLOCK_PLATFORM_OPT="$OPT" HOME="$FAKEHOME" \
    PATH="$PATH" "$ROOT/bin/airlock-ledger" transaction-restore >"$CASE/restore.log" 2>&1
  local rc=$? phase
  phase="$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')"
  if [ "$rc" = 0 ] && [ "$phase" = rolled_back ] && grep -qx web-v1 "$WEB/app/tree/index.html"; then
    ok "crash-reenter: a fresh process restores the durable checkpoint"
  else
    bad "crash-reenter: durable recovery failed (rc=$rc phase=${phase:-none}); $(tr '\n' ';' < "$CASE/restore.log")"
  fi
}

case "$case_name" in
  roundtrip) roundtrip ;;
  corrupt) corrupt ;;
  permission) permission_denied ;;
  space) space_denied ;;
  symlink-redirect) symlink_redirect ;;
  checkpoint-parent-redirect) checkpoint_parent_redirect ;;
  crash-reenter) crash_reenter ;;
  all)
    roundtrip
    corrupt
    permission_denied
    space_denied
    symlink_redirect
    checkpoint_parent_redirect
    crash_reenter
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' '---' "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
