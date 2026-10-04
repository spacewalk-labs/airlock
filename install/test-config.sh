#!/usr/bin/env bash
# Tests for bin/airlock-config (T2). No live services needed.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/../bin/airlock-config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Isolate the installed-state ledger: a developer's real ledger must never
# leak into (or fail) these tests. See docs/design/app-package-contract.md D6.
export AIRLOCK_STATE_DIR="$TMP/state"

airlock_test_counters_init

# --- fixtures ---
cat >"$TMP/good.toml" <<'TOML'
[site]
name = "My Dev Hub"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
collaborators = ["a@example.com", "b@example.com"]
[paths]
wiki = "~/wiki"
[branding]
product = "Airlock"
[apps.hub]
[apps.devterm]
font_size = 16
xai = true
compat_https_enabled = true
[apps.fileview]
TOML

# Record explicit fixture sources through the production installed-record writer.
seed_apps() {
  env -u AIRLOCK_APP_ID -u AIRLOCK_APP_DIR python3 - "$HERE/../bin/airlock-ledger" "$@" <<'PY_SEED'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("_fixture_ledger", sys.argv[1]).load_module()
rows = ledger.load_installed()
for pid, directory in zip(sys.argv[2::2], sys.argv[3::2]):
    repo = str(Path(directory).resolve())
    if pid not in rows or rows[pid]["repo"] != repo:
        rows[pid] = {"repo": repo, "commit": "", "artifacts": []}
ledger.write_installed(rows)
PY_SEED
}

run() { AIRLOCK_CONFIG="$1" python3 "$CFG" "${@:2}"; }

# 1. valid config validates
if run "$TMP/good.toml" validate >/dev/null 2>&1; then ok "validate: good"; else bad "validate: good"; fi

# Card ICON_GLYPH_GATE accepts this fixture suite, which covers the shortcut
# surface here and the packaged-manifest surface in test-manifest.sh.  Normal
# `validate` retains its stable one-line operator output; this explicit fixture
# mode carries the machine-readable acceptance observations instead.
glyph_ac="$(AIRLOCK_EMIT_AC=1 run "$TMP/good.toml" validate 2>&1)"
if grep -Eq '^AC-GLYPH-SPRITE \| expected: sprite_symbols > 0 \| observed: sprite_symbols=[1-9][0-9]* \| verdict: PASS \| signal: fixture \| evidence: hub/index.html@[0-9a-f]{7,}$' <<<"$glyph_ac" \
   && grep -Eq '^AC-GLYPH-DECLARATIONS \| expected: shipped_glyphs_checked == shipped_glyphs_declared \| observed: active_package_glyphs_checked=[0-9]+,shipped_glyphs_checked=[0-9]+,shipped_glyphs_declared=[0-9]+ \| verdict: PASS \| signal: fixture \| evidence: bin/airlock-config@[0-9a-f]{7,}$' <<<"$glyph_ac"; then
  ok "validate: emits glyph AC observations with checkout evidence"
else
  bad "validate: emits glyph AC observations with checkout evidence"
fi
printf '%s\n' "$glyph_ac" | sed -n '/^AC-GLYPH-/p'

# 3c. plaintext wiring: enabled apps with a plaintext port -> their redirect port
pt="$(run "$TMP/good.toml" plaintext 2>/dev/null | tr '\t' ':' | sort | tr '\n' ',')"
[ "$pt" = "hub:19901:19903," ] && ok "plaintext: listen -> redirect" || bad "plaintext: got '$pt'"
# D-DEVTERM-9900 retired the shipped 9900 default. Known ports are hub
# plus any still-declared plaintext_redirect (none on shipped devterm).
known="$(run "$TMP/good.toml" plaintext-known 2>/dev/null | sort -n | tr '\n' ',')"
[ "$known" = "19901," ] && ok "plaintext-known: hub only" || bad "plaintext-known: got '$known'"

# Both devterm HTTPS listeners are platform-rendered to the same owner gate.
# The 8443 compatibility route used to live only in mutable tailscaled state,
# which let it drift to an unrelated development server without any owner.
devterm_https="$(run "$TMP/good.toml" package-info 2>/dev/null | python3 -c '
import json, sys
mappings = json.load(sys.stdin)["packages"]["devterm"]["serve_mappings"]
print(",".join(sorted(
    "{}:{}".format(mapping["listen"], mapping["target"])
    for mapping in mappings.values()
    if mapping["mode"] == "https"
)))
')"
[ "$devterm_https" = "19910:19911,8443:19911" ] \
  && ok "devterm serve: primary and compatibility HTTPS share the owner gate" \
  || bad "devterm serve: got '$devterm_https'"

sed '/compat_https_enabled = true/d' "$TMP/good.toml" >"$TMP/devterm-default.toml"
devterm_default_https="$(run "$TMP/devterm-default.toml" package-info 2>/dev/null | python3 -c '
import json, sys
mappings = json.load(sys.stdin)["packages"]["devterm"]["serve_mappings"]
print(",".join(str(mapping["listen"]) for mapping in mappings.values()))
')"
[ "$devterm_default_https" = "19910" ] \
  && ok "devterm serve: compatibility HTTPS is opt-in" \
  || bad "devterm serve: disabled default rendered '$devterm_default_https'"

# 3d. webjson carries the measured FQDN so the launcher's cross-port links match
# the cert regardless of the origin the page was opened from — and omits it when
# unknown (the launcher then falls back to location.hostname).
wj="$(AIRLOCK_TS_FQDN=box.example.ts.net run "$TMP/good.toml" webjson 2>/dev/null)"
grep -q '"fqdn": "box.example.ts.net"' <<<"$wj" && ok "webjson: carries fqdn" || bad "webjson: fqdn missing"
# D7 (child 4) legitimately puts the literal string "owner" into webjson as a
# packaged app's `audience` VALUE (`"audience": "owner"` — one of the two
# audience-class enum values, D7/F14; good.toml's devterm now carries one,
# the first migrated app in this fixture to declare [audience]) so the
# launcher can fail-closed hide an owner-only tile from a non-owner viewer.
# That is not the leak this guard exists for — the guard exists to catch the
# OPERATOR'S auth.owner value, the identity header name, or an internal port
# KEY NAME (nginx_port/gate_port/redirect_port) reaching the browser. Drop
# exactly that one contract-mandated line before the substring check, so a
# real leak anywhere else (including a future "owner" appearing outside an
# audience value) still fails loudly.
grep -v '"audience": "owner"' <<<"$wj" \
  | grep -q 'owner\|identity\|nginx_port\|gate_port\|redirect_port' \
  && bad "webjson leaks internals" || ok "webjson: no internals"
