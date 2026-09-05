#!/usr/bin/env bash
# install/test-systemd-ordering.sh — regression guard for the reboot-breaking
# systemd ordering-cycle bug measured on a real box:
#
#   airlock-paseo.service: Found ordering cycle on default.target/start
#   airlock-paseo.service: Found dependency on airlock-paseo-browse-host.service/start
#   airlock-paseo.service: Found dependency on airlock-paseo.service/start
#   airlock-paseo.service: Job airlock-paseo-browse-host.service/start deleted to break ordering cycle
#
# Result: airlock-paseo-browse-host.service stayed `enabled` but `inactive
# (dead)` after every boot -- recoverable only by a manual `systemctl --user
# start`. Root cause (systemd.unit(5) "Default Dependencies"): a target unit
# (e.g. default.target) that Wants= a unit -- which is exactly what
# WantedBy=<target> in a unit's [Install] section creates at enable time --
# automatically gets an implicit After=<that unit> ("target units will
# complement all configured dependencies of type Wants=/Requires= with
# dependencies of type After="). So ANY unit that is both
# WantedBy=default.target AND explicitly After=default.target is a guaranteed
# 2-node ordering cycle: default.target wants it -> default.target gets an
# implicit After=<unit> -> and the unit is itself explicitly After=
# default.target. No third unit is required for the cycle to exist, though a
# chain through a third unit (exactly what the real box hit, via
# airlock-paseo-browse-host.service's After=airlock-paseo.service) is exactly
# as broken and is what systemd's cycle-breaking algorithm happened to report
# first.
#
# Why this is a hand-rolled graph check, not `systemd-analyze verify`: verify
# only evaluates a unit's OWN configured After=/Before=/Wants=/Requires=
# lines -- the implicit ordering [Install]/WantedBy= creates only exists once
# something has actually run `systemctl enable` inside a real systemd
# instance (a `.wants/` symlink materialising). Confirmed by hand against
# `systemd-analyze verify --root=<sysroot>` with the .wants/ symlinks
# actually created: verify plus real .wants/ symlinks DOES reproduce this
# exact cycle, but requires a full, non-trivial, real OS unit tree under
# --root (sysinit.target, /bin/true, etc. all have to resolve) that is
# awkward to fabricate hermetically and touches real systemd unit-file
# resolution machinery this suite otherwise never needs (no sudo, no
# network, no daemon, no live systemd instance -- see test-render-parity.sh's
# header for the same discipline). A plain, from-scratch graph model of the
# ONE documented rule this bug class depends on is simpler, faster, and
# needs nothing but the units' own rendered text.
#
# Every unit's real content is pulled from the SAME apps/<id>/render.sh
# functions install.sh actually calls (sourced live, called with the same
# representative fixture values install/test-render-parity.sh uses) --  so
# this test re-derives the graph from the live templates every run and
# cannot silently drift out of sync with a stale golden snapshot. The one
# exception is apps/paseo/browse-host/install.sh, which predates render.sh
# (a standalone, not-yet-wired-into-v1 follow-up installer -- see its own
# header) and writes its unit from an inline heredoc rather than a render.sh
# function; that heredoc is extracted directly from the live file by marker
# (see extract_browse_host_unit below), for the same "re-derive every run"
# reason.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"

pass=0 fail=0
ok(){ echo "ok   $1"; pass=$((pass+1)); }
bad(){ echo "FAIL $1"; fail=$((fail+1)); }

# ===========================================================================
# Graph model
#
# EDGE_BEFORE["ns:a"]="ns:b ns:c ..." -- "a" must be ordered (start-)before
# each of b, c, ... Namespaced "user:<name>" / "system:<name>": --user and
# --system are separate systemd instances with entirely separate
# default.target/multi-user.target graphs, so an edge must never cross the
# prefix (this repo renders exactly one --system unit,
# airlock-orca-firewall.service -- see apps/orca/install.sh:238).
# ===========================================================================
declare -A EDGE_BEFORE
NODES=""

add_node() { case " $NODES " in *" $1 "*) ;; *) NODES="$NODES $1" ;; esac; }
add_edge() { # add_edge before after -- "before" must start before "after"
  local b="$1" a="$2"
  add_node "$b"; add_node "$a"
  EDGE_BEFORE["$b"]="${EDGE_BEFORE[$b]:-} $a"
}
reset_graph() { EDGE_BEFORE=(); NODES=""; }

