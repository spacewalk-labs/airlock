#!/usr/bin/env bash
# Contracts for bin/airlock-status — the box's one status question.
#
# Two halves, and the second is the reason this file exists.
#
#  1. The MACHINE FORMAT is pinned here: the roster of check ids, their order,
#     the keys on every check, the status vocabulary, and the mapping from the
#     document's verdict to the process exit code. Another program may depend
#     on all of that, so changing any of it has to change this file too.
#
#  2. The NEGATIVE CONTROL: a box broken on purpose, several different ways,
#     must come out RED. The class of defect being guarded against is the one
#     measured on 2026-08-29 in bin/airlock-smoke (recorded in
#     docs/worklog/2026-08-29-live-check-emulation-and-live-drift.md): with an
#     unparseable airlock.toml it checked zero apps, printed "all 0 app
#     smoke(s) passed" and exited 0. An empty result set had become a pass.
#     Cases D and I below are that exact input; both assert airlock-status goes
#     red, and both print bin/airlock-smoke's own exit status beside it as the
#     measured contrast. That contrast is PRINTED, not asserted: fixing smoke
#     is a separate piece of work and must not break this suite.
#
# Hermetic: a scratch copy of the checkout, scratch platform roots, PATH-shimmed
# tailscale/systemctl/curl, and real loopback listeners on scratch ports. It
# needs no root, no network, and never touches the live box.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
LISTENER_PID=""
cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null
    wait "$LISTENER_PID" 2>/dev/null      # reap it; a bare kill leaves a zombie
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '     %s\n' "$1"; }

# ---- scratch checkout -------------------------------------------------------
# bin/airlock-status derives its root from its own path, so the tool under test
# has to live in the scratch tree. It is made a git repository because
# install.revision reports the checkout revision, and "not a git checkout" is a
# legitimate `unchecked` that would keep the healthy case from being green.
ROOT="$TMP/repo"
mkdir -p "$ROOT"
if ! (cd "$SOURCE_ROOT" && tar --exclude='./.git' --exclude='./airlock.lock' -cf - .) \
     | (cd "$ROOT" && tar -xf -); then
  echo "FAIL could not create scratch repository" >&2
  exit 1
fi
# A seam for making airlock-config FAIL on one subcommand. Not a seam in the
# production tool — a wrapper in the scratch tree, standing in for the ways a
# dependency really can stop answering on a live box (a full disk, an OOM kill).
# Two of airlock-status's `unchecked` paths are only reachable this way, and an
# unreachable path is an unverified one.
mv "$ROOT/bin/airlock-config" "$ROOT/bin/airlock-config.real"
cat >"$ROOT/bin/airlock-config" <<'WRAPPER'
#!/usr/bin/env python3
import os, runpy, sys
if len(sys.argv) > 1 and sys.argv[1] in os.environ.get("AIRLOCK_TEST_CONFIG_FAIL", "").split():
    sys.stderr.write("airlock-config: injected failure for %s\n" % sys.argv[1])
    sys.exit(9)
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "airlock-config.real")
sys.argv[0] = real
runpy.run_path(real, run_name="__main__")
WRAPPER
chmod +x "$ROOT/bin/airlock-config"

# --no-verify and an empty hooksPath: whether this passes must not depend on
# the hooks the person running it happens to have installed globally.
if ! ( cd "$ROOT" \
       && git init -q \
       && git -c core.hooksPath=/dev/null -c user.email=t@example.invalid \
              -c user.name=fixture -c commit.gpgsign=false add -A \
       && git -c core.hooksPath=/dev/null -c user.email=t@example.invalid \
              -c user.name=fixture -c commit.gpgsign=false commit -q --no-verify -m fixture ) >/dev/null 2>&1; then
  echo "FAIL could not make the scratch checkout a git repository" >&2
  exit 1
fi
STATUS="$ROOT/bin/airlock-status"
SMOKE="$ROOT/bin/airlock-smoke"

# A status file is intentionally mode 0644 and documented as a Python entry point.
# In practice, that refusal naturally sends an operator to `bash bin/airlock-status`.
# The old module docstring let Bash interpret Markdown backticks before it reached a
# syntax error; the `-> 100755` example therefore created an empty file named 100755
# in the checkout.  Keep that observed invocation fail-closed and side-effect-free.
status_bash_out="$(cd "$ROOT" && bash bin/airlock-status 2>&1)"; status_bash_rc=$?
if [ "$status_bash_rc" = 2 ] \
   && printf '%s' "$status_bash_out" | grep -q 'python3 bin/airlock-status' \
   && (cd "$ROOT" && test ! -e 100755); then
  ok "P bash invocation refuses safely without creating 100755"