wj2="$(AIRLOCK_TS_FQDN= run "$TMP/good.toml" webjson 2>/dev/null)"
grep -q '"fqdn"' <<<"$wj2" && bad "webjson: empty fqdn emitted" || ok "webjson: omits unknown fqdn"

# 4. apps lists enabled tables
apps="$(run "$TMP/good.toml" apps 2>/dev/null | sort | tr '\n' ',')"
[ "$apps" = "devterm,fileview,hub," ] && ok "apps: enabled list" || bad "apps: got '$apps'"

# 5. env exposes identity header (fixed) + common + app-specific override + default
env="$(run "$TMP/good.toml" env devterm 2>/dev/null)"
echo "$env" | grep -q "AIRLOCK_IDENTITY_HEADER=Tailscale-User-Login" && ok "env: identity header fixed" || bad "env: identity header"
echo "$env" | grep -q "AIRLOCK_OWNER=owner@fixture.dev" && ok "env: owner" || bad "env: owner"
echo "$env" | grep -q "AIRLOCK_COLLABORATORS=a@example.com,b@example.com" && ok "env: collaborators joined" || bad "env: collaborators"
echo "$env" | grep -q "AIRLOCK_DEVTERM_FONT_SIZE=16" && ok "env: app override" || bad "env: app override"
echo "$env" | grep -q "AIRLOCK_DEVTERM_TTYD_PORT=19912" && ok "env: app default merged" || bad "env: app default"
echo "$env" | grep -q "AIRLOCK_DEVTERM_XAI=true" && ok "env: xAI app override" || bad "env: xAI app override"
# site name with spaces must be shell-safe for eval
( eval "$env"; [ "$AIRLOCK_SITE_NAME" = "My Dev Hub" ] ) && ok "env: eval-safe quoting" || bad "env: quoting"

# 6. env for a disabled app fails
if run "$TMP/good.toml" env orca >/dev/null 2>&1; then bad "env: rejects disabled app"; else ok "env: rejects disabled app"; fi

# 7. get with default fallback + dotted key
[ "$(run "$TMP/good.toml" get auth.owner 2>/dev/null)" = "owner@fixture.dev" ] && ok "get: dotted" || bad "get: dotted"
[ "$(run "$TMP/good.toml" get apps.devterm.ttyd_port 2>/dev/null)" = "19912" ] && ok "get: default merged" || bad "get: default merged"

# 8. a [paths] value expands ~ — to the real home, not merely to something without a '~'
[ "$(run "$TMP/good.toml" get paths.wiki 2>/dev/null)" = "$HOME/wiki" ] \
  && ok "get: ~ expanded to \$HOME" || bad "get: ~ expanded to \$HOME"

