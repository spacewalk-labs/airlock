#!/usr/bin/env bash
# install/check-app-abi.sh — an app package may reach the platform only through
# the D5 ABI. Nothing in apps/ may assume it lives inside the platform tree.
#
# The apps/ cutover moves these packages to their own repository. The couplings
# that survive that move are the ones the D5 ABI names — three environment
# variables plus two sourceable platform files:
#
#   AIRLOCK_ROOT      the platform checkout          (required, never derived)
#   AIRLOCK_APP_DIR   this package's own directory   (cwd; $0-relative fallback ok)
#   AIRLOCK_APP_ID    this package's configured id
#   $ROOT/install/lib.sh   $ROOT/gate/*              the only readable platform paths
#
# Everything else is legacy by definition: it can only work while the package
# happens to sit at <platform>/apps/<id>. This gate fails on three shapes.
#
#   1. Climbing to the platform root from $0. `ROOT="$(cd "$HERE/../.." && pwd)"`
#      resolves to the platform only inside the platform's own apps/ tree. After
#      the cutover it silently resolves to the app repository instead — the app
#      then sources a lib.sh that is not there, or worse, one that is.
#   2. A defaulted AIRLOCK_ROOT. `${AIRLOCK_ROOT:-<anything>}` reintroduces (1)
#      through the back door; the ABI variable is required, so it takes `:?`.
#      This is why the gate keys on the shape and not on the fallback text: the
#      first sweep fixed the four lifecycle scripts and missed three auxiliary
#      installers carrying the same idiom, which is what motivated a gate at all.
#   3. Reading a platform path outside the ABI. Only install/lib.sh and gate/*
#      are contract; `$ROOT/install/resource-holder-pids.py` (a real case, in
#      apps/paseo) is a platform internal that must come through a lib.sh
#      function, and `$ROOT/apps/<id>/...` is an app reaching itself by the one
#      route the cutover removes.
#
# Usage:
#   bash install/check-app-abi.sh            scan $ROOT/apps
#   bash install/check-app-abi.sh --dir DIR  scan an arbitrary package tree
#                                            (a staged out-of-tree package, or
#                                            the apps repository after cutover)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SCAN="$ROOT/apps"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) [ "$#" -ge 2 ] || { echo "--dir requires a path" >&2; exit 2; }
           SCAN="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$SCAN" ] || { echo "not a directory: $SCAN" >&2; exit 2; }

fails=0
report() { printf '::error::%s\n%s\n' "$1" "$2" >&2; fails=$((fails+1)); }

# Shell sources, found by SHEBANG as well as by extension. An earlier version of
# this gate keyed on `*.sh` alone and silently skipped two real files —
# apps/code-server/bin/airlock-code-server-slot and apps/devterm/bin/devterm-shell
# are shell programs with no extension, and an app installs them. A gate that
# reports "ok" over a set that excludes app-authored shell is worse than no gate,
# because the zero it prints is indistinguishable from a clean tree.
#
# Non-shell app sources (.py/.mjs/.js) are still out of scope: the ABI is consumed
# in shell, and backends are handed their paths by the unit their installer
# renders. install/test-app-abi.sh asserts that this stays true, so widening the
# gate further is a deliberate act rather than something someone must remember.
#
# Vendored upstream trees (paseo's patches/, orca's bundles) are not app-authored
# contract surface and are excluded by path, not by content.
mapfile -t files < <(
  find "$SCAN" -type f -not -path '*/patches/*' -not -path '*/node_modules/*' \
       -not -path '*/web-bundle/*' -print0 \
  | while IFS= read -r -d '' f; do
      case "$f" in
        *.sh) printf '%s\n' "$f"; continue ;;
        *.py|*.mjs|*.cjs|*.js|*.json|*.md|*.toml|*.html|*.css|*.png|*.svg) continue ;;
      esac
      # shebang probe, on the first line only
      IFS= read -r first < "$f" || continue
      case "$first" in
        '#!'*sh|'#!'*sh\ *) printf '%s\n' "$f" ;;
      esac
    done | sort
)
[ "${#files[@]}" -gt 0 ] || { echo "no shell files under $SCAN" >&2; exit 2; }