# ingest_unit NAMESPACE NAME UNIT_TEXT -- parses After=/Before=/WantedBy=/
# RequiredBy= lines out of a unit's rendered [Unit]/[Install] text and adds
# the corresponding edges. Requires=/Wants= alone (without a matching
# After=/Before=) add NO ordering in real systemd and are deliberately not
# modeled -- every unit in this repo that uses Requires=/Wants= for ordering
# purposes already pairs it with an explicit After= on the same target(s)
# (e.g. airlock-orca.service: "Requires=airlock-orca-xvfb.service" +
# "After=... airlock-orca-xvfb.service"), so this is not a coverage gap.
ingest_unit() {
  # Two separate `local` statements, not one `local ns=$1 full=$ns:...`: bash
  # expands every word on a `local` line before any of that line's
  # assignments take effect, so a later name referencing an earlier one in
  # the SAME `local` statement sees the outer (often unset) scope, not the
  # value just declared -- an unbound-variable trap under `set -u`.
  local ns="$1" name="$2" text="$3"
  local full="$ns:$name"
  add_node "$full"
  local line tok
  while IFS= read -r line; do
    case "$line" in
      After=*)
        for tok in ${line#After=}; do add_edge "$ns:$tok" "$full"; done ;;
      Before=*)
        for tok in ${line#Before=}; do add_edge "$full" "$ns:$tok"; done ;;
      WantedBy=*|RequiredBy=*)
        # [Install] WantedBy=/RequiredBy=T creates, at enable time, a
        # T.wants//T.requires/ symlink -- equivalent to T's own unit file
        # containing Wants=/Requires=<this unit>. Per systemd.unit(5)
        # "Default Dependencies", a target then complements every configured
        # Wants=/Requires= with an implicit After= on the same unit -- so T
        # ends up ordered After= this unit, i.e. this unit must be Before= T.
        for tok in ${line#*=}; do add_edge "$full" "$ns:$tok"; done ;;
    esac
  done <<<"$text"
}

# ===========================================================================
# Cycle detection: recursive DFS, gray/black coloring, reports the cycle path
# it finds (not just "a cycle exists somewhere") so a future failure is
# actionable without re-deriving the graph by hand.
# ===========================================================================
declare -A COLOR
CYCLE_PATH=""

dfs() {
  local u="$1"
  COLOR["$u"]="gray"
  CYCLE_PATH="${CYCLE_PATH:+$CYCLE_PATH }$u"
  local v
  for v in ${EDGE_BEFORE[$u]:-}; do
    case "${COLOR[$v]:-white}" in
      gray)  CYCLE_PATH="$CYCLE_PATH $v"; return 1 ;;
      black) : ;;
      *) dfs "$v" || return 1 ;;
    esac
  done
  COLOR["$u"]="black"
  CYCLE_PATH="${CYCLE_PATH% "$u"}"
  return 0
}

# find_any_cycle -- on return 0, CYCLE_PATH holds a witness cycle (space
# separated node names, first node repeated at the end).
find_any_cycle() {
  COLOR=()
  local n
  for n in $NODES; do
    if [ "${COLOR[$n]:-white}" != "black" ]; then
      CYCLE_PATH=""
      if ! dfs "$n"; then return 0; fi
    fi
  done
  return 1
}

# assert_acyclic LABEL -- ok/bad against the graph built so far.
assert_acyclic() {
  local label="$1"
  if find_any_cycle; then
    bad "$label: ordering cycle found: $CYCLE_PATH"
  else
    ok "$label: no ordering cycle"
  fi
}

# ===========================================================================
# Self-check: prove the detector itself actually catches a cycle, on a
# synthetic graph, before trusting it to clear the real one. Independent of
# today's repo state -- this stays meaningful even after every real bug here
# is long fixed.
# ===========================================================================
reset_graph
add_edge "user:a" "user:b"
add_edge "user:b" "user:c"
add_edge "user:c" "user:a"
if find_any_cycle; then
  ok "self-check: detector finds an injected 3-node cycle (a->b->c->a): $CYCLE_PATH"