else
  bad "P bash invocation left a side effect or no Python guidance (rc=$status_bash_rc)"
  note "$(printf '%s' "$status_bash_out" | head -1)"
fi

# ---- the fixture box --------------------------------------------------------
# Ports are allocated by the kernel, never hardcoded. A fixed port is host state:
# anything else on the box holding 44402 turns this suite red for a reason that
# has nothing to do with the code under test — which is exactly what happened
# while this file was being written, with a second copy of the suite running.
#
# Five ports are HELD by a listener for the whole run (apps.backends does a real
# connect() against them). Three more are allocated and released: they are only
# ever compared against the tailscale shim's output, so nothing has to be there.
OWNER="owner@example.invalid"
PORTS_FILE="$TMP/ports"

python3 - "$PORTS_FILE" "$TMP" >"$TMP/listener.log" 2>&1 <<'LISTENER' &
import os, selectors, socket, sys, time

ports_file, tmp = sys.argv[1], sys.argv[2]

def bind():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(64)
    return s, s.getsockname()[1]

held = [bind() for _ in range(5)]          # kept open for the whole run
spare = [bind() for _ in range(3)]         # numbers only
for s, _ in spare:
    s.close()

with open(ports_file + ".tmp", "w") as fh:
    fh.write(" ".join(str(p) for _, p in held + spare) + "\n")
os.rename(ports_file + ".tmp", ports_file)  # appears complete or not at all

# Accept and drop every connection. A listener that only binds fills its accept
# queue after a handful of probes and then starts refusing them, which surfaces
# much later as an unrelated case going red for no visible reason.
sel = selectors.DefaultSelector()
open_socks = {}
for s, port in held:
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ)
    open_socks[port] = s

deadline = time.time() + 900
while time.time() < deadline:
    # A case that needs a port to go dead asks for it here, rather than the
    # suite hoping some port is free: "nothing is listening" has to be arranged,
    # not assumed.
    for port, s in list(open_socks.items()):
        if os.path.exists(f"{tmp}/drop-{port}"):
            sel.unregister(s)
            s.close()
            del open_socks[port]
            open(f"{tmp}/dropped-{port}", "w").close()
    for key, _ in sel.select(timeout=0.2):
        try:
            key.fileobj.accept()[0].close()
        except OSError:
            pass
LISTENER
LISTENER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$PORTS_FILE" ] && break
  sleep 0.1
done
if [ ! -s "$PORTS_FILE" ]; then
  echo "FAIL could not allocate the fixture ports:" >&2
  cat "$TMP/listener.log" >&2
  exit 1
fi
read -r HUB_NGINX HUB_REDIRECT DT_GATE DT_TTYD DT_BACKEND HUB_HTTPS HUB_HTTP DT_HTTPS <"$PORTS_FILE"

CFG="$TMP/airlock.toml"
cat >"$CFG" <<TOML
[airlock]
config_version = 2

[site]
name = "Status Fixture"

[auth]
provider = "tailscale"
owner = "$OWNER"

[apps.hub]
https_port = $HUB_HTTPS
http_port = $HUB_HTTP
nginx_port = $HUB_NGINX
redirect_port = $HUB_REDIRECT

[apps.devterm]
https_port = $DT_HTTPS
gate_port = $DT_GATE
ttyd_port = $DT_TTYD
backend_port = $DT_BACKEND
TOML
# Tailnet listens the install is supposed to have mapped — ingress.serve.
SERVE_PORTS_ALL="$HUB_HTTPS $DT_HTTPS $HUB_HTTP"

STATE="$TMP/state"; UU="$TMP/units-user"; US="$TMP/units-system"
mkdir -p "$STATE" "$UU" "$US"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
# The unit files the ledger will record as placed. bin/airlock-ledger commit
# records the artifacts that are actually there, so these have to exist.
printf '[Unit]\n' >"$UU/airlock-devterm.service"
printf '[Unit]\n' >"$UU/airlock-devterm-gate.service"

