#!/usr/bin/env bash
# Test install/render-nginx.sh: renders a valid site and passes `nginx -t`.
set -uo pipefail
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 15/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
# The installer and a www-data worker both need to traverse this fixture root.
chmod 755 "$TMP"
trap 'rm -rf "$TMP"' EXIT
export AIRLOCK_STATE_DIR="$TMP/state"   # isolate the installed-state ledger from the dev box

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

cat >"$TMP/airlock.toml" <<'TOML'
[site]
name = "My Dev Hub"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
collaborators = ["friend@example.com"]
[apps.hub]
[apps.notepad]
[apps.publish]
TOML

export AIRLOCK_CONFIG="$TMP/airlock.toml"
export AIRLOCK_WEBROOT="$TMP/webroot"
export AIRLOCK_CONFD="$TMP/confd"
# Pin the FQDN: the render refuses to guess (a redirect to the short hostname has
# no cert), and pinning lets the assertions below check the exact authority.
export AIRLOCK_TS_FQDN="box.example.ts.net"
mkdir -p "$AIRLOCK_WEBROOT" "$AIRLOCK_CONFD/hub-locations.d" "$AIRLOCK_CONFD/servers.d"

SITE="$(bash "$HERE/render-nginx.sh" 2>"$TMP/err")" || { bad "render-nginx exited non-zero"; cat "$TMP/err"; }

# structural checks
grep -q 'listen 127.0.0.1:19902;'                 <<<"$SITE" && ok "hub loopback port (default)" || bad "hub port"
grep -q '$http_tailscale_user_login $hub_ok'       <<<"$SITE" && ok "hub_ok map uses ident" || bad "hub_ok map"

# D7/F14 stage 4 (child 4/P3 flip): role is UNCONDITIONAL — every render
# carries the role map and the /whoami field, whether or not any configured
# package declares [audience]. notepad — a shipped, migrated package that
# declares no [audience] at all — is the representative here for "no audience
# declared anywhere" still getting the map and field.
grep -qF 'map $owner_ok $airlock_role { 1 "owner"; default "collaborator"; }' <<<"$SITE" \
  && ok "role: map present even when no configured package declares audience" \
  || bad "role: map missing"
grep -qF '"role":"$airlock_role"' <<<"$SITE" \
  && ok "role: /whoami field present even when no configured package declares audience" \
  || bad "role: /whoami field missing"
mkdir -p "$TMP/pkg-aud"
cat >"$TMP/pkg-aud/airlock-app.toml" <<'TOML'
contract = 1
id = "audapp"
[audience]
supported = ["shared", "owner"]
default = "owner"
TOML
printf '#!/bin/bash\ntrue\n' >"$TMP/pkg-aud/install.sh"
cp "$TMP/pkg-aud/install.sh" "$TMP/pkg-aud/smoke.sh"
cat >"$TMP/aud.toml" <<TOML
[site]
name = "My Dev Hub"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.audapp]
[packages.audapp]
path = "$TMP/pkg-aud"
TOML
AUD_SITE="$(AIRLOCK_CONFIG="$TMP/aud.toml" bash "$HERE/render-nginx.sh" 2>"$TMP/aud-err")" \
  || { bad "role: audience render exited non-zero"; cat "$TMP/aud-err"; }
grep -qF 'map $owner_ok $airlock_role { 1 "owner"; default "collaborator"; }' <<<"$AUD_SITE" \
  && ok "role: audience package emits the role map" || bad "role: map missing"
grep -qF '"role":"$airlock_role"' <<<"$AUD_SITE" \
  && ok "role: /whoami carries role when audience is declared" || bad "role: /whoami field missing"
