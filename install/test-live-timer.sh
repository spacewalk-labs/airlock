#!/usr/bin/env bash
# install/test-live-timer.sh — the weekly wiring, and the alarms it depends on.
#
# The rule this file exists to satisfy: **if the absence of a weekly run does not
# turn something red, the weekly run is not implemented.** So every case here is
# about a failure being noticed, not about a success being produced.
#
# An alarm that has never been fired on purpose is a belief. This fleet has seven
# recorded cases of a scheduled job dying silently — 29 days, 9 days, three weeks —
# and one of them was a timer committed and never installed, which is a state where
# there is nothing to go stale and therefore nothing to notice. So the freshness
# check is driven through every state it can be in, including that one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FRESH="$ROOT/.github/scripts/live-freshness.py"
pass=0; fail=0
ok()  { echo "ok   live-timer: $1"; pass=$((pass+1)); }
bad() { echo "FAIL live-timer: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- fixtures
# Timestamps are computed relative to now rather than written as literals: a fixed
# date makes every case "stale" the moment it is old enough, which is a test that
# passes for the wrong reason and then starts failing for no reason.
run_fresh() {   # run_fresh <spec...>  -> sets OUT, RC
  ( cd "$TMP" && python3 - "$@" <<'PY'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc)
out = []
for spec in sys.argv[1:]:
    kind, days, verdict = spec.split(":")
    when = (now - datetime.timedelta(days=float(days))).strftime("%Y-%m-%dT%H:%M:%SZ")
    if kind == "result":
        body = ("## live verification — `20260101t000000-abc1234`\n\n"
                "| | |\n|---|---|\n| commit | `abc` |\n"
                f"| verdict | **{verdict}** |\n")
    elif kind == "alarm":
        body = "## ⚠️ weekly live verification FAILED\n\nit did\n"
    elif kind == "malformed":
        body = "## live verification — `20260101t000000-abc1234`\n\nno verdict line here\n"
    else:
        body = "someone talking about something else entirely\n"
    out.append({"createdAt": when, "body": body})
json.dump(out, open("comments.json", "w"))
PY
  )
  OUT="$(python3 "$FRESH" "$TMP/comments.json" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------- freshness
run_fresh "result:1:0"
[ "$RC" = 0 ] && ok "a recent green result passes" \
  || { bad "a recent green result was rejected: $OUT"; }

run_fresh
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'NEVER STARTED' \
  && ok "no result at all is NEVER STARTED (the committed-but-never-installed case)" \
  || bad "an empty issue did not fail as NEVER STARTED: $OUT"

run_fresh "noise:1:0"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'NEVER STARTED' \
  && ok "unrelated comments do not count as results" \
  || bad "a non-result comment satisfied the check: $OUT"

run_fresh "result:20:0"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'STALE' \
  && ok "a 20-day-old green result is STALE" \
  || bad "a 20-day-old result passed: $OUT"

# The tolerance boundary, from both sides. A check whose threshold nobody has
# driven is a number somebody typed.
run_fresh "result:7.5:0"
[ "$RC" = 0 ] && ok "7.5 days is inside the 8-day tolerance" \
  || bad "7.5 days was rejected: $OUT"
run_fresh "result:8.5:0"
[ "$RC" != 0 ] && ok "8.5 days is outside it" \
  || bad "8.5 days passed: $OUT"

run_fresh "result:1:1"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'FRESH BUT RED' \
  && ok "a recent failing result is FRESH BUT RED, not stale" \
  || bad "a recent verdict-1 result was not reported as red: $OUT"

run_fresh "result:1:3"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'ingress' \
  && ok "verdict 3 passes with a warning about ingress, rather than being flattened either way" \
  || bad "verdict 3 was not handled as its own state: $OUT"

run_fresh "result:3:0" "alarm:1:0"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'RAN AND FAILED' \
  && ok "an alarm newer than the last result is RAN AND FAILED" \
  || bad "a failure alarm after the last result did not fail the check: $OUT"

run_fresh "alarm:3:0" "result:1:0"
[ "$RC" = 0 ] \
  && ok "an alarm OLDER than the last result does not keep the check red forever" \
  || bad "a stale alarm poisoned a subsequent green result: $OUT"

run_fresh "malformed:1:0"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'UNREADABLE' \
  && ok "a result with no verdict line is UNREADABLE, not a pass" \
  || bad "a malformed result did not fail: $OUT"

# The four states have to be distinguishable in the OUTPUT, not just in the exit
# code. A check that fails identically for every reason sends people looking in the
# wrong place, which is most of what a bad alarm costs.
seen=""
for spec_and_word in ":NEVER STARTED" "result:20:0|STALE" "result:1:1|FRESH BUT RED" "result:3:0 alarm:1:0|RAN AND FAILED"; do
  word="${spec_and_word##*|}"
  specs="${spec_and_word%%|*}"; [ "$specs" = ":NEVER STARTED" ] && specs=""
  # shellcheck disable=SC2086
  run_fresh $specs
  printf '%s' "$OUT" | grep -q "$word" && seen="$seen ok" || seen="$seen MISSING:$word"
done
case "$seen" in
  *MISSING*) bad "the four failure states are not distinguishable in the output:$seen" ;;
  *) ok "never-started / stale / fresh-but-red / ran-and-failed each name themselves" ;;
