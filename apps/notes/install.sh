#!/usr/bin/env bash
# Notes — config-backed vault registry, Perlite readers, and SilverBullet editors.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-notes}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load notes
require_cmd python3 curl sha256sum unzip systemctl docker

READER_PORT="${AIRLOCK_NOTES_READER_PORT:?}"
EDITOR_PORT_BASE="${AIRLOCK_NOTES_EDITOR_PORT_BASE:?}"
VAULT_SLOTS="${AIRLOCK_NOTES_VAULT_SLOTS:?}"
NONCE="${AIRLOCK_INSTALL_NONCE:-}"
RECONCILE_MODE="${AIRLOCK_CONTAINER_RECONCILE_MODE:-}"
EXPECTED_DAEMON_IDENTITY="${AIRLOCK_CONTAINER_DAEMON_IDENTITY:-}"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "$NONCE" ]; then NONCE="dry-run-nonce-0001"; fi
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  RECONCILE_MODE="${RECONCILE_MODE:-fresh}"
  EXPECTED_DAEMON_IDENTITY="${EXPECTED_DAEMON_IDENTITY:-docker:dry-run}"
fi
[[ "$NONCE" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
  || die "AIRLOCK_INSTALL_NONCE is missing or invalid"
case "$RECONCILE_MODE" in fresh|reuse-required) ;; *) die "container reconcile mode is missing or invalid" ;; esac
[[ "$EXPECTED_DAEMON_IDENTITY" =~ ^docker:[A-Za-z0-9][A-Za-z0-9:_-]{0,255}$ ]] \
  || die "Docker daemon identity is missing or invalid"

PERLITE_IMAGE="sec77/perlite@sha256:e4912b9a014b5f68b0f29386244e5600e935de09e66906fb13e849f54d2b300c"
NGINX_IMAGE="nginx@sha256:46ccc48fbb1f5a43167f2ee2c279c122b96eec5d976e7f4e1e0780f59a51b4d6"
SB_VER="2.10.0"
SB_SHA256="ca33f7de3bae2f2e7d95cdd2cca1a023e51267388c9dbc8ff5acc33b1cbd5a7d"
SB_URL="https://github.com/silverbulletmd/silverbullet/releases/download/${SB_VER}/silverbullet-server-linux-x86_64.zip"

case "$(uname -m)" in x86_64) ;; *) die "notes supports x86_64 only" ;; esac

RUNTIME="$HOME/.local/share/airlock/notes"
OPT="$HOME/.local/opt/airlock-notes"
UNIT_DIR="$HOME/.config/systemd/user"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  RUNTIME="$AIRLOCK_RENDER_DIR/runtime"
  OPT="$AIRLOCK_RENDER_DIR/opt"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
  CONFD="$AIRLOCK_RENDER_DIR/confd"
fi

DEFAULT_VAULT="$(airlock_config get apps.notes.vaults.default_vault)" \
  || die "apps.notes.vaults.default_vault is required"
ENTRIES_JSON="$(airlock_config get apps.notes.vaults.entries)" \
  || die "apps.notes.vaults.entries is required"

plan_args=(
  --entries-json "$ENTRIES_JSON" --default-vault "$DEFAULT_VAULT" --home "$HOME"
  --reader-port "$READER_PORT" --editor-port-base "$EDITOR_PORT_BASE"
  --vault-slots "$VAULT_SLOTS"
)
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then plan_args+=(--skip-path-check); fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
python3 "$HERE/bin/config-plan.py" "${plan_args[@]}" > "$stage/server-plan.json"
python3 "$HERE/bin/config-plan.py" "${plan_args[@]}" --format client > "$stage/vaults.json"

docker_cmd=(docker)
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] && ! docker info >/dev/null 2>&1; then
  sudo -n docker info >/dev/null 2>&1 || die "Docker daemon unavailable"
  docker_cmd=(sudo -n docker)
fi
docker_run() { "${docker_cmd[@]}" "$@"; }
assert_docker_identity() {
  local engine_id actual
  engine_id="$(docker_run info --format '{{.ID}}')" || die "Docker daemon identity query failed"
  actual="docker:$engine_id"
  [ "$actual" = "$EXPECTED_DAEMON_IDENTITY" ] \
    || die "Docker daemon identity changed during Notes lifecycle"
}
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then assert_docker_identity; fi

