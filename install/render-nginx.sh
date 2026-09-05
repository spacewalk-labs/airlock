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
ACCOUNTS_PORT="${AIRLOCK_HUB_ACCOUNTS_PORT:?hub accounts_port missing}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
IDENT="$(ident_var "$AIRLOCK_IDENTITY_HEADER")"

# publish's dedicated document-view port is always present when the app is
# enabled. Its broader tailnet-member tier is not: the shipped default is false,
# which selects the exact same owner+collaborators map as the hub. A box opts in
# with [apps.publish] tailnet_view = true. Only Tailscale Serve may reach this
# loopback listener, so a non-empty identity header is an authenticated tailnet
# identity rather than a client assertion (SECURITY.md, Trust model facts 1-3).
PUBLISH_ENABLED=false
PUBLISH_GATE="hub_ok"
PUBLISH_HTTPS_PORT=""
PUBLISH_GATE_PORT=""
PUBLISH_SHARE_DIR=""
if airlock_config apps | grep -qx publish; then
  eval "$(airlock_config env publish)"
  PUBLISH_ENABLED=true
  PUBLISH_HTTPS_PORT="${AIRLOCK_PUBLISH_HTTPS_PORT:?publish https_port missing}"
  PUBLISH_GATE_PORT="${AIRLOCK_PUBLISH_GATE_PORT:?publish gate_port missing}"
  PUBLISH_SHARE_DIR="${AIRLOCK_PUBLISH_SHARE_DIR:?publish share_dir missing}"
  PUBLISH_SHARE_DIR="${PUBLISH_SHARE_DIR/#\~/$HOME}"
  if [ "${AIRLOCK_PUBLISH_TAILNET_VIEW:-false}" = true ]; then
    PUBLISH_GATE="tailnet_ok"
  fi
fi

# hub is reachable by owner + collaborators; privileged apps stay owner-only.
hub_logins=("$AIRLOCK_OWNER")
if [ -n "${AIRLOCK_COLLABORATORS:-}" ]; then
  IFS=',' read -r -a _collab <<<"$AIRLOCK_COLLABORATORS"
  hub_logins+=("${_collab[@]}")
fi

emit_connection_upgrade_map
emit_identity_map hub_ok "${hub_logins[@]}"
emit_identity_map owner_ok "$AIRLOCK_OWNER"
if [ "$PUBLISH_ENABLED" = true ]; then
  printf 'map $%s $tailnet_ok {\n    "" 0;\n    default 1;\n}\n' "$IDENT"
