#!/usr/bin/env bash
# gui-provisioner.sh — turn one Ubuntu 24.04 host into a selected Airlock install.
#
# This script runs on the target host as root. The LXD E2E driver is retained only as a
# disposable proof harness; the Ubuntu product path installs directly on the host.
#
# Required:
#   AIRLOCK_GUI_BUNDLE          gzip tar made by build-gui-provisioner-bundle.sh
#   AIRLOCK_GUI_BUNDLE_SHA256   digest measured by the caller before delivery
#   AIRLOCK_GUI_HOSTNAME        tailnet hostname to claim
# Optional:
#   AIRLOCK_GUI_AUTHKEY_FILE    regular mode-0400/0600 file; consumed and deleted
#   AIRLOCK_GUI_OWNER           fallback owner login when Tailscale does not report one
#   AIRLOCK_GUI_EXPECTED_TAILNET
#                               expected DNS suffix (for example, a *.ts.net tailnet
#                               name); checked after auth and before stock install
#   AIRLOCK_GUI_SELECTION_FILE  root-owned mode-0400/0600 GUI selection JSON; when
#                               absent, the approved profile default is used
#
# stdout is newline-delimited JSON progress. Human diagnostics go to stderr. Exit 3 is
# the resumable needs-auth boundary; the stock installer has not run in that state.
set -euo pipefail

say() { printf '[gui-provisioner] %s\n' "$*" >&2; }
emit() {
  local event="$1" detail="${2:-}" value="${3:-}"
  EVENT="$event" DETAIL="$detail" VALUE="$value" python3 - <<'PY'
import json, os
doc = {"event": os.environ["EVENT"], "schema": "airlock.gui-progress/v1"}
if os.environ.get("DETAIL"):
    doc["detail"] = os.environ["DETAIL"]
if os.environ.get("VALUE"):
    doc["value"] = os.environ["VALUE"]
print(json.dumps(doc, sort_keys=True), flush=True)
PY
}

failure_stage=preflight
failure_code=preflight-failed
failure_message="설치 준비 상태를 확인하지 못했습니다."
failure_remedy="설치 파일과 기기 상태를 확인한 뒤 다시 시도해 주세요."
failure_log=""
terminal_emitted=0
set_failure() {
  failure_stage="$1" failure_code="$2" failure_message="$3" failure_remedy="$4" failure_log="${5:-}"
}
emit_failure() {
  [ "$terminal_emitted" = 0 ] || return 0
  terminal_emitted=1
  CODE="$failure_code" STAGE="$failure_stage" MESSAGE="$failure_message" \
  REMEDY="$failure_remedy" LOG_REF="$failure_log" python3 - <<'PY'
import json, os
doc = {
    "event": "failed", "schema": "airlock.gui-progress/v1",
    "code": os.environ["CODE"], "stage": os.environ["STAGE"],
    "message": os.environ["MESSAGE"], "remedy": os.environ["REMEDY"],
    "retry": True,
}
if os.environ.get("LOG_REF"):
    doc["log"] = os.environ["LOG_REF"]
print(json.dumps(doc, ensure_ascii=False, sort_keys=True), flush=True)
PY
}
die() { local detail="$*"; emit_failure; say "FATAL [$failure_code]: $detail"; exit 1; }
unexpected_failure() {
  local rc="$1"
  trap - ERR
  emit_failure || true
  say "FATAL [$failure_code]: unexpected command failure (exit $rc)"
  exit "$rc"
}
trap 'unexpected_failure $?' ERR

command -v python3 >/dev/null 2>&1 || { say "FATAL: python3 is required by the GUI installer"; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root on the target host"
[ -n "${AIRLOCK_GUI_BUNDLE:-}" ] || die "AIRLOCK_GUI_BUNDLE is not set"
[ -n "${AIRLOCK_GUI_BUNDLE_SHA256:-}" ] || die "AIRLOCK_GUI_BUNDLE_SHA256 is not set"
[ -n "${AIRLOCK_GUI_HOSTNAME:-}" ] || die "AIRLOCK_GUI_HOSTNAME is not set"

case "$AIRLOCK_GUI_BUNDLE_SHA256" in
  *[!0-9a-f]*|'') die "AIRLOCK_GUI_BUNDLE_SHA256 must be a lowercase SHA-256" ;;
