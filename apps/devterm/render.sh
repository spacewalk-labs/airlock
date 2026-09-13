# shellcheck shell=bash
# apps/devterm/render.sh — sourceable render library (child 4, P1a
# extract-verify-swap). Functions only, no top-level execution. Each unit
# function body is a VERBATIM copy of the heredoc it replaces, proven
# byte-identical to the inline text by install/test-render-parity.sh before
# any write site moves (P1b).
#
# The nginx fragment is not a heredoc in install.sh (it composes
# gate/nginx-lib.sh's emit_owner_gate + emit_https_redirect), so
# render_devterm_nginx is a thin wrapper around those calls — included for a
# single P1b write-site swap.

# render_devterm_exec_shim RESOLVED_ABSOLUTE_TARGET
# The installer writes this to a same-directory temporary file and atomically renames
# it over the legacy terminal command. shlex.quote keeps unusual but valid absolute
# paths safe without leaving an AIRLOCK_* variable for an interactive shell to resolve.
render_devterm_exec_shim() {
  python3 - "$1" <<'PY'
import shlex
import sys
print("#!/bin/sh")
print('exec %s "$@"' % shlex.quote(sys.argv[1]))
PY
}

# render_devterm_unit_ttyd DEVTERM_LANG TTYD_PORT TTYD_BIN FONT_SIZE
render_devterm_unit_ttyd() {
  local DEVTERM_LANG="$1" TTYD_PORT="$2" TTYD_BIN="$3" FONT_SIZE="$4"
  cat <<UNIT
[Unit]
Description=airlock devterm — ttyd PTY backend (127.0.0.1:${TTYD_PORT})
After=network.target

[Service]
Environment=LANG=${DEVTERM_LANG}
Environment=LC_CTYPE=${DEVTERM_LANG}
# -a: pass ?arg= to the shell as its session name; -W: writable; -P 2: fast dead-conn detect
ExecStart=${TTYD_BIN} -i 127.0.0.1 -p ${TTYD_PORT} -P 2 -W -a -t fontSize=${FONT_SIZE} %h/.local/bin/devterm-shell
KillMode=process
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
}

# render_devterm_unit_gate BACKEND_PORT gate_env PY GATE_PY
# gate_env is the pre-built multi-line "Environment=K=V\n..." block (built by
# install.sh's add_env helper — unchanged, still outside this library).
render_devterm_unit_gate() {
  local BACKEND_PORT="$1" gate_env="$2" PY="$3" GATE_PY="$4"
  cat <<UNIT
[Unit]
Description=airlock devterm-gate — custom client + API, proxies to ttyd (127.0.0.1:${BACKEND_PORT})
After=network.target airlock-devterm.service
Wants=airlock-devterm.service

[Service]
Type=simple
${gate_env}ExecStart=${PY} ${GATE_PY}
# KillMode=process, same reason as the ttyd unit: the gate starts a detached
# \`codex login --device-auth\` that must outlive a redeploy. setsid does not leave the
# cgroup, so the default (control-group) kills the pending login while the user is
# entering the code on their phone — and the old credential is already backed out.
KillMode=process
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
}

