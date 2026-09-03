#!/usr/bin/env bash
# install/test-render-parity.sh — child 4, P1b: extract-verify-swap's second
# half (docs/tasks/active/app-pkg-c4-builtin-migration.md, "Approach" P1,
# "Extract-verify-swap" — "P1b: swap each write site onto the emission
# helper ... render outputs asserted against the P1a goldens").
#
# P1a proved every apps/<id>/render.sh function byte-identical to the inline
# heredoc it replaced and committed F13 baselines under
# install/golden/render/**. P1b swapped every write site onto the render.sh
# functions and deleted the inline heredocs — so this suite is now render
# function vs P1a golden (a regression pin), plus (after review round 2) a
# handful of fixtures that exercise the REAL installer call sites, not just
# the render.sh functions directly.
#
# Comparison is BYTE-EXACT (`cmp`), not string equality on a `$(...)`
# capture: command substitution strips ALL trailing newlines, so an earlier
# revision of this suite passed even when a heredoc's trailing blank line
# went missing — caught by adversarial review (round 2), fixed here. Every
# render_* call below redirects DIRECTLY to a file (never captured into a
# shell variable first) so the exact bytes, trailing newline included, reach
# the comparison.
#
# Variable sets enumerate every artifact-producing branch found by reading
# each installer (recorded per app below). Composition functions that
# assemble several heredocs procedurally (orca/paseo nginx) are goldened as
# a whole; round 2 found one of them (render_paseo_nginx's icon_ring splice)
# had a real bug that the P1a string-based comparison could not see — see
# the paseo section for the icon-on/icon-on-variants sets that now pin it.
#
# Scope: renders only — sources apps/<id>/render.sh (a library of functions,
# no top-level execution) and gate/nginx-lib.sh; no network, no sudo for the
# direct-render sections. The "installer-path" and "render-dir combo/guard"
# sections at the bottom run REAL install.sh scripts end to end, always
# under AIRLOCK_DRY_RUN=1 (install/lib.sh now fails closed if
# AIRLOCK_RENDER_DIR is set without it — see the guard fixture).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
export ROOT
GOLDEN="$HERE/golden/render"
MODE="${1:-check}"
TMP="$(mktemp -d)"
NGTMP=""
NGSOCKDIR=""
NGINX_PARITY_PID=""
nginx_parity_cleanup() {
  if [ -n "$NGINX_PARITY_PID" ] && kill -0 "$NGINX_PARITY_PID" 2>/dev/null; then
    kill -TERM "$NGINX_PARITY_PID" 2>/dev/null || true
    wait "$NGINX_PARITY_PID" 2>/dev/null || true
  fi
  [ -z "$NGTMP" ] || chmod 700 "$NGTMP/private" 2>/dev/null || true
  rm -rf "$TMP"
  [ -z "$NGTMP" ] || rm -rf "$NGTMP"
  [ -z "$NGSOCKDIR" ] || rm -rf "$NGSOCKDIR"
}
trap nginx_parity_cleanup EXIT
# paseo's real installer resolves node's bin dir off PATH (`readlink -f
# "$(command -v node)"`) into the unit's Environment=PATH — a box-real,
# non-fixture-controlled absolute path. The installer-path fixtures run the
# REAL install.sh (see run_installer_path below), so paseo's captured unit
# bakes this box's node location in unless normalised out here, same as
# $ROOT/$WDIR/$TMP.
# Two dirs now, not one: since 2026-08-07 the installers put the directory node was
# FOUND in on the unit PATH as well as the one it resolves to, because a snap wrapper
# resolves to /usr/bin and takes `node` off the unit's PATH entirely. They are the
# same value on most boxes (nvm, apt, a tarball) and differ on a snap box.
NODE_FOUND_BIN_DIR=""
NODE_REAL_BIN_DIR=""
if command -v node >/dev/null 2>&1; then
  NODE_FOUND_BIN_DIR="$(dirname "$(command -v node)")"
  NODE_REAL_BIN_DIR="$(dirname "$(readlink -f "$(command -v node)")" 2>/dev/null || true)"
  [ "$NODE_REAL_BIN_DIR" = "$NODE_FOUND_BIN_DIR" ] && NODE_REAL_BIN_DIR=""
fi
pass=0 fail=0
ok(){ echo "ok   $1"; pass=$((pass+1)); }
bad(){ echo "FAIL $1"; fail=$((fail+1)); }

# Every command ANY shipped app could need (F11 assembly: the raw TSV plus
# every migrated app's manifest-declared [[prerequisites]] rows) — a P2
# migration deletes an app's TSV row the moment its manifest row lands, so
# scanning install/prerequisites.tsv alone under-covers once an app (nft for
# orca, npm for paseo, ...) has no TSV row left at all. Computed once, used
# everywhere below that shims "any missing prerequisite command" (mirrors
# install/test-equivalence.sh's rationale, generalised to manifests).
ALL_PREREQ_CMDS_CFG="$TMP/all-prereq-cmds.toml"
{
  printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n'
  find "$ROOT/apps" -mindepth 1 -maxdepth 1 -type d -printf '[apps.%f]\n' | sort
} > "$ALL_PREREQ_CMDS_CFG"
ALL_PREREQ_CMDS="$(AIRLOCK_CONFIG="$ALL_PREREQ_CMDS_CFG" python3 "$ROOT/bin/airlock-config" prereqs 2>/dev/null \
  | awk -F '\t' 'NF >= 2 {print $2}' | sort -u)"
[ -n "$ALL_PREREQ_CMDS" ] || echo "WARN: could not assemble prerequisite commands (F11) — shim coverage may be incomplete" >&2

# shellcheck source=/dev/null
. "$ROOT/gate/nginx-lib.sh"

# out_file — a genuinely fresh scratch path under $TMP for a render_* call
# to redirect into (`render_x ... > "$(out_file)"`), via `mktemp` rather
# than a counter: `f="$(out_file)"` runs the counter increment inside a
# command-substitution SUBSHELL, so a plain `_seq=$((_seq+1))` counter never
# advances in the parent shell and every call would silently collide on the
# same path — mktemp sidesteps that instead of relying on every call site
# being coincidentally safe under reuse.
out_file() { mktemp -p "$TMP"; }

# render_to <outfile> <render_fn> [args...]
# Every DIRECT renderer call in this suite goes through here.
#
# A render_* function is supposed to be a pure function of its arguments: exit 0,
# write the artifact to stdout, and say nothing else. The third part was never
# checked, and that is the whole of defect 5. render_paseo_unit's body is
# `cat <<UNITEOF` with no quotes, so two backticked words in its own comments were
# command substitution: the shell ran them, printed three `command not found`
# lines to stderr, and dropped `infinity`, `pids.events` and `max` out of the
# rendered unit. The function still returned 0 — `cat` succeeded, and `cat`'s
# status is the function's status — and the redirection above sent only stdout to
# the file, so the diagnosis went to the terminal and the damage went to the
# golden. This suite then reported 106 passed, 0 failed.
#
# rc and non-empty stdout are cheap and included for completeness. The assertion
# that would have caught it is the empty-stderr one.
#
# Note where this does NOT belong: install/test-equivalence.sh folds stderr into
# the transcript it compares on purpose (":103-107" — a new warning on the
# built-in path is a behaviour change too), and its golden opens with 74 warning
# lines. Asserting silence there would have turned CI red on day one for a design
# that was already right. Renderers called directly are the place where "wrote to
# stderr" has no legitimate meaning.
RENDER_CLEAN=()      # outfile -> 1, consulted by golden_check_file --regen
render_calls=0
render_dirty=0
render_to() {
  local out="$1"; shift
  local fn="$1" errf rc=0
  errf="$out.err"
  render_calls=$((render_calls+1))
  "$@" > "$out" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "render: $fn exited $rc"
    sed 's/^/    /' "$errf"
  elif [ ! -s "$out" ]; then
    bad "render: $fn wrote nothing to stdout"
  elif [ -s "$errf" ]; then
    bad "render: $fn wrote to stderr — a renderer is a pure function of its arguments and has nobody to talk to"
    sed 's/^/    /' "$errf"
  else
    RENDER_CLEAN+=("$out")
    return 0
  fi
  render_dirty=$((render_dirty+1))
  return 1
}