# Before matching, each file is normalised: whole-line comments are dropped and
# backslash line-continuations are joined into one logical line.
#
# Only WHOLE-LINE comments, deliberately. Every app script carries an ABI comment
# block that names the banned idioms on purpose, and those blocks are whole-line.
# The earlier `sed 's/[[:space:]]*#.*$//'` stripped from the first `#` anywhere on
# a line and is not quote-aware, so a `#` inside a quoted value deleted the rest of
# a real line of code from the scan — a hole in exactly the wrong direction.
# Keeping trailing text costs nothing: a violation followed by a comment is still a
# violation, and a comment alone on a code line matches no pattern here.
#
# Continuations are joined because a split path (`. "$ROOT"/\` + newline +
# `install/lib.sh`) is one read written on two lines, and matching per physical
# line cannot see it.
code_of() {
  grep -vE '^[[:space:]]*#' "$1" | sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*//;ba' -e '}'
}

# The canonical way to name the platform. This is an ALLOWLIST, and that choice is
# the whole design of this gate.
#
# Two rounds of adversarial review killed the blocklist approach. Round one walked
# six spellings of one climb past it — a cd-subshell, two chained `cd ..` steps,
# nested `dirname`, a `${VAR%/*/*}` suffix strip, `..` parked in a variable, and
# `$(dirname "$0")/../..` whose inner `)` slipped through a `[^)]*` pattern. Round
# two, against a rule that checked the ASSIGNMENT instead, walked six more:
# `read -r ROOT`, `printf -v ROOT`, `declare`, an array element, a positional
# parameter, an assignment tucked inside `if true; then ... fi`, and — the one that
# needs no variable at all — `. "$(cd "$HERE/../.." && pwd)/install/lib.sh"`.
# It also found that an ACCEPTED within-package climb could be extended one more
# level and escape (`P="$(cd "$HERE/../.." && pwd)"; . "$P/../install/lib.sh"`).
#
# The lesson is not that the next pattern will be better. Shell has unbounded ways
# to spell "a path", so no blocklist terminates. An allowlist does: there is exactly
# one accepted way to read the platform, every other spelling is a violation by
# construction, and a new evasion is not a new hole because it is not on the list.
ROOT_RE='["'"'"']?\$\{?(AIRLOCK_)?ROOT\}?["'"'"']?'