esac

# ---------------------------------------------------------------- the alarm
# Fired deliberately, which is the only way an alarm becomes evidence rather than
# a belief.
ALARM_DIR="$TMP/state"; mkdir -p "$ALARM_DIR"
printf '2026-08-01T00:00:00Z abc123 0\n' > "$ALARM_DIR/LAST-RUN"
AIRLOCK_LIVE_RESULT_DIR="$ALARM_DIR" bash "$ROOT/live/alarm.sh" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] \
  && ok "the alarm exits 0 — a reporter that fails because the thing it reports failed is noise" \
  || bad "live/alarm.sh exited $rc"
[ -f "$ALARM_DIR/FAILING" ] \
  && ok "the alarm leaves a marker a watchdog elsewhere can see" \
  || bad "live/alarm.sh left no FAILING marker"
grep -q 'last run' "$ALARM_DIR/LAST-FAILURE" 2>/dev/null \
  && ok "the alarm records what the last run was, not just that one failed" \
  || bad "LAST-FAILURE does not carry the last-run state"
# Job 1 must survive job 2 being impossible: no gh, no issue number, still a marker.
rm -f "$ALARM_DIR/FAILING" "$ALARM_DIR/LAST-FAILURE"
nogh="$TMP/nogh"; mkdir -p "$nogh"
for c in bash sh date cat printf mkdir journalctl grep; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$nogh/$c"
done
PATH="$nogh" AIRLOCK_LIVE_RESULT_DIR="$ALARM_DIR" AIRLOCK_LIVE_ISSUE=999999 \
  bash "$ROOT/live/alarm.sh" >/dev/null 2>&1
[ -f "$ALARM_DIR/FAILING" ] \
  && ok "the local marker is written even when GitHub cannot be reached at all" \
  || bad "with gh missing the alarm left no local evidence — the two jobs are not independent"

# ---------------------------------------------------------------- the wiring
# The unit templates are checked as text, because a systemd unit is one of the few
# things where a missing line is silent by design.
S="$ROOT/live/systemd/airlock-live-verify.service.in"
T="$ROOT/live/systemd/airlock-live-verify.timer.in"
grep -q '^Persistent=true' "$T" \
  && ok "the timer is Persistent — a box that was off catches up instead of skipping the week" \
  || bad "the timer is not Persistent=true: a missed week would be silent"
grep -q '^OnFailure=airlock-live-failed.service' "$S" \
  && ok "the service has an OnFailure handler" \
  || bad "the service has no OnFailure — a failed run would be silent"

# The unattended run has to verify what ships, not whatever was last left in the
# checkout the unit runs from. Both halves are asserted because either one alone is
# silent: without the unit line the timer never asks, and without the script block the
# ask does nothing. Measured 2026-08-17 — that checkout was 10 commits behind and two
# of the ten had changed this verification system itself, so it was testing a tree
# without its own fixes and reporting green (#152).
grep -q '^Environment=AIRLOCK_LIVE_UPDATE=1' "$S" \
  && ok "the timer asks for the checkout to be advanced before it verifies" \
  || bad "the service does not set AIRLOCK_LIVE_UPDATE=1 — the weekly run would verify whatever tree it happened to find"
