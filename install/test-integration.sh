#!/usr/bin/env bash
# Integration: run the REAL orchestrator (dry) to install all enabled separate-port
# apps, then render the full nginx site and validate with `nginx -t`. No live services.
set -uo pipefail
# Pin the RAM the paseo installer picks its memory tier from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: unpinned, a suite straddling
# the 16 GiB tier edge flips between 14G/12G and 5.5G/5G, and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AIRLOCK_STATE_DIR="$TMP/state"   # isolate the installed-state ledger from the dev box
pass=0 fail=0
ok(){ printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

cat >"$TMP/airlock.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
collaborators = ["friend@example.com"]
[paths]
# markwand refuses to be installed without this: it is the read+write file surface
# the collaborator above receives.
code_root = "/srv/code"
[apps.hub]
[apps.devterm]
[apps.code-server]
[apps.markwand]
[apps.publish]
[apps.notepad]
[apps.dev-monitor]
[apps.orca]
[apps.paseo]
TOML

# This whole suite is AIRLOCK_DRY_RUN=1: it never applies an nft ruleset, never starts a
# terminal, and never asks tailscaled to change anything. But three installers
# `require_cmd` those binaries, so on a machine without them the orchestrator died before
# writing a single fragment and the suite reported a pile of missing-fragment failures
# that had nothing to do with the code. That made it unrunnable on a CI runner (no nft,
# no tailscale and no tmux on any GitHub ubuntu image) and permanently red on a dev box,
# which is how twenty-odd real assertions ended up gating nothing.
#
# The shims satisfy the presence check. They are prepended ALWAYS, not only when the real
# binary is missing, so the suite behaves identically on a runner and on a developer's own
# box — otherwise a dev run would read that developer's live tailscale config while CI
# read nothing, and the two would be testing different things while both showing green.
#
# They fail on every invocation. One call does reach them: the orchestrator's
# `ts_stale_plaintext_ports` runs outside the dry-run guard and deliberately soft-fails
# (`tailscale serve status --json 2>/dev/null || return 0`), so it sees "no stale
# mappings" — the right answer for a test, and the reason this cannot be described as
# "nothing ever invokes them".
SHIM="$TMP/shim"; mkdir -p "$SHIM"
for c in nft nginx tailscale tmux ss sudo; do
  cat >"$SHIM/$c" <<STUB
#!/usr/bin/env bash
echo "$c: stubbed by install/test-integration.sh — this suite is a dry run (called with: \$*)" >&2
exit 1
STUB
  chmod +x "$SHIM/$c"
done
PATH="$SHIM:$PATH"; export PATH

export AIRLOCK_CONFIG="$TMP/airlock.toml"
export AIRLOCK_CONFD="$TMP/confd"
export AIRLOCK_WEBROOT="$TMP/web"
export AIRLOCK_DRY_RUN=1
# pin the FQDN: renders refuse to guess it (a short-hostname redirect has no cert)
export AIRLOCK_TS_FQDN="box.example.ts.net"

# real orchestrator (dry) — runs each enabled app installer, which writes its fragment
mkdir -p "$TMP/fullhome"
if HOME="$TMP/fullhome" bash "$ROOT/install/airlock-install.sh" >"$TMP/orch.log" 2>&1; then ok "orchestrator (dry) ran"; else bad "orchestrator (dry)"; sed 's/^/    /' "$TMP/orch.log"; fi

# Local publishing is validated before any dry-run mutation. These probes keep the
# paths under a world-traversable temporary root so each failure names the condition
# under test rather than mktemp's own 0700 directory.
chmod 755 "$TMP"
PUBLISH_PROBE_ROOT="$TMP/publish-probes"; mkdir -p "$PUBLISH_PROBE_ROOT"; chmod 755 "$PUBLISH_PROBE_ROOT"
PUBLISH_PROBE_HOME="$TMP/publish-home"; mkdir -p "$PUBLISH_PROBE_HOME"
chmod 755 "$PUBLISH_PROBE_HOME"
publish_probe() {
  local config="$1" confd="$2"
  HOME="$PUBLISH_PROBE_HOME" AIRLOCK_CONFIG="$config" AIRLOCK_CONFD="$confd" \
    AIRLOCK_WEBROOT="$confd/web" AIRLOCK_DRY_RUN=1 \
    bash "$ROOT/apps/publish/install.sh"
}

mkdir -p "$PUBLISH_PROBE_HOME/.local/state/airlock"
cat >"$PUBLISH_PROBE_HOME/.local/state/airlock/publish-public.json" <<'JSON'
{"version":1,"items":{"live-doc-abc":{"expiry":4102444800}}}
JSON
cat >"$TMP/publish-remote-transition.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share-transition"
[apps.publish.public_target]
mode = "remote"
ingest_url = "https://ingest.example"
base_url = "https://docs.example"
TOML
publish_transition_rc=0
publish_transition_out="$(publish_probe "$TMP/publish-remote-transition.toml" "$TMP/publish-remote-transition-confd" 2>&1)" || publish_transition_rc=$?
case "$publish_transition_rc:$publish_transition_out" in
  0:*) bad "publish: remote reinstall ignored active local state" ;;
  *"local mode"*"revoke"*"wait for expiry"*) ok "publish: remote reinstall is rejected while local publications are active" ;;
  *) bad "publish: transition rejection did not explain the recovery path"; printf '%s\n' "$publish_transition_out" | sed 's/^/    /' ;;