# Was this file produced by a render_to call that came back clean?
# Files that no renderer produced (installer-path captures, the nginx skeleton,
# the tile projection) answer "unknown" and are left to the checks that already
# cover them — this guard is about renderers, and claiming more than that would
# make it another rule nobody trusts.
render_was_clean() {
  local want="$1" got
  for got in ${RENDER_CLEAN+"${RENDER_CLEAN[@]}"}; do
    [ "$got" = "$want" ] && return 0
  done
  return 1
}
render_was_known() {
  case "$1" in "$TMP"/*) [ -e "$1.err" ] && return 0 ;; esac
  return 1
}

# golden_check_file <path-under-GOLDEN> <srcfile>
# BYTE-EXACT (`cmp`), not string comparison. --regen: writes the file (after
# normalising this checkout's absolute $ROOT out of it — several render
# functions embed a $ROOT-derived backend script path — via `sed`, which on
# this box preserves a missing final newline exactly as found, so the
# normalisation step itself introduces no byte drift). check (default):
# `cmp -s` against what's committed.
golden_check_file() {
  local rel="$1" srcfile="$2" path norm
  path="$GOLDEN/$rel"
  norm="$(out_file).norm"
  sed -e "s|$ROOT|ROOT|g" \
      -e 's|proxy_set_header X-Devmon-Proxy-Secret "[^"]\+";|proxy_set_header X-Devmon-Proxy-Secret "DEVMON_SECRET";|' \
      "$srcfile" > "$norm"
  if [ "$MODE" = "--regen" ]; then
    # The golden learned defect 5 because --regen is a `cp`. Whatever the renderer
    # emitted became the expected answer, including the three words it had just
    # deleted from itself, and every later run agreed with the damage. So a regen
    # from a renderer that failed render_to's checks is refused here: the fix for
    # "the test learned a bug" cannot be "someone should read the diff", because
    # someone did and it still shipped.
    if render_was_known "$srcfile" && ! render_was_clean "$srcfile"; then
      bad "golden NOT written: $rel — the renderer that produced it was not clean (see the render: failure above)"
      return 1
    fi
    mkdir -p "$(dirname "$path")"
    cp "$norm" "$path"
    ok "golden written: $rel"
    return 0
  fi
  if [ ! -f "$path" ]; then
    bad "golden missing: $rel (run: bash $0 --regen)"
    return 1
  fi
  if cmp -s "$path" "$norm"; then
    ok "golden: $rel"
  else
    bad "golden: $rel (byte-exact drift from committed baseline — regen if intended)"
    cmp "$path" "$norm" 2>&1 | sed 's/^/    /'
    diff "$path" "$norm" 2>&1 | head -n 20 | sed 's/^/    /'
  fi
}

# ===========================================================================
# code-server — apps/code-server/render.sh
# Branch: SLOTS (1 vs N) changes the unit@ ExecCondition case list
# (SLOT_CASE) and emit_slot_gate's per-slot location count. Sets: slots1,
# slots3.
# ===========================================================================
APP="$ROOT/apps/code-server"
. "$APP/render.sh"
for SET in slots1 slots3; do
  case "$SET" in
    slots1) SLOTS=1; SLOT_CASE=1 ;;
    slots3) SLOTS=3; SLOT_CASE="1|2|3" ;;
  esac
  BACKEND_PORT=19100; BACKEND_BASE=$((BACKEND_PORT - 1)); MANAGER_PORT=19199
  GATE_PORT=19198; AIRLOCK_OWNER="owner@fixture.dev"; AIRLOCK_IDENTITY_HEADER="Tailscale-User-Login"
  WEBROOT="/opt/airlock/hub"; SHELL_DIR="/etc/airlock/nginx/code-server"

  f="$(out_file)"; render_to "$f" render_code_server_unit_slot "$BACKEND_BASE" "$SLOT_CASE" "$SLOTS"
  golden_check_file "code-server/$SET/unit-slot.service" "$f"

  f="$(out_file)"; render_to "$f" render_code_server_unit_manager "$MANAGER_PORT" "$SLOTS" "$BACKEND_PORT" "$AIRLOCK_OWNER" "$AIRLOCK_IDENTITY_HEADER"
  golden_check_file "code-server/$SET/unit-manager.service" "$f"

  export AIRLOCK_IDENTITY_HEADER
  f="$(out_file)"; render_to "$f" render_code_server_nginx "$GATE_PORT" "$BACKEND_PORT" "$SLOTS" "$MANAGER_PORT" "$SHELL_DIR" "$WEBROOT"
  golden_check_file "code-server/$SET/nginx.conf" "$f"
done

# ===========================================================================
# dev-monitor — apps/dev-monitor/render.sh
# Branch: MESSAGES (true vs false) adds the owner_location NGXOWNER block to
# the nginx fragment and changes the unit's Environment=...MESSAGES=
# literal. Sets: messages-off, messages-on. Plus a cors_hosts="" variant
# (FQDN unresolved — install.sh:59-69) since it is a real, cheap-to-cover
# value case for the same unit heredoc.
#
# Second branch: TOKEN_FRESHNESS. The credential-freshness card is gated by three
# Environment= lines in the same unit, and the arguments carrying them are OPTIONAL
# positionals — so the set below pins BOTH the defaulted shape (every set that passes
# five arguments, as the pre-feature call sites still do) and the configured one
# (token-freshness-on). A default that silently changed would otherwise turn the
# feature on, or off, with nothing to see.
# ===========================================================================
APP="$ROOT/apps/dev-monitor"
. "$APP/render.sh"
# Direct renderer cases do not source install/lib.sh, so hand in the same D5 value
# explicitly. An empty golden would prove only that the line exists, not that the
# platform path survives the package-local rename.
AIRLOCK_ACCOUNTS_STATUS_BIN="/opt/example/airlock/bin/airlock-accounts-status"
# The env-file renderer gets its own secret-empty golden. A non-empty webhook or
# proxy secret in a committed golden would turn a fixture into a credential copy.
f="$(out_file)"; render_to "$f" render_dev_monitor_env \
  "owner@fixture.dev" "" "/home/example/.local/state/airlock/dev-monitor" \
  "/home/example" "devmon-exec" "" "" "https://box.example.ts.net/monitor/#messages"
golden_check_file "dev-monitor/env/messages-on.env.txt" "$f"
# The email lane configured, pinned separately. The lane being off is the shape most boxes
# have, so it is the shape a golden most easily freezes by accident: without this case a
# renderer that dropped all five SMTP lines would still match the golden above, and the
# email path would go missing with nothing to see. The password stays empty here for the
# same reason the webhooks do.
f_mail="$(out_file)"; render_to "$f_mail" render_dev_monitor_env \
  "owner@fixture.dev" "" "/home/example/.local/state/airlock/dev-monitor" \
  "/home/example" "devmon-exec" "" "" "https://box.example.ts.net/monitor/#messages" \
  "relay.example.com" "587" "dev-monitor@example.com" "owner@fixture.dev" "devmon" ""
golden_check_file "dev-monitor/env/messages-on-email.env.txt" "$f_mail"
# The roster path (P4) configured, pinned separately for the same reason the email lane
# is: unconfigured is the shape most boxes have (the golden above), so it is the shape a
# regression most easily hides behind. A path is not a secret, so unlike the SMTP/webhook
# fixtures this one carries a real-looking value rather than an empty placeholder.
f_roster="$(out_file)"; render_to "$f_roster" render_dev_monitor_env \
  "owner@fixture.dev" "" "/home/example/.local/state/airlock/dev-monitor" \
  "/home/example" "devmon-exec" "" "" "https://box.example.ts.net/monitor/#messages" \
  "" "" "" "" "" "" "/home/example/.local/state/roster/roster.json"
golden_check_file "dev-monitor/env/messages-on-roster.env.txt" "$f_roster"
for f_secret in "$f" "$f_mail" "$f_roster"; do
  if grep -Eq '^(DEV_MONITOR_PROXY_SECRET|DEV_MONITOR_SMTP_PASSWORD|AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_(URGENT|ROUTINE))=.+$' "$f_secret"; then
    bad "dev-monitor env golden source contains a non-empty secret"
  else
    ok "dev-monitor env golden source contains no non-empty secret"
  fi
done
for SET in messages-off messages-on messages-off-no-cors token-freshness-on; do
  BACKEND_PORT=19200; IDENTITY_HEADER="Tailscale-User-Login"
  DEVMON_ENV="/home/example/.config/airlock/dev-monitor.env"
  cors_hosts="box.example.ts.net,box"
  hdr_var="$(printf '%s' "${IDENTITY_HEADER//-/_}" | tr '[:upper:]' '[:lower:]')"
  DEVMON_SECRET="deadbeefcafef00d"
  TOKEN_ARGS=()
  case "$SET" in
    messages-off) MESSAGES=false; owner_location="" ;;
    messages-on)
      MESSAGES=true
      ;;
    messages-off-no-cors) MESSAGES=false; owner_location=""; cors_hosts="" ;;
    token-freshness-on)
      MESSAGES=true
      TOKEN_ARGS=(true 6 12)
      ;;
  esac

  f="$(out_file)"; render_to "$f" render_dev_monitor_unit "$BACKEND_PORT" "$MESSAGES" "$IDENTITY_HEADER" "$cors_hosts" "$DEVMON_ENV" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}
  golden_check_file "dev-monitor/$SET/unit.service" "$f"

  if [ "$MESSAGES" = true ]; then
    f="$(out_file)"; render_to "$f" render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET"
    owner_location="$(cat "$f")"
  fi

  f="$(out_file)"; render_to "$f" render_dev_monitor_owner_location \
    "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" '= /monitor/api/owner/updates'
  updates_location="$(cat "$f")"
  f="$(out_file)"; render_to "$f" render_dev_monitor_owner_location \
    "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" '/monitor/api/owner/updates/'
  updates_location="$updates_location$(cat "$f")"
  f="$(out_file)"; render_to "$f" render_dev_monitor_owner_location \
    "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" '/monitor/api/owner/harness/'
  updates_location="$updates_location$(cat "$f")"
  f="$(out_file)"; render_to "$f" render_dev_monitor_nginx \
    "$BACKEND_PORT" "$updates_location" "$owner_location"
  golden_check_file "dev-monitor/$SET/nginx.conf" "$f"
done

# ===========================================================================
# devterm — apps/devterm/render.sh
# Branch: ACCOUNTS (true vs false) adds four Environment= lines (claude
# switch/status, fleet store) to the gate unit's gate_env block. The nginx
# fragment is unaffected by ACCOUNTS (composed via emit_owner_gate plus the
# platform account-panel alias block). Sets: accounts-off, accounts-on.
# ===========================================================================
APP="$ROOT/apps/devterm"
. "$APP/render.sh"
for SET in accounts-off accounts-on; do
  DEVTERM_LANG="C.UTF-8"; TTYD_PORT=19300; TTYD_BIN="/home/example/.local/bin/ttyd"; FONT_SIZE=15
  BACKEND_PORT=19301; GATE_PORT=19302; REDIRECT_PORT=19303
  PY="/usr/bin/python3"; GATE_PY="$APP/backend/devterm-gate.py"
  WEB_ROOT="/home/example/.local/share/airlock-devterm/web"
  IDENTITY_HEADER="Tailscale-User-Login"; AIRLOCK_OWNER="owner@fixture.dev"
  CODE_ROOT=""; FILEVIEW=false; REMOTE_HOSTS=""; ORCA_SHIM=""
  XAI=false
  REV="deadbeefcafe"
  CANON="https://box.example.ts.net:${GATE_PORT}"
  ACCOUNT_PANEL_DIR="/opt/airlock/hub/assets/accounts"

  # Mirrors install.sh's add_env() construction — the derived gate_env block
  # is not itself a heredoc, so it is reproduced here rather than extracted.
  # The unit PATH is pinned rather than measured, same reason as fileview/paseo
  # above: install.sh derives the node slot from airlock_cmd_dirs, and a real node
  # dir would make the golden depend on whichever box ran the suite. The
  # installer-path fixture below is where the derived value is checked.
  UNIT_PATH="%h/.local/bin:%h/.npm-global/bin:NODE_BIN:/usr/local/bin:/usr/bin:/bin"
  gate_env=""
  add_env() { gate_env="${gate_env}Environment=$1=$2
"; }
  add_env PATH "$UNIT_PATH"
  case "$SET" in
    accounts-off) ACCOUNTS=false ;;
    accounts-on)
      ACCOUNTS=true
      CLAUDE_SWITCH="$ROOT/bin/airlock-accounts"
      CLAUDE_STATUS="$ROOT/bin/airlock-accounts-status"
      FLEET_STORE=""; FLEET_STORE_URL=""
      ;;
  esac
  add_env DEVTERM_REV "$REV"
  add_env DEVTERM_LISTEN_HOST 127.0.0.1
  add_env DEVTERM_LISTEN_PORT "$BACKEND_PORT"
  add_env DEVTERM_TTYD_HOST 127.0.0.1
  add_env DEVTERM_TTYD_PORT "$TTYD_PORT"
  add_env DEVTERM_WEB "$WEB_ROOT"
  add_env AIRLOCK_IDENTITY_HEADER "$IDENTITY_HEADER"
  add_env AIRLOCK_OWNER "$AIRLOCK_OWNER"
  add_env AIRLOCK_CODE_ROOT "$CODE_ROOT"
  add_env DEVTERM_FILEVIEW "$FILEVIEW"
  add_env DEVTERM_ACCOUNTS "$ACCOUNTS"
  add_env DEVTERM_XAI "$XAI"
  add_env DEVTERM_REMOTE_HOSTS "$REMOTE_HOSTS"
  add_env DEVTERM_ORCA_SHIM "$ORCA_SHIM"
  add_env DEVTERM_ACCOUNTS_BIN "$ROOT/bin/airlock-accounts"
  add_env DEVTERM_SECRET_BIN "$ROOT/bin/airlock-secret"
  if [ "$ACCOUNTS" = true ]; then
    add_env DEVTERM_CLAUDE_STATUS "$CLAUDE_STATUS"
    add_env DEVTERM_CLAUDE_SWITCH "$CLAUDE_SWITCH"
    add_env DEVTERM_FLEET_STORE "$FLEET_STORE"
    add_env DEVTERM_FLEET_STORE_URL "$FLEET_STORE_URL"
  fi

  f="$(out_file)"; render_to "$f" render_devterm_unit_ttyd "$DEVTERM_LANG" "$TTYD_PORT" "$TTYD_BIN" "$FONT_SIZE"
  golden_check_file "devterm/$SET/unit-ttyd.service" "$f"

  f="$(out_file)"; render_to "$f" render_devterm_unit_gate "$BACKEND_PORT" "$gate_env" "$PY" "$GATE_PY"
  golden_check_file "devterm/$SET/unit-gate.service" "$f"

  if [ "$ACCOUNTS" = true ]; then
    f="$(out_file)"; render_to "$f" render_devterm_exec_shim "$CLAUDE_SWITCH"
    golden_check_file "devterm/$SET/shim-claude-switch" "$f"
    f="$(out_file)"; render_to "$f" render_devterm_exec_shim "$CLAUDE_STATUS"
    golden_check_file "devterm/$SET/shim-claude-status" "$f"
  fi

  # Arg 3 is the platform account-panel directory (ACCT_OWN). It used to be the
  # retired redirect port, which the function ignored; it does not ignore this one, so
  # the fixture names a webroot path rather than leaving a port to be read as one.
  f="$(out_file)"; render_to "$f" render_devterm_nginx "$GATE_PORT" "$BACKEND_PORT" "$ACCOUNT_PANEL_DIR"
  golden_check_file "devterm/$SET/nginx.conf" "$f"

  # The gate must forward the client Host VERBATIM. nginx's $host drops the port, and
  # the devterm backend's write guard (_secret_origin_ok) compares the browser Origin
  # -- which always carries the port -- against Host. Behind the non-443 `tailscale
  # serve` entrance, $host therefore made every same-origin account/secret write from
  # the owner's own page answer 403 "forbidden origin". The golden above pins the
  # bytes; this pins the reason, so a future rewrite cannot regen the defect back in.
  if grep -q 'proxy_set_header Host \$http_host;' "$f" \
     && ! grep -q 'proxy_set_header Host \$host;' "$f"; then
    ok "devterm/$SET: gate forwards the client Host verbatim (port survives to the origin guard)"
  else
    bad "devterm/$SET: gate must send Host \$http_host — \$host strips the port and the backend answers 403 forbidden origin"
  fi
done

# ===========================================================================
# feedback — apps/feedback/render.sh
# No structural branch: every var above just changes a value, never which
# lines are emitted. Two value sets for parameterization coverage: bare
# (nothing configured) and full (intake+mail configured).
# ===========================================================================
APP="$ROOT/apps/feedback"
. "$APP/render.sh"
for SET in bare full; do
  BACKEND_PORT=19400; IDENTITY_HEADER="Tailscale-User-Login"
  case "$SET" in
    bare)
      INTAKE_URL=""; TOKEN_ENV="AIRLOCK_FEEDBACK_TOKEN"
      MAIL_TO=""; MAIL_FROM=""; MAIL_API=""; MAIL_KEY_ENV="RESEND_API_KEY"
      ;;
    full)
      INTAKE_URL="https://intake.example.com/hook"; TOKEN_ENV="AIRLOCK_FEEDBACK_TOKEN"
      MAIL_TO="ops@example.com"; MAIL_FROM="Airlock <noreply@example.com>"
      MAIL_API="https://api.resend.com/emails"; MAIL_KEY_ENV="RESEND_API_KEY"
      ;;
  esac

  f="$(out_file)"; render_to "$f" render_feedback_unit "$BACKEND_PORT" "$IDENTITY_HEADER" "$INTAKE_URL" "$TOKEN_ENV" "$MAIL_TO" "$MAIL_FROM" "$MAIL_API" "$MAIL_KEY_ENV"
  golden_check_file "feedback/$SET/unit.service" "$f"

  f="$(out_file)"; render_to "$f" render_feedback_nginx "$BACKEND_PORT"
  golden_check_file "feedback/$SET/nginx.conf" "$f"
done

# ===========================================================================
# fileview — apps/fileview/render.sh
# No structural branch: FB_PORT is a value only. One set.
# ===========================================================================
APP="$ROOT/apps/fileview"
. "$APP/render.sh"
SET=default
FB_PORT=19501
FB_BIN="/home/example/.local/bin/filebrowser"
FB_DB="/home/example/.config/filebrowser/fb.db"

f="$(out_file)"; render_to "$f" render_fileview_unit_filebrowser "$FB_PORT" "$FB_BIN" "$FB_DB"
golden_check_file "fileview/$SET/unit.service" "$f"

f="$(out_file)"; render_to "$f" render_fileview_nginx "$FB_PORT"
golden_check_file "fileview/$SET/nginx.conf" "$f"

# ===========================================================================
# orca — apps/orca/render.sh
# Branch: ORCA_WEB_ENABLED (whether the patched web client bundle is
# vendored) adds the $orca_redir map + four extra locations to the nginx
# fragment; pairing_frag (whether the pairing blob was captured yet) changes
# the map's default target within the web-enabled branch — a real content
# difference, so it is its own set rather than a fixed value inside
# web-enabled. WIDGET_MENU_ATTRS empty (no devterm installed) is covered too
# — it feeds directly into the sub_filter line. The REAP script, xvfb unit,
# serve unit and firewall unit heredocs carry no branch (values only).
# ===========================================================================
APP="$ROOT/apps/orca"
. "$APP/render.sh"
SET=default
BACKEND_PORT=19600; XDISP=59; SQUASHFS="/home/example/.local/share/airlock-orca/squashfs-root"
APPRUN="$SQUASHFS/AppRun"; PAIRING_CODE="deadbeefcafef00d1234567890abcdef"
FQDN="box.example.ts.net"; HTTPS_PORT=19601
SERVELOG="/home/example/.local/share/airlock-orca/serve.log"
REAP_BIN="/home/example/.local/bin/airlock-orca-reap"
NFT_FILE="/etc/airlock/orca-loopback.nft"

f="$(out_file)"; render_to "$f" render_orca_reap_script
golden_check_file "orca/$SET/reap.sh" "$f"

f="$(out_file)"; render_to "$f" render_orca_unit_xvfb "$XDISP"
golden_check_file "orca/$SET/unit-xvfb.service" "$f"

f="$(out_file)"; render_to "$f" render_orca_unit_serve "$SQUASHFS" "$XDISP" "$APPRUN" "$BACKEND_PORT" "$PAIRING_CODE" "$FQDN" "$HTTPS_PORT" "$SERVELOG" "$REAP_BIN"
golden_check_file "orca/$SET/unit-serve.service" "$f"

f="$(out_file)"; render_to "$f" render_orca_unit_firewall "$BACKEND_PORT" "$NFT_FILE"
golden_check_file "orca/$SET/unit-firewall.service" "$f"

WEBROOT="/opt/airlock/hub"; ORCA_DIST_SERVE="/opt/airlock/orca-web/dist"
for SET in web-disabled web-enabled web-enabled-no-pairing web-enabled-no-widget-menu; do
  GATE_PORT=19602
  WIDGET_MENU_ATTRS=" data-menu=\"1\" data-panel=\"https://box.example.ts.net:19700/\""
  case "$SET" in
    web-disabled)               ORCA_WEB_ENABLED=0; pairing_frag="" ;;
    web-enabled)                ORCA_WEB_ENABLED=1; pairing_frag="#pairing=deadbeef1234" ;;
    web-enabled-no-pairing)     ORCA_WEB_ENABLED=1; pairing_frag="" ;;
    web-enabled-no-widget-menu) ORCA_WEB_ENABLED=1; pairing_frag="#pairing=deadbeef1234"; WIDGET_MENU_ATTRS="" ;;
  esac

  f="$(out_file)"; render_to "$f" render_orca_nginx "$GATE_PORT" "$BACKEND_PORT" "$WEBROOT" "$ORCA_WEB_ENABLED" "$ORCA_DIST_SERVE" "$WIDGET_MENU_ATTRS" "$pairing_frag"
  golden_check_file "orca/$SET/nginx.conf" "$f"
done

# ===========================================================================
# paseo — apps/paseo/render.sh
# Branch: BROWSE (true vs false) splices the /browse-view/ location into the
# nginx fragment; the daemon unit is unaffected. icon_ring (favicon only,
# and favicon+variants) splices the @@ICON_LOC@@ block — round 2 adversarial
# review found render_paseo_nginx's icon splice was byte-broken (a stripped
# trailing newline merged the spliced block into the next line, e.g.
# "}    location / {"), fixed by P1b's `printf '%s\n'`. These icon-on sets
# exist specifically to pin that fix: reverting the fix back to `printf
# '%s'` must fail these two golden checks. WIDGET_MENU_ATTRS empty is
# covered too. Sets: browse-off, browse-on, icon-on, icon-on-variants,
# no-widget-menu.
# ===========================================================================
APP="$ROOT/apps/paseo"
. "$APP/render.sh"
SET=default
UNIT_PATH="/home/example/.npm-global/bin:/home/example/.local/bin:/usr/local/bin:/usr/bin:/bin"
HOME_VAL="/home/example"; FQDN="box.example.ts.net"; HTTPS_PORT=19700
PASEO_BIN="/home/example/.npm-global/bin/paseo"; BACKEND_PORT=19701
PY="/usr/bin/python3"; STALE_PID_GUARD="$APP/paseo-clear-stale-pid.py"
# Fixed fixture values: the real numbers are the installer's share of the box, but the
# renderer must stay a pure function of its args for the golden to be stable.
# These are what a 32GiB box gets — 11/16 and 10/16 of 32 GiB.
MEMMAX="22528M"; MEMHIGH="20480M"; TASKSMAX=infinity

f="$(out_file)"; render_to "$f" render_paseo_unit "$UNIT_PATH" "$HOME_VAL" "$FQDN" "$HTTPS_PORT" "$PASEO_BIN" "$BACKEND_PORT" \
  "$PY" "$STALE_PID_GUARD" "$MEMMAX" "$MEMHIGH" "$TASKSMAX"
golden_check_file "paseo/$SET/unit.service" "$f"

# snap-node override (owner decision, 2026-08-07). AIRLOCK_ALLOW_SNAP_NODE=1 turns
# NoNewPrivileges off for THIS unit and renders why, so the next person reading the
# unit finds the reason in the unit rather than in a commit message. The block is
# assembled by the installer and passed as one argument; goldened here in both
# states because "renders the reason" is the whole of what the owner approved, and
# an override that silently drops the directive would pass a test that only checked
# the default.
PASEO_NNP_OFF="# NoNewPrivileges is deliberately OFF for this unit.
# node on this box is behind a snap wrapper (probes=[path resolved] found=/snap/bin/node resolved=/usr/bin/snap runtime=<unreadable>).
# snap re-executes through the setuid-root snap-confine, which NoNewPrivileges
# neuters; the unit then fails with status=1 and no output at all.
NoNewPrivileges=no"
f="$(out_file)"; render_to "$f" render_paseo_unit "$UNIT_PATH" "$HOME_VAL" "$FQDN" "$HTTPS_PORT" "$PASEO_BIN" "$BACKEND_PORT" \
  "$PY" "$STALE_PID_GUARD" "$MEMMAX" "$MEMHIGH" "$TASKSMAX" "$PASEO_NNP_OFF"
golden_check_file "paseo/snap-override/unit.service" "$f"

GATE_PORT=19702; WIDGET="/opt/airlock/hub/assets/airlock-return.js"
BROWSE_WS_PORT=19953
UISTATE_PORT=19954
CONFD_FIXTURE="/etc/airlock/nginx"

for SET in browse-off browse-on icon-on icon-on-variants no-widget-menu; do
  BROWSE=false
  WIDGET_MENU_ATTRS=" data-menu=\"1\" data-panel=\"https://box.example.ts.net:19300/\""
  ICON_LOC_BODY=""
  case "$SET" in
    browse-off) : ;;
    browse-on) BROWSE=true ;;
    icon-on)
      f="$(out_file)"; render_to "$f" render_paseo_icon_favicon "$CONFD_FIXTURE"
      ICON_LOC_BODY="$(cat "$f")"
      ;;
    icon-on-variants)
      f="$(out_file)"; render_to "$f" render_paseo_icon_favicon "$CONFD_FIXTURE"
      ICON_LOC_BODY="$(cat "$f")"
      f="$(out_file)"; render_to "$f" render_paseo_icon_variants "$CONFD_FIXTURE"
      ICON_LOC_BODY="$ICON_LOC_BODY
$(cat "$f")"
      ;;
    no-widget-menu) WIDGET_MENU_ATTRS="" ;;
  esac
  f="$(out_file)"; render_to "$f" render_paseo_nginx "$GATE_PORT" "$BACKEND_PORT" "$FQDN" "$HTTPS_PORT" "$WIDGET" "$WIDGET_MENU_ATTRS" "$BROWSE" "$BROWSE_WS_PORT" "$ICON_LOC_BODY" "$UISTATE_PORT"
  golden_check_file "paseo/$SET/nginx.conf" "$f"
  # icon-on / icon-on-variants: assert the splice did NOT merge into the
  # following line (the exact byte pattern round 2 found: a location block's
  # closing brace glued directly to the next directive with no newline).
  if [ "$SET" = "icon-on" ] || [ "$SET" = "icon-on-variants" ]; then
    # Precise pattern (not a generic "} followed by non-space" scan, which
    # false-positives on legitimate comment text like "types{}-clearing"
    # elsewhere in this same file): the exact bug signature round 2 found
    # was the icon splice's closing "    }" line glued directly onto the
    # following "location / {" line with no newline between them.
    if grep -qE '\}[[:space:]]*location[[:space:]]*/' "$f"; then
      bad "paseo/$SET nginx: a closing brace is glued to the next 'location /' directive (icon splice lost its trailing newline)"
      grep -nE '\}[[:space:]]*location[[:space:]]*/' "$f" | sed 's/^/    /'
    else
      ok "paseo/$SET nginx: icon splice trailing newline intact (no glued '}location')"
    fi
  fi
done

# ===========================================================================
# publish — apps/publish/render.sh
# Branch: PUBLIC_MODE (remote vs local) changes the unit's
# Environment=...PUBLIC_MODE/PUBLIC_DIR values (values only — no structural
# change to the unit heredoc) and, at the write site, whether the gated
# nginx fragment is even written. Sets: mode-remote, mode-local. Plus a
# sed-metacharacter set: publish_sed_replacement must escape \, &, | in a
# path before it reaches sed's replacement position, or a share_dir/
# gated_dir containing one of those bytes corrupts the rendered fragment
# (or breaks the sed invocation outright) instead of appearing literally.
# ===========================================================================
APP="$ROOT/apps/publish"
. "$APP/render.sh"
UPLOADS_DIR="/home/example/uploads"; IDENTITY_HEADER="Tailscale-User-Login"
SHARE_DIR="/opt/airlock/share"; STATE_DIR="/home/example/.local/state/airlock"
GATED_DIR="/opt/airlock/share-gated"; HTPASSWD_DIR="/opt/airlock/publish-gated-auth"
HTPASSWD_BIN="htpasswd"; INGEST_URL=""; BASE_URL=""; TOKEN_ENV="AIRLOCK_PUBLISH_TOKEN"
BACKEND_PORT=19800
for SET in mode-remote mode-local; do
  case "$SET" in
    mode-remote) PUBLIC_MODE=remote; PUBLIC_DIR="" ;;
    mode-local)  PUBLIC_MODE=local;  PUBLIC_DIR="/opt/airlock/share-public" ;;
  esac

  f="$(out_file)"; render_to "$f" render_publish_unit_service "$BACKEND_PORT" "$SHARE_DIR" "$UPLOADS_DIR" "$IDENTITY_HEADER" \
    "$INGEST_URL" "$BASE_URL" "$TOKEN_ENV" "$PUBLIC_MODE" "$PUBLIC_DIR" "$STATE_DIR" "$GATED_DIR" "$HTPASSWD_DIR" "$HTPASSWD_BIN"
  golden_check_file "publish/$SET/unit-service.service" "$f"

  f="$(out_file)"; render_to "$f" render_publish_unit_cleanup "$UPLOADS_DIR" "$PUBLIC_MODE" "$PUBLIC_DIR" "$STATE_DIR" "$GATED_DIR" "$HTPASSWD_DIR" "$HTPASSWD_BIN"
  golden_check_file "publish/$SET/unit-cleanup.service" "$f"

  f="$(out_file)"; render_to "$f" render_publish_unit_timer
  golden_check_file "publish/$SET/unit-timer.timer" "$f"

  f="$(out_file)"; render_to "$f" render_publish_nginx_main "$BACKEND_PORT" "$SHARE_DIR"
  golden_check_file "publish/$SET/nginx-main.conf" "$f"

  f="$(out_file)"; render_to "$f" render_publish_nginx_gated "$GATED_DIR" "$HTPASSWD_DIR"
  if [ "$PUBLIC_MODE" = local ]; then
    golden_check_file "publish/$SET/nginx-gated.conf" "$f"
  fi
