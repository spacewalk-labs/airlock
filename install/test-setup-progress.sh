#!/usr/bin/env bash
# Tests docker/orbstack-machine-setup.sh — specifically that a GUI can drive it
# (AIRLOCK_PROGRESS=json) and that doing so changed nothing for the person who runs it
# in a terminal.
#
# Why this exists: the macOS launcher is a graphical front end to this script
# (docs/tasks/active/macos-app-launcher.md), and the task doc's own promise is that
# `bash docker/orbstack-machine-setup.sh` keeps working untouched. That promise had no
# enforcement — before this file the script's only coverage was four lines of
# install/test-integration.sh, which stop at the architecture banner because their `orb`
# stub deliberately fails.
#
# How it runs a Mac-only script on Linux: every command the script sends to the machine
# goes through `orb`, so a stub for that one name drives the whole thing offline. The
# stub RECORDS, and that recording is the load-bearing oracle — a transcript shows what
# the operator reads, but the call log shows what the machine was actually asked to do,
# which is the thing that must not move.
#
# Offline and inert: no OrbStack, no VM, no network, no machine state anywhere.
set -uo pipefail
# install/test-render-parity.sh gates that every suite whose text mentions an app
# installer pins the RAM the paseo installer takes its memory share from. The gate is a
# deliberately coarse text scan — it does not reason about WHICH app a path resolves to
# — so suites that never install paseo carry the pin anyway and it sits inert. Cheaper
# than a gate that tries to be clever about which mention counts.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# Setup is checked, not assumed. This file runs without `set -e` (repo convention, so
# one failing check does not hide the rest), which means an unwritable TMPDIR would
# otherwise sail past every `cp` and report a partial pass — a misleading "2 of 14
# passed" instead of "this could not run at all". Observed exactly that on a sandbox
# with a read-only temp filesystem.
setup_or_die() { "$@" || { printf 'FAIL harness setup failed: %s\n' "$*" >&2; exit 1; }; }
TMP="$(mktemp -d)" || { echo "FAIL cannot create a temp directory — nothing was tested" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
GOLD="$HERE/golden/setup-progress"
setup_or_die mkdir -p "$TMP/bin" "$TMP/repo/docker" "$TMP/repo/install"
setup_or_die cp "$HERE/setup-orb-stub.sh"   "$TMP/bin/orb"
setup_or_die cp "$HERE/setup-uname-stub.sh" "$TMP/bin/uname"
# The stubs are found on PATH and executed, so they need the bit here — they do not
# carry it in the tree, because the cutline forbids creating a file under install/
# executable (docs/airlock/sot-cutline.yaml: install/ allows 100755->100755 only).
setup_or_die chmod +x "$TMP/bin/orb" "$TMP/bin/uname"
setup_or_die cp "$ROOT/docker/orbstack-machine-setup.sh" "$TMP/repo/docker/"
setup_or_die touch "$TMP/repo/install/airlock-install.sh" "$TMP/repo/airlock.toml"

# run <out> <err> <orblog> [VAR=VAL...] -> sets RC
run() {
  local out="$1" err="$2" orblog="$3"; shift 3
  : > "$orblog"
  env PATH="$TMP/bin:$PATH" ORB_LOG="$orblog" "$@" \
      bash "$TMP/repo/docker/orbstack-machine-setup.sh" > "$out" 2> "$err"
  RC=$?
}
# Paths differ per run; the transcript must not.
# The path is escaped before it becomes a sed pattern: a TMPDIR containing `|`, `&`
# or `\` would otherwise corrupt the substitution silently on someone else's runner,
# and the failure would look like a golden mismatch rather than a broken test.
TMP_RE="$(printf '%s' "$TMP" | sed -e 's/[|&\\.^$*[]/\\&/g')"
norm() { sed -e "s|$TMP_RE|TMP|g" "$1"; }

# 1. CONTROL. Every assertion below is worthless if the stub is not the thing being
#    called — a PATH mishap would either use a real `orb` (on a Mac) or fail at
#    `command -v orb`, and a green run would mean nothing either way.
run "$TMP/h.out" "$TMP/h.err" "$TMP/h.orb" env
if [ "$RC" -ne 0 ]; then
  bad "control: the script did not complete under the stub (rc=$RC): $(head -1 "$TMP/h.err")"
elif [ ! -s "$TMP/h.orb" ]; then
  bad "control: nothing was recorded — the stub was never called, so nothing here is tested"
else
  ok "control: the run completed entirely through the stub ($(wc -l < "$TMP/h.orb") calls recorded)"
fi

# 2. The human path is byte-identical to its golden. This is the task doc's promise
#    ("the existing path still works untouched") turned into something CI can fail.
#    Regenerate deliberately with AIRLOCK_REGEN=1 so the diff shows up in a commit.
if [ "${AIRLOCK_REGEN:-0}" = 1 ]; then
  norm "$TMP/h.out" > "$GOLD/human.txt"
  norm "$TMP/h.orb" > "$GOLD/orb-calls.txt"
  echo "regenerated $GOLD/{human.txt,orb-calls.txt}"
fi
if diff -u "$GOLD/human.txt" <(norm "$TMP/h.out") > "$TMP/hd" 2>&1; then
  ok "the human-readable transcript is unchanged"
else
  bad "the default transcript changed: $(sed -n '4,6p' "$TMP/hd" | tr '\n' ' ')"
fi
# What is asserted is what actually holds: none of THIS SCRIPT'S output goes to stderr in
# the default mode, and no event does. Not "stderr is empty" — under the stub it happens
# to be, because the stubbed installer prints nothing, but a real run puts 4.7 kB of the
# installer's own progress there and that is entirely proper. Measured on hardware
# 2026-08-21: 4712 bytes of `[airlock] ...` from install/airlock-install.sh, zero
# `[airlock-mac]` lines, zero events.
if grep -q 'airlock-mac' "$TMP/h.err"; then
  bad "the script's own log reached stderr in the default mode: $(grep -m1 airlock-mac "$TMP/h.err")"
elif grep -q '"event"' "$TMP/h.err"; then
  bad "an event was emitted in the default mode"
else
  ok "in the default mode neither the script's own log nor any event goes to stderr"
fi

# 3. THE central claim: turning progress reporting on does not change what the script
#    does. Compare the recorded call sequences, not the output — the transcript could
#    match while an `orb` argument quietly moved.
run "$TMP/j.out" "$TMP/j.err" "$TMP/j.orb" env AIRLOCK_PROGRESS=json
if [ "$RC" -ne 0 ]; then
  bad "json mode did not complete (rc=$RC): $(tail -1 "$TMP/j.err")"
elif diff -q "$TMP/h.orb" "$TMP/j.orb" >/dev/null; then
  ok "json mode sends the machine exactly the same commands, in the same order"
else
  bad "json mode changed what is run: $(diff "$TMP/h.orb" "$TMP/j.orb" | head -2 | tr '\n' ' ')"
fi
if diff -q "$GOLD/orb-calls.txt" <(norm "$TMP/h.orb") >/dev/null; then
  ok "the recorded call sequence matches its golden"
else
  bad "the commands sent to the machine changed: $(diff "$GOLD/orb-calls.txt" <(norm "$TMP/h.orb") | head -2 | tr '\n' ' ')"
fi

# 4. The stream split IS the contract: events on stderr, everything the underlying
#    commands print on stdout. A caller reading two pipes then never has to guess
#    whether a line is an event or installer output.
if python3 - "$TMP/j.err" <<'PYJ'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
if not lines:
    print("no events emitted at all", file=sys.stderr); raise SystemExit(1)
for n, line in enumerate(lines, 1):
    try:
        obj = json.loads(line)
    except ValueError as e:
        print(f"stderr line {n} is not JSON: {e}: {line[:70]}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(obj, dict) or "event" not in obj:
        print(f"stderr line {n} is JSON but not an event: {line[:70]}", file=sys.stderr)
        raise SystemExit(1)
PYJ
then
  ok "every stderr line in json mode is a JSON event object"
else
  bad "json mode emitted something on stderr that a caller cannot parse"
fi
if grep -q '"event"' "$TMP/j.out"; then
  bad "an event leaked onto stdout, where the underlying commands' output lives"
else
  ok "no event reaches stdout — the two streams stay separate"
fi

# 5. Steps come in pairs. "started" and "finished" are different facts, and a progress
#    bar built on start-only events tells the operator a step is done when it is not.
if python3 - "$TMP/j.err" <<'PYS'
import json, sys
started, done = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    o = json.loads(line)
    if o.get("event") == "step":
        status = o.get("status")
        if status == "start":
            started.append(o["step"])
        elif status == "ok":
            done.append(o["step"])
        else:
            print(f"step event with unknown status {status!r}", file=sys.stderr)
            raise SystemExit(1)
if not started:
    print("no step events at all", file=sys.stderr); raise SystemExit(1)
if started != done:
    print(f"start {started} != ok {done}", file=sys.stderr); raise SystemExit(1)
PYS
then
  ok "every step that starts also reports finishing, in the same order"
else
  bad "step start/ok events do not pair up"
fi

# 6. The login URL. It exists only in tailscale's own stdout, and a GUI cannot ask the
#    operator to approve a link it never saw. It must ALSO still reach stdout: the
#    person watching a terminal is the case that already worked.
if grep -q '"event":"login-url"' "$TMP/j.err" \
   && grep -q 'https://login.tailscale.com/a/abc123def456' "$TMP/j.err"; then
  ok "the Tailscale login URL is surfaced as an event"
else
  bad "no login-url event — a GUI has no link to show"
fi
for mode in h j; do
  if grep -q 'https://login.tailscale.com/a/abc123def456' "$TMP/$mode.out"; then
    ok "the login URL still reaches stdout ($([ $mode = h ] && echo human || echo json) mode)"
  else
    bad "the login URL vanished from stdout in $([ $mode = h ] && echo human || echo json) mode"
  fi
done

# 7. Failure has to be legible on both sides. A GUI that cannot tell "failed" from
#    "still going" shows a spinner forever.
run "$TMP/f.out" "$TMP/f.err" "$TMP/f.orb" env AIRLOCK_PROGRESS=json STUB_TS_FAIL=1
if [ "$RC" -eq 0 ]; then
  bad "a failing 'tailscale up' exited 0 in json mode"
elif grep -q '"event":"fatal","message":"tailscale up failed"' "$TMP/f.err"; then
  # The message, not just the presence of a fatal: a die() somewhere else entirely
  # would satisfy "nonzero exit plus some fatal event" while the piped branch's own
  # `|| die` stayed broken.
  ok "a failure inside the piped tailscale step still reaches die() and emits a fatal event"
else
  bad "json mode failed (rc=$RC) without emitting a fatal event: $(tail -1 "$TMP/f.err")"
fi
run "$TMP/fh.out" "$TMP/fh.err" "$TMP/fh.orb" env STUB_TS_FAIL=1
if [ "$RC" -ne 0 ] && grep -q 'FATAL' "$TMP/fh.err"; then
  ok "the same failure still says FATAL in the default mode"
else
  bad "the default mode's failure reporting changed (rc=$RC)"
fi

# 8. An unknown mode is a typo, not a request for the default. Falling back silently is
#    how a caller asking for json quietly gets prose and parses nothing.
run "$TMP/x.out" "$TMP/x.err" "$TMP/x.orb" env AIRLOCK_PROGRESS=xml
if [ "$RC" -eq 2 ] && grep -q 'must be' "$TMP/x.err"; then
  ok "an unrecognised AIRLOCK_PROGRESS is refused with exit 2"
elif [ "$RC" -eq 0 ]; then
  bad "an unrecognised AIRLOCK_PROGRESS silently fell back to the default"
else
  bad "an unrecognised AIRLOCK_PROGRESS exited $RC"
fi

# 9. A fatal message must survive into ONE parseable event. Section 4's
#    "airlock.toml not found" spans three lines, and an escaper that only handled the
#    quote and the backslash split that event across three stderr lines — leaving the
#    caller's parser broken at the exact moment it most needs to report the failure.
#    The stub can fail either of section 4's two checks; both are exercised because
#    both messages are multi-line or carry paths.
for case in STUB_NO_CONFIG STUB_NO_REPO; do
  run "$TMP/d.out" "$TMP/d.err" "$TMP/d.orb" env AIRLOCK_PROGRESS=json "$case=1"
  label="$([ "$case" = STUB_NO_CONFIG ] && echo "missing airlock.toml" || echo "repo not visible")"
  if [ "$RC" -eq 0 ]; then
    bad "$label exited 0"
  elif ! python3 - "$TMP/d.err" <<'PYD'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
for n, line in enumerate(lines, 1):
    try:
        json.loads(line)
    except ValueError as e:
        print(f"line {n} is not JSON ({e}): {line[:60]!r}", file=sys.stderr)
        raise SystemExit(1)
if not any(json.loads(l).get("event") == "fatal" for l in lines):
    print("no fatal event", file=sys.stderr); raise SystemExit(1)
PYD
  then
    bad "$label produced an unparseable or missing fatal event"
  else
    ok "$label fails as one parseable fatal event, multi-line message and all"
  fi
done

# 10. The same two failures still read as failures in the default mode. The json path is
#     additive; it must not have become the only path that reports properly.
for case in STUB_NO_CONFIG STUB_NO_REPO; do
  run "$TMP/dh.out" "$TMP/dh.err" "$TMP/dh.orb" env "$case=1"
  if [ "$RC" -ne 0 ] && grep -q 'FATAL' "$TMP/dh.err"; then
    ok "$case still prints FATAL in the default mode"
  else
    bad "$case: default-mode reporting changed (rc=$RC)"
  fi
done

# 11. The escaper itself, against values no message in this script happens to contain
#     today. The die paths above prove the newline case that actually broke; this proves
#     the rest of the class, so the next message someone adds does not reopen it.
#     Sourced rather than reimplemented — a copy of the escaper here would drift.
esc_out="$(
  # shellcheck disable=SC2034  # PROGRESS is read by the `event` defined just below
  PROGRESS=json
  eval "$(sed -n '/^_json()/,/^step_ok()/p' "$ROOT/docker/orbstack-machine-setup.sh")"
  for v in 'a"b' 'a\b' "$(printf 'a\nb')" "$(printf 'a\tb')" "$(printf 'a\001b')" '한글 😀'; do
    event probe "value=$v"
  done 2>&1
)"
if printf '%s' "$esc_out" | python3 -c '
import json, sys
n = 0
for line in sys.stdin:
    if not line.strip():
        continue
    n += 1
    json.loads(line)          # raises -> nonzero exit
sys.exit(0 if n == 6 else 1)  # all six must have been emitted, not swallowed
'; then
  ok "the JSON escaper survives quotes, backslashes, newlines, tabs, control chars and non-BMP text"
else
  bad "the JSON escaper produced something unparseable: $(printf '%s' "$esc_out" | head -1 | cut -c1-70)"
fi

# 12. The other half of the machine `if`. Every run above took the "already exists"
#     path; a first-run launcher takes the CREATE path, and until now no test had.
run "$TMP/c.out" "$TMP/c.err" "$TMP/c.orb" env AIRLOCK_PROGRESS=json STUB_NO_MACHINE=1
if [ "$RC" -ne 0 ]; then
  bad "the create-a-machine path failed (rc=$RC): $(tail -1 "$TMP/c.err")"
elif ! grep -q "^orb create" "$TMP/c.orb"; then
  bad "STUB_NO_MACHINE did not reach 'orb create' — the branch is still untested"
elif grep -q '"step":"machine","status":"ok"' "$TMP/c.err"; then
  ok "creating the machine takes the other branch and still reports the step"
else
  bad "the create path ran but reported no machine step"
fi

# 13. The TS_AUTHKEY branch — the non-interactive login a launcher would use with a
#     pre-minted key, and the one place the login-url event legitimately does not fire.
run "$TMP/k.out" "$TMP/k.err" "$TMP/k.orb" env AIRLOCK_PROGRESS=json TS_AUTHKEY=tskey-fake
if [ "$RC" -ne 0 ]; then
  bad "the TS_AUTHKEY path failed (rc=$RC): $(tail -1 "$TMP/k.err")"
elif grep -q -- "--authkey" "$TMP/k.orb"; then
  ok "TS_AUTHKEY takes the non-interactive branch and passes the key through"
else
  bad "TS_AUTHKEY did not reach the authkey branch"
fi

# 14. A FQDN that will not parse is tolerated by design (`|| true`), so the run must
#     still finish — but the caller must not be handed a URL built from an empty host.
run "$TMP/q.out" "$TMP/q.err" "$TMP/q.orb" env AIRLOCK_PROGRESS=json STUB_BAD_FQDN=1
if [ "$RC" -ne 0 ]; then
  bad "an unparseable FQDN aborted the run (rc=$RC) — the script tolerates it by design"
elif grep -q '"url":"https:///"' "$TMP/q.err"; then
  bad "an unparseable FQDN produced the URL 'https:///' — a caller would open nothing"
elif ! grep -q '"event":"finished"' "$TMP/q.err"; then
  bad "an unparseable FQDN produced no finished event at all"
elif grep -q '"event":"finished"[^}]*"url"' "$TMP/q.err"; then
  bad "an unparseable FQDN still emitted a url key — the caller cannot tell it is unusable"
else
  ok "an unparseable FQDN finishes without handing the caller a URL to nowhere"
fi

# 15. The URL as the last thing printed, with no trailing newline. A prompt legitimately
#     looks like that, and a plain `while read` returns nonzero on the final partial line
#     and discards it — dropping the one line this branch was added to find.
run "$TMP/n.out" "$TMP/n.err" "$TMP/n.orb" env AIRLOCK_PROGRESS=json STUB_TS_NO_NEWLINE=1
if [ "$RC" -ne 0 ]; then
  bad "an unterminated final line aborted the run (rc=$RC)"
elif grep -q '"event":"login-url"' "$TMP/n.err"; then
  ok "a login URL with no trailing newline is still surfaced"
else
  bad "a login URL with no trailing newline was dropped by the read loop"
fi

# 16. Finder does not inherit an interactive shell's PATH. The launcher therefore
#     resolves this account's OrbStack command and hands the exact absolute path to the
#     setup script. Put that command somewhere outside PATH to prove the script uses the
#     contract rather than accidentally finding the ordinary stub.
setup_or_die mkdir -p "$TMP/account-orb"
setup_or_die cp "$HERE/setup-orb-stub.sh" "$TMP/account-orb/orb"
setup_or_die chmod +x "$TMP/account-orb/orb"
run "$TMP/e.out" "$TMP/e.err" "$TMP/e.orb" env AIRLOCK_PROGRESS=json \
  AIRLOCK_ORB_BIN="$TMP/account-orb/orb" STUB_RECORD_EXECUTABLE=1
if [ "$RC" -ne 0 ]; then
  bad "the explicit per-account orb path failed (rc=$RC): $(tail -1 "$TMP/e.err")"
elif ! grep -Fq "orb executable=$TMP/account-orb/orb " "$TMP/e.orb"; then
  bad "setup did not use the supplied orb executable: $(head -1 "$TMP/e.orb")"
else
  ok "the exact per-account orb path drives the whole setup"
fi

# 17. The override is an executable path, not shell text or a second PATH. Refuse a
#     relative value before any machine command runs and report one parseable failure
#     to the GUI.
run "$TMP/r.out" "$TMP/r.err" "$TMP/r.orb" env AIRLOCK_PROGRESS=json \
  AIRLOCK_ORB_BIN="relative/orb"
if [ "$RC" -eq 0 ]; then
  bad "a relative AIRLOCK_ORB_BIN was accepted"
elif [ -s "$TMP/r.orb" ]; then
  bad "a relative AIRLOCK_ORB_BIN reached the machine command"
elif python3 - "$TMP/r.err" <<'PYR'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
raise SystemExit(0 if len(events) == 3 and events[-1].get("event") == "fatal"
                 and "absolute path" in events[-1].get("message", "") else 1)
PYR
then
  ok "a relative orb override is refused before mutation with a parseable failure"
else
  bad "a relative orb override did not produce the expected fatal event"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
