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
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 15/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
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
# The remaining host reads, pinned like everything above (measured 2026-08-25:
# on a box with airlock actually installed, the transcript grew dev-monitor's
# `pre-ledger artifact(s) found` line and lost `chmod o+x /opt/airlock` —
# a --regen there would have baked that box's state into the goldens).
#   - adopt-scan globs the system unit dir and the two static platform dirs
#     for known-builtin artifacts: point all three at empty scratch dirs, the
#     fixed "nothing pre-installed" state every run sees.
#   - publish's mkdir_nginx_path decides its chmod lines by which ancestors
#     of /opt/airlock/share already exist: pin the dry run's existence probes
#     to a scratch root where /opt exists and /opt/airlock does not.
# install/test-equivalence-hermetic.sh proves these pins hold: it re-runs
# this suite with all four variables polluted toward a populated fake host.
mkdir -p "$TMP/unit-system" "$TMP/platform-etc" "$TMP/platform-opt" "$TMP/fsroot/opt"
export AIRLOCK_UNIT_DIR_SYSTEM="$TMP/unit-system"
export AIRLOCK_PLATFORM_ETC="$TMP/platform-etc"
export AIRLOCK_PLATFORM_OPT="$TMP/platform-opt"
export AIRLOCK_DRY_RUN_FSROOT="$TMP/fsroot"

cat > "$AIRLOCK_CONFIG" <<EOF
[site]
name = "Equivalence"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[paths]

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
  # The only bare username in these transcripts is this exact linger command.
  # Do not substitute a word-bounded username everywhere: GNU sed correctly
  # treats \broot\b as a word, so a root-named runner used to rewrite nginx's
  # `root` directives and comments as well.
  local runner_user="${1:-$(id -un)}" runner_group="${2:-$(id -gn)}"
  sed -e "s|$ROOT|ROOT|g" \
      -e "s|$TMP|TMP|g" \
      -e "s|$runner_user:$runner_group|USER:GROUP|g" \
      -e "s|^\(\[dry\] loginctl enable-linger \)$runner_user$|\1USER|"
}

# This deliberately uses root even if the runner is not root. It is the
# positive control for the bug above: a token whose spelling happens to be a
# common username must remain ordinary transcript content unless it is the
# one dynamic field we intend to erase.
normalise_fixture=$'[dry] loginctl enable-linger root\nroot TMP/web\n# the root location remains literal'
normalise_expected=$'[dry] loginctl enable-linger USER\nroot TMP/web\n# the root location remains literal'
normalise_actual="$(printf '%s\n' "$normalise_fixture" | normalise root root)"
normalise_ok=1
if [ "$normalise_actual" != "$normalise_expected" ]; then
  normalise_ok=0
  echo "FAIL equivalence: normalise rewrote a literal root token or missed the linger user"
fi

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

# The normal invocation is the card's entry.verify.  Its child runs need only
# the three byte comparisons above, otherwise the hermeticity suite's D/E
# controls would recursively start this suite again.
hermetic_ok=UNMEASURED
installed_paths=0
for host_path in /opt/airlock /etc/airlock /etc/systemd/system; do
  if [ -d "$host_path" ] && [ -n "$(find "$host_path" -mindepth 1 -print -quit)" ]; then
    installed_paths=$((installed_paths + 1))
  fi
done
clean_paths=UNMEASURED
installed_golden_diff_files=UNMEASURED
clean_golden_diff_files=UNMEASURED
clean_mount_capable=UNMEASURED
negative_control=UNMEASURED
host_samples_verdict=UNMEASURED

# This narrow mode is executed inside the deliberately clean mount namespace
# below. It is an anti-vacuity control: the same entrypoint must refuse to call
# a box "installed" when its three measured roots are empty.
if [ "${AIRLOCK_EQUIVALENCE_EXPECT_UNMEASURED:-0}" = 1 ]; then
  if [ "$installed_paths" != 0 ]; then
    echo "FAIL equivalence: clean-host negative control still saw $installed_paths populated installation root(s)"
    fail=1
    host_samples_verdict=FAIL
  fi
