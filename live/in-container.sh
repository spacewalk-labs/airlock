#!/usr/bin/env bash
# live/in-container.sh — everything that happens INSIDE the disposable container.
#
# Runs as root. Creates the unprivileged account, joins the tailnet, then runs the
# airlock install and smoke AS THAT ACCOUNT — never as root, because that is how a
# real box is installed and because a harness that installs as root would prove
# something nobody does.
#
# It writes one JSON document to stdout and everything else to stderr, so the
# caller can capture the record without parsing prose. That split is the contract:
# live/verify.sh reads stdout, a human reads stderr.
#
# Inputs, all through the environment (nothing on argv — a container's argv is
# readable from the host's process table):
#   LIVE_USER      account to create and install as
#   LIVE_OWNER     the airlock owner identity (an email; goes in airlock.toml)
#   LIVE_HOSTNAME  tailnet hostname to claim
#   LIVE_TAG       tailscale tag to advertise
#   LIVE_SHA       the commit this tree came from, recorded in the result
#   LIVE_SOAK      seconds to wait between the first and second unit reading
#   LIVE_DEVMON_MESSAGES
#                  true = start the message console with no Slack webhooks
#   /run/live-tskey  mode-600 file holding the tailscale auth key (deleted here)
set -uo pipefail

say() { printf '%s\n' "$*" >&2; }
die() { say "FATAL: $*"; exit 1; }

: "${LIVE_USER:?}" "${LIVE_OWNER:?}" "${LIVE_HOSTNAME:?}" "${LIVE_TAG:?}" "${LIVE_SHA:?}"
LIVE_SOAK="${LIVE_SOAK:-60}"
LIVE_DEVMON_MESSAGES="${LIVE_DEVMON_MESSAGES:-false}"
case "$LIVE_DEVMON_MESSAGES" in
  true|false) ;;
  *) die "LIVE_DEVMON_MESSAGES must be true or false" ;;
esac
SRC=/opt/airlock-src
[ -d "$SRC" ] || die "repo payload missing at $SRC"

# ---------------------------------------------------------------- 1. the box
say "== preparing the box =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || die "apt-get update failed"
# curl and ca-certificates are needed to fetch tailscale and node; the rest is
# what a bare noble image is missing before any airlock prerequisite is even
# consulted. Everything else must come from the app manifests — if this list
# starts growing, the manifests are lying about what they need.
apt-get install -y -qq curl ca-certificates gnupg sudo systemd-container >/dev/null 2>&1 \
  || die "apt-get install of the base tools failed"

id -u "$LIVE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$LIVE_USER"
usermod -aG sudo "$LIVE_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$LIVE_USER" > "/etc/sudoers.d/90-$LIVE_USER"
chmod 440 "/etc/sudoers.d/90-$LIVE_USER"
# `systemctl --user` needs a lingering session, and every airlock unit is a user
# unit. Without this the install "succeeds" and nothing runs.
loginctl enable-linger "$LIVE_USER" || die "could not enable linger for $LIVE_USER"

# ---------------------------------------------------------------- 2. tailnet
say "== joining the tailnet as $LIVE_HOSTNAME =="
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || die "tailscale install failed"
systemctl enable --now tailscaled >/dev/null 2>&1 || die "tailscaled did not start"
[ -f /run/live-tskey ] || die "no auth key at /run/live-tskey"
TSKEY="$(cat /run/live-tskey)"; rm -f /run/live-tskey
# Retry, with a timeout. A `tailscale up` called before tailscaled has finished
# its first initialisation falls back to the interactive login URL and hangs
# forever without --timeout; a few seconds later the same key works. Recorded in
# the fleet's provisioning notes after it ate a whole session once.
ts_ok=0
ts_err=""
for i in 1 2 3 4 5; do
  # 🔴 stderr 를 버리지 않는다. 예전엔 `>/dev/null 2>&1` 이라 다섯 번의 실패가 전부 같은
  #    "attempt N failed" 한 줄로만 남았고, 진짜 사유는 어디에도 없었다. 2026-08-18 에 이게
  #    30분을 먹었다 — 로그만 보면 네트워크·이미지·타이밍 중 무엇인지 구분이 안 돼, 결국
  #    Tailscale API 로 키를 직접 조회하고 나서야 **키가 single-use 이고 이미 소진·폐기됐다**는
  #    답이 나왔다. 침묵을 찾으라고 만든 시스템 안에 있던 침묵이다.
  #    stdout 만 버린다(정상 경로의 진행 표시는 소음이다).
  if ts_err="$(tailscale up --hostname="$LIVE_HOSTNAME" --authkey="$TSKEY" \
       --advertise-tags="$LIVE_TAG" --ssh --accept-routes --timeout=45s </dev/null 2>&1 >/dev/null)"; then
    ts_ok=1; break
  fi
  say "tailscale up attempt $i failed: ${ts_err:-(아무 말도 없이 실패)}"
  sleep 5