else
  bad "self-check: detector MISSED an injected 3-node cycle -- the checker itself is broken, every other result in this file is untrustworthy"
fi
reset_graph
add_edge "user:x" "user:y"
add_edge "user:y" "user:z"
if find_any_cycle; then
  bad "self-check: detector reported a cycle on an acyclic graph (x->y->z, no back edge): $CYCLE_PATH"
else
  ok "self-check: detector correctly reports no cycle on a plain acyclic chain"
fi
# The exact real-world shape (WantedBy=default.target + After=default.target
# on one unit, no third party needed): must be caught standalone.
reset_graph
ingest_unit user "self-cycle.service" "After=default.target
WantedBy=default.target"
if find_any_cycle; then
  ok "self-check: WantedBy=default.target + After=default.target on the SAME unit is caught with no third unit involved: $CYCLE_PATH"
else
  bad "self-check: WantedBy=default.target + After=default.target on the same unit was NOT flagged -- the core rule this whole test exists for is not modeled"
fi

# ===========================================================================
# Real graph: every systemd unit this repo can render, built from the live
# render.sh functions (or, for browse-host, the live install.sh heredoc) with
# the same representative fixture values install/test-render-parity.sh uses.
# One shared "user:" graph (the --user manager instance) plus the repo's one
# "system:" unit -- namespaces never cross, matching two independent systemd
# instances.
# ===========================================================================
reset_graph

extract_browse_host_unit() {
  # apps/paseo/browse-host/install.sh writes its unit via a plain
  # `cat > "$UNIT" <<EOF ... EOF` heredoc (no render.sh -- see that
  # installer's own header: a standalone follow-up, not yet wired into v1).
  # Extract the heredoc body by marker so this stays live-derived rather
  # than a copy-pasted snapshot.
  sed -n '/^cat > "\$UNIT" <<EOF$/,/^EOF$/p' "$ROOT/apps/paseo/browse-host/install.sh" \
    | sed '1d;$d'
}

# ---- paseo ----
APP="$ROOT/apps/paseo"; . "$APP/render.sh"
UNIT_PATH="/home/example/.npm-global/bin:/home/example/.local/bin:/usr/local/bin:/usr/bin:/bin"
HOME_VAL="/home/example"; FQDN="box.example.ts.net"; HTTPS_PORT=19700
PASEO_BIN="/home/example/.npm-global/bin/paseo"; BACKEND_PORT=19701
PY="/usr/bin/python3"; STALE_PID_GUARD="$APP/paseo-clear-stale-pid.py"
PASEO_UNIT_TEXT="$(render_paseo_unit "$UNIT_PATH" "$HOME_VAL" "$FQDN" "$HTTPS_PORT" "$PASEO_BIN" "$BACKEND_PORT" "$PY" "$STALE_PID_GUARD" "30720M" "28672M" 24576)"
ingest_unit user "airlock-paseo.service" "$PASEO_UNIT_TEXT"

BROWSE_HOST_UNIT_TEXT="$(extract_browse_host_unit)"
if [ -z "$BROWSE_HOST_UNIT_TEXT" ]; then
  bad "extract_browse_host_unit: got empty text -- the marker no longer matches apps/paseo/browse-host/install.sh (fix the sed marker, this suite would otherwise silently skip that unit)"
else
  ingest_unit user "airlock-paseo-browse-host.service" "$BROWSE_HOST_UNIT_TEXT"
fi

# ---- orca ----
APP="$ROOT/apps/orca"; . "$APP/render.sh"
XDISP=59; SQUASHFS="/home/example/.local/share/airlock-orca/squashfs-root"
APPRUN="$SQUASHFS/AppRun"; PAIRING_CODE="deadbeefcafef00d1234567890abcdef"
ORCA_BACKEND_PORT=19600; ORCA_HTTPS_PORT=19601
SERVELOG="/home/example/.local/share/airlock-orca/serve.log"
REAP_BIN="/home/example/.local/bin/airlock-orca-reap"
NFT_FILE="/etc/airlock/orca-loopback.nft"
ingest_unit user "airlock-orca-xvfb.service" "$(render_orca_unit_xvfb "$XDISP")"
ingest_unit user "airlock-orca.service" "$(render_orca_unit_serve "$SQUASHFS" "$XDISP" "$APPRUN" "$ORCA_BACKEND_PORT" "$PAIRING_CODE" "$FQDN" "$ORCA_HTTPS_PORT" "$SERVELOG" "$REAP_BIN")"
ingest_unit system "airlock-orca-firewall.service" "$(render_orca_unit_firewall "$ORCA_BACKEND_PORT" "$NFT_FILE")"