esac

printf '%s\n' '{not-json' >"$PUBLISH_PROBE_HOME/.local/state/airlock/publish-public.json"
publish_corrupt_rc=0
publish_corrupt_out="$(publish_probe "$TMP/publish-remote-transition.toml" "$TMP/publish-corrupt-state-confd" 2>&1)" || publish_corrupt_rc=$?
[ "$publish_corrupt_rc" = 0 ] \
  && ok "publish: corrupt local state does not block remote install" \
  || { bad "publish: corrupt local state was treated as an active publication"; printf '%s\n' "$publish_corrupt_out" | sed 's/^/    /'; }

cat >"$TMP/publish-local-uppercase.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share-uppercase"
[apps.publish.public_target]
mode = " LOCAL "
base_url = "https://docs.example"
public_dir = "$PUBLISH_PROBE_ROOT/public-uppercase"
gated_dir = "$PUBLISH_PROBE_ROOT/gated-uppercase"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth&prod"
TOML
publish_upper_rc=0
publish_upper_out="$(publish_probe "$TMP/publish-local-uppercase.toml" "$TMP/publish-local-uppercase-confd" 2>&1)" || publish_upper_rc=$?
UPPER_GATED="$TMP/publish-local-uppercase-confd/public-includes.d/publish-gated.conf"
if [ "$publish_upper_rc" = 0 ] && [ -f "$UPPER_GATED" ] \
  && grep -Fq "$PUBLISH_PROBE_ROOT/auth&prod/\$gslug.htpasswd" "$UPPER_GATED"; then
  ok "publish: mode normalization enables LOCAL and preserves ampersands in the gated fragment"
else
  bad "publish: mode normalization or sed replacement failed"; printf '%s\n' "$publish_upper_out" | sed 's/^/    /'
fi

cat >"$TMP/publish-state-overlap.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share-state"
[apps.publish.public_target]
mode = "local"
base_url = "https://docs.example"
public_dir = "$PUBLISH_PROBE_HOME/.local/state/airlock"
gated_dir = "$PUBLISH_PROBE_ROOT/gated-state"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth-state"
TOML
publish_state_rc=0
publish_state_out="$(publish_probe "$TMP/publish-state-overlap.toml" "$TMP/publish-state-overlap-confd" 2>&1)" || publish_state_rc=$?
case "$publish_state_rc:$publish_state_out" in
  0:*) bad "publish: public_dir overlapping STATE_DIR was accepted" ;;
  *"state_dir"*"owner identities"*) ok "publish: STATE_DIR overlap is rejected" ;;
  *) bad "publish: STATE_DIR overlap failed without the state-storage reason"; printf '%s\n' "$publish_state_out" | sed 's/^/    /' ;;
esac

# A real, non-dry local install under umask 077 checks the directory modes that
# dry-run logging cannot observe. The shims keep systemd and sudo in-process.
PUBLISH_REAL_HOME="$PUBLISH_PROBE_ROOT/real-home"; mkdir -p "$PUBLISH_REAL_HOME"; chmod 755 "$PUBLISH_REAL_HOME"
PUBLISH_REAL_SHIM="$TMP/publish-real-shim"; mkdir -p "$PUBLISH_REAL_SHIM"
cat >"$PUBLISH_REAL_SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$PUBLISH_REAL_SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) shift ;;
    -u) shift 2 ;;
    *) break ;;
  esac
done
exec "$@"
STUB
chmod +x "$PUBLISH_REAL_SHIM/systemctl" "$PUBLISH_REAL_SHIM/sudo"
mkdir -p "$PUBLISH_PROBE_ROOT/existing"; chmod 701 "$PUBLISH_PROBE_ROOT/existing"
cat >"$TMP/publish-umask.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share-umask"
[apps.publish.public_target]
mode = "local"
base_url = "https://docs.example"
public_dir = "$PUBLISH_PROBE_ROOT/existing/new/open"
gated_dir = "$PUBLISH_PROBE_ROOT/gated-umask/new"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth-umask/new"
TOML
publish_umask_rc=0
publish_umask_out="$(HOME="$PUBLISH_REAL_HOME" AIRLOCK_CONFIG="$TMP/publish-umask.toml" \
  AIRLOCK_CONFD="$TMP/publish-umask-confd" AIRLOCK_WEBROOT="$TMP/publish-umask-web" \
  AIRLOCK_DRY_RUN=0 PATH="$PUBLISH_REAL_SHIM:$PATH" \
  bash -c 'umask 077; exec bash "$1"' _ "$ROOT/apps/publish/install.sh" 2>&1)" || publish_umask_rc=$?
