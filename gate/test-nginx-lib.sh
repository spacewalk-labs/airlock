#!/usr/bin/env bash
# Tests for gate/nginx-lib.sh emitters (T3). Golden-ish + `nginx -t` if available.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/nginx-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
has() { grep -q -- "$2" <<<"$1"; }

export AIRLOCK_IDENTITY_HEADER="Tailscale-User-Login"

# 1. ident_var maps header -> nginx var (the coupling point)
[ "$(ident_var "Tailscale-User-Login")" = "http_tailscale_user_login" ] \
  && ok "ident_var" || bad "ident_var: got $(ident_var "Tailscale-User-Login")"

# 2. identity map: default deny + listed logins allowed
MAP="$(emit_identity_map owner_ok "me@example.com" "friend@example.com")"
has "$MAP" 'default 0;'            && ok "map: default deny" || bad "map: default deny"
has "$MAP" '"me@example.com" 1;'   && ok "map: owner allowed" || bad "map: owner"
has "$MAP" '$http_tailscale_user_login $owner_ok' && ok "map: uses ident var" || bad "map: ident var"

# 3. owner gate: 403 guard, WS headers, NO X-Forwarded, placeholders resolved
GATE="$(emit_owner_gate 9910 127.0.0.1:9911 owner_ok)"
has "$GATE" 'if ($owner_ok = 0) { return 403; }' && ok "gate: 403 guard" || bad "gate: 403 guard"
has "$GATE" 'listen 127.0.0.1:9910;'             && ok "gate: loopback listen" || bad "gate: listen"
has "$GATE" 'proxy_pass http://127.0.0.1:9911;'  && ok "gate: upstream" || bad "gate: upstream"
has "$GATE" 'proxy_set_header Connection $connection_upgrade;' && ok "gate: WS upgrade" || bad "gate: WS"
grep -q 'proxy_set_header X-Forwarded' <<<"$GATE" && bad "gate: must NOT set X-Forwarded directive" || ok "gate: no X-Forwarded directive"
grep -q '@@' <<<"$GATE$MAP"      && bad "no unresolved @@placeholder@@" || ok "no unresolved placeholder"

# 3b. slot gate (code-server multi-instance): shell at /, looped /s/N/, /api/, widget
SLOT="$(emit_slot_gate 18808 18811 3 18810 owner_ok /etc/airlock/nginx/code-server shell.html /opt/airlock/hub/assets/airlock-return.js)"
has "$SLOT" 'if ($owner_ok = 0) { return 403; }' && ok "slot gate: owner guard" || bad "slot gate: owner guard"
has "$SLOT" 'listen 127.0.0.1:18808;'            && ok "slot gate: loopback listen" || bad "slot gate: listen"
has "$SLOT" 'try_files /shell.html =404;'        && ok "slot gate: serves shell" || bad "slot gate: shell"
has "$SLOT" 'location /s/1/ {'                    && ok "slot gate: /s/1/" || bad "slot gate: /s/1/"
has "$SLOT" 'proxy_pass http://127.0.0.1:18811/;' && ok "slot gate: slot1 port" || bad "slot gate: slot1 port"
has "$SLOT" 'location /s/3/ {'                    && ok "slot gate: /s/3/ (looped to slots)" || bad "slot gate: /s/3/"
has "$SLOT" 'proxy_pass http://127.0.0.1:18813/;' && ok "slot gate: slot3 port" || bad "slot gate: slot3 port"
grep -q 'location /s/4/' <<<"$SLOT" && bad "slot gate: must NOT emit slots beyond count" || ok "slot gate: no over-count slot"
has "$SLOT" 'proxy_pass http://127.0.0.1:18810;'  && ok "slot gate: /api/ -> manager" || bad "slot gate: /api/"
has "$SLOT" 'location = /airlock-return.js'       && ok "slot gate: serves return widget" || bad "slot gate: widget"
has "$SLOT" 'proxy_set_header Tailscale-User-Login $http_tailscale_user_login;' && ok "slot gate: re-injects identity to manager" || bad "slot gate: identity re-inject"
grep -q 'proxy_set_header X-Forwarded' <<<"$SLOT" && bad "slot gate: must NOT set X-Forwarded" || ok "slot gate: no X-Forwarded"
grep -q '@@' <<<"$SLOT" && bad "slot gate: unresolved placeholder" || ok "slot gate: no placeholder"

# 4. nft render fills template, no leftover placeholders
NFT="$(render_loopback_nft airlock_orca 18821)"
has "$NFT" 'table inet airlock_orca'      && ok "nft: table name" || bad "nft: table"
has "$NFT" 'tcp dport 18821 drop'         && ok "nft: port drop rule" || bad "nft: port"
grep -q '@@' <<<"$NFT" && bad "nft: unresolved placeholder" || ok "nft: no placeholder"