# --- 9. code_root is retired: it names a boundary that no longer exists --------
# fileview's filebrowser runs with `--root %h` (the account's home), so there is
# nothing to configure — and the message has to say the root is not a value, or the
# key comes back pointed at home.
# A leftover key must NOT fail the box (every config written before this release
# carries one) — it gets the targeted retired-key message instead.
mk() { printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n%s\n' "$1" >"$TMP/t.toml"; }

mk '[paths]
code_root = "~/code"
[apps.fileview]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "code_root: retired, does not fail"; else bad "code_root: retired, does not fail"; fi
cr_msg="$(run "$TMP/t.toml" validate 2>&1)"
grep -q 'code_root' <<<"$cr_msg" && ok "code_root: names the key" || bad "code_root: names the key"
grep -q -- '--root %h' <<<"$cr_msg" && ok "code_root: says what replaced it" || bad "code_root: says what replaced it"

# fileview no longer needs any path key at all.
mk '[apps.fileview]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "fileview: validates with no [paths] at all"; else bad "fileview: validates with no [paths] at all"; fi

# P2a moves the defaults behind these two devterm keys to platform binaries, but the
# keys themselves must remain declared: config validation is fail-closed and existing
# operators may still use them as explicit gate-tool overrides.
mk '[apps.devterm]
claude_switch = "/opt/operator/claude-switch"
claude_status = "/opt/operator/claude-status"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  devterm_override_env="$(run "$TMP/t.toml" env devterm 2>/dev/null)"
  if grep -q '^AIRLOCK_DEVTERM_CLAUDE_SWITCH=/opt/operator/claude-switch$' <<<"$devterm_override_env" \
     && grep -q '^AIRLOCK_DEVTERM_CLAUDE_STATUS=/opt/operator/claude-status$' <<<"$devterm_override_env"; then
    ok "devterm: legacy account-tool override keys still validate and export"
  else
    bad "devterm: account-tool override keys validated but did not export"
  fi
else
  bad "devterm: legacy account-tool override keys remain accepted"
fi

mk '[apps.dev-monitor]
slack_webhook_urgent_env = "DEVMON_URGENT"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  ok "dev-monitor: single webhook selector is accepted"
else
  bad "dev-monitor: single webhook selector is accepted"
fi
dm_env="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if grep -qxF 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV=DEVMON_URGENT' <<<"$dm_env"; then
  ok "dev-monitor: single webhook selector exports its name"
else
  bad "dev-monitor: single webhook selector exports its name"
fi

mk '[apps.dev-monitor]
spool_writer_user = "monitor-writer"
spool_writer_group = "monitor-writers"'
dm_writer="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_writer" | grep -q '^AIRLOCK_DEV_MONITOR_SPOOL_WRITER_USER=monitor-writer$' \
   && printf '%s\n' "$dm_writer" | grep -q '^AIRLOCK_DEV_MONITOR_SPOOL_WRITER_GROUP=monitor-writers$'; then
  ok "dev-monitor: spool writer identity is configured by name, never numeric UID"
else
  bad "dev-monitor: spool writer identity exports"
fi

# Nested tables belong to their installer (`get a.b.c`), not to APP_DEFAULTS.
mk '[apps.publish]
[apps.publish.public_target]
mode = "local"
base_url = "https://doc.example.com"
public_dir = "/opt/airlock/share-public"
htpasswd_dir = "/opt/airlock/publish-gated-auth"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "keys: nested table allowed"; else bad "keys: nested table allowed"; fi

mk '[apps.dev-monitor]
external = true'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "keys: common 'external' allowed"; else bad "keys: common 'external' allowed"; fi

# paseo.version is a real key, and its default must stay EMPTY: a version string
# here would be exported and would override the installer's own pin forever.
mk '[apps.paseo]
version = "0.1.99"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "keys: paseo.version allowed"; else bad "keys: paseo.version allowed"; fi
mk '[apps.paseo]'
run "$TMP/t.toml" env paseo 2>/dev/null | grep -q "AIRLOCK_PASEO_VERSION=''" \
  && ok "paseo.version: defaults empty (installer pin wins)" || bad "paseo.version: default not empty"

# --- 11. retired keys: loud, targeted, but NOT fatal -------------------------
# They shipped in the example, so hard-failing would brick every box that copied
# it. The message has to correct what the operator believed the key was doing.
mk '[paths]
code_root = "/srv/code"
mount_exclude = ["snap"]
[apps.fileview]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "retired: mount_exclude does not fail"; else bad "retired: mount_exclude does not fail"; fi
msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
grep -q 'mount_exclude' <<<"$msg" && ok "retired: names mount_exclude" || bad "retired: names mount_exclude"
grep -qi 'never implemented' <<<"$msg" && ok "retired: says it never worked" || bad "retired: says it never worked"

# a retired key outside [paths] (mk() would duplicate the [auth] table, so build it here)
cat >"$TMP/t.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
read_open = true
[apps.hub]
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "retired: auth.read_open does not fail"; else bad "retired: auth.read_open does not fail"; fi
msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
grep -q 'read_open' <<<"$msg" && ok "retired: warns on auth.read_open" || bad "retired: warns on auth.read_open"

# a retired key one level deeper — apps.<app>.<key>. The two-token loop above cannot see it,
# and the app-key loops call anything they do not recognise a typo and die. Retiring
# apps.dev-monitor.skill_allow has to reach the same operator, with the same correction.
cat >"$TMP/t.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[paths]
code_root = "/srv/code"
[apps.hub]
[apps.dev-monitor]
skill_allow = "harness-gardener"
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "retired: apps.dev-monitor.skill_allow does not fail"; else bad "retired: apps.dev-monitor.skill_allow does not fail"; fi
msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
grep -q 'skill_allow' <<<"$msg" && ok "retired: names skill_allow" || bad "retired: names skill_allow"
grep -q 'prompt' <<<"$msg" && ok "retired: says the list was bypassable" || bad "retired: says the list was bypassable"
# --- 12. no scope warning is possible any more -------------------------------
# There used to be a heuristic warning here: code_root == $HOME plus collaborators
# meant handing over every dotfile. The key is gone and the root is always /, so
# the warning has no input to look at. What replaced it is a plain statement in
# SECURITY.md — the scope is the unix account, always. Assert the key's absence
# does not resurrect a gate: a collaborators box validates with no [paths] at all.
printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\ncollaborators = ["c@example.com"]\n[apps.hub]\n[apps.fileview]\n' >"$TMP/t.toml"
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "scope: fileview + collaborators validates with no paths key"; else bad "scope: fileview + collaborators validates with no paths key"; fi

# --- 13. airlock.toml.example is a copy-and-fill template ------------------
# README instructs an operator to fill in owner before preflight. Keep the
# template structurally valid (D-DEVTERM-9900 once left retired keys here).
example="$HERE/../airlock.toml.example"
sed 's/owner    = "me@example.com"/owner    = "owner@fixture.dev"/' "$example" >"$TMP/example-valid.toml"
if run "$TMP/example-valid.toml" validate >/dev/null 2>&1; then
  ok "example: filled owner validates"
else
  bad "example: filled owner validates — $(run "$TMP/example-valid.toml" validate 2>&1 | head -1)"
fi

# --- 14. sources: the one reader of ① (apps by origin + links) --------------
# The table that shipped in #199 with no test at all was replaced by two files and
# one reader. Every counterexample below is a shape a real file has: a personal
# file under $HOME, a company file in another clone, and a link file somebody has
# hand-edited into something TOML does not like.
#
# HOME is redirected because the personal links path is a fixed constant — the
# one place it is defined. That is deliberate (the file is box-local and outside
# any repo) and it is why the fixture, not the code, moves.
HOME_SAVE="$HOME"
trap 'HOME="$HOME_SAVE"; rm -rf "$TMP"' EXIT
HOME="$TMP/home"
mkdir -p "$HOME/.config/airlock" "$TMP/repo/apps/wiki-manager"

cat >"$TMP/repo/apps/wiki-manager/airlock-app.toml" <<'TOML'
contract = 1
id = "wiki-manager"
[tile]
label = "Wiki"
sub = "wiki PR review"
cat = "docs"
glyph = "app-wiki"
TOML

cat >"$TMP/repo/links.toml" <<'TOML'
[team-chat]
name = "Team Chat"
desc = "팀 채팅"
url = "https://chat.example.test/"
glyph = "app-chat"

[broken-https]
name = "broken-https"
url = "http://insecure.example.test/"

[nourl]
name = "no url"
TOML

cat >"$HOME/.config/airlock/links.toml" <<'TOML'
[remote-vm]
name = "remote vm"
desc = "VM console"
url = "https://vm.example.test/"
glyph = "app-vm"
icon = "not-a-url"

[team-chat]
name = "Personal chat"
url = "https://mine.example.test/"

[fileview]
name = "shadows an app id"
url = "https://shadow.example.test/
TOML

# Company offers are committed main, read via the engine's bare mirror.
# An invalid-encoding manifest is skipped alone, keeping all valid offers.
mkdir -p "$TMP/repo/apps/bad-encoding"
printf '\xff\xfe' >"$TMP/repo/apps/bad-encoding/airlock-app.toml"
export AIRLOCK_DATA_DIR="$TMP/data" AIRLOCK_FIXTURE_ROOT="$TMP"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" -c user.name=Fixture -c user.email=fixture@example.test add apps links.toml
git -C "$TMP/repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm "Company sources"
company_commit() {
  git -C "$TMP/repo" add apps links.toml
  git -C "$TMP/repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm "$1"
}

src() {   # a good config plus a body, with the Company source pointed at the fixture.
         # `[site] company_repo` is the ONE Company key (P3_ENGINE PR1, #856); a
         # second table here would be a second answer to the same question.
  printf '[site]\nname = "fixture"\ncompany_repo = "%s"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[paths]\ncode_root = "~/code"\n[apps.hub]\n[apps.fileview]\n' "$TMP/repo" >"$TMP/src.toml"
  printf '%s\n' "$1" >>"$TMP/src.toml"
  run "$TMP/src.toml" "${@:2}"
}

# 16 · a file that will not parse yields no links and ONE line on stderr; every
# other file is still read and webjson still answers 0. One company's broken
# links.toml must not be able to stop this box from installing or publishing.
printf '[broken\nname = "unterminated\n' >"$HOME/.config/airlock/links.toml"
brk="$(src '' sources 2>"$TMP/err")" && brk_rc=0 || brk_rc=$?
python3 - "$brk" <<'PYEOF' && ok "sources: a broken personal links file yields no links of its own" \
  || bad "sources: a broken personal links file yields no links of its own"
import json, sys
d = json.loads(sys.argv[1])
assert [r["id"] for r in d["links"]] == ["team-chat"], d["links"]
PYEOF
if [ "$brk_rc" = 0 ] && [ "$(grep -c 'skipping links in' "$TMP/err")" = 1 ] \
   && grep -q "$HOME/.config/airlock/links.toml" "$TMP/err" \
   && run "$TMP/src.toml" webjson >/dev/null 2>&1; then
  ok "sources: a broken links.toml is one stderr line and rc 0"
else
  bad "sources: a broken links.toml is one stderr line and rc 0"
fi
# A shipped id is a Public candidate already. Listing it under Personal too made
# every `sources` call print one duplicate warning per enabled app, which is noise
# a daily read does not get to produce.
src '' sources >"$TMP/clean.json" 2>"$TMP/clean-err"
python3 - "$TMP/clean.json" <<'PYEOF' && ok "sources: a shipped builtin is never also a Personal candidate" \
  || bad "sources: a shipped builtin is never also a Personal candidate"
import json, sys
d = json.load(open(sys.argv[1]))
public = {r["id"] for r in d["apps"]["public"]}
personal = {r["id"] for r in d["apps"]["personal"]}
assert not (public & personal), sorted(public & personal)
assert "fileview" in public, sorted(public)
PYEOF
# The regression is the duplicate, not the whole stderr channel — a file with a
# bad row is SUPPOSED to say so. What must never appear is "offered by both" for
# an id the two source lists already divide between them.
if ! grep -q 'offered by both' "$TMP/clean-err"; then
  ok "sources: the three origins never report the same id twice"
else
  bad "sources: the three origins never report the same id twice"
  grep 'offered by both' "$TMP/clean-err" | head -3
fi

# An id shared by an app is still dropped rather than offered twice.
cat >"$HOME/.config/airlock/links.toml" <<'TOML'
[remote-vm]
name = "remote vm"
desc = "VM console"
url = "https://vm.example.test/"
glyph = "app-vm"
icon = "not-a-url"

[team-chat]
name = "Personal chat"
url = "https://mine.example.test/"

[fileview]
name = "shadows an app id"
url = "https://shadow.example.test/"
TOML

out="$(src '' sources)"
python3 - "$out" "$TMP/repo" <<'PYEOF' && ok "sources: apps are grouped by origin and links carry theirs" \
  || bad "sources: apps are grouped by origin and links carry theirs"
import json, pathlib, sys
d = json.loads(sys.argv[1])
# 17 · a row whose url is missing or plain http is skipped alone; the other two
# links from the same file survive.
assert sorted(r["id"] for r in d["links"] if r["origin"] == "company") == ["team-chat"], d["links"]
# Company is shared (collaborators see company links, owner decision 2026-08-25)
# and Personal is owner-only — the audience is decided by the source, so no file
# has to declare one.
aud = {r["id"]: r["audience"] for r in d["links"]}
assert aud["team-chat"] == "shared" and aud["remote-vm"] == "owner", aud
# The icon that is not an https URL is dropped and the glyph beside it stays.
vm = next(r for r in d["links"] if r["id"] == "remote-vm")
assert "icon" not in vm and vm["glyph"] == "app-vm", vm
# 18 · an id shared with an app keeps ONE row, and the app wins.
ids = [r["id"] for r in d["links"]]
assert len(ids) == len(set(ids)), ids
assert "fileview" not in ids, ids
assert "fileview" in [r["id"] for r in d["apps"]["public"]], d["apps"]["public"]
# The company repo's apps are candidates, with their own origin.
wiki = d["apps"]["company"]
assert [r["id"] for r in wiki] == ["wiki-manager"] and wiki[0]["origin"] == "company", wiki
assert wiki[0]["glyph"] == "app-wiki" and wiki[0]["name"] == "Wiki", wiki
assert d["company_repo"] == pathlib.Path(sys.argv[2]).resolve().as_uri(), d["company_repo"]
PYEOF

# 18 · the same id from a Company repo and from a personal package keeps one row.
mkdir -p "$TMP/pkg"
printf 'contract = 1\nid = "wiki-manager"\n[tile]\nlabel = "Mine"\nglyph = "app-wiki"\n' \
  >"$TMP/pkg/airlock-app.toml"
printf '[site]\ncompany_repo = "%s"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[packages.wiki-manager]\npath = "%s"\n[apps.hub]\n[apps.wiki-manager]\n' \
  "$TMP/repo" "$TMP/pkg" >"$TMP/dup.toml"
seed_apps wiki-manager "$TMP/pkg"
dup="$(run "$TMP/dup.toml" sources 2>"$TMP/dup-err")"
python3 - "$dup" <<'PYEOF' && ok "sources: one id from both origins keeps the Company row" \
  || bad "sources: one id from both origins keeps the Company row"
import json, sys
d = json.loads(sys.argv[1])
rows = d["apps"]["company"] + d["apps"]["personal"]
assert [r["id"] for r in rows] == ["wiki-manager"], rows
assert rows[0]["origin"] == "company" and rows[0]["name"] == "Wiki", rows[0]
PYEOF
grep -q 'offered by both personal and company' "$TMP/dup-err" \
  && ok "sources: the dropped duplicate is named on stderr" \
  || bad "sources: the dropped duplicate is named on stderr"

rm -f "$AIRLOCK_STATE_DIR/installed-apps.json"

# A links file saved in the wrong encoding used to take the whole reader down with
# a UnicodeDecodeError traceback and rc=1 — the promise is that this file alone is
# skipped and every other source, and the projection, survive it.
printf '\xff\xfe\x00bad' >"$TMP/repo/links.toml"
company_commit 'invalid links encoding'
bin_wjs="$(src '' sources 2>"$TMP/bin-err")" && bin_rc=0 || bin_rc=$?
python3 - "$bin_wjs" <<'PYEOF' && ok "sources: a non-UTF-8 links file is skipped, not fatal" \
  || bad "sources: a non-UTF-8 links file is skipped, not fatal"
import json, sys
d = json.loads(sys.argv[1])
# The personal file was still read, and the company apps are still listed. The
# company file contributed nothing at all — including its team-chat, which the
# personal file also declares, so that one survives from there instead.
assert [r["id"] for r in d["links"]] == ["remote-vm", "team-chat"], d["links"]
assert [r["id"] for r in d["apps"]["company"]] == ["wiki-manager"], d["apps"]["company"]
PYEOF
if [ "$bin_rc" = 0 ] && grep -q 'not valid UTF-8' "$TMP/bin-err" \
   && src '' webjson >/dev/null 2>&1; then
  ok "sources: a non-UTF-8 links file keeps webjson at rc 0"
else
  bad "sources: a non-UTF-8 links file keeps webjson at rc 0"
fi

# Put the company file back — the assertions below read it.
cat >"$TMP/repo/links.toml" <<'TOML'
[team-chat]
name = "Team Chat"
desc = "팀 채팅"
url = "https://chat.example.test/"
glyph = "app-chat"

[broken-https]
name = "broken-https"
url = "http://insecure.example.test/"

[nourl]
name = "no url"
TOML

company_commit 'restore links'

# 15 · four ordinary states, all of them an empty Company menu at rc 0: no key at
# all, a path that does not exist, a directory with no apps/ and no links.toml,
# and the shape the key really takes — a git URL this reader does not clone.
printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n[apps.fileview]\n' \
  >"$TMP/nocompany.toml"
printf '[site]\ncompany_repo = "%s"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' \
  "$TMP/does-not-exist" >"$TMP/c-missing.toml"
printf '[site]\ncompany_repo = "%s"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' \
  "$TMP/pkg" >"$TMP/c-bare.toml"
printf '[site]\ncompany_repo = "file:///nonexistent/company.git"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' \
  >"$TMP/c-url.toml"
for cfg in "$TMP/nocompany.toml" "$TMP/c-missing.toml" "$TMP/c-bare.toml" "$TMP/c-url.toml"; do
  got="$(run "$cfg" sources 2>"$TMP/case-err")" && rc=0 || rc=$?
  python3 - "$got" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["apps"]["company"] == [], d["apps"]["company"]
assert not [r for r in d["links"] if r["origin"] == "company"], d["links"]
PYEOF
  if [ "$rc" = 0 ]; then
    ok "sources: $(basename "$cfg") is an empty Company menu, not an error"
  else
    bad "sources: $(basename "$cfg") is an empty Company menu, not an error (rc=$rc)"
  fi
done
# A git URL says why it produced nothing, so an empty Company menu is never a
# mystery. A URL is also never treated as a path.
grep -q 'Company source unavailable' "$TMP/case-err" \
  && ok "sources: an unavailable Company main reports the fetch failure" \
  || bad "sources: an unavailable Company main reports the fetch failure"
# A file URL reads the same pinned main through the engine mirror. An
# uncommitted working-tree edit cannot change an offer, and no source checkout
# or operator config/installation record is created by this read.
printf '[site]\ncompany_repo = "file://%s"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' \
  "$TMP/repo" >"$TMP/url-main.toml"
cp "$TMP/url-main.toml" "$TMP/url-main.before"
printf '\n# local uncommitted edit\n' >>"$TMP/repo/apps/wiki-manager/airlock-app.toml"
url_main="$(run "$TMP/url-main.toml" sources)"
python3 - "$url_main" "$TMP" <<'PYEOF' && ok "sources: URL main uses only the canonical bare mirror and preserves config/store" \
  || bad "sources: URL main uses only the canonical bare mirror and preserves config/store"
import json, pathlib, subprocess, sys
value, root = json.loads(sys.argv[1]), pathlib.Path(sys.argv[2])
assert [row["id"] for row in value["apps"]["company"]] == ["wiki-manager"]
assert [row["id"] for row in value["links"] if row["origin"] == "company"] == ["team-chat"]
mirror = root / "data/sources/company.git"
main = subprocess.check_output(["git", "-C", str(root / "repo"), "rev-parse", "main"], text=True).strip()
pinned = subprocess.check_output(["git", "-C", str(mirror), "rev-parse", "FETCH_HEAD"], text=True).strip()
assert pinned == main
assert (root / "url-main.toml").read_bytes() == (root / "url-main.before").read_bytes()
assert not (root / "state/installed-apps.json").exists()
assert sorted(path.name for path in (root / "data/sources").iterdir()) == ["company.git"]
assert not (root / "data/apps").exists()
PYEOF
# All Company local path spellings name the same repository URL. Explicit
# Personal --source directories retain their separate app-directory contract.
python3 - "$HERE/../bin/airlock-ledger" "$TMP/repo" <<'PYEOF' && ok "Company path spellings normalize to one repository URL" \
  || bad "Company path spellings normalize to one repository URL"
import os, pathlib, runpy, sys
engine = runpy.run_path(sys.argv[1])
repo = pathlib.Path(sys.argv[2]).resolve()
normalize = lambda value: engine["company_repo"]({"company_repo": value})
assert normalize(str(repo)) == repo.as_uri()
os.chdir(repo.parent)
assert normalize(repo.name) == repo.as_uri()
os.environ["HOME"] = str(repo.parent)
assert normalize("~/" + repo.name) == repo.as_uri()
os.environ["COMPANY_PATH_FIXTURE"] = str(repo)
assert normalize("$COMPANY_PATH_FIXTURE") == repo.as_uri()
for url in (repo.as_uri(), "https://example.test/company.git", "git@example.test:company.git", ""):
    assert normalize(url) == url
PYEOF
# The same read also preserves a pre-existing canonical installation record.
mkdir -p "$TMP/state"
printf '{}\n' >"$TMP/state/installed-apps.json"
cp "$TMP/state/installed-apps.json" "$TMP/installed.before"
if run "$TMP/url-main.toml" sources >"$TMP/url-existing.json" \
   && cmp -s "$TMP/state/installed-apps.json" "$TMP/installed.before" \
   && cmp -s "$TMP/url-main.toml" "$TMP/url-main.before"; then
  ok "sources: an existing installation record stays byte-identical"
else
  bad "sources: an existing installation record stays byte-identical"
fi
rm "$TMP/state/installed-apps.json"

# 🔴 One key, not two. `[site] company_repo` is the only Company declaration that
# means anything; a leftover `[company] repo` is ignored rather than honoured.
printf '[site]\ncompany_repo = "%s"\n[company]\nrepo = "/nonexistent/decoy"\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' \
  "$TMP/repo" >"$TMP/c-decoy.toml"
decoy="$(run "$TMP/c-decoy.toml" sources)"
python3 - "$decoy" <<'PYEOF' && ok "sources: the retired [company] table changes nothing" \
  || bad "sources: the retired [company] table changes nothing"
import json, sys
d = json.loads(sys.argv[1])
assert d["company_repo"].endswith("/repo"), d["company_repo"]
assert [r["id"] for r in d["apps"]["company"]] == ["wiki-manager"], d["apps"]["company"]
PYEOF

# The launcher reads links through webjson, not the owner API, because a
# collaborator has to see the company links too.
wjs="$(run "$TMP/src.toml" webjson)"
python3 - "$wjs" <<'PYEOF' && ok "sources: webjson projects links with link, external and tile" \
  || bad "sources: webjson projects links with link, external and tile"
import json, sys
a = json.loads(sys.argv[1])["apps"]
chat = a["team-chat"]
assert chat["link"] is True and chat["external"] is True, chat
assert chat["audience"] == "shared", chat
assert chat["tile"] == {"label": "Team Chat", "sub": "팀 채팅",
                        "path": "https://chat.example.test/", "glyph": "app-chat"}, chat["tile"]
# An app id that also appears in a links file stays an app: one id, one row.
assert "link" not in a["fileview"], a["fileview"]
PYEOF

# No shortcut table is read any more, and a leftover one is ignored rather than
# fatal: validate stays at rc 0 and nothing projects it.
# The header is assembled rather than written out: a literal retired table name in
# this file would make the card's own deletion grep match its own counterexample.
DOT="."
printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n[shortcuts%slegacy]\nlabel = "Legacy"\nurl = "https://legacy.example.test/"\ncat = "tools"\n' \
  "$DOT" >"$TMP/legacy.toml"
if run "$TMP/legacy.toml" validate >/dev/null 2>&1 \
   && ! run "$TMP/legacy.toml" webjson | grep -q legacy; then
  ok "sources: a leftover retired shortcut table validates and projects nothing"
else
  bad "sources: a leftover retired shortcut table validates and projects nothing"
fi
HOME="$HOME_SAVE"

# ---- hub inherits the account-surface keys still written under [apps.devterm] ----
# The surface moved to the platform; the operator's config did not. good.toml sets
# devterm.xai = true and nothing under hub, which is exactly the migrated-box shape.
hubenv="$(run "$TMP/good.toml" env hub 2>/dev/null)"
case "$hubenv" in *"AIRLOCK_HUB_XAI=true"*) ok "hub: inherits devterm.xai" ;;
  *) bad "hub: inherits devterm.xai ($(printf '%s' "$hubenv" | grep XAI))" ;; esac
