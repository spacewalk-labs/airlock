#!/usr/bin/env bash
# Built-in equivalence harness (child 3, F-spec 9): the packages feature must
# be invisible to a built-in-only box. Runs the shimmed 4-app dry run (the
# child-2 procedure, now in-tree) plus the nginx render and webjson against
# the working tree, normalises volatile strings, and byte-compares each
# transcript to a committed golden. Changing built-in behaviour therefore
# requires `--regen` — a commit that SHOWS the transcript diff.
#
# Scope, stated precisely: the guarantee measured here is equivalence of THIS
# fixed hub/notepad/publish/devterm DRY-RUN fixture (plus the render and
# webjson projections). Built-ins outside the fixture and real-run-only
# branches are covered by their own suites, not by these goldens; the
# full-matrix byte comparison is F13, child 4.
#
#   bash install/test-equivalence.sh            # compare against goldens
#   bash install/test-equivalence.sh --regen    # rewrite goldens (commit the diff)
set -euo pipefail
# Pin the RAM the paseo installer picks its memory tier from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: unpinned, a suite straddling
# the 16 GiB tier edge flips between 14G/12G and 5.5G/5G, and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GOLDEN_DIR="$HERE/golden"
MODE="${1:-check}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- fixed environment -------------------------------------------------------
# Everything an install could read from the box is pinned or scratch-scoped, so
# two runs anywhere produce the same bytes after normalisation.
mkdir -p "$TMP/home" "$TMP/web" "$TMP/confd" "$TMP/code" "$TMP/state" "$TMP/bin"
export HOME="$TMP/home"
export AIRLOCK_CONFIG="$TMP/airlock.toml"
export AIRLOCK_STATE_DIR="$TMP/state"
export AIRLOCK_WEBROOT="$TMP/web"
export AIRLOCK_CONFD="$TMP/confd"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_DRY_RUN=1

cat > "$AIRLOCK_CONFIG" <<EOF
[site]
name = "Equivalence"

[auth]
provider = "tailscale"
owner = "me@example.com"

[paths]
code_root = "$TMP/code"

[apps.hub]
[apps.notepad]
[apps.publish]
[apps.devterm]
EOF

# PATH shims: preflight probes `command -v` for every TSV command an enabled
# app owns; a box (CI) without tailscale/nginx/etc. must still pass, and the
# dry run itself never executes the [dry]-prefixed commands. Only MISSING
# commands are shimmed — present ones stay real so version probes stay honest.
while IFS=$'\t' read -r _owner cmd _rest; do
  case "$cmd" in ""|\#*) continue ;; esac
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  fi
done < "$ROOT/install/prerequisites.tsv"
# loginctl is NOT in prerequisites.tsv (it is not an app prerequisite) but
# airlock_enable_linger (install/lib.sh) reads its REAL output unconditionally
# — not dry-run-guarded — to decide which log line to print. Left un-shimmed,
# the transcript depends on whether the box running this test already has
# lingering enabled for its own user, which is exactly the box-dependence
# this harness exists to eliminate. Always shim it (unconditionally, unlike
# the loop above) to the same fixed "never configured" state every run.
cat > "$TMP/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show-user)     echo "Linger=no" ;;
  enable-linger) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/loginctl"
export PATH="$TMP/bin:$PATH"

normalise() {
  # \b on the bare-user substitution: an unanchored s|root|USER| would eat
  # the substring inside "webroot" for a root-named runner.
  sed -e "s|$ROOT|ROOT|g" \
      -e "s|$TMP|TMP|g" \
      -e "s|$(id -un):$(id -gn)|USER:GROUP|g" \
      -e "s|\b$(id -un)\b|USER|g"
}

# ---- the three transcripts ---------------------------------------------------
rc=0
bash "$ROOT/install/airlock-install.sh" > "$TMP/install.raw" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
  echo "FAIL equivalence: dry run exited rc=$rc"
  tail -20 "$TMP/install.raw"
  exit 1
fi
normalise < "$TMP/install.raw" > "$TMP/install.txt"

# stderr joins each transcript: a NEW WARNING on the built-in path is a
# behaviour change too, and diverting it to an uncompared file would hide it.
if ! bash "$ROOT/install/render-nginx.sh" > "$TMP/render.raw" 2>&1; then
  echo "FAIL equivalence: nginx render failed"; tail -20 "$TMP/render.raw"; exit 1
fi
normalise < "$TMP/render.raw" > "$TMP/render.txt"

if ! "$ROOT/bin/airlock-config" webjson > "$TMP/webjson.raw" 2>&1; then
  echo "FAIL equivalence: webjson failed"; tail -20 "$TMP/webjson.raw"; exit 1
fi
normalise < "$TMP/webjson.raw" > "$TMP/webjson.txt"

# ---- compare or regenerate ---------------------------------------------------
fail=0
for name in install render webjson; do
  golden="$GOLDEN_DIR/equivalence-$name.txt"
  actual="$TMP/$name.txt"
  if [ "$MODE" = "--regen" ]; then
    mkdir -p "$GOLDEN_DIR"
    cp "$actual" "$golden"
    echo "regenerated $golden"
    continue
  fi
  if [ ! -f "$golden" ]; then
    echo "FAIL equivalence: missing golden $golden (run --regen and commit it)"
    fail=1
    continue
  fi
  if ! diff -u "$golden" "$actual" > "$TMP/$name.diff"; then
    echo "FAIL equivalence: built-in $name transcript changed:"
    cat "$TMP/$name.diff"
    echo "  If this change is intended, rerun with --regen and COMMIT the"
    echo "  golden diff — built-in behaviour changes must be visible in review."
    fail=1
  else
    echo "ok   equivalence: $name transcript byte-identical"
  fi
done
[ "$MODE" = "--regen" ] && exit 0
echo "---"
if [ "$fail" = 0 ]; then echo "passed=3 failed=0"; else echo "equivalence FAILED"; fi
exit "$fail"
