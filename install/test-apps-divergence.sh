#!/usr/bin/env bash
# Controls for install/check-apps-divergence.py.
#
# A compare that is never fed a split looks exactly like a compare that cannot
# see one. The cases below plant two tiny git trees, then add a new split,
# put it back, and swap which file is split so a count-only baseline would
# stay green.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$HERE/check-apps-divergence.py"
pass=0
fail=0
ok()  { printf 'ok   apps-divergence: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL apps-divergence: %s\n' "$1"; fail=$((fail+1)); }

FIX="$(mktemp -d)" || { echo "FAIL apps-divergence: could not create fixture dir" >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

seed_repo() {
  local dir="$1"
  mkdir -p "$dir/apps/keep" "$dir/apps/drift"
  printf 'same\n' > "$dir/apps/keep/stable.txt"
  printf 'same-too\n' > "$dir/apps/keep/twin.txt"
  printf '%s\n' "$2" > "$dir/apps/drift/known.txt"
  git -C "$dir" init -b main >/dev/null
  git -C "$dir" -c user.name=gate -c user.email=gate@test commit --allow-empty -m seed >/dev/null
  git -C "$dir" add apps
  git -C "$dir" -c user.name=gate -c user.email=gate@test commit -m tree >/dev/null
}

commit_tree() {
  local dir="$1" message="$2"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=gate -c user.email=gate@test commit -m "$message" >/dev/null
}

seed_repo "$FIX/work" "work-known"
seed_repo "$FIX/apps" "apps-known"
printf 'only-on-work\n' > "$FIX/work/apps/drift/only-work.txt"
commit_tree "$FIX/work" "only-work"

BASE="$FIX/baseline.txt"
cat > "$BASE" <<'EOF'
only-work	apps/drift/only-work.txt
content	apps/drift/known.txt
EOF

run_gate() {
  python3 "$GATE" --work-root "$FIX/work" --apps-root "$FIX/apps" --baseline "$BASE"
}

out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'extra=0'; then
  ok "known path list is green"
else
  bad "known path list should be green (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

printf 'new-split\n' > "$FIX/work/apps/keep/stable.txt"
commit_tree "$FIX/work" "new-split"
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'EXTRA content apps/keep/stable.txt'; then
  ok "new content split is red"
else
  bad "new content split should be red (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

git -C "$FIX/work" -c user.name=gate -c user.email=gate@test revert --no-edit HEAD >/dev/null
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'extra=0'; then
  ok "reverted split is green again"
else
  bad "reverted split should be green (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

printf 'apps-known\n' > "$FIX/work/apps/drift/known.txt"
printf 'now-split\n' > "$FIX/work/apps/keep/twin.txt"
commit_tree "$FIX/work" "same-count-swap"
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'EXTRA content apps/keep/twin.txt' \
  && printf '%s\n' "$out" | grep -q 'healed content apps/drift/known.txt'; then
  ok "same count, different path is red"
else
  bad "same-count swap should be red (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

git -C "$FIX/work" -c user.name=gate -c user.email=gate@test revert --no-edit HEAD >/dev/null
mkdir -p "$FIX/apps/apps/keep"
printf 'apps-only\n' > "$FIX/apps/apps/keep/ghost.txt"
commit_tree "$FIX/apps" "only-apps"
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'EXTRA only-apps apps/keep/ghost.txt'; then
  ok "new apps-only path is red"
else
  bad "new apps-only path should be red (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

git -C "$FIX/apps" -c user.name=gate -c user.email=gate@test revert --no-edit HEAD >/dev/null

printf 'work-known-changed\n' > "$FIX/work/apps/drift/known.txt"
commit_tree "$FIX/work" "known-blob"
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'extra=0' \
  && printf '%s\n' "$out" | grep -q 'kind-changed=0'; then
  ok "known content path may keep changing blobs"
else
  bad "known content blob change should stay green (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

git -C "$FIX/apps" rm -q apps/drift/known.txt
commit_tree "$FIX/apps" "drop-known"
out="$(run_gate 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'KIND content->only-work apps/drift/known.txt'; then
  ok "known content path becoming only-work is red"
else
  bad "kind worsening should be red (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

git -C "$FIX/apps" -c user.name=gate -c user.email=gate@test revert --no-edit HEAD >/dev/null

out="$(python3 "$GATE" --work-root "$FIX/work" --apps-root "$FIX/missing" --baseline "$BASE" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'not a directory'; then
  ok "missing apps-root fails closed"
else
  bad "missing apps-root should fail closed (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

EMPTY="$FIX/empty.txt"
: > "$EMPTY"
out="$(python3 "$GATE" --work-root "$FIX/work" --apps-root "$FIX/apps" --baseline "$EMPTY" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'lists no paths'; then
  ok "empty baseline fails closed"
else
  bad "empty baseline should fail closed (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

if [ "$fail" -ne 0 ]; then
  printf 'apps-divergence: %s ok, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'apps-divergence: %s ok, %s failed\n' "$pass" "$fail"