# Comments are stripped before these two look. The first version of this check read the
# whole file, so turning the branch into `if false` still passed — the paragraph above
# the code kept the name alive. A grep that a comment can satisfy is not a check.
verify_code=$(grep -vE '^[[:space:]]*#' "$ROOT/live/verify.sh")
printf '%s\n' "$verify_code" | grep -q 'AIRLOCK_LIVE_UPDATE' \
  && ok "verify.sh acts on that request" \
  || bad "verify.sh ignores AIRLOCK_LIVE_UPDATE outside its comments — the unit asks for something nothing does"
# And it must fast-forward rather than reset: a backstop that discards a commit to run
# is worse than one that refuses. `--ff-only` cannot, which is why it is the whole
# safety story here.
printf '%s\n' "$verify_code" | grep -q 'merge --ff-only' \
  && ok "the update is fast-forward only — it cannot discard a commit to make itself runnable" \
  || bad "verify.sh advances the checkout by some means other than --ff-only"
# Neither step of the update may fail open. `fetch … || true` passed every check above
# while putting the run straight back to verifying a tree of unknown age — the exact
# state #152 was filed about. Scoped to the update block: the teardown further down has
# a deliberate `|| true` on the tailnet logout, where a failure must not abort cleanup.
update_block=$(printf '%s\n' "$verify_code" | awk '/AIRLOCK_LIVE_UPDATE:-0/{f=1} f{print} f&&/^fi$/{exit}')
if [ -z "$update_block" ]; then
  bad "the AIRLOCK_LIVE_UPDATE block is not where this test looks for it, so its failure modes are unchecked"
elif printf '%s\n' "$update_block" | grep -q '|| true'; then
  bad "the update swallows a failure with '|| true' — a fetch that cannot fail leaves the run verifying a tree of unknown age"
else
  ok "the update refuses rather than continuing when it cannot advance the checkout"
fi
grep -q '^Environment=PATH=' "$S" \
  && ok "the service states its own PATH (a timer-driven session does not inherit one)" \
  || bad "the service inherits PATH from a non-interactive session"
# The alarm unit needs a working directory, because `gh issue comment` resolves
# the repository from cwd and a unit with none runs from /. Every alarm posted
# nothing until this was found by firing one on purpose (2026-08-08).
grep -q '^WorkingDirectory=@REPO@' "$ROOT/live/systemd/airlock-live-failed.service.in" \
  && ok "the alarm unit has a WorkingDirectory (gh resolves the repo from cwd)" \
  || bad "the alarm unit has no WorkingDirectory — gh cannot tell which repo to post to"
grep -q '^TimeoutStartSec=' "$S" \
  && ok "the service has a timeout — a hung run must not hold the slot forever" \
  || bad "the service has no TimeoutStartSec"
for f in "$S" "$T" "$ROOT/live/systemd/airlock-live-failed.service.in"; do
  grep -q '@REPO@\|@ENVFILE@\|@ONCALENDAR@' "$f" \
    || bad "$(basename "$f") has no placeholders — a site path may have been baked in"
done
ok "every unit template is still a template"

# ---------------------------------------------------- template vs what is installed
# Everything above reads the template. The template is not what runs. Measured
# 2026-08-18 on the one box the timer fires on: the template carried
# `AIRLOCK_LIVE_UPDATE=1` and the unit
# actually installed under ~/.config/systemd/user did not — it predated that line and
# nothing re-rendered it. So the fix for #152 was committed, tested, green, and absent
# from the one box the timer fires on. Every assertion above passed while the weekly
# run kept verifying whatever tree it found.
#
# Only the lines whose absence is silent are compared, and only on a box where the unit
# is installed; on CI there is nothing to compare and saying so is the honest result.
INSTALLED="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/airlock-live-verify.service"
if [ -f "$INSTALLED" ]; then
  drift=""
  for line in 'Environment=AIRLOCK_LIVE_UPDATE=1' 'OnFailure=airlock-live-failed.service' 'Environment=PATH='; do
    grep -q "^$line" "$S" || continue      # not required by the template → not drift
    grep -q "^$line" "$INSTALLED" || drift="${drift:+$drift, }$line"
  done
  [ -z "$drift" ] \
    && ok "the installed unit carries every line the template requires" \
    || bad "the installed unit at $INSTALLED is behind the template and is what actually runs — missing: $drift. Re-run live/install-timer.sh"