for f in "${files[@]}"; do
  rel="${f#"$SCAN"/}"
  code="$(code_of "$f")"

  # 1. Every read of a platform ABI path must be spelled with the canonical root.
  #    Anything else in that position — another variable, a command substitution,
  #    a concatenation, a climb — is refused without the gate having to know what
  #    it computes.
  hit="$(printf '%s\n' "$code" | grep -nE '/(install/lib\.sh|gate/[A-Za-z0-9_.-]+)' \
         | grep -vE "$ROOT_RE/(install/lib\.sh|gate/[A-Za-z0-9_.-]+)" || true)"
  [ -n "$hit" ] && report \
    "apps/$rel: reads a platform ABI path by some name other than \$ROOT/\$AIRLOCK_ROOT. The platform is named by the D5 ABI and by nothing else — not a derived variable, not an inline \$( ) that computes a root, not a path built from another path." \
    "$hit"

  # 2. And that root must come from AIRLOCK_ROOT, required, with no default.
  #    Checked both ways: no assignment to ROOT from anything else, and no other
  #    binding construct aimed at the name (read/printf -v/declare/eval), which is
  #    how round two rebound a correctly-assigned variable afterwards.
  if printf '%s\n' "$code" | grep -E "$ROOT_RE/(install/lib\.sh|gate/)" >/dev/null; then
    hit="$(printf '%s\n' "$code" \
           | grep -nE '(^|[;&|}[:space:]])(export[[:space:]]+)?ROOT=' \
           | grep -vE 'ROOT="?\$\{AIRLOCK_ROOT[:?}]' || true)"
    [ -n "$hit" ] && report \
      "apps/$rel: \$ROOT is used to read the platform but is assigned from something other than \${AIRLOCK_ROOT:?...}. The platform root is handed to the package; it may not be derived from \$0, because that derivation is the platform only while the package sits in the platform's own apps/ tree." \
      "$hit"

    hit="$(printf '%s\n' "$code" \
           | grep -nE '((^|[;&|[:space:]])(read|declare|typeset|local)([[:space:]]+-[A-Za-z]+)*[[:space:]]+ROOT([[:space:]]|=|$)|printf[[:space:]]+-v[[:space:]]+ROOT|(^|[;&|[:space:]])eval([[:space:]]|$))' || true)"
    [ -n "$hit" ] && report \
      "apps/$rel: rebinds \$ROOT through read/declare/printf -v, or uses eval, in a file that reads the platform. The root must come from the one \${AIRLOCK_ROOT:?...} assignment and stay there; a second binding makes the first one decorative." \
      "$hit"
  fi

  # 3. AIRLOCK_ROOT with a default instead of a requirement.
  hit="$(printf '%s\n' "$code" | grep -nE '\$\{AIRLOCK_ROOT:-' || true)"
  [ -n "$hit" ] && report \
    "apps/$rel: AIRLOCK_ROOT carries a default. It is a required ABI variable — use \${AIRLOCK_ROOT:?...} so a missing ABI fails here instead of resolving to the wrong tree." \
    "$hit"

  # 4. Any other platform path, keyed on the DIRECTORY the path names rather than
  #    on the variable in front of it — an app that reads $PLATFORM/bin/airlock-config
  #    is doing the same thing as one that reads $ROOT/bin/airlock-config, and only
  #    this shape catches both. `apps/` is here because a package reaching its own
  #    files that way is using the one route the cutover removes.
  #
  #    The directory names are the ones the PLATFORM has and a package does not.
  #    Measured, not guessed: no package holds a subdirectory named install, gate,
  #    live, schemas, policy, apps, hub, docker or mac. `bin/` is deliberately
  #    absent from that list because four packages DO have one
  #    (code-server, devterm, orca, paseo/browse-host), so keying on it flags
  #    `$HERE/bin/devterm-shell` — a package reading its own file, which is the
  #    thing the ABI is for. The platform account/config/secret entry points under
  #    bin/ are named explicitly instead: apps receive their paths through the ABI
  #    and must not derive them from the platform root.
  hit="$(printf '%s\n' "$code" \
    | sed -e 's/["'"'"']//g' -e 's|//*|/|g' -e 's|/\./|/|g' \
    | grep -noE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/((install|gate|apps|live|schemas|policy|hub|docker|mac)/[A-Za-z0-9_./-]+|bin/airlock-(config|accounts|secret))' \
    | grep -vE '/(install/lib\.sh|gate/[A-Za-z0-9_.-]+)$' || true)"
  [ -n "$hit" ] && report \
    "apps/$rel: reads a platform path that is not in the D5 ABI. Only install/lib.sh and gate/* are contract; a platform internal must be exposed as a lib.sh function first, and a package must reach its own files through AIRLOCK_APP_DIR." \
    "$hit"
done

# WHAT THIS GATE DOES NOT DECIDE. Static reading of shell is not complete, and the
# allowlist above narrows rather than closes that. It cannot see a path assembled
# at runtime from data, a cwd-relative source with no variable in it, or anything
# behind an indirect expansion. Those are covered from the other side, by running
# the real script: install/test-render-parity.sh executes apps/paseo/browse-host's
# nested installer with AIRLOCK_ROOT unset and asserts it refuses, and with
# AIRLOCK_APP_DIR polluted and asserts it still finds its own files. A static gate
# and a runtime probe fail differently, which is the point of having both.

if [ "$fails" -gt 0 ]; then
  echo "FAIL check-app-abi: $fails violation(s) in $SCAN" >&2
  exit 1
fi
echo "ok check-app-abi: ${#files[@]} shell file(s) under $SCAN reach the platform only through the D5 ABI"