fi

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
    -e "s/@@ACCTPORT@@/${ACCOUNTS_PORT}/g" \
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
    # No `=`: keep the honest 403 status. The server-rewrite gate runs before a
    # location is chosen, so a request with hub_ok=0 cannot reach any other 403
    # source. That makes hub_ok an exact selector here: denied identities keep the
    # wrong-owner page, while a location/filesystem 403 reached by an allowed
    # identity gets an honest resource-error explanation instead.
    error_page 403 @denied;
    location @denied {
        root @@WEBROOT@@;
        default_type text/html;
        if ($hub_ok = 1) {
            return 403 '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Resource forbidden</title></head><body><main><h1>Airlock cannot serve this resource</h1><p>Your access to this Airlock was verified, but the requested resource is forbidden.</p><p>This is not an Airlock ownership error. Check the resource access rules and every file and directory in its path.</p></main></body></html>';
        }
        rewrite ^ /wrong-owner.html break;
    }

    # frontend reads its own (gate-verified) identity here
    location = /whoami {
        default_type application/json;
        return 200 '{"login":"$@@IDENT@@"@@ROLE@@}';
    }

    # shared "return to Airlock" widget — served at a stable /airlock-return.js so
    # same-origin subpath apps (fileview, notepad, publish, dev-monitor) can load
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

    # ==== platform account surface (ACCT_SURFACE) ====
    # 🔴 Two things make this location's own guard load-bearing, and neither is obvious
    # from looking at the server block above.
    #
    # 1. The server-level gate is $hub_ok, which admits COLLABORATORS. An account
    #    surface is the owner's alone, so the audience claim has to be made here. An app
    #    package would make the same claim twice — once in its manifest's [audience] and
    #    once in its location (SECURITY.md) — but the hub is platform core and has no
    #    manifest, so this line is the ONLY declaration. That is why the test that
    #    removes it and expects red is not optional decoration: it is the second half of
    #    the contract, standing in for the manifest that does not exist.
    #    Precedent for the shape: apps/learning/render.sh, apps/notes/bin/render.py,
    #    apps/fileview/render.sh.
    #
    # 2. A prefix location, not one location per route. Eighteen locations would mean
    #    eighteen copies of the guard, and one omission fails OPEN. It also keeps the
    #    surface out of `location /` below, whose `try_files ... /index.html` answers an
    #    unknown path with index.html and HTTP 200 — so a route the backend does not
    #    serve would arrive at the caller as HTML that fails to parse as JSON, with
    #    nothing anywhere saying why.
    #
    # The trailing slash on proxy_pass strips the prefix, so the backend keeps serving
    # the same route names it serves today (/accounts, /acct-alert, ...) and the frontend
    # only gains a base. Dropping it would forward /airlock-accounts/accounts to a
    # backend that has never heard of the prefix and 404 every request
    # (apps/learning/render.sh says the same thing about the same character).
    location /airlock-accounts/ {
        if ($owner_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@ACCTPORT@@/;
        proxy_http_version 1.1;
        # $http_host, not $host: $host drops the port, and an upstream that compares the
        # browser's Origin against Host then sees a mismatch on every same-origin
        # request. That exact defect answered the owner's own page with 403 in #318.
        proxy_set_header Host $http_host;
        proxy_read_timeout 300s;
        # The account surface is never a cached answer: usage numbers and login state
        # are the whole point of asking.
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }

    # the entrance itself
    location / {
        try_files $uri $uri/ /index.html;
    }

    # same-origin subpath apps (fileview, publish, dev-monitor, notepad) drop
    # location fragments here as they are installed. They inherit the server-level
    # gate above — fragments are plain proxies, no per-location guard needed.
    include @@CONFD@@/hub-locations.d/*.conf;
}

NGINX

if [ "$PUBLISH_ENABLED" = true ]; then
  PUBLISH_SHARE_SED="$(printf '%s' "$PUBLISH_SHARE_DIR" | sed 's/[\\&|]/\\&/g')"
  sed -e "s/@@PORT@@/${PUBLISH_GATE_PORT}/g" \
      -e "s/@@HTTPS_PORT@@/${PUBLISH_HTTPS_PORT}/g" \
      -e "s/@@GATE@@/${PUBLISH_GATE}/g" \
      -e "s|@@WEBROOT@@|${WEBROOT}|g" \
      -e "s|@@SHARE@@|${PUBLISH_SHARE_SED}|g" <<'NGINX'
# ==== Publish dedicated document-view gate ====
# tailscale serve --https=@@HTTPS_PORT@@ targets this loopback server.
server {
    listen 127.0.0.1:@@PORT@@;
    server_name _;

    # The selector is hub_ok unless this box explicitly enables tailnet_view.
    # Keep it at server rewrite phase so every document and asset path shares
    # one guard and a later location cannot forget it.
    if ($@@GATE@@ = 0) { return 403; }
    error_page 403 @publish_denied;
    location @publish_denied {
        root @@WEBROOT@@;
        default_type text/html;
        if ($@@GATE@@ = 1) {
            return 403 '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Resource forbidden</title></head><body><main><h1>Airlock cannot serve this resource</h1><p>Your access to this Airlock was verified, but the requested resource is forbidden.</p><p>This is not an Airlock ownership error. Check the resource access rules and every file and directory in its path.</p></main></body></html>';
        }
        rewrite ^ /wrong-owner.html break;
    }

    # Read-only document surface at the ROOT of this port: the whole link is
    # <fqdn>:<port>/<name>.html. The hub needs the /publish/files/ prefix because
    # the share dir shares that origin with every other app; this port serves
    # nothing else, so the prefix is kept only so links minted against the hub
    # keep opening. /_assets/ is a directory inside the share dir and needs no
    # location of its own. The manager UI and /publish/api/ are not proxied here,
    # so they 404 like any other path that is not a file in the share dir.
    location / {
        root @@SHARE@@;
        autoindex on;
        add_header Cache-Control "no-cache" always;
        # Same injection the hub's /publish/files/ carries (apps/publish/render.sh):
        # a reader inside a home-screen web app has no browser chrome and no way back.
        # Whether THIS port escapes that on its own — a separate port may put the
        # document outside the app's scope, which is how the legacy box got iOS to
        # lend it a back arrow — has not been measured on a device. So the surface is
        # covered rather than assumed, and the assumption costs nothing if it holds:
        # the widget draws only in a standalone window, so a document that opened
        # with chrome gets no second control.
        sub_filter '</body>' '<script src="/airlock-return.js" data-mode="corner" defer></script></body>';
        sub_filter_once on;
    }
    location /publish/files/ {
        alias @@SHARE@@/;
        autoindex on;
        add_header Cache-Control "no-cache" always;
        # Same injection the hub's /publish/files/ carries (apps/publish/render.sh):
        # a reader inside a home-screen web app has no browser chrome and no way back.
        # Whether THIS port escapes that on its own — a separate port may put the
        # document outside the app's scope, which is how the legacy box got iOS to
        # lend it a back arrow — has not been measured on a device. So the surface is
        # covered rather than assumed, and the assumption costs nothing if it holds:
        # the widget draws only in a standalone window, so a document that opened
        # with chrome gets no second control.
        sub_filter '</body>' '<script src="/airlock-return.js" data-mode="corner" defer></script></body>';
        sub_filter_once on;
    }
    # The widget itself. This port serves the share dir and nothing else, so it has
    # no route to the hub webroot the injected tag points at. Separate-port gates
    # each serve their own copy for the same reason (see emit_owner_gate).
    location = /airlock-return.js {
        alias @@WEBROOT@@/assets/airlock-return.js;
        default_type application/javascript;
        add_header Cache-Control "no-cache" always;
        access_log off;
    }
}
# ==== End publish dedicated document-view gate ====
NGINX
fi

sed -e "s|@@CONFD@@|${CONFD}|g" <<'NGINX'

# separate-port owner gates (devterm, code-server, orca, paseo) drop server
# fragments here as they are installed.
include @@CONFD@@/servers.d/*.conf;
NGINX