container_is_absent() {
  local object_id="$1" inspect_error
  if inspect_error="$(docker_run inspect "$object_id" 2>&1 >/dev/null)"; then
    return 1
  fi
  case "$inspect_error" in
    "Error: No such object: $object_id"|\
    "Error response from daemon: No such container: $object_id") ;;
    *) return 1 ;;
  esac
  assert_docker_identity
}

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] verify immutable images already present: $PERLITE_IMAGE $NGINX_IMAGE"
  perlite_id="sha256:dry-perlite"
else
  perlite_id="$(docker_run image inspect "$PERLITE_IMAGE" --format '{{.Id}}')" \
    || die "pinned Perlite image absent; preload it explicitly: $PERLITE_IMAGE"
  docker_run image inspect "$NGINX_IMAGE" >/dev/null \
    || die "pinned nginx image absent; preload it explicitly: $NGINX_IMAGE"
fi

install -d -m 700 "$RUNTIME/runs" "$OPT" "$UNIT_DIR" "$CONFD/hub-locations.d"
perlite_root="$OPT/perlite-${perlite_id#sha256:}"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  install -d "$perlite_root"
  : > "$perlite_root/index.php"
elif [ ! -f "$perlite_root/.airlock-image-id" ] \
  || [ "$(cat "$perlite_root/.airlock-image-id" 2>/dev/null || true)" != "$perlite_id" ]; then
  image_tar="$stage/perlite-image.tar"
  extracted="$stage/perlite-root"
  docker_run image save "$PERLITE_IMAGE" > "$image_tar"
  python3 "$HERE/bin/extract-image-path.py" --archive "$image_tar" --destination "$extracted"
  printf '%s\n' "$perlite_id" > "$extracted/.airlock-image-id"
  rm -rf "$perlite_root"
  mv "$extracted" "$perlite_root"
fi
# Docker cannot synthesize nested bind targets below the read-only Perlite root
# bind. These two empty directories are package-owned mountpoints, not data.
install -d -m 755 "$perlite_root/notes" "$perlite_root/_obs"

SB_DIR="$OPT/silverbullet-${SB_VER}"
SB_BIN="$SB_DIR/silverbullet"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  install -d "$SB_DIR"; : > "$SB_BIN"; chmod 755 "$SB_BIN"
elif [ ! -x "$SB_BIN" ] \
  || ! "$SB_BIN" version 2>/dev/null | head -1 | grep -Eq "^${SB_VER}([+ -]|$)"; then
  curl -fsSL --max-time 180 -o "$stage/silverbullet.zip" "$SB_URL"
  echo "$SB_SHA256  $stage/silverbullet.zip" | sha256sum -c - >/dev/null
  unzip -oq "$stage/silverbullet.zip" -d "$stage/silverbullet"
  [ -f "$stage/silverbullet/silverbullet" ] || die "SilverBullet archive has no binary"
  install -d -m 700 "$SB_DIR"
  install -m 755 "$stage/silverbullet/silverbullet" "$SB_DIR/.silverbullet.new"
  mv "$SB_DIR/.silverbullet.new" "$SB_BIN"
fi

run_final="$RUNTIME/runs/$NONCE"
can_reuse_containers() {
  local current_plan="$RUNTIME/current/server-plan.json" ids inspect_file
  local -a id_args=()
  assert_docker_identity
  [ -f "$current_plan" ] && cmp -s "$current_plan" "$stage/server-plan.json" || return 1
  ids="$(docker_run ps -aq --no-trunc --filter "label=io.airlock.package=notes" \
    --filter "label=io.airlock.install-nonce=$NONCE")" || return 1
  while IFS= read -r id; do [ -z "$id" ] || id_args+=("$id"); done <<< "$ids"
  [ "${#id_args[@]}" -gt 0 ] || return 1
  inspect_file="$stage/current-containers.json"
  docker_run inspect "${id_args[@]}" > "$inspect_file" || return 1
  python3 - "$stage/server-plan.json" "$inspect_file" "$NONCE" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1])); objects=json.load(open(sys.argv[2])); nonce=sys.argv[3]