# The install record is written by bin/airlock-ledger itself rather than by
# hand: airlock-config validate reads the store and rejects a malformed one, so
# a hand-rolled fixture would be testing the fixture. `""` writes an empty but
# valid store — a box that has recorded nothing.
write_ledger() {   # write_ledger [<app id to commit>]
  local app="${1:-}"
  rm -f "$STATE/app-ledger.json"
  printf '{"version": 6, "entries": {}, "events": []}\n' >"$STATE/app-ledger.json"
  [ -n "$app" ] || return 0
  AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-config" package-info >"$TMP/pkg-info.json" \
    || { echo "FAIL fixture: package-info" >&2; return 1; }
  AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-ledger" intent "$app" \
    <"$TMP/pkg-info.json" >/dev/null 2>&1 || { echo "FAIL fixture: ledger intent" >&2; return 1; }
  AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-ledger" commit "$app" \
    <"$TMP/pkg-info.json" >/dev/null 2>&1 || { echo "FAIL fixture: ledger commit" >&2; return 1; }
}
export AIRLOCK_STATE_DIR="$STATE"
write_ledger devterm || exit 1

# ---- shims ------------------------------------------------------------------
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/tailscale" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  python3 - "${AIRLOCK_TEST_TS_STATE:-Running}" "${AIRLOCK_TEST_TS_DNSNAME-box.example.ts.net.}" <<'PY'
import json, sys
state, dns = sys.argv[1], sys.argv[2]
self_ = {"DNSName": dns} if dns else {}
print(json.dumps({"BackendState": state, "CertDomains": ["example.ts.net"],
                  "Self": self_, "Health": []}))
PY
  exit 0
fi
if [ "${1:-}" = serve ] && [ "${2:-}" = status ]; then
  python3 - ${AIRLOCK_TEST_SERVE_PORTS-} <<'PY'
import json, sys
print(json.dumps({"TCP": {p: {"HTTPS": True} for p in sys.argv[1:]}}))
PY
  exit 0
fi
exit 0
STUB
cat >"$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
unit=""
for a in "$@"; do case "$a" in *.service|*.socket|*.timer|*.path|*.target) unit="$a" ;; esac; done
props() {
  local type= active=active sub=waiting result=success status= load=loaded
  case "$unit" in
    *.service) type=simple; sub=running; status=0 ;;
  esac
  case " ${AIRLOCK_TEST_DEAD_UNITS-} " in
    *" $unit "*) active=inactive; sub=dead ;;
  esac
  case " ${AIRLOCK_TEST_ONESHOT_SUCCESS_UNITS-} " in
    *" $unit "*) type=oneshot; active=inactive; sub=dead ;;
  esac
  case " ${AIRLOCK_TEST_ONESHOT_ACTIVATING_UNITS-} " in
    *" $unit "*) type=oneshot; active=activating; sub=start ;;
  esac
  case " ${AIRLOCK_TEST_ONESHOT_FAILED_UNITS-} " in
    *" $unit "*) type=oneshot; active=failed; sub=failed; result=exit-code; status=1 ;;
  esac
  case " ${AIRLOCK_TEST_CONTRADICTORY_ACTIVE_UNITS-} " in
    *" $unit "*) type=simple; active=active; sub=failed; result=success; status=0 ;;
  esac
  case " ${AIRLOCK_TEST_BAD_ACTIVATING_UNITS-} " in
    *" $unit "*) type=oneshot; active=activating; sub=dead; result=success; status=0 ;;
  esac
  case " ${AIRLOCK_TEST_INACTIVE_TIMER_UNITS-} " in
    *" $unit "*) type=; active=inactive; sub=dead ;;
  esac
  case " ${AIRLOCK_TEST_NOT_FOUND_UNITS-} " in
    *" $unit "*) type=; load=not-found; active=inactive; sub=dead ;;
  esac
  printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nResult=%s\n' \
    "$load" "$active" "$sub" "$result"
  [ -n "$type" ] && printf 'Type=%s\n' "$type"
  [ -n "$status" ] && printf 'ExecMainStatus=%s\n' "$status"
}
case " $* " in
  *" show "*) props; exit 0 ;;
esac
case " ${AIRLOCK_TEST_ONESHOT_ACTIVATING_UNITS-} " in
  *" $unit "*) printf 'activating\n'; exit 3 ;;
esac
case " ${AIRLOCK_TEST_ONESHOT_FAILED_UNITS-} " in
  *" $unit "*) printf 'failed\n'; exit 3 ;;
esac
case " ${AIRLOCK_TEST_DEAD_UNITS-} " in
  *" $unit "*) printf 'inactive\n'; exit 3 ;;
esac
printf 'active\n'
exit 0
STUB
# The curl shim answers per REQUEST, not per run: the three gate probes and the
# entrance probe are different questions and a fixture that could only give one
# answer could not express a gate hole.
cat >"$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
hdr=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) hdr="${2-}"; shift 2 ;;
    -o|-w|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://*) printf '%s' "${AIRLOCK_TEST_ENTRANCE_CODE:-200}"; exit 0 ;;
