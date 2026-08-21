# shellcheck shell=bash
# Airlock nginx gate emitters — the single place that turns the configured
# identity header into nginx, and stamps the owner-gate / WS-safe proxy pattern.
#
# All emitters print an nginx fragment to stdout. render-nginx.sh composes them.
# We use QUOTED heredocs + sed placeholder substitution so that nginx runtime
# variables ($host, $http_upgrade, ...) are never touched by the shell — this
# deliberately avoids the unquoted-heredoc `$var` expansion trap (which under
# `set -u` can abort the whole render).

# ident_var "Tailscale-User-Login" -> "http_tailscale_user_login"
# The one function that couples Airlock to the identity header at the nginx layer.
ident_var() {
  local h="${1:?ident_var: header name required}"
  h="${h//-/_}"
  printf 'http_%s' "$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
}

# emit_connection_upgrade_map — global map needed once for WebSocket proxying.
emit_connection_upgrade_map() {
  cat <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX
}

# emit_identity_map <map_var> <allow_login...>
# Produces: map $http_<ident> $<map_var> { default 0; "owner" 1; ... }
# Requires AIRLOCK_IDENTITY_HEADER in the environment.
emit_identity_map() {
  local mapvar="${1:?emit_identity_map: map var required}"; shift
  if [ -z "${AIRLOCK_IDENTITY_HEADER:-}" ]; then
    printf 'emit_identity_map: AIRLOCK_IDENTITY_HEADER not set (run via airlock env)\n' >&2
    return 1
  fi
  local var; var="$(ident_var "$AIRLOCK_IDENTITY_HEADER")"
  printf 'map $%s $%s {\n    default 0;\n' "$var" "$mapvar"
  local login
  for login in "$@"; do
    [ -n "$login" ] && printf '    "%s" 1;\n' "$login"
  done
  printf '}\n'
}

# emit_subpath_location <location_path> <upstream_addr>
# A reverse proxy for a same-origin subpath app (publish, notepad, dev-monitor).
# The fragment is included INSIDE the hub server block, which gates every request
# at the server level ($hub_ok) — so this is a plain proxy with no per-location
# guard (a per-location `if` + proxy/try_files does not gate reliably; the single
# server-level chokepoint does). proxy_pass carries NO URI, so the original path
# is passed through unchanged (backends that own their subpath prefix expect
# this). WS-safe (no X-Forwarded-*).
emit_subpath_location() {
  local path="${1:?emit_subpath_location: location path required}"
  local upstream="${2:?emit_subpath_location: upstream addr required}"
  sed -e "s|@@PATH@@|${path}|g" \
      -e "s|@@UPSTREAM@@|${upstream}|g" <<'NGINX'
location @@PATH@@ {
    proxy_pass http://@@UPSTREAM@@;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 86400s;
    # WS-safe: no X-Forwarded-* (see emit_owner_gate).
}
NGINX
}

# emit_https_redirect <listen_port> <https_origin>
# A loopback server whose ONLY job is to bounce a plaintext arrival to the
# canonical https origin. `tailscale serve --http=<port>` points here instead of
# at a gate, so Airlock never serves content — or an identity header — over a
# non-TLS connection, and the browser always ends up in a secure context
# (clipboard, OSC52, PWA) on the FQDN the Tailscale cert is issued for.
#
# <https_origin> is a scheme+host[:port] with NO trailing slash, e.g.
# "https://box.tailnet.ts.net" or "https://box.tailnet.ts.net:8443". Pass the
# literal FQDN when it is known: the short hostname resolves on a tailnet but has
# no cert, so redirecting to $host would just move the failure. When the FQDN is
# unknown at render time (dry-run/CI) callers pass 'https://$host' as a fallback.
emit_https_redirect() {
  local listen="${1:?emit_https_redirect: listen port required}"
  local origin="${2:?emit_https_redirect: https origin required}"
  # The origin is pasted into a sed replacement and then into a Location header,
  # so validate its shape here — the one chokepoint. `&` would re-insert the match
  # and corrupt the config, `|` would break the sed expression outright, and a
  # stray space or newline would emit an nginx directive we did not intend. A real
  # Tailscale DNSName is always within this character set; an operator-supplied
  # AIRLOCK_TS_FQDN might not be.
  case "$origin" in
    https://*) ;;
    *) printf 'emit_https_redirect: origin must start with https:// (got %s)\n' "$origin" >&2; return 1 ;;
  esac
  if ! printf '%s' "$origin" | grep -qE '^https://[A-Za-z0-9._-]+(:[0-9]{1,5})?$'; then
    printf 'emit_https_redirect: refusing malformed origin %s (expected https://<host>[:port])\n' "$origin" >&2
    return 1
  fi
  sed -e "s/@@LISTEN@@/${listen}/g" \
      -e "s|@@ORIGIN@@|${origin}|g" <<'NGINX'
