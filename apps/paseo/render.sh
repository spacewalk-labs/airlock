# shellcheck shell=bash
# apps/paseo/render.sh — sourceable render library (child 4, P1a
# extract-verify-swap). Functions only, no top-level execution. Each
# heredoc-bearing function body is a VERBATIM copy of the heredoc it
# replaces, proven byte-identical to the inline text by
# install/test-render-parity.sh before any write site moves (P1b).
#
# render_paseo_nginx composes the smaller pieces exactly as install.sh's
# fragment-assembly block does (same marker-splice order via sed -i on a
# scratch file) — a procedural copy of the splicing logic, since the
# original assembly is several heredocs plus shell logic, not one heredoc.

# render_paseo_unit UNIT_PATH HOME FQDN HTTPS_PORT PASEO_BIN BACKEND_PORT PY PID_GUARD \
#                   MEMMAX MEMHIGH TASKSMAX NNP_BLOCK
# HOME is a local (shadows $HOME for this function only — pops on return) so
# the heredoc body below can reference ${HOME} exactly as the source does.
# PY/PID_GUARD: interpreter + apps/paseo/paseo-clear-stale-pid.py path, spliced
# into an ExecStartPre that reaps a stale $HOME/.paseo/paseo.pid before start
# (see that script's header for why: upstream never reaps it itself).
# MEMMAX/MEMHIGH/TASKSMAX: resource backstop, picked from the box's RAM tier by
# the caller (install.sh). Passed in rather than computed here so the rendered text
# stays a pure function of its arguments — the golden-render tests depend on it.
# NNP_BLOCK: normally the single line `NoNewPrivileges=yes`. When the installer
# has been told to proceed on a snap-wrapped node it is that line turned off plus
# the comment saying why — assembled by the caller and passed as ONE argument, on
# purpose. This heredoc is unquoted, and the reason text quotes a shell command;
# a value substituted into a heredoc is not re-scanned for substitution, so the
# text arrives literally no matter what it contains. Building it here instead
# would put operator-facing prose back inside the heredoc, which is exactly the
# shape that deleted three words from this unit on 2026-08-07.
render_paseo_unit() {
  local UNIT_PATH="$1" HOME="$2" FQDN="$3" HTTPS_PORT="$4" PASEO_BIN="$5" BACKEND_PORT="$6" \
        PY="$7" PID_GUARD="$8" MEMMAX="$9" MEMHIGH="${10}" TASKSMAX="${11}" \
        NNP_BLOCK="${12:-NoNewPrivileges=yes}"
  cat <<UNITEOF
[Unit]
Description=airlock-paseo — Paseo daemon (coding-agent orchestration + web UI) behind the owner gate
Documentation=https://github.com/getpaseo/paseo
# NOT After=default.target: this unit is WantedBy=default.target below, and a
# unit that is both Wanted by a target and ordered After that SAME target is a
# guaranteed ordering cycle (the target gets an implicit After= on everything
# it Wants — systemd.unit(5) "Default Dependencies" — so default.target ends
# up After= this unit AND this unit After= default.target). Measured on a real
# box: "Found ordering cycle on default.target/start ... Job
# airlock-paseo-browse-host.service/start deleted to break ordering cycle" —
# the unit never started on boot, only via a manual 'systemctl start'.
# network.target matches every other app unit in this repo (dev-monitor,
# devterm, feedback, publish, code-server) and carries no such back-edge.
After=network.target

[Service]
Type=simple
# Explicit PATH: npm global bin + provider CLI dirs + node + system. The daemon
# spawns provider CLIs against this PATH — a mismatch is the #1 pilot gotcha.
Environment=PATH=${UNIT_PATH}
# Provider CLI credential paths (claude=~/.claude, codex/gemini=~/.config).
Environment=HOME=${HOME}
Environment=XDG_CONFIG_HOME=${HOME}/.config
Environment=PASEO_HOME=${HOME}/.paseo
# Trust the reverse proxy (nginx@127.0.0.1) X-Forwarded-Proto https so the web UI
# uses wss:// (gate specific (1)/(2)). Without this the WebSocket fails behind TLS.
Environment=PASEO_TRUSTED_PROXIES=127.0.0.1
# DNS-rebinding host allowlist — must accept the Host the gate forwards (fqdn WITH
# the https port, gate specific (3)) plus localhost.
Environment=PASEO_HOSTNAMES=${FQDN},${FQDN}:${HTTPS_PORT},localhost
# Headless: no dictation/voice (avoids an unexpected ~600MB speech model download).
Environment=PASEO_DICTATION_ENABLED=false
Environment=PASEO_VOICE_MODE_ENABLED=false
# Reap a stale singleton pidfile before every start (including on-boot and every
# Restart=always retry): upstream (@getpaseo/cli) writes \$PASEO_HOME/paseo.pid to
# enforce "only one daemon" but never reaps it itself, so a record surviving a
# reboot (stale pid, sometimes already reused by an unrelated process) makes the
# daemon refuse to start FOREVER with "Another Paseo daemon is already running" —
# measured on a real box, RestartSec=3 looping it (counter into double digits).
# Leading '-': a guard-script problem must never block the real ExecStart; the
# script itself only ever deletes the file when it can prove staleness (dead pid,
# or a live pid whose uid/hostname/start-time contradict the record) and always
# exits 0 either way. See apps/paseo/paseo-clear-stale-pid.py.
ExecStartPre=-${PY} ${PID_GUARD} ${HOME}/.paseo/paseo.pid
# --foreground: Type=simple. --no-relay: no upstream relay outbound. --web-ui: the
# browser UI. --listen 127.0.0.1: loopback bind (the gate is the only ingress).
ExecStart=${PASEO_BIN} daemon start --foreground --no-relay --web-ui --listen 127.0.0.1:${BACKEND_PORT}
# always, not on-failure: the web UI's "restart daemon" is a websocket shutdown RPC
# that exits the worker cleanly (status 0) and expects a supervisor to bring it back.
# Under on-failure systemd reads that as an intended stop and leaves it dead — so the
# button permanently kills the daemon (the gate stays up, so it just looks hung).
# An explicit 'systemctl --user stop' still stops it: always only covers self-exit.
# (Single quotes, not backticks: this heredoc is unquoted, so backticks here would
# be command substitution — the comment would RUN at install time and vanish.)
Restart=always
RestartSec=3
# Backstop, not a reservation (idle ~440M) — a ceiling this unit must never cross,
# not memory set aside for it. Picked by the installer from a RAM tier table
# (standard 5.5G/5G; >=16 GiB -> 14G/12G), so a runaway multi-session tree cannot take
# the machine down with it. No box is refused over this: on a box smaller than the
# tier the ceiling is inert and the installer says so.
#
# MemoryHigh, a little under max, is the part that matters in practice. MemoryMax alone
# is a cliff: the cgroup runs flat out to the ceiling and then the allocation is
# refused, and each runtime dies its own way there (node=SIGABRT, chrome=SIGTRAP,
# python=SIGSEGV) with no warning first. MemoryHigh does not refuse — it forces
# reclaim and throttles, so the result is a slowdown instead of a crash, and the
# 'high' counter in memory.events becomes an early signal. Measured on a box that
# had max but no high: high 1,886,403 / max 27,479 / oom_kill 0 — the kernel never
# killed anything, the sessions just got strangled and timed out. Read the counters
# with: cat /sys/fs/cgroup/user.slice/user-\$(id -u).slice/user@\$(id -u).service/\\
#       app.slice/airlock-paseo.service/memory.events
# 'high' climbing is by design; 'max' climbing means the box is too small.
# Keep high < max — above max it is inert.
MemoryMax=${MEMMAX}
MemoryHigh=${MEMHIGH}
# Agent trees fork wide (a CLI plus its children per session, times N sessions).
# 1024 was a real ceiling on a busy box: pids.events 'max' climbs, fork() starts
# failing, and it surfaces as unrelated-looking tool errors rather than as a
# resource limit. 24576 was the next guess, chosen on one box.
#
# Owner decision (2026-08-07): the default is the most this box can give, not a
# number picked somewhere else. 'infinity' is not "unbounded" for a --user unit —
# it is enclosed by user-<uid>.slice, whose pids.max is the real ceiling (339389
# on the box this was measured on; systemd's DefaultTasksMax is 15% of
# kernel.threads-max elsewhere). Deferring to that is the only spelling of
# "maximum" that stays true when the box changes; a number derived here would
# bake one kernel's limits into a golden, which is the mistake the memory block
# above already had to unlearn.
#
# What it costs, stated plainly: this unit no longer carries a pids backstop of
# its own, so 'pids.events' on the unit will never show 'max' climbing — the
# slice's will instead. AIRLOCK_PASEO_TASKS_MAX puts a finite one back.
TasksMax=${TASKSMAX}
${NNP_BLOCK}

[Install]
WantedBy=default.target
UNITEOF
}