umask_middle_mode="$(stat -c '%a' "$PUBLISH_PROBE_ROOT/existing/new" 2>/dev/null || true)"
umask_existing_mode="$(stat -c '%a' "$PUBLISH_PROBE_ROOT/existing" 2>/dev/null || true)"
if [ "$publish_umask_rc" = 0 ] \
  && case "$umask_middle_mode" in *[1357]) true ;; *) false ;; esac \
  && [ "$umask_existing_mode" = 701 ]; then
  ok "publish: umask 077 leaves new intermediate traversal and existing modes intact"
else
  bad "publish: umask 077 produced an nginx-blocking intermediate or changed an existing directory"; printf '%s\n' "$publish_umask_out" | sed 's/^/    /'; printf '    modes: middle=%s existing=%s\n' "$umask_middle_mode" "$umask_existing_mode"
fi

PUBLISH_SMOKE_SHIM="$TMP/publish-smoke-shim"; mkdir -p "$PUBLISH_SMOKE_SHIM"
cat >"$PUBLISH_SMOKE_SHIM/curl" <<'STUB'
#!/usr/bin/env bash
body=yes owner=no nobody=no
for arg in "$@"; do
  case "$arg" in
    -o) body=no ;;
    *"me@example.com"*) owner=yes ;;
    *"nobody@example.com"*) nobody=yes ;;
  esac
done
if [ "$body" = no ]; then
  if [ "$nobody" = yes ] || { printf '%s\n' "$*" | grep -q '/publish/api/list' && [ "$owner" = no ]; }; then
    echo 403
  else
    echo 200
  fi
else
  echo '{"ok":true,"public_enabled":true}'
fi
STUB
cat >"$PUBLISH_SMOKE_SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) shift ;;
    -u) shift 2 ;;
    *) break ;;
  esac
done
exec "$@"
STUB
chmod +x "$PUBLISH_SMOKE_SHIM/curl" "$PUBLISH_SMOKE_SHIM/sudo"
mkdir -p "$PUBLISH_PROBE_ROOT/smoke-public" "$PUBLISH_PROBE_ROOT/smoke-gated" "$PUBLISH_PROBE_ROOT/smoke-auth"
chmod 755 "$PUBLISH_PROBE_ROOT/smoke-public" "$PUBLISH_PROBE_ROOT/smoke-gated" "$PUBLISH_PROBE_ROOT/smoke-auth"
cat >"$TMP/publish-smoke-local.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.hub]
nginx_port = 18080
[apps.publish]
backend_port = 18081
share_dir = "$PUBLISH_PROBE_ROOT/smoke-share"
[apps.publish.public_target]
mode = " LOCAL "
base_url = "https://docs.example"
public_dir = "$PUBLISH_PROBE_ROOT/smoke-public"
gated_dir = "$PUBLISH_PROBE_ROOT/smoke-gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/smoke-auth"
TOML
mkdir -p "$PUBLISH_PROBE_ROOT/smoke-share"
smoke_local_rc=0
smoke_local_out="$(HOME="$PUBLISH_PROBE_HOME" AIRLOCK_CONFIG="$TMP/publish-smoke-local.toml" \
  PATH="$PUBLISH_SMOKE_SHIM:$PATH" bash "$ROOT/apps/publish/smoke.sh" 2>&1)" || smoke_local_rc=$?
case "$smoke_local_rc:$smoke_local_out" in
  0:*"local-public=ok"*) ok "publish smoke: mode normalization checks LOCAL as local" ;;
  *) bad "publish smoke: LOCAL mode was treated as remote or smoke failed"; printf '%s\n' "$smoke_local_out" | sed 's/^/    /' ;;
esac

cat >"$TMP/publish-overlap.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
base_url = "https://docs.example"
public_dir = "$PUBLISH_PROBE_ROOT/public"
gated_dir = "$PUBLISH_PROBE_ROOT/public/gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth"
TOML
publish_overlap_rc=0
publish_overlap_out="$(publish_probe "$TMP/publish-overlap.toml" "$TMP/publish-overlap-confd" 2>&1)" || publish_overlap_rc=$?
case "$publish_overlap_rc:$publish_overlap_out" in
  0:*) bad "publish: gated_dir overlap was accepted in dry-run" ;;
  *"gated_dir"*"expose gated content without authentication"*) ok "publish: gated_dir overlap is rejected fail-closed" ;;
  *) bad "publish: gated_dir overlap failed without the exposure reason"; printf '%s\n' "$publish_overlap_out" | sed 's/^/    /' ;;
