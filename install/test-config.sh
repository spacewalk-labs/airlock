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
owner = "me@example.com"
collaborators = ["a@example.com", "b@example.com"]
[paths]
code_root = "~/code"
[branding]
product = "Airlock"
[apps.hub]
[apps.devterm]
font_size = 16
xai = true
[apps.markwand]
TOML

cat >"$TMP/badprovider.toml" <<'TOML'
[auth]
provider = "basic"
owner = "me@example.com"
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
owner = "me@example.com"
[apps.hub]
[apps.devterm]
backend_port = 9910
TOML
if run "$TMP/portclash.toml" validate >/dev/null 2>&1; then bad "validate: rejects port collision"; else ok "validate: rejects port collision"; fi

# 3c. plaintext wiring: enabled apps with a plaintext port -> their redirect port
pt="$(run "$TMP/good.toml" plaintext 2>/dev/null | tr '\t' ':' | sort | tr '\n' ',')"
[ "$pt" = "hub:9999:18806," ] && ok "plaintext: listen -> redirect" || bad "plaintext: got '$pt'"
# D-DEVTERM-9900 retired the shipped 9900 default. Known ports are hub
# plus any still-declared plaintext_redirect (none on shipped devterm).
known="$(run "$TMP/good.toml" plaintext-known 2>/dev/null | sort -n | tr '\n' ',')"
[ "$known" = "9999," ] && ok "plaintext-known: hub only" || bad "plaintext-known: got '$known'"

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
[ "$apps" = "devterm,hub,markwand," ] && ok "apps: enabled list" || bad "apps: got '$apps'"

# App names cross a line-oriented shell API. A quoted TOML key may contain an
# escaped newline, so both validation and the direct `apps` command must reject
# it instead of turning one table into two enabled installer names.
cat >"$TMP/bad-app-name.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
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
owner = "me@example.com"
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
echo "$env" | grep -q "AIRLOCK_OWNER=me@example.com" && ok "env: owner" || bad "env: owner"
echo "$env" | grep -q "AIRLOCK_COLLABORATORS=a@example.com,b@example.com" && ok "env: collaborators joined" || bad "env: collaborators"
echo "$env" | grep -q "AIRLOCK_DEVTERM_FONT_SIZE=16" && ok "env: app override" || bad "env: app override"
echo "$env" | grep -q "AIRLOCK_DEVTERM_TTYD_PORT=9911" && ok "env: app default merged" || bad "env: app default"
echo "$env" | grep -q "AIRLOCK_DEVTERM_XAI=true" && ok "env: xAI app override" || bad "env: xAI app override"
# site name with spaces must be shell-safe for eval
( eval "$env"; [ "$AIRLOCK_SITE_NAME" = "My Dev Hub" ] ) && ok "env: eval-safe quoting" || bad "env: quoting"

# 6. env for a disabled app fails
if run "$TMP/good.toml" env orca >/dev/null 2>&1; then bad "env: rejects disabled app"; else ok "env: rejects disabled app"; fi

# 7. get with default fallback + dotted key
[ "$(run "$TMP/good.toml" get auth.owner 2>/dev/null)" = "me@example.com" ] && ok "get: dotted" || bad "get: dotted"
[ "$(run "$TMP/good.toml" get apps.devterm.ttyd_port 2>/dev/null)" = "9911" ] && ok "get: default merged" || bad "get: default merged"

# 8. code_root expands ~ — to the real home, not merely to something without a '~'
[ "$(run "$TMP/good.toml" get paths.code_root 2>/dev/null)" = "$HOME/code" ] \
  && ok "get: ~ expanded to \$HOME" || bad "get: ~ expanded to \$HOME"