esac
[ "${#AIRLOCK_GUI_BUNDLE_SHA256}" = 64 ] || die "AIRLOCK_GUI_BUNDLE_SHA256 must be 64 hex characters"
case "$AIRLOCK_GUI_HOSTNAME" in
  *[!a-z0-9-]*|-*|*-) die "AIRLOCK_GUI_HOSTNAME must be a lowercase DNS label" ;;
esac
[ "${#AIRLOCK_GUI_HOSTNAME}" -le 63 ] || die "AIRLOCK_GUI_HOSTNAME is longer than a DNS label"
if [ ! -f "$AIRLOCK_GUI_BUNDLE" ] || [ -L "$AIRLOCK_GUI_BUNDLE" ]; then
  die "bundle must be a regular non-symlink file"
fi

exec 9>/run/airlock-gui-provisioner.lock
flock -n 9 || die "another GUI provisioner is already running"

emit start target "$AIRLOCK_GUI_HOSTNAME"

# shellcheck source=/dev/null
os_id="$(. /etc/os-release && printf '%s' "$ID")"
# shellcheck source=/dev/null
os_version="$(. /etc/os-release && printf '%s' "$VERSION_ID")"
arch="$(uname -m)"
[ "$os_id" = ubuntu ] || die "unsupported host OS: $os_id"
[ "$os_version" = 24.04 ] || die "unsupported Ubuntu version: $os_version (need 24.04)"
[ "$arch" = x86_64 ] || die "unsupported Ubuntu architecture: $arch (this profile is x86_64)"
emit target-verified platform "ubuntu-${os_version}-${arch}"

actual_bundle_sha="$(sha256sum "$AIRLOCK_GUI_BUNDLE" | awk '{print $1}')"
[ "$actual_bundle_sha" = "$AIRLOCK_GUI_BUNDLE_SHA256" ] || die "bundle SHA-256 does not match the delivered digest"

scratch="$(mktemp -d /run/airlock-gui-extract.XXXXXX)" || die "could not create extraction directory"
auth_cleanup=""
release_staging=""
cleanup() {
  rm -rf "$scratch"
  [ -z "$auth_cleanup" ] || rm -f "$auth_cleanup"
  [ -z "${selection_file:-}" ] || rm -f "$selection_file"
  case "$release_staging" in
    /opt/airlock-gui/releases/.*) rm -rf -- "$release_staging" ;;
    '') ;;
    *) say "refusing unsafe release-staging cleanup path: $release_staging" ;;
  esac
}
trap cleanup EXIT

# Python's data filter rejects absolute paths, traversal, device nodes and link escapes.
BUNDLE="$AIRLOCK_GUI_BUNDLE" DEST="$scratch" python3 - <<'PY' || die "bundle extraction safety check failed"
import os, tarfile
with tarfile.open(os.environ["BUNDLE"], "r:gz") as tf:
    tf.extractall(os.environ["DEST"], filter="data")
PY

payload="$scratch/airlock"
manifest="$payload/gui-provisioner-manifest.json"
profile="$payload/docker/gui-default-profile.json"
catalog="$payload/docker/gui-catalog.json"
if [ ! -d "$payload" ] || [ -L "$payload" ]; then
  die "bundle must contain one airlock/ root"
fi
if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
  die "bundle manifest is missing or unsafe"
fi
if [ ! -f "$profile" ] || [ -L "$profile" ]; then
  die "GUI profile is missing or unsafe"
fi
if [ ! -f "$catalog" ] || [ -L "$catalog" ]; then
  die "GUI catalog is missing or unsafe"
fi
selection_helper="$payload/docker/gui_selection.py"
if [ ! -f "$selection_helper" ] || [ -L "$selection_helper" ]; then
  die "GUI selection validator is missing or unsafe"