# render_paseo_nginx_base GATE_PORT BACKEND_PORT FQDN HTTPS_PORT WIDGET WIDGET_MENU_ATTRS
# Body still carries the @@ICON_LOC@@ / @@BROWSE_LOC@@ markers — spliced by
# render_paseo_nginx below, exactly as install.sh's sed -i does on the file.
# The four leading "# paseo owner gate ..." comment lines are separate `echo`
# statements in install.sh, outside this heredoc — render_paseo_nginx (the
# composition function) emits them, matching the original structure exactly.
render_paseo_nginx_base() {
  local GATE_PORT="$1" BACKEND_PORT="$2" FQDN="$3" HTTPS_PORT="$4" WIDGET="$5" WIDGET_MENU_ATTRS="$6"
  sed -e "s/@@LISTEN@@/${GATE_PORT}/g" \
      -e "s|@@UPSTREAM@@|127.0.0.1:${BACKEND_PORT}|g" \
      -e "s|@@HOSTPORT@@|${FQDN}:${HTTPS_PORT}|g" \
      -e "s|@@WIDGET@@|${WIDGET}|g" \
      -e "s|@@WIDGET_MENU@@|${WIDGET_MENU_ATTRS}|g" <<'NGINX'
server {
    listen 127.0.0.1:@@LISTEN@@;
    server_name _;

    # paseo serves an upstream web UI we cannot edit, so the gate serves + injects
    # the shared "return to Airlock" widget (floating, bottom-right).
    location = /airlock-return.js { alias @@WIDGET@@; default_type application/javascript; add_header Cache-Control "no-cache" always; access_log off; }
@@ICON_LOC@@
@@BROWSE_LOC@@
    location / {
        if ($owner_ok = 0) { return 403; }
        proxy_pass http://@@UPSTREAM@@;
        proxy_http_version 1.1;
        # Host WITH the port — $host strips it and triggers a welcome-screen bug.
        proxy_set_header Host @@HOSTPORT@@;
        # This gate is a plain-http listener, so $scheme would be 'http'. Tell the
        # daemon it is behind TLS or the web UI opens ws:// and the socket dies.
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400s;
        # return-to-Airlock widget: uncompressed HTML so sub_filter applies (WS/JS
        # bundles are untouched — sub_filter only rewrites text/html).
        proxy_set_header Accept-Encoding "";
        sub_filter '</body>' '<script src="/airlock-return.js" data-anchor="bottom-right"@@WIDGET_MENU@@ defer></script></body>';
        sub_filter_once on;
    }
}
NGINX
}

