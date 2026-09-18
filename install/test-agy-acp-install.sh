#!/usr/bin/env bash
# install/test-agy-acp-install.sh — apps/paseo/agy-acp/install.sh itself: the
# config gate, the build, and apps/paseo/agy-acp/configure-agy-acp.py's
# idempotent config.json/skills.json writes. Offline except for `npm install`
# of the fork's own two runtime deps (same network dependency as
# install/test-agy-acp.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FORK_INSTALL="$ROOT/apps/paseo/agy-acp/install.sh"

pass=0; fail=0
ok()  { echo "ok   agy-acp-install: $1"; pass=$((pass+1)); }
bad() { echo "FAIL agy-acp-install: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_install() {   # run_install <home-dir> <paseo-home-dir> <agy-enabled> <log-file>
  env AIRLOCK_PASEO_AGY="$3" HOME="$1" PASEO_HOME="$2" \
    bash "$FORK_INSTALL" >"$4" 2>&1
}

# rc 2 means "wrote a config change, caller should restart" — the parent
# apps/paseo/install.sh hook folds that into its own need_restart, not a
# failure here. Only some OTHER nonzero rc is a real failure.
expect_rc() {   # expect_rc <actual> <allowed-rc...>
  local actual="$1"; shift
  for want in "$@"; do [ "$actual" = "$want" ] && return 0; done
  return 1
}

# --- 1. disabled by default: exits 0, touches nothing ------------------------
HOME_OFF="$TMP/home-off"; PASEO_HOME_OFF="$TMP/paseo-off"
mkdir -p "$HOME_OFF" "$PASEO_HOME_OFF"
run_install "$HOME_OFF" "$PASEO_HOME_OFF" false "$TMP/off.log"; rc=$?
if expect_rc "$rc" 0; then
  ok "disabled gate exits 0"
else
  bad "disabled gate exited $rc, expected 0 — $(cat "$TMP/off.log")"
fi
[ ! -e "$PASEO_HOME_OFF/config.json" ] && ok "disabled gate wrote no config.json" \
  || bad "disabled gate wrote config.json anyway"
[ ! -e "$HOME_OFF/.gemini/config/skills.json" ] && ok "disabled gate wrote no skills.json" \
  || bad "disabled gate wrote skills.json anyway"

# --- 2. enabled: builds, registers the provider, writes skills.json ----------
HOME_ON="$TMP/home-on"; PASEO_HOME_ON="$TMP/paseo-on"
mkdir -p "$HOME_ON" "$PASEO_HOME_ON"
run_install "$HOME_ON" "$PASEO_HOME_ON" true "$TMP/on1.log"; rc=$?
if expect_rc "$rc" 2; then
  ok "enabled install (first run, writes a change) exits 2"
else
  bad "enabled install exited $rc, expected 2 (wrote a change) — $(tail -30 "$TMP/on1.log")"
fi
[ -f "$HOME_ON/.local/share/agy-acp/dist/cli.js" ] && ok "fork staged + built under \$HOME/.local/share/agy-acp" \
  || bad "no dist/cli.js under \$HOME/.local/share/agy-acp"
[ -f "$HOME_ON/.local/share/agy-acp/LICENSE" ] && ok "installed fork ships its MIT LICENSE" \
  || bad "no LICENSE under the installed \$HOME/.local/share/agy-acp"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$PASEO_HOME_ON/config.json" <<'PY' && ok "config.json: agy provider has extends=acp, no static models"
import json, sys
cfg = json.load(open(sys.argv[1]))
agy = cfg["agents"]["providers"]["agy"]
assert agy["extends"] == "acp", agy
assert "models" not in agy, agy
assert agy["command"][-1].endswith("dist/cli.js"), agy
PY
  [ $? -eq 0 ] || bad "config.json agy provider shape is wrong"

  python3 - "$HOME_ON/.gemini/config/skills.json" "$HOME_ON" <<'PY' && ok "skills.json has the absolute ~/.claude/skills entry"
import json, os, sys
cfg = json.load(open(sys.argv[1]))
want = os.path.join(sys.argv[2], ".claude", "skills")
assert any(e.get("path") == want for e in cfg["entries"]), cfg
assert "~" not in json.dumps(cfg), "skills.json must carry no literal ~"
PY
  [ $? -eq 0 ] || bad "skills.json entry is wrong or unexpanded"
else
  bad "python3 not available to check config.json/skills.json shape"
fi