grep -q '"friend@example.com" 1;'                  <<<"$SITE" && ok "collaborator in hub map" || bad "collaborator"
grep -q '$http_tailscale_user_login $owner_ok'     <<<"$SITE" && ok "owner_ok map present" || bad "owner_ok map"
grep -q 'friend@example.com' <<<"$(grep -A3 '\$owner_ok {' <<<"$SITE")" && bad "owner_ok must NOT include collaborators" || ok "owner_ok excludes collaborators"
# D7. A hub-subpath app is inside the $hub_ok server, so an owner-only manifest
# is only true if its own fragment narrows further. fileview's audience is
# operator-selectable, so the guard has to track it — and anything that is not
# "shared" (including a value this renderer does not know) must narrow, never
# widen. Without this the tile hides while the URL stays open, which reads as a
# closed door and is not one.
( . "$ROOT/apps/fileview/render.sh"
  g_owner="$(render_fileview_nginx 1 owner  | grep -c 'if ($owner_ok = 0) { return 403; }')"
  g_share="$(render_fileview_nginx 1 shared | grep -c 'owner_ok' || true)"
  g_junk="$( render_fileview_nginx 1 zzzz   | grep -c 'if ($owner_ok = 0) { return 403; }')"
  [ "$g_owner" = 3 ] || { echo "FAIL audience: owner must guard all 3 fileview content locations (got $g_owner)"; exit 1; }
  [ "$g_share" = 0 ] || { echo "FAIL audience: shared must emit no owner guard (got $g_share)"; exit 1; }
  [ "$g_junk"  = 3 ] || { echo "FAIL audience: an unknown audience must fail closed (got $g_junk)"; exit 1; }
) && ok "audience: fileview guard tracks the declared audience, unknown fails closed" \
  || bad "audience: fileview guard does not track the declared audience"

# ==== platform account surface: the guard IS the audience declaration ====
# An app package declares its audience twice — manifest [audience] and the location's own
# $owner_ok (SECURITY.md). The hub is platform core and has no manifest, so for this
# surface the location is the ONLY place the claim exists. These checks are therefore not
# "does the renderer still emit what it emitted yesterday"; they are the audience
# contract itself.
ACCT_LOC="$(awk '/location \/airlock-accounts\/ \{/{f=1} f{print} f&&/^    \}/{exit}' <<<"$SITE")"
[ -n "$ACCT_LOC" ] && ok "account surface: the prefix location is rendered" \
  || bad "account surface: no /airlock-accounts/ location in the hub block"
grep -q 'if ($owner_ok = 0) { return 403; }' <<<"$ACCT_LOC" \
  && ok "account surface: owner guard present (the hub gate admits collaborators)" \
  || bad "account surface: NO owner guard — \$hub_ok admits collaborators, so this location is open to them"
# $hub_ok here would be the fail-open spelling: it is what the server block already
# applied, so writing it would look like a guard and gate nothing further.
grep -q 'hub_ok' <<<"$ACCT_LOC" \
  && bad "account surface: guard keys on \$hub_ok, which admits collaborators" \
  || ok "account surface: guard does not key on \$hub_ok"
# The trailing slash strips the prefix so the backend keeps its own route names.
grep -qE 'proxy_pass http://127\.0\.0\.1:[0-9]+/;' <<<"$ACCT_LOC" \
  && ok "account surface: proxy_pass keeps its prefix-stripping trailing slash" \
  || bad "account surface: proxy_pass has no trailing slash — every route would 404 in the backend"
# Prefix, not per-route: one guard instead of eighteen, and out of `location /`'s
# try_files (which would answer an unserved route with index.html and HTTP 200).
[ "$(grep -c 'location /airlock-accounts/' <<<"$SITE")" = 1 ] \
  && ok "account surface: exactly one location carries the whole surface" \
  || bad "account surface: more than one account location — each would need its own guard"

grep -q 'listen 127.0.0.1:19903;'                  <<<"$SITE" && ok "hub redirect loopback port (default)" || bad "hub redirect port"
# the authority must be the pinned FQDN — NOT $host (client-controlled = open
# redirect) and not the short hostname (no cert).
grep -q 'return 301 https://box.example.ts.net\$request_uri;' <<<"$SITE" \
  && ok "plaintext entrance 301s to the FQDN https origin" || bad "redirect target"
grep -q 'return 301 https://\$host'                <<<"$SITE" && bad "redirect authority is client-controlled" \
  || ok "redirect authority is not \$host"
