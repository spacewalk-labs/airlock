#!/usr/bin/env bash
# Full clean-guest acceptance for the GUI-default Airlock provisioner.
#
# This driver NEVER creates, deletes or configures an LXD instance. The fixture is an
# input made outside this script. It only inspects, delivers to, executes in and restarts
# that exact named instance. The public script carries no site hostname or owner.
#
#   AIRLOCK_E2E_TARGET=ssh-destination:instance-name \
#   AIRLOCK_TS_AUTHKEY_FILE=/mode-0600/input \
#   bash docker/test-gui-provisioner-e2e.sh
#
# Alternatively set AIRLOCK_E2E_TARGET to the instance name and AIRLOCK_E2E_SSH to the
# SSH destination. AIRLOCK_E2E_BUNDLE may name a prebuilt bundle; otherwise committed
# HEAD is built. AIRLOCK_E2E_RESULT may select the evidence JSON path.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

say() { printf '[gui-e2e] %s\n' "$*" >&2; }
die() { say "FATAL: $*"; exit 1; }

: "${AIRLOCK_E2E_TARGET:?set AIRLOCK_E2E_TARGET to ssh-destination:instance-name}"
: "${AIRLOCK_TS_AUTHKEY_FILE:?set AIRLOCK_TS_AUTHKEY_FILE to a mode-0600 auth-key file}"

case "$AIRLOCK_E2E_TARGET" in
  *:*)
    e2e_ssh="${AIRLOCK_E2E_TARGET%%:*}"
    instance="${AIRLOCK_E2E_TARGET#*:}"
    ;;
  *)
    e2e_ssh="${AIRLOCK_E2E_SSH:-}"
    instance="$AIRLOCK_E2E_TARGET"
    ;;
esac
[ -n "$e2e_ssh" ] || die "target has no SSH destination; use ssh-destination:instance or AIRLOCK_E2E_SSH"
case "$e2e_ssh" in *[!A-Za-z0-9_.@-]*|'') die "SSH destination contains unsafe characters" ;; esac
case "$instance" in *[!a-z0-9-]*|'') die "instance name must use lowercase letters, digits and hyphens" ;; esac

command -v tailscale >/dev/null 2>&1 || die "the external E2E client needs tailscale to identify its expected tailnet"
client_fqdn="$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
print(str((json.load(sys.stdin).get("Self") or {}).get("DNSName") or "").rstrip("."))
')" || die "could not read the external E2E client's Tailscale identity"
expected_tailnet="${client_fqdn#*.}"
case "$client_fqdn:$expected_tailnet" in
  *.*:*.ts.net) ;;
  *) die "external E2E client did not report a usable *.ts.net DNS name" ;;
esac

if [ ! -f "$AIRLOCK_TS_AUTHKEY_FILE" ] || [ -L "$AIRLOCK_TS_AUTHKEY_FILE" ]; then
  die "auth-key input must be a regular non-symlink file"
fi
key_mode="$(stat -c '%a' "$AIRLOCK_TS_AUTHKEY_FILE" 2>/dev/null || true)"
case "$key_mode" in 400|600) ;; *) die "auth-key input mode is ${key_mode:-unknown}; need 400 or 600" ;; esac

scratch="$(mktemp -d)" || die "could not create local scratch directory"
key_delivered=0
cleanup() {
  if [ "$key_delivered" = 1 ]; then
    ssh -o BatchMode=yes "$e2e_ssh" lxc exec "$instance" -- \
      rm -f /run/airlock-gui-authkey >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

ssh_lxc() { ssh -o BatchMode=yes "$e2e_ssh" lxc "$@"; }
guest() { ssh -o BatchMode=yes "$e2e_ssh" lxc exec "$instance" -- "$@"; }

say "confirming the exact pre-created fixture before changing it"
list_json="$(ssh_lxc list "$instance" --format=json)" || die "could not query the LXD fixture"
instance_meta="$(LIST_JSON="$list_json" INSTANCE="$instance" python3 - <<'PY'
import json, os
rows = json.loads(os.environ["LIST_JSON"])
rows = [r for r in rows if r.get("name") == os.environ["INSTANCE"]]
if len(rows) != 1:
    raise SystemExit(f"wanted exactly one exact instance; found {len(rows)}")
r = rows[0]
if r.get("status") != "Running":
    raise SystemExit(f"instance is {r.get('status')}, not Running")
print((r.get("config") or {}).get("volatile.base_image", "unknown"))
PY
)" || die "fixture identity/status check failed: $instance_meta"
image_fingerprint="$instance_meta"

