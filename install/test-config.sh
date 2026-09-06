#!/usr/bin/env bash
# Tests for bin/airlock-config (T2). No live services needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/../bin/airlock-config"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Isolate the installed-state ledger: a developer's real ledger must never
# leak into (or fail) these tests. See docs/design/app-package-contract.md D6.
export AIRLOCK_STATE_DIR="$TMP/state"

pass=0 fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

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

cat >"$TMP/badprovider.toml" <<'TOML'
[auth]
provider = "basic"
owner = "owner@fixture.dev"
[apps.hub]
TOML

cat >"$TMP/noowner.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "nobody"
[apps.hub]
TOML

run() { AIRLOCK_CONFIG="$1" python3 "$CFG" "${@:2}"; }

# 1. valid config validates
if run "$TMP/good.toml" validate >/dev/null 2>&1; then ok "validate: good"; else bad "validate: good"; fi

# 2. non-tailscale provider fails closed
if run "$TMP/badprovider.toml" validate >/dev/null 2>&1; then bad "validate: rejects non-tailscale"; else ok "validate: rejects non-tailscale"; fi

# 3. bad owner fails
if run "$TMP/noowner.toml" validate >/dev/null 2>&1; then bad "validate: rejects bad owner"; else ok "validate: rejects bad owner"; fi

# 3b. a port collision fails closed. Two nginx servers on one loopback port both
# match `server_name _`, so nginx silently keeps the first — if a redirect_port
# landed on a gate_port, the plaintext ingress would serve content again.
cat >"$TMP/portclash.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.devterm]
backend_port = 19911
TOML
if run "$TMP/portclash.toml" validate >/dev/null 2>&1; then bad "validate: rejects port collision"; else ok "validate: rejects port collision"; fi

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

# App names cross a line-oriented shell API. A quoted TOML key may contain an
# escaped newline, so both validation and the direct `apps` command must reject
# it instead of turning one table into two enabled installer names.
cat >"$TMP/bad-app-name.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps."paseo\nlocal"]
TOML
if run "$TMP/bad-app-name.toml" validate >/dev/null 2>&1; then
  bad "apps: validate rejects multiline name"
else
  ok "apps: validate rejects multiline name"
fi
if run "$TMP/bad-app-name.toml" apps >/dev/null 2>&1; then
  bad "apps: listing rejects multiline name"
else
  ok "apps: listing rejects multiline name"
fi

# A newline in the MIDDLE is rejected by any anchor; a TRAILING one was not. Python's `$`
# matches immediately before a final newline, so `paseo\n` satisfied APP_NAME_RE and only
# the fullmatch at the call site kept it out — exactly the "one table name becomes two
# installer names" value the comment above that pattern exists to reject.
cat >"$TMP/trailing-newline-app-name.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps."paseo\n"]
TOML
if run "$TMP/trailing-newline-app-name.toml" validate >/dev/null 2>&1; then
  bad "apps: validate rejects a trailing newline in a name"
else
  ok "apps: validate rejects a trailing newline in a name"
fi
if run "$TMP/trailing-newline-app-name.toml" apps >/dev/null 2>&1; then
  bad "apps: listing rejects a trailing newline in a name"
else
  ok "apps: listing rejects a trailing newline in a name"
