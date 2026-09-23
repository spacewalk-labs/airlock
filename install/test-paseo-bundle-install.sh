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
python3 "$HERE/test-paseo-native-links.py" || exit 1
BUNDLE="$ROOT/apps/paseo/vendor/guarded-0.8.0"
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
# Every patch step for a patch baked into the 0.8.0 bundle must have found its
# target ("already applied").
for want in \
  'depth4 search patch already applied' \
  'model prune already applied' \
  'OpenCode grok picker defaults already applied' \
  'pasted-image persistence already applied' \
  'schedule schema busy-pending patch already applied' \
  'schedule service busy-pending patch already applied' \
  'archive/workspace consistency already applied' \
  'archive/workspace consistency behaviour check passed' \
  'provider-subagent server filter already applied' \
  'provider-subagent selective delivery pair verified' \
  'orphan guard already applied (claude)' \
  'process-group sweep already applied (claude-agent)' \
  'process-group sweep already applied (claude-query)' \
  'process-group sweep already applied (codex-transport)' \
  'ACP context gauge applied' \
  'ACP cross-provider mode default applied' \
  'ACP invalid model rejection applied' \
  'paseo installed (owner:'; do
  grep -qF "$want" "$out" && ok "log: $want" || bad "log lacks: $want"
done
if grep -vF -e 'anchors not found' -e 'not found under' -e 'session.js or web-ui not found' \
    <<<"$(grep 'not found' "$out")" | grep -q .; then
  bad "some patch step could not find its target for an unexpected reason:"
  grep 'not found' "$out" | sed 's/^/    /'
else
  ok "no patch step reported an unexpected missing target"
fi
if grep 'warning:' "$out" | grep -q .; then
  bad "the install log carries an unexpected warning:"
  grep 'warning:' "$out" | sed 's/^/    /'
else
  ok "the install log carries no warnings — every patch is baked in and applies clean"
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

# The unit's own shadow guard, run rather than read. Node resolves upward from the
# cli, so a server nested under it wins over the patched prefix-level one at the next
# daemon start — the 2026-09-20 shadow on an operator box was created between installs and
# surfaced two days later at boot. The installer heals a shadow it meets (section 3
# below); this line is what holds the invariant in between, so assert the rendered
# command actually removes a shadow and leaves the canonical copy alone.
UNIT_FILE="$HOME_DIR/.config/systemd/user/airlock-paseo.service"
mkdir -p "$NESTED/dist"; : >"$NESTED/dist/shadow-marker"
guard="$(sed -n "s|^ExecStartPre=/bin/sh -c '\(.*\)'$|\1|p" "$UNIT_FILE")"
if [ -z "$guard" ]; then
  bad "the unit carries no ExecStartPre shadow guard"
elif sh -c "$guard" && [ ! -e "$NESTED" ] && [ -f "$TOP/dist/server/server/session.js" ]; then
  ok "the unit's ExecStartPre drops a nested server and keeps the prefix-level one"
else
  bad "the unit's ExecStartPre did not clear $NESTED (or removed the wrong tree)"
fi
rm -rf "$NESTED"
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
if grep 'not found\|warning:' "$out" | grep -q .; then
  bad "shadowed tree: unexpected warnings after reinstall:"
  grep 'not found\|warning:' "$out" | sed 's/^/    /'
else
  ok "shadowed tree: every patch found its target after the reinstall"
fi

echo "---"
echo "paseo-bundle-install: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