server {
    listen 127.0.0.1:@@LISTEN@@;
    server_name _;
    # 301, not 302: let browsers and home-screen shortcuts learn the https
    # entrance for good. Nothing else is served here.
    return 301 @@ORIGIN@@$request_uri;
}
NGINX
}

# emit_owner_gate <listen_port> <upstream_addr> <map_var> [return_widget_file] [anchor] [extra_locations_file]
# A loopback server that 403s unless $<map_var> == 1, then WS-safely proxies.
# If return_widget_file is given (a path to airlock-return.js on disk), the gate
# also serves it at /airlock-return.js and injects <script src="/airlock-return.js">
# before </body> via sub_filter — so upstream bundles (orca) that we cannot edit
# still get the "return to Airlock" widget. anchor (default bottom-right) picks the
# floating button's default corner. sub_filter only touches text/html, so WS and
# JS bundles are untouched; Accept-Encoding is cleared so the upstream sends
# uncompressed HTML (sub_filter no-ops on compressed responses).
# If extra_locations_file is given, its contents are emitted INSIDE this server block
# (after location /, before the closing brace) — e.g. orca's static patched web client
# at /orca-web/ + a zero-paste redirect. Those extra locations must carry their own
# `if ($<map_var> = 0) { return 403; }` guard (an nginx per-location `if` only covers
# its own location; only location / above is guarded here).
emit_owner_gate() {
  local listen="${1:?}" upstream="${2:?}" mapvar="${3:?}"
  local widget="${4:-}" anchor="${5:-bottom-right}" extra="${6:-}"
  sed -e "s/@@LISTEN@@/${listen}/g" <<'NGINX'
server {
    listen 127.0.0.1:@@LISTEN@@;
    server_name _;
NGINX
  if [ -n "$widget" ]; then
    printf '\n    location = /airlock-return.js { alias %s; default_type application/javascript; add_header Cache-Control "no-cache" always; access_log off; }\n' "$widget"
  fi
  sed -e "s|@@UPSTREAM@@|${upstream}|g" \
      -e "s/@@MAP@@/${mapvar}/g" <<'NGINX'

    location / {
        if ($@@MAP@@ = 0) { return 403; }
        proxy_pass http://@@UPSTREAM@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400s;
        # WS-safe: do NOT add X-Forwarded-* here — some upstreams (orca) verify
        # Origin and break if the forwarded proto/host is rewritten.
NGINX
  if [ -n "$widget" ]; then
    printf '        proxy_set_header Accept-Encoding "";\n'
    printf "        sub_filter '</body>' '<script src=\"/airlock-return.js\" data-anchor=\"%s\" defer></script></body>';\n" "$anchor"
    printf '        sub_filter_once on;\n'
  fi
  # close location /
  printf '    }\n'
  # optional extra locations inside this gated server (each self-guarded — see above)
  if [ -n "$extra" ] && [ -f "$extra" ]; then
    cat "$extra"
  fi
  # close server
  printf '}\n'
}

# emit_slot_gate <listen> <backend_port> <slots> <manager_port> <map_var> \
#                <shell_dir> <shell_file> [return_widget_file]
#
# SHARED-FILE NOTE: added for the multi-instance code-server port
# (apps/code-server). Other apps only use emit_owner_gate; keep both in sync when
# editing the WS-safe proxy pattern.
#
# A full owner-gated server block for the code-server slot manager. Unlike
# emit_owner_gate (which proxies "/" to a single upstream), this SERVES a static
# tab-bar shell at "/" and reverse-proxies one "/s/N/" per slot plus an "/api/"
# route to the loopback slot manager. It emits:
#   - owner guard ($<map_var> = 0 -> 403) at the server level, covering every
#     location below (WebSocket upgrades included).
#   - "/" -> the shell HTML via root + try_files (NOT alias: alias on an exact
#     "= /" makes nginx append the index name and 500s).
#   - "/s/N/" for N in 1..slots, each proxying 127.0.0.1:<backend_port + N - 1>,
#     WS-safe (Host + Upgrade + Connection only; NO X-Forwarded-* — code-server
#     verifies the WS Origin and a rewritten proto/host breaks the workbench
#     socket). Slot ports MUST match the systemd template and the manager.
#   - "/api/" -> the manager, re-injecting the gate-verified identity header so
#     the manager can re-check the owner (defense-in-depth).
#   - optional "/airlock-return.js" served from the shared widget on disk (the
#     shell embeds <script src="/airlock-return.js"> itself, so NO sub_filter).
# Requires AIRLOCK_IDENTITY_HEADER in the environment.
emit_slot_gate() {
  local listen="${1:?emit_slot_gate: listen port required}"
  local backend="${2:?emit_slot_gate: backend port required}"
  local slots="${3:?emit_slot_gate: slot count required}"
  local manager="${4:?emit_slot_gate: manager port required}"
  local mapvar="${5:?emit_slot_gate: map var required}"
  local shell_dir="${6:?emit_slot_gate: shell dir required}"
  local shell_file="${7:?emit_slot_gate: shell file required}"
  local widget="${8:-}"
  if [ -z "${AIRLOCK_IDENTITY_HEADER:-}" ]; then
    printf 'emit_slot_gate: AIRLOCK_IDENTITY_HEADER not set (run via airlock env)\n' >&2
    return 1
  fi
  local var; var="$(ident_var "$AIRLOCK_IDENTITY_HEADER")"

  printf 'server {\n'
  printf '    listen 127.0.0.1:%s;\n' "$listen"
  printf '    server_name _;\n\n'
  printf '    # owner-only: server-level guard covers every location, WS upgrades included.\n'
  printf '    if ($%s = 0) { return 403; }\n\n' "$mapvar"

  if [ -n "$widget" ]; then
    printf '    location = /airlock-return.js { alias %s; default_type application/javascript; add_header Cache-Control "no-cache" always; access_log off; }\n\n' "$widget"
  fi

  printf '    # tab-bar shell (single static file). root+try_files, NOT alias (see header).\n'
  printf '    location = / {\n'
  printf '        root %s;\n' "$shell_dir"
  printf '        try_files /%s =404;\n' "$shell_file"
  printf '        default_type text/html;\n'
  printf '        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;\n'
  printf '    }\n'
  printf '    location = /favicon.ico { return 204; }\n\n'

  local n port
  for (( n = 1; n <= slots; n++ )); do
    port=$(( backend + n - 1 ))
    printf '    location = /s/%s { return 308 /s/%s/; }\n' "$n" "$n"
    printf '    location /s/%s/ {\n' "$n"
    printf '        proxy_pass http://127.0.0.1:%s/;\n' "$port"
    printf '        proxy_http_version 1.1;\n'
    printf '        proxy_set_header Host $host;\n'
    printf '        proxy_set_header Upgrade $http_upgrade;\n'
    printf '        proxy_set_header Connection $connection_upgrade;\n'
    printf '        proxy_read_timeout 86400s;\n'
    printf '        proxy_send_timeout 86400s;\n'
    printf '    }\n'
  done
  printf '\n'

  printf '    # slot manager API (loopback). Re-inject the gate-verified identity header\n'
  printf '    # so the manager can re-check the owner (defense-in-depth).\n'
  printf '    location /api/ {\n'
  printf '        proxy_pass http://127.0.0.1:%s;\n' "$manager"
  printf '        proxy_http_version 1.1;\n'
  printf '        proxy_set_header Host $host;\n'
  printf '        proxy_set_header %s $%s;\n' "$AIRLOCK_IDENTITY_HEADER" "$var"
  printf '    }\n'
  printf '}\n'
}
