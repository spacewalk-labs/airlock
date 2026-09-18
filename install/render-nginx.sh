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

emit_canonical_fragment_includes() {
  local sub="$1" app
  airlock_config apps | while IFS= read -r app; do
    [ -n "$app" ] || continue
    printf '%s' "$app" | grep -qE '^[a-z0-9][a-z0-9-]{0,31}$' || continue
    [ -f "$CONFD/$sub/$app.conf" ] || continue
    printf 'include %s/%s/%s.conf;\n' "$CONFD" "$sub" "$app"
  done
}

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
PUBLISH_BACKEND_PORT=""
PUBLISH_SHARE_DIR=""
PUBLISH_TITLE_META=false
HUB_GATE="hub_ok"
HUB_GATE_EXCEPTION=""
HUB_EXACT_SCOPE=""
if airlock_config apps | grep -qx publish; then
  eval "$(airlock_config env publish)"
  PUBLISH_ENABLED=true
  PUBLISH_HTTPS_PORT="${AIRLOCK_PUBLISH_HTTPS_PORT:?publish https_port missing}"
  PUBLISH_GATE_PORT="${AIRLOCK_PUBLISH_GATE_PORT:?publish gate_port missing}"
  PUBLISH_BACKEND_PORT="${AIRLOCK_PUBLISH_BACKEND_PORT:?publish backend_port missing}"
  PUBLISH_SHARE_DIR="${AIRLOCK_PUBLISH_SHARE_DIR:?publish share_dir missing}"
  PUBLISH_SHARE_DIR="${PUBLISH_SHARE_DIR/#\~/$HOME}"
  PUBLISH_TITLE_META="${AIRLOCK_PUBLISH_TITLE_META:-false}"
  if [ "$PUBLISH_TITLE_META" = true ]; then
    HUB_GATE="publish_hub_ok"
    HUB_GATE_EXCEPTION=", except authenticated tailnet identities on the exact title metadata route"
    HUB_EXACT_SCOPE=" for ordinary hub paths"
  fi
  if [ "${AIRLOCK_PUBLISH_TAILNET_VIEW:-false}" = true ]; then
    PUBLISH_GATE="tailnet_ok"
  fi
fi
# The injected widget's unread badge polls the HUB's owner-only message preview
# (hub/assets/airlock-return.js UNREAD_URL) — a route this box's own $hub_ok gate
# protects. When PUBLISH_GATE is hub_ok, every visitor here already cleared that
# same gate, so the badge poll can only succeed or fail the way it always has.
# When tailnet_view widens PUBLISH_GATE to tailnet_ok, most visitors are NOT
# owner/collaborator and the badge poll would hit the hub gate's 403 before ever
# reaching dev-monitor — data-badge="0" turns the poll off rather than firing a
# request that cannot succeed and that the browser logs as a blocked-CORS-fetch
# console error no matter how the rejection is handled in JS.
PUBLISH_WIDGET_BADGE_ATTR=""
[ "$PUBLISH_GATE" = "tailnet_ok" ] && PUBLISH_WIDGET_BADGE_ATTR=' data-badge="0"'

# hub is reachable by owner + collaborators; privileged apps stay owner-only.
hub_logins=("$AIRLOCK_OWNER")
if [ -n "${AIRLOCK_COLLABORATORS:-}" ]; then
  IFS=',' read -r -a _collab <<<"$AIRLOCK_COLLABORATORS"
  hub_logins+=("${_collab[@]}")
fi

emit_connection_upgrade_map
emit_identity_map hub_ok "${hub_logins[@]}"
airlock_emit_owner_v1_unit "$AIRLOCK_OWNER"
if [ "$PUBLISH_ENABLED" = true ]; then
  printf 'map $%s $tailnet_ok {\n    "" 0;\n    default 1;\n}\n' "$IDENT"
fi
if [ "$PUBLISH_TITLE_META" = true ]; then
  cat <<'NGINX'