done

SET=sed-metachars
SHARE_DIR_META='/opt/airlock/sha&re|dir\with'
f="$(out_file)"; render_to "$f" render_publish_nginx_main "$BACKEND_PORT" "$SHARE_DIR_META"
if grep -qF "$SHARE_DIR_META" "$f"; then
  ok "publish/$SET nginx-main: share_dir with sed metachars (\\, &, |) appears literally"
else
  bad "publish/$SET nginx-main: share_dir with sed metachars was corrupted, not passed through literally"
  sed 's/^/    /' "$f"
fi
golden_check_file "publish/$SET/nginx-main.conf" "$f"

# ===========================================================================
# nginx render golden (F13 baseline (a), the hub-level skeleton half).
#
# Captures install/render-nginx.sh's own output — the maps + hub server +
# plaintext redirect it renders directly — for a representative config with
# all nine built-in apps enabled. hub-locations.d/servers.d are created but
# left EMPTY here: the per-app fragment text is exactly what the goldens
# above pin, and the "installer-path" section below separately proves the
# real install.sh call sites produce byte-identical content to those
# goldens (round 2 Major: this suite previously only checked render.sh
# functions directly, never the actual call site argument wiring).
# ===========================================================================
NGTMP="$(mktemp -d)"
NGSOCKDIR="$(mktemp -d /tmp/airlock-nginx.XXXXXX)"
mkdir -p "$NGTMP/home" "$NGTMP/web/assets" "$NGTMP/confd/hub-locations.d" "$NGTMP/confd/servers.d" "$NGTMP/code"
NGCFG="$NGTMP/airlock.toml"
cat > "$NGCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[paths]

[apps.hub]
[apps.code-server]
[apps.dev-monitor]
[apps.devterm]
[apps.feedback]
[apps.fileview]
[apps.notepad]
[apps.orca]
[apps.paseo]
[apps.publish]
EOF
(
  export HOME="$NGTMP/home" AIRLOCK_CONFIG="$NGCFG" AIRLOCK_WEBROOT="$NGTMP/web" \
         AIRLOCK_CONFD="$NGTMP/confd" AIRLOCK_TS_FQDN="box.example.ts.net"
  bash "$ROOT/install/render-nginx.sh"
) > "$NGTMP/site.conf" 2> "$NGTMP/site.err"
if [ -s "$NGTMP/site.conf" ]; then
  f="$(out_file)"; sed -e "s|$ROOT|ROOT|g" -e "s|$NGTMP|TMP|g" "$NGTMP/site.conf" > "$f"
  golden_check_file "nginx/site.conf" "$f"
else
  bad "nginx render golden: render-nginx.sh produced no output"
  sed 's/^/    /' "$NGTMP/site.err"
fi

# tailnet_view changes only the selector inside publish's dedicated server. It
# must not rewrite the allowlist-backed map or the hub server it protects.
# Extract the two brace-delimited blocks from off/on renders and compare bytes;
# a grep for a line or two would miss a moved/relaxed guard elsewhere in either
# block. The fixture's identity header is fixed by the Tailscale provider.
NGONCFG="$NGTMP/airlock-tailnet-on.toml"
sed '/^\[apps.publish\]$/a tailnet_view = true' "$NGCFG" > "$NGONCFG"
(
  export HOME="$NGTMP/home" AIRLOCK_CONFIG="$NGONCFG" AIRLOCK_WEBROOT="$NGTMP/web" \
         AIRLOCK_CONFD="$NGTMP/confd" AIRLOCK_TS_FQDN="box.example.ts.net"
  bash "$ROOT/install/render-nginx.sh"
) > "$NGTMP/site-tailnet-on.conf" 2> "$NGTMP/site-tailnet-on.err"
extract_hub_contract() {
  python3 - "$1" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for token, opener in (
    ("map $http_tailscale_user_login $hub_ok {", "map "),
    ("listen 127.0.0.1:19902;", "server {"),
):
    pos = text.index(token)
    start = text.rfind(opener, 0, pos + 1)
    if start < 0:
        raise SystemExit(f"could not find block opener for {token!r}")
    depth = 0
    opened = False
    for end in range(start, len(text)):
        if text[end] == "{":
            depth += 1
            opened = True
        elif text[end] == "}":
            depth -= 1
            if opened and depth == 0:
                end += 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                sys.stdout.write(text[start:end])
                break
    else:
        raise SystemExit(f"unterminated block for {token!r}")
PY
}
extract_hub_contract "$NGTMP/site.conf" > "$NGTMP/hub-off.contract"
extract_hub_contract "$NGTMP/site-tailnet-on.conf" > "$NGTMP/hub-on.contract"
if cmp -s "$NGTMP/hub-off.contract" "$NGTMP/hub-on.contract"; then
  ok "publish tailnet view: hub_ok map and hub server are byte-identical off/on"
else
  bad "publish tailnet view: enabling the dedicated tier changed hub_ok or the hub server"
  diff -u "$NGTMP/hub-off.contract" "$NGTMP/hub-on.contract" | head -n 40 | sed 's/^/    /'
fi
if sed -n '/^# ==== Publish dedicated document-view gate ====$/,/^# ==== End publish dedicated document-view gate ====$/p' \
     "$NGTMP/site.conf" | grep -qF 'if ($hub_ok = 0)'; then
  ok "publish tailnet view: shipped default keeps the dedicated port on hub_ok"
else
  bad "publish tailnet view: shipped default is not hub_ok (tailnet-wide trust must default off)"
fi
if sed -n '/^# ==== Publish dedicated document-view gate ====$/,/^# ==== End publish dedicated document-view gate ====$/p' \
     "$NGTMP/site-tailnet-on.conf" | grep -qF 'if ($tailnet_ok = 0)'; then
  ok "publish tailnet view: box opt-in selects the non-empty tailnet identity tier"
else
  bad "publish tailnet view: box opt-in did not select tailnet_ok"
fi

# The golden above pins bytes; this live matrix pins meaning. The regression this
# guards was invisible to nginx -t: a filesystem 403 from publish's alias inherited
# the server-level error_page and therefore rendered the identity-denial page. A
# collaborator is the important allowed identity here — using the owner would not
# catch an accidental $owner_ok selector.
NGINX_BIN="$(command -v nginx 2>/dev/null || true)"
for candidate in /usr/sbin/nginx /sbin/nginx; do
  [ -n "$NGINX_BIN" ] || [ ! -x "$candidate" ] || NGINX_BIN="$candidate"
done
CURL_HELP=""
if command -v curl >/dev/null 2>&1; then
  CURL_HELP="$(curl --help all 2>/dev/null || true)"
fi
if [ -z "$NGINX_BIN" ]; then
  bad "nginx 403 provenance e2e: nginx is required (also checked /usr/sbin and /sbin)"
elif [[ "$CURL_HELP" != *"--unix-socket"* ]]; then
  bad "nginx 403 provenance e2e: curl with --unix-socket is required"