expected={plan["router_container"], *(v["reader_container"] for v in plan["vaults"])}
actual=set()
for obj in objects:
    labels=obj.get("Config", {}).get("Labels") or {}
    if (obj.get("State", {}).get("Running") is not True
            or labels.get("io.airlock.package") != "notes"
            or labels.get("io.airlock.install-nonce") != nonce):
        raise SystemExit(1)
    actual.add(obj.get("Name", "").removeprefix("/"))
raise SystemExit(0 if actual == expected and len(objects) == len(expected) else 1)
PY
  local result=$?
  assert_docker_identity
  return "$result"
}

if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  admission="$(airlock_config container-admit notes)" \
    || die "container runtime admission changed before Notes mutation"
  IFS=$'\t' read -r admitted_mode admitted_nonce admitted_identity extra <<< "$admission"
  [ -z "${extra:-}" ] && [ "$admitted_mode" = "$RECONCILE_MODE" ] \
    && [ "$admitted_nonce" = "$NONCE" ] \
    && [ "$admitted_identity" = "$EXPECTED_DAEMON_IDENTITY" ] \
    || die "container runtime admission no longer matches the loaded intent"
  assert_docker_identity
  if [ "$RECONCILE_MODE" = reuse-required ]; then
    if can_reuse_containers; then
      [ -f "$run_final/airlock-notes-editor.service" ] \
        && [ -f "$run_final/notes.conf" ] || die "reusable container set has no runtime render"
      install -m 644 "$run_final/airlock-notes-editor.service" "$UNIT_DIR/airlock-notes-editor.service"
      install -m 644 "$run_final/notes.conf" "$CONFD/hub-locations.d/notes.conf"
      systemctl --user daemon-reload
      systemctl --user enable --now airlock-notes-editor.service
      log "notes unchanged; retained committed container ids (nonce=$NONCE)"
      exit 0
    fi
    die "the committed Notes container set is not reusable; remove the [apps.notes] subtree and run the normal installer once, then restore the changed subtree and install again"
  fi
fi

run_stage="$RUNTIME/runs/.${NONCE}.$$"
rm -rf "$run_stage"
install -d -m 700 "$run_stage/obs" "$run_stage/sockets"
install -m 600 "$stage/server-plan.json" "$run_stage/server-plan.json"
install -m 644 "$stage/vaults.json" "$run_stage/obs/vaults.json"
python3 "$HERE/bin/render.py" \
  --plan "$run_stage/server-plan.json" --out "$run_stage" \
  --unit "$run_stage/airlock-notes-editor.service" \
  --fragment "$run_stage/notes.conf" --runtime-plan "$run_final/server-plan.json" \
  --silverbullet "$SB_BIN" \
  --supervisor "$HERE/bin/editor-supervisor.py" --uid "$(id -u)" --gid "$(id -g)"
install -m 644 "$run_stage/edit-jump.js" "$run_stage/obs/edit-jump.js"
install -m 644 "$HERE/reader/raw.php" "$run_stage/obs/raw.php"
install -m 644 "$HERE/reader/app.html" "$run_stage/obs/app.html"
while IFS= read -r vault_id; do
  install -d -m 700 "$run_stage/sockets/$vault_id"
done < <(python3 -c 'import json,sys; print("\n".join(v["id"] for v in json.load(open(sys.argv[1]))["vaults"]))' "$run_stage/server-plan.json")

cleanup_nonce() {
  local ids listed_id inspected package_label nonce_label full_id remaining failed=0
  assert_docker_identity
  ids="$(docker_run ps -aq --no-trunc \
    --filter "label=io.airlock.package=notes" \
    --filter "label=io.airlock.install-nonce=$NONCE")" || return 1
  while IFS= read -r listed_id; do
    [ -n "$listed_id" ] || continue
    [[ "$listed_id" =~ ^[0-9a-f]{64}$ ]] || { failed=1; continue; }
    inspected="$(docker_run inspect --format '{{.Id}} {{index .Config.Labels "io.airlock.package"}} {{index .Config.Labels "io.airlock.install-nonce"}}' "$listed_id")" \
      || { failed=1; continue; }
    read -r full_id package_label nonce_label <<< "$inspected"
    if [ "$full_id" != "$listed_id" ] || [ "$package_label" != notes ] \
      || [ "$nonce_label" != "$NONCE" ]; then
      failed=1
      continue
    fi
    assert_docker_identity
    docker_run rm -f "$full_id" >/dev/null || failed=1
    container_is_absent "$full_id" || failed=1
  done <<< "$ids"
  remaining="$(docker_run ps -aq --no-trunc \
    --filter "label=io.airlock.package=notes" \
    --filter "label=io.airlock.install-nonce=$NONCE")" || return 1
  [ -z "$remaining" ] || failed=1
  assert_docker_identity
  return "$failed"
}

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] create airlock-notes-reader-* and airlock-notes-router with nonce $NONCE"
else
  cleanup_nonce || die "could not remove the active nonce's prior container set"