# the redirect server must carry no content and no gate — only the 301
awk '/listen 127.0.0.1:19903;/{f=1} f&&/proxy_pass|root |try_files/{print "leak"} f&&/^}/{f=0}' <<<"$SITE" \
  | grep -q leak && bad "redirect server serves content" || ok "redirect server serves only the 301"
grep -q 'include .*/servers.d/\*.conf;'            <<<"$SITE" && ok "servers.d include" || bad "servers.d include"
grep -q 'include .*/hub-locations.d/\*.conf;'      <<<"$SITE" && ok "hub-locations.d include" || bad "hub-locations include"
grep -q '@@' <<<"$SITE" && bad "no unresolved placeholder" || ok "no unresolved placeholder"

# Generate the actual local-mode fragment. This guards the installer template,
# rather than a second hand-copied nginx snippet.
LOCAL_CONFIG="$TMP/local-publish.toml"
printf '%s\n' \
  '[auth]' 'provider = "tailscale"' 'owner = "owner@fixture.dev"' \
  '[apps.publish]' '[apps.publish.public_target]' \
  'mode = "local"' 'base_url = "https://docs.example"' \
  "public_dir = \"$TMP/public\"" "gated_dir = \"$TMP/gated\"" \
  "htpasswd_dir = \"$TMP/auth\"" >"$LOCAL_CONFIG"
LOCAL_CONFD="$TMP/local-confd"
INSTALL_BIN="$TMP/publish-install-bin"; mkdir -p "$INSTALL_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$INSTALL_BIN/systemctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$INSTALL_BIN/sudo"
chmod +x "$INSTALL_BIN/systemctl" "$INSTALL_BIN/sudo"
if PATH="$INSTALL_BIN:$PATH" HOME="$TMP/local-home" AIRLOCK_DRY_RUN=0 AIRLOCK_CONFIG="$LOCAL_CONFIG" \
  AIRLOCK_CONFD="$LOCAL_CONFD" AIRLOCK_WEBROOT="$TMP/local-web" \
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/publish" AIRLOCK_APP_ID=publish \
  bash "$ROOT/apps/publish/install.sh" >"$TMP/local-publish.log" 2>&1; then
  ok "local publish installer generated its gated fragment"
else
  bad "local publish installer failed"; sed 's/^/    /' "$TMP/local-publish.log"
fi
GATED_FRAGMENT="$LOCAL_CONFD/public-includes.d/publish-gated.conf"
[ -f "$GATED_FRAGMENT" ] && ok "local gated fragment is in public-includes.d" || bad "local gated fragment missing"
GATED_SYNTAX_FRAGMENT="$TMP/gated-syntax.conf"
cp "$GATED_FRAGMENT" "$GATED_SYNTAX_FRAGMENT" 2>/dev/null || :
REMOTE_CONFIG="$TMP/remote-publish.toml"
printf '%s\n' \
  '[auth]' 'provider = "tailscale"' 'owner = "owner@fixture.dev"' \
  '[apps.publish]' '[apps.publish.public_target]' \
  'mode = "remote"' 'ingest_url = "https://ingest.example"' \
  'base_url = "https://docs.example"' 'token_env = "PUBLISH_TEST_TOKEN"' >"$REMOTE_CONFIG"
if PATH="$INSTALL_BIN:$PATH" HOME="$TMP/remote-home" AIRLOCK_DRY_RUN=0 AIRLOCK_CONFIG="$REMOTE_CONFIG" \
  AIRLOCK_CONFD="$LOCAL_CONFD" AIRLOCK_WEBROOT="$TMP/remote-web" \
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/publish" AIRLOCK_APP_ID=publish \
  bash "$ROOT/apps/publish/install.sh" >"$TMP/remote-publish.log" 2>&1; then
  # Retraction is "serves nothing", not "is gone". The operator's own public server
  # block includes this path (README), so removing the file makes nginx refuse to
  # load the whole configuration — silently, until the next reload or restart.
  if [ -f "$GATED_FRAGMENT" ]; then ok "remote install leaves the operator's include resolvable"
  else bad "remote install removed the fragment an operator include points at"; fi
  if [ -f "$GATED_FRAGMENT" ] && ! grep -qE '^[[:space:]]*(location|auth_basic)' "$GATED_FRAGMENT"; then
    ok "remote install retracts the gated fragment (no directives left)"
  else bad "remote install left gated fragment active"; fi