else
  NGE2E_CFG="$NGTMP/airlock-e2e.toml"
  sed -e '/owner = "owner@fixture.dev"/a collaborators = ["friend@fixture.dev"]' \
      -e "/^\[apps.publish\]$/a share_dir = \"$NGTMP/share\"" \
      "$NGCFG" > "$NGE2E_CFG"
  NGE2E_ON_CFG="$NGTMP/airlock-e2e-tailnet-on.toml"
  sed '/^\[apps.publish\]$/a tailnet_view = true' "$NGE2E_CFG" > "$NGE2E_ON_CFG"
  (
    export HOME="$NGTMP/home" AIRLOCK_CONFIG="$NGE2E_ON_CFG" AIRLOCK_WEBROOT="$NGTMP/web" \
           AIRLOCK_CONFD="$NGTMP/confd" AIRLOCK_TS_FQDN="box.example.ts.net"
    bash "$ROOT/install/render-nginx.sh"
  ) > "$NGTMP/e2e-site.conf" 2> "$NGTMP/e2e-site.err"
  (
    export HOME="$NGTMP/home" AIRLOCK_CONFIG="$NGE2E_CFG" AIRLOCK_WEBROOT="$NGTMP/web" \
           AIRLOCK_CONFD="$NGTMP/confd" AIRLOCK_TS_FQDN="box.example.ts.net"
    bash "$ROOT/install/render-nginx.sh"
  ) > "$NGTMP/e2e-site-tailnet-off.conf" 2> "$NGTMP/e2e-site-tailnet-off.err"

  mkdir -p "$NGTMP/share" "$NGTMP/private" "$NGTMP/cbt" "$NGTMP/pt" \
    "$NGTMP/ft" "$NGTMP/ut" "$NGTMP/st"
  chmod 755 "$NGTMP" "$NGTMP/web" "$NGTMP/share" "$NGTMP/confd" \
    "$NGTMP/confd/hub-locations.d" "$NGTMP/confd/servers.d"
  chmod 777 "$NGTMP/cbt" "$NGTMP/pt" "$NGTMP/ft" "$NGTMP/ut" "$NGTMP/st"
  cp "$ROOT/hub/wrong-owner.html" "$NGTMP/web/wrong-owner.html"
  printf '%s\n' 'HUB OK' > "$NGTMP/web/index.html"
  printf '%s\n' 'READABLE' > "$NGTMP/share/readable.html"
  printf '%s\n' 'UNREADABLE' > "$NGTMP/private/unreadable.html"
  chmod 000 "$NGTMP/private"
  ln -s "$NGTMP/private/unreadable.html" "$NGTMP/share/unreadable.html"
  ln -s "$NGTMP/does-not-exist.html" "$NGTMP/share/dangling.html"
  render_publish_nginx_main 19800 "$NGTMP/share" > "$NGTMP/confd/hub-locations.d/publish.conf"
  render_fileview_nginx 19501 owner > "$NGTMP/confd/hub-locations.d/fileview.conf"

  sed -e "s|listen 127.0.0.1:19902;|listen unix:$NGSOCKDIR/hub.sock;|" \
      -e "s|listen 127.0.0.1:19903;|listen unix:$NGSOCKDIR/redirect.sock;|" \
      -e "s|listen 127.0.0.1:19925;|listen unix:$NGSOCKDIR/publish-on.sock;|" \
      "$NGTMP/e2e-site.conf" > "$NGTMP/e2e-site-unix.conf"
  sed -n '/^# ==== Publish dedicated document-view gate ====$/,/^# ==== End publish dedicated document-view gate ====$/p' \
      "$NGTMP/e2e-site-tailnet-off.conf" \
    | sed -e "s|listen 127.0.0.1:19925;|listen unix:$NGSOCKDIR/publish-off.sock;|" \
      > "$NGTMP/e2e-publish-tailnet-off.conf"
  {
    [ "$(id -u)" -ne 0 ] || echo 'user nobody;'
    echo "pid $NGTMP/e2e-nginx.pid;"
    echo "error_log $NGTMP/e2e-nginx-error.log;"
    echo 'daemon off;'
    echo 'events {}'
    echo 'http {'
    echo '  access_log off;'
    echo "  client_body_temp_path $NGTMP/cbt;"
    echo "  proxy_temp_path $NGTMP/pt;"
    echo "  fastcgi_temp_path $NGTMP/ft;"
    echo "  uwsgi_temp_path $NGTMP/ut;"
    echo "  scgi_temp_path $NGTMP/st;"
    cat "$NGTMP/e2e-site-unix.conf"
    cat "$NGTMP/e2e-publish-tailnet-off.conf"
    echo '}'
  } > "$NGTMP/e2e-nginx.conf"

  if ! "$NGINX_BIN" -t -c "$NGTMP/e2e-nginx.conf" -p "$NGTMP" > "$NGTMP/e2e-nginx-test.log" 2>&1; then
    bad "nginx 403 provenance e2e: rendered config is invalid"
    sed 's/^/    /' "$NGTMP/e2e-nginx-test.log"
  else
    "$NGINX_BIN" -c "$NGTMP/e2e-nginx.conf" -p "$NGTMP" > "$NGTMP/e2e-nginx-start.log" 2>&1 &
    NGINX_PARITY_PID=$!
    NGINX_READY=0
    for ((attempt = 0; attempt < 50; attempt++)); do
      if [ -S "$NGSOCKDIR/hub.sock" ] \
        && [ -S "$NGSOCKDIR/publish-on.sock" ] \
        && [ -S "$NGSOCKDIR/publish-off.sock" ] \
        && kill -0 "$NGINX_PARITY_PID" 2>/dev/null; then
        NGINX_READY=1
        break
      fi
      sleep 0.1
    done
    if [ "$NGINX_READY" -eq 0 ]; then
      bad "nginx 403 provenance e2e: nginx did not start"
      sed 's/^/    /' "$NGTMP/e2e-nginx-start.log"
    else
      hub_get() {
        local login="$1" path="$2" body="$3"
        curl --silent --show-error --path-as-is --max-time 5 \
          --unix-socket "$NGSOCKDIR/hub.sock" -H "Tailscale-User-Login: $login" \
          --output "$body" --write-out '%{http_code}' "http://localhost$path" 2> "$body.err" || true
      }

      publish_get() {
        local socket="$1" login="$2" path="$3" body="$4"
        local -a headers=()
        [ "$login" = __NO_HEADER__ ] || headers=(-H "Tailscale-User-Login: $login")
        curl --silent --show-error --path-as-is --max-time 5 \
          --unix-socket "$socket" "${headers[@]}" \
          --output "$body" --write-out '%{http_code}' "http://localhost$path" 2> "$body.err" || true
      }

      publish_post() {
        local socket="$1" login="$2" path="$3" body="$4"
        curl --silent --show-error --path-as-is --max-time 5 \
          --unix-socket "$socket" -H "Tailscale-User-Login: $login" \
          -H 'Content-Type: application/json' --data '{}' \
          --output "$body" --write-out '%{http_code}' "http://localhost$path" 2> "$body.err" || true
      }

      status="$(publish_get "$NGSOCKDIR/publish-off.sock" stranger@fixture.dev \
        /publish/files/readable.html "$NGTMP/publish-off-stranger.body")"
      if [ "$status" = 403 ] && grep -qF "This isn't your Airlock" "$NGTMP/publish-off-stranger.body"; then
        ok "publish tailnet view: flag=false denies a non-allowlisted identity on the dedicated port"
      else
        bad "publish tailnet view: flag=false stranger returned $status or bypassed hub_ok"
      fi

      status="$(publish_get "$NGSOCKDIR/publish-on.sock" __NO_HEADER__ \
        /publish/files/readable.html "$NGTMP/publish-on-no-header.body")"
      if [ "$status" = 403 ] && grep -qF "This isn't your Airlock" "$NGTMP/publish-on-no-header.body"; then
        ok "publish tailnet view: flag=true still denies a request with no identity header"
      else
        bad "publish tailnet view: missing identity header returned $status or passed"
      fi

      status="$(publish_get "$NGSOCKDIR/publish-on.sock" any-member@fixture.dev \
        /publish/files/readable.html "$NGTMP/publish-on-member.body")"
      if [ "$status" = 200 ] && grep -qx READABLE "$NGTMP/publish-on-member.body"; then
        ok "publish tailnet view: flag=true admits an arbitrary non-empty tailnet identity to a document"
      else
        bad "publish tailnet view: authenticated tailnet member document returned $status"
      fi

      manager_status="$(publish_get "$NGSOCKDIR/publish-on.sock" any-member@fixture.dev \
        /publish/ "$NGTMP/publish-on-manager.body")"
      list_status="$(publish_get "$NGSOCKDIR/publish-on.sock" any-member@fixture.dev \
        /publish/api/list "$NGTMP/publish-on-list.body")"
      upload_status="$(publish_post "$NGSOCKDIR/publish-on.sock" any-member@fixture.dev \
        /publish/api/upload-file "$NGTMP/publish-on-upload.body")"
      delete_status="$(publish_post "$NGSOCKDIR/publish-on.sock" any-member@fixture.dev \
        /publish/api/unpublish-direct "$NGTMP/publish-on-delete.body")"
      if [ "$manager_status" = 404 ] && [ "$list_status" = 404 ] \
        && [ "$upload_status" = 404 ] && [ "$delete_status" = 404 ]; then
        ok "publish tailnet view: manager UI and list/upload/delete APIs are absent from the dedicated port"
      else
        bad "publish tailnet view: dedicated port exposed manager=$manager_status list=$list_status upload=$upload_status delete=$delete_status"
      fi

      status="$(hub_get friend@fixture.dev /publish/files/readable.html "$NGTMP/friend-readable.body")"
      if [ "$status" = 200 ] && grep -qx READABLE "$NGTMP/friend-readable.body"; then
        ok "nginx 403 provenance: collaborator can read a readable publish target"
      else
        bad "nginx 403 provenance: collaborator readable target returned $status"
      fi

      status="$(hub_get friend@fixture.dev /publish/files/unreadable.html "$NGTMP/friend-unreadable.body")"
      if [ "$status" = 403 ] \
        && grep -qF 'This is not an Airlock ownership error.' "$NGTMP/friend-unreadable.body" \
        && ! grep -qF "This isn't your Airlock" "$NGTMP/friend-unreadable.body"; then
        ok "nginx 403 provenance: collaborator filesystem 403 names the resource error"
      else
        bad "nginx 403 provenance: collaborator filesystem denial returned $status or the wrong explanation"
      fi

      status="$(hub_get friend@fixture.dev /publish/files/dangling.html "$NGTMP/friend-dangling.body")"
      if [ "$status" = 404 ] && ! grep -qF "This isn't your Airlock" "$NGTMP/friend-dangling.body"; then
        ok "nginx 403 provenance: collaborator dangling target remains 404"
      else
        bad "nginx 403 provenance: collaborator dangling target returned $status or an ownership error"
      fi

      status="$(hub_get friend@fixture.dev /fileview/ "$NGTMP/friend-owner-only.body")"
      if [ "$status" = 403 ] \
        && grep -qF 'This is not an Airlock ownership error.' "$NGTMP/friend-owner-only.body" \
        && ! grep -qF "This isn't your Airlock" "$NGTMP/friend-owner-only.body"; then
        ok "nginx 403 provenance: collaborator location denial names the resource error"
      else
        bad "nginx 403 provenance: collaborator location denial returned $status or the wrong explanation"
      fi

      status="$(hub_get stranger@fixture.dev /fileview/ "$NGTMP/stranger-owner-only.body")"
      if [ "$status" = 403 ] \
        && grep -qF "This isn't your Airlock" "$NGTMP/stranger-owner-only.body" \
        && ! grep -qF 'This is not an Airlock ownership error.' "$NGTMP/stranger-owner-only.body"; then
        ok "nginx 403 provenance: stranger owner-only location is stopped by the identity gate"
      else
        bad "nginx 403 provenance: stranger owner-only location returned $status or bypassed the identity explanation"
      fi

      for target in readable unreadable dangling; do
        status="$(hub_get stranger@fixture.dev "/publish/files/$target.html" "$NGTMP/stranger-$target.body")"
        if [ "$status" = 403 ] \
          && grep -qF "This isn't your Airlock" "$NGTMP/stranger-$target.body" \
          && ! grep -qF 'This is not an Airlock ownership error.' "$NGTMP/stranger-$target.body"; then
          ok "nginx 403 provenance: stranger $target target is stopped by the identity gate"
        else
          bad "nginx 403 provenance: stranger $target target returned $status or bypassed the identity explanation"
        fi
      done
    fi
  fi
  if [ -n "$NGINX_PARITY_PID" ] && kill -0 "$NGINX_PARITY_PID" 2>/dev/null; then
    kill -TERM "$NGINX_PARITY_PID" 2>/dev/null || true
    wait "$NGINX_PARITY_PID" 2>/dev/null || true
  fi
  NGINX_PARITY_PID=""
fi
chmod 700 "$NGTMP/private" 2>/dev/null || true
rm -rf "$NGTMP"
NGTMP=""
rm -rf "$NGSOCKDIR"
NGSOCKDIR=""

# ===========================================================================
# tile projection golden (F13c) — the manifest-driven projection: CURRENT
# webjson through the CURRENT (child 4/P3: APPS-registry-free) airlockTileMeta
# (same pure function install/test-hub-filter.sh exercises), for the same
# nine-app representative config. Byte-identical to the pre-P3 projection —
# every app here is already shipped, so the registry fallback this golden
# used to also exercise was already dead weight before P3 deleted it.
# ===========================================================================
if command -v node >/dev/null 2>&1; then
  TLTMP="$(mktemp -d)"
  mkdir -p "$TLTMP/home" "$TLTMP/web" "$TLTMP/confd" "$TLTMP/code" "$TLTMP/state"
  TLCFG="$TLTMP/airlock.toml"
  cat > "$TLCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[paths]

[apps.hub]
[apps.code-server]
[apps.dev-monitor]
[apps.devterm]
[apps.feedback]
[apps.fileview]
[apps.notepad]
[apps.orca]
[apps.paseo]
[apps.publish]
EOF
  webjson="$(AIRLOCK_CONFIG="$TLCFG" AIRLOCK_STATE_DIR="$TLTMP/state" AIRLOCK_WEBROOT="$TLTMP/web" \
             AIRLOCK_CONFD="$TLTMP/confd" AIRLOCK_TS_FQDN="box.example.ts.net" HOME="$TLTMP/home" \
             python3 "$ROOT/bin/airlock-config" webjson 2>"$TLTMP/webjson.err")"
  if [ -n "$webjson" ]; then
    tj="$(out_file)"
    node - "$ROOT/hub/index.html" "$webjson" > "$tj" <<'JS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const mFn = html.match(/function airlockTileMeta\([\s\S]*?\n\}/);
if (!mFn) { console.error("airlockTileMeta not found"); process.exit(1); }
const airlockTileMeta = eval("(" + mFn[0] + ")");
const cfg = JSON.parse(process.argv[3]);
const apps = cfg.apps || {};
const names = Object.keys(apps).filter(n => n !== "hub" && n !== "feedback").sort();
const out = {};
for (const name of names) {
  out[name] = airlockTileMeta(apps[name]);
}
console.log(JSON.stringify(out, null, 2));
JS
    if [ -s "$tj" ]; then
      golden_check_file "tile/projection.json" "$tj"
    else
      bad "tile projection golden: node produced no output"
    fi
  else
    bad "tile projection golden: airlock-config webjson produced no output"
    sed 's/^/    /' "$TLTMP/webjson.err"
  fi
  rm -rf "$TLTMP"