map "$hub_ok:$tailnet_ok:$request_method:$uri" $publish_hub_ok {
    default 0;
    ~^1: 1;
    "0:1:GET:/publish/api/meta" 1;
}
NGINX
fi

# The central fleet collector still declares its read domain on devterm while its
# caller points at devterm's compatibility port.  The platform account surface needs
# the same value during the overlap, but reading it here does not make devterm a runtime
# dependency: airlock-config resolves one scalar while rendering nginx, and the emitted
# maps and proxy headers stand alone afterwards.  Keep the read in a subshell so the
# app-specific env cannot overwrite the hub values already selected above.
ACCOUNTS_FLEET_READ_DOMAIN=""
if airlock_config apps | grep -qx devterm; then
  ACCOUNTS_FLEET_READ_DOMAIN="$({
    eval "$(airlock_config env devterm)"
    printf '%s' "${AIRLOCK_DEVTERM_FLEET_READ_DOMAIN:-}"
  })"
fi
ACCOUNTS_FLEET_READ_DOMAIN="${ACCOUNTS_FLEET_READ_DOMAIN#@}"
if [ -n "$ACCOUNTS_FLEET_READ_DOMAIN" ] \
   && ! printf '%s' "$ACCOUNTS_FLEET_READ_DOMAIN" \
        | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
  die "refusing malformed fleet_read_domain: $ACCOUNTS_FLEET_READ_DOMAIN"
fi
ACCOUNTS_FLEET_READ_ESCAPED="${ACCOUNTS_FLEET_READ_DOMAIN//./\\.}"
ACCOUNTS_LOCATION_GATE=owner_ok
ACCOUNTS_FLEET_SED=(-e '/@@ACCTFLEET@@/d')

# Two maps are required because the hub and the account surface have different base
# audiences: hub_ok includes collaborators, while owner_ok does not.  In both maps the
# exception is exact: one configured identity domain, GET, and one of four paths.  A
# future route or method therefore stays closed without anyone remembering to add a
# second guard.  The backend re-checks the standardized proxy headers below.
if [ -n "$ACCOUNTS_FLEET_READ_ESCAPED" ]; then
  printf 'map $%s $airlock_accounts_fleet_identity_ok {\n    default 0;\n' "$IDENT"
  printf '    "~*^[^@]+@%s$" 1;\n' "$ACCOUNTS_FLEET_READ_ESCAPED"
  printf '}\n'
  printf 'map "$%s:$airlock_accounts_fleet_identity_ok:$request_method:$uri" $airlock_accounts_hub_ok {\n' "$HUB_GATE"
  printf '    default 0;\n    ~^1: 1;\n'
  printf '    "0:1:GET:%s" 1;\n' \
    /airlock-accounts/claude-status \
    /airlock-accounts/claude-usage \
    /airlock-accounts/claude-usage-store \
    /airlock-accounts/codex-usage
  printf '}\n'
  cat <<'NGINX'
