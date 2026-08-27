#!/usr/bin/env bash
# install/lib.sh contracts that only a live box would otherwise expose.
#
# A sourced library must not edit its caller's shell options.
#
# install/lib.sh used to open with `set -euo pipefail`. Every apps/*/smoke.sh opens
# with `set -uo pipefail` — errexit off deliberately, because a smoke collects status
# codes and prints one summary line, and the codes it most needs to print are the
# failing ones. Sourcing the library turned errexit back on, so the first probe that
# could not connect killed the script before it printed a single character. Measured
# on a live box on 2026-08-07: three apps failed their smoke and the whole diagnostic
# was the orchestrator's "smoke FAILED: <app>".
#
# CI never saw it because CI never runs a live smoke. This suite is the cheap
# stand-in: it asserts the property directly rather than the symptom.
set -uo pipefail
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 11/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok   shell-options: $1"; pass=$((pass+1)); }
bad() { echo "FAIL shell-options: $1"; fail=$((fail+1)); }

# ---- 1. the library leaves the caller's options alone ----
# Run a probe with errexit OFF, source the library, and see whether it came back.
probe="$(mktemp)"
cat > "$probe" <<'PROBE'
set -uo pipefail
. "$1/install/lib.sh"
case "$-" in *e*) echo "errexit-on" ;; *) echo "errexit-off" ;; esac
PROBE
got="$(bash "$probe" "$ROOT" 2>/dev/null | tail -1)"
if [ "$got" = "errexit-off" ]; then
  ok "sourcing install/lib.sh does not turn errexit on behind the caller's back"
else
  bad "install/lib.sh re-enabled errexit in a caller that had it off (got '$got')"
fi

# A caller that DID ask for errexit must still have it — the fix is "do not change
# the caller", not "turn it off for everyone".
cat > "$probe" <<'PROBE'
set -euo pipefail
. "$1/install/lib.sh"
case "$-" in *e*) echo "errexit-on" ;; *) echo "errexit-off" ;; esac
PROBE
got="$(bash "$probe" "$ROOT" 2>/dev/null | tail -1)"
[ "$got" = "errexit-on" ] \
  && ok "a caller that set errexit itself still has it after sourcing" \
  || bad "sourcing install/lib.sh cleared the caller's own errexit (got '$got')"

# ---- 2. every consumer states its own options ----
# Removing the `set` from a library is only safe while nobody was relying on
# inheriting it. That is a property of the tree, so check the tree.
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  decl="$(grep -m1 -E '^set -' "$f" || true)"
  case "$rel" in
    */smoke.sh)
      # A smoke MUST NOT use errexit: its contract is to probe every surface and
      # print one line carrying all of the codes, and the codes worth printing are
      # the failing ones. This is the rule the library was breaking.
      case "$decl" in
        "set -uo pipefail") ok "$rel keeps errexit off on purpose" ;;
        *e*) bad "$rel sets errexit ($decl) — a smoke collects status codes, it cannot die on the first probe" ;;
        "")  bad "$rel sets no shell options and used to inherit them from the library" ;;
        *)   bad "$rel has an unexpected options line: $decl" ;;
      esac ;;
    install/test-*.sh|gate/test-*.sh)
      # A suite may reasonably choose either — some collect, some stop at the first
      # golden mismatch. What it may not do is leave the choice to whatever it
      # happens to source. Require the line, not a particular value.
      case "$decl" in
        set\ -*) ok "$rel states its own options ($decl)" ;;
        *) bad "$rel sets no shell options and used to inherit them from the library" ;;
      esac ;;
    *)
      case "$decl" in
        *e*) ok "$rel sets errexit itself" ;;
        "")  bad "$rel sets no shell options and used to inherit them from the library" ;;
        *)   bad "$rel does not set errexit ($decl) — it used to inherit it from the library" ;;
      esac ;;
  esac
# Match a real source line, not a mention: apps/fileview/render.sh names the
# library in a comment and is not a consumer, which this scan happily reported as
# a violation until the pattern was anchored.
done < <(grep -rlE '^[[:space:]]*(\.|source)[[:space:]].*install/lib\.sh' --include='*.sh' \
           "$ROOT/apps" "$ROOT/install" "$ROOT/gate" 2>/dev/null \
         | grep -v '/install/lib\.sh$' | sort)