else
  ok "no unit is installed here, so template-vs-installed drift is unmeasurable (this is CI, not the box that runs it)"
fi

# The installer must refuse the two states that make a weekly job fail forever for
# reasons that have nothing to do with airlock.
out="$(cd "$ROOT" && bash live/install-timer.sh --envfile /nonexistent/env 2>&1)"; rc=$?
[ "$rc" != 0 ] \
  && ok "install-timer refuses to wire a job with no environment file" \
  || bad "install-timer accepted a missing environment file"
if [ -f "$ROOT/.git" ]; then
  printf '%s' "$out" | grep -q 'worktree' \
    && ok "install-timer refuses a git worktree (it gets reclaimed, and then the job fails weekly)" \
    || bad "install-timer did not refuse a worktree: $out"
else
  ok "install-timer's worktree refusal is unexercised here (this is a permanent clone)"
fi

# ---------------------------------------------------------------- the fetcher
# The judge above is only ever as good as the list handed to it, and the fetcher can
# hand it a short one without erroring: the API returns 30 comments per page, oldest
# first, so reading one page and stopping drops the newest result and the judge then
# says STALE about a schedule that is fine. That is a false alarm from the check whose
# whole value is being believed, so pagination gets a test rather than a comment.
FETCH="$ROOT/live/fetch-issue-comments.py"
if [ -f "$FETCH" ]; then
  # The body goes to a file rather than into a heredoc inside `$( )`: bash warns that
  # the here-document is unterminated there, and a construct the shell is unsure about
  # is a poor place to keep a test that other tests are trusted on.
  cat > "$TMP/fetcher_test.py" <<'PY'
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("fetcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

nxt = '<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=9>; rel="last"'
assert m.next_link(nxt) == "https://api.github.com/x?page=2", "next_link missed rel=next"
# Negative control: the last page carries only rel=prev/first, and reading `next` out of
# that is how a fetcher loops forever instead of stopping.
assert m.next_link('<https://api.github.com/x?page=8>; rel="prev"') is None, \
    "next_link invented a next page"

pages = {
    "u1": ([{"created_at": "2026-01-01T00:00:00Z", "body": "old"}],
           '<u2>; rel="next"'),
    "u2": ([{"created_at": "2026-02-01T00:00:00Z", "body": None}], ""),
}
m.fetch = lambda url, token: pages["u2" if url == "u2" else "u1"]
m.API = ""
os.environ["GITHUB_TOKEN"] = "t"; os.environ["GITHUB_REPOSITORY"] = "o/r"
out = os.path.join(tempfile.mkdtemp(), "c.json")
sys.argv = [sys.argv[0], "84", out]
m.main()
got = json.load(open(out))
assert len(got) == 2, f"pagination dropped comments: {got}"
assert [c["createdAt"] for c in got] == ["2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"], got
assert got[1]["body"] == "", "a null body must become empty text, not None"

# A page that errors must stop the run, not end it early with what it has. Both of these
# survived at 36/0 when only the happy path was driven — and a short list is exactly what
# the judge cannot tell apart from a schedule that stopped firing, so it is the one shape
# this fetcher must never produce quietly.
import urllib.error
for err in (urllib.error.HTTPError("u", 404, "nope", {}, None),
            urllib.error.URLError("no route to host")):
    def boom(url, token, _e=err):
        if url.endswith("page=2"):
            raise _e
        return ([{"created_at": "2026-01-01T00:00:00Z", "body": "old"}],
                '<u?page=2>; rel="next"')
    m.fetch = boom
    out2 = os.path.join(tempfile.mkdtemp(), "c.json")
    sys.argv = [sys.argv[0], "84", out2]
    try:
        m.main()
    except SystemExit as e:
        assert e.code not in (0, None), f"{type(err).__name__} exited {e.code!r}, not red"
    else:
        raise AssertionError(f"{type(err).__name__} on page 2 did not stop the fetch")
    assert not os.path.exists(out2), \
        f"{type(err).__name__} still wrote {out2} — a partial list that reads as a verdict"
print("fetcher ok")
PY
  OUT="$(python3 "$TMP/fetcher_test.py" "$FETCH" 2>&1)"; RC=$?
  [ "$RC" = 0 ] && ok "the fetcher reads every page and keeps the newest comment" \
    || bad "the fetcher's pagination/shape contract is broken: $OUT"

  # Fail-closed: no token must stop the run, not produce an empty list. An empty list
  # reaches the judge as NEVER STARTED, which is a true-looking alarm for a false reason.
  #
  # The message is asserted, not just the exit code. Without the guard this script goes
  # on to make the request anyway and dies on the 404 — or, on a machine with no network,
  # on the connection — so "it exited non-zero" is satisfied by the bug as well as by the
  # fix, and this test would sit here green while measuring nothing. A mutation run on
  # 2026-08-16 is how that was found: deleting the guard left the suite at 36/0.
  OUT="$( unset GITHUB_TOKEN; GITHUB_REPOSITORY=o/r python3 "$FETCH" 84 "$TMP/none.json" 2>&1 )"
  RC=$?
  # And it has to stop *before* the request, not complain and then die on the 401 that
  # follows — so the absence of any api.github.com in the output is part of the verdict.
  # That is the difference between a guard and a log line, and only the first one holds
  # when the network is up and the token is merely wrong.
  if [ "$RC" != 0 ] \
     && printf '%s' "$OUT" | grep -q 'GITHUB_TOKEN is empty' \
     && ! printf '%s' "$OUT" | grep -q 'api.github.com'; then
    ok "the fetcher refuses to run without a token, before it asks for anything"
  else
    bad "the fetcher did not stop on a missing token for the right reason (rc=$RC): $OUT"
  fi
else
  bad "the fetcher live/fetch-issue-comments.py is missing, and the workflow calls it"
fi

# And CI has to run this file, or none of the above is load-bearing.
grep -q 'install/test-live-timer.sh' "$ROOT/.github/workflows/ci.yml" \
  && ok "ci.yml runs this suite" \
  || bad "ci.yml does not run install/test-live-timer.sh"
grep -q 'live-freshness.py' "$ROOT/.github/workflows/live-freshness.yml" \
  && ok "the scheduled freshness workflow calls the script this suite drives" \
  || bad "the freshness workflow does not call live-freshness.py"

# Calling the script is not the same as running it. The workflow exempts the published
# mirror, where the tracking issue does not exist, and an exemption that quietly widens
# is indistinguishable from the check being switched off — which is exactly how this
# workflow spent its first seven runs skipping its own check while this suite stayed
# green.
#
# Three rounds of this block tried to assert that shape by *describing* it — is the
# shared runner named, is there a hosted fallback, is the script mentioned in the body.
# Every round was defeated, and the last one at a clean 39/0 by six separate edits
# (2026-08-17): an extra conjunct in the `runs-on` condition, which a non-greedy split
# puts in the wrong branch; a fallback of `["self-hosted","ubuntu-latest"]`, a label set
# no runner answers but which contains `ubuntu-`; and four ways to neuter the shell body
# while every named string stays present — `exit 0` above it, `if false; then … fi`
# around it, `set +e` instead of `set -euo pipefail`, and ` || true` after the judge.
#
# The lesson is that a description of a four-line shape is longer and weaker than the
# shape. So this block asserts the two load-bearing lines **exactly**, modulo whitespace.
# That is deliberately rigid: changing either one now fails here, and the failure asks
# for the change to be made in both places with a reason. A test that has been walked
# around six times has earned the right to be inflexible.
WF="$ROOT/.github/workflows/live-freshness.yml"
shape=$(python3 - "$WF" <<'PY'
import re, sys
CHECKS = 10
V = []
def ok(m): V.append('ok|' + m)
def bad(m): V.append('bad|' + m)
def emit():
    # Always exactly CHECKS verdicts. Leaving early has to look like failing checks,
    # not like fewer checks — the caller counts these.
    while len(V) < CHECKS:
        V.append('bad|a workflow-shape check did not run')
    # The count goes out with the verdicts rather than being written down again in the
    # caller: a number kept in two places is a number that will disagree, and the way it
    # disagrees here is checks going missing without anyone saying so.
    print('checks|%d' % CHECKS)
    print('\n'.join(V[:CHECKS])); sys.exit()

MIRROR = 'spacewalk-labs/airlock'
WORKING = 'spacewalk-labs/airlock-work'
RUNNER = ("${{ github.repository == '" + WORKING + "' && "
          "fromJSON('[\"self-hosted\",\"Linux\",\"X64\",\"shared-ci\"]') || 'ubuntu-latest' }}")
BODY = ['set -euo pipefail',
        'python3 live/fetch-issue-comments.py "$ISSUE" comments.json',
        'python3 .github/scripts/live-freshness.py comments.json']

def norm(s):
    return re.sub(r'\s+', ' ', s).strip()

lines = open(sys.argv[1]).read().splitlines()

# The trigger, before anything about the job. This suite's own first rule is that the
# absence of a weekly run has to turn something red — and deleting the `schedule:` block
# outright scored a clean pass here on 2026-08-16.
if any(re.match(r'^\s*-\s*cron:\s*\S', l) for l in lines) and \
        any(re.match(r'^  schedule:\s*$', l) for l in lines):
    ok('the watchdog is still on a schedule of its own')
else:
    bad('the freshness workflow has no `schedule:`/`cron:` trigger; a watchdog that only '
        'runs when someone asks it to is not watching anything')

# The permission #136 added. Its absence is not silent — the fetch 404s and says so — but
# it cost this file its first seven runs.
if any(re.match(r'^\s*issues:\s*read\s*$', l) for l in lines):
    ok('the token can still read the issue the results are on (#136)')
else:
    bad('`issues: read` is gone from permissions; naming any scope drops the rest to '
        'none, and on a private repository that reads as 404, not 403')

# The job block: from `  freshness:` to the next key at the same depth. Comments are NOT
# stripped from `raw` — a `run:` body is a block scalar where `#` is data, and the
# heuristic that used to strip it kept a line whole whenever an odd number of `'`
# preceded the `#`, which is how `echo 'off # python3 …live-freshness.py'` passed.
start = next((i for i, l in enumerate(lines) if re.match(r'^  freshness:\s*$', l)), None)
if start is None:
    bad('the freshness job is not where this test looks for it, so none of the checks '
        'below could run'); emit()
end = next((i for i in range(start + 1, len(lines))
            if lines[i].strip() and not lines[i].startswith('    ')), len(lines))
raw = lines[start + 1:end]
indent = min((len(l) - len(l.lstrip()) for l in raw if l.strip()), default=4)

def strip_yaml_comment(s):
    # Only for key lines, never for block-scalar bodies.
    q = s.find('#')
    return s[:q] if q != -1 else s

def key_at(name, depth):
    pat = re.compile(r'^ {%d}[\'"]?%s[\'"]?\s*:' % (depth, name))
    return [l for l in raw if pat.match(strip_yaml_comment(l))]

if key_at('if', indent):
    bad('the freshness job carries a condition of its own; a skipped job reports '
        'skipped, and one line there switches the whole watchdog off')
else:
    ok('the freshness job itself is unconditional')

rl = key_at('runs-on', indent)
if len(rl) != 1:
    bad('the job has %d `runs-on` keys; a duplicate mapping key is resolved last-wins, '
        'so the one this test reads need not be the one that runs' % len(rl))
else:
    ok('the job names its runner exactly once')

runner = norm(rl[0].split(':', 1)[1]) if rl else ''
if runner == norm(RUNNER):
    ok('the runner line is the one this file was reasoned about')
else:
    bad('the runner line changed. Three properties depend on it and each fails '
        'differently: the working copy must reach the shared runner (hosted minutes are '
        'blocked here, so a job sent to them never reaches a step); every other copy '
        'must land on a real hosted image (labels no runner answers do not go red, they '
        'queue until they are silently cancelled); and the working copy must be named by '
        'exact match (a suffix drifts forks and renames onto the shared runner). If the '
        'change is deliberate, update the expected value in install/test-live-timer.sh '
        'and say why.\n      expected: %s\n      found:    %s' % (norm(RUNNER), runner))

# Any value, not just `true`: `True`, `TRUE`, `yes` and `${{ … }}` are all truthy to
# YAML or to Actions, and there is no reading of this workflow where the key belongs.
if [l for l in raw if re.match(r'^\s*[\'"]?continue-on-error[\'"]?\s*:', strip_yaml_comment(l))]:
    bad('something in the freshness job is allowed to fail without turning the job '
        'red, which is the one thing this workflow exists to do')
else:
    ok('nothing in the freshness job may fail quietly')

# Steps: split on the list markers inside `steps:`.
si = next((i for i, l in enumerate(raw)
           if re.match(r'^ {%d}steps:\s*$' % indent, strip_yaml_comment(l))), None)
steps, cur = [], None
for l in (raw[si + 1:] if si is not None else []):
    if re.match(r'^\s*- ', l):
        cur = [l]; steps.append(cur)
    elif cur is not None:
        cur.append(l)

def named(n):
    return [s for s in steps
            if any(re.search(r'(?:^|\s)name:\s*%s\s*$' % re.escape(n), strip_yaml_comment(l))
                   for l in s)]

CHECK_STEP = 'the newest result is recent and green'
for label, name, cond in (
    ('the freshness check', CHECK_STEP, "${{ github.repository != '%s' }}" % MIRROR),
    ('the mirror exemption', 'not the copy the results are posted to',
     "${{ github.repository == '%s' }}" % MIRROR),
):
    hits = named(name)
    if len(hits) != 1:
        bad('%s is missing, or named more than once — %d steps in the job answer to '
            'that name' % (label, len(hits)))
        continue
    found = [strip_yaml_comment(l).split(':', 1)[1].strip() for l in hits[0]
             if re.match(r'^\s*[\'"]?if[\'"]?\s*:', strip_yaml_comment(l))]
    if found == [cond]:
        ok('%s carries exactly its own condition' % label)
    else:
        bad('%s does not carry its own condition (found %r) — swapped, widened, '
            'or dropped' % (label, found))

# The shell the check actually runs, compared line for line. Naming the scripts is not
# running them: `exit 0`, `if false; then … fi`, `set +e` and ` || true` all leave every
# name in place and all four passed the previous version of this check.
hits = named(CHECK_STEP)
body, issue = [], None
if len(hits) == 1:
    st = hits[0]
    ri = next((i for i, l in enumerate(st)
               if re.match(r'^\s*[\'"]?run[\'"]?\s*:', strip_yaml_comment(l))), None)
    if ri is not None:
        body = [norm(l) for l in st[ri + 1:] if l.strip()]
    for l in st:
        m = re.match(r'^\s*ISSUE:\s*(\S+)\s*$', strip_yaml_comment(l))
        if m:
            issue = m.group(1).strip('\'"')

if body == [norm(b) for b in BODY]:
    ok('the check step runs exactly the two scripts and nothing else')
else:
    bad('the check step\'s shell is not the one this suite drives. Every edit to it is '
        'an edit to whether the watchdog can go red at all — `exit 0`, a false '
        'conditional, `set +e` and a trailing `|| true` each end its purpose while '
        'leaving the script names in place. If the change is deliberate, update the '
        'expected body in install/test-live-timer.sh and say why.\n'
        '      expected: %r\n      found:    %r' % ([norm(b) for b in BODY], body))

if issue == '84':
    ok('the check still reads the issue the results are posted to')
else:
    bad('the tracking issue number is %r, not 84; a wrong number cannot be caught at '
        'runtime by anything except the judge refusing an empty list' % issue)

emit()

PY
)
# Count the verdicts before trusting them. A check that did not run must not be absent
# from the tally — that is the same mistake as a workflow whose step is skipped while
# the suite stays green, which is why this block exists at all.
want=$(printf '%s\n' "$shape" | sed -n 's/^checks|//p')
verdicts=$(printf '%s\n' "$shape" | grep -E '^(ok|bad)\|')
n=$(printf '%s\n' "$verdicts" | grep -cE '^(ok|bad)\|')
if [ -n "$want" ] && [ "$n" = "$want" ]; then
  while IFS='|' read -r verdict msg; do
    [ "$verdict" = ok ] && ok "$msg" || bad "$msg"
  done <<< "$verdicts"
else
  bad "the workflow-shape checks did not all report (${n} of ${want:-?}); treat the shape of live-freshness.yml as unverified"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