map "$owner_ok:$airlock_accounts_fleet_identity_ok:$request_method:$uri" $airlock_accounts_surface_ok {
    default 0;
    ~^1: 1;
    "0:1:GET:/airlock-accounts/claude-status" 1;
    "0:1:GET:/airlock-accounts/claude-usage" 1;
    "0:1:GET:/airlock-accounts/claude-usage-store" 1;
    "0:1:GET:/airlock-accounts/codex-usage" 1;
}
NGINX
  HUB_GATE=airlock_accounts_hub_ok
  ACCOUNTS_LOCATION_GATE=airlock_accounts_surface_ok
  ACCOUNTS_FLEET_SED=(-e 's/@@ACCTFLEET@@//')
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
    "${ACCOUNTS_FLEET_SED[@]}" \
    -e "s|@@WEBROOT@@|${WEBROOT}|g" \
    -e "s/@@IDENT@@/${IDENT}/g" \
    -e "s/@@HUB_GATE@@/${HUB_GATE}/g" \
    -e "s/@@HUB_GATE_EXCEPTION@@/${HUB_GATE_EXCEPTION}/g" \
    -e "s/@@HUB_EXACT_SCOPE@@/${HUB_EXACT_SCOPE}/g" \
    -e "s|@@ROLE@@|${ROLE_FIELD}|g" \
    -e "s/@@ACCTPORT@@/${ACCOUNTS_PORT}/g" \
    -e "s/@@ACCTGATE@@/${ACCOUNTS_LOCATION_GATE}/g" \
    -e "s/@@ACCTFLEETDOMAIN@@/${ACCOUNTS_FLEET_READ_DOMAIN}/g" \
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
    # owner + collaborators pass ($hub_ok); everyone else gets the wrong-owner page@@HUB_GATE_EXCEPTION@@.
    if ($@@HUB_GATE@@ = 0) { return 403; }
    # No `=`: keep the honest 403 status. The server-rewrite gate runs before a
    # location is chosen, so a request with hub_ok=0 cannot reach any other 403
    # source. That makes hub_ok an exact selector here@@HUB_EXACT_SCOPE@@: denied identities keep the
    # wrong-owner page, while a location/filesystem 403 reached by an allowed
    # identity gets an honest resource-error explanation instead.
    error_page 403 @denied;
    location @denied {
        root @@WEBROOT@@;
        default_type text/html;
        # A named error location preserves the original method. Rewriting a
        # denied POST/PUT/etc. to the static wrong-owner page would therefore
        # let nginx's static handler replace the gate's 403 with 405.
        if ($request_method !~ ^(GET|HEAD)$) { return 403; }
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
        if ($@@ACCTGATE@@ = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@ACCTPORT@@/;
        proxy_http_version 1.1;
        # $http_host, not $host: $host drops the port, and an upstream that compares the
        # browser's Origin against Host then sees a mismatch on every same-origin
        # request. That exact defect answered the owner's own page with 403 in #318.
        proxy_set_header Host $http_host;
@@ACCTFLEET@@        # Standardize the trusted ingress facts for the backend's second guard. These
@@ACCTFLEET@@        # overwrite any client-supplied values; the loopback service treats requests
@@ACCTFLEET@@        # without the marker as the still-live devterm compatibility ingress.
@@ACCTFLEET@@        proxy_set_header X-Airlock-Platform-Account-Gate 1;
@@ACCTFLEET@@        proxy_set_header X-Airlock-Owner-Ok $owner_ok;
@@ACCTFLEET@@        proxy_set_header X-Airlock-Verified-Login $@@IDENT@@;
@@ACCTFLEET@@        proxy_set_header X-Airlock-Fleet-Read-Domain "@@ACCTFLEETDOMAIN@@";
        proxy_read_timeout 300s;
        # The account surface is never a cached answer: usage numbers and login state
        # are the whole point of asking.
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
NGINX

if [ "$PUBLISH_TITLE_META" = true ]; then
  sed -e "s|@@BACKEND@@|${PUBLISH_BACKEND_PORT}|g" \
      -e "s|@@IDENT_HEADER@@|${AIRLOCK_IDENTITY_HEADER}|g" \
      -e "s|@@IDENT@@|${IDENT}|g" <<'NGINX'

    # This exception lives in the core site rather than the app fragment. If a
    # fragment is missing or stale, the route therefore cannot fall through to
    # the SPA and turn a gate exception into a 200 response with hub content.
    location = /publish/api/meta {
        limit_except GET { deny all; }
        if ($tailnet_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@BACKEND@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header @@IDENT_HEADER@@ $@@IDENT@@;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
NGINX
fi

sed -e "s|@@CONFD@@|${CONFD}|g" <<'NGINX'

    # the entrance itself
    location / {
        try_files $uri $uri/ /index.html;
        # Launcher code and assets use stable URLs; revalidate after each install.
        add_header Cache-Control "no-cache" always;
    }

    # same-origin subpath apps (fileview, publish, dev-monitor, notepad) drop
    # location fragments here as they are installed. They inherit the server-level
    # gate above — fragments are plain proxies, no per-location guard needed.
    # Only enabled-app ids are included; manual files outside that set stay inert.
NGINX
emit_canonical_fragment_includes hub-locations.d
printf '}\n\n'

if [ "$PUBLISH_ENABLED" = true ]; then
  PUBLISH_SHARE_SED="$(printf '%s' "$PUBLISH_SHARE_DIR" | sed 's/[\\&|]/\\&/g')"
  sed -e "s/@@PORT@@/${PUBLISH_GATE_PORT}/g" \
      -e "s/@@HTTPS_PORT@@/${PUBLISH_HTTPS_PORT}/g" \
      -e "s|@@BACKEND@@|${PUBLISH_BACKEND_PORT}|g" \
      -e "s|@@IDENT_HEADER@@|${AIRLOCK_IDENTITY_HEADER}|g" \
      -e "s|@@IDENT@@|${IDENT}|g" \
      -e "s/@@GATE@@/${PUBLISH_GATE}/g" \
      -e "s|@@WEBROOT@@|${WEBROOT}|g" \
      -e "s|@@SHARE@@|${PUBLISH_SHARE_SED}|g" \
      -e "s|@@BADGEATTR@@|${PUBLISH_WIDGET_BADGE_ATTR}|g" <<'NGINX'
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
        if ($request_method !~ ^(GET|HEAD)$) { return 403; }
        if ($@@GATE@@ = 1) {
            return 403 '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Resource forbidden</title></head><body><main><h1>Airlock cannot serve this resource</h1><p>Your access to this Airlock was verified, but the requested resource is forbidden.</p><p>This is not an Airlock ownership error. Check the resource access rules and every file and directory in its path.</p></main></body></html>';
        }
        rewrite ^ /wrong-owner.html break;
    }

    # The generated document library is served from this port. Expose only the
    # external-share calls it uses, not local deletion, repair, batch or upload.
    # Keep the hub's owner+collaborator boundary even when tailnet_view widens
    # document reading.
    location ~ ^/publish/api/(list|public-list)$ {
        limit_except GET { deny all; }
        if ($hub_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@BACKEND@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header @@IDENT_HEADER@@ $@@IDENT@@;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }
    location ~ ^/publish/api/(publish-public|public-revoke|public-set-expiry)$ {
        limit_except POST { deny all; }
        if ($hub_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:@@BACKEND@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header @@IDENT_HEADER@@ $@@IDENT@@;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    }

    # Read-only document surface at the ROOT of this port: the whole link is
    # <fqdn>:<port>/<name>.html. The hub needs the /publish/files/ prefix because
    # the share dir shares that origin with every other app; this port serves
    # nothing else, so the prefix is kept only so links minted against the hub
    # keep opening. /_assets/ is a directory inside the share dir and needs no
    # location of its own. The manager UI is not served here. The exact external
    # sharing routes above are the only write surface and retain the narrower gate.
    # A migrated legacy share can still contain its generated index.html.  Nginx's
    # index module runs before autoindex, so that stale file silently wins and new
    # documents never appear on the port's front page.  Suppress index lookup only
    # for the share root: nested bundles such as /plancritic/ must keep resolving
    # their own index.html through the ordinary location below.
    location = / {
        root @@SHARE@@;
        index .airlock-live-directory-index;
        autoindex on;
        add_header Cache-Control "no-cache" always;
        sub_filter '</body>' '<script src="/airlock-return.js" data-mode="corner"@@BADGEATTR@@ defer></script></body>';
        sub_filter_once on;
    }
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
        sub_filter '</body>' '<script src="/airlock-return.js" data-mode="corner"@@BADGEATTR@@ defer></script></body>';
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
        sub_filter '</body>' '<script src="/airlock-return.js" data-mode="corner"@@BADGEATTR@@ defer></script></body>';
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

cat <<'NGINX'

# separate-port owner gates (devterm, code-server, orca, paseo) drop server
# fragments here as they are installed. Only enabled-app ids are included;
# a manual listener such as publish-doc-gate.conf is not preserved.
NGINX
emit_canonical_fragment_includes servers.d