esac
if [ -z "$hdr" ]; then
  printf '%s' "${AIRLOCK_TEST_GATE_ANON_CODE:-403}"
elif [ "${hdr#*: }" = "${AIRLOCK_TEST_OWNER-}" ]; then
  printf '%s' "${AIRLOCK_TEST_GATE_OWNER_CODE:-200}"
else
  printf '%s' "${AIRLOCK_TEST_GATE_STRANGER_CODE:-403}"
fi
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_TEST_OWNER="$OWNER"
export AIRLOCK_TEST_SERVE_PORTS="$SERVE_PORTS_ALL"

reset_box() {
  export AIRLOCK_CONFIG="$CFG"
  export AIRLOCK_TS_FQDN="box.example.ts.net"
  export AIRLOCK_TEST_SERVE_PORTS="$SERVE_PORTS_ALL"
  unset AIRLOCK_TEST_TS_STATE AIRLOCK_TEST_TS_DNSNAME AIRLOCK_TEST_DEAD_UNITS \
        AIRLOCK_TEST_ONESHOT_SUCCESS_UNITS AIRLOCK_TEST_ONESHOT_ACTIVATING_UNITS \
        AIRLOCK_TEST_ONESHOT_FAILED_UNITS AIRLOCK_TEST_INACTIVE_TIMER_UNITS \
        AIRLOCK_TEST_NOT_FOUND_UNITS AIRLOCK_TEST_CONTRADICTORY_ACTIVE_UNITS \
        AIRLOCK_TEST_BAD_ACTIVATING_UNITS \
        AIRLOCK_TEST_ENTRANCE_CODE AIRLOCK_TEST_GATE_ANON_CODE \
        AIRLOCK_TEST_GATE_OWNER_CODE AIRLOCK_TEST_GATE_STRANGER_CODE \
        AIRLOCK_TEST_CONFIG_FAIL
  write_ledger devterm || { echo "FAIL fixture: could not reset the box" >&2; exit 1; }
}

# run_status [--json] -> sets $rc and $out
rc=0; out=""
run_status() { out="$(python3 "$STATUS" "$@" 2>"$TMP/stderr")"; rc=$?; }

# jq is not a dependency of this repo; read the document with python3.
q() { printf '%s' "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>&1; }

# ---- A. a healthy box is green ---------------------------------------------
reset_box
run_status
if [ "$rc" = 0 ]; then ok "A healthy fixture box exits 0"
else bad "A healthy fixture box exited $rc"; printf '%s\n' "$out" | sed 's/^/     /'; fi
case "$out" in
  *"verdict: OK"*) ok "A the human summary states the verdict" ;;
  *) bad "A the human summary has no verdict line" ;;
esac
case "$out" in
  *"----"*) bad "A a healthy box still reports an unchecked line" ;;
  *) ok "A nothing on a healthy box is left unchecked" ;;
esac

# ---- B. the machine format is pinned ---------------------------------------
reset_box
run_status --json
if [ "$rc" = 0 ]; then ok "B --json on a healthy box exits 0"
else bad "B --json on a healthy box exited $rc"; fi

EXPECTED_IDS='config.validate config.owner install.ledger install.drift install.revision ingress.backend ingress.serve ingress.entrance gate.owner gate.stranger gate.anonymous units.active apps.enabled apps.backends'
got="$(q "' '.join(c['id'] for c in d['checks'])")"
if [ "$got" = "$EXPECTED_IDS" ]; then ok "B the check roster and its order are exactly as pinned"
else bad "B roster drifted"; note "want: $EXPECTED_IDS"; note "got : $got"; fi

got="$(q "' '.join(sorted(d))")"
want='checks counts exit_code generated_at host root schema_version tool verdict'
if [ "$got" = "$want" ]; then ok "B the document's top-level keys are exactly as pinned"
else bad "B top-level keys drifted"; note "want: $want"; note "got : $got"; fi

got="$(q "d['schema_version']")"
if [ "$got" = "1" ]; then ok "B schema_version is 1"
else bad "B schema_version is '$got', not 1 — a consumer pinned to 1 must be told"; fi

got="$(q "sorted({k for c in d['checks'] for k in c})")"
want="['detail', 'id', 'next', 'section', 'status', 'title']"
if [ "$got" = "$want" ]; then ok "B every check carries exactly the pinned keys"
else bad "B check keys drifted"; note "want: $want"; note "got : $got"; fi

got="$(q "sorted({c['status'] for c in d['checks']} - {'ok','warn','fail','unchecked'})")"
if [ "$got" = "[]" ]; then ok "B every status is in the vocabulary"
else bad "B status vocabulary drifted: $got"; fi