fi

selection_file="${AIRLOCK_GUI_SELECTION_FILE:-}"
if [ -n "$selection_file" ]; then
  if [ ! -f "$selection_file" ] || [ -L "$selection_file" ]; then
    die "GUI selection must be a regular non-symlink file"
  fi
  selection_mode="$(stat -c '%a' "$selection_file" 2>/dev/null || true)"
  selection_owner="$(stat -c '%u' "$selection_file" 2>/dev/null || true)"
  case "$selection_mode" in 400|600) ;; *) die "GUI selection mode is ${selection_mode:-unknown}; need 400 or 600" ;; esac
  [ "$selection_owner" = 0 ] || die "GUI selection must be root-owned"
fi

selection_arg="${selection_file:--}"
meta="$(python3 "$selection_helper" \
  "$manifest" "$profile" "$catalog" "$selection_arg" "$arch" 2>&1)" \
  || die "bundle/profile/selection validation failed: $meta"
source_sha="$(printf '%s\n' "$meta" | sed -n '1p')"
install_apps="$(printf '%s\n' "$meta" | sed -n '2p')"
source_epoch="$(printf '%s\n' "$meta" | sed -n '3p')"

version_helper="$payload/docker/gui-version-relation.py"
set_failure version version-check-failed "설치 묶음의 버전을 확인하지 못했습니다." "설치 USB를 다시 만들어 주세요."
if [ ! -f "$version_helper" ] || [ -L "$version_helper" ]; then
  die "bundle version-relation helper is missing or unsafe"