done
unset TSKEY
# 🔴 키 값은 절대 싣지 않는다 — 사유 문자열만 싣는다. `tailscale up` 은 실패 사유에 키를
#    되뱉지 않는다(확인함). 이 결과는 이슈에 공개될 수 있다.
[ "$ts_ok" = 1 ] || die "tailscale up never succeeded — 마지막 사유: ${ts_err:-(없음)}"
TS_FQDN="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
[ -n "$TS_FQDN" ] || die "joined the tailnet but could not read back the FQDN"
say "tailnet fqdn: $TS_FQDN"

# ---------------------------------------------------------------- 3. install
#
# Everything below runs through `su -`, not `runuser -l`, and the difference is not
# cosmetic. Measured in this exact image on 2026-08-07:
#
#   root         PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#   su - user    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:...
#   runuser -l   PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
#
# `runuser` skips the PAM session stack, so pam_env never reads /etc/environment
# and /usr/sbin never reaches PATH. Under it the preflight reported nginx and nft
# as MISSING on a box where both were installed — a false failure produced by the
# harness, about a PATH no real operator has. A harness that runs the install in an
# environment nobody else gets is measuring itself.
chown -R "$LIVE_USER:$LIVE_USER" "$SRC"
HOMEDIR="$(getent passwd "$LIVE_USER" | cut -d: -f6)"
# The nine entries below are shipped packages. Copy this example outside the
# checkout as an explicit package too: a run that installs only shipped packages
# cannot speak about explicit admission at all.
rm -rf "$HOMEDIR/hello-example"
cp -a "$SRC/examples/app-package" "$HOMEDIR/hello-example"
chown -R "$LIVE_USER:$LIVE_USER" "$HOMEDIR/hello-example"
cat > "$HOMEDIR/airlock.toml" <<TOML
[airlock]
config_version = 2

[site]
name = "Airlock live verification"

[auth]
provider = "tailscale"
owner = "$LIVE_OWNER"
collaborators = []

[paths]
wiki = ""

[apps.hub]
[apps.devterm]
[apps.fileview]
[apps.publish]
[apps.notepad]
[apps.dev-monitor]
messages = $LIVE_DEVMON_MESSAGES
[apps.code-server]
[apps.orca]
[apps.paseo]
[apps.feedback]
[apps.hello-example]

[packages.hello-example]
path = "$HOMEDIR/hello-example/package"
TOML
chown "$LIVE_USER:$LIVE_USER" "$HOMEDIR/airlock.toml"

# ------------------------------------------------------- 3a. prerequisites
# The installer reports missing prerequisites and refuses; it does not install
# them. On a real box a human reads the `exact fix` column and runs it. So that is
# what happens here — the manifests' own fix strings, executed verbatim.
#
# This is deliberate and it is the most valuable thing in this script. A fix string
# is documentation that nobody executes, which means it rots silently: until
# 2026-08-07 every node row in paseo and fileview said `snap install node
# --classic`, and the installer now refuses a snap node. Running them here means a
# wrong fix string turns this run red instead of turning up on somebody's fresh box
# six months later.
say "== prerequisites: running the manifests' own fix strings =="
FIXES="$(su - "$LIVE_USER" -c \
  "cd '$SRC' && AIRLOCK_CONFIG='$HOMEDIR/airlock.toml' python3 bin/airlock-config prereqs" 2>/dev/null \
  | awk -F '\t' 'NF >= 5 && $5 != "" && $5 != "-" {print $5}' | sort -u)"
[ -n "$FIXES" ] || die "no prerequisite fix strings — the manifests declare nothing to install"
fix_failed=""
while IFS= read -r fix; do
  [ -n "$fix" ] || continue
  say "-- fix: $fix"
  if ! bash -c "$fix" >>/tmp/prereq.log 2>&1; then
    say "   FAILED (see /tmp/prereq.log)"
    fix_failed="$fix_failed
$fix"
  fi
done <<EOF
$FIXES
EOF
[ -z "$fix_failed" ] || say "WARNING: some fix strings failed:$fix_failed"

say "== installing =="
install_rc=0
su - "$LIVE_USER" -c \
  "cd '$SRC' && AIRLOCK_CONFIG='$HOMEDIR/airlock.toml' bash install/airlock-install.sh" \
  >/tmp/install.log 2>&1 || install_rc=$?