# render_paseo_browse_location BROWSE_WS_PORT — the @@BROWSE_LOC@@ splice body.
render_paseo_browse_location() {
  local BROWSE_WS_PORT="$1"
  sed -e "s|@@STREAM@@|127.0.0.1:${BROWSE_WS_PORT}|g" <<'BLOC'

    location /browse-view/ {
        if ($owner_ok = 0) { return 403; }
        proxy_pass http://@@STREAM@@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
BLOC
}

# render_paseo_icon_favicon CONFD — the @@ICON_LOC@@ splice body (favicon.ico only).
render_paseo_icon_favicon() {
  local CONFD="$1"
  cat <<ILOC

    location = /favicon.ico {
        if (\$owner_ok = 0) { return 403; }
        alias $CONFD/paseo/favicon-ring.svg;
        # nginx types-maps the REQUEST uri (.ico), not the alias target (.svg), so it
        # would label this SVG image/x-icon and the browser would fail to parse it.
        # An empty types{} block drops that mapping so default_type is what ships.
        types { }
        default_type image/svg+xml;
        add_header Cache-Control "no-cache" always;
        access_log off;
    }
ILOC
}

# render_paseo_icon_variants CONFD — appended after the favicon block only when
# at least one runtime tab-icon variant was ringed (ring_n > 0).
render_paseo_icon_variants() {
  local CONFD="$1"
  cat <<ILOC2

    location ~ ^/assets/assets/images/(favicon-[^/]+)\.png\$ {
        if (\$owner_ok = 0) { return 403; }
        # The upstream name says .png; the ringed copy is an SVG, so the same
        # types{}-clearing trick as /favicon.ico applies.
        alias $CONFD/paseo/icons/\$1.svg;
        types { }
        default_type image/svg+xml;
        add_header Cache-Control "no-cache" always;
        access_log off;
    }
ILOC2
}

# render_paseo_nginx GATE_PORT BACKEND_PORT FQDN HTTPS_PORT WIDGET WIDGET_MENU_ATTRS \
#                    BROWSE BROWSE_WS_PORT ICON_LOC_BODY(may be empty)
#
# ICON_LOC_BODY is the caller-supplied already-rendered @@ICON_LOC@@ splice
# text (favicon [+ variants], or empty when icon_ring is off) — install.sh
# computes it (ring_icon_svg calls, on-disk variant discovery) outside any
# heredoc, so it is not this library's concern; render_paseo_icon_favicon /
# render_paseo_icon_variants above are the pieces a caller composes it from.
render_paseo_nginx() {
  local GATE_PORT="$1" BACKEND_PORT="$2" FQDN="$3" HTTPS_PORT="$4" WIDGET="$5" \
        WIDGET_MENU_ATTRS="$6" BROWSE="$7" BROWSE_WS_PORT="$8" ICON_LOC_BODY="${9:-}"
  local frag; frag="$(mktemp)"
  {
    echo "# paseo owner gate — generated by apps/paseo/install.sh"
    echo "# Written directly (not via emit_owner_gate) so it can add the two headers"
    echo "# the paseo daemon requires behind TLS: X-Forwarded-Proto https and a Host"
    echo "# WITH the https port. See install.sh header + apps/paseo/README.md."
    render_paseo_nginx_base "$GATE_PORT" "$BACKEND_PORT" "$FQDN" "$HTTPS_PORT" \
      "$WIDGET" "$WIDGET_MENU_ATTRS"
  } > "$frag"

  if [ "$BROWSE" = true ]; then
    local bloc; bloc="$(mktemp)"
    render_paseo_browse_location "$BROWSE_WS_PORT" > "$bloc"
    sed -i -e "/@@BROWSE_LOC@@/r $bloc" -e "/@@BROWSE_LOC@@/d" "$frag"
    rm -f "$bloc"
  else
    sed -i "/@@BROWSE_LOC@@/d" "$frag"
  fi

  if [ -n "$ICON_LOC_BODY" ]; then
    local iloc; iloc="$(mktemp)"
    # Trailing newline restored: callers build ICON_LOC_BODY via command
    # substitution (which strips it), but install.sh's original iloc file
    # (built with `cat > file <<ILOC`) always ended in exactly one newline.
    printf '%s\n' "$ICON_LOC_BODY" > "$iloc"
    sed -i -e "/@@ICON_LOC@@/r $iloc" -e "/@@ICON_LOC@@/d" "$frag"
    rm -f "$iloc"
  else
    sed -i "/@@ICON_LOC@@/d" "$frag"
  fi

  cat "$frag"
  rm -f "$frag"
}