sed -e 's|^font_size = 16$|font_size = 16\nfleet_store = "~/usage.json"|' "$TMP/good.toml" >"$TMP/inherit.toml"
case "$(run "$TMP/inherit.toml" env hub 2>/dev/null)" in
  *"AIRLOCK_HUB_FLEET_STORE='~/usage.json'"*) ok "hub: inherits devterm.fleet_store" ;;
  *) bad "hub: inherits devterm.fleet_store" ;; esac
sed -e 's|^\[apps.hub\]$|[apps.hub]\nxai = false|' "$TMP/good.toml" >"$TMP/hubwins.toml"
case "$(run "$TMP/hubwins.toml" env hub 2>/dev/null)" in
  *"AIRLOCK_HUB_XAI=false"*) ok "hub: an explicit hub value beats the devterm fallback" ;;
  *) bad "hub: an explicit hub value beats the devterm fallback" ;; esac


# Recorded membership/source consumer regressions (existing suite).
if python3 - "$HERE/.." <<'PY_CONFIG_MEMBERSHIP'
#!/usr/bin/env python3
"""Read-only engine hook/defaults fixtures; no live units or writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import sys
ROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="airlock-config-membership-") as scratch:
    base = Path(scratch)
    config = base / "config.toml"
    state = base / "state"
    state.mkdir()
    config.write_text(
        '[auth]\nprovider="tailscale"\nowner="fixture@test"\n'
        '[packages.publish]\npath=' + json.dumps(str(ROOT / "apps/publish")) + '\n'
    )
    env = dict(os.environ, AIRLOCK_ROOT=str(ROOT), AIRLOCK_CONFIG=str(config),
               AIRLOCK_STATE_DIR=str(state), AIRLOCK_DATA_DIR=str(base / "data"))
    for key in ("AIRLOCK_APP_ID", "AIRLOCK_APP_DIR", "AIRLOCK_CONFIG_SNAPSHOT",
                "AIRLOCK_CONFIG_SNAPSHOT_SHA256", "AIRLOCK_INSTALL_PKG_INFO_SHA256",
                "AIRLOCK_PKG_INFO", "AIRLOCK_SHIPPED_APPS_ROOT", "AIRLOCK_PROJECT_IDS",
                "AIRLOCK_CONFIG_BIN"):
        env.pop(key, None)

    def run(*args, extra=None):
        return subprocess.run(args, env=dict(env, **(extra or {})),
                              capture_output=True, text=True, timeout=30)

    def cfg(*args, extra=None):
        return run("python3", str(ROOT / "bin/airlock-config"), *args, extra=extra)

    before_config = config.read_bytes()
    # A registered candidate does not become installed by resolving defaults.
    result = cfg("get", "apps.publish.backend_port")
    assert result.returncode != 0, result.stdout
    hook = {"AIRLOCK_APP_ID": "publish", "AIRLOCK_APP_DIR": str(ROOT / "apps/publish")}
    result = cfg("get", "apps.publish.backend_port", extra=hook)
    assert result.returncode == 0 and result.stdout.strip() == "19922", (result.stdout, result.stderr)
    result = run("bash", "-c", 'source "$AIRLOCK_ROOT/install/lib.sh"; airlock_load publish; '
                 'test "$AIRLOCK_PUBLISH_BACKEND_PORT" = 19922', extra=hook)
    assert result.returncode == 0, (result.stdout, result.stderr)

    record = state / "installed-apps.json"
    record.write_text(json.dumps({"publish": {"repo": str(ROOT / "apps/publish"),
                                             "commit": "", "artifacts": []}}))
    before_record = record.read_bytes()
    result = cfg("env", "publish")
    assert result.returncode == 0 and "AIRLOCK_PUBLISH_BACKEND_PORT=19922" in result.stdout, (result.stdout, result.stderr)
    assert config.read_bytes() == before_config and record.read_bytes() == before_record

    config.write_text(config.read_text() + '[apps.publish]\nbackend_port=19929\n')
    result = cfg("get", "apps.publish.backend_port")
    assert result.returncode == 0 and result.stdout.strip() == "19929", (result.stdout, result.stderr)
    config.write_text(config.read_text() + 'backend_port=19930\n')
    result = cfg("validate")
    assert result.returncode != 0, (result.stdout, result.stderr)

print("PASS real airlock_load, installed defaults, candidate exclusion, explicit inputs, read bytes")

PY_CONFIG_MEMBERSHIP
then
  ok "config membership uses recorded installation and source identity"
else
  bad "config membership consumer regression"
fi

if python3 -B - "$HERE/.." <<'PY_GATE_CUT'
#!/usr/bin/env python3
"""Normal inputs that unrelated-source and preview gates used to reject."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from urllib.request import urlopen

