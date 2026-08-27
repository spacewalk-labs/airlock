# shellcheck shell=bash
# apps/orca/render.sh — sourceable render library (child 4, P1a
# extract-verify-swap). Functions only, no top-level execution. Each
# heredoc-bearing function body is a VERBATIM copy of the heredoc it
# replaces, proven byte-identical to the inline text by
# install/test-render-parity.sh before any write site moves (P1b).
#
# render_orca_nginx composes the smaller pieces exactly as install.sh's
# fragment-assembly block does (same order, same conditionals) — a
# procedural copy of the splicing logic rather than a single heredoc, since
# the original assembly is itself several heredocs plus shell logic, not one.

# render_orca_reap_script — no substitution: the source heredoc uses a quoted
# delimiter ('REAP'), so $HOME/$f/etc. are literal in the installed script,
# not expanded at render time. No args.
render_orca_reap_script() {
  cat <<'REAP'
#!/usr/bin/env bash
# airlock-orca daemon reap — ExecStopPost for airlock-orca.service.
#
# Orca's daemon directory and app-orca scopes are also used by legacy stacks.
# INVOCATION_ID is injected by systemd and inherited by the detached daemon, so
# it is the ownership proof: never delete a pidfile or stop a scope merely
# because its name looks like Orca's.
invocation="${INVOCATION_ID:-}"
[ -n "$invocation" ] || exit 0
declare -a scopes=()
for f in "$HOME"/.config/orca/daemon/daemon-v*.pid; do
    [ -f "$f" ] || continue
    p=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$f" 2>/dev/null)
    [ -n "$p" ] || continue
    [ -r "/proc/$p/environ" ] || continue
    tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null \
        | grep -Fqx "INVOCATION_ID=$invocation" || continue
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
        *orca*) ;;  # exact invocation + executable family: PID-reuse safe
        *) continue ;;
    esac
    unit=$(systemctl --user whoami "$p" 2>/dev/null || true)
    case "$unit" in
        app-orca-*.scope) scopes+=("$unit") ;;
    esac
    kill "$p" 2>/dev/null || true
    rm -f "$f"
done
# Reclaim only scopes measured from this invocation's daemon PID. A glob would
# also match a concurrently running legacy instance.
if [ "${#scopes[@]}" -gt 0 ]; then
    mapfile -t scopes < <(printf '%s\n' "${scopes[@]}" | sort -u)
    systemctl --user stop "${scopes[@]}" 2>/dev/null || true
fi
exit 0
REAP
}

# render_orca_unit_xvfb XDISP
render_orca_unit_xvfb() {
  local XDISP="$1"
  cat <<UNIT
[Unit]
Description=airlock-orca-xvfb — dedicated virtual display (:${XDISP}) for Orca ADE
# NOT After=default.target: this unit is WantedBy=default.target below, and a
# unit both Wanted by a target and ordered After that same target is a
# guaranteed ordering cycle (the target gets an implicit After= on everything
# it Wants — systemd.unit(5) "Default Dependencies"). Same anti-pattern
# measured and fixed in apps/paseo/render.sh — see that comment for the exact
# boot-log signature. network.target matches every other non-dependent app
# unit in this repo and carries no such back-edge.
After=network.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
# Never unlink this display's lock/socket here. ExecStartPre runs again on every
# failed restart, and a competing legacy X server may still own both resources.
# The installer hands over the measured owner before start; a race or stale file
# therefore makes Xvfb fail loudly without damaging the other runtime.
# -extension GLX: on boxes with NVIDIA userspace EGL/GBM libs, Xvfb SIGSEGVs while
#   loading libEGL_nvidia during GLX init (no real GPU in a container). orca renders
#   with LIBGL_ALWAYS_SOFTWARE so it never needs server GLX -> disabling it is safe.
ExecStart=/usr/bin/Xvfb :${XDISP} -screen 0 1280x1024x24 -nolisten tcp -extension GLX
# active != socket-ready -> poll for the socket (up to ~10s) so orca's After holds.
ExecStartPost=/bin/sh -c 'for _ in \$(seq 1 100); do [ -S /tmp/.X11-unix/X${XDISP} ] && exit 0; sleep 0.1; done; exit 1'
# Resource conflicts exit nonzero and must not loop; abnormal termination such
# as the measured NVIDIA/GLX SIGSEGV may still recover.
Restart=on-abnormal
RestartSec=2

[Install]
WantedBy=default.target
UNIT
}