say "install exited $install_rc (log: $(wc -l </tmp/install.log) lines)"
tail -40 /tmp/install.log >&2

say "== resolved package info =="
package_info_rc=0
su - "$LIVE_USER" -c \
  "cd '$SRC' && AIRLOCK_CONFIG='$HOMEDIR/airlock.toml' python3 bin/airlock-config package-info" \
  >/tmp/package-info.json 2>/tmp/package-info.err || package_info_rc=$?
say "package-info exited $package_info_rc (json: /tmp/package-info.json)"
cat /tmp/package-info.err >&2

# ---------------------------------------------------------------- 4. facts
# Read the units twice with a soak between. "Responds once, then crash-loops" is
# exactly what paseo did on 2026-08-07 — a single reading taken immediately after
# the install would have called that a pass.
#
# `systemctl show -p A -p B --value` does NOT return the values in the order the
# flags were given, so the first version of this labelled every column wrong and
# reported thirteen healthy units as `active=0`. Key=Value and parse by name: one
# call per unit, no positional assumption to get wrong.
unit_facts() {
  su - "$LIVE_USER" -c '
    systemctl --user list-units --type=service --all --no-legend --plain "airlock-*" \
      | awk "{print \$1}" | sort -u \
      | while read -r u; do
          [ -n "$u" ] || continue
          systemctl --user show "$u" \
            -p Id -p Type -p ActiveState -p SubState -p NRestarts -p ExecMainStatus \
            | paste -sd"|" -
        done' 2>/dev/null
}
say "== units, first reading =="
unit_facts > /tmp/facts-early; cat /tmp/facts-early >&2
say "== soaking ${LIVE_SOAK}s =="
SOAK_STARTED_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
sleep "$LIVE_SOAK"
SOAK_ENDED_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
SOAK_ELAPSED_MS=$(( (SOAK_ENDED_NS - SOAK_STARTED_NS) / 1000000 ))
say "== units, second reading =="
unit_facts > /tmp/facts-late; cat /tmp/facts-late >&2

say "== smoke =="
smoke_rc=0
su - "$LIVE_USER" -c \
  "cd '$SRC' && AIRLOCK_CONFIG='$HOMEDIR/airlock.toml' bash bin/airlock-smoke" \
  >/tmp/smoke.log 2>&1 || smoke_rc=$?
# 0 / 1 / 3 and NOT a boolean. 3 means every app gate passed but this box could
# not check its own serve frontend — see bin/airlock-smoke:9-19. A caller that
# tests `!= 0` records unverified ingress as verified.
say "smoke exited $smoke_rc"
cat /tmp/smoke.log >&2

# The ordinary smoke proves the HTTP ABI.  This separate collector proves the
# defect layer named by the phase-7 plan: after a real soak with messages enabled
# but both webhooks absent, the production database has no watchdog incident.  A
# known terminal delivery is then sent through the same DB and the same production
# entrypoint so a zero cannot be mistaken for a dead metric.
devmon_no_webhook_rc=0
if [ "$LIVE_DEVMON_MESSAGES" = true ]; then
  say "== dev-monitor messages-on/no-webhook watchdog gate =="
  su - "$LIVE_USER" -c \
    "python3 '$SRC/live/check-devmon-no-webhook.py' \
      '$HOMEDIR/.local/state/airlock/dev-monitor/messages.db' \
      '$SRC/apps/dev-monitor/backend' 'http://127.0.0.1:18804/api/health' \
      '$LIVE_SOAK' '$SOAK_ELAPSED_MS'" \
    >/tmp/devmon-no-webhook.json 2>/tmp/devmon-no-webhook.err || devmon_no_webhook_rc=$?
  cat /tmp/devmon-no-webhook.err >&2
else
  printf '%s\n' '{"skipped":true}' > /tmp/devmon-no-webhook.json
fi

# This stage changes the box: acceptance.sh sets AIRLOCK_CONFIG to a config
# containing only hub and hello-example, so reconciliation tears down the nine.
# It is last because their facts are already in this record. It also exports a
# fake AIRLOCK_TS_FQDN that is written into hub's __airlock.json and rendered
# into nginx, while removal invokes real `sudo tailscale serve ... off`. That is
# harmless when the container is deleted, but AIRLOCK_LIVE_KEEP=1 leaves a box
# naming a domain that does not exist.
acceptance_rc=0
ACCEPTANCE_COPY="$HOMEDIR/hello-example-acceptance"
say "== acceptance cycle (last; it reconciles the nine away) =="
su - "$LIVE_USER" -c \
  "AIRLOCK_CHECKOUT='$SRC' PKG_COPY='$ACCEPTANCE_COPY' bash '$SRC/examples/app-package/acceptance.sh'" \
  >/tmp/acceptance.log 2>&1 || acceptance_rc=$?