# This is deliberately before bundle/key delivery. A refusal here leaves the fixture
# untouched and prevents a prepared box from being relabelled as a clean witness.
baseline="$(guest bash -s <<'GUEST'
set -uo pipefail
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] || {
  echo "bad-platform:$ID:$VERSION_ID" >&2; exit 10;
}
[ "$(uname -m)" = x86_64 ] || { echo "bad-arch:$(uname -m)" >&2; exit 11; }
for command_name in git node nodejs nginx tailscale tailscaled; do
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "command-present:$command_name" >&2; exit 12
  fi
done
for package_name in git nodejs nginx tailscale; do
  if dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null | grep -qx installed; then
    echo "package-present:$package_name" >&2; exit 13
  fi
done
getent passwd airlock >/dev/null 2>&1 && { echo "user-present:airlock" >&2; exit 14; }
for path in /opt/airlock /opt/airlock-gui /etc/airlock /home/airlock /var/lib/airlock-gui-provisioner; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || { echo "path-present:$path" >&2; exit 15; }
done
printf 'ubuntu=%s\narch=%s\nboot_id=%s\n' "$VERSION_ID" "$(uname -m)" "$(cat /proc/sys/kernel/random/boot_id)"
GUEST
)" || die "fixture is not pristine; no payload was delivered"
ubuntu_version="$(printf '%s\n' "$baseline" | sed -n 's/^ubuntu=//p')"
architecture="$(printf '%s\n' "$baseline" | sed -n 's/^arch=//p')"
boot_before="$(printf '%s\n' "$baseline" | sed -n 's/^boot_id=//p')"
[ -n "$boot_before" ] || die "pristine probe did not return a boot ID"
say "pristine assertion passed: Ubuntu $ubuntu_version $architecture"
if [ "${AIRLOCK_E2E_PREFLIGHT_ONLY:-0}" = 1 ]; then
  say "PREFLIGHT PASS: exact fixture is pristine; no payload or auth input was delivered"
  exit 0
fi

bundle="${AIRLOCK_E2E_BUNDLE:-}"
if [ -z "$bundle" ]; then
  bundle="$scratch/airlock-gui-provisioner.tgz"
  bash "$HERE/build-gui-provisioner-bundle.sh" --output "$bundle" --revision HEAD \
    >"$scratch/build.out" || die "could not build committed HEAD bundle"
fi
if [ ! -f "$bundle" ] || [ -L "$bundle" ]; then
  die "bundle input must be a regular non-symlink file"
fi
bundle_sha="$(sha256sum "$bundle" | awk '{print $1}')"
manifest_json="$(tar -xOzf "$bundle" airlock/gui-provisioner-manifest.json)" \
  || die "bundle has no readable manifest"
source_sha="$(MANIFEST_JSON="$manifest_json" python3 - <<'PY'
import json, os, re
d = json.loads(os.environ["MANIFEST_JSON"])
sha = d.get("source_sha", "")
if d.get("schema") != "airlock.gui-provisioner-bundle/v1" or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
    raise SystemExit("bad manifest")
print(sha)
PY
)" || die "bundle manifest does not bind a valid source revision"
head_sha="$(git -C "$ROOT" rev-parse HEAD)"
[ -n "${AIRLOCK_E2E_BUNDLE:-}" ] || [ "$source_sha" = "$head_sha" ] \
  || die "freshly built bundle source $source_sha is not HEAD $head_sha"

runner="$scratch/gui-provisioner.sh"
tar -xOzf "$bundle" airlock/docker/gui-provisioner.sh > "$runner" \
  || die "bundle does not contain its guest provisioner"
chmod 0700 "$runner"
bash -n "$runner" || die "bundled guest provisioner has invalid shell syntax"

say "delivering the exact bundle and protected auth input"
guest install -m 0600 /dev/null /run/airlock-gui-provisioner.tgz \
  || die "could not create protected bundle target"
guest tee /run/airlock-gui-provisioner.tgz < "$bundle" >/dev/null \
  || die "could not deliver bundle"
guest install -m 0700 /dev/null /run/gui-provisioner.sh \
  || die "could not create protected provisioner target"
guest tee /run/gui-provisioner.sh < "$runner" >/dev/null \
  || die "could not deliver guest provisioner"
