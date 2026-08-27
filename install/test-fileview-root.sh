#!/usr/bin/env bash
# fileview serves `/`, and there is no way to make it serve anything else.
#
# This is not a style check. `[paths].code_root` existed because filebrowser demands
# a --root argument, and once the installer had to write a value somewhere it became
# a setting, and once it was a setting it was read as a boundary it never enforced.
# It was retired by making the argument a constant. A constant is only a constant
# while nobody threads a variable back through it, and that is a two-line change
# somebody makes in a hurry — so it is asserted here instead of trusted.
#
# The same applies to the OTHER half of the boundary. What fileview can reach is
# decided by the account its user service runs as — the kernel draws that line, and
# the app cannot express it, so there is nothing to configure and nothing to turn
# off. That only stays true while the unit declares no User=/Group= of its own.
#
# What is checked: every place this app starts filebrowser passes a LITERAL `/`, the
# unit renderer takes no root parameter, the unit names no account, and no root value
# can reach it from configuration.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/apps/fileview"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

# 1. Every --root in the app's CODE is followed by a literal / and nothing else.
#    Comments are stripped first: they discuss `--root /` in prose, and matching
#    those was the difference between a check and a wall of false alarms.
code_roots="$(sed 's/#.*//' "$APP"/*.sh | grep -hoE -- '--root [^ ]+' | sort -u)"
n_sites="$(sed 's/#.*//' "$APP"/*.sh | grep -c -- '--root ')"
if [ "$code_roots" = "--root /" ]; then
  ok "every --root in apps/fileview is a literal / ($n_sites site(s))"
else
  bad "a --root other than a literal / appears in apps/fileview:"; printf '%s\n' "$code_roots" | sed 's/^/     /'
fi

# 2. The rendered unit says --root / — rendered, not grepped from the template, so a
#    variable smuggled in through a parameter would show up here.
# shellcheck source=/dev/null
. "$APP/render.sh"
unit="$(render_fileview_unit_filebrowser 19999 /nowhere/filebrowser /nowhere/fb.db)"
case "$unit" in
  *"--root / "*) ok "the rendered unit serves /" ;;
  *)             bad "the rendered unit does not serve / (got: $(printf '%s' "$unit" | grep ExecStart))" ;;
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
#     setting attracts is a value somebody has to choose.
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

# 6. Where the tree OPENS is the running account's home — and that is a fact about
#    the account, not a setting. The distinction matters because this is exactly the
#    shape `[paths].code_root` had: a directory the installer had to write somewhere,
#    which then became a key, which was then read as a boundary. So three things are
#    pinned: the shipped HTML carries an EMPTY value (a repo that ships a path has
#    somebody's box baked into it), the installer fills it from $HOME and from
#    nothing else, and no config key feeds it.
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
# And it decides only where you land: the scope is still the constant checked above.
if grep -q 'accountHome' "$APP/static/app.js" && \
   ! grep -nE 'accountHome' "$APP/static/app.js" | grep -qE 'apiUrl|--root|scope ='; then
  ok "the home path is used to expand the tree, not to bound it"
else
  bad "the home path reached something other than the initial expansion"
fi

# --- controls -----------------------------------------------------------------
# A check that cannot fail is not a check. Break each rule in a scratch copy and
# confirm this file rejects it.
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
cp -r "$APP" "$scratch/fileview"
# shellcheck disable=SC2016  # the literal ${CODE_ROOT} text is the point: that is
# exactly the shape being planted for the control to catch.
sed -i 's|--root / --address|--root "${CODE_ROOT}" --address|' "$scratch/fileview/render.sh"
if APP="$scratch/fileview" bash -c '
  code_roots="$(sed "s/#.*//" "$APP"/*.sh | grep -hoE -- "--root [^ ]+" | sort -u)"
  [ "$code_roots" = "--root /" ]'; then
  bad "control: a variable --root was NOT detected"
else
  ok "control: a variable --root is detected"
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