else
  bad "remote publish installer failed"; sed 's/^/    /' "$TMP/remote-publish.log"
fi

# fail-closed: no measurable FQDN -> refuse to render rather than emit a redirect
# to the short hostname (which has no certificate).
printf '#!/bin/sh\nexit 1\n' >"$TMP/tailscale"; chmod +x "$TMP/tailscale"   # tailscaled down
if AIRLOCK_TS_FQDN='' PATH="$TMP:$PATH" bash "$HERE/render-nginx.sh" >/dev/null 2>&1; then
  bad "render must refuse when the FQDN cannot be determined"
else
  ok "render refuses without a determinable FQDN (fail-closed)"
fi

# a malformed operator-supplied FQDN must be rejected, not pasted into the config
if AIRLOCK_TS_FQDN='foo&bar' bash "$HERE/render-nginx.sh" >/dev/null 2>&1; then
  bad "render accepted a malformed AIRLOCK_TS_FQDN"
else
  ok "render rejects a malformed AIRLOCK_TS_FQDN"
fi

# fail-closed: a non-tailscale provider makes render refuse
sed 's/provider = "tailscale"/provider = "basic"/' "$TMP/airlock.toml" >"$TMP/bad.toml"
if AIRLOCK_CONFIG="$TMP/bad.toml" bash "$HERE/render-nginx.sh" >/dev/null 2>&1; then
  bad "render refuses non-tailscale provider"
else
  ok "render refuses non-tailscale provider (fail-closed)"
fi

# full nginx -t on the rendered site
if command -v nginx >/dev/null 2>&1; then
  {
    echo "pid \"$TMP/nginx.pid\";"
    echo "error_log \"$TMP/error.log\";"
    echo "events {}"
    echo "http {"
    echo "  access_log off;"
    echo "  client_body_temp_path \"$TMP/cbt\";"
    echo "  proxy_temp_path \"$TMP/pt\";"
    echo "  fastcgi_temp_path \"$TMP/ft\";"
    echo "  uwsgi_temp_path \"$TMP/ut\";"
    echo "  scgi_temp_path \"$TMP/st\";"
    echo "$SITE"
    echo "}"
  } >"$TMP/nginx.conf"
  if nginx -t -c "$TMP/nginx.conf" -p "$TMP" >/dev/null 2>&1; then
    ok "nginx -t: rendered site valid"
  else
    bad "nginx -t: rendered site invalid"; nginx -t -c "$TMP/nginx.conf" -p "$TMP" 2>&1 | sed 's/^/    /'
  fi
else
  echo "skip nginx -t (nginx not installed)"
fi