else
  bad "tile projection golden: node not found"
fi

# ===========================================================================
# installer-path fixtures (round 2 Major) — one artifact per app produced by
# running the REAL install.sh end to end (AIRLOCK_DRY_RUN=1 +
# AIRLOCK_RENDER_DIR=scratch), byte-compared against a dedicated
# "installer-path" golden. This is what the direct render.sh-call sections
# above cannot catch: a render_* call whose ARGUMENTS are wired in the wrong
# order/name at the actual call site (the direct sections call the same
# functions the same way the call site does, by construction, so a swapped
# argument at the call site is invisible to them). The nginx fragment is used
# for every app: it is the one artifact every installer here writes
# UNCONDITIONALLY, dry-run or not. Unit (and, for orca, nft) writes used to be
# dry-run-gated with no AIRLOCK_RENDER_DIR carve-out at all, so this section
# used to check the fragment only — M4 review proved that blind: swapping
# feedback's render_feedback_unit's first two arguments stayed green because
# nothing here ever exercised the unit write call site. Every app's installer
# now takes the AIRLOCK_DRY_RUN=1 branch it always took for its real system
# mutations (systemctl/sudo/etc.) while ALSO taking the write branch for its
# render_* call sites when AIRLOCK_RENDER_DIR is set — so every artifact_rel
# below (units, nft files, orca's reap script) is captured from the SAME
# single real run of install.sh and compared against its own golden.
# ===========================================================================
run_installer_path() {
  local app="$1" extra_toml="$2" app_toml="$3" golden_set="$4"; shift 4
  local WDIR CFG out rc=0
  WDIR="$(mktemp -d)"
  mkdir -p "$WDIR/home" "$WDIR/render" "$WDIR/code" "$WDIR/shim"
  CFG="$WDIR/airlock.toml"
  {
    printf '[site]\nname = "RenderParity"\n\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n\n'
    printf '%s\n' "$extra_toml"
    printf '[apps.%s]\n' "$app"
    [ -z "$app_toml" ] || printf '%s\n' "$app_toml"
  } > "$CFG"
  # Shim any prerequisite command missing on this box (mirrors
  # install/test-equivalence.sh) — a dry run never executes the shimmed
  # command, it only needs `command -v` to succeed at require_cmd. Sourced
  # from ALL_PREREQ_CMDS (F11 assembly: TSV + every manifest), not the raw
  # TSV alone, or a migrated app's manifest-only command goes unshimmed.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf '#!/bin/sh\nexit 0\n' > "$WDIR/shim/$cmd"; chmod +x "$WDIR/shim/$cmd"
    fi
  done <<<"$ALL_PREREQ_CMDS"
  out="$(
    # Pin the RAM the paseo installer sizes its cgroup backstop from (32GiB), or
    # the golden would bake in whatever box ran the test and fail everywhere else.
    export HOME="$WDIR/home" AIRLOCK_CONFIG="$CFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
           AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$WDIR/render" \
           AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368 \
           PATH="$WDIR/shim:$PATH"
    # The D5 ABI, exported the way the orchestrator exports it. It is required,
    # not optional: an app may not derive the platform root from its own location
    # (install/check-app-abi.sh), because after the apps/ cutover that derivation
    # points at the app repository instead of the platform.
    export AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/$app" AIRLOCK_APP_ID="$app"
    bash "$ROOT/apps/$app/install.sh" 2>&1
  )" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "installer-path: $app — install.sh exited $rc"
    printf '%s\n' "$out" | tail -25 | sed 's/^/    /'
    rm -rf "$WDIR"
    return
  fi
  # Remaining args are (artifact_rel, golden_name) pairs — one call per app,
  # every rendered artifact it produced compared in one real run.
  while [ "$#" -ge 2 ]; do
    local artifact_rel="$1" golden_name="$2"; shift 2
    if [ ! -f "$WDIR/render/$artifact_rel" ]; then
      bad "installer-path: $app — artifact not found under AIRLOCK_RENDER_DIR ($artifact_rel)"
      printf '%s\n' "$out" | tail -25 | sed 's/^/    /'
      continue
    fi
    # Normalise this run's mktemp $WDIR out first (some apps embed a
    # CONFD-derived path — e.g. code-server's slot-gate "root" line — and
    # CONFD is redirected under AIRLOCK_RENDER_DIR=$WDIR/render here, so the
    # raw artifact is not reproducible run to run without this).
    # $TMP (this suite's own top-level scratch dir) also leaks into fileview's
    # unit — so it must
    # be normalised too, not just $WDIR, or the golden is non-reproducible run
    # to run.
    local wdirnorm; wdirnorm="$(out_file).wdirnorm"
    # $NODE_REAL_BIN_DIR is scoped to paseo ONLY (its unit PATH line is the
    # sole place a real node install path is ever embedded) — applying it
    # globally is wrong and was caught by adversarial review: on a box where
    # node lives at a common prefix (/usr/bin, /usr/local/bin — apt install,
    # the official tarball, node Docker images), the same sed also rewrites
    # unrelated bytes in every OTHER app's golden (e.g. feedback/dev-monitor's
    # `ExecStart=/usr/bin/python3 ...`, orca's `#!/usr/bin/env bash` reap
    # script), corrupting goldens that have nothing to do with node.
    #
    # And within paseo's own unit the substitution must be the FIRST
    # colon-delimited PATH slot only, NOT global: install.sh prepends the
    # resolved node dir before the fixed base `/usr/local/bin:/usr/bin:/bin`
    # (apps/paseo/install.sh:110-115), so when node itself lives at /usr/bin
    # (a system-node CI runner), a global replace also rewrites the trailing
    # base /usr/bin and the golden no longer matches (green on an nvm box,
    # red in CI). The node slot is always the first `:<dir>:` occurrence, so
    # a colon-anchored first-match hits it and leaves the base entries literal.
    #
    # Scoped by CONTENT rather than by app name since 2026-08-07, when fileview's
    # markserv unit also derived its PATH. markserv is gone, but the content test is
    # still the right boundary. An artifact that has no `Environment=PATH=` line
    # cannot be the one embedding a node dir, and that is exactly the set the comment
    # above says must not be touched.
    local _node_sed=()
    if grep -q '^Environment=PATH=' "$WDIR/render/$artifact_rel" 2>/dev/null; then
      [ -n "$NODE_FOUND_BIN_DIR" ] && _node_sed+=(-e "s|:$NODE_FOUND_BIN_DIR:|:NODE_BIN:|")
      [ -n "$NODE_REAL_BIN_DIR" ]  && _node_sed+=(-e "s|:$NODE_REAL_BIN_DIR:|:NODE_BIN:|")
    fi
    sed -e "s|$WDIR|WDIR|g" -e "s|$TMP|TMP|g" "${_node_sed[@]}" \
      "$WDIR/render/$artifact_rel" > "$wdirnorm"
    golden_check_file "$app/$golden_set/$golden_name" "$wdirnorm"
  done
  rm -rf "$WDIR"
}

run_installer_path code-server "" "" installer-path \
  "confd/servers.d/code-server.conf" "nginx.conf" \
  "units/airlock-code-server@.service" "unit-slot.service" \
  "units/airlock-code-server-manager.service" "unit-manager.service"
run_installer_path dev-monitor "" "" installer-path \
  "confd/hub-locations.d/dev-monitor.conf" "nginx.conf" \
  "units/airlock-dev-monitor.service" "unit.service"

# dev-monitor webhook precedence — the real installer path, all eight combinations.
# Values are deliberately distinguishable fakes and are never copied to a golden.
run_devmon_webhook_case() {
  local label="$1" urgent="$2" routine="$3" alias="$4" expected_urgent="$5" expected_routine="$6"
  local WDIR CFG out rc=0 envf unit warning_count expected_warning=0
  WDIR="$(mktemp -d)"; CFG="$WDIR/airlock.toml"
  mkdir -p "$WDIR/home/.config/airlock" "$WDIR/render" "$WDIR/shim"
  printf 'DEV_MONITOR_PROXY_SECRET=fixture-proxy-only\n' > "$WDIR/home/.config/airlock/dev-monitor.env"
  {
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.dev-monitor]\nmessages = true\n'
    [ "$urgent" = set ] && printf 'slack_webhook_urgent_env = "DEVMON_FIXTURE_URGENT"\n'
    [ "$urgent" = missing ] && printf 'slack_webhook_urgent_env = "DEVMON_FIXTURE_MISSING"\n'
    [ "$routine" = set ] && printf 'slack_webhook_routine_env = "DEVMON_FIXTURE_ROUTINE"\n'
    [ "$alias" = set ] && printf 'slack_webhook_env = "DEVMON_FIXTURE_ALIAS"\n'
  } > "$CFG"
  out="$(
    export HOME="$WDIR/home" AIRLOCK_CONFIG="$CFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
      AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$WDIR/render" \
      DEVMON_FIXTURE_URGENT="urgent-fixture" \
      DEVMON_FIXTURE_ROUTINE="routine-fixture" \
      DEVMON_FIXTURE_ALIAS="alias-fixture"
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
    bash "$ROOT/apps/dev-monitor/install.sh" 2>&1
  )" || rc=$?
  envf="$WDIR/render/files/dev-monitor.env"
  unit="$WDIR/render/units/airlock-dev-monitor.service"
  if [ "$rc" -ne 0 ]; then
    bad "dev-monitor precedence $label: installer exited $rc"
  elif [ ! -f "$envf" ]; then
    bad "dev-monitor precedence $label: captured env missing"
  elif ! grep -qxF "AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT=${expected_urgent}" "$envf" \
       || ! grep -qxF "AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE=${expected_routine}" "$envf"; then
    bad "dev-monitor precedence $label: resolved lanes differ"
  elif grep -q '^AIRLOCK_DEVMON_SLACK_WEBHOOK=' "$envf"; then
    bad "dev-monitor precedence $label: legacy generated variable survived"
  else
    ok "dev-monitor precedence $label: canonical lane values"
  fi
  [ "$alias" = set ] && expected_warning=1
  warning_count="$(printf '%s\n' "$out" | grep -c 'apps.dev-monitor.slack_webhook_env is deprecated' || true)"
  if [ "$warning_count" = "$expected_warning" ] \
      && { [ "$expected_warning" = 0 ] || printf '%s\n' "$out" | grep -q 'slack_webhook_urgent_env.*2026-09-07'; }; then
    ok "dev-monitor precedence $label: alias warning count/content"
  else
    bad "dev-monitor precedence $label: alias warning count/content"
  fi
  if [ -f "$envf" ] && [ "$(stat -c '%a' "$envf")" = 600 ]; then
    ok "dev-monitor precedence $label: env mode 0600"
  else
    bad "dev-monitor precedence $label: env mode is not 0600"
  fi
  if [ -f "$unit" ] \
      && grep -qxF "EnvironmentFile=-$WDIR/home/.config/airlock/dev-monitor.env" "$unit" \
      && ! grep -qF "$WDIR/render/files/dev-monitor.env" "$unit"; then
    ok "dev-monitor precedence $label: capture path is not service path"
  else
    bad "dev-monitor precedence $label: EnvironmentFile points at capture path"
  fi
  rm -rf "$WDIR"
}

run_devmon_webhook_case U-R-x set set unset urgent-fixture routine-fixture
run_devmon_webhook_case U-x-x set unset unset urgent-fixture ""
run_devmon_webhook_case x-R-x unset set unset "" routine-fixture
run_devmon_webhook_case x-x-x unset unset unset "" ""
run_devmon_webhook_case U-R-A set set set urgent-fixture routine-fixture
run_devmon_webhook_case U-x-A set unset set urgent-fixture ""
run_devmon_webhook_case x-R-A unset set set alias-fixture routine-fixture
run_devmon_webhook_case x-x-A unset unset set alias-fixture ""
run_devmon_webhook_case Umissing-x-A missing unset set "" ""

# Turning messages off removes its spool/action values but retains the two-value updates
# owner gate. Otherwise the daily snapshot would exist with no authenticated read path.
DMOFF="$(mktemp -d)"; mkdir -p "$DMOFF/home/.config/airlock" "$DMOFF/render"
printf 'stale\n' > "$DMOFF/render/files-placeholder" 2>/dev/null || true
cat > "$DMOFF/on.toml" <<'EOF'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.dev-monitor]
messages = true
EOF
printf 'DEV_MONITOR_PROXY_SECRET=fixture-proxy-only\n' > "$DMOFF/home/.config/airlock/dev-monitor.env"
HOME="$DMOFF/home" AIRLOCK_CONFIG="$DMOFF/on.toml" AIRLOCK_TS_FQDN=box.example.ts.net \
  AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$DMOFF/render" \
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" >/dev/null 2>&1
sed 's/messages = true/messages = false/' "$DMOFF/on.toml" > "$DMOFF/off.toml"
HOME="$DMOFF/home" AIRLOCK_CONFIG="$DMOFF/off.toml" AIRLOCK_TS_FQDN=box.example.ts.net \
  AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$DMOFF/render" \
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" >/dev/null 2>&1
if [ "$(cat "$DMOFF/render/files/dev-monitor.env")" = "$(printf '%s\n' \
  '# generated owner gate for dev-monitor updates' \
  'DEV_MONITOR_OWNER=owner@fixture.dev' \
  'DEV_MONITOR_PROXY_SECRET=fixture-proxy-only')" ]; then
  ok "dev-monitor messages off retains only the updates owner gate"
else
  bad "dev-monitor messages off kept message configuration or lost updates gate"
fi
rm -rf "$DMOFF"

# Env-file injection guards: reject both configured variable names and the values
# resolved through them, while never echoing the rejected value.
for dm_key in slack_webhook_urgent_env slack_webhook_routine_env slack_webhook_env; do
  DMBAD="$(mktemp -d)"; mkdir -p "$DMBAD/home/.config/airlock" "$DMBAD/render"
  {
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.dev-monitor]\nmessages = true\n'
    printf '%s = "BAD\\nNAME"\n' "$dm_key"
  } > "$DMBAD/airlock.toml"
  dm_out="$(HOME="$DMBAD/home" AIRLOCK_CONFIG="$DMBAD/airlock.toml" \
    AIRLOCK_TS_FQDN=box.example.ts.net AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$DMBAD/render" \
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
    bash "$ROOT/apps/dev-monitor/install.sh" 2>&1)"; dm_rc=$?
  if [ "$dm_rc" -ne 0 ] && printf '%s\n' "$dm_out" | grep -q 'config values must not contain newlines' \
      && ! printf '%s\n' "$dm_out" | grep -q 'BAD'; then
    ok "dev-monitor rejects newline in $dm_key without value disclosure"
  else
    bad "dev-monitor newline guard failed for $dm_key"
  fi
  rm -rf "$DMBAD"
done