cat /tmp/acceptance.log >&2

# ---------------------------------------------------------------- 5. the record
printf '%s' "$FIXES" > /tmp/fixes.txt
touch /tmp/prereq.log
printf '%s' "$fix_failed" > /tmp/fixes-failed.txt
python3 - "$LIVE_SHA" "$TS_FQDN" "$install_rc" "$smoke_rc" "$LIVE_SOAK" "$acceptance_rc" "$package_info_rc" "$LIVE_DEVMON_MESSAGES" "$devmon_no_webhook_rc" <<'PY'
import json, re, sys, pathlib, subprocess

sha, fqdn, install_rc, smoke_rc, soak, acceptance_rc, package_info_rc, devmon_messages, devmon_no_webhook_rc = sys.argv[1:10]

def units(text):
    """Parse `Key=Value|Key=Value|...` lines by NAME, never by position."""
    want = {"Id": "id", "Type": "type", "ActiveState": "active",
            "SubState": "sub", "NRestarts": "restarts",
            "ExecMainStatus": "exec_status"}
    out = []
    for line in text.splitlines():
        rec = {}
        for field in line.split("|"):
            key, _, value = field.partition("=")
            if key in want:
                rec[want[key]] = value
        if rec.get("id"):
            out.append(rec)
    return out

def read(p):
    q = pathlib.Path(p)
    if not q.exists():
        return ""
    # One undecodable byte must not discard the whole record; preserving the rest
    # of a log is the point of this script, and losing it is the opposite.
    return q.read_text(encoding="utf-8", errors="replace")

early = units(read("/tmp/facts-early"))
late = units(read("/tmp/facts-late"))
smoke = read("/tmp/smoke.log")
install = read("/tmp/install.log")
acceptance_log = read("/tmp/acceptance.log")
package_info = {}
if package_info_rc == "0":
    try:
        package_info = json.loads(read("/tmp/package-info.json"))
    except (json.JSONDecodeError, TypeError):
        # Invalid package-info leaves external_packages empty, so the verdict fails
        # closed instead of treating an unreadable admission result as coverage.
        package_info = {}
packages = package_info.get("packages") if isinstance(package_info, dict) else {}
if not isinstance(packages, dict):
    packages = {}
external_packages = sorted(
    package_id for package_id, package in packages.items()
    if isinstance(package, dict) and package.get("source_class") == "explicit"
)
try:
    devmon_no_webhook = json.loads(read("/tmp/devmon-no-webhook.json"))
except (json.JSONDecodeError, TypeError):
    devmon_no_webhook = {"error": "collector did not produce valid JSON"}

# The smoke prints one line per app; keep them verbatim rather than a count, so a
# reader can see WHICH app and not just how many.
smoke_lines = [l for l in smoke.splitlines() if l.startswith("[") and " smoke]" in l]
external_gate_line_found = any(l.startswith("[hello-example smoke]") for l in smoke_lines)
acceptance_results = re.findall(
    r"^=+ RESULT:\s*(\d+) passed,\s*(\d+) failed\s*$", acceptance_log, re.M
)
acceptance_passed, acceptance_failed = (
    acceptance_results[-1] if acceptance_results else ("-1", "-1")
)

print(json.dumps({
    "commit": sha,
    "fqdn": fqdn,
    "install_rc": int(install_rc),
    "smoke_rc": int(smoke_rc),
    "soak_seconds": int(soak),
    "dev_monitor_messages_requested": devmon_messages == "true",
    "devmon_no_webhook": {
        "rc": int(devmon_no_webhook_rc),
        "observation": devmon_no_webhook,
    },
    "units_early": early,
    "units_late": late,
    "smoke_lines": smoke_lines,
    "external_packages": external_packages,
    "external_gate_line_found": external_gate_line_found,
    "acceptance": {
        "rc": int(acceptance_rc),
        "passed": int(acceptance_passed),
        "failed": int(acceptance_failed),
        "log_tail": acceptance_log.splitlines()[-60:],
    },
    "prereq_fixes_run": [l for l in read("/tmp/fixes.txt").splitlines() if l.strip()],
    "prereq_fixes_failed": [l for l in read("/tmp/fixes-failed.txt").splitlines() if l.strip()],
    "prereq_log_tail": read("/tmp/prereq.log").splitlines()[-40:],
    "install_log_tail": install.splitlines()[-60:],
    "smoke_log": smoke.splitlines(),
}, indent=2))
PY