guest install -m 0600 /dev/null /run/airlock-gui-authkey \
  || die "could not create protected auth-input target"
key_delivered=1
guest tee /run/airlock-gui-authkey < "$AIRLOCK_TS_AUTHKEY_FILE" >/dev/null \
  || die "could not deliver auth input"

say "invoking the provisioner exactly once"
provision_stdout="$scratch/provision.ndjson"
provision_stderr="$scratch/provision.log"
provision_invocations=1
if ! guest env \
  AIRLOCK_GUI_BUNDLE=/run/airlock-gui-provisioner.tgz \
  AIRLOCK_GUI_BUNDLE_SHA256="$bundle_sha" \
  AIRLOCK_GUI_HOSTNAME="$instance" \
  AIRLOCK_GUI_EXPECTED_TAILNET="$expected_tailnet" \
  AIRLOCK_GUI_AUTHKEY_FILE=/run/airlock-gui-authkey \
  bash /run/gui-provisioner.sh \
  >"$provision_stdout" 2> >(tee "$provision_stderr" >&2); then
  die "the one provisioner invocation failed"
fi
guest test ! -e /run/airlock-gui-authkey || die "guest did not consume the auth input"
key_delivered=0

url="$(python3 - "$provision_stdout" <<'PY'
import json, pathlib, sys
events = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    try: events.append(json.loads(line))
    except json.JSONDecodeError: raise SystemExit("non-JSON progress output")
finished = [e for e in events if e.get("event") == "finished"]
if len(finished) != 1 or finished[0].get("detail") != "entrance":
    raise SystemExit("missing unique finished entrance event")
print(finished[0].get("value", ""))
PY
)" || die "provisioner did not emit one valid finished event"
case "$url" in https://*.ts.net/) ;; *) die "finished URL is not an https ts.net entrance" ;; esac

probe_url() {
  local label="$1" attempt out code tls
  for attempt in $(seq 1 60); do
    out="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}|%{ssl_verify_result}' "$url" 2>/dev/null || true)"
    code="${out%%|*}"; tls="${out#*|}"
    if [ "$code" = 200 ] && [ "$tls" = 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    [ "$attempt" = 60 ] || sleep 3
  done
  say "$label external probe last observed: ${out:-no response}"
  return 1
}

say "probing the entrance from outside the container"
probe_before="$(probe_url before-restart)" || die "outside HTTPS did not reach 200 with certificate verification"

say "restarting only the exact named fixture"
ssh_lxc restart "$instance" --timeout 120 >/dev/null || die "exact fixture restart failed"
boot_after=""
for _ in $(seq 1 60); do
  boot_after="$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  system_state="$(guest systemctl is-system-running 2>/dev/null || true)"
  if [ -n "$boot_after" ] && [ "$boot_after" != "$boot_before" ] \
    && { [ "$system_state" = running ] || [ "$system_state" = degraded ]; }; then
      break
  fi
  sleep 3
done
if [ -z "$boot_after" ] || [ "$boot_after" = "$boot_before" ]; then
  die "restart did not produce a new boot ID"
fi
case "$system_state" in
  running|degraded) ;;
  *) die "system did not settle after restart (last state: ${system_state:-unknown})" ;;
esac

say "checking reboot persistence before the second external probe"
unit_facts="$(guest bash -s <<'GUEST'
set -euo pipefail
user=airlock
uid="$(id -u "$user")"
[ "$(loginctl show-user -p Linger --value "$user")" = yes ]
systemctl is-enabled --quiet nginx tailscaled
systemctl is-active --quiet nginx tailscaled "user@${uid}.service"
command -v git >/dev/null
dpkg-query -W -f='${db:Status-Status}' git 2>/dev/null | grep -qx installed
printf 'linger|yes|n/a\n'
printf 'nginx|enabled|active\n'
printf 'tailscaled|enabled|active\n'
printf 'user@%s.service|n/a|active\n' "$uid"
export XDG_RUNTIME_DIR="/run/user/$uid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
for unit in \
  airlock-devterm.service \
  airlock-devterm-gate.service \
  airlock-fileview.service \
  airlock-publish.service \
  airlock-paseo.service \
  airlock-paseo-uistate.service; do
  su - "$user" -c "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' systemctl --user is-enabled --quiet '$unit'"
  su - "$user" -c "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' systemctl --user is-active --quiet '$unit'"
  printf '%s|enabled|active\n' "$unit"