got="$(q "d['counts'] == {s: sum(1 for c in d['checks'] if c['status']==s) for s in ('ok','warn','fail','unchecked')} and len(d['checks'])==sum(d['counts'].values())")"
if [ "$got" = "True" ]; then ok "B counts add up to the checks they summarise"
else bad "B counts do not match the checks ($got)"; fi

# ---- C. the two outputs describe the same run -------------------------------
reset_box
run_status --json
json_verdict="$(q "d['verdict']")"
json_counts="$(q "'%d %d %d %d' % (d['counts']['ok'],d['counts']['warn'],d['counts']['fail'],d['counts']['unchecked'])")"
run_status
read -r n_ok n_warn n_fail n_unchecked <<EOF
$json_counts
EOF
human="verdict: $(printf '%s' "$json_verdict" | tr '[:lower:]' '[:upper:]') — $n_ok ok, $n_warn warn, $n_fail failed, $n_unchecked not checked"
case "$out" in
  *"$human"*) ok "C the human summary and --json report the same run" ;;
  *) bad "C the two outputs disagree"; note "expected in the human text: $human" ;;
esac

# ---- D. an unreadable config is red, and smoke is the contrast --------------
reset_box
printf 'this is not toml =\n' >"$TMP/broken.toml"
export AIRLOCK_CONFIG="$TMP/broken.toml"
run_status --json
if [ "$rc" = 1 ]; then ok "D an unparseable airlock.toml exits 1"
else bad "D an unparseable airlock.toml exited $rc, expected 1"; fi
got="$(q "[c['status'] for c in d['checks'] if c['id']=='config.validate'][0]")"
if [ "$got" = fail ]; then ok "D config.validate is the failure"
else bad "D config.validate is '$got'"; fi
got="$(q "sorted({c['status'] for c in d['checks'] if c['id']!='config.validate'})")"
if [ "$got" = "['unchecked']" ]; then
  ok "D nothing downstream of a broken config claims to have passed"
else bad "D downstream checks reported $got, not only 'unchecked'"; fi
got="$(q "len(d['checks'])")"
if [ "$got" = 14 ]; then ok "D a failed run still emits the whole roster"
else bad "D the roster shrank to $got checks on failure"; fi
smoke_out="$(cd "$ROOT" && bash "$SMOKE" 2>&1)"; smoke_rc=$?
note "for the record, on this same input — bin/airlock-smoke exits $smoke_rc, airlock-status exits 1"
note "  (smoke says: $(printf '%s' "$smoke_out" | tail -1))"
printf '%s\n' "$smoke_out" >"$TMP/smoke-broken-config.log"

# ---- E. a gate hole is red --------------------------------------------------
reset_box
export AIRLOCK_TEST_GATE_STRANGER_CODE=200
run_status --json
if [ "$rc" = 1 ]; then ok "E a stranger who is not denied exits 1"
else bad "E a gate hole exited $rc, expected 1"; fi
got="$(q "[c['status'] for c in d['checks'] if c['id']=='gate.stranger'][0]")"
if [ "$got" = fail ]; then ok "E gate.stranger is the failure"
else bad "E gate.stranger is '$got'"; fi

reset_box
export AIRLOCK_TEST_GATE_ANON_CODE=200
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='gate.anonymous'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "E a request with no identity header that is not denied is red"
else bad "E anonymous hole gave rc=$rc gate.anonymous=$got"; fi

reset_box
export AIRLOCK_TEST_GATE_OWNER_CODE=403
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='gate.owner'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "E an owner locked out of their own box is red"
else bad "E owner 403 gave rc=$rc gate.owner=$got"; fi

# ---- F. a dead unit is red --------------------------------------------------
reset_box
export AIRLOCK_TEST_DEAD_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "F a committed unit that is not active is red"
else bad "F dead unit gave rc=$rc units.active=$got"; fi
got="$(q "[c['detail'] for c in d['checks'] if c['id']=='units.active'][0]")"
case "$got" in
  *airlock-devterm-gate.service*) ok "F the failure names the unit that is down" ;;
  *) bad "F the failure does not name the unit: $got" ;;
esac

# ---- F2. systemd unit type and result define health, not is-active alone ----
# These property sets were copied from the reference box on 2026-08-30. A timer-run
# oneshot and a manual action oneshot both settle at inactive/dead after success;
# claude-fleet-usage was also caught at activating/start during a real run.
reset_box
export AIRLOCK_TEST_DEAD_UNITS="airlock-devterm-gate.service"
export AIRLOCK_TEST_ONESHOT_SUCCESS_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 0 ] && [ "$got" = ok ]; then
  ok "F2 inactive/dead oneshot with Result=success and ExecMainStatus=0 is healthy"
