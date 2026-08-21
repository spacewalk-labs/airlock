#!/usr/bin/env bash
# install/test-live-preflight-gate.sh — the two gates that decide whether a weekly run
# happens at all, and the marker that decides whether anyone believes it afterwards.
#
# Both were found by a run that did not happen. On 2026-08-17 the unattended weekly
# verification died in preflight because another session had left an untracked worklog
# draft in the shared checkout. The payload is `git archive "$SHA"`, so that file was
# never going to ship and the run would have been byte-identical — the gate rejected a
# reproducible run, and because the timer is weekly the cost was a week. The alarm it
# raised then sat in `FAILING` with nothing in the system able to remove it.
#
# The gate is exercised against a throwaway repository with a fake `ssh` in front of it,
# rather than by reading verify.sh as text: a grep for `--untracked-files=no` would pass
# on a line that had been commented out, and this file exists because a comment already
# satisfied one check in this suite once (see test-live-timer.sh).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok   live-preflight: $1"; pass=$((pass+1)); }
bad() { echo "FAIL live-preflight: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)" || { echo "FAIL live-preflight: mktemp"; exit 1; }
case "$TMP" in /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"/*) ;;
  *) echo "FAIL live-preflight: unexpected temp path $TMP"; exit 1 ;; esac
trap 'rm -rf "$TMP"' EXIT

# A fake ssh that succeeds. Preflight probes the LXD host before it reaches the gate, so
# without this the run dies of something else and the gate is never observed. Everything
# after the gate also goes through this stub, which is why each case runs under a
# timeout and is judged on what it printed, not on how it ended.
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/ssh"; chmod 755 "$BIN/ssh"

# Shaped like a real key: the preflight reads the id out of the third dash-field, so a
# placeholder without that shape silently skips the check the cases below are about.
KEY="$TMP/tskey"; printf 'tskey-auth-kFAKE1CNTRL-notarealsecret\n' > "$KEY"; chmod 600 "$KEY"

# One fixture repository, rebuilt per case so the cases cannot contaminate each other.
make_fixture() {   # $1 = dirty|untracked|clean
  local fix="$TMP/fix"
  rm -rf "$fix"; mkdir -p "$fix"
  cp -r "$ROOT/live" "$fix/live"
  git -C "$fix" init -q
  git -C "$fix" config user.email t@example.invalid
  git -C "$fix" config user.name t
  git -C "$fix" add -A
  git -C "$fix" commit -qm fixture
  case "$1" in
    dirty)     printf '\n# edited\n' >> "$fix/live/verify.sh" ;;
    untracked) printf 'draft\n' > "$fix/some-worklog-draft.md" ;;
    clean)     ;;
  esac
  printf '%s' "$fix"
}

run_preflight() {  # $1 = fixture root; extra env in the caller. prints combined output
  PATH="$BIN:$PATH" \
  AIRLOCK_LIVE_SSH=fake-host \
  AIRLOCK_LIVE_OWNER=t@example.invalid \
  AIRLOCK_LIVE_TSKEY_FILE="$KEY" \
  AIRLOCK_LIVE_RESULT_DIR="$TMP/result" \
  AIRLOCK_LIVE_PUBLISH=none \
  AIRLOCK_LIVE_ALLOW_DIRTY="${ALLOW_DIRTY:-0}" \
    timeout 60 bash "$1/live/verify.sh" 2>&1
}

echo "── the dirty gate"

fix="$(make_fixture untracked)"
out="$(run_preflight "$fix")"
printf '%s' "$out" | grep -qi 'FATAL.*modified\|FATAL.*dirty' \
  && bad "an untracked file stopped the run — it is not in the payload (git archive), so it cannot change the result" \
  || ok "an untracked file does not stop the run"
printf '%s' "$out" | grep -q 'untracked file' \
  && ok "the untracked file is still reported, so a green result is not mistaken for a claim about the disk" \
  || bad "the untracked file passed silently — an operator comparing the result to their disk gets no warning"

fix="$(make_fixture dirty)"
out="$(run_preflight "$fix")"
printf '%s' "$out" | grep -qi 'FATAL.*modified' \
  && ok "a modified tracked file does stop the run" \
  || bad "a modified tracked file did not stop the run: the operator's edits are not what would be verified"

fix="$(make_fixture dirty)"
out="$(ALLOW_DIRTY=1 run_preflight "$fix")"
printf '%s' "$out" | grep -qi 'FATAL.*modified' \
  && bad "AIRLOCK_LIVE_ALLOW_DIRTY=1 no longer overrides the gate" \
  || ok "AIRLOCK_LIVE_ALLOW_DIRTY=1 still overrides the gate"

echo "── the auth key"