for dm_key in slack_webhook_urgent_env slack_webhook_routine_env slack_webhook_env; do
  DMBAD="$(mktemp -d)"; mkdir -p "$DMBAD/home/.config/airlock" "$DMBAD/render"
  printf 'DEV_MONITOR_PROXY_SECRET=fixture-proxy-only\n' > "$DMBAD/home/.config/airlock/dev-monitor.env"
  {
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.dev-monitor]\nmessages = true\n'
    printf '%s = "DEVMON_BAD_VALUE"\n' "$dm_key"
  } > "$DMBAD/airlock.toml"
  dm_out="$(HOME="$DMBAD/home" AIRLOCK_CONFIG="$DMBAD/airlock.toml" \
    AIRLOCK_TS_FQDN=box.example.ts.net AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$DMBAD/render" \
    DEVMON_BAD_VALUE=$'secret-canary\nINJECTED=1' \
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
    bash "$ROOT/apps/dev-monitor/install.sh" 2>&1)"; dm_rc=$?
  if [ "$dm_rc" -ne 0 ] && printf '%s\n' "$dm_out" | grep -q 'resolved Slack webhook values must not contain newlines' \
      && ! printf '%s\n' "$dm_out" | grep -Eq 'secret-canary|INJECTED'; then
    ok "dev-monitor rejects newline in resolved $dm_key value without disclosure"
  else
    bad "dev-monitor resolved newline guard failed for $dm_key"
  fi
  rm -rf "$DMBAD"
done
run_installer_path devterm "" "accounts = true" installer-path \
  "confd/servers.d/devterm.conf" "nginx.conf" \
  "units/airlock-devterm.service" "unit-ttyd.service" \
  "units/airlock-devterm-gate.service" "unit-gate.service"
run_installer_path devterm "" "xai = true" installer-path-xai-only \
  "confd/servers.d/devterm.conf" "nginx.conf" \
  "units/airlock-devterm.service" "unit-ttyd.service" \
  "units/airlock-devterm-gate.service" "unit-gate.service"

# The installer-path oracle above must stay dry-run because it captures rendered
# system artifacts. That branch intentionally stops before mktemp/chmod/mv, however,
# so it cannot prove the P2a upgrade invariant: an already-installed credential writer
# is replaced atomically even after its feature is disabled, and a failed replacement
# leaves the old path intact. These full installer runs are non-dry but hermetic: HOME,
# nginx config and every service command are redirected below $TMP; ttyd is preseeded
# so there is no download, and no host service or $HOME path is touched.
run_devterm_shim_install() {
  local case_dir="$1" app_toml="$2" fail_mv="${3:-false}" out rc=0 cmd
  mkdir -p "$case_dir/home/.local/bin" "$case_dir/confd" "$case_dir/shim"
  printf '#!/bin/sh\nexit 0\n' > "$case_dir/home/.local/bin/ttyd"
  chmod 755 "$case_dir/home/.local/bin/ttyd"
  for cmd in systemctl tailscale sudo tmux; do
    printf '#!/bin/sh\nexit 0\n' > "$case_dir/shim/$cmd"
    chmod 755 "$case_dir/shim/$cmd"
  done
  if [ "$fail_mv" = true ]; then
    printf '#!/bin/sh\nexit 73\n' > "$case_dir/shim/mv"
    chmod 755 "$case_dir/shim/mv"
  fi
  {
    printf '[site]\nname = "RenderParity"\n\n'
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n\n'
    printf '[apps.devterm]\n%s\n' "$app_toml"
  } > "$case_dir/airlock.toml"
  out="$(
    HOME="$case_dir/home" AIRLOCK_CONFIG="$case_dir/airlock.toml" \
      AIRLOCK_TS_FQDN=box.example.ts.net AIRLOCK_CONFD="$case_dir/confd" \
      TTYD_BIN="$case_dir/home/.local/bin/ttyd" \
      AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/devterm" AIRLOCK_APP_ID=devterm \
      PATH="$case_dir/shim:$PATH" bash "$ROOT/apps/devterm/install.sh" 2>&1
  )" || rc=$?
  printf '%s\n' "$rc" > "$case_dir/rc"
  printf '%s\n' "$out" > "$case_dir/out"
}

SHIM_EXPECT_SWITCH="$(out_file)"
SHIM_EXPECT_STATUS="$(out_file)"
render_devterm_exec_shim "$ROOT/bin/airlock-accounts" > "$SHIM_EXPECT_SWITCH"
render_devterm_exec_shim "$ROOT/bin/airlock-accounts-status" > "$SHIM_EXPECT_STATUS"

SHIM_UPGRADE="$TMP/devterm-shim-upgrade-off"
mkdir -p "$SHIM_UPGRADE/home/.local/bin"
printf '#!/bin/sh\nprintf stale-switch\\n\n' > "$SHIM_UPGRADE/home/.local/bin/claude-switch"
printf '#!/bin/sh\nprintf stale-status\\n\n' > "$SHIM_UPGRADE/home/.local/bin/claude-status"
run_devterm_shim_install "$SHIM_UPGRADE" $'accounts = false\nxai = false'
if [ "$(cat "$SHIM_UPGRADE/rc")" = 0 ] \
   && cmp -s "$SHIM_EXPECT_SWITCH" "$SHIM_UPGRADE/home/.local/bin/claude-switch" \
   && cmp -s "$SHIM_EXPECT_STATUS" "$SHIM_UPGRADE/home/.local/bin/claude-status" \
   && [ "$(stat -c %a "$SHIM_UPGRADE/home/.local/bin/claude-switch")" = 755 ] \
   && [ "$(stat -c %a "$SHIM_UPGRADE/home/.local/bin/claude-status")" = 755 ]; then
  ok "devterm upgrade replaces disabled-feature credential writers with executable platform shims"
else
  bad "devterm upgrade left a stale disabled-feature credential writer or wrong shim mode"
  tail -25 "$SHIM_UPGRADE/out" | sed 's/^/    /'
fi

SHIM_XAI="$TMP/devterm-shim-xai-only"
run_devterm_shim_install "$SHIM_XAI" $'accounts = false\nxai = true'
if [ "$(cat "$SHIM_XAI/rc")" = 0 ] \
   && [ ! -e "$SHIM_XAI/home/.local/bin/claude-switch" ] \
   && cmp -s "$SHIM_EXPECT_STATUS" "$SHIM_XAI/home/.local/bin/claude-status"; then
  ok "devterm xAI-only install creates only the platform status shim"
else
  bad "devterm xAI-only install produced the wrong compatibility shims"
  tail -25 "$SHIM_XAI/out" | sed 's/^/    /'
fi

SHIM_FAILURE="$TMP/devterm-shim-failed-replace"
mkdir -p "$SHIM_FAILURE/home/.local/bin"
printf '#!/bin/sh\nprintf preserve-me\\n\n' > "$SHIM_FAILURE/home/.local/bin/claude-switch"
cp "$SHIM_FAILURE/home/.local/bin/claude-switch" "$SHIM_FAILURE/sentinel"
run_devterm_shim_install "$SHIM_FAILURE" $'accounts = false\nxai = false' true
if [ "$(cat "$SHIM_FAILURE/rc")" -ne 0 ] \
   && cmp -s "$SHIM_FAILURE/sentinel" "$SHIM_FAILURE/home/.local/bin/claude-switch" \
   && ! find "$SHIM_FAILURE/home/.local/bin" -maxdepth 1 -name 'claude-switch.tmp.*' -print -quit | grep -q .; then
  ok "devterm failed atomic shim replace preserves the installed credential path"
else
  bad "devterm failed atomic shim replace changed the installed path or leaked a temp file"
  tail -25 "$SHIM_FAILURE/out" | sed 's/^/    /'
fi

run_installer_path feedback "" "" installer-path \
  "confd/hub-locations.d/feedback.conf" "nginx.conf" \
  "units/airlock-feedback.service" "unit.service"
run_installer_path fileview "" "" installer-path \
  "confd/hub-locations.d/fileview.conf" "nginx.conf" \
  "units/airlock-fileview.service" "unit.service"
run_installer_path orca "" "" installer-path \
  "confd/servers.d/orca.conf" "nginx.conf" \
  "units/airlock-orca-xvfb.service" "unit-xvfb.service" \
  "units/airlock-orca.service" "unit-serve.service" \
  "bin/airlock-orca-reap" "reap.sh" \
  "etc-airlock/orca-loopback.nft" "nft.conf" \
  "etc-systemd-system/airlock-orca-firewall.service" "unit-firewall.service"
run_installer_path paseo "" "" installer-path \
  "confd/servers.d/paseo.conf" "nginx.conf" \
  "units/airlock-paseo.service" "unit.service"

# paseo memory cases — exercise the real installer's proportional sizing from tiny to
# huge. The expectation is COMPUTED here from the same ratio the installer uses, so the
# assertion is "11/16 and 10/16 of the rounded cap", not a list of remembered numbers.
# Neither half alone would be enough: an ordering check (`high < max`) passes with any
# pair of numbers, and a fixed expected pair passes with any ratio. With the
# non-whole-GiB caps below, the ratio, the rounding and the rendering are each pinned
# separately.
size_to_mib() {
  awk -v s="$1" 'BEGIN{
    if (s !~ /^[0-9]+(\.[0-9]+)?[GM]$/) { print "NaN"; exit }
    u = substr(s, length(s), 1); n = substr(s, 1, length(s) - 1)
    printf "%d", n * (u == "G" ? 1024 : 1)
  }'
}
# paseo_memory_case EXPECT_CAP_GIB MODE [TASKS_OVERRIDE] [RAW_CAP_BYTES]
# EXPECT_CAP_GIB is what the installer's rounding must arrive at, NOT the raw cap.
# With RAW_CAP_BYTES the two differ on purpose: that is how the rounding line itself
# gets asserted. Without it every cap driven here is an exact GiB multiple, and floor,
# ceil and round-to-nearest are indistinguishable — the tier TABLE would be covered
# while the tier SELECTION was not (measured: deleting the rounding left this suite
# fully green).
# Every call bumps this and the tail of the block asserts the total. Without it,
# DELETING cases is invisible: shrinking the cap loop from thirteen entries to one left
# the suite fully green, and the same shape once removed the `finite` branch entirely.
# A coverage suite that cannot notice its own coverage disappearing is not one.
paseo_mem_cases_run=0
paseo_memory_case() {
  paseo_mem_cases_run=$(( paseo_mem_cases_run + 1 ))
  local cap_gib="$1" mode="$2" tasks_override="${3:-}" raw_bytes="${4:-}"
  local cap_bytes WDIR CFG out rc=0 unit max high
  local expect_max expect_high
  if [ -n "$raw_bytes" ]; then cap_bytes="$raw_bytes"
  else cap_bytes=$(( cap_gib * 1024 * 1024 * 1024 ))
  fi
  local tag="${cap_gib}GiB"
  [ -n "$raw_bytes" ] && tag="${raw_bytes}B (rounds to ${cap_gib}GiB)"
  # Deliberately NOT a copy of the installer's expression: spelled as MiB-per-GiB so a
  # mutation of either numerator in install.sh shows up here as a mismatch instead of
  # being mirrored into the expectation.
  expect_max="$(( cap_gib * 704 ))M"   # 704 MiB = 11/16 GiB
  expect_high="$(( cap_gib * 640 ))M"  # 640 MiB = 10/16 GiB
  WDIR="$(mktemp -d)"
  mkdir -p "$WDIR/home" "$WDIR/render" "$WDIR/shim"
  CFG="$WDIR/airlock.toml"
  {
    printf '[site]\nname = "RenderParity"\n\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n\n'
    printf '[apps.paseo]\n'
  } > "$CFG"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf '#!/bin/sh\nexit 0\n' > "$WDIR/shim/$cmd"
      chmod +x "$WDIR/shim/$cmd"
    fi
  done <<<"$ALL_PREREQ_CMDS"

  out="$(
    export HOME="$WDIR/home" AIRLOCK_CONFIG="$CFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
           AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$WDIR/render" \
           AIRLOCK_PASEO_MEM_CAP_BYTES="$cap_bytes" PATH="$WDIR/shim:$PATH"
    if [ "$mode" = unbacked ]; then
      export AIRLOCK_PASEO_ALLOW_UNBACKED_MEM=1
    else
      unset AIRLOCK_PASEO_ALLOW_UNBACKED_MEM
    fi
    if [ -n "$tasks_override" ]; then
      export AIRLOCK_PASEO_TASKS_MAX="$tasks_override"
    else
      unset AIRLOCK_PASEO_TASKS_MAX
    fi
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/paseo" AIRLOCK_APP_ID=paseo \
    bash "$ROOT/apps/paseo/install.sh" 2>&1
  )" || rc=$?

  case "$mode" in
    share-only)
      # Sub-GiB boxes: the installer clamps the share to the raw cap, so the exact number
      # is not `cap_gib * 704`. Asserting the PROPERTY instead of mirroring the clamp
      # keeps this a test rather than a second copy of the code.
      unit="$WDIR/render/units/airlock-paseo.service"
      if [ "$rc" -ne 0 ] || [ ! -f "$unit" ]; then
        bad "paseo memory ${tag}: install failed (rc=$rc) or unit missing"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
      else
        max="$(sed -n 's/^MemoryMax=\(.*\)$/\1/p' "$unit")"
        high="$(sed -n 's/^MemoryHigh=\(.*\)$/\1/p' "$unit")"
        local max_mib high_mib
        max_mib="$(size_to_mib "$max")"; high_mib="$(size_to_mib "$high")"
        if [ "$max_mib" = NaN ] || [ "$high_mib" = NaN ]; then
          bad "paseo memory ${tag}: unit did not render a finite size systemd can parse"
          grep -E '^Memory(Max|High)=' "$unit" | sed 's/^/    /'
        elif [ "$max_mib" -lt 1 ]; then
          bad "paseo memory ${tag}: rendered a zero ceiling (MemoryMax=${max}) — the unit would not start"
        elif [ "$high_mib" -ge "$max_mib" ]; then
          bad "paseo memory ${tag}: invariant failed (MemoryHigh=${high} not below MemoryMax=${max})"
        elif [ "$cap_bytes" -ge 1048576 ] && [ "$max_mib" -gt $(( cap_bytes / 1048576 )) ]; then
          bad "paseo memory ${tag}: the ceiling is bigger than the box (MemoryMax=${max} > ${cap_bytes} bytes)"
        else
          ok "paseo memory ${tag}: sub-GiB box gets a non-zero share inside its own box (${max}/${high})"
        fi
      fi
      ;;
    finite)
      unit="$WDIR/render/units/airlock-paseo.service"
      if [ "$rc" -ne 0 ] || [ ! -f "$unit" ]; then
        bad "paseo memory ${tag}: install failed (rc=$rc) or unit missing"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
      else
        max="$(sed -n 's/^MemoryMax=\(.*\)$/\1/p' "$unit")"
        high="$(sed -n 's/^MemoryHigh=\(.*\)$/\1/p' "$unit")"
        local max_mib high_mib
        max_mib="$(size_to_mib "$max")"; high_mib="$(size_to_mib "$high")"
        if [ "$max" != "$expect_max" ] || [ "$high" != "$expect_high" ]; then
          bad "paseo memory ${tag}: wrong share (got MemoryMax=${max} MemoryHigh=${high}, want ${expect_max}/${expect_high})"
          grep -E '^(Memory(Max|High)|TasksMax)=' "$unit" | sed 's/^/    /'
        elif [ "$max_mib" = NaN ] || [ "$high_mib" = NaN ]; then
          bad "paseo memory ${tag}: unit did not render a finite size systemd can parse"
          grep -E '^(Memory(Max|High)|TasksMax)=' "$unit" | sed 's/^/    /'
        elif [ "$high_mib" -ge "$max_mib" ]; then
          bad "paseo memory ${tag}: invariant failed (MemoryHigh=${high} not below MemoryMax=${max})"
        elif [ "$max_mib" -gt $(( cap_bytes / 1048576 )) ]; then
          # Against the RAW cap, not the rounded one. Compared against the rounded cap
          # this was dominated by the equality check above and could only fire when the
          # EXPECTATION was wrong — a review proved that vacuous, twice. Against the raw
          # cap it asserts the installer's "never above the box" clamp is doing its job.
          bad "paseo memory ${tag}: the ceiling is bigger than the box (MemoryMax=${max} > ${cap_bytes} bytes)"
        elif ! grep -qx 'TasksMax=infinity' "$unit"; then
          bad "paseo memory ${tag}: TasksMax is not the box maximum"
          grep -E '^TasksMax=' "$unit" | sed 's/^/    /'
        elif ! grep -qF "paseo memory share: cap=${cap_bytes} bytes" <<<"$out" \
             || ! grep -qF "MemoryMax=${expect_max} (11/16) MemoryHigh=${expect_high} (10/16)" <<<"$out"; then
          # The install log must name the same numbers the unit got, and name the ratio
          # it used. That log line is the only operator-visible explanation of why this
          # box got this share; a unit that is right while the log says something else
          # sends the next person looking in the wrong place.
          bad "paseo memory ${tag}: the install log does not report the share it wrote"
          printf '%s\n' "$out" | grep -i 'memory' | tail -4 | sed 's/^/    /'
        else
          ok "paseo memory ${tag}: share ${expect_max}/${expect_high} = 11/16 and 10/16 of ${cap_gib}GiB, MemoryHigh < MemoryMax <= the raw cap, logged under 'paseo memory share:', TasksMax at the box maximum"
        fi
      fi
      ;;
    unbacked)
      unit="$WDIR/render/units/airlock-paseo.service"
      if [ "$rc" -ne 0 ] || [ ! -f "$unit" ]; then
        bad "paseo memory ${tag} + override: install failed (rc=$rc) or unit missing"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
      elif ! grep -qx 'MemoryMax=infinity' "$unit" \
           || ! grep -qx 'MemoryHigh=infinity' "$unit" \
           || ! grep -qx 'TasksMax=infinity' "$unit"; then
        bad "paseo memory ${tag} + override: unit did not disable only the memory backstop"
        grep -E '^(Memory(Max|High)|TasksMax)=' "$unit" | sed 's/^/    /'
      elif ! grep -qF 'WARNING: paseo memory backstop disabled by explicit override' <<<"$out"; then
        bad "paseo memory ${tag} + override: missing loud no-backstop warning"
        printf '%s\n' "$out" | tail -10 | sed 's/^/    /'
      else
        ok "paseo memory ${tag} + override: infinity memory limits, TasksMax at the box maximum, warning emitted"
      fi
      ;;
    tasks-override)
      # The default is the box maximum, so the only way to prove the knob exists
      # is to ask for a finite one and see it in the unit. Without this case,
      # deleting AIRLOCK_PASEO_TASKS_MAX from the installer changes nothing that
      # anything checks.
      unit="$WDIR/render/units/airlock-paseo.service"
      if [ "$rc" -ne 0 ] || [ ! -f "$unit" ]; then
        bad "paseo TasksMax override: install failed (rc=$rc) or unit missing"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
      elif ! grep -qx "TasksMax=${tasks_override}" "$unit"; then
        bad "paseo TasksMax override: AIRLOCK_PASEO_TASKS_MAX=${tasks_override} did not reach the unit"
        grep -E '^TasksMax=' "$unit" | sed 's/^/    /'
      elif ! grep -qE '^MemoryMax=[0-9]+(\.[0-9]+)?[GM]$' "$unit"; then
        bad "paseo TasksMax override: the memory backstop moved with it"
        grep -E '^Memory(Max|High)=' "$unit" | sed 's/^/    /'
      else
        ok "paseo TasksMax override: a finite pids backstop is still available on request"
      fi
      ;;
    *)
      # Not decoration: an unknown mode used to fall through `case` silently, so a case
      # that asserted nothing looked exactly like a case that passed. That happened —
      # a bad edit removed the `finite` branch and thirteen caps went unchecked, with
      # only the total count to notice it by.
      bad "paseo memory ${tag}: unknown mode '${mode}' — the case asserted nothing"
      ;;
  esac
  rm -rf "$WDIR"
}