fi
current_manifest="-"
if [ -L /opt/airlock-gui/current ]; then
  current_release="$(readlink -f /opt/airlock-gui/current)" \
    || die "current GUI release link is broken"
  case "$current_release" in
    /opt/airlock-gui/releases/*) ;;
    *) die "current GUI release link escapes the release root" ;;
  esac
  current_manifest="$current_release/gui-provisioner-manifest.json"
  if [ ! -f "$current_manifest" ] || [ -L "$current_manifest" ]; then
    die "current GUI release manifest is missing or unsafe"
  fi
elif [ -e /opt/airlock-gui/current ]; then
  die "current GUI release path exists but is not a symlink"
fi
version_relation="$(python3 "$version_helper" "$current_manifest" "$manifest")" \
  || die "could not compare current and candidate GUI bundle versions"
case "$version_relation" in
  fresh|same|chronological-forward) ;;
  rollback|ambiguous)
    emit version-blocked relation "$version_relation"
    set_failure version unsafe-version "이 설치 묶음은 현재 설치보다 오래됐거나 순서를 확인할 수 없습니다." "더 새로운 설치 USB를 사용해 주세요."
    emit_failure
    say "candidate bundle relation is '$version_relation'; refusing before release switch or stock install"
    exit 5
    ;;
  *) die "version helper returned an unknown relation: $version_relation" ;;
esac
emit version-relation bundle "$version_relation"

# Everything above this line precedes the first persistent/package mutation, including
# update-direction validation. The lock and scratch extraction under /run are ephemeral.
# Only a target, pinned bundle and GUI selection that agree may mutate persistent state.
set_failure bootstrap bootstrap-failed "기본 프로그램을 준비하지 못했습니다." "인터넷 연결을 확인한 뒤 다시 시도해 주세요."
export DEBIAN_FRONTEND=noninteractive
say "installing the small bootstrap needed by Airlock"
apt-get update -qq >/dev/null || die "apt-get update failed"
apt-get install -y -qq ca-certificates coreutils curl gnupg gzip python3 sudo systemd-container tar util-linux \
  >/dev/null || die "base bootstrap install failed"

release="/opt/airlock-gui/releases/$source_sha"
set_failure release bundle-install-failed "확인한 설치 파일을 이 기기에 놓지 못했습니다." "저장 공간을 확인한 뒤 다시 시도해 주세요."
if [ -e "$release" ]; then
  if [ ! -f "$release/gui-provisioner-manifest.json" ] \
    || [ ! -f "$release/docker/gui-default-profile.json" ] \
    || [ ! -f "$release/docker/gui-catalog.json" ] \
    || [ ! -f "$release/docker/gui_selection.py" ] \
    || [ ! -f "$release/install/airlock-install.sh" ]; then
    die "existing release is incomplete: $release"
  fi
  cmp -s "$release/gui-provisioner-manifest.json" "$manifest" \
    || die "existing release manifest differs from the pinned bundle"
  existing_profile_sha="$(sha256sum "$release/docker/gui-default-profile.json" 2>/dev/null | awk '{print $1}')"
  expected_profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
  [ "$existing_profile_sha" = "$expected_profile_sha" ] || die "existing release profile differs from the bundle"
  existing_catalog_sha="$(sha256sum "$release/docker/gui-catalog.json" 2>/dev/null | awk '{print $1}')"
  expected_catalog_sha="$(sha256sum "$catalog" | awk '{print $1}')"
  [ "$existing_catalog_sha" = "$expected_catalog_sha" ] || die "existing release catalog differs from the bundle"
else
  install -d -m 0755 /opt/airlock-gui/releases
  release_staging="$(mktemp -d "/opt/airlock-gui/releases/.${source_sha}.XXXXXX")" \
    || die "could not create same-filesystem release staging"
  cp -a "$payload/." "$release_staging/" || die "could not stage the pinned release"
  mv "$release_staging" "$release" || die "could not atomically publish the pinned release"
  release_staging=""
fi
ln -sfn "$release" /opt/airlock-gui/current
emit bundle-verified source_sha "$source_sha"

user=airlock
set_failure account account-setup-failed "Airlock 전용 사용자를 준비하지 못했습니다." "기기를 다시 시작한 뒤 다시 시도해 주세요."
if ! id -u "$user" >/dev/null 2>&1; then
  if getent passwd 1001 >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
  else
    useradd -m -u 1001 -s /bin/bash "$user"
  fi
fi
home="$(getent passwd "$user" | cut -d: -f6)"
uid="$(id -u "$user")"
usermod -aG sudo "$user"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "/etc/sudoers.d/90-$user"
chmod 0440 "/etc/sudoers.d/90-$user"
install -d -o "$user" -g "$user" -m 0755 "$home/code"
chown -R "$user:$user" "$release"

loginctl enable-linger "$user" || die "could not enable linger for $user"
systemctl start "user@${uid}.service" || die "could not start user manager for $user"
for _ in $(seq 1 30); do
  [ -S "/run/user/$uid/bus" ] && systemctl is-active --quiet "user@${uid}.service" && break
  sleep 1
done
[ -S "/run/user/$uid/bus" ] || die "user manager bus did not appear for $user"
systemctl is-active --quiet "user@${uid}.service" || die "user manager is not active for $user"
emit account-ready user "$user"

bootstrap_config="/run/airlock-gui-bootstrap.toml"
"$release/bin/airlock-config" init \
  --owner bootstrap@example.invalid \
  --site-name "$AIRLOCK_GUI_HOSTNAME" \
  --apps "$install_apps" > "$bootstrap_config" || die "could not generate bootstrap config"
chown "$user:$user" "$bootstrap_config"

say "executing the selected manifests' prerequisite fixes"
set_failure prerequisites prerequisite-failed "선택한 앱에 필요한 프로그램을 준비하지 못했습니다." "인터넷 연결을 확인한 뒤 다시 시도해 주세요." /var/log/airlock-gui-prerequisites.log
fixes="$(su - "$user" -c \
  "cd '$release' && AIRLOCK_CONFIG='$bootstrap_config' python3 bin/airlock-config prereqs" \
  | awk -F '\t' 'NF >= 5 && $5 != "" && $5 != "-" {print $5}' | sort -u)" \
  || die "could not resolve manifest prerequisites"
[ -n "$fixes" ] || die "selected manifests returned no prerequisite fixes"
while IFS= read -r fix; do
  [ -n "$fix" ] || continue
  say "prerequisite: $fix"
  bash -c "$fix" >>/var/log/airlock-gui-prerequisites.log 2>&1 \
    || die "prerequisite fix failed: $fix (see /var/log/airlock-gui-prerequisites.log)"
done <<EOF
$fixes
EOF

systemctl enable --now nginx >/dev/null || die "nginx did not enable and start"
systemctl enable --now tailscaled >/dev/null || die "tailscaled did not enable and start"
emit prerequisites-ready services "nginx,tailscaled"

set_failure tailnet tailscale-failed "Tailscale 연결을 준비하지 못했습니다." "Tailscale 상태를 확인한 뒤 다시 시도해 주세요."
ts_state="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState", ""))' 2>/dev/null || true)"
if [ "$ts_state" != Running ]; then
  auth_file="${AIRLOCK_GUI_AUTHKEY_FILE:-}"
  if [ -z "$auth_file" ]; then
    login_out="$(timeout 20 tailscale up --hostname="$AIRLOCK_GUI_HOSTNAME" --ssh --timeout=10s 2>&1 || true)"
    login_url="$(printf '%s\n' "$login_out" | grep -Eo 'https://[^[:space:]]+' | head -1 || true)"
    emit needs-auth login_url "$login_url"
    say "Tailscale needs interactive authorization; rerun with AIRLOCK_GUI_AUTHKEY_FILE"
    exit 3
  fi
  if [ ! -f "$auth_file" ] || [ -L "$auth_file" ]; then
    die "auth key input must be a regular non-symlink file"
  fi
  auth_mode="$(stat -c '%a' "$auth_file" 2>/dev/null || true)"
  case "$auth_mode" in 400|600) ;; *) die "auth key file mode is ${auth_mode:-unknown}; need 400 or 600" ;; esac
  auth_cleanup="$auth_file"
  ts_err=""
  ts_ok=0
  for attempt in 1 2 3 4 5; do
    if ts_err="$(tailscale up --auth-key="file:$auth_file" --hostname="$AIRLOCK_GUI_HOSTNAME" --ssh --timeout=20s 2>&1)"; then
      ts_ok=1
      break
    fi
    say "tailscale up attempt $attempt failed: ${ts_err:-(no diagnostic)}"
    sleep 3
  done
  rm -f "$auth_file"
  auth_cleanup=""
  unset AIRLOCK_GUI_AUTHKEY_FILE
  [ "$ts_ok" = 1 ] || die "tailscale up did not succeed: ${ts_err:-(no diagnostic)}"
elif [ -n "${AIRLOCK_GUI_AUTHKEY_FILE:-}" ]; then
  # A resumed/idempotent run may find the node already authenticated. The delivered
  # credential is still a one-run input and must not be left behind merely because it
  # was unnecessary this time.
  auth_file="$AIRLOCK_GUI_AUTHKEY_FILE"
  if [ ! -f "$auth_file" ] || [ -L "$auth_file" ]; then
    die "unused auth key input must still be a regular non-symlink file"
  fi
  auth_mode="$(stat -c '%a' "$auth_file" 2>/dev/null || true)"
  case "$auth_mode" in 400|600) ;; *) die "auth key file mode is ${auth_mode:-unknown}; need 400 or 600" ;; esac
  rm -f "$auth_file"
  unset AIRLOCK_GUI_AUTHKEY_FILE
fi

ts_info="$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
self = d.get("Self") or {}
fqdn = str(self.get("DNSName") or "").rstrip(".")
uid = str(self.get("UserID") or "")
u = (d.get("User") or {}).get(uid) or {}
print(fqdn)
print(u.get("LoginName") or "")
')" || die "could not read authenticated Tailscale identity"
fqdn="$(printf '%s\n' "$ts_info" | sed -n '1p')"
reported_owner="$(printf '%s\n' "$ts_info" | sed -n '2p')"
owner="${reported_owner:-${AIRLOCK_GUI_OWNER:-}}"
[ -n "$fqdn" ] || die "Tailscale is running but did not report a DNS name"
expected_tailnet="${AIRLOCK_GUI_EXPECTED_TAILNET:-}"
if [ -n "$expected_tailnet" ]; then
  case "$expected_tailnet" in
    *[!a-z0-9.-]*|.*|*..*|*.) die "AIRLOCK_GUI_EXPECTED_TAILNET is not a valid lowercase DNS suffix" ;;
  esac
  case "$expected_tailnet" in
    *.ts.net) ;;
    *) die "AIRLOCK_GUI_EXPECTED_TAILNET must end in .ts.net" ;;
  esac
  case "$fqdn" in
    *."$expected_tailnet") ;;
    *)
      actual_tailnet="${fqdn#*.}"
      emit wrong-tailnet expected "$expected_tailnet"
      set_failure tailnet wrong-tailnet "다른 Tailscale 네트워크에 로그인되어 있습니다." "현재 로그아웃한 뒤 안내받은 Tailscale 네트워크로 로그인해 주세요."
      emit_failure
      say "authenticated into '$actual_tailnet', but the installer client is in '$expected_tailnet'; refusing before stock install"
      exit 4
      ;;
  esac
fi
case "$owner" in *@*) ;; *) die "Tailscale did not report an owner login; set AIRLOCK_GUI_OWNER explicitly" ;; esac
emit tailnet-ready fqdn "$fqdn"

set_failure configuration config-generation-failed "선택한 앱 설정을 만들지 못했습니다." "앱 선택을 확인한 뒤 다시 시도해 주세요."
config="$home/airlock.toml"
"$release/bin/airlock-config" init \
  --owner "$owner" --site-name "$AIRLOCK_GUI_HOSTNAME" --apps "$install_apps" > "$config" \
  || die "could not generate final Airlock config"
chown "$user:$user" "$config"
actual_apps="$(AIRLOCK_CONFIG="$config" "$release/bin/airlock-config" apps | paste -sd, -)"
expected_apps="$(AIRLOCK_CONFIG="$bootstrap_config" "$release/bin/airlock-config" apps | paste -sd, -)"
[ "$actual_apps" = "$expected_apps" ] || die "generated config app set drifted: got $actual_apps, expected $expected_apps"

emit installer-start source_sha "$source_sha"
install_log=/var/log/airlock-gui-install.log
set_failure installer stock-installer-failed "Airlock 앱 설치를 끝내지 못했습니다." "다시 시도해 주세요. 계속 실패하면 자세히의 오류 코드와 설치 기록을 담당자에게 보여 주세요." "$install_log"
if ! su - "$user" -c \
  "cd '$release' && export AIRLOCK_CONFIG='$config' XDG_RUNTIME_DIR='/run/user/$uid' DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/$uid/bus'; bash install/airlock-install.sh" \
  >"$install_log" 2>&1; then
  tail -80 "$install_log" >&2
  die "stock installer failed (full log: $install_log)"
fi

install -d -m 0755 /var/lib/airlock-gui-provisioner
STATE_PATH=/var/lib/airlock-gui-provisioner/state.json \
SOURCE_SHA="$source_sha" SOURCE_EPOCH="$source_epoch" BUNDLE_SHA="$actual_bundle_sha" PROFILE_SHA="$(sha256sum "$release/docker/gui-default-profile.json" | awk '{print $1}')" \
FQDN="$fqdn" APPS="$actual_apps" python3 - <<'PY'
import json, os
doc = {
    "schema": "airlock.gui-provisioner-state/v1",
    "source_sha": os.environ["SOURCE_SHA"],
    "source_epoch": int(os.environ["SOURCE_EPOCH"]),
    "bundle_sha256": os.environ["BUNDLE_SHA"],
    "profile_sha256": os.environ["PROFILE_SHA"],
    "apps": os.environ["APPS"].split(","),
    "fqdn": os.environ["FQDN"],
}
path = os.environ["STATE_PATH"]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY

emit finished entrance "https://$fqdn/"
terminal_emitted=1