# A syntax-only `nginx -t` on this fragment used to live here. It is gone on
# purpose: the block below includes the same fragment and actually serves it, so
# the parse is covered strictly better by a request that has to succeed. The
# removed check was also wrong — a bare `http {}` with no `access_log off;`
# makes nginx open the compiled-in default /var/log/nginx/access.log, which no
# unprivileged runner can write, so it reported "fragment invalid" for a fragment
# whose syntax was fine.
if command -v nginx >/dev/null 2>&1; then
  NGINX_BIN="$(command -v nginx)"
  GATED_PORT=18999
  GATED_URL="http://127.0.0.1:$GATED_PORT"
  GATED_SUDO=0
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 && id -u www-data >/dev/null 2>&1; then
    GATED_SUDO=1
  fi

  mkdir -p "$TMP/gated/alpha" "$TMP/gated/bravo" "$TMP/auth" \
    "$TMP/cbt" "$TMP/pt" "$TMP/ft" "$TMP/ut" "$TMP/st"
  # www-data must be able to traverse the fixture path; the auth files below
  # are owned by the test user so 0600 can reproduce a different-worker uid.
  chmod 755 "$TMP" "$TMP/gated" "$TMP/gated/alpha" "$TMP/gated/bravo" "$TMP/auth" \
    "$TMP/cbt" "$TMP/pt" "$TMP/ft" "$TMP/ut" "$TMP/st"
  printf '%s\n' 'ALPHA' >"$TMP/gated/alpha/index.html"
  printf '%s\n' 'BRAVO' >"$TMP/gated/bravo/index.html"

  ALPHA_PASSWORD='alpha-password'
  BRAVO_PASSWORD='bravo-password'
  ALPHA_CREDENTIALS="alpha:$ALPHA_PASSWORD"
  BRAVO_CREDENTIALS="bravo:$BRAVO_PASSWORD"
  # Precomputed with Python bcrypt (cost 4) for the fixed passwords above;
  # these use the same bcrypt record format as `htpasswd -niB`, but stay
  # hardcoded because apache2-utils/htpasswd is absent from CI.
  printf '%s\n' "alpha:\$2y\$04\$.XPfUEQ5aQb/99bs8ULYO./vAwf8l6gQSy6M/GxY244PXHMyk1cLa" >"$TMP/auth/alpha.htpasswd"
  printf '%s\n' "bravo:\$2y\$04\$u1dyLA7vt/GiVWq2ISqIrOJw8NmmAbASmLYi/6Lxem/voKqkTlpIC" >"$TMP/auth/bravo.htpasswd"
  chmod 644 "$TMP/auth/alpha.htpasswd" "$TMP/auth/bravo.htpasswd"

  {
    [ "$GATED_SUDO" -eq 1 ] && echo "user www-data;"
    echo "pid \"$TMP/gated-live.pid\";"
    echo "error_log \"$TMP/gated-live-error.log\";"
    echo "daemon off;"
    echo "events {}"
    echo "http {"
    echo "  access_log off;"
    echo "  client_body_temp_path \"$TMP/cbt\";"
    echo "  proxy_temp_path \"$TMP/pt\";"
    echo "  fastcgi_temp_path \"$TMP/ft\";"
    echo "  uwsgi_temp_path \"$TMP/ut\";"
    echo "  scgi_temp_path \"$TMP/st\";"
    echo "  server { listen 127.0.0.1:$GATED_PORT; include $GATED_SYNTAX_FRAGMENT; }"
    echo "}"
  } >"$TMP/gated-live.conf"

  GATED_NGINX_PID=
  GATED_NGINX_SUDO="$GATED_SUDO"
  gated_nginx_cleanup() {
    if [ -n "${GATED_NGINX_PID:-}" ] && kill -0 "$GATED_NGINX_PID" 2>/dev/null; then
      if [ "$GATED_NGINX_SUDO" -eq 1 ]; then
        sudo -n "$NGINX_BIN" -s stop -c "$TMP/gated-live.conf" -p "$TMP" >/dev/null 2>&1 || :
      else
        "$NGINX_BIN" -s stop -c "$TMP/gated-live.conf" -p "$TMP" >/dev/null 2>&1 || :
      fi
    fi
    if [ -n "${GATED_NGINX_PID:-}" ]; then
      wait "$GATED_NGINX_PID" 2>/dev/null || :
    fi
    rm -rf "$TMP"
  }
  # Replace the original tempdir-only trap so a live master is stopped before
  # its prefix disappears, including when the test is interrupted.
  trap gated_nginx_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! command -v curl >/dev/null 2>&1; then
    bad "gated nginx e2e requires curl"
  else
    GATED_PORT_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 1 "$GATED_URL/" 2>/dev/null || true)"
    if [ "$GATED_PORT_STATUS" != 000 ]; then
      bad "gated nginx e2e fixed port $GATED_PORT is already in use"
    else
      if [ "$GATED_SUDO" -eq 1 ]; then
        # The prefix is user-owned, so this redirect intentionally happens
        # outside sudo and captures startup diagnostics for the test user.
        # shellcheck disable=SC2024
        sudo -n "$NGINX_BIN" -c "$TMP/gated-live.conf" -p "$TMP" >"$TMP/gated-live-start.log" 2>&1 &
      else
        "$NGINX_BIN" -c "$TMP/gated-live.conf" -p "$TMP" >"$TMP/gated-live-start.log" 2>&1 &
      fi
      GATED_NGINX_PID=$!

      GATED_READY=0
      for ((attempt = 0; attempt < 50; attempt++)); do
        GATED_STATUS="$(curl --silent --path-as-is --output /dev/null --write-out '%{http_code}' \
          --max-time 1 "$GATED_URL/g/alpha/" 2>/dev/null || true)"
        if [ -s "$TMP/gated-live.pid" ] && kill -0 "$GATED_NGINX_PID" 2>/dev/null && [ "$GATED_STATUS" != 000 ]; then
          GATED_READY=1
          break
        fi
        sleep 0.1
      done

      if [ "$GATED_READY" -eq 0 ]; then
        bad "gated nginx did not start"
        sed 's/^/    /' "$TMP/gated-live-start.log"
      else
      # 1: the gate must challenge anonymous requests; an open location would
      # make the credential and per-slug checks below meaningless.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --output "$TMP/no-auth.body" \
        --write-out '%{http_code}' "$GATED_URL/g/alpha/" 2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 401 ]; then
        ok "gated e2e: anonymous alpha GET is 401"
      else
        bad "gated e2e: anonymous alpha GET returned $GATED_STATUS"
      fi

      # 2: a valid alpha record must be readable by the worker (B1) and serve
      # the matching slug rather than another document.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/alpha.body" --write-out '%{http_code}' "$GATED_URL/g/alpha/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/alpha.body" ] && [ "$(<"$TMP/alpha.body")" = ALPHA ]; then
        ok "gated e2e: alpha credentials return ALPHA"
      else
        bad "gated e2e: alpha GET returned $GATED_STATUS or wrong body"
      fi

      # 3: the second slug has its own valid record and content, proving the
      # per-slug fixture path needed to expose B2.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$BRAVO_CREDENTIALS" \
        --output "$TMP/bravo.body" --write-out '%{http_code}' "$GATED_URL/g/bravo/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/bravo.body" ] && [ "$(<"$TMP/bravo.body")" = BRAVO ]; then
        ok "gated e2e: bravo credentials return BRAVO"
      else
        bad "gated e2e: bravo GET returned $GATED_STATUS or wrong body"
      fi

      # 4: alpha credentials must not open bravo; this is B2, which a shared
      # htpasswd file would falsely pass with a 200/BRAVO response.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/alpha-on-bravo.body" --write-out '%{http_code}' "$GATED_URL/g/bravo/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 401 ]; then
        ok "gated e2e: alpha credentials are rejected for bravo"
      else
        bad "gated e2e: alpha credentials opened bravo with HTTP $GATED_STATUS"
      fi

      # 5: mode 0600 only reproduces B1 when the worker has a different uid,
      # so this permission check is intentionally skipped unless sudo can
      # launch www-data.
      if [ "$GATED_SUDO" -eq 1 ]; then
        chmod 600 "$TMP/auth/alpha.htpasswd"
        GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
          --output "$TMP/alpha-unreadable.body" --write-out '%{http_code}' "$GATED_URL/g/alpha/" \
          2>"$TMP/curl-error" || true)"
        if [ "$GATED_STATUS" = 403 ] || [ "$GATED_STATUS" = 500 ]; then
          ok "gated e2e: unreadable alpha auth file fails closed (B1)"
        else
          bad "gated e2e: unreadable alpha auth file returned $GATED_STATUS (B1)"
        fi

        # 6: restoring 0644 must recover the request, proving this is B1's
        # worker-readability failure rather than a permanently broken gate.
        chmod 644 "$TMP/auth/alpha.htpasswd"
        GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
          --output "$TMP/alpha-readable.body" --write-out '%{http_code}' "$GATED_URL/g/alpha/" \
          2>"$TMP/curl-error" || true)"
        if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/alpha-readable.body" ] && [ "$(<"$TMP/alpha-readable.body")" = ALPHA ]; then
          ok "gated e2e: readable alpha auth file works again (B1)"
        else
          bad "gated e2e: readable alpha auth file returned $GATED_STATUS (B1)"
        fi
      else
        echo "skip gated e2e: B1 permission cases need sudo -n and www-data"
      fi

      # 8: encoded and repeated separators must not let alpha credentials
      # escape the alpha slug and return BRAVO.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/dot-segment.body" --write-out '%{http_code}' "$GATED_URL/g/alpha/../bravo/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/dot-segment.body" ] && [ "$(<"$TMP/dot-segment.body")" = BRAVO ]; then
        bad "gated e2e: alpha dot-segment request returned BRAVO"
      elif [ "$GATED_STATUS" = 000 ]; then
        bad "gated e2e: alpha dot-segment request had no HTTP response"
      elif [ "$GATED_STATUS" = 200 ]; then
        bad "gated e2e: alpha dot-segment request unexpectedly returned HTTP 200"
      else
        ok "gated e2e: alpha dot-segment request stays within its slug"
      fi
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/encoded-slash.body" --write-out '%{http_code}' "$GATED_URL/g/alpha%2f..%2fbravo/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/encoded-slash.body" ] && [ "$(<"$TMP/encoded-slash.body")" = BRAVO ]; then
        bad "gated e2e: alpha encoded-slash request returned BRAVO"
      elif [ "$GATED_STATUS" = 000 ]; then
        bad "gated e2e: alpha encoded-slash request had no HTTP response"
      elif [ "$GATED_STATUS" = 200 ]; then
        bad "gated e2e: alpha encoded-slash request unexpectedly returned HTTP 200"
      else
        ok "gated e2e: alpha encoded-slash request stays within its slug"
      fi
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/repeated-slash.body" --write-out '%{http_code}' "$GATED_URL/g/alpha//bravo/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 200 ] && [ -f "$TMP/repeated-slash.body" ] && [ "$(<"$TMP/repeated-slash.body")" = BRAVO ]; then
        bad "gated e2e: alpha repeated-slash request returned BRAVO"
      elif [ "$GATED_STATUS" = 000 ]; then
        bad "gated e2e: alpha repeated-slash request had no HTTP response"
      elif [ "$GATED_STATUS" = 200 ]; then
        bad "gated e2e: alpha repeated-slash request unexpectedly returned HTTP 200"
      else
        ok "gated e2e: alpha repeated-slash request stays within its slug"
      fi

      # 7: deleting the alpha record must revoke access without a reload and
      # never fail open.
      rm -f "$TMP/auth/alpha.htpasswd"
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --user "$ALPHA_CREDENTIALS" \
        --output "$TMP/revoked-alpha.body" --write-out '%{http_code}' "$GATED_URL/g/alpha/" \
        2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 000 ]; then
        bad "gated e2e: revoked alpha credentials had no HTTP response"
      elif [ "$GATED_STATUS" != 200 ]; then
        ok "gated e2e: revoked alpha credentials fail closed (HTTP $GATED_STATUS)"
      else
        bad "gated e2e: revoked alpha credentials still return 200"
      fi

      # 9: the regex must reject short and uppercase slugs before auth runs;
      # 401/500 here would indicate the location boundary is too broad.
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --output "$TMP/short-slug.body" \
        --write-out '%{http_code}' "$GATED_URL/g/al" 2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 404 ]; then
        ok "gated e2e: short slug is 404"
      else
        bad "gated e2e: short slug returned $GATED_STATUS"
      fi
      GATED_STATUS="$(curl --silent --show-error --path-as-is --max-time 5 --output "$TMP/uppercase-slug.body" \
        --write-out '%{http_code}' "$GATED_URL/g/ALPHA" 2>"$TMP/curl-error" || true)"
      if [ "$GATED_STATUS" = 404 ]; then
        ok "gated e2e: uppercase slug is 404"
      else
        bad "gated e2e: uppercase slug returned $GATED_STATUS"
      fi
      fi
    fi
  fi
else
  echo "skip gated nginx e2e (nginx not installed)"
fi

echo "---"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