# --- 3. idempotent re-run: byte-identical files, no unnecessary rewrite ------
sha_before_config="$(sha256sum "$PASEO_HOME_ON/config.json" | cut -d' ' -f1)"
sha_before_skills="$(sha256sum "$HOME_ON/.gemini/config/skills.json" | cut -d' ' -f1)"
run_install "$HOME_ON" "$PASEO_HOME_ON" true "$TMP/on2.log"; rc=$?
if expect_rc "$rc" 0; then
  ok "re-run (no change) exits 0, not 2 — no restart requested for a no-op"
else
  bad "re-run exited $rc, expected 0 — $(tail -30 "$TMP/on2.log")"
fi
sha_after_config="$(sha256sum "$PASEO_HOME_ON/config.json" | cut -d' ' -f1)"
sha_after_skills="$(sha256sum "$HOME_ON/.gemini/config/skills.json" | cut -d' ' -f1)"
[ "$sha_before_config" = "$sha_after_config" ] && ok "config.json unchanged on re-run" \
  || bad "config.json changed on an idempotent re-run"
[ "$sha_before_skills" = "$sha_after_skills" ] && ok "skills.json unchanged on re-run" \
  || bad "skills.json changed on an idempotent re-run"
grep -q "already up to date" "$TMP/on2.log" && ok "re-run reports already up to date" \
  || bad "re-run log does not report already up to date"

# --- 4. a pre-existing config.json with other providers is preserved ---------
HOME_MERGE="$TMP/home-merge"; PASEO_HOME_MERGE="$TMP/paseo-merge"
mkdir -p "$HOME_MERGE" "$PASEO_HOME_MERGE"
cat >"$PASEO_HOME_MERGE/config.json" <<'JSON'
{"version": 1, "daemon": {"listen": "127.0.0.1:6767"}, "agents": {"providers": {"claude": {"extends": "claude"}}}}
JSON
run_install "$HOME_MERGE" "$PASEO_HOME_MERGE" true "$TMP/merge.log"; rc=$?
if expect_rc "$rc" 2; then
  python3 - "$PASEO_HOME_MERGE/config.json" <<'PY' && ok "merge preserves pre-existing config (version, daemon, other providers)"
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg["version"] == 1
assert cfg["daemon"]["listen"] == "127.0.0.1:6767"
assert cfg["agents"]["providers"]["claude"] == {"extends": "claude"}
assert cfg["agents"]["providers"]["agy"]["extends"] == "acp"
PY
  [ $? -eq 0 ] || bad "merge damaged pre-existing config.json content"
else
  bad "install against a pre-existing config.json exited $rc, expected 2 — $(tail -30 "$TMP/merge.log")"
fi

# --- 5. stale manual agy-* aliases (old unpatched global install) are removed;
#        an unrelated agy-* provider that does not match is left alone --------
HOME_ALIAS="$TMP/home-alias"; PASEO_HOME_ALIAS="$TMP/paseo-alias"
mkdir -p "$HOME_ALIAS" "$PASEO_HOME_ALIAS"
cat >"$PASEO_HOME_ALIAS/config.json" <<'JSON'
{
  "version": 1,
  "agents": {
    "providers": {
      "claude": {"extends": "claude"},
      "agy-low": {
        "extends": "acp",
        "label": "Antigravity",
        "command": ["/usr/bin/node", "/home/x/.nvm/versions/node/v22.22.3/lib/node_modules/google-antigravity-acp/dist/cli.js", "-m", "gemini-3.8-flash-low"]
      },
      "agy-opus": {
        "extends": "acp",
        "label": "Antigravity Opus",
        "command": ["/usr/bin/node", "/home/x/.nvm/versions/node/v22.22.3/lib/node_modules/google-antigravity-acp/dist/cli.js", "-m", "claude-opus-4-6-thinking"]
      },
      "agy-gpt": {
        "extends": "acp",
        "label": "Antigravity GPT",
        "command": ["/usr/bin/node", "/home/x/.nvm/versions/node/v22.22.3/lib/node_modules/google-antigravity-acp/dist/cli.js", "-m", "gpt-oss-120b-medium"]
      },
      "agy-custom": {
        "extends": "acp",
        "label": "An operator's own unrelated agy-* provider",
        "command": ["/usr/bin/node", "/opt/something-else/cli.js"]
      }
    }
  }
}
JSON
run_install "$HOME_ALIAS" "$PASEO_HOME_ALIAS" true "$TMP/alias.log"; rc=$?
if expect_rc "$rc" 2; then
  ok "install against manual aliases exits 2 (wrote a change)"
else
  bad "install against manual aliases exited $rc, expected 2 — $(tail -30 "$TMP/alias.log")"
fi
if grep -q 'removed stale manual alias' "$TMP/alias.log"; then
  ok "install log reports the removed aliases"
else
  bad "install log does not mention removing stale aliases — $(cat "$TMP/alias.log")"