elif [ "${AIRLOCK_EQUIVALENCE_CORE_ONLY:-0}" != 1 ]; then
  if bash "$HERE/test-equivalence-hermetic.sh"; then
    hermetic_ok=1
  else
    hermetic_ok=0
    fail=1
    echo "FAIL equivalence: pinned-host-read controls failed"
  fi

  # Regenerate outside this worktree. First assert that this is actually an
  # installed host, then compare it with an unshared namespace which bind
  # mounts EMPTY /opt, /etc/airlock, and /etc/systemd/system. The source
  # goldens are inputs to diff only, never rewritten by this proof.
  if [ "$installed_paths" = 0 ]; then
    echo "UNMEASURED equivalence: no populated installation root among /opt/airlock, /etc/airlock, /etc/systemd/system"
  else
    SAMPLE="$(mktemp -d)"
    trap 'rm -rf "$TMP" "$SAMPLE"' EXIT
    if git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$SAMPLE" \
        && cp "$HERE/test-equivalence.sh" "$SAMPLE/install/test-equivalence.sh" \
        && bash "$SAMPLE/install/test-equivalence.sh" --regen \
        && diff -ruN "$GOLDEN_DIR" "$SAMPLE/install/golden" >/dev/null; then
      installed_golden_diff_files=0
    else
      installed_golden_diff_files=1
      echo "FAIL equivalence: installed-host --regen diverged from committed goldens"
    fi

    if [ "$installed_golden_diff_files" != 0 ]; then
      host_samples_verdict=FAIL
      fail=1
    elif clean_mount_error="$(unshare --user --map-root-user --mount --fork bash -ceu '
        clean=$(mktemp -d)
        mkdir -p "$clean/opt" "$clean/etc-airlock" "$clean/systemd"
        mount --bind "$clean/opt" /opt
        mount --bind "$clean/etc-airlock" /etc/airlock
        mount --bind "$clean/systemd" /etc/systemd/system
        for path in /opt /etc/airlock /etc/systemd/system; do
          test -z "$(find "$path" -mindepth 1 -print -quit)"
        done
      ' 2>&1)"; then
      clean_mount_capable=1
      clean_paths=0
      if unshare --user --map-root-user --mount --fork bash -ceu '
          clean=$(mktemp -d)
          mkdir -p "$clean/opt" "$clean/etc-airlock" "$clean/systemd"
          mount --bind "$clean/opt" /opt
          mount --bind "$clean/etc-airlock" /etc/airlock
          mount --bind "$clean/systemd" /etc/systemd/system
          for path in /opt /etc/airlock /etc/systemd/system; do
            test -z "$(find "$path" -mindepth 1 -print -quit)"
          done
          bash "$1/install/test-equivalence.sh" --regen
        ' bash "$SAMPLE" \
        && diff -ruN "$GOLDEN_DIR" "$SAMPLE/install/golden" >/dev/null; then
        clean_golden_diff_files=0
      else
        clean_golden_diff_files=1
        echo "FAIL equivalence: clean-host --regen diverged from committed goldens"
      fi

      # Negative control for the exact boundary above: when all three roots are
      # clean, this entrypoint must emit AC-GH-04 as UNMEASURED, never PASS.
      if negative_out="$(unshare --user --map-root-user --mount --fork bash -ceu '
        clean=$(mktemp -d)
        mkdir -p "$clean/opt" "$clean/etc-airlock" "$clean/systemd"
        mount --bind "$clean/opt" /opt
        mount --bind "$clean/etc-airlock" /etc/airlock
        mount --bind "$clean/systemd" /etc/systemd/system
        for path in /opt /etc/airlock /etc/systemd/system; do
          test -z "$(find "$path" -mindepth 1 -print -quit)"
        done
        AIRLOCK_EQUIVALENCE_EXPECT_UNMEASURED=1 bash "$1"
      ' bash "$HERE/test-equivalence.sh" 2>&1)" \
          && grep -q '^AC-GH-04 .*verdict: UNMEASURED ' <<<"$negative_out"; then
        negative_control=1
      else
        negative_control=0
        echo "FAIL equivalence: clean-host negative control emitted host_samples PASS or did not measure UNMEASURED"
      fi

      if [ "$clean_golden_diff_files" = 0 ] && [ "$negative_control" = 1 ]; then
        host_samples_verdict=PASS
      else
        host_samples_verdict=FAIL
        fail=1
      fi
    else
      # A CI runner can create a user namespace yet forbid mount(2). That says
      # nothing about golden equivalence: report this axis as UNMEASURED, while
      # retaining the separately measured installed-host golden diff above.
      echo "UNMEASURED equivalence: clean mount namespace unavailable: ${clean_mount_error##*$'\n'}"
    fi
  fi
fi

if [ "$normalise_ok" = 0 ]; then fail=1; fi
echo "---"
if [ "$fail" = 0 ]; then echo "passed=3 failed=0"; else echo "equivalence FAILED"; fi

# AC rows are intentionally emitted only by the public entrypoint, not its
# core-only children.  The card acceptor reruns this exact command at HEAD.
if [ "${AIRLOCK_EQUIVALENCE_CORE_ONLY:-0}" != 1 ]; then
  rev="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
  verdict() { [ "$1" = 1 ] && printf PASS || printf FAIL; }
  printf 'AC-GH-01 | expected: hermetic_controls == 1 | observed: hermetic_controls=%s | verdict: %s | signal: fixture | evidence: install/test-equivalence-hermetic.sh@%s\n' "$hermetic_ok" "$(verdict "$hermetic_ok")" "$rev"
  printf 'AC-GH-02 | expected: hermetic_controls == 1 | observed: hermetic_controls=%s | verdict: %s | signal: fixture | evidence: apps/publish/install.sh@%s\n' "$hermetic_ok" "$(verdict "$hermetic_ok")" "$rev"
  printf 'AC-GH-03 | expected: hermetic_controls == 1 | observed: hermetic_controls=%s | verdict: %s | signal: fixture | evidence: install/test-equivalence.sh@%s\n' "$hermetic_ok" "$(verdict "$hermetic_ok")" "$rev"
  printf 'AC-GH-04 | expected: installed_paths >= 1 && installed_golden_diff_files == 0 && clean_mount_capable == 1 && clean_paths == 0 && clean_golden_diff_files == 0 && negative_control == 1 | observed: installed_paths=%s,installed_golden_diff_files=%s,clean_mount_capable=%s,clean_paths=%s,clean_golden_diff_files=%s,negative_control=%s | verdict: %s | signal: replay | evidence: install/test-equivalence.sh@%s\n' "$installed_paths" "$installed_golden_diff_files" "$clean_mount_capable" "$clean_paths" "$clean_golden_diff_files" "$negative_control" "$host_samples_verdict" "$rev"
  printf 'AC-GH-05 | expected: normalise_literal_root == 1 | observed: normalise_literal_root=%s | verdict: %s | signal: fixture | evidence: install/test-equivalence.sh@%s\n' "$normalise_ok" "$(verdict "$normalise_ok")" "$rev"
fi
exit "$fail"