ROOT = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as raw:
    base = Path(raw)
    (base / 'home').mkdir()
    (base / 'state').mkdir()
    selected = base / 'selected'
    selected.mkdir()
    package_id = 'Selected.App-' + 'x' * 40
    (selected / 'airlock-app.toml').write_text(f'contract=1\nid="{package_id}"\n[artifacts]\nrooted=["payload"]\n')
    broken = base / 'broken'
    broken.mkdir()
    (broken / 'airlock-app.toml').write_text('broken TOML =')
    config = base / 'airlock.toml'
    config.write_text('[auth]\nowner="fixture@test"\n[apps.hub]\n[apps.missing]\nvalue="operator input"\n')
    (base / 'state/installed-apps.json').write_text(json.dumps({
        'broken': {'repo': str(broken), 'commit': '', 'artifacts': []},
        'missing': {'repo': str(base / 'missing'), 'commit': '', 'artifacts': []},
    }))
    env = {**os.environ, 'HOME': str(base / 'home'), 'AIRLOCK_CONFIG': str(config),
           'AIRLOCK_STATE_DIR': str(base / 'state'), 'AIRLOCK_SHIPPED_APPS_ROOT': str(base / 'shipped')}
    def run(*args):
        result = subprocess.run([str(ROOT / 'bin/airlock-config'), *args], env=env,
                                text=True, capture_output=True, check=True)
        return result.stdout
    preview = json.loads(run('package-preview', str(selected)))
    assert preview['id'] == package_id and preview['installable'] is True, preview
    assert preview['package']['artifacts']['rooted'] == ['payload'], preview
    print('PASS C08: selected Personal preview ignores unrelated broken manifest and capability wording')
    with config.open('a') as handle:
        handle.write('[apps.' + json.dumps(package_id) + ']\nvalue="selected input"\n')
    selected_env = run('env', package_id)
    bash_env = subprocess.run(['bash', '-c', 'eval "$1"; printf %s "$AIRLOCK_SELECTED_APP_' + 'X' * 40 + '_VALUE"', 'bash', selected_env], text=True, capture_output=True, check=True)
    assert bash_env.stdout == 'selected input', bash_env
    print('PASS K01: upper-case long filename id with punctuation reaches the actual shell env consumer')
    assert run('get', 'apps.missing.value').strip() == 'operator input'
    assert 'AIRLOCK_MISSING_VALUE=' in run('env', 'missing')
    print('PASS C14: get/env retain explicit values when recorded source is absent')
    projection = json.loads(run('package-info', 'hub'))
    assert projection['order'] == ['hub'] and projection['packages'] == {}, projection
    # The real writer reads hub/core inputs, not every configured shipped app.
    fragments = base / 'confd/hub-locations.d'
    fragments.mkdir(parents=True)
    (fragments / (package_id + '.conf')).write_text('# fixture fragment\n')
    env['AIRLOCK_CONFD'] = str(base / 'confd')
    env['AIRLOCK_PROJECT_IDS'] = json.dumps(['hub', 'broken', 'missing', package_id])
    rendered = subprocess.run(['bash', str(ROOT / 'install/render-nginx.sh')], env=env, text=True, capture_output=True)
    assert rendered.returncode == 0, (rendered.stdout, rendered.stderr)
    assert 'server {' in rendered.stdout and (package_id + '.conf') in rendered.stdout, rendered
    observed = subprocess.run([str(ROOT / 'bin/airlock-config'), 'webjson'], env=env, text=True, capture_output=True)
    assert observed.returncode == 0 and set(json.loads(observed.stdout)['apps']) == {'hub', 'missing', package_id}, observed
    assert 'invalid TOML' in observed.stderr, observed.stderr
    hub = json.loads(run('json', 'hub'))
    assert set(hub['apps']) == {'hub'} and hub['apps']['hub']['nginx_port'] == 19902, hub
    assert run('plaintext-known').strip() == '19901'
    assert run('get', 'apps.' + package_id + '.value').strip() == 'selected input'
    for name in ('My App', 'Line\nApp', 'Star*App', '-sample'):
        with config.open('a') as handle:
            handle.write('[apps.' + json.dumps(name) + ']\nvalue="operator"\n')
        (fragments / (name + '.conf')).write_text('# exact fragment\n')
        env['AIRLOCK_PROJECT_IDS'] = json.dumps(['hub', name])
        assert run('get', 'apps.' + name + '.value').strip() == 'operator'
        assert set(json.loads(run('webjson'))['apps']) == {'hub', name}
        rendered = subprocess.run(['bash', str(ROOT / 'install/render-nginx.sh')], env=env, text=True, capture_output=True)
        assert rendered.returncode == 0, (name, rendered.stdout, rendered.stderr)
    env['AIRLOCK_APP_ID'], env['AIRLOCK_APP_DIR'] = package_id, str(selected)
    run('icon-stage', package_id)
    env.pop('AIRLOCK_APP_ID'); env.pop('AIRLOCK_APP_DIR')
    env.pop('AIRLOCK_PROJECT_IDS')
    print('PASS C09: selected core inputs and runtime projections ignore unrelated malformed app manifest')
    saved_env = env.copy()
    default_source = base / 'trailing-shipped'
    default_config = base / 'defaults.toml'
    default_config.write_text('[auth]\nowner="fixture@test"\n[apps.hub]\n')
    env.update(AIRLOCK_CONFIG=str(default_config), AIRLOCK_STATE_DIR=str(base / 'default-state'),
               AIRLOCK_SHIPPED_APPS_ROOT=str(default_source))
    env.pop('AIRLOCK_PROJECT_IDS', None)
    try:
        for name in ('Trailing ', 'Trailing\n', 'My App', 'Selected.App', 'Comma,App'):
            directory = default_source / name
            directory.mkdir(parents=True)
            (directory / 'airlock-app.toml').write_text(
                'contract=1\nid=' + json.dumps(name) + '\n[config.defaults]\nvalue="default"\n')
            with default_config.open('a') as handle:
                handle.write('[apps.' + json.dumps(name) + ']\n')
            assert json.loads(run('package-preview', str(directory)))['id'] == name
            assert run('get', 'apps.' + name + '.value').strip() == 'default'
            assert 'VALUE=default' in run('env', name)
            all_apps = json.loads(run('get', 'apps'))
            assert all_apps[name]['value'] == 'default' and all_apps[name]['audience'] == 'owner', all_apps
            generated = base / 'init.toml'
            generated.write_text(run('init', '--owner', 'fixture@test', '--apps', name))
            env['AIRLOCK_CONFIG'] = str(generated)
            run('validate')
            assert set(json.loads(run('json'))['apps']) == {'hub', name}
            env['AIRLOCK_CONFIG'] = str(default_config)
        generated.write_text(run('init', '--owner', 'fixture@test', '--apps',
                                 'My App, Selected.App', '--apps', 'Comma,App'))
        env['AIRLOCK_CONFIG'] = str(generated)
        run('validate')
        assert set(json.loads(run('json'))['apps']) == {'hub', 'My App', 'Selected.App', 'Comma,App'}
        env['AIRLOCK_CONFIG'] = str(default_config)
        assert run('get', 'auth.owner').strip() == 'fixture@test'
    finally:
        env.clear(); env.update(saved_env)
    print('PASS actual trailing-space/LF paths and full apps defaults remain intact')
    # Public/Personal launcher and store URLs must fetch the unchanged staged
    # filename, including URL delimiters in the app's actual directory name.
    icon_config = base / 'icons.toml'
    public_ids = ('Hash#App', 'Query?App')
    personal_ids = ('Personal#App', 'Personal?App')
    icon_config.write_text('[auth]\nowner="fixture@test"\n' +
                          ''.join('[apps.' + json.dumps(name) + ']\n'
                                  for name in (*public_ids, *personal_ids)))
    icon_state = base / 'icon-state'
    icon_state.mkdir()
    installed = {}
    for name in (*public_ids, *personal_ids):
        directory = base / ('icon-shipped' if name in public_ids else 'icon-personal') / name
        directory.mkdir(parents=True)
        (directory / 'airlock-app.toml').write_text(
            'contract=1\nid=' + json.dumps(name) + '\n[tile]\nlabel="Fixture"\nicon="icon.svg"\n')
        (directory / 'icon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
        if name in personal_ids:
            installed[name] = {'repo': str(directory), 'commit': '', 'artifacts': []}
    (icon_state / 'installed-apps.json').write_text(json.dumps(installed))
    webroot = base / 'icon-webroot'
    webroot.mkdir()
    icon_env = {**env, 'AIRLOCK_CONFIG': str(icon_config), 'AIRLOCK_STATE_DIR': str(icon_state),
                'AIRLOCK_SHIPPED_APPS_ROOT': str(base / 'icon-shipped'), 'AIRLOCK_WEBROOT': str(webroot)}
    def icon_run(*args):
        return subprocess.run([str(ROOT / 'bin/airlock-config'), *args], env=icon_env,
                              text=True, capture_output=True, check=True).stdout
    for name in (*public_ids, *personal_ids):
        icon_run('icon-stage', name)
        assert (webroot / 'assets/apps' / name / 'icon.svg').is_file()
    launcher = json.loads(icon_run('webjson'))['apps']
    sources = json.loads(icon_run('sources'))['apps']
    class QuietHTTP(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    with ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHTTP, directory=str(webroot))) as server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for origin, names in (('public', public_ids), ('personal', personal_ids)):
                candidates = {row['id']: row for row in sources[origin]}
                for name in names:
                    url = launcher[name]['tile']['icon']
                    assert ('%23' if '#' in name else '%3F') in url, (name, url)
                    assert candidates[name]['icon'] == url, (name, candidates[name], url)
                    with urlopen(f'http://127.0.0.1:{server.server_port}' + url) as response:
                        assert response.status == 200 and response.read().startswith(b'<svg')
        finally:
            server.shutdown()
            worker.join()
    print('PASS icon URLs: real HTTP 200 for percent-encoded Public/Personal launcher and store icons')

    # Git's default quotePath output must not become a candidate's identity.
    company = base / 'company'
    company.mkdir()
    company_ids = ('Plain', 'Quote"App', '한국앱', 'Tab\tApp', 'Line\nApp', *public_ids)
    for name in company_ids:
        directory = company / 'apps' / name
        directory.mkdir(parents=True)
        (directory / 'airlock-app.toml').write_text(
            'contract=1\nid=' + json.dumps(name, ensure_ascii=False) +
            '\n[tile]\nlabel="Fixture"\nicon="icon.svg"\n')
    def git(*args):
        return subprocess.run(['git', '-C', str(company), *args], env=icon_env,
                              text=True, capture_output=True, check=True).stdout
    git('init', '-q')
    git('config', 'core.quotePath', 'true')
    git('add', 'apps')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@test', 'commit', '-qm', 'Company fixtures')
    sha = git('rev-parse', 'HEAD').strip()
    candidate_code = '''
from importlib.machinery import SourceFileLoader
from pathlib import Path
import json, sys
config = SourceFileLoader('_icon_fixture_config', sys.argv[1]).load_module()
print(json.dumps(config._company_app_candidates(Path(sys.argv[2]), sys.argv[3])))
'''
    candidate_rows = subprocess.run(['python3', '-B', '-c', candidate_code,
                                     str(ROOT / 'bin/airlock-config'), str(company), sha],
                                    env=icon_env, text=True, capture_output=True, check=True)
    candidates = {row['id']: row for row in json.loads(candidate_rows.stdout)}
    assert set(candidates) == set(company_ids), (candidates, candidate_rows.stderr)
    for name in public_ids:
        assert candidates[name]['icon'] == launcher[name]['tile']['icon'], candidates[name]
    print('PASS Company git: quoted/Unicode/tab/newline IDs and encoded icon URLs retain exact identities')

PY_GATE_CUT
then ok "selected configuration accepts unrelated failures and absent source input";
else bad "selected configuration gate-cut counterexamples"; fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