else bad "F2 successful completed oneshot gave rc=$rc units.active=$got"; fi

reset_box
export AIRLOCK_TEST_ONESHOT_ACTIVATING_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 0 ] && [ "$got" = ok ]; then
  ok "F2 activating/start oneshot is healthy while its real job is running"
else bad "F2 running oneshot gave rc=$rc units.active=$got"; fi

# Actual negative control: skill-wiring-check.service was failed/failed with
# Result=exit-code and ExecMainStatus=1 even though its timer was active/waiting.
reset_box
export AIRLOCK_TEST_ONESHOT_FAILED_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "F2 a failed oneshot stays red even when oneshot inactivity is otherwise valid"
else bad "F2 failed oneshot gave rc=$rc units.active=$got"; fi

reset_box
export AIRLOCK_TEST_CONTRADICTORY_ACTIVE_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "F2 contradictory active/failed state is never silently healthy"
else bad "F2 active/failed contradiction gave rc=$rc units.active=$got"; fi

reset_box
export AIRLOCK_TEST_BAD_ACTIVATING_UNITS="airlock-devterm-gate.service"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "F2 activating/dead oneshot is not mistaken for a running job"
else bad "F2 activating/dead contradiction gave rc=$rc units.active=$got"; fi

# A scheduled service's timer is a separate committed ledger artifact. Replace
# one service artifact with that timer shape to prove inactive/not-found timers
# are not excused by the successful-oneshot rule.
replace_committed_unit() {
  python3 - "$STATE/app-ledger.json" "$1" "$2" <<'PY'
import json, os, sys
path, old, new = sys.argv[1:]
with open(path) as f:
    store = json.load(f)
record = store["entries"]["devterm"]["committed"]
units = record["artifacts"]["units"]
units[units.index(old)] = new
scopes = record["unit_scopes"]
scopes[os.path.basename(new)] = scopes.pop(os.path.basename(old))
with open(path, "w") as f:
    json.dump(store, f)
PY
}

reset_box
printf '[Unit]\n' >"$UU/airlock-devterm-gate.timer"
replace_committed_unit "$UU/airlock-devterm-gate.service" "$UU/airlock-devterm-gate.timer"
export AIRLOCK_TEST_INACTIVE_TIMER_UNITS="airlock-devterm-gate.timer"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "F2 an inactive committed timer is red"
else bad "F2 inactive timer gave rc=$rc units.active=$got"; fi

reset_box
printf '[Unit]\n' >"$UU/airlock-devterm-gate.timer"
replace_committed_unit "$UU/airlock-devterm-gate.service" "$UU/airlock-devterm-gate.timer"
export AIRLOCK_TEST_NOT_FOUND_UNITS="airlock-devterm-gate.timer"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "F2 a not-found committed timer is red even when systemctl reports Result=success"
else bad "F2 missing timer gave rc=$rc units.active=$got"; fi

reset_box
printf '[Unit]\n' >"$UU/airlock-devterm-gate.timer"
replace_committed_unit "$UU/airlock-devterm-gate.service" "$UU/airlock-devterm-gate.timer"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$rc" = 0 ] && [ "$got" = ok ]; then
  ok "F2 active/waiting timer is healthy with service-only properties omitted"
else bad "F2 active timer without Type/ExecMainStatus gave rc=$rc units.active=$got"; fi

# ---- G. a missing serve mapping and a dead backend are red ------------------
reset_box
export AIRLOCK_TEST_SERVE_PORTS="$HUB_HTTPS $HUB_HTTP"   # devterm's https mapping is gone
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='ingress.serve'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "G a declared serve mapping that is gone is red"
else bad "G missing serve mapping gave rc=$rc ingress.serve=$got"; fi

reset_box
export AIRLOCK_TEST_TS_STATE=Stopped
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='ingress.backend'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "G tailscaled that is not Running is red"
else bad "G stopped tailscale gave rc=$rc ingress.backend=$got"; fi

# ---- H. unchecked is not ok -------------------------------------------------
# The whole point of the third exit status: this box cannot measure its own
# tailnet name, so the entrance was never tested. Nothing failed, and the run
# still must not read as a clean bill of health.
reset_box
unset AIRLOCK_TS_FQDN
export AIRLOCK_TEST_TS_DNSNAME=""
run_status --json
if [ "$rc" = 3 ]; then ok "H a check that could not run exits 3, not 0"
else
  bad "H unmeasurable entrance exited $rc, expected 3"
  note "$(q "[c['id'] + '=' + c['status'] + ' (' + c['detail'][:120] + ')' for c in d['checks'] if c['status'] != 'ok']")"