# 5. missing AIRLOCK_IDENTITY_HEADER -> loud failure (not silent empty map)
if ( unset AIRLOCK_IDENTITY_HEADER; emit_identity_map x owner >/dev/null 2>&1 ); then
  bad "fail-loud: emit_identity_map without header"
else
  ok "fail-loud: emit_identity_map without header"
fi

# 7. owner gate with an extra-locations file — inserted INSIDE the server, before }
EXTRA="$(mktemp)"
printf '    location = /orca-web/probe { return 204; }\n' > "$EXTRA"
GATE2="$(emit_owner_gate 9910 127.0.0.1:9911 owner_ok '' bottom-right "$EXTRA")"
rm -f "$EXTRA"
has "$GATE2" 'location = /orca-web/probe { return 204; }' && ok "gate: extra location emitted" || bad "gate: extra location"
ln_loc=$(grep -n 'location / {'   <<<"$GATE2" | head -1 | cut -d: -f1)
ln_x=$(grep -n 'orca-web/probe'   <<<"$GATE2" | head -1 | cut -d: -f1)
ln_end=$(grep -n '.' <<<"$GATE2" | tail -1 | cut -d: -f1)
{ [ -n "$ln_loc" ] && [ -n "$ln_x" ] && [ "$ln_x" -gt "$ln_loc" ] && [ "$ln_x" -lt "$ln_end" ]; } \
  && ok "gate: extra sits after location / and before server close" || bad "gate: extra placement"
[ "$(printf '%s\n' "$GATE2" | tail -1)" = "}" ] && ok "gate: server closes after extra" || bad "gate: server close"
# omitting the extra arg must be byte-identical to before (additive change)
[ "$(emit_owner_gate 9910 127.0.0.1:9911 owner_ok)" = "$GATE" ] \
  && ok "gate: no-extra output unchanged" || bad "gate: no-extra output changed"

# 6. FULL nginx -t validation (if nginx present) — compose a real config
if command -v nginx >/dev/null 2>&1; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  # orca-shaped extra locations: a $orca_redir-driven root + a static /orca-web/ alias.
  ORCA_EXTRA="$TMP/orca-extra.conf"
  cat > "$ORCA_EXTRA" <<'NGINX'
    location = / {
        absolute_redirect off;
        if ($owner_ok = 0) { return 403; }
        if ($orca_redir) { return 302 $orca_redir; }
        proxy_pass http://127.0.0.1:9911;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400s;
    }
    location = /web-index.html {
        absolute_redirect off;
        if ($owner_ok = 0) { return 403; }
        return 302 /orca-web/web-index.html$is_args$args;
    }
    location = /orca-web/web-index.html {
        if ($owner_ok = 0) { return 403; }
        alias /nonexistent/dist/web-index.html;
        default_type text/html;
        add_header Cache-Control "no-store" always;
        sub_filter '</body>' '<script src="/airlock-return.js" defer></script></body>';
        sub_filter_once on;
    }
    location /orca-web/assets/ {
        if ($owner_ok = 0) { return 403; }
        alias /nonexistent/dist/assets/;
        access_log off;
    }
NGINX
  {
    # self-contained paths so `nginx -t` needs no privileged dirs
    echo "pid \"$TMP/nginx.pid\";"
    echo "error_log \"$TMP/error.log\";"
    echo "events {}"
    echo "http {"
    echo "    access_log off;"
    echo "    client_body_temp_path \"$TMP/cbt\";"
    echo "    proxy_temp_path \"$TMP/pt\";"
    echo "    fastcgi_temp_path \"$TMP/ft\";"
    echo "    uwsgi_temp_path \"$TMP/ut\";"
    echo "    scgi_temp_path \"$TMP/st\";"
    emit_connection_upgrade_map
    emit_identity_map owner_ok "me@example.com"
    emit_owner_gate 9910 127.0.0.1:9911 owner_ok
    emit_slot_gate 18808 18811 3 18810 owner_ok "$TMP" shell.html "$TMP/airlock-return.js"
    # orca zero-paste map (http context) + the orca-shaped owner gate with extras
    printf 'map $http_upgrade $orca_redir {\n    default "/orca-web/web-index.html#pairing=deadbeef";\n    "websocket" "";\n}\n'
    emit_owner_gate 9930 127.0.0.1:9931 owner_ok "$TMP/ret.js" bottom-right "$ORCA_EXTRA"
    echo "}"
  } > "$TMP/nginx.conf"
  : > "$TMP/ret.js"
  if nginx -t -c "$TMP/nginx.conf" -p "$TMP" >/dev/null 2>&1; then
    ok "nginx -t: composed config (incl. orca extras + \$orca_redir map) is valid"
  else
    bad "nginx -t: composed config invalid"; nginx -t -c "$TMP/nginx.conf" -p "$TMP" 2>&1 | sed 's/^/    /'
  fi
else
  echo "skip nginx -t (nginx not installed — CI validates)"
fi

echo "---"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