# ---- code-server ----
APP="$ROOT/apps/code-server"; . "$APP/render.sh"
CS_BACKEND_PORT=19100; CS_BACKEND_BASE=$((CS_BACKEND_PORT - 1)); CS_MANAGER_PORT=19199
CS_OWNER="owner@fixture.dev"; CS_ID_HEADER="Tailscale-User-Login"
ingest_unit user "airlock-code-server@.service" "$(render_code_server_unit_slot "$CS_BACKEND_BASE" "1|2|3" 3)"
ingest_unit user "airlock-code-server-manager.service" "$(render_code_server_unit_manager "$CS_MANAGER_PORT" 3 "$CS_BACKEND_PORT" "$CS_OWNER" "$CS_ID_HEADER")"

# ---- dev-monitor ----
APP="$ROOT/apps/dev-monitor"; . "$APP/render.sh"
ingest_unit user "airlock-dev-monitor.service" "$(render_dev_monitor_unit 19200 false "Tailscale-User-Login" "box.example.ts.net,box" "/home/example/.config/airlock/dev-monitor.env")"
ingest_unit system "airlock-dev-monitor-spool-firewall.service" "$(render_dev_monitor_spool_firewall_unit)"

# ---- devterm ----
APP="$ROOT/apps/devterm"; . "$APP/render.sh"
ingest_unit user "airlock-devterm.service" "$(render_devterm_unit_ttyd "C.UTF-8" 19300 "/home/example/.local/bin/ttyd" 15)"
# gate_env carries the unit PATH the installer derives (apps/devterm/install.sh) —
# pinned here, not measured, for the same reason as the paseo UNIT_PATH above.
DEVTERM_GATE_ENV="Environment=PATH=/home/example/.local/bin:/home/example/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
"
ingest_unit user "airlock-devterm-gate.service" "$(render_devterm_unit_gate 19301 "$DEVTERM_GATE_ENV" "$PY" "$APP/backend/devterm-gate.py")"

# ---- fileview ----
# One unit now: markserv is gone and its renderer with it. This used to ingest
# two, and to assert that the markserv unit carried a runtime PATH — a check that
# only ever existed because a `#!/usr/bin/env node` script needed one.
APP="$ROOT/apps/fileview"; . "$APP/render.sh"
ingest_unit user "airlock-fileview.service" "$(render_fileview_unit_filebrowser 19401 "/home/example/.local/bin/filebrowser" "/home/example/.config/airlock-fileview/fb.db")"

# ---- feedback ----
APP="$ROOT/apps/feedback"; . "$APP/render.sh"
ingest_unit user "airlock-feedback.service" "$(render_feedback_unit 19500 "Tailscale-User-Login" "" "AIRLOCK_FEEDBACK_TOKEN" "" "" "" "")"

# ---- publish ----
APP="$ROOT/apps/publish"; . "$APP/render.sh"
PUB_ARGS=(19800 "/opt/airlock/share" "/home/example/uploads" "Tailscale-User-Login" "" "" "AIRLOCK_PUBLISH_TOKEN" remote "" "/home/example/.local/state/airlock" "/opt/airlock/share-gated" "/opt/airlock/publish-gated-auth" htpasswd X-Airlock-Publish-Token)
ingest_unit user "airlock-publish.service" "$(render_publish_unit_service "${PUB_ARGS[@]}")"
ingest_unit user "airlock-publish-cleanup.service" "$(render_publish_unit_cleanup "/home/example/uploads" remote "" "/home/example/.local/state/airlock" "/opt/airlock/share-gated" "/opt/airlock/publish-gated-auth" htpasswd)"
ingest_unit user "airlock-publish-cleanup.timer" "$(render_publish_unit_timer)"

echo "graph: ${#NODES} bytes of node names, $(printf '%s\n' "$NODES" | wc -w) nodes"
assert_acyclic "full rendered unit set (user + system namespaces together)"

echo
echo "systemd-ordering: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
