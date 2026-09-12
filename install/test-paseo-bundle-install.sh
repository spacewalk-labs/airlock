#!/usr/bin/env bash
# install/test-paseo-bundle-install.sh — the real paseo installer against the real
# guarded bundle, in a scratch HOME.
#
# Why this exists: install/test-paseo-bundle.sh proves the tarballs are what they say,
# and install/test-paseo-patch-drift.sh proves each patcher against a hand-built
# fixture. Neither ever ran apps/paseo/install.sh against the tree that `npm i -g` of
# six sibling tarballs actually produces — and that tree puts @getpaseo/server at the
# prefix level, not nested under the cli where every patch path used to look. On
# 2026-09-12 the first real install of the bundle died on that lookup and rolled the
# whole platform back. This suite is the missing layer: the installer's own npm
# command, the installer's own patch steps, measured on the layout they will meet.
#
# Needs npm to reach a registry for the bundle's third-party dependencies (the six
# tarballs are local; their ~280 dependencies are not vendored). Everything systemd,
# tailscale or sudo would do is shimmed and logged; nothing outside $TMP is touched.
set -uo pipefail
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUNDLE="$ROOT/apps/paseo/vendor/guarded-0.2.5"
pass=0; fail=0
ok()  { echo "ok   paseo-bundle-install: $1"; pass=$((pass+1)); }
bad() { echo "FAIL paseo-bundle-install: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; SHIM="$TMP/shim"; EVENTS="$TMP/systemctl.log"
mkdir -p "$HOME_DIR" "$SHIM" "$TMP/confd" "$TMP/web/assets"
: >"$EVENTS"

cat >"$TMP/airlock.toml" <<'EOF'
[site]
name = "BundleInstall"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.paseo]
EOF

# --- shims: record what the installer asks of the box, answer "nothing running" ---
cat >"$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'systemctl %s\n' "$*" >>"${AIRLOCK_TEST_EVENT_LOG:?}"
[ "${1:-}" = --user ] && shift
case "${1:-}" in
  show)
    case " $* " in
      *" --property=ActiveState "*) echo inactive ;;
      *" --property=MainPID "*) echo 0 ;;
      *) echo "" ;;
    esac
    ;;
  is-active) exit 3 ;;
  whoami) exit 1 ;;
  *) exit 0 ;;
esac
STUB
cat >"$SHIM/tailscale" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *status*) echo '{"Self":{"DNSName":"box.example.ts.net."}}' ;;
  *) exit 0 ;;
esac
STUB
# The installer waits up to 60s for the backend to bind; a shim that already
# reports it listening keeps the suite fast. The port is whatever the config
# resolves for this app — read it the way the installer does.
BACKEND_PORT="$(AIRLOCK_CONFIG="$TMP/airlock.toml" python3 "$ROOT/bin/airlock-config" env paseo \
  | sed -n 's/^AIRLOCK_PASEO_BACKEND_PORT=//p')"