done
su - "$user" -c "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' systemctl --user is-enabled --quiet airlock-publish-cleanup.timer"
su - "$user" -c "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' systemctl --user is-active --quiet airlock-publish-cleanup.timer"
printf 'airlock-publish-cleanup.timer|enabled|active\n'
GUEST
)" || die "required services did not recover after restart"

probe_after="$(probe_url after-restart)" || die "outside HTTPS did not recover to verified 200 after restart"

say "running the default-four app smoke after restart"
smoke_log="$scratch/smoke.log"
smoke_rc=0
guest bash -s >"$smoke_log" 2>&1 <<'GUEST' || smoke_rc=$?
set -uo pipefail
user=airlock
uid="$(id -u "$user")"
home="$(getent passwd "$user" | cut -d: -f6)"
release="$(readlink -f /opt/airlock-gui/current)"
su - "$user" -c "cd '$release' && export AIRLOCK_CONFIG='$home/airlock.toml' XDG_RUNTIME_DIR='/run/user/$uid' DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/$uid/bus'; bash bin/airlock-smoke"
GUEST
case "$smoke_rc" in 0|3) ;; *) tail -80 "$smoke_log" >&2; die "post-restart app smoke failed with rc=$smoke_rc" ;; esac
for app in devterm fileview publish paseo; do
  grep -qi "$app" "$smoke_log" || die "post-restart smoke log has no evidence for $app"
done

result="${AIRLOCK_E2E_RESULT:-$ROOT/.airlock/evidence/gui-provisioner-e2e-$(date -u +%Y%m%dT%H%M%SZ).json}"
mkdir -p "$(dirname "$result")"
RESULT="$result" TARGET="$AIRLOCK_E2E_TARGET" INSTANCE="$instance" SOURCE_SHA="$source_sha" \
BUNDLE_SHA="$bundle_sha" IMAGE_FINGERPRINT="$image_fingerprint" UBUNTU_VERSION="$ubuntu_version" \
ARCHITECTURE="$architecture" BOOT_BEFORE="$boot_before" BOOT_AFTER="$boot_after" \
PROBE_BEFORE="$probe_before" PROBE_AFTER="$probe_after" URL="$url" SMOKE_RC="$smoke_rc" \
PROVISION_INVOCATIONS="$provision_invocations" \
UNIT_FACTS="$unit_facts" \
python3 - <<'PY'
import json, os, pathlib
def probe(value):
    code, tls = value.split("|", 1)
    return {"http_code": int(code), "ssl_verify_result": int(tls)}
doc = {
    "schema": "airlock.gui-provisioner-e2e/v1",
    "target_coordinate": os.environ["TARGET"],
    "instance": os.environ["INSTANCE"],
    "source_sha": os.environ["SOURCE_SHA"],
    "bundle_sha256": os.environ["BUNDLE_SHA"],
    "image_fingerprint": os.environ["IMAGE_FINGERPRINT"],
    "pristine": {
        "asserted_before_delivery": True,
        "ubuntu": os.environ["UBUNTU_VERSION"],
        "architecture": os.environ["ARCHITECTURE"],
        "commands_absent": ["git", "node", "nodejs", "nginx", "tailscale", "tailscaled"],
        "user_absent": "airlock",
    },
    "provisioner_invocations": int(os.environ["PROVISION_INVOCATIONS"]),
    "entrance_url": os.environ["URL"],
    "boot_id_before": os.environ["BOOT_BEFORE"],
    "boot_id_after": os.environ["BOOT_AFTER"],
    "external_probe_before_restart": probe(os.environ["PROBE_BEFORE"]),
    "external_probe_after_restart": probe(os.environ["PROBE_AFTER"]),
    "post_restart_smoke_rc": int(os.environ["SMOKE_RC"]),
    "git_installed": True,
    "required_units_enabled_and_active": True,
    "post_restart_unit_facts": {
        name: {"enabled": enabled, "active": active}
        for name, enabled, active in (
            line.split("|", 2) for line in os.environ["UNIT_FACTS"].splitlines()
        )
    },
    "auth_key_value_recorded": False,
}
path = pathlib.Path(os.environ["RESULT"])
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
tmp.replace(path)
PY

say "PASS: pristine -> one provision -> verified HTTPS 200 -> restart -> verified HTTPS 200"
printf '%s\n' "$result"
