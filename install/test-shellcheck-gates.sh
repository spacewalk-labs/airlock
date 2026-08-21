#!/usr/bin/env bash
# install/test-shellcheck-gates.sh — controls for install/check-shellcheck-gates.sh.
#
# A scan that returns zero because it is broken looks exactly like a scan that
# returns zero because the tree is clean. That is not a hypothetical here: the
# repository has been running ShellCheck over these same files for months and
# discarding the answer with `|| true`, which is the same failure wearing a
# different hat. So the gate gets a positive control (a fixture that really is
# bad and must be refused) and a negative control (a legitimate look-alike that
# must be accepted), and both are asserted, not assumed.
#
# The fixtures are written here rather than committed as files on purpose: a bad
# fixture living in the tree would be found by the gate's own default file set,
# and the first thing anyone would do is add an exclusion — which is how the
# `|| true` got there in the first place.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$HERE/check-shellcheck-gates.sh"
pass=0; fail=0
ok()  { echo "ok   shellcheck-gates: $1"; pass=$((pass+1)); }
bad() { echo "FAIL shellcheck-gates: $1"; fail=$((fail+1)); }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# ---- positive control: the exact shape of defect 5 ----
# An unquoted heredoc whose body contains a backtick. This is not a style
# preference: `cat <<WORD` (no quotes) makes the body subject to substitution, so
# the shell RUNS what the author wrote as a comment, the words disappear from the
# rendered output, and `cat` still exits 0 so the caller sees success.
mkdir -p "$FIX/bad"
cat > "$FIX/bad/render.sh" <<'FIXTURE'
# shellcheck shell=bash
render_bad_unit() {
  local VALUE="$1"
  cat <<UNITEOF
[Service]
# The default is `infinity`, which is not the same as unbounded.
TasksMax=${VALUE}
UNITEOF
}
FIXTURE
out="$(bash "$GATE" "$FIX/bad/render.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "positive control passed — the gate does not catch a backtick in an unquoted heredoc"
  printf '%s\n' "$out" | sed 's/^/    /'
else
  # Both rules must fire on it: SC2006 tree-wide AND -S style because it is a
  # render.sh. If only one fires, one of the two rules is not doing anything.
  n_sc2006=$(printf '%s\n' "$out" | grep -c 'legacy backticks (SC2006)')
  n_style=$(printf '%s\n' "$out" | grep -c 'style findings in a renderer')
  if [ "$n_sc2006" -ge 1 ] && [ "$n_style" -ge 1 ]; then
    ok "positive control refused by both rules (rc=$rc)"
  else
    bad "positive control refused, but only by one rule (SC2006=$n_sc2006 style=$n_style)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
fi

# ---- negative control: the legitimate look-alike ----
# The same comment, written the way this repo's renderers write it, plus the two
# things that DO belong in an unquoted heredoc — a `${VAR}` the caller expands and
# a `\$VAR` escaped so it survives into the rendered unit. A gate that cannot tell
# these apart from the fixture above is noise, and noise is what people silence.
mkdir -p "$FIX/good"
cat > "$FIX/good/render.sh" <<'FIXTURE'
# shellcheck shell=bash
render_good_unit() {
  local VALUE="$1" HOME_DIR="$2"
  cat <<UNITEOF
[Service]
# The default is 'infinity', which is not the same as unbounded.
# Read the counter with: cat /sys/fs/cgroup/user.slice/user-\$(id -u).slice/pids.events
Environment=HOME=${HOME_DIR}
TasksMax=${VALUE}
UNITEOF
}
FIXTURE
out="$(bash "$GATE" "$FIX/good/render.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "negative control accepted (single quotes, \${VAR} expansion and \\\$(...) escaping all pass)"
else
  bad "negative control rejected — the gate false-positives on a legitimate renderer"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- the gate refuses to be silently absent ----
# `command -v shellcheck || skip` would make this whole file report success on a
# box without the tool. Exit 2 is deliberately neither pass nor fail.
probe="$FIX/nopath"; mkdir -p "$probe"
for c in bash sh grep sed cat head basename dirname mktemp git; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$probe/$c"
done
out="$(PATH="$probe" bash "$GATE" "$FIX/good/render.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'shellcheck is not installed'; then
  ok "a missing shellcheck is an error (exit 2), not a silent pass"
else
  bad "with shellcheck off PATH the gate returned rc=$rc: $out"
fi

# ---- the real tree is clean ----
# The gate is only worth having if it is green on what we actually ship; a rule
# that arrives red is a rule someone will add an exclusion to this week.
out="$(bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "the shipped tree passes both rules"
else
  bad "the shipped tree fails the gate"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- CI actually runs it ----
# The seventh recorded case in this fleet of a scheduled job dying silently was a
# unit that was committed and never installed. A gate that no workflow calls is
# the same thing.
if grep -q 'install/check-shellcheck-gates.sh' "$ROOT/.github/workflows/ci.yml"; then
  ok "ci.yml calls the gate"
else
  bad "ci.yml does not call install/check-shellcheck-gates.sh — the gate is not wired"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