cat >"$SHIM/ss" <<STUB
#!/usr/bin/env bash
echo "LISTEN 0 4096 127.0.0.1:${BACKEND_PORT:?} 0.0.0.0:*"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHIM/sudo"
chmod +x "$SHIM"/*

NPM_ROOT="$HOME_DIR/.npm-global/lib/node_modules"
TOP="$NPM_ROOT/@getpaseo/server"
NESTED="$NPM_ROOT/@getpaseo/cli/node_modules/@getpaseo/server"

run_install() {   # run_install <log-file>  ; returns the installer's rc
  local out="$1" rc=0
  env HOME="$HOME_DIR" PATH="$SHIM:$PATH" \
      AIRLOCK_CONFIG="$TMP/airlock.toml" AIRLOCK_CONFD="$TMP/confd" AIRLOCK_WEBROOT="$TMP/web" \
      AIRLOCK_DRY_RUN=0 AIRLOCK_TEST_EVENT_LOG="$EVENTS" \
      AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/paseo" AIRLOCK_APP_ID=paseo \
      bash "$ROOT/apps/paseo/install.sh" >"$out" 2>&1 || rc=$?
  return "$rc"
}

# ---- 1. a fresh install lands the bundle at the prefix level and every patch finds it ----
out="$TMP/install-1.log"
if run_install "$out"; then
  ok "fresh install exits 0"
else
  bad "fresh install failed rc=$? — $(grep -m1 'FATAL' "$out" || tail -1 "$out")"
  sed 's/^/    /' "$out" | tail -20
fi
grep -q 'install paseo bundle:' "$out" && ok "the bundle path was taken (not the registry)" \
  || bad "the log does not show a bundle install"
[ -f "$TOP/dist/server/server/session.js" ] && ok "server is a prefix-level sibling of the cli" \
  || bad "no server at $TOP"
[ ! -e "$NESTED" ] && ok "nothing is nested under the cli" \
  || bad "a server copy is nested under the cli: $NESTED"
# Every patch step must have found its target. The bundle already carries the server
# half of each patch, so "already applied" is the expected answer; the web half is
# applied here and must be verified against the served bundle.
for want in \
  'depth4 search patch already applied' \
  'provider-subagent server filter already applied' \
  'provider-subagent selective delivery pair verified' \
  'model prune already applied' \
  'pasted-image persistence already applied' \
  'orphan guard already applied (claude)' \
  'orphan guard already applied (codex)' \
  'orphan guard behaviour check passed' \
  'process-group sweep already applied (claude-agent)' \
  'process-group sweep already applied (claude-query)' \
  'process-group sweep already applied (codex-transport)' \
  'process-group behaviour check passed' \
  'credential key preservation already applied (claude)' \
  'credential key preservation already applied (codex)' \
  'credential key preservation behaviour check passed (claude)' \
  'credential key preservation behaviour check passed (codex)' \
  'paseo installed (owner:'; do
  grep -qF "$want" "$out" && ok "log: $want" || bad "log lacks: $want"
done
# The Fable 5.1 step retires itself once upstream ships the rows (rc 20) or reports
# them present (rc 10); either is a found target. What must not appear is the
# "not found" warning that means a wrong path.
grep -qE 'Fable 5.1 (rows already present|add skipped)' "$out" \
  && ok "log: Fable 5.1 step found the manifest" \
  || bad "log: Fable 5.1 step did not find the manifest"
if grep -q 'not found' "$out"; then
  bad "some patch step could not find its target:"
  grep 'not found' "$out" | sed 's/^/    /'
else
  ok "no patch step reported a missing target"
fi
if grep -q 'warning:' "$out"; then
  bad "the install log carries warnings:"
  grep 'warning:' "$out" | sed 's/^/    /'
else
  ok "the install log carries no warnings"
fi
webui="$TOP/dist/server/web-ui"
served="$(grep -o 'index-[0-9a-f]*\.js' "$webui/index.html" | head -1)"
if [ -n "$served" ] && [ -f "$webui/_expo/static/js/web/$served" ] \
   && node --check "$webui/_expo/static/js/web/$served" 2>/dev/null; then
  ok "index.html names a served bundle that is on disk and valid JS ($served)"
else
  bad "served web-ui bundle missing or invalid (index.html -> ${served:-none})"
fi
[ -f "$HOME_DIR/.config/systemd/user/airlock-paseo.service" ] \
  && ok "the unit was rendered" || bad "no unit rendered"
grep -q 'systemctl --user restart airlock-paseo.service' "$EVENTS" \
  && ok "the daemon restart was requested" || bad "no restart requested"
# INSTALLED_SHA256SUMS is written against the prefix-level layout; the installer
# checks it after npm and again on every idempotent re-run.
(cd "$NPM_ROOT" && sha256sum -c "$BUNDLE/INSTALLED_SHA256SUMS" >/dev/null 2>&1) \
  && ok "INSTALLED_SHA256SUMS verifies at the prefix level" \
  || bad "INSTALLED_SHA256SUMS does not verify at $NPM_ROOT"

# ---- 2. a re-run is idempotent: no npm, no restart ----
: >"$EVENTS"
out="$TMP/install-2.log"
if run_install "$out"; then ok "re-run exits 0"; else bad "re-run failed rc=$?"; sed 's/^/    /' "$out" | tail -8; fi
grep -q 'present (prefix=' "$out" && ok "re-run: bundle recognised as present (no npm)" \
  || bad "re-run: bundle was reinstalled or not recognised"
# With the shim reporting the unit inactive, the installer restarts it; what must not
# happen is a reinstall. The daemon-restart decision on a live box is covered elsewhere.
grep -q 'install paseo bundle:' "$out" && bad "re-run reinstalled the bundle" \
  || ok "re-run did not reinstall the bundle"

# ---- 3. a stale nested server (registry-era leftover) is a shadow, not a match ----
# Node resolves upward from the cli, so a nested copy would win over the verified
# prefix-level one. The idempotency check must refuse to call that "present", and
# npm's reinstall must remove the shadow. The box this was measured on (2026-09-12,
# after the rollback) also had ~/.npm-global/bin/paseo re-pointed at an external
# wrapper script by something outside Airlock; the reinstall must replace that link
# rather than trip over it, so the fixture carries the same collision.
mkdir -p "$(dirname "$NESTED")"
cp -r "$TOP" "$NESTED"
printf '\n// stale\n' >>"$NESTED/dist/server/server/session.js"
printf '#!/bin/sh\nexec "%s/@getpaseo/cli/bin/paseo" "$@"\n' "$NPM_ROOT" >"$TMP/foreign-wrapper.sh"
chmod +x "$TMP/foreign-wrapper.sh"
ln -sf "$TMP/foreign-wrapper.sh" "$HOME_DIR/.npm-global/bin/paseo"
out="$TMP/install-3.log"
if run_install "$out"; then ok "shadowed tree: install exits 0"; else bad "shadowed tree: install failed rc=$?"; sed 's/^/    /' "$out" | tail -8; fi
grep -q 'install paseo bundle:' "$out" && ok "shadowed tree: the bundle was reinstalled, not called present" \
  || bad "shadowed tree: the installer accepted a shadowed tree as present"
[ ! -e "$NESTED" ] && ok "shadowed tree: npm's reinstall removed the nested copy" \
  || bad "shadowed tree: the nested copy survived the reinstall"
case "$(readlink "$HOME_DIR/.npm-global/bin/paseo")" in
  *"/@getpaseo/cli/bin/paseo") ok "shadowed tree: the foreign bin/paseo symlink was replaced by npm's own" ;;
  *) bad "shadowed tree: bin/paseo still points at $(readlink "$HOME_DIR/.npm-global/bin/paseo")" ;;
esac
grep -q 'not found\|warning:' "$out" && { bad "shadowed tree: warnings after reinstall:"; grep 'not found\|warning:' "$out" | sed 's/^/    /'; } \
  || ok "shadowed tree: every patch found its target after the reinstall"

echo "---"
echo "paseo-bundle-install: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