paseo_memory_case 8 tasks-override 4096
# Every cap gets the same treatment now — there is no tier to fall either side of, so
# the range is what matters: three orders of magnitude, and the ratio must hold at all
# of them. 1 GiB is the floor clamp; 72 is this repo's own dev box, the size that broke
# the fixed-tier design.
for cap_gib in 1 2 3 4 6 7 8 12 15 16 32 64 72; do
  paseo_memory_case "$cap_gib" finite
done
# The opt-out still renders infinity, on a small box and a large one alike.
paseo_memory_case 2  unbacked
paseo_memory_case 64 unbacked
# Rounding cases — caps that are NOT whole GiB, which is what every real box reports.
# Without these, floor / ceil / round-to-nearest are indistinguishable: every whole-GiB
# cap above rounds to itself. A real machine reports under its own name, and rounding
# first is what makes the published numbers exact (7.63 GiB -> 8 -> 5632M = 5.5 GiB,
# the figure this was validated at; flooring would hand it 4928M).
paseo_memory_case 8  finite "" 8192650117    #  7.63 GiB, a real "8GB" box  -> 8
paseo_memory_case 7  finite "" 8042326261    #  7.49 GiB, just under        -> 7
paseo_memory_case 16 finite "" 16696685363   # 15.55 GiB, a real "16GB" box -> 16
paseo_memory_case 15 finite "" 16535624090   # 15.40 GiB, just under        -> 15
# The 512 MiB rounding edge, asserted from both sides at the exact byte. Without these
# two, shifting the constant by one or swapping -ge for -gt survives: no other case has
# a remainder anywhere near 536870912.
paseo_memory_case 16 finite "" 16642998272   # 15 GiB + exactly 512 MiB -> rounds up
paseo_memory_case 15 finite "" 16642998271   # one byte less            -> rounds down
# Sub-GiB boxes. Two things must hold and neither is a remembered number: the share
# never renders `MemoryMax=0M` (which systemd accepts and which stops the unit dead),
# and it never sits above the box it is a share of. Rounding the cap UP is what would
# break the second, so these are the cases that hold the installer's clamp in place.
paseo_memory_case 1 share-only "" 536870911  # 0.4999 GiB — rounds up, must be clamped
paseo_memory_case 1 share-only "" 629145600  # 600 MiB
paseo_memory_case 1 share-only "" 1          # 1 byte — the seam's floor
# A malformed seam value must be fatal, not ignored. `AIRLOCK_PASEO_MEM_CAP_BYTES=32GiB`
# is a units typo anyone could write, and it used to fall through to /proc/meminfo
# silently — so a suite that believed it had pinned the RAM was reading the runner's,
# which is the single outcome the pin gate exists to prevent. Nothing else in this file
# can catch that: every other case passes a well-formed number, so removing the
# strictness leaves them all green (measured).
paseo_bad_seam_case() {
  local val="$1" WDIR CFG out rc=0
  WDIR="$(mktemp -d)"; mkdir -p "$WDIR/home" "$WDIR/render" "$WDIR/shim"
  CFG="$WDIR/airlock.toml"
  {
    printf '[site]\nname = "RenderParity"\n\n[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n\n'
    printf '[apps.paseo]\n'
  } > "$CFG"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    command -v "$cmd" >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$WDIR/shim/$cmd"; chmod +x "$WDIR/shim/$cmd"; }
  done <<<"$ALL_PREREQ_CMDS"
  out="$(
    export HOME="$WDIR/home" AIRLOCK_CONFIG="$CFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
           AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$WDIR/render" \
           AIRLOCK_PASEO_MEM_CAP_BYTES="$val" PATH="$WDIR/shim:$PATH"
    unset AIRLOCK_PASEO_ALLOW_UNBACKED_MEM AIRLOCK_PASEO_TASKS_MAX
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/paseo" AIRLOCK_APP_ID=paseo \
    bash "$ROOT/apps/paseo/install.sh" 2>&1
  )" || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "paseo memory seam '${val}': a malformed pin was accepted — the installer read this box's RAM instead"
  elif ! grep -qF "AIRLOCK_PASEO_MEM_CAP_BYTES must be a plain byte count" <<<"$out"; then
    bad "paseo memory seam '${val}': refused, but without saying the value was the problem"
    printf '%s\n' "$out" | tail -6 | sed 's/^/    /'
  else
    ok "paseo memory seam '${val}': a malformed pin is fatal and names itself"
  fi
  rm -rf "$WDIR"
}
paseo_bad_seam_case '32GiB'      # the units typo
paseo_bad_seam_case '8589934592 ' # a stray trailing space
paseo_bad_seam_case 'max'        # the cgroup sentinel, which is NOT a valid pin

# The number of cases above is asserted, because deleting cases is otherwise invisible:
# shrinking the cap loop from thirteen entries to one left this suite fully green.
paseo_mem_cases_expected=25
if [ "$paseo_mem_cases_run" -ne "$paseo_mem_cases_expected" ]; then
  bad "paseo memory coverage: ${paseo_mem_cases_run} cases ran, ${paseo_mem_cases_expected} expected — cases were added or removed without updating the count"
else
  ok "paseo memory coverage: all ${paseo_mem_cases_expected} declared cases ran"
fi

# Gate: a suite that runs the real installer must pin the RAM the paseo sizing block
# reads, or its result depends on the RAM of whichever box ran it: the backstop is a
# SHARE of the box, so unpinned, every runner writes a different MemoryMax and the
# goldens bake in whichever the runner happened to have.
#
# Two things the naive version of this gate got wrong, both found by review:
#   - It matched the literal `apps/paseo/install.sh`, so the dynamic idiom this very
#     file uses at run_installer_path (`bash "$ROOT/apps/$app/install.sh"`) slipped
#     past. A throwaway suite copying that line sat unpinned while the gate reported
#     "all pinned". The app segment is now a wildcard.
#   - It scanned whole files including comments, so the pin comment each suite
#     received — which itself names apps/paseo/install.sh — made the count partly
#     self-satisfying. Comment lines are stripped before matching, so the count is
#     evidence about code.
paseo_pin_scanned=0
paseo_pin_unpinned=()
for _suite in "$HERE"/test-*.sh; do
  # Process substitution, NOT a pipe. `producer | grep -q` is a SIGPIPE trap under
  # `set -o pipefail` (this file's option set): grep -q exits at the FIRST match, the
  # producer dies of SIGPIPE, the pipeline status goes nonzero, and `|| continue` then
  # skips exactly the suites that DID match. Measured: the gate reported 9 while 12
  # matched. `< <(...)` puts the producer outside the status this `if` reads.
  # Not `^[^#]*` either: that reads any earlier `#` on the line as a comment start, so
  # `bash "${ROOT#/}/apps/paseo/install.sh"` — ordinary parameter expansion — would
  # silently drop the suite from the gate.
  #
  # LIMIT, stated because the ok line below would otherwise overstate it: this is a
  # TEXT scan, so a path assembled across variables is invisible to it. Measured
  # evasions, none of which exist in this tree today (every suite spells the path out,
  # at most with `$app` in the app segment):
  #     INST="$ROOT/apps/paseo"; bash "$INST/install.sh"
  #     bash "$ROOT/apps/paseo"/install.sh
  #     cd "$ROOT/apps/paseo" && bash ./install.sh
  # If a suite ever needs one of those shapes, pin it by hand — the gate will not ask.
  grep -qE 'apps/[^/[:space:]"]*/install\.sh|airlock-install\.sh' \
    < <(grep -vE '^[[:space:]]*#' "$_suite") || continue
  paseo_pin_scanned=$(( paseo_pin_scanned + 1 ))
  # Comments stripped on THIS side too. They were not, so replacing a suite's real
  # export with a comment that merely mentions the variable passed the gate — the same
  # "a comment satisfies the check" defect the matcher above was already fixed for.
  grep -q 'AIRLOCK_PASEO_MEM_CAP_BYTES' \
    < <(grep -vE '^[[:space:]]*#' "$_suite") || paseo_pin_unpinned+=("$(basename "$_suite")")
done
# Positive control on the scan itself: if the match expression ever stops matching,
# the loop would report "all pinned" while having looked at nothing.
if [ "$paseo_pin_scanned" -lt 5 ]; then
  bad "paseo RAM pin gate: the scan found only ${paseo_pin_scanned} suites running the real installer — the match expression is broken, not the tree"
elif [ "${#paseo_pin_unpinned[@]}" -ne 0 ]; then
  bad "paseo RAM pin gate: ${#paseo_pin_unpinned[@]} of ${paseo_pin_scanned} suites run the real installer without pinning AIRLOCK_PASEO_MEM_CAP_BYTES: ${paseo_pin_unpinned[*]}"
else
  ok "paseo RAM pin gate: all ${paseo_pin_scanned} suites whose text names a real app installer (comments stripped, dynamic app segment included) pin the RAM it sizes from"
fi

run_installer_path publish "" "" installer-path \
  "confd/hub-locations.d/publish.conf" "nginx.conf" \
  "units/airlock-publish.service" "unit-service.service" \
  "units/airlock-publish-cleanup.service" "unit-cleanup.service" \
  "units/airlock-publish-cleanup.timer" "unit-timer.timer"

# ===========================================================================
# paseo nested-installer ABI: the browse-host sidecar
# (apps/paseo/browse-host/install.sh) is invoked as a NESTED bash subprocess
# from paseo's own install.sh (`bash "$BROWSE_INSTALL"`, only reached when
# browse=true — off by default, so run_installer_path above never exercises it).
#
# It has to split two questions that used to be answered by one climb:
#
#   which platform?  -> AIRLOCK_ROOT, inherited from the packaged parent. It is
#                       the same platform, so inheriting is correct — and it is
#                       now the ONLY answer, because "../../.." is the platform
#                       only while the package sits in the platform's apps/ tree.
#   which files are  -> ${BASH_SOURCE[0]}, this sidecar's own directory. That
#   mine?               must NOT come from the inherited AIRLOCK_APP_DIR, which
#                       names paseo's package root, not this subdirectory.
#
# This fixture used to assert the opposite for the first question — that the
# script ignores the inherited AIRLOCK_ROOT and computes its own by climbing.
# That pinned the legacy arrangement in place: it passed only because the
# package was inside the platform, which is exactly what the cutover ends.
#
# Both legs run the REAL script (not an extracted copy — BASH_SOURCE only
# reflects reality for a script executed as a real file), with node withheld
# from PATH so a correct run fails at its own `require_cmd node npm systemctl`,
# the first thing it does after sourcing $ROOT/install/lib.sh. Reaching
# require_cmd is the evidence that lib.sh resolved; a wrong root instead dies
# sourcing a nonexistent install/lib.sh, a distinguishable bash error.
BH_INSTALL="$ROOT/apps/paseo/browse-host/install.sh"
BH_NOPATH="$TMP/paseo-nested-abi-nonode-path"; mkdir -p "$BH_NOPATH"
for c in bash sh grep sed cat mktemp dirname basename readlink; do
  [ -n "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$BH_NOPATH/$c" 2>/dev/null
done

# Leg 1 — the platform comes from the inherited AIRLOCK_ROOT, and a POLLUTED
# AIRLOCK_APP_DIR does not displace the sidecar's own BASH_SOURCE location.
BH_ERR="$(
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$TMP/not-the-real-app-dir" \
    AIRLOCK_APP_ID=paseo PATH="$BH_NOPATH" bash "$BH_INSTALL" 2>&1 >/dev/null
)"; BH_RC=$?
if [ "$BH_RC" -eq 0 ]; then
  bad "paseo nested ABI: browse-host/install.sh exited 0 with node withheld from PATH (expected it to refuse)"