# --- 9. code_root is mandatory for markwand, never guessed -------------------
# markwand hands this directory to markserv (read) and filebrowser (write), and
# the hub gate admits collaborators — so an installer must not pick it silently.
mk() { printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\n[apps.hub]\n%s\n' "$1" >"$TMP/t.toml"; }

mk '[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "code_root: rejects missing"; else ok "code_root: rejects missing"; fi
# (capture, don't pipe: `run` exits non-zero here and pipefail would mask grep)
msg="$(run "$TMP/t.toml" validate 2>&1)"
grep -q 'code_root' <<<"$msg" && ok "code_root: names the key" || bad "code_root: names the key"
grep -q '~/code' <<<"$msg" && ok "code_root: gives the migration" || bad "code_root: gives the migration"

mk '[paths]
code_root = ""
[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "code_root: rejects empty"; else ok "code_root: rejects empty"; fi

mk '[paths]
code_root = "   "
[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "code_root: rejects whitespace"; else ok "code_root: rejects whitespace"; fi

mk '[paths]
code_root = false
[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "code_root: rejects non-string"; else ok "code_root: rejects non-string"; fi

mk '[paths]
code_root = "code"
[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "code_root: rejects relative"; else ok "code_root: rejects relative"; fi

# ...but only markwand needs it; a box without markwand is unaffected.
mk '[apps.devterm]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "code_root: optional without markwand"; else bad "code_root: optional without markwand"; fi

# --- 10. unknown key = typo = die (a typo would silently keep the default) ---
mk '[paths]
code_root = "/srv/code"
nonesuch = "x"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown [paths] key"; else ok "keys: rejects unknown [paths] key"; fi

mk '[apps.dev-monitor]
message = true'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown app key"; else ok "keys: rejects unknown app key"; fi

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
smtp_to = "owner@example.com"
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
    && printf '%s\n' "$dm_smtp" | grep -q '^AIRLOCK_DEV_MONITOR_SMTP_TO=owner@example.com$' \
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
owner = "me@example.com"
colaborators = ["c@example.com"]
[apps.hub]
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects [auth] typo"; else ok "keys: rejects [auth] typo"; fi
mk '[branding]
prodcut = "X"'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects [branding] typo"; else ok "keys: rejects [branding] typo"; fi

# An unknown SECTION is a typo too: [brandng] would leave the product name at its
# default while the config reads as if it had been set.
printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\n[apps.hub]\n[brandng]\nproduct = "Acme"\n' >"$TMP/t.toml"
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "keys: rejects unknown section"; else ok "keys: rejects unknown section"; fi

# A malformed section must produce an actionable error — not a traceback, and not
# a pass. Both halves are asserted: absence of a traceback alone would also hold
# if the validator wrongly succeeded.
for bad_shape in 'auth = 1' 'apps = 1' 'site = 1' 'branding = false'; do
  printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\n[apps.hub]\n' >"$TMP/t.toml"
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
code_root = "~nosuchuser1234/code"
[apps.markwand]'
msg="$(run "$TMP/t.toml" validate 2>&1)"
grep -q 'Traceback' <<<"$msg" && bad "code_root: traceback on bad ~user" || ok "code_root: no traceback on bad ~user"
grep -q 'cannot expand' <<<"$msg" && ok "code_root: actionable ~user error" || bad "code_root: actionable ~user error"

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
[apps.markwand]'
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "retired: mount_exclude does not fail"; else bad "retired: mount_exclude does not fail"; fi
msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
grep -q 'mount_exclude' <<<"$msg" && ok "retired: names mount_exclude" || bad "retired: names mount_exclude"
grep -qi 'never implemented' <<<"$msg" && ok "retired: says it never worked" || bad "retired: says it never worked"

# a retired key outside [paths] (mk() would duplicate the [auth] table, so build it here)
cat >"$TMP/t.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
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
owner = "me@example.com"
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
owner = "me@example.com"
[paths]
code_root = "/srv/code"
[apps.hub]
[apps.dev-monitor]
skil_allow = "x"
TOML
if run "$TMP/t.toml" validate >/dev/null 2>&1; then bad "retired: a typo beside it still fails"; else ok "retired: a typo beside it still fails"; fi

# --- 12. wide code_root + collaborators = warning (heuristic, not a gate) ----
printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\ncollaborators = ["c@example.com"]\n[paths]\ncode_root = "%s"\n[apps.hub]\n[apps.markwand]\n' "$HOME" >"$TMP/t.toml"
if run "$TMP/t.toml" validate >/dev/null 2>&1; then ok "wide root: warns, does not fail"; else bad "wide root: warns, does not fail"; fi
run "$TMP/t.toml" validate 2>&1 >/dev/null | grep -qi 'home directory' \
  && ok "wide root: warning names the risk" || bad "wide root: warning missing"
# no collaborators -> no warning (a solo box may legitimately use the home dir).
# Capture rather than pipe: under pipefail a failing validate would satisfy `|| ok`.
printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\n[paths]\ncode_root = "%s"\n[apps.hub]\n[apps.markwand]\n' "$HOME" >"$TMP/t.toml"
if run "$TMP/t.toml" validate >/dev/null 2>&1; then
  msg="$(run "$TMP/t.toml" validate 2>&1 >/dev/null)"
  grep -qi 'home directory' <<<"$msg" && bad "wide root: warns without collaborators" \
    || ok "wide root: silent without collaborators"
else
  bad "wide root: solo home dir must still validate"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