# bin/ scripts carry no extension; check the shell ones that source the library.
for b in "$ROOT"/bin/*; do
  [ -f "$b" ] || continue
  head -1 "$b" | grep -q 'bash' || continue
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*install/lib\.sh' "$b" || continue
  rel="${b#"$ROOT"/}"
  decl="$(grep -m1 -E '^set -' "$b" || true)"
  case "$rel:$decl" in
    bin/airlock-smoke:"set -uo pipefail") ok "$rel keeps errexit off on purpose" ;;
    *:*e*) ok "$rel sets errexit itself" ;;
    *:"")  bad "$rel sets no shell options and used to inherit them from the library" ;;
    *)     bad "$rel does not set errexit ($decl)" ;;
  esac
done

# ---- 3. airlock_quiet keeps the output of a command that failed ----
# The other half of the same defect: `>/dev/null 2>&1 || die` throws away the only
# run worth reading. These two cases are what that fix has to satisfy.
cat > "$probe" <<'PROBE'
set -uo pipefail
. "$1/install/lib.sh"
airlock_quiet sh -c 'echo I-worked-loudly; exit 0'
PROBE
quiet_out="$(bash "$probe" "$ROOT" 2>&1)"
[ -z "$quiet_out" ] \
  && ok "airlock_quiet says nothing when the command succeeds" \
  || bad "airlock_quiet leaked output on success: $quiet_out"

# The marker is assembled INSIDE the command from $SUFFIX, and the exit code comes
# from $RC, so neither can appear in the argv that the header echoes back. The first
# version of this case used literals that the command line also contained, and it
# passed with `tail` deleted and again with the exit code dropped — the header alone
# satisfied both assertions. Mutating the helper is the only reason that was caught,
# and the only reason it is written this way.
cat > "$probe" <<'PROBE'
set -uo pipefail
. "$1/install/lib.sh"
airlock_quiet sh -c 'printf "cause-of-death-%s\n" "$SUFFIX" >&2; exit "$RC"'
PROBE
loud_out="$(SUFFIX=41d7 RC=42 bash "$probe" "$ROOT" 2>&1)"
case "$loud_out" in
  *cause-of-death-41d7*)
    case "$loud_out" in
      *"exit 42"*) ok "airlock_quiet prints the failing command's output and its exit code" ;;
      *) bad "airlock_quiet printed the output but not the exit code" ;;
    esac ;;
  *) bad "airlock_quiet lost the failure output (got: $loud_out)" ;;
esac

# And the call sites actually use it — a helper nothing calls fixes nothing.
# fileview dropped off this list when markserv (its only npm dependency) was
# deleted: it runs no npm at all now, so requiring airlock_quiet of it would be
# asserting a call that has nothing to wrap.
for f in apps/paseo/install.sh; do
  if grep -q 'airlock_quiet' "$ROOT/$f" && ! grep -qE 'npm (install|i) .*>/dev/null' "$ROOT/$f"; then
    ok "$f runs npm through airlock_quiet"
  else
    bad "$f still discards npm output"
  fi
done

# ---- 4. airlock_cmd_dirs finds the directory a shebang will actually search ----
# The snap shape, built as a fixture: bin/node is a symlink to a wrapper in another
# directory, exactly like /snap/bin/node -> /usr/bin/snap. `readlink -f` alone
# answers "the wrapper's directory", which is the one place `node` is NOT, and that
# is how two units ended up crash-looping on `env: node: No such file or directory`
# after an install that reported success.
fix="$(mktemp -d)"; trap 'rm -f "$probe"; rm -rf "$fix"' EXIT
mkdir -p "$fix/bin" "$fix/wrapper"
printf '#!/bin/sh\nexit 0\n' > "$fix/wrapper/thewrapper"; chmod +x "$fix/wrapper/thewrapper"
ln -s "$fix/wrapper/thewrapper" "$fix/bin/faux-node"

cat > "$probe" <<'PROBE'
set -uo pipefail
. "$1/install/lib.sh"
PATH="$2/bin:$PATH" airlock_cmd_dirs faux-node
PROBE
dirs="$(bash "$probe" "$ROOT" "$fix" 2>&1)"
first="$(printf '%s\n' "$dirs" | head -1)"
[ "$first" = "$fix/bin" ] \
  && ok "airlock_cmd_dirs puts the directory the command was FOUND in first" \
  || bad "airlock_cmd_dirs did not return the found directory first (got: $dirs)"
printf '%s\n' "$dirs" | grep -qx "$fix/wrapper" \
  && ok "airlock_cmd_dirs also returns the resolved directory" \
  || bad "airlock_cmd_dirs dropped the resolved directory (got: $dirs)"

# A plain (non-symlinked) command must not be reported twice.
printf '#!/bin/sh\nexit 0\n' > "$fix/bin/faux-plain"; chmod +x "$fix/bin/faux-plain"
cat > "$probe" <<'PROBE'
set -uo pipefail
. "$1/install/lib.sh"
PATH="$2/bin:$PATH" airlock_cmd_dirs faux-plain
PROBE
n="$(bash "$probe" "$ROOT" "$fix" 2>&1 | grep -c .)"
[ "$n" = 1 ] \
  && ok "airlock_cmd_dirs does not duplicate a directory when nothing is symlinked" \
  || bad "airlock_cmd_dirs returned $n directories for an unlinked command"

# A command that is not installed is not an error — the unit PATH just gets nothing.
cat > "$probe" <<'PROBE'
set -euo pipefail
. "$1/install/lib.sh"
out="$(airlock_cmd_dirs definitely-not-installed-anywhere)"
[ -z "$out" ] && echo empty-and-ok
PROBE
[ "$(bash "$probe" "$ROOT" 2>&1)" = "empty-and-ok" ] \
  && ok "airlock_cmd_dirs is silent and non-fatal for a missing command" \
  || bad "airlock_cmd_dirs failed on a missing command (it runs under set -e)"

# The call sites use it — the derivation is worthless if the units do not get it.
grep -q 'airlock_cmd_dirs node' "$ROOT/apps/paseo/install.sh" \
  && ok "apps/paseo/install.sh derives its unit PATH from airlock_cmd_dirs" \
  || bad "apps/paseo/install.sh no longer derives node's directory"
# fileview used to have the same requirement (markserv was `#!/usr/bin/env node`).
# markserv is gone and fileview's only unit runs a static Go binary by absolute
# path, so there is no node directory to derive — assert the requirement is really
# absent rather than leaving a check that would pass by accident.
grep -q 'Environment=PATH=' "$ROOT/apps/fileview/render.sh" \
  && bad "apps/fileview/render.sh grew a unit PATH again — derive it, do not hardcode" \
  || ok "fileview's unit needs no PATH (its ExecStart is an absolute static binary)"

# ---- 5. no `big-producer | grep -q` under pipefail ----
# `producer | grep -q needle` looks like a membership test and is a race whenever the
# producer writes more than the 64 KB pipe buffer: grep -q exits at the match, the
# producer takes SIGPIPE, and `set -o pipefail` reports the pipeline as FAILED — so
# the test says "absent" exactly when the thing is present, intermittently, by output
# size. apps/fileview/smoke.sh:39 hit it on an HTTP body and wrote it down; orca then
# hit it on `ldconfig -p` and spent two full installs claiming "libgtk-3 install
# failed" on a box where libgtk-3 was installed.
#
# Producers listed here are the ones known to exceed a pipe buffer. Small, bounded
# producers (`--version`, `airlock_config apps`, `ss -ltn`) are left alone
# deliberately — banning the shape outright would be noise, and noise is how the
# fileview note stayed a local curiosity instead of a rule.
big_producers='ldconfig -p'
raced=0
while IFS= read -r prod; do
  [ -n "$prod" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    bad "$hit — '$prod' outruns a pipe buffer, so '| grep -q' fails when the match EXISTS; capture it and match with a glob"
    raced=1
  # Skip comment lines: the fix for this very race explains the pattern in prose,
  # and a scan that cannot tell code from a warning about code flags the warning.
  done < <(grep -rn -- "$prod .*|.*grep[^|]*-[a-zA-Z]*q" --include='*.sh' \
             "$ROOT/apps" "$ROOT/install" "$ROOT/gate" "$ROOT/bin" 2>/dev/null \
           | grep -v '/test-shell-options\.sh:' \
           | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
done <<EOF
$big_producers
EOF
[ "$raced" = 0 ] && ok "no known-large producer is piped into grep -q"

# ---- 6. no HTTP body piped into grep -q ----
# The same race, one step more general. A named producer can be judged by name
# (`ldconfig -p` is large, `--version` is not); an HTTP response body cannot be
# judged at all, because its size is decided by the server's data and not by
# anything visible in the code. `curl <endpoint> | grep -q` is therefore always
# the racing shape — it just waits for the box to accumulate enough rows.
#
# apps/fileview/smoke.sh met it first and fixed it by capturing the body and
# matching in-shell. apps/publish/smoke.sh had two of them left over (the list
# endpoint and the backend health probe): a publish install with a few hundred
# shared files would have started reporting `okjson=no` on a working box, which
# is the failure this whole campaign is about — a check that lies quietly and
# intermittently.
#
# `code()`-style calls are exempt by construction: `-o /dev/null -w '%{http_code}'`
# emits three bytes, which is a bound the code really does state.
piped_body=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  bad "$hit — an HTTP body has no code-visible size bound, so '| grep -q' fails when the match EXISTS; capture the body and match in-shell"
  piped_body=1
done < <(grep -rn -- "curl[^|]*|[^|]*grep[^|]*-[a-zA-Z]*q" --include='*.sh' \
           "$ROOT/apps" "$ROOT/install" "$ROOT/gate" "$ROOT/bin" 2>/dev/null \
         | grep -v '/test-shell-options\.sh:' \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
         | grep -v -- '-o /dev/null' || true)
[ "$piped_body" = 0 ] && ok "no HTTP response body is piped into grep -q"

# Positive control: the scan must actually fire on the shape it describes, and
# must not fire on the bounded look-alike. Written to a fixture rather than left
# in the tree — a committed bad example is the first thing someone excludes.
ctl="$fix/ctl"; mkdir -p "$ctl"
{
  echo '#!/usr/bin/env bash'
  echo 'curl -s "http://127.0.0.1:1/api/list" | grep -q needle && found=yes'
} > "$ctl/bad.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }'
  echo 'c=$(code "http://127.0.0.1:1/"); body="$(curl -s "http://127.0.0.1:1/api/list")"'
  echo '[[ "$body" == *needle* ]] && found=yes'
} > "$ctl/good.sh"
ctl_scan() {
  grep -rn -- "curl[^|]*|[^|]*grep[^|]*-[a-zA-Z]*q" --include='*.sh' "$1" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v -- '-o /dev/null'
}
[ -n "$(ctl_scan "$ctl/bad.sh")" ] \
  && ok "HTTP-body scan positive control: 'curl ... | grep -q' is caught" \
  || bad "HTTP-body scan positive control: the scan did not fire on a real instance of the shape"
[ -z "$(ctl_scan "$ctl/good.sh")" ] \
  && ok "HTTP-body scan negative control: a bounded 'code()' curl and a captured body both pass" \
  || bad "HTTP-body scan negative control: the scan false-positives on the approved fix"

# ---- 7. smoke lane SQL must not live in a single-quoted python3 -c ----
# 2026-08-16 live: the lane checker ran as `python3 -c '... status!='superseded' ...'`.
# The inner quotes closed the -c string, SQLite saw a column named superseded, and the
# check failed only when messages=true actually executed that SQL. CI and the default
# live install (messages=false) never reached it. Short one-line `python3 -c` probes
# above the lane block stay; they contain no nested single quotes.
lane_sql_python_c_scan() {
  awk '
    function assignment_substitution(s) {
      return s ~ /^[[:space:]]*((local|readonly|declare|export)[[:space:]]+)?[[:alpha:]_][[:alnum:]_]*[[:space:]]*=[[:space:]]*"?[[:space:]]*\$\(/
    }
    function last_python_tail(s, rest, tail) {
      rest=s; tail=""
      while (match(rest, /["'\'' ]?python3["'\'']?/)) {
        tail=substr(rest, RSTART)
        rest=substr(rest, RSTART + RLENGTH)
      }
      return tail
    }
    function dangerous(s) {
      gsub(/[[:space:]]+/, " ", s)
      return s ~ /python3["'\'']?[[:space:]]+["'\'']?-c["'\'']?([[:space:]]|$)/
    }
    assignment_substitution($0) {
      active=1; text=""; host=""; heredoc=0
    }
    active {
      line=$0
      sub(/\\[[:space:]]*$/, "", line)
      text=text " " line
      if (!heredoc) {
        host=text
        if (line ~ /<<-?[[:space:]]*["'\'']/ ||
            line ~ /<<-?[[:space:]]*[[:alpha:]_]/)
          heredoc=1
      }
      if (line ~ /status!='\''superseded'\''/) {
        probe=(heredoc ? last_python_tail(host) : text)
        if (dangerous(probe)) found=1
        active=0
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}
if lane_sql_python_c_scan "$ROOT/apps/dev-monitor/smoke.sh"; then
  bad "target lane SQL sits in a scanned scalar-assignment python3 -c host"
else
  ok "target lane SQL is absent from scanned scalar-assignment python3 -c hosts"
fi
if grep -n -- "messages.delivery_lane_health" "$ROOT/apps/dev-monitor/smoke.sh" >/dev/null \
   && grep -n -- "python3 - .*<<'PY'" "$ROOT/apps/dev-monitor/smoke.sh" >/dev/null; then
  ok "lane health calls the production backend inside a quoted heredoc"
else
  bad "production lane health or its quoted-heredoc host is missing from apps/dev-monitor/smoke.sh"
fi

# Positive controls cover both ways this regression can be restored. The second
# one is deliberately a malformed hybrid: keeping the heredoc marker must not
# hide that the lane checker was changed back to `python3 -c`.
lane_ctl="$fix/lane-sql"; mkdir -p "$lane_ctl"
cat > "$lane_ctl/faithful-regression.sh" <<'SH'
lane_result=$(python3 -c '
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
' "$want" 2>&1)
SH
cat > "$lane_ctl/heredoc-hybrid-regression.sh" <<'SH'
lane_result=$(python3 -c "$want" 2>&1 <<'PY'
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
PY
)
SH
cat > "$lane_ctl/quoted-substitution-regression.sh" <<'SH'
lane_result="$(python3 -c '
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
')"
SH
cat > "$lane_ctl/multiline-substitution-regression.sh" <<'SH'
lane_result=$(
  python3 -c '
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
')
SH
cat > "$lane_ctl/renamed-variable-regression.sh" <<'SH'
lane_json=$(python3 -c '
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
')
SH
cat > "$lane_ctl/quoted-heredoc.sh" <<'SH'
lane_result=$(python3 - "$want" 2>&1 <<'PY'
conn.execute("SELECT id FROM deliveries WHERE status!='superseded'")
PY
)
SH
lane_sql_python_c_scan "$lane_ctl/faithful-regression.sh" \
  && ok "lane-SQL scan positive control: the faithful python3 -c regression is caught" \
  || bad "lane-SQL scan positive control: the faithful python3 -c regression escaped"
lane_sql_python_c_scan "$lane_ctl/heredoc-hybrid-regression.sh" \
  && ok "lane-SQL scan positive control: python3 -c is caught even when the heredoc marker remains" \
  || bad "lane-SQL scan positive control: the heredoc marker masked python3 -c"
lane_sql_python_c_scan "$lane_ctl/quoted-substitution-regression.sh" \
  && ok "lane-SQL scan positive control: shellcheck-style quoted command substitution is caught" \
  || bad "lane-SQL scan positive control: quoted command substitution escaped"
lane_sql_python_c_scan "$lane_ctl/multiline-substitution-regression.sh" \
  && ok "lane-SQL scan positive control: a newline after command-substitution open is caught" \
  || bad "lane-SQL scan positive control: multiline command substitution escaped"
lane_sql_python_c_scan "$lane_ctl/renamed-variable-regression.sh" \
  && ok "lane-SQL scan positive control: changing the result variable does not evade the gate" \
  || bad "lane-SQL scan positive control: renamed result variable escaped"
if lane_sql_python_c_scan "$lane_ctl/quoted-heredoc.sh"; then
  bad "lane-SQL scan negative control: the approved quoted heredoc was rejected"
else
  ok "lane-SQL scan negative control: the approved quoted heredoc passes"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