fi
got="$(q "d['verdict']")"
if [ "$got" = incomplete ]; then ok "H the verdict is 'incomplete', not 'ok'"
else bad "H the verdict is '$got'"; fi
got="$(q "[c['status'] for c in d['checks'] if c['id']=='ingress.entrance'][0]")"
if [ "$got" = unchecked ]; then ok "H ingress.entrance is the unchecked one"
else bad "H ingress.entrance is '$got'"; fi
got="$(q "sum(1 for c in d['checks'] if c['status']=='fail')")"
if [ "$got" = 0 ]; then ok "H exit 3 really does mean nothing failed"
else bad "H exit 3 with $got failure(s) — 3 and 1 have been conflated"; fi
run_status
case "$out" in
  *"not a clean bill of health"*) ok "H the human summary says the run was incomplete" ;;
  *) bad "H the human summary does not distinguish incomplete from ok" ;;
esac

# ---- I. an empty inventory is not a pass ------------------------------------
# The bin/airlock-smoke shape, reproduced with a config that PARSES: the app
# list is legitimately empty, every downstream probe therefore has nothing to
# check, and that must not add up to a healthy box.
reset_box
cat >"$TMP/hub-only.toml" <<TOML
[airlock]
config_version = 2
[site]
name = "Hub Only"
[auth]
provider = "tailscale"
owner = "$OWNER"
[apps.hub]
https_port = $HUB_HTTPS
http_port = $HUB_HTTP
nginx_port = $HUB_NGINX
redirect_port = $HUB_REDIRECT
TOML
export AIRLOCK_CONFIG="$TMP/hub-only.toml"
write_ledger ""
run_status --json
if [ "$rc" != 0 ]; then ok "I a box with zero apps does not exit 0"
else bad "I zero apps exited 0 — the false-success shape is back"; fi
got="$(q "[c['status'] for c in d['checks'] if c['id']=='apps.enabled'][0]")"
if [ "$got" = fail ]; then ok "I apps.enabled reports the empty inventory as a failure"
else bad "I apps.enabled is '$got' on an empty inventory"; fi
got="$(q "[c['status'] for c in d['checks'] if c['id']=='units.active'][0]")"
if [ "$got" = unchecked ]; then ok "I an empty ledger leaves units.active unchecked, never ok"
else bad "I units.active is '$got' with nothing committed"; fi
smoke_out="$(cd "$ROOT" && bash "$SMOKE" 2>&1)"; smoke_rc=$?
note "measured contrast on this same input — bin/airlock-smoke exits $smoke_rc, airlock-status exits $rc"
note "  (smoke says: $(printf '%s' "$smoke_out" | tail -1))"

# ---- J. config and install disagreeing is red -------------------------------
reset_box
write_ledger ""            # devterm is enabled but nothing is committed
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='install.drift'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "J an enabled app that was never installed is red"
else bad "J install drift gave rc=$rc install.drift=$got"; fi
got="$(q "[c['detail'] for c in d['checks'] if c['id']=='install.drift'][0]")"
case "$got" in
  *devterm*) ok "J the drift names the app that is missing" ;;
  *) bad "J the drift does not name the app: $got" ;;
esac

reset_box
rm -f "$STATE/app-ledger.json"
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='install.ledger'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "J a box with no install record at all is red"
else bad "J missing ledger gave rc=$rc install.ledger=$got"; fi

# ---- L. the rest of the machine contract ------------------------------------
# The roster and the key set were pinned in B. These are the parts a consumer
# would also break on: what the values MEAN.
reset_box
run_status --json
got="$(q "d['tool']")"
if [ "$got" = "airlock-status" ]; then ok "L the document names its producer"
else bad "L tool is '$got'"; fi

got="$(q "all(isinstance(c[k], str) for c in d['checks'] for k in ('id','section','status','title','detail','next')) and isinstance(d['schema_version'], int) and isinstance(d['exit_code'], int) and all(isinstance(v, int) for v in d['counts'].values()) and all(isinstance(d[k], str) for k in ('tool','generated_at','host','root','verdict'))")"
if [ "$got" = True ]; then ok "L every value has the pinned type"
else bad "L a value changed type ($got)"; fi

