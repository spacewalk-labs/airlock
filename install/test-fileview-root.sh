#!/usr/bin/env bash
# fileview serves the account's home, and there is no way to make it serve anything
# else.
#
# This is not a style check. `[paths].code_root` existed because filebrowser demands
# a --root argument, and once the installer had to write a value somewhere it became
# a setting, and once it was a setting it was read as a boundary it never enforced.
# It was retired by making the argument a constant `/`. The operator then asked for
# the opposite scope — home, with nothing above it visible (2026-09-04) — and the
# danger is that "a narrower root" is exactly the shape that invites the key back.
# So the root is still not a value anybody chooses: it is `%h` in the unit (systemd's
# own specifier for the running account's home) and `$HOME` in the short-lived
# first-run process, and that is asserted here rather than trusted.
#
# The OTHER half of the boundary is unchanged. What fileview could reach at all is
# decided by the account its user service runs as — the kernel draws that line, the
# app cannot express it, and it stays true only while the unit declares no
# User=/Group= of its own.
#
# What is checked: every place this app starts filebrowser passes home and nothing
# else, the unit renderer takes no root parameter, the unit names no account, and no
# root value can reach any of it from configuration. That the scope actually HOLDS at
# runtime — `..`, absolute paths, symlinks out — is measured against the real binary
# by install/test-fileview-home-scope.sh, and the client half by
# install/test-fileview-scope.mjs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/apps/fileview"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

# 1. Every --root in the app's CODE names home, literally: `%h` (the unit, where
#    systemd expands it) or `"$HOME"` (the installer's own process). Comments are
#    stripped first: they discuss the flag in prose, and matching those was the
#    difference between a check and a wall of false alarms.
code_roots="$(sed 's/#.*//' "$APP"/*.sh | grep -hoE -- '--root [^ ]+' | sort -u)"
n_sites="$(sed 's/#.*//' "$APP"/*.sh | grep -c -- '--root ')"
want="$(printf '%s\n%s' '--root "$HOME"' '--root %h' | sort -u)"
if [ "$code_roots" = "$want" ]; then
  ok "every --root in apps/fileview is home, literally ($n_sites site(s): %h and \$HOME)"
else
  bad "a --root other than %h / \"\$HOME\" appears in apps/fileview:"; printf '%s\n' "$code_roots" | sed 's/^/     /'
fi

# 2. The rendered unit says --root %h — rendered, not grepped from the template, so a
#    variable smuggled in through a parameter would show up here.
# shellcheck source=/dev/null
. "$APP/render.sh"
unit="$(render_fileview_unit_filebrowser 19999 /nowhere/filebrowser /nowhere/fb.db)"
case "$unit" in
  *"--root %h "*) ok "the rendered unit serves %h (the running account's home)" ;;
  *)              bad "the rendered unit does not serve %h (got: $(printf '%s' "$unit" | grep ExecStart))" ;;
esac
# And it serves nothing wider. `/` is the value this replaced; a revert would be a
# one-character edit and would otherwise pass every other check in this file.
case "$unit" in
  *"--root / "*) bad "the rendered unit is back to --root / (the whole filesystem)" ;;
  *)             ok "the rendered unit does not serve /" ;;
esac

# 3. The renderer must not GROW a root parameter. Three arguments, and a fourth is
#    ignored — if someone adds one, this catches it before it reaches a config key.
unit4="$(render_fileview_unit_filebrowser 19999 /nowhere/filebrowser /nowhere/fb.db /some/root)"
if [ "$unit" = "$unit4" ]; then
  ok "a fourth argument changes nothing — the renderer has no root parameter"
else
  bad "render_fileview_unit_filebrowser grew a parameter that changes the unit"
fi

# 3b. The unit must not name an account. fileview is the viewer OF the account it
#     runs as; a User=/Group= line would make that a setting, and the first thing a
#     setting attracts is a value somebody has to choose. It matters more now than it
#     did under `/`: %h is the home of whoever the unit runs as, so a User= line
#     would move the SCOPE as well as the permissions.
case "$unit" in
  *$'\nUser='*|*$'\nGroup='*) bad "the unit declares User=/Group= — the account is not the unit's to choose" ;;
  *) ok "the unit names no account (it runs as whoever installed it)" ;;
esac
if grep -qE '^\s*(User|Group)=' "$APP/render.sh"; then
  bad "render.sh grew a User=/Group= line"
else
  ok "render.sh has no User=/Group= line"
fi

# 4. Nothing in the app manifest can carry a path. The only config key is the port.
keys="$(python3 - "$APP/airlock-app.toml" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
cfg = d.get('config', {})
print(' '.join(sorted(list(cfg.get('defaults', {})) + [r['name'] for r in cfg.get('required', [])])))
PY
)"
if [ "$keys" = "filebrowser_port" ]; then
  ok "the manifest's only config key is filebrowser_port"