esac

cat >"$TMP/publish-auth-overlap.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
public_dir = "$PUBLISH_PROBE_ROOT/public:root"
gated_dir = "$PUBLISH_PROBE_ROOT/gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/public:root/auth"
TOML
publish_auth_rc=0
publish_auth_out="$(publish_probe "$TMP/publish-auth-overlap.toml" "$TMP/publish-auth-overlap-confd" 2>&1)" || publish_auth_rc=$?
case "$publish_auth_rc:$publish_auth_out" in
  0:*) bad "publish: htpasswd_dir overlap was accepted in dry-run" ;;
  *"htpasswd_dir"*"expose password hashes"*) ok "publish: htpasswd_dir overlap is rejected fail-closed" ;;
  *) bad "publish: htpasswd_dir overlap failed without the hash-exposure reason"; printf '%s\n' "$publish_auth_out" | sed 's/^/    /' ;;
esac

cat >"$TMP/publish-root-overlap.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
public_dir = "$PUBLISH_PROBE_ROOT/public"
gated_dir = "/"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth"
TOML
publish_root_rc=0
publish_root_out="$(publish_probe "$TMP/publish-root-overlap.toml" "$TMP/publish-root-overlap-confd" 2>&1)" || publish_root_rc=$?
case "$publish_root_rc:$publish_root_out" in
  0:*) bad "publish: root gated_dir overlap was accepted in dry-run" ;;
  *"gated_dir"*"internal share"*) ok "publish: root gated_dir overlap is rejected" ;;
  *) bad "publish: root gated_dir overlap failed without the exposure reason"; printf '%s\n' "$publish_root_out" | sed 's/^/    /' ;;
esac

cat >"$TMP/publish-missing-parent-overlap.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
public_dir = "$PUBLISH_PROBE_ROOT/public"
gated_dir = "$PUBLISH_PROBE_ROOT/missing/../public/gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth"
TOML
publish_missing_rc=0
publish_missing_out="$(publish_probe "$TMP/publish-missing-parent-overlap.toml" "$TMP/publish-missing-parent-overlap-confd" 2>&1)" || publish_missing_rc=$?
case "$publish_missing_rc:$publish_missing_out" in
  0:*) bad "publish: overlap through a missing parent was accepted" ;;
  *"gated_dir"*"without authentication"*) ok "publish: overlap through a missing parent is rejected" ;;
  *) bad "publish: missing-parent overlap failed without the exposure reason"; printf '%s\n' "$publish_missing_out" | sed 's/^/    /' ;;
esac

cat >"$TMP/publish-relative.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
public_dir = "$PUBLISH_PROBE_ROOT/public"
gated_dir = "relative/gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth"
TOML
publish_relative_rc=0
publish_relative_out="$(publish_probe "$TMP/publish-relative.toml" "$TMP/publish-relative-confd" 2>&1)" || publish_relative_rc=$?
case "$publish_relative_rc:$publish_relative_out" in
  0:*) bad "publish: relative gated_dir was accepted" ;;
  *"relative/gated"*"different working directories"*) ok "publish: relative gated_dir is rejected" ;;
  *) bad "publish: relative gated_dir failed without the path-resolution reason"; printf '%s\n' "$publish_relative_out" | sed 's/^/    /' ;;
esac

mkdir -p "$PUBLISH_PROBE_ROOT/private"; chmod 700 "$PUBLISH_PROBE_ROOT/private"
cat >"$TMP/publish-traverse.toml" <<TOML
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.publish]
share_dir = "$PUBLISH_PROBE_ROOT/share"
[apps.publish.public_target]
mode = "local"
public_dir = "$PUBLISH_PROBE_ROOT/public"
gated_dir = "$PUBLISH_PROBE_ROOT/private/gated"
htpasswd_dir = "$PUBLISH_PROBE_ROOT/auth"
TOML
publish_traverse_rc=0
publish_traverse_out="$(publish_probe "$TMP/publish-traverse.toml" "$TMP/publish-traverse-confd" 2>&1)" || publish_traverse_rc=$?
case "$publish_traverse_rc:$publish_traverse_out" in
  0:*) bad "publish: 0700 ancestor was accepted" ;;
  *"$PUBLISH_PROBE_ROOT/private"*)
    case "$publish_traverse_out" in
      *"0750 root:www-data"*) ok "publish: 0700 ancestor is rejected with its blocking path and group-mode alternative" ;;
      *) bad "publish: traversal rejection omitted the group-mode alternative"; printf '%s\n' "$publish_traverse_out" | sed 's/^/    /' ;;
    esac ;;
  *) bad "publish: 0700 ancestor failed without naming the blocker"; printf '%s\n' "$publish_traverse_out" | sed 's/^/    /' ;;