# A spent key is what these cases exist for. Measured 2026-08-18: the weekly run passed
# every gate above, built a container, delivered the tree, and only then failed five opaque
# tailscale-up retries — the key on disk was single-use and had been consumed and revoked a
# day earlier. That job could not have succeeded on any future week, and the log said
# nothing about why. Minting per run removes the class; failing before the container is
# built removes the four minutes it used to take to find out.
printf '#!/bin/sh\ncat "$FAKE_CURL_BODY"\n' > "$BIN/curl"; chmod 755 "$BIN/curl"
printf 'fake-api-token\n' > "$TMP/apitoken"; chmod 600 "$TMP/apitoken"
export FAKE_CURL_BODY="$TMP/keybody.json"

fresh_body() { printf '%s' '{"id":"kNEW","key":"tskey-auth-kNEW-fresh"}' > "$FAKE_CURL_BODY"; }

# The chosen fix is to mint per run: a key on disk fails two ways — single-use dies next
# week, reusable leaves a long-lived credential in a file. Minted, used, deleted has neither.
fresh_body
fix="$(make_fixture clean)"
out="$(AIRLOCK_LIVE_TSAPI_TOKEN_FILE="$TMP/apitoken" run_preflight "$fix")"
printf '%s' "$out" | grep -q 'auth key minted for this run' \
  && ok "with an API token the run mints its own key instead of using the one on disk" \
  || bad "the run did not mint a key — it is back to depending on whatever is in the file"
printf '%s' "$out" | grep -q 'tskey-auth-kNEW-fresh' \
  && bad "🔴 the minted key value appears in the log, which is published" \
  || ok "the minted key value never reaches the log"

# A mint that fails must stop here, not four minutes later inside a container.
printf '%s' '{"message":"invalid credentials"}' > "$FAKE_CURL_BODY"
fix="$(make_fixture clean)"
out="$(AIRLOCK_LIVE_TSAPI_TOKEN_FILE="$TMP/apitoken" run_preflight "$fix")"
printf '%s' "$out" | grep -q 'FATAL.*could not mint' \
  && ok "a failed mint stops the run before anything is built" \
  || bad "a failed mint did not stop the run"
printf '%s' "$out" | grep -q 'invalid credentials' \
  && ok "the API's own reason is carried through, so an expired token names itself" \
  || bad "the mint failure gives no reason — the next person re-measures what the API already said"

# No token → the file key is used and its validity is unmeasured. It must say so: an
# unmeasured key that reads as a checked one is how the spent key survived a whole week.
fix="$(make_fixture clean)"
out="$(run_preflight "$fix")"
printf '%s' "$out" | grep -q '못 쟀습니다' \
  && ok "without an API token the run says the key is unmeasured, not that it is valid" \
  || bad "without an API token the run is silent about the key"

# 🔴 The minted key must not survive the run. It is written to a temp file and the EXIT
# trap that deletes it is later replaced by the teardown trap — so the deletion has to be
# inside teardown too. This asserts the pairing rather than the temp file, which is gone
# either way by the time the test can look.
grep -q 'rm -f "\$MINTED_KEY_FILE"' "$ROOT/live/verify.sh" \
  && ok "the minted key file is removed on exit" \
  || bad "nothing removes the minted key file"
awk '/^cleanup\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$ROOT/live/verify.sh" | grep -q 'MINTED_KEY_FILE' \
  && ok "the teardown removes it too (it replaces the earlier EXIT trap)" \
  || bad "only the early EXIT trap removes it — the teardown trap overwrites that one, so the key survives every exit path after the container is built"

echo "── the FAILING marker"

# Asserted on the source rather than by running a full verification: reaching the line
# means creating a container. What is checked is the pairing — the retraction has to sit
# with the LAST-GREEN write, because a retraction that can run on a red verdict would
# erase a live alarm. Comments are stripped first, for the reason named at the top.
code=$(grep -vE '^[[:space:]]*#' "$ROOT/live/verify.sh")
green_block=$(printf '%s\n' "$code" | awk '/LAST-GREEN/{f=1} f{print} f&&/^fi$/{exit}')
if [ -z "$green_block" ]; then
  bad "the LAST-GREEN block is not where this test looks for it, so the retraction is unchecked"
elif printf '%s\n' "$green_block" | grep -q 'rm -f.*FAILING'; then
  ok "a green run retracts FAILING, so one bad week does not alarm forever"
else
  bad "nothing removes FAILING on a green run — alarm.sh writes it and it outlives every fix, which trains people to ignore it"
fi
printf '%s\n' "$code" | grep -q 'rm -f "\$RESULT_DIR/FAILING"' \
  && ok "the retraction names FAILING explicitly" \
  || bad "the retraction does not name FAILING"

echo
echo "live-preflight: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