# render_devterm_fleet_read DOMAIN MAP_VAR [OWNER_LOGIN...]
# Prints the http-context map half of the read-open (render_devterm_fleet_locations
# prints the other half). A servers.d fragment is included at http level, so a `map`
# here is legal and needs no edit to the platform renderer.
#
# 🔴 Four routes, and the boundary is "does it emit a secret", not "is it a GET".
# /claude-status, /claude-usage, /claude-usage-store and /codex-usage report WHICH
# account this box is logged in as and how much of its quota is left. No token, no
# refresh token, no hash. /acct-alert is a GET too and is NOT here: it is the owner's
# own alert state. Everything that writes — /acct-login-*, /acct-switch,
# /acct-remove — stays behind `location /`; /secret-* has its own owner-only locations
# (proxied to the platform surface).
#
# Per-location guards, not a wider map on `location /`: an nginx `if` covers only the
# location it is written in, so opening these four cannot leak into the terminal, the
# secret drop or the panel. The trade is that a route added later is closed by
# default, which is the direction we want to fail in.
#
# The map is anchored `^[^@]+@<domain>$`. An unanchored match would accept
# "owner@evil.example.com-attacker.invalid", and the empty header (no identity at
# all) must fall to `default 0` rather than matching a bare suffix.
#
# The owner logins are listed exactly as well, and nginx prefers an exact match over
# a regex. Without them an owner whose login sits outside the fleet domain would be
# 403ed on their OWN box's status route by a key meant only to widen access.
render_devterm_fleet_read() {
  local DOMAIN="$1" MAPVAR="$2"; shift 2
  local ident escaped login
  ident="$(ident_var "${AIRLOCK_IDENTITY_HEADER:?render_devterm_fleet_read: AIRLOCK_IDENTITY_HEADER not set}")"
  DOMAIN="${DOMAIN#@}"
  # Validated here, the one place it reaches nginx: the value is pasted into a regex
  # and a config file, so anything outside a hostname's character set is refused
  # rather than escaped into something that still parses.
  if ! printf '%s' "$DOMAIN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
    printf 'render_devterm_fleet_read: refusing malformed fleet_read_domain %s\n' "$DOMAIN" >&2
    return 1
  fi
  escaped="${DOMAIN//./\\.}"
  printf 'map $%s $%s {\n    default 0;\n' "$ident" "$MAPVAR"
  for login in "$@"; do
    [ -n "$login" ] && printf '    "%s" 1;\n' "$login"
  done
  printf '    "~*^[^@]+@%s$" 1;\n}\n' "$escaped"
}

# render_devterm_fleet_locations MAP_VAR BACKEND_PORT — the location half (see above).
# QUOTED heredoc + sed placeholders, the convention this file and gate/nginx-lib.sh
# state: $http_host is an nginx runtime variable and must reach the config verbatim.
render_devterm_fleet_locations() {
  local MAPVAR="$1" BACKEND_PORT="$2"
  local path
  printf '\n    # fleet read-open (fleet_read_domain) — account STATE, never a credential.\n'
  for path in /claude-status /claude-usage /claude-usage-store /codex-usage; do
    sed -e "s|@@PATH@@|${path}|g" \
        -e "s|@@UPSTREAM@@|127.0.0.1:${BACKEND_PORT}|g" \
        -e "s/@@MAP@@/${MAPVAR}/g" <<'NGINX'
    location = @@PATH@@ {
        if ($@@MAP@@ = 0) { return 403; }
        proxy_pass http://@@UPSTREAM@@;
        proxy_http_version 1.1;
        # $http_host for the same reason location / uses it (see emit_owner_gate).
        # No proxy_set_header for the identity: nginx forwards the client's headers
        # unchanged, which is how the gate gets the value it re-checks.
        proxy_set_header Host $http_host;
        # 60s, not location /'s 86400s: these are probes, not a terminal WebSocket,
        # and /claude-usage can sit on a slow upstream API call.
        proxy_read_timeout 60s;
    }
NGINX
  done
}