# render_orca_unit_serve SQUASHFS XDISP APPRUN BACKEND_PORT PAIRING_CODE FQDN HTTPS_PORT SERVELOG REAP_BIN
render_orca_unit_serve() {
  local SQUASHFS="$1" XDISP="$2" APPRUN="$3" BACKEND_PORT="$4" PAIRING_CODE="$5" \
        FQDN="$6" HTTPS_PORT="$7" SERVELOG="$8" REAP_BIN="$9"
  cat <<UNIT
[Unit]
Description=airlock-orca — Orca ADE headless serve (behind the 127.0.0.1 owner gate)
Requires=airlock-orca-xvfb.service
# NOT After=default.target — same WantedBy=default.target ordering-cycle
# anti-pattern as airlock-orca-xvfb.service above; see that comment.
After=network.target airlock-orca-xvfb.service

[Service]
Type=simple
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=APPDIR=${SQUASHFS}
# DISPLAY is provided by the dedicated Xvfb unit; without it orca SIGSEGVs.
Environment=DISPLAY=:${XDISP}
# Defensive: even with xvfb active the socket can lag a moment — wait for it.
ExecStartPre=/bin/sh -c 'for _ in \$(seq 1 100); do [ -S /tmp/.X11-unix/X${XDISP} ] && exit 0; sleep 0.1; done; echo "X${XDISP} socket not ready"; exit 1'
# --pairing-code fixed (above) -> stable webClientUrl. --pairing-address rewrites
# the endpoint the web client dials to the public gate (default ws://0.0.0.0:BACKEND
# is not browser-reachable). The webClientUrl is only ever emitted to serve.log
# (Electron stdout never reaches journald), so capture it there.
ExecStart=/bin/sh -c 'exec ${APPRUN} serve --port ${BACKEND_PORT} --pairing-code ${PAIRING_CODE} --pairing-address wss://${FQDN}:${HTTPS_PORT} > ${SERVELOG} 2>&1'
# The daemon self-detaches into app-orca-*.scope, so reclaim it on stop.
ExecStopPost=${REAP_BIN}
Restart=on-failure
RestartSec=3
# Backstop only — app-orca-*.scope lives in app.slice, outside this cap.
MemoryMax=8G
TasksMax=1024
NoNewPrivileges=yes

[Install]
WantedBy=default.target
UNIT
}

# render_orca_unit_firewall BACKEND_PORT NFT_FILE
render_orca_unit_firewall() {
  local BACKEND_PORT="$1" NFT_FILE="$2"
  cat <<UNIT
[Unit]
Description=airlock-orca firewall — drop non-loopback traffic to :${BACKEND_PORT} (orca binds 0.0.0.0)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Idempotent re-apply: drop only our own table, then reload it (docker untouched).
ExecStart=/bin/sh -c '/usr/sbin/nft delete table inet airlock_orca 2>/dev/null; /usr/sbin/nft -f ${NFT_FILE}'
ExecStop=/usr/sbin/nft delete table inet airlock_orca

[Install]
WantedBy=multi-user.target
UNIT
}

# render_orca_nginx_extra BACKEND_PORT ORCA_DIST_SERVE WIDGET_MENU_ATTRS
# Only called when the patched web client is vendored (ORCA_WEB_ENABLED=1).
render_orca_nginx_extra() {
  local BACKEND_PORT="$1" ORCA_DIST_SERVE="$2" WIDGET_MENU_ATTRS="$3"
  cat <<NGINX
    # ---- patched Orca web client (vendored) + zero-paste entry ----
    location = / {
        absolute_redirect off;
        if (\$owner_ok = 0) { return 403; }
        if (\$orca_redir) { return 302 \$orca_redir; }
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 86400s;
        # WS-safe: no X-Forwarded-* (orca verifies Origin).
    }
    location = /web-index.html {
        absolute_redirect off;
        if (\$owner_ok = 0) { return 403; }
        return 302 /orca-web/web-index.html\$is_args\$args;
    }
    location = /orca-web/web-index.html {
        if (\$owner_ok = 0) { return 403; }
        alias ${ORCA_DIST_SERVE}/web-index.html;
        default_type text/html;
        add_header Cache-Control "no-store" always;
        sub_filter '</body>' '<script src="/airlock-return.js" data-anchor="bottom-right"${WIDGET_MENU_ATTRS} defer></script></body>';
        sub_filter_once on;
    }
    location /orca-web/assets/ {
        if (\$owner_ok = 0) { return 403; }
        alias ${ORCA_DIST_SERVE}/assets/;
        access_log off;
    }
NGINX
}

# render_orca_nginx_map pairing_frag — only called when ORCA_WEB_ENABLED=1.
render_orca_nginx_map() {
  local pairing_frag="$1"
  cat <<NGINX
map \$http_upgrade \$orca_redir {
    default     "/orca-web/web-index.html${pairing_frag}";
    "websocket" "";
}
NGINX
}

# render_orca_nginx GATE_PORT BACKEND_PORT WEBROOT ORCA_WEB_ENABLED ORCA_DIST_SERVE \
#                   WIDGET_MENU_ATTRS pairing_frag
# Procedural copy of install.sh's fragment-assembly block (same order, same
# conditionals): the extra web-client locations file feeds emit_owner_gate's
# extra_locations_file argument exactly as the inline install.sh does.
# Requires AIRLOCK_IDENTITY_HEADER in the environment (emit_owner_gate reads it
# indirectly via the widget/anchor path — kept identical to the call site).
render_orca_nginx() {
  local GATE_PORT="$1" BACKEND_PORT="$2" WEBROOT="$3" ORCA_WEB_ENABLED="$4" \
        ORCA_DIST_SERVE="$5" WIDGET_MENU_ATTRS="$6" pairing_frag="$7"
  local extra="" extra_arg=""
  if [ "$ORCA_WEB_ENABLED" = 1 ]; then
    extra="$(mktemp)"; extra_arg="$extra"
    render_orca_nginx_extra "$BACKEND_PORT" "$ORCA_DIST_SERVE" "$WIDGET_MENU_ATTRS" > "$extra"
  fi
  {
    echo "# orca owner gate — generated by apps/orca/install.sh"
    if [ "$ORCA_WEB_ENABLED" = 1 ]; then
      render_orca_nginx_map "$pairing_frag"
    fi
    emit_owner_gate "$GATE_PORT" "127.0.0.1:${BACKEND_PORT}" owner_ok \
      "${WEBROOT}/assets/airlock-return.js" bottom-right "$extra_arg"
  }
  [ -n "$extra" ] && rm -f "$extra"
  return 0
}