fi
rm -rf "$run_final"
mv "$run_stage" "$run_final"
ln_tmp="$RUNTIME/.current.$$"
ln -s "runs/$NONCE" "$ln_tmp"
mv -Tf "$ln_tmp" "$RUNTIME/current"

install -m 644 "$run_final/airlock-notes-editor.service" "$UNIT_DIR/airlock-notes-editor.service"
install -m 644 "$run_final/notes.conf" "$CONFD/hub-locations.d/notes.conf"

if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  install_failed=1
  on_install_exit() {
    local exit_rc=$?
    if [ "$install_failed" = 1 ]; then cleanup_nonce || true; fi
    rm -rf "$stage"
    exit "$exit_rc"
  }
  trap on_install_exit EXIT
  while IFS=$'\t' read -r vault_id vault_path home_file container; do
    assert_docker_identity
    docker_run run -d --pull=never --name "$container" \
      --label io.airlock.package=notes \
      --label "io.airlock.install-nonce=$NONCE" \
      --restart unless-stopped --network none --read-only --user "$(id -u):$(id -g)" \
      --tmpfs "/tmp:rw,nosuid,nodev,noexec,mode=0700,uid=$(id -u),gid=$(id -g)" \
      --mount "type=bind,src=$perlite_root,dst=/var/www/perlite,readonly" \
      --mount "type=bind,src=$vault_path,dst=/var/www/perlite/notes,readonly" \
      --mount "type=bind,src=$run_final/obs,dst=/var/www/perlite/_obs,readonly" \
      --mount "type=bind,src=$run_final/php-fpm.conf,dst=/etc/airlock-notes-fpm.conf,readonly" \
      --mount "type=bind,src=$run_final/sockets/$vault_id,dst=/run/airlock-notes" \
      --env NOTES_PATH=notes --env URI_PATH=/notes/ \
      --env "HOME_FILE=$home_file" --env "SITE_TITLE=$vault_id" \
      --entrypoint php-fpm "$PERLITE_IMAGE" -F -y /etc/airlock-notes-fpm.conf >/dev/null
  done < <(python3 -c 'import json,sys
for v in json.load(open(sys.argv[1]))["vaults"]:
 print("\t".join((v["id"],v["path"],v["home_file"],v["reader_container"])))' "$run_final/server-plan.json")

  router_args=(run -d --pull=never --name airlock-notes-router
    --label io.airlock.package=notes --label "io.airlock.install-nonce=$NONCE"
    --restart unless-stopped --network host --read-only --user "$(id -u):$(id -g)"
    --tmpfs "/tmp:rw,nosuid,nodev,noexec,mode=0700,uid=$(id -u),gid=$(id -g)"
    --mount "type=bind,src=$perlite_root,dst=/var/www/perlite,readonly"
    --mount "type=bind,src=$run_final/obs,dst=/var/www/perlite/_obs,readonly"
    --mount "type=bind,src=$run_final/router.conf,dst=/etc/nginx/nginx.conf,readonly"
    --mount "type=bind,src=$run_final/sockets,dst=/run/airlock-notes,readonly")
  router_args+=(--entrypoint nginx "$NGINX_IMAGE" -c /etc/nginx/nginx.conf -g "daemon off;")
  assert_docker_identity
  docker_run "${router_args[@]}" >/dev/null

  ready=0
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$READER_PORT/" >/dev/null 2>&1; then ready=1; break; fi
    sleep .25
  done
  [ "$ready" = 1 ] || die "notes reader did not become healthy"
  systemctl --user daemon-reload
  systemctl --user enable --now airlock-notes-editor.service
  install_failed=0
fi

log "notes installed (vaults=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["vaults"]))' "$run_final/server-plan.json"), reader=127.0.0.1:$READER_PORT)"