# render_devterm_nginx GATE_PORT BACKEND_PORT [ACCOUNT_PANEL_DIR] [FLEET_READ_DOMAIN] [ACCOUNTS_PORT]
#
# FLEET_READ_DOMAIN (optional, [apps.devterm] fleet_read_domain) opens the four
# account-state read routes to any identity in that domain, so a central console can
# poll this box. Empty — the shipped default — emits nothing at all, and the gate stays
# owner-only end to end. See render_devterm_fleet_read below for why these four and
# why a per-location guard rather than widening the map on `location /`.
# Trailing args beyond those are ignored: D-DEVTERM-9900 retired the plaintext redirect.
#
# ACCOUNT_PANEL_DIR (optional) is the platform's account-panel asset directory in the
# webroot. When given, this gate serves panel.html and accounts.js from THERE instead
# of from devterm's own web root — the panel is a platform asset (ACCT_OWN), and an
# alias keeps one deployed copy rather than a per-app duplicate that can drift. Same
# arrangement emit_owner_gate already uses for airlock-return.js, with one difference
# that matters: these two carry their own owner guard. An nginx `if` only covers the
# location it is written in, so a location added beside `location /` inherits nothing
# from it, and the account panel is not a thing to hand to a passing collaborator.
# The same directory carries the platform secret drop UI (secretdrop.js), aliased the
# same way: devterm's page loads it and injects only terminal delivery + session target.
#
# ACCOUNTS_PORT (optional) is the platform account/secret surface's loopback port
# (bin/airlock-accounts-api). When given, the three secret-drop routes on this origin are
# proxied THERE, so the in-terminal drop stays same-origin while the guard, the store and
# the TTL remain the platform's — devterm's gate has no secret handler at all
# (docs/tasks/active/platform-secret-drop.md). Exact locations, each with its own owner
# guard, for the reason above.
render_devterm_nginx() {
  local GATE_PORT="$1" BACKEND_PORT="$2" PANEL_DIR="${3:-}" FLEET_DOMAIN="${4:-}"
  local ACCOUNTS_PORT="${5:-}"
  local extra="" path
  case "$ACCOUNTS_PORT" in
    '') ;;
    *[!0-9]*) printf 'render_devterm_nginx: refusing non-numeric accounts port %s\n' "$ACCOUNTS_PORT" >&2
              return 1 ;;
  esac
  if [ -n "$PANEL_DIR" ]; then
    extra="$(mktemp)"
    # QUOTED heredoc + sed placeholder, the convention gate/nginx-lib.sh states and the
    # reason it states it: an unquoted heredoc here would hand `$owner_ok` to the shell,
    # and a backtick in one of these deleted three words from every rendered paseo unit
    # in 2026-08.
    sed -e "s|@@PANEL_DIR@@|${PANEL_DIR}|g" >"$extra" <<'NGINX'

    # platform account panel (hub/assets/accounts) — served here, not by the hub,
    # because accounts.js fetches root-absolute paths on the API's own origin.
    location = /panel.html {
        if ($owner_ok = 0) { return 403; }
        alias @@PANEL_DIR@@/panel.html;
        default_type text/html;
        add_header Cache-Control "no-cache" always;
    }
    location = /accounts.js {
        if ($owner_ok = 0) { return 403; }
        alias @@PANEL_DIR@@/accounts.js;
        default_type application/javascript;
        add_header Cache-Control "no-cache" always;
    }
    # platform secret drop UI — devterm's index.html loads it; the terminal injects only
    # delivery and the session's target box.
    location = /secretdrop.js {
        if ($owner_ok = 0) { return 403; }
        alias @@PANEL_DIR@@/secretdrop.js;
        default_type application/javascript;
        add_header Cache-Control "no-cache" always;
    }
NGINX
  fi
  if [ -n "$ACCOUNTS_PORT" ]; then
    [ -n "$extra" ] || extra="$(mktemp)"
    printf '\n    # platform secret drop API (bin/airlock-accounts-api) — never devterm-gate.\n' >>"$extra"
    for path in /secret-put /secret-list /secret-del; do
      sed -e "s|@@PATH@@|${path}|g" -e "s|@@ACCTPORT@@|${ACCOUNTS_PORT}|g" >>"$extra" <<'NGINX'
    location = @@PATH@@ {
        if ($owner_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@ACCTPORT@@;
        proxy_http_version 1.1;
        # $http_host: the platform's same-origin guard compares the browser Origin
        # (always ported) against Host, exactly as devterm's own gate does.
        proxy_set_header Host $http_host;
        proxy_read_timeout 30s;
    }
NGINX
    done
  fi
  if [ -n "$FLEET_DOMAIN" ]; then
    [ -n "$extra" ] || extra="$(mktemp)"
    render_devterm_fleet_locations devterm_fleet_ok "$BACKEND_PORT" >>"$extra"
  fi
  echo "# devterm owner gate — generated by apps/devterm/install.sh"
  if [ -n "$FLEET_DOMAIN" ]; then
    # AIRLOCK_OWNER is the same comma-separated list emit_identity_map takes for
    # $owner_ok; splitting it here keeps one source for who the owner is.
    local _owners
    IFS=',' read -r -a _owners <<<"${AIRLOCK_OWNER:-}"
    render_devterm_fleet_read "$FLEET_DOMAIN" devterm_fleet_ok "${_owners[@]}" || return 1
  fi
  emit_owner_gate "$GATE_PORT" "127.0.0.1:${BACKEND_PORT}" owner_ok "" "" "$extra"
  [ -n "$extra" ] && rm -f "$extra"
  return 0
}