esac


# A dry run on a box that has NEVER been installed must work. It used to die with
# "install: cannot create directory '/etc/airlock': Permission denied", because the
# orchestrator's sudo mkdir is inside airlock_run while each app installer's
# `install -d "$CONFD/..."` is not — so the preview only worked after a real
# install. Reproduce the condition with unwritable, non-existent target paths
# (a path under a read-only dir stands in for /etc without needing root).
CLEAN="$TMP/clean"; mkdir -p "$CLEAN"
cat >"$CLEAN/airlock.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
[paths]
code_root = "/srv/code"
[apps.hub]
[apps.paseo]
TOML
RO="$TMP/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
clean_rc=0
clean_out="$(AIRLOCK_CONFIG="$CLEAN/airlock.toml" \
  AIRLOCK_WEBROOT="$RO/opt/airlock/hub" AIRLOCK_CONFD="$RO/etc/airlock/nginx" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)" || clean_rc=$?
# The oracle is the specific failure, not the exit code: this suite's exit code also
# carries unrelated environment gaps (an app whose dependency is missing), and
# conflating the two would report the wrong cause.
case "$clean_rc:$clean_out" in
  *"Permission denied"*|*"cannot create directory"*)
    bad "dry run still dies on an unwritable system path (clean-box preview broken)"
    printf '%s\n' "$clean_out" | grep -iE 'permission|cannot create' | sed 's/^/    /' ;;
  0:*) ok "dry run succeeds on a box that has never been installed" ;;
  *)   bad "dry run failed for some other reason"; printf '%s\n' "$clean_out" | tail -3 | sed 's/^/    /' ;;
esac
case "$clean_out" in
  *"previewing into"*) ok "dry run says where it previewed instead" ;;
  *) bad "dry run redirected silently, or not at all" ;;
esac
# ...and it must not have created anything under the real paths.
{ [ ! -e "$RO/etc" ] && [ ! -e "$RO/opt" ]; } \
  && ok "dry run wrote nothing under the real system paths" \
  || bad "dry run created files under the paths it was only supposed to preview"
chmod 700 "$RO"

# paseo's unit PATH must include the dirs the CLIs land in even before they exist:
# $NPM_GBIN is created by paseo's own npm install, and the agent CLIs are normally
# installed AFTER Airlock. Filtering on [ -d ] dropped both on a first install, so
# paseo came up with a UI and no working providers.
#
# HOME is overridden because the FIRST-install state is the whole point: on a box
# where ~/.npm-global/bin already exists the old filter passes too, so reusing the
# run above would assert nothing (measured — the [ -d ] control did not flip).
FH="$TMP/fakehome"; mkdir -p "$FH"
paseo_out="$(HOME="$FH" AIRLOCK_CONFIG="$CLEAN/airlock.toml" \
  AIRLOCK_CONFD="$FH/confd" AIRLOCK_WEBROOT="$FH/web" \
  bash "$ROOT/install/airlock-install.sh" 2>&1 || true)"
case "$paseo_out" in
  *"unit PATH=$FH/.npm-global/bin"*) ok "paseo unit PATH keeps the npm prefix that does not exist yet" ;;
  *"unit PATH="*) bad "paseo unit PATH dropped the not-yet-created npm prefix -> $(printf '%s' "$paseo_out" | grep -m1 -o 'unit PATH=.*')" ;;
  *) bad "paseo installer never reported its unit PATH"; printf '%s\n' "$paseo_out" | tail -3 | sed 's/^/    /' ;;
esac
[ -d "$FH/.npm-global/bin" ] && bad "fakehome probe was not a first-install state" || true

# The serve check must fail ONLY on deterministic local invariants, and must never be
# worded as if it proved reachability from another device — it cannot: a request to our
# own tailnet name is delivered over loopback. Both halves are asserted, because the
# wording is the part that four review rounds killed.
if command -v curl >/dev/null 2>&1; then
  GB="$TMP/servebin"; mkdir -p "$GB"
  cat >"$GB/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_URL_LOG:-}" ] && printf '%s\n' "${@: -1}" >>"$CURL_URL_LOG"