elif grep -qF 'required command not found: node' <<<"$BH_ERR"; then
  ok "paseo nested ABI: browse-host/install.sh takes the platform from the inherited AIRLOCK_ROOT and its own files from \${BASH_SOURCE[0]}, unaffected by a polluted AIRLOCK_APP_DIR"
else
  bad "paseo nested ABI: browse-host/install.sh failed for the wrong reason (never reached require_cmd — ROOT resolved wrong): $BH_ERR"
fi

# Leg 2 — with no AIRLOCK_ROOT it must REFUSE rather than climb out of itself.
# Without this leg, leg 1 would still pass if the script went back to climbing:
# inside this repository the climb and the inherited root are the same path, and
# that coincidence is the whole reason the legacy shape survived unnoticed.
BH_ERR2="$(env -u AIRLOCK_ROOT -u AIRLOCK_APP_DIR -u AIRLOCK_APP_ID \
  PATH="$BH_NOPATH" bash "$BH_INSTALL" 2>&1 >/dev/null)"; BH_RC2=$?
if [ "$BH_RC2" -ne 0 ] && grep -qF 'AIRLOCK_ROOT' <<<"$BH_ERR2"; then
  ok "paseo nested ABI: browse-host/install.sh refuses to run without AIRLOCK_ROOT instead of climbing \"../../..\" to a root it cannot have after the cutover"
else
  bad "paseo nested ABI: browse-host/install.sh ran (or failed for another reason) without AIRLOCK_ROOT (rc=$BH_RC2): $BH_ERR2"
fi

# ===========================================================================
# AIRLOCK_RENDER_DIR contract fixtures (round 2 Blocker 3).
#
# Fail-closed guard: AIRLOCK_RENDER_DIR set WITHOUT AIRLOCK_DRY_RUN=1 must
# abort immediately (install/lib.sh), before touching sudo or systemctl.
# Proven with shims that LOG every invocation — an empty log after the run
# is the actual evidence, not just a nonzero exit code (a script could exit
# nonzero for an unrelated reason after already calling sudo once).
#
# Combination fixture: DRY_RUN=1 + RENDER_DIR together is the supported
# form (already exercised for every app above, in run_installer_path) —
# still asserted explicitly here for feedback, checking BOTH that the
# unconditional nginx write redirects AND that the dry-run-gated unit write
# ALSO redirects (M4 fix: RENDER_DIR takes precedence over the dry-run skip
# for every render_* call site — a pure dry run with no RENDER_DIR still only
# logs, asserted separately below).
# ===========================================================================
GDTMP="$(mktemp -d)"
mkdir -p "$GDTMP/home" "$GDTMP/render" "$GDTMP/shim"
GDCFG="$GDTMP/airlock.toml"
cat > "$GDCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
[apps.feedback]
EOF
cat > "$GDTMP/shim/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_SUDO_LOG"
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
STUB
cat > "$GDTMP/shim/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_SYSTEMCTL_LOG"
exit 0
STUB
chmod +x "$GDTMP/shim/sudo" "$GDTMP/shim/systemctl"
: > "$GDTMP/sudo.log"; : > "$GDTMP/systemctl.log"
gd_out="$(
  export HOME="$GDTMP/home" AIRLOCK_CONFIG="$GDCFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
         AIRLOCK_RENDER_DIR="$GDTMP/render" AIRLOCK_TEST_SUDO_LOG="$GDTMP/sudo.log" \
         AIRLOCK_TEST_SYSTEMCTL_LOG="$GDTMP/systemctl.log" PATH="$GDTMP/shim:$PATH"
  unset AIRLOCK_DRY_RUN
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/feedback" AIRLOCK_APP_ID=feedback \
  bash "$ROOT/apps/feedback/install.sh" 2>&1
)"; gd_rc=$?
if [ "$gd_rc" -eq 0 ]; then
  bad "render-dir guard: AIRLOCK_RENDER_DIR without AIRLOCK_DRY_RUN=1 exited 0 (must fail closed)"
elif ! printf '%s' "$gd_out" | grep -q "AIRLOCK_RENDER_DIR is a test-harness hook"; then
  bad "render-dir guard: exited $gd_rc but not with the expected fail-closed message"
  printf '%s\n' "$gd_out" | tail -10 | sed 's/^/    /'
else
  ok "render-dir guard: AIRLOCK_RENDER_DIR alone exits nonzero with the fail-closed message"
fi
if [ -s "$GDTMP/sudo.log" ] || [ -s "$GDTMP/systemctl.log" ]; then
  bad "render-dir guard: sudo/systemctl were invoked before the fail-closed guard fired"
  cat "$GDTMP/sudo.log" "$GDTMP/systemctl.log" | sed 's/^/    /'
else
  ok "render-dir guard: sudo/systemctl shim logs are empty (guard fired before any mutation)"
fi
rm -rf "$GDTMP"

RDTMP="$(mktemp -d)"
mkdir -p "$RDTMP/home" "$RDTMP/render"
RDCFG="$RDTMP/airlock.toml"
cat > "$RDCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
[apps.feedback]
EOF
(
  export HOME="$RDTMP/home" AIRLOCK_CONFIG="$RDCFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
         AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$RDTMP/render"
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/feedback" AIRLOCK_APP_ID=feedback \
  bash "$ROOT/apps/feedback/install.sh"
) > "$RDTMP/install.log" 2>&1
rc=$?
frag="$RDTMP/render/confd/hub-locations.d/feedback.conf"
unit="$RDTMP/render/units/airlock-feedback.service"
if [ "$rc" -ne 0 ]; then
  bad "render-dir combo: feedback install.sh exited $rc"
  sed 's/^/    /' "$RDTMP/install.log"
elif [ ! -f "$frag" ]; then
  bad "render-dir combo: nginx fragment not found under AIRLOCK_RENDER_DIR ($frag) — the unconditional write site did not redirect"
else
  ok "render-dir combo: nginx fragment redirected under AIRLOCK_RENDER_DIR"
fi
if [ ! -f "$unit" ]; then
  bad "render-dir combo: unit file NOT written under AIRLOCK_DRY_RUN=1+AIRLOCK_RENDER_DIR ($unit) — the dry-run-gated write site did not redirect (M4)"
else
  ok "render-dir combo: unit write correctly redirects under AIRLOCK_DRY_RUN=1+AIRLOCK_RENDER_DIR"
fi
rm -rf "$RDTMP"

# A PURE dry run (AIRLOCK_DRY_RUN=1, no AIRLOCK_RENDER_DIR) must be completely
# unaffected by the M4 fix above: the unit write site still just logs and
# writes nothing anywhere. This is the other half of the "write conditions
# unchanged outside RENDER_DIR" invariant test-integration.sh:52 also pins.
PDTMP="$(mktemp -d)"
mkdir -p "$PDTMP/home" "$PDTMP/confd"
PDCFG="$PDTMP/airlock.toml"
cat > "$PDCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
[apps.feedback]
EOF
(
  export HOME="$PDTMP/home" AIRLOCK_CONFIG="$PDCFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
         AIRLOCK_CONFD="$PDTMP/confd" AIRLOCK_DRY_RUN=1
  unset AIRLOCK_RENDER_DIR
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/feedback" AIRLOCK_APP_ID=feedback \
  bash "$ROOT/apps/feedback/install.sh"
) > "$PDTMP/install.log" 2>&1
pd_rc=$?
if [ "$pd_rc" -ne 0 ]; then
  bad "pure dry run: feedback install.sh exited $pd_rc"
  sed 's/^/    /' "$PDTMP/install.log"
elif [ -e "$PDTMP/home/.config/systemd/user/airlock-feedback.service" ]; then
  bad "pure dry run: unit file WAS written with no AIRLOCK_RENDER_DIR set — a pure dry run must only log"
else
  ok "pure dry run: unit write correctly skipped (no AIRLOCK_RENDER_DIR, logs only)"
fi
rm -rf "$PDTMP"

# ===========================================================================
# orca RENDER_DIR combo (round-3 M4): the sudo-tee nft/firewall-unit write
# site is the one path where the real branch reaches sudo, so its RENDER_DIR
# carve-out could not reuse the simple if/else every other app uses (see
# apps/orca/install.sh's nft section, three-way branch). Proves ALL of
# orca's rendered artifacts redirect under AIRLOCK_RENDER_DIR — reap script,
# both --user units, the nft ruleset, AND the system-scope firewall unit —
# with sudo/systemctl shims that log every invocation: an empty sudo log
# after the run is the actual evidence, not just "no error".
# ===========================================================================
ODTMP="$(mktemp -d)"
mkdir -p "$ODTMP/home" "$ODTMP/render" "$ODTMP/shim"
ODCFG="$ODTMP/airlock.toml"
cat > "$ODCFG" <<EOF
[site]
name = "RenderParity"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
[apps.orca]
EOF
cat > "$ODTMP/shim/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_SUDO_LOG"
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
STUB
cat > "$ODTMP/shim/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_SYSTEMCTL_LOG"
exit 0
STUB
chmod +x "$ODTMP/shim/sudo" "$ODTMP/shim/systemctl"
: > "$ODTMP/sudo.log"; : > "$ODTMP/systemctl.log"
# Shim every other missing prerequisite too (mirrors run_installer_path;
# ALL_PREREQ_CMDS — F11 assembly, not the raw TSV alone — see its
# definition near the top of this file).
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$ODTMP/shim/$cmd"; chmod +x "$ODTMP/shim/$cmd"
  fi
done <<<"$ALL_PREREQ_CMDS"
od_out="$(
  export HOME="$ODTMP/home" AIRLOCK_CONFIG="$ODCFG" AIRLOCK_TS_FQDN="box.example.ts.net" \
         AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$ODTMP/render" \
         AIRLOCK_TEST_SUDO_LOG="$ODTMP/sudo.log" AIRLOCK_TEST_SYSTEMCTL_LOG="$ODTMP/systemctl.log" \
         PATH="$ODTMP/shim:$PATH"
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/orca" AIRLOCK_APP_ID=orca \
  bash "$ROOT/apps/orca/install.sh" 2>&1
)"; od_rc=$?
if [ "$od_rc" -ne 0 ]; then
  bad "orca render-dir combo: install.sh exited $od_rc"
  printf '%s\n' "$od_out" | tail -25 | sed 's/^/    /'
else
  ok "orca render-dir combo: install.sh exited 0"
fi
for artifact in \
  "render/units/airlock-orca-xvfb.service" \
  "render/units/airlock-orca.service" \
  "render/bin/airlock-orca-reap" \
  "render/etc-airlock/orca-loopback.nft" \
  "render/etc-systemd-system/airlock-orca-firewall.service" \
  "render/confd/servers.d/orca.conf"
do
  if [ -f "$ODTMP/$artifact" ]; then
    ok "orca render-dir combo: $artifact redirected under AIRLOCK_RENDER_DIR"
  else
    bad "orca render-dir combo: $artifact NOT found under AIRLOCK_RENDER_DIR"
  fi
done
if [ -s "$ODTMP/sudo.log" ]; then
  bad "orca render-dir combo: sudo WAS invoked under AIRLOCK_RENDER_DIR (the sudo-tee nft path must skip sudo entirely)"
  cat "$ODTMP/sudo.log" | sed 's/^/    /'
else
  ok "orca render-dir combo: sudo shim log is empty (nft/firewall-unit write skipped sudo)"
fi
if [ -s "$ODTMP/systemctl.log" ]; then
  bad "orca render-dir combo: systemctl WAS invoked under AIRLOCK_RENDER_DIR (every systemctl call here goes through airlock_run, which must stay dry under AIRLOCK_DRY_RUN=1)"
  cat "$ODTMP/systemctl.log" | sed 's/^/    /'
else
  ok "orca render-dir combo: systemctl shim log is empty (every mutation stayed dry)"
fi
rm -rf "$ODTMP"

# ===========================================================================
# renderer silence — the summary, and the two controls that prove the check
# is doing something.
#
# One line rather than one per call: 30 extra "ok" lines would bury the number
# that matters, which is how many renderer calls were checked at all. If that
# count ever drops, a call site has been added that bypasses render_to.
# ===========================================================================
if [ "$render_dirty" -eq 0 ]; then
  ok "renderer silence: all $render_calls direct renderer calls exited 0, wrote stdout, and wrote nothing to stderr"
else
  bad "renderer silence: $render_dirty of $render_calls direct renderer calls were not clean (details above)"
fi
[ "$render_calls" -ge 50 ] \
  || bad "renderer silence: only $render_calls direct renderer calls went through render_to — a call site is bypassing it"

# Positive control. A renderer with defect 5's exact shape: an unquoted heredoc
# whose comment contains a backtick. It must be caught, and the --regen guard must
# refuse to write a golden from it. Run in a subshell so its deliberate failure
# does not count against this suite.
# The bad fixture is GENERATED, not written literally, and the reason is the point:
# a literal backtick-in-an-unquoted-heredoc anywhere in this tree is exactly what
# install/check-shellcheck-gates.sh now refuses, and it scans tracked files by
# content, not by an exclusion list. A control that had to be exempted from the
# other gate would be the first crack in it. `\140` is the backtick; the fixture
# lands under $TMP, which is untracked and therefore out of that gate's scope.
CTL_LIB="$TMP/control-renderers.sh"
{
  printf '_ctl_bad_render() {\n  cat <<CTLEOF\n[Service]\n'
  printf '# the default is \140this-command-does-not-exist-4b1f\140\n'
  printf 'TasksMax=infinity\nCTLEOF\n}\n'
  printf '_ctl_good_render() {\n  cat <<CTLEOF\n[Service]\n'
  printf "# the default is 'infinity'\n"
  printf 'TasksMax=infinity\nCTLEOF\n}\n'
} > "$CTL_LIB"
# shellcheck source=/dev/null
. "$CTL_LIB"
ctl_out="$( ctl_f="$(out_file)"; render_to "$ctl_f" _ctl_bad_render 2>&1 )"
case "$ctl_out" in
  *"wrote to stderr"*) ok "renderer silence positive control: a backticked comment in an unquoted heredoc is caught" ;;
  *) bad "renderer silence positive control: the check did not fire (got: $ctl_out)" ;;
esac
ctl_out="$(
  MODE=--regen
  ctl_f="$(out_file)"
  render_to "$ctl_f" _ctl_bad_render >/dev/null 2>&1
  golden_check_file "control/never-written.service" "$ctl_f" 2>&1
)"
case "$ctl_out" in
  *"golden NOT written"*) ok "renderer silence positive control: --regen refuses a golden from an unclean render" ;;
  *) bad "renderer silence positive control: --regen would have written the damaged output (got: $ctl_out)" ;;
esac
[ -e "$GOLDEN/control/never-written.service" ] \
  && bad "renderer silence positive control: the refused golden was written anyway"
# Negative control — the same comment written correctly must still pass, or the
# rule is just "renderers may not have comments".
ctl_out="$( ctl_f="$(out_file)"; render_to "$ctl_f" _ctl_good_render 2>&1 )"
if [ -z "$ctl_out" ]; then
  ok "renderer silence negative control: a single-quoted comment in the same heredoc passes"
else
  bad "renderer silence negative control: a legitimate renderer was rejected (got: $ctl_out)"
fi

echo
echo "render-parity: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