fi
python3 - "$PASEO_HOME_ALIAS/config.json" <<'PY' && ok "agy-low/agy-opus/agy-gpt removed; claude and the unrelated agy-custom survive; agy is the patched fork"
import json, sys
cfg = json.load(open(sys.argv[1]))
providers = cfg["agents"]["providers"]
assert "agy-low" not in providers, providers
assert "agy-opus" not in providers, providers
assert "agy-gpt" not in providers, providers
assert providers["claude"] == {"extends": "claude"}, providers
assert providers["agy-custom"]["command"] == ["/usr/bin/node", "/opt/something-else/cli.js"], providers
assert providers["agy"]["extends"] == "acp"
assert "/.local/share/agy-acp/" in providers["agy"]["command"][-1], providers["agy"]
PY
[ $? -eq 0 ] || bad "alias cleanup left the config.json in the wrong shape"

echo

# --- parent fold: apps/paseo/install.sh runs under `set -euo pipefail`; the
# child's rc 2 ("config changed") must fold into need_restart instead of
# aborting the whole installer (C2.5 F1, 2026-09-15). Runs the parent's real
# 3b block text, not a copy, against a stub child returning 0 / 2 / 1.
PARENT_BLOCK="$TMP/parent-3b.sh"
awk '/^# --- 3b\./{on=1} /^# --- 4\./{on=0} on' "$ROOT/apps/paseo/install.sh" >"$PARENT_BLOCK"
if ! grep -q 'agy-acp/install.sh' "$PARENT_BLOCK"; then
  bad "parent fold: could not extract the 3b block from apps/paseo/install.sh"
else
  for case in "0:0" "2:1" "1:0"; do
    child_rc="${case%%:*}"; want_restart="${case##*:}"
    STUB="$TMP/stub-$child_rc"; mkdir -p "$STUB/agy-acp"
    printf '#!/usr/bin/env bash\nexit %s\n' "$child_rc" >"$STUB/agy-acp/install.sh"
    out="$(bash -c 'set -euo pipefail; HERE="$1"; AIRLOCK_PASEO_AGY=true; need_restart=0
      log() { :; }; . "$2"; echo "reached need_restart=$need_restart"' _ "$STUB" "$PARENT_BLOCK" 2>&1)"; prc=$?
    if [ "$prc" = 0 ] && [ "$out" = "reached need_restart=$want_restart" ]; then
      ok "parent fold: child rc $child_rc continues with need_restart=$want_restart"
    else
      bad "parent fold: child rc $child_rc -> parent rc $prc, output: $out"
    fi
  done
fi


# --- dry run must not mutate (C2.5 F2, 2026-09-15): a dry-run selected install from a
# Paseo seat wrote the live ~/.paseo/config.json. Parent must not call the child, and
# the child must not write even when called directly.
STUBD="$TMP/stub-dry"; mkdir -p "$STUBD/agy-acp"
printf '#!/usr/bin/env bash\ntouch "$(dirname "$0")/CALLED"\nexit 2\n' >"$STUBD/agy-acp/install.sh"
out="$(bash -c 'set -euo pipefail; HERE="$1"; AIRLOCK_PASEO_AGY=true; AIRLOCK_DRY_RUN=1; need_restart=0
  log() { :; }; . "$2"; echo "reached need_restart=$need_restart"' _ "$STUBD" "$PARENT_BLOCK" 2>&1)"; prc=$?
if [ "$prc" = 0 ] && [ ! -e "$STUBD/agy-acp/CALLED" ] && [ "$out" = "reached need_restart=0" ]; then
  ok "dry run: parent does not run the agy-acp child"
else
  bad "dry run: parent rc $prc, child called=$([ -e "$STUBD/agy-acp/CALLED" ] && echo yes || echo no), output: $out"
fi
HOME_DRY="$TMP/home-dry"; PASEO_DRY="$TMP/paseo-dry"; mkdir -p "$HOME_DRY" "$PASEO_DRY"
env AIRLOCK_DRY_RUN=1 AIRLOCK_PASEO_AGY=true HOME="$HOME_DRY" PASEO_HOME="$PASEO_DRY" \
  bash "$FORK_INSTALL" >"$TMP/dry.log" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$PASEO_DRY/config.json" ] && [ ! -e "$HOME_DRY/.gemini/config/skills.json" ] && [ ! -e "$HOME_DRY/.local/share/agy-acp" ]; then
  ok "dry run: child writes nothing"
else
  bad "dry run: child rc $rc, wrote config=$([ -e "$PASEO_DRY/config.json" ] && echo yes || echo no) — $(tail -3 "$TMP/dry.log")"
fi

echo "agy-acp-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