echo "${FAKE_HTTP_CODE:-200}"
STUB
  chmod +x "$GB/curl"
  sc() {  # $1 = status the frontend answers with -> "pass" | "fail"
    PATH="$GB:$PATH" AIRLOCK_DRY_RUN=0 FAKE_HTTP_CODE="$1" AIRLOCK_TS_FQDN=probe.example.ts.net \
      bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" >/dev/null 2>&1 && echo pass || echo fail
  }
  [ "$(sc 502)" = fail ] && ok "serve: 502 fails (mapping up, target down)" || bad "serve: 502 accepted as healthy"
  [ "$(sc 200)" = pass ] && ok "serve: a normal status passes"              || bad "serve: 200 wrongly rejected"
  [ "$(sc 403)" = pass ] && ok "serve: an identity 403 is not a serve fault" || bad "serve: 403 wrongly rejected"

  # A real transport failure (connection refused) must fail; an unresolvable own name
  # must SKIP, since MagicDNS being off says nothing about serve.
  refused_rc=0
  refused_out="$(AIRLOCK_DRY_RUN=0 AIRLOCK_TS_FQDN=127.0.0.1 AIRLOCK_HUB_HTTPS_PORT=9 \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" 2>&1)" || refused_rc=$?
  { [ "$refused_rc" -ne 0 ] && case "$refused_out" in *127.0.0.1:9*) true ;; *) false ;; esac; } \
    && ok "serve: a dead frontend fails, naming the URL it tried" \
    || { bad "serve: dead frontend not reported correctly"; printf '    %s\n' "$refused_out"; }
  dns_rc=0
  dns_out="$(AIRLOCK_DRY_RUN=0 AIRLOCK_TS_FQDN=airlock-probe.invalid \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" 2>&1)" || dns_rc=$?
  # rc 2, not 0: a skip must be distinguishable from a pass, or a caller narrates it as one.
  case "$dns_rc:$dns_out" in
    2:*cannot\ resolve*) ok "serve: an unresolvable own name is a named SKIP (rc 2)" ;;
    0:*) bad "serve: a skip is indistinguishable from a pass (rc 0)" ;;
    *) bad "serve: unresolvable own name mishandled (rc $dns_rc)"; printf '    %s\n' "$dns_out" ;;
  esac

  # Every skip path returns 2. The dry-run guard had NO coverage: deleting it left the
  # suite green, because the run then fell through to the DNS skip — one guard silently
  # absorbing the loss of another.
  dry_rc=0
  dry_out="$(AIRLOCK_DRY_RUN=1 bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" 2>&1)" || dry_rc=$?
  case "$dry_rc:$dry_out" in
    2:*AIRLOCK_DRY_RUN=1*) ok "serve: a dry run skips for the dry-run reason (rc 2)" ;;
    *) bad "serve: dry-run guard missing or mislabelled (rc $dry_rc)" ;;
  esac
  NOCURL="$TMP/nocurl"; mkdir -p "$NOCURL"
  for c in bash python3 sed grep cat dirname mktemp tailscale; do ln -sf "$(command -v $c)" "$NOCURL/$c" 2>/dev/null; done
  curl_rc=0
  curl_out="$(PATH="$NOCURL" AIRLOCK_DRY_RUN=0 AIRLOCK_TS_FQDN=probe.example.ts.net \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" 2>&1)" || curl_rc=$?
  case "$curl_rc:$curl_out" in
    2:*curl\ is\ not\ installed*) ok "serve: no curl is a named SKIP (rc 2)" ;;
    *) bad "serve: missing curl mishandled (rc $curl_rc)" ;;
  esac

  # `tailscale serve` answers 404 for an unmounted path and 500 for an unknown
  # destination WITHOUT reaching a backend — the exact fault this check is for. A
  # blacklist that only knew 502 called both healthy.
  [ "$(sc 404)" = fail ] && ok "serve: 404 fails (mapping no longer reaches the hub)" || bad "serve: 404 accepted as healthy"
  [ "$(sc 500)" = fail ] && ok "serve: 500 fails (serve has no destination)"          || bad "serve: 500 accepted as healthy"

  # The URL must follow [apps.hub].https_port, not a hardcoded 443.
  cat >"$TMP/hubport.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.hub]