got="$(q "' '.join(c['section'] for c in d['checks'])")"
want='config config install install install ingress ingress ingress gate gate gate units apps apps'
if [ "$got" = "$want" ]; then ok "L each check keeps its section"
else bad "L sections drifted"; note "want: $want"; note "got : $got"; fi

got="$(q "all(c['title'] for c in d['checks']) and len({c['title'] for c in d['checks']}) == len(d['checks'])")"
if [ "$got" = True ]; then ok "L every check has its own non-empty title"
else bad "L titles are missing or duplicated"; fi

got="$(q "__import__('re').match(r'^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$', d['generated_at']) is not None")"
if [ "$got" = True ]; then ok "L generated_at is an ISO-8601 UTC instant"
else bad "L generated_at is not the pinned shape"; fi

# verdict <-> exit_code, all three, and against the PROCESS exit status.
check_verdict_pair() {   # check_verdict_pair <expected verdict> <expected rc> <label>
  local want_v="$1" want_rc="$2" label="$3" v e
  v="$(q "d['verdict']")"; e="$(q "d['exit_code']")"
  if [ "$v" = "$want_v" ] && [ "$e" = "$want_rc" ] && [ "$rc" = "$want_rc" ]; then
    ok "L $label: verdict=$want_v, document exit_code=$want_rc, process rc=$want_rc"
  else
    bad "L $label: verdict=$v exit_code=$e process rc=$rc (wanted $want_v/$want_rc)"
  fi
}
check_verdict_pair ok 0 "healthy"
reset_box; unset AIRLOCK_TS_FQDN; export AIRLOCK_TEST_TS_DNSNAME=""
run_status --json; check_verdict_pair incomplete 3 "incomplete"
reset_box; export AIRLOCK_TEST_GATE_STRANGER_CODE=200
run_status --json; check_verdict_pair fail 1 "failed"

# ---- M. exit 2 belongs to the tool, not to the box --------------------------
# A broken box must never produce 2, and a crash or a misuse must never produce
# 1 — otherwise "this tool is broken" and "your box is broken" are the same
# answer.
reset_box
run_status --not-an-option
if [ "$rc" = 2 ]; then ok "M a usage error exits 2, not 1"
else bad "M a usage error exited $rc"; fi

# ---- N. a config that validates but will not resolve ------------------------
reset_box
export AIRLOCK_TEST_CONFIG_FAIL=json
run_status --json
got="$(q "[c['status'] for c in d['checks'] if c['id']=='config.validate'][0]")"
if [ "$rc" = 1 ] && [ "$got" = fail ]; then
  ok "N validate passing does not make config.validate ok on its own"
else bad "N validate-then-json-fail gave rc=$rc config.validate=$got"; fi

# ---- O. a dependency that stops answering is unchecked, never ok ------------
# Both of these compare against a list airlock-config produces. If producing it
# fails and the tool compares against what is left, the survivors read as
# healthy — a subset passing for the whole is the same defect as an empty set
# passing for a pass.
reset_box
export AIRLOCK_TEST_CONFIG_FAIL=package-info
run_status --json
if [ "$rc" = 3 ]; then ok "O a mapping producer that failed exits 3, not 0"
else bad "O failed package-info exited $rc, expected 3"; fi
got="$(q "' '.join(c['status'] for c in d['checks'] if c['id'] in ('ingress.serve','apps.backends'))")"
if [ "$got" = "unchecked unchecked" ]; then
  ok "O ingress.serve and apps.backends refuse to judge an incomplete list"
else bad "O got '$got', expected 'unchecked unchecked'"; fi

# ---- K. a loopback target with nothing on it is red -------------------------
# Last, because it takes a held port away for good. Without this case, an
# airlock-status whose port probe always answered "listening" would pass every
# other case in this file.
reset_box
: >"$TMP/drop-$DT_GATE"
for _ in $(seq 1 100); do
  [ -e "$TMP/dropped-$DT_GATE" ] && break
  sleep 0.1
done
if [ ! -e "$TMP/dropped-$DT_GATE" ]; then
  bad "K the fixture could not take port $DT_GATE down"
else
  run_status --json
  got="$(q "[c['status'] for c in d['checks'] if c['id']=='apps.backends'][0]")"
  if [ "$rc" = 1 ] && [ "$got" = fail ]; then ok "K a loopback target with nothing listening is red"
  else bad "K dead backend gave rc=$rc apps.backends=$got"; fi
  got="$(q "[c['detail'] for c in d['checks'] if c['id']=='apps.backends'][0]")"
  case "$got" in
    *"$DT_GATE"*) ok "K the failure names the port that is dead" ;;
    *) bad "K the failure does not name port $DT_GATE: $got" ;;
  esac
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
