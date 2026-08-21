#!/usr/bin/env bash
# Render the Airlock nginx site to stdout from airlock.toml.
#
# Emits http{}-context content (maps + the hub server + include hooks). The
# installer writes it where the box's nginx http{} includes it; `tailscale serve`
# fronts the loopback hub port (that ingress is what makes identity trustworthy —
# see SECURITY.md). Per-app fragments are dropped by each app's installer into:
#   <confd>/hub-locations.d/*.conf   -> same-origin subpath apps (inside hub server)
#   <confd>/servers.d/*.conf         -> separate-port owner gates (http level)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/gate/nginx-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_config validate >/dev/null    # fail-closed before we render anything

eval "$(airlock_config env hub)"
HUB_PORT="${AIRLOCK_HUB_NGINX_PORT:?hub nginx_port missing}"
REDIRECT_PORT="${AIRLOCK_HUB_REDIRECT_PORT:?hub redirect_port missing}"
HUB_HTTPS_PORT="${AIRLOCK_HUB_HTTPS_PORT:-443}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
IDENT="$(ident_var "$AIRLOCK_IDENTITY_HEADER")"

# hub is reachable by owner + collaborators; privileged apps stay owner-only.
hub_logins=("$AIRLOCK_OWNER")
if [ -n "${AIRLOCK_COLLABORATORS:-}" ]; then
  IFS=',' read -r -a _collab <<<"$AIRLOCK_COLLABORATORS"
  hub_logins+=("${_collab[@]}")
fi

emit_connection_upgrade_map
emit_identity_map hub_ok "${hub_logins[@]}"
emit_identity_map owner_ok "$AIRLOCK_OWNER"

# Plaintext entrance -> canonical https. `tailscale serve --http=<http_port>`
# points at this loopback port (never at the hub server), so the hub is only ever
# SERVED over TLS. Redirect to the FQDN literal: the short tailnet hostname has no
# cert, and the launcher builds every tile from location.hostname — landing on the
# short name would hand out https links the browser cannot verify.
# ts_fqdn die()s (exit) when tailscale is absent/down, which kills the command
# substitution's subshell before any `|| true` inside it could run — so catch the
# status on the ASSIGNMENT, or `set -e` would abort the whole render.
FQDN="${AIRLOCK_TS_FQDN:-}"
[ -n "$FQDN" ] || FQDN="$(ts_fqdn 2>/dev/null)" || FQDN=""
# No short-hostname fallback: that name has no certificate, so a redirect to it
# would hand the browser a TLS error instead of the hub. If the FQDN cannot be
# measured (tailscaled restarting, LocalAPI hiccup), refuse to render rather than
# bake a broken entrance. AIRLOCK_TS_FQDN covers CI and offline renders.
[ -n "$FQDN" ] || die "could not determine the tailnet FQDN, so the plaintext \
entrance cannot be pointed at a certificate-valid https URL. Is tailscaled up \
('tailscale status')? For an offline render, set AIRLOCK_TS_FQDN=<box>.<tailnet>.ts.net."
CANON="https://$FQDN"
[ "$HUB_HTTPS_PORT" = 443 ] || CANON="$CANON:$HUB_HTTPS_PORT"
emit_https_redirect "$REDIRECT_PORT" "$CANON"

# D7/F14 (stage 4, unconditional — child 4/P3 flip): /whoami always carries
# "role". Stage 3 gated this on "some configured package declares [audience]"
# so a built-in-only render stayed byte-identical to the pre-packages output;
# that render no longer exists to protect — devterm/orca/code-server/paseo
# all declare [audience] now (F13a/F14 folds this in, byte-equal to today's
# output). Role derives from the SAME owner_ok map the gates use: one
# identity chokepoint, no second comparison.
printf 'map $owner_ok $airlock_role { 1 "owner"; default "collaborator"; }\n'
ROLE_FIELD=',"role":"$airlock_role"'

sed -e "s/@@PORT@@/${HUB_PORT}/g" \
    -e "s|@@WEBROOT@@|${WEBROOT}|g" \
    -e "s/@@IDENT@@/${IDENT}/g" \
    -e "s|@@ROLE@@|${ROLE_FIELD}|g" \
    -e "s|@@CONFD@@|${CONFD}|g" <<'NGINX'
server {
    listen 127.0.0.1:@@PORT@@;
    server_name _;
    root @@WEBROOT@@;
    index index.html;

    # ==== Identity gate — the single chokepoint ====
    # Gate at the SERVER level, not per-location: a server-context `if ... return`
    # runs in the server rewrite phase before any location is chosen, so it covers
    # every location uniformly — including the subpath-app fragments included below
    # (an app can never forget its guard). This deliberately does NOT use a
    # per-location `if` + `try_files`, which do not gate reliably together.
    # owner + collaborators pass ($hub_ok); everyone else gets the wrong-owner page.
    if ($hub_ok = 0) { return 403; }
    # No `=`: keep the honest 403 status AND serve the wrong-owner page body
    # (browsers render an error_page body regardless of status). This matches the
    # separate-port gates, which also 403 a denied identity.
    error_page 403 @denied;
    location @denied {
        root @@WEBROOT@@;
        rewrite ^ /wrong-owner.html break;
    }

    # frontend reads its own (gate-verified) identity here
    location = /whoami {
        default_type application/json;
        return 200 '{"login":"$@@IDENT@@"@@ROLE@@}';
    }

    # shared "return to Airlock" widget — served at a stable /airlock-return.js so
    # same-origin subpath apps (markwand, notepad, publish, dev-monitor) can load
    # it. Separate-port gates serve their own copy (see emit_owner_gate). The
    # orchestrator copies hub/assets/ (incl. airlock-return.js) to <webroot>/assets.
    location = /airlock-return.js {
        alias @@WEBROOT@@/assets/airlock-return.js;
        default_type application/javascript;
        add_header Cache-Control "no-cache" always;
        access_log off;
    }

    # Browsers auto-probe /favicon.ico at the root regardless of the <link rel=icon>
    # in index.html; without this it falls into the SPA fallback below and returns
    # index.html as text/html, so the tab shows a generic/stale icon instead of the
    # brand mark. Serve the PNG brand favicon here (browsers accept a PNG at .ico).
    location = /favicon.ico {
        alias @@WEBROOT@@/assets/favicon.png;
        default_type image/png;
        add_header Cache-Control "no-cache" always;
        access_log off;
    }

    # the entrance itself
    location / {
        try_files $uri $uri/ /index.html;
    }

    # same-origin subpath apps (markwand, publish, dev-monitor, notepad) drop
    # location fragments here as they are installed. They inherit the server-level
    # gate above — fragments are plain proxies, no per-location guard needed.
    include @@CONFD@@/hub-locations.d/*.conf;
}

# separate-port owner gates (devterm, code-server, orca, paseo) drop server
# fragments here as they are installed.
include @@CONFD@@/servers.d/*.conf;
NGINX