https_port = 8443
TOML
  url_of() { : >"$TMP/urls.txt"
    PATH="$GB:$PATH" AIRLOCK_DRY_RUN=0 AIRLOCK_TS_FQDN=probe.example.ts.net \
      AIRLOCK_CONFIG="$1" CURL_URL_LOG="$TMP/urls.txt" \
      bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" >/dev/null 2>&1 || true
    tail -1 "$TMP/urls.txt"; }
  [ "$(url_of "$TMP/hubport.toml")" = "https://probe.example.ts.net:8443/" ] \
    && ok "serve: follows the configured hub https_port" || bad "serve: wrong URL for a non-443 hub"
  [ "$(url_of "$TMP/airlock.toml")" = "https://probe.example.ts.net/" ] \
    && ok "serve: default hub port needs no :443 suffix" || bad "serve: wrong URL for the default port"

  # 🔴 The claim itself. A passing serve check must NOT say the entrance is reachable,
  # and a run must close with an explicit unverified state naming the URL to open.
  pass_out="$(PATH="$GB:$PATH" AIRLOCK_DRY_RUN=0 FAKE_HTTP_CODE=200 AIRLOCK_TS_FQDN=probe.example.ts.net \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_serve_check" 2>&1)"
  case "$pass_out" in
    *reachab*|*"entrance answers"*|*"tailnet entrance"*)
      bad "serve: pass message claims reachability it cannot establish -> $pass_out" ;;
    *"serve frontend OK"*) ok "serve: pass message claims only the frontend" ;;
    *) bad "serve: unexpected pass wording -> $pass_out" ;;
  esac
  # 🔴 The DRIVER's summary line, not just the function's. An earlier revision said
  # "and the serve frontend answered" after the check had SKIPPED — invisible to every
  # assertion above, because nothing exercised bin/airlock-smoke. hub-only, because with
  # real apps enabled the run dies at the first app smoke and never reaches the summary.
  cat >"$TMP/hubonly.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
[apps.hub]
TOML
  sm_rc=0
  sm_out="$(AIRLOCK_CONFIG="$TMP/hubonly.toml" AIRLOCK_DRY_RUN=0 \
    AIRLOCK_TS_FQDN=airlock-probe.invalid bash "$ROOT/bin/airlock-smoke" 2>&1)" || sm_rc=$?
  case "$sm_out" in
    *"serve frontend answered"*) bad "airlock-smoke says the frontend answered after a skip" ;;
    *"NOT checked"*)             ok  "airlock-smoke reports a skipped serve check as not checked" ;;
    *) bad "airlock-smoke summary did not describe the serve outcome" ;;
  esac
  # The same fact in the channel a script can read. The prose above was already
  # right; the exit code was 0 either way, so coverage and the absence of coverage
  # were indistinguishable to every caller that is not a person reading a terminal.
  [ "$sm_rc" = 3 ] \
    && ok "airlock-smoke exits 3 (passed, ingress unchecked) rather than 0" \
    || bad "airlock-smoke exited $sm_rc after a skipped serve check (want 3)"

  unv_out="$(AIRLOCK_TS_FQDN=probe.example.ts.net \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_ingress_unverified" 2>&1)"
  case "$unv_out" in
    *"INGRESS UNVERIFIED"*probe.example.ts.net*) ok "run closes with INGRESS UNVERIFIED and the URL to open" ;;
    *) bad "no explicit unverified end state -> $unv_out" ;;
  esac
else echo "skip serve-check probes (no curl)"; fi

# The macOS setup script's architecture default used to be amd64 while every doc
# said arm64, so forgetting the variable landed you on the Rosetta path silently.
# Drive the real script with a stubbed `uname` — it announces the arch before it
# looks for `orb`, so this exercises the actual resolution on a Linux runner.
UB="$TMP/unamebin"; mkdir -p "$UB"
cat >"$UB/uname" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_UNAME_M:-unknown}"
STUB
# A failing `orb` stub is LOAD-BEARING, not decoration. Unstubbed on the Mac this
# script targets, the run would sail past `command -v orb` into `orb create` and a
# full provision — four times, with a lying `uname`. With the stub the run stops at
# `orb create` (exit 127 -> set -e), having passed only `command -v` and `orb list`,
# none of which change state. Same behaviour on a machine with OrbStack and one
# without, which is the point.
cat >"$UB/orb" <<'STUB'
#!/usr/bin/env bash
echo "orb: stubbed for install/test-integration.sh — no machine may be touched" >&2
exit 127
STUB
chmod +x "$UB/uname" "$UB/orb"
arch_line() {  # $1 = fake uname -m, $2 = AIRLOCK_ARCH ('' = unset)
  PATH="$UB:$PATH" FAKE_UNAME_M="$1" AIRLOCK_ARCH="${2:-}" \
    bash "$ROOT/docker/orbstack-machine-setup.sh" 2>&1 | grep -m1 -E 'architecture:|FATAL' || true
}
case "$(arch_line arm64)"  in *"architecture: arm64 (detected"*) ok "arch: Apple Silicon defaults to arm64" ;; *) bad "arch: arm64 host -> $(arch_line arm64)" ;; esac
case "$(arch_line x86_64)" in *"architecture: amd64 (detected"*) ok "arch: Intel Mac defaults to amd64" ;; *) bad "arch: x86_64 host -> $(arch_line x86_64)" ;; esac
case "$(arch_line arm64 amd64)" in *"architecture: amd64 (AIRLOCK_ARCH)"*) ok "arch: explicit AIRLOCK_ARCH still wins" ;; *) bad "arch: override ignored -> $(arch_line arm64 amd64)" ;; esac
# An unrecognised host must say so rather than silently pick one.
case "$(arch_line sparc64)" in *FATAL*) ok "arch: unknown host refuses to guess" ;; *) bad "arch: unknown host guessed -> $(arch_line sparc64)" ;; esac