fi
# The two cases above pass with or without the anchor, because the call site is a
# fullmatch — they lock the behaviour, not the pattern. This one fails the moment
# APP_NAME_RE ends at `$` again, which is the regression worth naming.
if python3 - "$CFG" <<'PYCHECK'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('airlock_config', sys.argv[1])
spec = importlib.util.spec_from_loader('airlock_config', loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
sys.exit(0 if module.APP_NAME_RE.match('paseo\n') is None else 1)
PYCHECK
then
  ok "apps: APP_NAME_RE is anchored at end-of-string, not before a trailing newline"
else
  bad "apps: APP_NAME_RE is anchored at end-of-string, not before a trailing newline"
fi

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

# --- 10. unknown key = typo = die (a typo would silently keep the default) ---
mk '[paths]
code_root = "/srv/code"
nonesuch = "x"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown [paths] key"; else ok "keys: rejects unknown [paths] key"; fi

mk '[apps.dev-monitor]
message = true'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown app key"; else ok "keys: rejects unknown app key"; fi

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
slack_webhook_urgent_env = "DEVMON_URGENT"
slack_webhook_routine_env = "DEVMON_ROUTINE"
slack_webhook_env = "DEVMON_LEGACY"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  ok "dev-monitor: canonical webhook keys and legacy alias are accepted"
else
  bad "dev-monitor: canonical webhook keys and legacy alias are accepted"
fi
dm_warning="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
if [ "$(printf '%s\n' "$dm_warning" | grep -c 'apps.dev-monitor.slack_webhook_env is deprecated' || true)" = 1 ] \
    && printf '%s\n' "$dm_warning" | grep -q 'apps.dev-monitor.slack_webhook_urgent_env' \
    && printf '%s\n' "$dm_warning" | grep -q '2026-09-07'; then
  ok "dev-monitor: legacy alias emits one dated config warning"
else
  bad "dev-monitor: legacy alias emits one dated config warning"
fi
dm_env_warning="$(run "$TMP/t.toml" env dev-monitor 2>&1 >/dev/null)"
if [ "$(printf '%s\n' "$dm_env_warning" | grep -c 'apps.dev-monitor.slack_webhook_env is deprecated' || true)" = 1 ]; then
  ok "dev-monitor: direct env export emits one alias warning"
else
  bad "dev-monitor: direct env export emits one alias warning"
fi
dm_env="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_env" | grep -q '^AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV=DEVMON_URGENT$' \
    && printf '%s\n' "$dm_env" | grep -q '^AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE_ENV=DEVMON_ROUTINE$' \
    && printf '%s\n' "$dm_env" | grep -q '^AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ENV=DEVMON_LEGACY$'; then
  ok "dev-monitor: webhook config keys export distinct names"
else
  bad "dev-monitor: webhook config keys export distinct names"
fi

mk '[apps.dev-monitor]
slack_webhook_urgent_env = "DEVMON_URGENT"
slack_webhook_routine_env = "DEVMON_ROUTINE"
slack_webhook_env = "   "'
dm_clean="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
if ! printf '%s\n' "$dm_clean" | grep -q 'slack_webhook_env is deprecated'; then
  ok "dev-monitor: canonical-only and whitespace-empty alias are warning-free"
else
  bad "dev-monitor: canonical-only and whitespace-empty alias are warning-free"
fi

# The email lane's keys, asserted the same way the webhook keys are: declared in the manifest
# means accepted and exported under this package's own prefix, and a plausible neighbour that
# is NOT declared still dies. Without the second half this only proves the config layer is
# permissive, which would let install.sh drift away from the manifest unnoticed.
mk '[apps.dev-monitor]
smtp_host = "relay.example.com"
smtp_port = 587
smtp_from = "dev-monitor@example.com"
smtp_to = "owner@fixture.dev"
smtp_user = "devmon"
smtp_password_env = "DEVMON_SMTP_PASSWORD"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  ok "dev-monitor: smtp keys are accepted once the manifest declares them"
else
  bad "dev-monitor: smtp keys are accepted once the manifest declares them"
fi
dm_smtp="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_HOST=relay.example.com$' \
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_PORT=587$' \
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_FROM=dev-monitor@example.com$' \
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_TO=owner@fixture.dev$' \
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_USER=devmon$' \
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_PASSWORD_ENV=DEVMON_SMTP_PASSWORD$'; then
  ok "dev-monitor: smtp config keys export the names install.sh reads"
else
  bad "dev-monitor: smtp config keys export the names install.sh reads"
fi
# The password itself is never a config key — only the name of the variable holding it.
if printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_PASSWORD='; then
  bad "dev-monitor: smtp password must not be a config key"
else
  ok "dev-monitor: smtp password is named, never held, in config"
fi
mk '[apps.dev-monitor]
smtp_password = "hunter2"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  bad "dev-monitor: an undeclared smtp_password key must be rejected"
else
  ok "dev-monitor: an undeclared smtp_password key is rejected"
fi
mk '[apps.dev-monitor]
smtp_port = "587"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  bad "dev-monitor: smtp_port must be a number, not a string"
else
  ok "dev-monitor: smtp_port must be a number, not a string"
fi

# The roster path (P4): a bare path, not a credential, so no *_env indirection — declared
# means accepted and exported under this package's own prefix, same as every other
# config.defaults key.
mk '[apps.dev-monitor]
roster_path = "/home/example/.local/state/roster/roster.json"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  ok "dev-monitor: roster_path is accepted once the manifest declares it"
else
  bad "dev-monitor: roster_path is accepted once the manifest declares it"
fi
dm_roster="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_roster" | grep -q '^AIRLOCK_DEV_MONITOR_ROSTER_PATH=/home/example/.local/state/roster/roster.json$'; then
  ok "dev-monitor: roster_path exports the name install.sh reads"
else
  bad "dev-monitor: roster_path exports the name install.sh reads"
fi
mk '[apps.dev-monitor]'
dm_roster_default="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_roster_default" | grep -q "^AIRLOCK_DEV_MONITOR_ROSTER_PATH=''$"; then
  ok "dev-monitor: roster_path defaults to empty — no roster on this box is supported"
else
  bad "dev-monitor: roster_path defaults to empty — no roster on this box is supported"
fi

mk '[apps.dev-monitor]
compat_env_path = "/srv/legacy/dev-monitor.env"'
dm_compat="$(run "$TMP/t.toml" env dev-monitor 2>/dev/null)"
if printf '%s\n' "$dm_compat" | grep -q '^AIRLOCK_DEV_MONITOR_COMPAT_ENV_PATH=/srv/legacy/dev-monitor.env$'; then
  ok "dev-monitor: compat_env_path is explicit config, never a public hard-coded path"
else
  bad "dev-monitor: compat_env_path exports the name install.sh reads"
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

mk '[apps.dev-monitor]
extras = ["a", "b"]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown non-scalar key"; else ok "keys: rejects unknown non-scalar key"; fi

# Nested tables belong to their installer (`get a.b.c`), not to APP_DEFAULTS.
mk '[apps.publish]
[apps.publish.public_target]
mode = "local"
base_url = "https://doc.example.com"
public_dir = "/opt/airlock/share-public"
htpasswd_dir = "/opt/airlock/publish-gated-auth"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "keys: nested table allowed"; else bad "keys: nested table allowed"; fi

mk '[apps.publish]
[apps.publish.public_target]
htpasswd_file = "/tmp/obsolete"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects removed htpasswd_file"; else ok "keys: rejects removed htpasswd_file"; fi

mk '[apps.dev-monitor]
external = true'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "keys: common 'external' allowed"; else bad "keys: common 'external' allowed"; fi

# The non-app sections are closed too: a mistyped `collaborators` would otherwise
# read as "access granted" while granting nothing.
cat >"$TMP/t.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
colaborators = ["c@example.com"]
[apps.hub]
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects [auth] typo"; else ok "keys: rejects [auth] typo"; fi
mk '[branding]
prodcut = "X"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects [branding] typo"; else ok "keys: rejects [branding] typo"; fi

# An unknown SECTION is a typo too: [brandng] would leave the product name at its
# default while the config reads as if it had been set.
printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n[brandng]\nproduct = "Acme"\n' >"$TMP/t.toml"
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown section"; else ok "keys: rejects unknown section"; fi

# A malformed section must produce an actionable error — not a traceback, and not
# a pass. Both halves are asserted: absence of a traceback alone would also hold
# if the validator wrongly succeeded.
for bad_shape in 'auth = 1' 'apps = 1' 'site = 1' 'branding = false'; do
  printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' >"$TMP/t.toml"
  printf '%s\n' "$bad_shape" | cat - "$TMP/t.toml" >"$TMP/t2.toml"; mv "$TMP/t2.toml" "$TMP/t.toml"
  msg="$(run "$TMP/t.toml" validate 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q 'Traceback' <<<"$msg"; then
    ok "types: '$bad_shape' -> actionable error"
  else
    bad "types: '$bad_shape' (rc=$rc)"
  fi
done

# A nested table must be one we know: a typo in the table NAME reads as "feature
# not configured", and a nested table on a scalar key shadows it silently.
mk '[apps.publish]
[apps.publish.public_targte]
mode = "local"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects nested-table typo"; else ok "keys: rejects nested-table typo"; fi
mk '[apps.dev-monitor]
[apps.dev-monitor.messages]
enabled = true'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects table shadowing a scalar"; else ok "keys: rejects table shadowing a scalar"; fi

# `~nosuchuser` is an easy typo and pathlib raises on it — must be actionable.
mk '[paths]
wiki = "~nosuchuser1234/wiki"
[apps.fileview]'
msg="$(run "$TMP/t.toml" validate 2>&1)"
grep -q 'Traceback' <<<"$msg" && bad "paths: traceback on bad ~user" || ok "paths: no traceback on bad ~user"
grep -q 'cannot expand' <<<"$msg" && ok "paths: actionable ~user error" || bad "paths: actionable ~user error"

# An unknown app TABLE is fatal (child 4/P3: the local/custom-app escape
# hatch retired along with the built-in registry — every nine built-ins are
# shipped packages now, so an [apps.X] that resolves to neither hub nor a
# package can only be a typo or a missing [packages.X]/manifest).
mk '[apps.mytool]
backend_port = 19999'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: unknown app table is fatal"; else ok "keys: unknown app table is fatal"; fi
msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
grep -q 'apps.mytool' <<<"$msg" && ok "keys: unknown app table names the offending table" || bad "keys: unknown app table names the offending table"

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
# negative control: a typo next to it is still fatal — the retirement is one key, not an opening
cat >"$TMP/t.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[paths]
code_root = "/srv/code"
[apps.hub]
[apps.dev-monitor]
skil_allow = "x"
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "retired: a typo beside it still fails"; else ok "retired: a typo beside it still fails"; fi

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
# template structurally valid (D-DEVTERM-9900 once left retired keys here), but
# ensure an unedited copy never looks ready for installation.
example="$HERE/../airlock.toml.example"
sed 's/owner    = "me@example.com"/owner    = "owner@fixture.dev"/' "$example" >"$TMP/example-valid.toml"
if run "$TMP/example-valid.toml" validate >/dev/null 2>&1; then
  ok "example: filled owner validates"
else
  bad "example: filled owner validates — $(run "$TMP/example-valid.toml" validate 2>&1 | head -1)"
fi

example_msg="$(run "$example" validate 2>&1)"
example_rc=$?
if [ "$example_rc" -ne 0 ] \
    && grep -Fq "documentation placeholder ('me@example.com')" <<<"$example_msg"; then
  ok "example: unedited owner is refused"
else
  bad "example: unedited owner is refused — $example_msg"
fi

# --- 14. [shortcuts.<id>] ---------------------------------------------------
# The table shipped in #199 with no test at all — every assertion below is the
# first one it has had. A shortcut is the one tile whose href leaves this origin
# and whose target nobody here authorises, so the fields that keep it honest
# (https, a real glyph, a heading the launcher can draw) are exactly the fields
# a silent regression would take away.
sc() {   # a good config plus the shortcut body passed in
  printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[paths]\ncode_root = "~/code"\n[apps.hub]\n[apps.fileview]\n%s\n' "$1" >"$TMP/sc.toml"
}
SC_OK='[shortcuts.team-chat]
label = "Team Chat"
url = "https://chat.example.com/"
cat = "comms"
glyph = "app-chat"'

sc "$SC_OK"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then ok "shortcut: minimal table validates"; else bad "shortcut: minimal table validates"; fi

# http is not a style preference here: the browser blocks it as mixed content on
# an https launcher, and the attempt arms HSTS on the target host.
sc "${SC_OK/https:\/\/chat/http://chat}"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects http url"; else ok "shortcut: rejects http url"; fi
# A hub subpath is a package's shape, not a shortcut's — accepting it would make
# the two tables interchangeable and the [tile] path rule bypassable.
sc "${SC_OK/https:\/\/chat.example.com\//\/chat\/}"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects relative url"; else ok "shortcut: rejects relative url"; fi
sc "${SC_OK/app-chat/}"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects empty glyph"; else ok "shortcut: rejects empty glyph"; fi
# Non-empty was never enough: an invented symbol id validated, installed, and
# smoked green, then rendered a blank tile (2026-08-25: app-docs, app-files,
# app-system, app-notes). The glyph must exist in hub/index.html's sprite.
# Positive control on both sides: the good config above already proves a real
# id (app-chat) passes; here the invented one must fail, and the error must
# name the shortcut, the bad glyph, and the candidates.
sc "${SC_OK/app-chat/app-docs}"
gout="$(run "$TMP/sc.toml" validate 2>&1)"
if [ $? -ne 0 ] && grep -Fq 'does not exist in the hub sprite' <<<"$gout" \
   && grep -Fq 'team-chat' <<<"$gout" && grep -Fq 'app-docs' <<<"$gout" \
   && grep -Fq 'Available glyphs:' <<<"$gout"; then
  ok "shortcut: rejects glyph absent from the sprite, naming id+glyph+candidates"
else
  bad "shortcut: rejects glyph absent from the sprite — $(head -1 <<<"$gout")"
fi
# A near-miss gets a did-you-mean so the fix is one read away.
sc "${SC_OK/app-chat/app-chatt}"
gout="$(run "$TMP/sc.toml" validate 2>&1)"
if [ $? -ne 0 ] && grep -Fq 'Did you mean' <<<"$gout" && grep -Fq 'app-chat' <<<"$gout"; then
  ok "shortcut: near-miss glyph suggests the close sprite id"
else
  bad "shortcut: near-miss glyph suggests the close sprite id — $(head -1 <<<"$gout")"
fi
sc "${SC_OK/comms/chat}"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects unknown cat"; else ok "shortcut: rejects unknown cat"; fi
sc "$SC_OK
icon = \"icons/chat.png\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects unknown key"; else ok "shortcut: rejects unknown key"; fi
# One id renders one tile. A collision would have the launcher draw whichever of
# the two webjson wrote last, which is neither an error nor a choice anyone made.
sc "${SC_OK/team-chat/fileview}"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects id colliding with an app"; else ok "shortcut: rejects id colliding with an app"; fi

# `section` — the launcher heading. Optional, defaulted in webjson so the
# launcher never has to invent one.
sc "$SC_OK
section = \"Shared services\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then ok "shortcut: section validates"; else bad "shortcut: section validates"; fi
wjs="$(run "$TMP/sc.toml" webjson 2>/dev/null)"
grep -q '"section": "Shared services"' <<<"$wjs" && ok "shortcut: webjson carries the declared section" \
  || bad "shortcut: webjson carries the declared section"
sc "$SC_OK"
wjs="$(run "$TMP/sc.toml" webjson 2>/dev/null)"
grep -q '"section": "Shortcuts"' <<<"$wjs" && ok "shortcut: webjson defaults the section" \
  || bad "shortcut: webjson defaults the section"
# The launcher tells a viewer that these tiles leave the gate, and it decides
# that from `shortcut`, not from `external` — a packaged app on its own port is
# external too and is still behind the gate.
grep -q '"shortcut": true' <<<"$wjs" && ok "shortcut: webjson marks the tile as a shortcut" \
  || bad "shortcut: webjson marks the tile as a shortcut"
# `audience` — who the launcher shows this tile to. The regression this pins is
# the one that shipped: the shortcut entry carried NO audience key at all, and
# airlockTileVisible reads a missing audience as owner-only (#249), so the five
# company shortcuts were invisible to collaborators and nothing in the config
# could say otherwise. Owner decision 2026-08-25 made them shared.
grep -q '"audience": "shared"' <<<"$wjs" && ok "shortcut: webjson defaults audience to shared" \
  || bad "shortcut: webjson defaults audience to shared"
sc "$SC_OK
audience = \"owner\""
wjs="$(run "$TMP/sc.toml" webjson 2>/dev/null)"
grep -q '"audience": "owner"' <<<"$wjs" && ok "shortcut: webjson carries a declared owner audience" \
  || bad "shortcut: webjson carries a declared owner audience"
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then ok "shortcut: audience=owner validates"; else bad "shortcut: audience=owner validates"; fi
sc "$SC_OK
audience = \"everyone\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects unknown audience"; else ok "shortcut: rejects unknown audience"; fi
# The default is the whole point of the change, so it is asserted where the
# launcher reads it, not only where validate accepts it: a shortcut that says
# nothing must reach collaborators.
sc "$SC_OK"
wjs="$(run "$TMP/sc.toml" webjson 2>/dev/null)"
python3 - "$wjs" <<'PYEOF' && ok "shortcut: silent shortcut resolves shared, package silence still resolves owner" \
  || bad "shortcut: silent shortcut resolves shared, package silence still resolves owner"
import json, sys
d = json.loads(sys.argv[1])
sc = d["apps"]["team-chat"]
assert sc["audience"] == "shared", sc
# and the package rule is untouched in the same output
fv = d["apps"]["fileview"]
assert fv["audience"] == "owner", fv
PYEOF
sc "$SC_OK
section = \"\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects empty section"; else ok "shortcut: rejects empty section"; fi
# Two headings differing only by an invisible character render as one name over
# two grids — the screen cannot show the difference, so validate must.
sc "$SC_OK
section = \"Shared\tservices\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects control char in section"; else ok "shortcut: rejects control char in section"; fi
sc "$SC_OK
section = \"$(printf 'x%.0s' $(seq 33))\""
if run "$TMP/sc.toml" validate >/dev/null 2>&1; then bad "shortcut: rejects over-long section"; else ok "shortcut: rejects over-long section"; fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