else
  bad "apps/fileview/airlock-app.toml declares config keys beyond the port: $keys"
fi

# 5. And the retired key stays retired: it must be refused as a live key.
if grep -q '"paths.code_root"' "$ROOT/bin/airlock-config"; then
  ok "paths.code_root is still listed as retired"
else
  bad "paths.code_root fell out of RETIRED_KEYS — a config carrying it would go quiet"
fi
if grep -qE '"paths": *frozenset\(\{[^}]*code_root' "$ROOT/bin/airlock-config"; then
  bad "paths.code_root came back as an accepted key"
else
  ok "paths.code_root is not an accepted [paths] key"
fi

# 6. The home path the CLIENT uses is the same fact, from the same source. The
#    viewer needs the value (the API speaks paths relative to the root while the UI
#    speaks absolute ones), and that is exactly the shape `[paths].code_root` had —
#    a directory the installer had to write somewhere, which became a key, which was
#    then read as a boundary. So three things are pinned: the shipped HTML carries an
#    EMPTY value (a repo that ships a path has somebody's box baked into it), the
#    installer fills it from $HOME and from nothing else, and no config key feeds it.
home_meta="$(grep -o '<meta name="fileview-home" content="[^"]*">' "$APP/static/viewer.html" || true)"
if [ "$home_meta" = '<meta name="fileview-home" content="">' ]; then
  ok "the shipped viewer carries no home path (the installer writes it)"
else
  bad "apps/fileview/static/viewer.html ships a home path: $home_meta"
fi
home_src="$(grep -c 'fileview-home.*content=.*\$HOME' "$APP/install.sh" || true)"
if [ "$home_src" = "1" ]; then
  ok "the installer fills the home meta from \$HOME, once"
else
  bad "the home meta is not written from \$HOME exactly once (found $home_src)"
fi
if grep -nE 'fileview-home' "$APP/install.sh" | grep -qiE 'airlock-config|config get|\bcfg\b'; then
  bad "the home meta is read from config — it is a fact about the account, not a key"
else
  ok "the home meta never comes from config"
fi
# 6b. And the client BOUNDS with it: every API URL goes through the translation that
#     refuses a path outside it. Under `--root /` this assertion was the opposite —
#     the home path decided where the tree opened and nothing else. The behaviour is
#     run, not grepped, by install/test-fileview-scope.mjs; what is checked here is
#     that the one funnel is still the one funnel.
if grep -q 'function apiUrl' "$APP/static/app.js" && \
   grep -A3 'function apiUrl' "$APP/static/app.js" | grep -q 'toApiPath'; then
  ok "every API URL is built through the home-relative translation"
else
  bad "apiUrl no longer goes through toApiPath — paths would reach the API unchecked"
fi

# --- controls -----------------------------------------------------------------
# A check that cannot fail is not a check. Break each rule in a scratch copy and
# confirm this file rejects it.
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
cp -r "$APP" "$scratch/fileview"
# shellcheck disable=SC2016  # the literal ${CODE_ROOT} text is the point: that is
# exactly the shape being planted for the control to catch.
sed -i 's|--root %h --address|--root "${CODE_ROOT}" --address|' "$scratch/fileview/render.sh"
if APP="$scratch/fileview" bash -c '
  code_roots="$(sed "s/#.*//" "$APP"/*.sh | grep -hoE -- "--root [^ ]+" | sort -u)"
  want="$(printf "%s\n%s" "--root \"\$HOME\"" "--root %h" | sort -u)"
  [ "$code_roots" = "$want" ]'; then
  bad "control: a variable --root was NOT detected"
else
  ok "control: a variable --root is detected"
fi
# The revert this change is most likely to suffer: somebody puts `/` back.
cp -r "$APP" "$scratch/fileview3"
sed -i 's|--root %h --address|--root / --address|' "$scratch/fileview3/render.sh"
if (
  # shellcheck source=/dev/null
  . "$scratch/fileview3/render.sh"
  u="$(render_fileview_unit_filebrowser 19999 /nowhere/filebrowser /nowhere/fb.db)"
  case "$u" in *"--root / "*) exit 0 ;; *) exit 1 ;; esac
); then
  ok "control: a unit reverted to --root / is detected"
else
  bad "control: a unit reverted to --root / was NOT detected"
fi
cp -r "$APP" "$scratch/fileview2"
sed -i 's|^WorkingDirectory=|User=someone\nWorkingDirectory=|' "$scratch/fileview2/render.sh"
if grep -qE '^\s*(User|Group)=' "$scratch/fileview2/render.sh"; then
  ok "control: a User= line is detected"
else
  bad "control: a User= line was NOT detected"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