# The linger warning must track STATE, not the exit code of an operation that is a
# no-op once the state holds. The stub reproduces the container case that made the
# old form cry wolf on every OrbStack install: enable-linger fails, yet Linger=yes.
LB="$TMP/lingbin"; mkdir -p "$LB"
cat >"$LB/loginctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show-user)     echo "Linger=${LINGER_STATE:-no}" ;;
  enable-linger) exit 1 ;;
esac
STUB
chmod +x "$LB/loginctl"
linger_out() {
  PATH="$LB:$PATH" AIRLOCK_DRY_RUN=0 LINGER_STATE="$1" \
    bash -c ". \"$ROOT/install/lib.sh\"; airlock_enable_linger someone" 2>&1 || true
}
case "$(linger_out yes)" in
  *WARN*) bad "linger: warns although lingering is already on" ;;
  *)      ok  "linger: no warning when lingering is already on" ;;
esac
case "$(linger_out no)" in
  *WARN*) ok  "linger: still warns when lingering really is off" ;;
  *)      bad "linger: silent when lingering is off (real warning lost)" ;;
esac

for a in devterm code-server orca paseo; do
  [ -f "$AIRLOCK_CONFD/servers.d/$a.conf" ] && ok "$a fragment written" || bad "$a fragment missing"
  grep -q 'if ($owner_ok = 0) { return 403; }' "$AIRLOCK_CONFD/servers.d/$a.conf" 2>/dev/null \
    && ok "$a owner-only guard" || bad "$a owner guard"
done

# D-DEVTERM-9900 retired the plaintext redirect. The fragment is HTTPS-only.
DTFRAG="$AIRLOCK_CONFD/servers.d/devterm.conf"
if grep -q 'listen 127.0.0.1:9913;' "$DTFRAG" 2>/dev/null; then
  bad "devterm redirect server should be gone"
else
  ok "devterm redirect server absent"
fi
if grep -q 'return 301 ' "$DTFRAG" 2>/dev/null; then
  bad "devterm fragment still emits a 301"
else
  ok "devterm fragment has no 301"
fi

# markwand is a same-origin subpath: fragment lands in hub-locations.d and is
# gated by the hub's single server-level chokepoint (asserted on $SITE below).
MWFRAG="$AIRLOCK_CONFD/hub-locations.d/markwand.conf"
[ -f "$MWFRAG" ] && ok "markwand fragment written" || bad "markwand fragment missing"
[ -f "$AIRLOCK_CONFD/hub-locations.d/publish.conf" ] && ok "publish fragment written" || bad "publish fragment missing"
[ ! -e "$AIRLOCK_CONFD/public-includes.d/publish-gated.conf" ] && ok "remote publish does not write gated fragment" || bad "remote publish wrote gated fragment"
[ -f "$AIRLOCK_CONFD/hub-locations.d/dev-monitor.conf" ] && ok "dev-monitor fragment written" || bad "dev-monitor fragment missing"

SITE="$(AIRLOCK_DRY_RUN=0 bash "$ROOT/install/render-nginx.sh")" || bad "render failed"

# The gate must be a single server-level chokepoint that covers all subpath apps.
printf '%s\n' "$SITE" | grep -q 'if ($hub_ok = 0) { return 403; }' \
  && ok "hub server-level identity gate present" || bad "hub server-level gate missing"

# The nginx shim exists only so preflight can run hermetically. Remove it before
# the syntax gate: CI must use its real nginx, while a local box without nginx
# keeps the established explicit skip.
rm -f "$SHIM/nginx"
if command -v nginx >/dev/null 2>&1; then
  {
    echo "pid \"$TMP/nginx.pid\";"; echo "error_log \"$TMP/error.log\";"
    echo "events {}"; echo "http {"; echo "  access_log off;"
    echo "  client_body_temp_path \"$TMP/a\"; proxy_temp_path \"$TMP/b\";"
    echo "  fastcgi_temp_path \"$TMP/c\"; uwsgi_temp_path \"$TMP/d\"; scgi_temp_path \"$TMP/e\";"
    echo "$SITE"; echo "}"
  } >"$TMP/nginx.conf"
  if nginx -t -c "$TMP/nginx.conf" -p "$TMP" >/dev/null 2>&1; then
    ok "nginx -t: hub + devterm + code-server + markwand + publish + dev-monitor all valid"
  else
    bad "nginx -t invalid"; nginx -t -c "$TMP/nginx.conf" -p "$TMP" 2>&1 | sed 's/^/    /'
  fi
else echo "skip nginx -t"; fi

echo "---"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
