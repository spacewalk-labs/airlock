#!/usr/bin/env bash
# install/test-app-abi.sh — controls for install/check-app-abi.sh.
#
# The gate says an app package reaches the platform only through the D5 ABI, and
# it says so by scanning for three shapes. A scan that returns zero because its
# pattern no longer matches looks exactly like a tree that is clean, and this
# gate is the thing standing between the apps/ cutover and a package that quietly
# stops working once it leaves the platform tree. So each banned shape gets a
# positive control (a fixture that really is bad and must be refused) and the
# permitted look-alikes get negative controls (they must be accepted).
#
# The fixtures are written to a temp dir rather than committed under apps/: a bad
# fixture living in the real tree would be found by the gate's own default scan,
# and the first move would be to add an exclusion — which is how a gate stops
# gating. `--dir` exists for exactly this, and for scanning the apps repository
# after the cutover.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$HERE/check-app-abi.sh"
pass=0; fail=0
ok()  { echo "ok   app-abi: $1"; pass=$((pass+1)); }
bad() { echo "FAIL app-abi: $1"; fail=$((fail+1)); }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# Each case is one package tree holding one script, scanned on its own, so a
# result can never be attributed to the wrong fixture.
# Fixture setup is asserted, not assumed. An earlier version returned only the
# gate's exit code, and `refuses` accepted ANY rc=1 — so with an unwritable
# TMPDIR the redirect failed, bash returned 1 without ever running the gate, and
# every positive control printed `ok`. A control that passes when the harness is
# broken is the failure it exists to detect, wearing the harness's clothes.
# So: the fixture write is checked, and the VERDICT LINE is matched, not the rc.
scan() {  # scan <case> <ext> <script-body>
  local name="$1" ext="$2" body="$3"
  local d="$FIX/$name/pkg"   # separate statement: under `set -u`, a name declared
                             # by `local` is not yet readable inside that same local
  mkdir -p "$d" || { echo "FIXTURE-SETUP-FAILED mkdir"; return; }
  printf '%s\n' "$body" > "$d/install$ext" || { echo "FIXTURE-SETUP-FAILED write"; return; }
  chmod +x "$d/install$ext" 2>/dev/null || :
  [ -s "$d/install$ext" ] || { echo "FIXTURE-SETUP-FAILED empty"; return; }
  local out; out="$(bash "$GATE" --dir "$FIX/$name" 2>&1)"
  printf 'rc=%s\n%s\n' "$?" "$out"
}

refuses() {  # refuses <case> <script-body> <what> [ext]
  local r; r="$(scan "$1" "${4-.sh}" "$2")"
  # rc AND the gate's own FAIL line, so a harness failure (rc=1, no output) and a
  # gate failure for an unrelated reason (rc=2) are both distinguishable from a hit.
  if grep -q '^rc=1$' <<<"$r" && grep -q '^FAIL check-app-abi: [1-9]' <<<"$r"; then
    ok "refuses $3"
  else
    bad "accepted $3 — or the fixture never ran: $(tr '\n' ' ' <<<"$r")"
  fi
}

accepts() {  # accepts <case> <script-body> <what> [ext]
  local r; r="$(scan "$1" "${4-.sh}" "$2")"
  # rc AND the gate's ok line naming a non-zero file count, so "accepted" can
  # never mean "scanned nothing".
  if grep -q '^rc=0$' <<<"$r" && grep -qE '^ok check-app-abi: [1-9][0-9]* shell file' <<<"$r"; then
    ok "accepts $3"
  else
    bad "refused $3 — or the fixture never ran: $(tr '\n' ' ' <<<"$r")"
  fi
}

# ---------------------------------------------------------- positive controls
# 1. Climbing out of the package to reach the platform. This is THE legacy shape:
#    it resolves to the platform only while the package sits in the platform's
#    own apps/ tree, and after the cutover it resolves somewhere else in silence.
refuses climb '#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/install/lib.sh"' 'a package that computes the platform root by climbing "../.."'

# The same climb one level deeper — apps/paseo/browse-host/install.sh really did
# carry "../../.." and a pattern pinned to two levels would have walked past it.
refuses climb3 '#!/usr/bin/env bash
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"
. "$ROOT/install/lib.sh"' 'a deeper "../../.." climb (the browse-host shape)'

# 2. A defaulted AIRLOCK_ROOT, which reintroduces the climb through the back door.
refuses defaulted '#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-/opt/airlock}"
. "$ROOT/install/lib.sh"' 'AIRLOCK_ROOT carrying a default instead of :?'

# 3a. A platform internal that is not in the ABI. The real case: apps/paseo read
#     install/resource-holder-pids.py directly, and it is now a lib.sh function.
refuses internal '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT/install/lib.sh"
python3 "$ROOT/install/resource-holder-pids.py" pidfile /tmp/x' \
  'reading a platform internal (install/resource-holder-pids.py) by path'

# 3b. The platform config binary, likewise internal — airlock_config is the ABI.
refuses configbin '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
"$ROOT/bin/airlock-config" get apps.x.y' 'reading bin/airlock-config by path'

# The account and secret CLIs are handed to packages through named ABI variables,
# exactly like config is exposed through airlock_config. Deriving either from the
# platform root bypasses that contract even though the file lives under bin/.
refuses accountsbin '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
"$ROOT/bin/airlock-accounts" list --json' 'reading bin/airlock-accounts by path'

refuses secretbin '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
"$ROOT/bin/airlock-secret" list' 'reading bin/airlock-secret by path'

refuses accountsbin_quotebreak '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
"$ROOT/bin"/airlock-accounts list --json' \
  'reading bin/airlock-accounts with the quote closed before the filename'

# 3c. A package reaching its OWN files through the platform root. This is what
#     apps/feedback/render.sh did, and the unit it wrote baked the path in.
refuses selfpath '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT/install/lib.sh"
PY="$ROOT/apps/feedback/backend/airlock-feedback.py"' \
  'a package reaching its own files via $ROOT/apps/<id>'

# The climb written other ways. These are not exotic — they are how the same
# mistake reads when someone rewrites the line, and the first version of this
# gate matched only the cd-subshell spelling and let all four through.
refuses climb_twocd '#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && cd .. && pwd)"
. "$ROOT/install/lib.sh"' 'the climb written as two chained cd .. steps'

refuses climb_dirname '#!/usr/bin/env bash
ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"
. "$ROOT/install/lib.sh"' 'the climb written as nested dirname'

refuses climb_strip '#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE%/*/*}"
. "$ROOT/install/lib.sh"' 'the climb written as a suffix strip'

refuses climb_var '#!/usr/bin/env bash
UP="../.."
ROOT="$(cd "$HERE/$UP" && pwd)"
. "$ROOT/install/lib.sh"' 'the climb hidden in a variable'

# The platform path with the quote closing early — the same read, and it walked
# straight through a pattern that required $ROOT and the path to be contiguous.
refuses internal_quotebreak '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT"/install/preflight.sh' 'a platform internal read as "$ROOT"/path'

# A shell program with NO .sh extension. Two of these ship today
# (code-server/bin/airlock-code-server-slot, devterm/bin/devterm-shell) and the
# first version of this gate never opened either of them.
refuses noext '#!/bin/bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/install/lib.sh"' 'a violation in an extensionless shell program (found by shebang)' ''

# ---- round two: what an ASSIGNMENT-site rule let through ----
# These ten are not invented. A second adversarial pass produced every one of them
# against a gate that checked how $ROOT was assigned, and each one reached the
# platform anyway. They are the reason the gate became an allowlist: no blocklist
# survived two rounds, and there was no reason to believe it would survive a third.

refuses ev_no_variable '#!/bin/bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(cd "$HERE/../.." && pwd)/install/lib.sh"' 'sourcing the platform with no variable at all'

refuses ev_read_rebind '#!/bin/bash
ROOT="${AIRLOCK_ROOT:?}"
read -r ROOT < /tmp/x
. "$ROOT/install/lib.sh"' 'a correct assignment rebound afterwards by read'

refuses ev_printf_rebind '#!/bin/bash
ROOT="${AIRLOCK_ROOT:?}"
printf -v ROOT "%s" "$(cd "$HERE/../.." && pwd)"
. "$ROOT/install/lib.sh"' 'a correct assignment rebound afterwards by printf -v'

refuses ev_if_branch '#!/bin/bash
if true; then ROOT=$(cd "$HERE/../.." && pwd); fi
. "$ROOT/install/lib.sh"' 'an assignment tucked inside an if-branch on one line'

refuses ev_array '#!/bin/bash
R[0]="$(cd "$HERE/../.." && pwd)"
. "${R[0]}/install/lib.sh"' 'the root parked in an array element'

refuses ev_chained '#!/bin/bash
HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM_APPS="$(cd "$HERE/../.." && pwd)"
. "$PLATFORM_APPS/../install/lib.sh"' 'an accepted within-package climb extended one level to escape'

refuses ev_continuation '#!/bin/bash
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT"/\
install/preflight.sh' 'a platform path split across a backslash continuation'

refuses ev_source_kw '#!/bin/bash
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/install/lib.sh"' 'the same read written with `source` instead of `.`'

refuses ev_eval '#!/bin/bash
ROOT="${AIRLOCK_ROOT:?}"
eval ROOT=/somewhere
. "$ROOT/install/lib.sh"' 'eval in a file that reads the platform'

refuses ev_othervar '#!/bin/bash
PLAT="${AIRLOCK_ROOT:?}"
python3 "$PLAT/bin/airlock-config" get x' 'a platform internal read through a differently-named variable'

# ---------------------------------------------------------- negative controls
# The ABI itself must not be flagged, or the gate is unusable and gets disabled.
accepts abi '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?the D5 ABI is required}"
HERE="${AIRLOCK_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:?}"
. "$ROOT/install/lib.sh"
. "$ROOT/gate/nginx-lib.sh"
. "$HERE/render.sh"
python3 "$HERE/backend/thing.py"' 'the D5 ABI itself (lib.sh, gate/, AIRLOCK_APP_DIR)'

# Climbing WITHIN the package is self-location too, and must be accepted. This is
# apps/orca/bin/verify-web-bundle.sh's real shape — it steps from bin/ up to the
# package root to find web-bundle/, and that stays correct after the cutover
# because the whole package moves together. An earlier rule banned the ".." path
# segment outright and turned this file red, which is what forced the gate onto
# the actual invariant (a platform read must come from AIRLOCK_ROOT) instead of
# onto syntax.
accepts climb_inside '#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$HERE/.." && pwd)/web-bundle"
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT/install/lib.sh"' 'a package climbing one level to reach its own sibling directory'

# $0-relative SELF-location is not the banned shape: it points at the package,
# which moves with the package. Only climbing OUT of it is legacy.
accepts selfloc '#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/backend/thing.py"' 'a package locating its own directory from $0'

# A package's own bin/ stays package-local surface. Rule 4 deliberately names
# the three platform files instead of banning bare bin/, so this must stay green.
accepts own_bin '#!/usr/bin/env bash
HERE="${AIRLOCK_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
"$HERE/bin/something" --help' 'a package reading its own $HERE/bin/<something>'

# The whole canonical preamble at once, including the two shapes rule 4 must not
# flag: a within-package climb, and a package reading its own bin/ (four packages
# ship one, which is why `bin/` is not in the platform-directory list).
accepts canonical_all '#!/usr/bin/env bash
ROOT="${AIRLOCK_ROOT:?required}"
HERE="${AIRLOCK_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:?}"
. "$ROOT/install/lib.sh"
. "$ROOT/gate/nginx-lib.sh"
BUNDLE="$(cd "$HERE/.." && pwd)/web-bundle"
cp "$HERE/bin/devterm-shell" /tmp/' 'the full canonical preamble, a package bin/, and a within-package climb together'

# Prose describing the banned idioms must not trip the gate — every app script
# now carries an ABI comment that names "../..", and so does this suite.
accepts prose '#!/usr/bin/env bash
# The platform root cannot be derived from "$(cd "$HERE/../.." && pwd)" once the
# package leaves the tree, and ${AIRLOCK_ROOT:-anything} is the same mistake.
ROOT="${AIRLOCK_ROOT:?}"
. "$ROOT/install/lib.sh"' 'comments that describe the banned idioms'

# ---------------------------------------------------------- the live tree
# The gate must be green on the real apps/, and must have actually looked at it:
# an empty scan is a broken scan, so the count is asserted, not printed.
live="$(bash "$GATE" 2>&1)"; live_rc=$?
[ "$live_rc" = 0 ] \
  && ok "the shipped apps/ tree passes" \
  || bad "the shipped apps/ tree fails: $live"
n="$(printf '%s' "$live" | sed -n 's/^ok check-app-abi: \([0-9]*\) shell file.*/\1/p')"
{ [ -n "$n" ] && [ "$n" -ge 30 ]; } \
  && ok "the scan really read the tree ($n shell files, not an empty set)" \
  || bad "the scan reported an implausible file count: ${n:-<none>}"

# An empty directory is an error, not a pass — the shape a --dir typo takes.
bash "$GATE" --dir "$FIX/empty-dir" >/dev/null 2>&1; rc=$?
mkdir -p "$FIX/empty"; bash "$GATE" --dir "$FIX/empty" >/dev/null 2>&1; rc2=$?
{ [ "$rc" = 2 ] && [ "$rc2" = 2 ]; } \
  && ok "a missing or empty --dir is an error, not a silent pass" \
  || bad "empty scan did not error (missing rc=$rc, empty rc=$rc2)"

# ---------------------------------------------------------- the gate's scope
# The gate reads *.sh. That is only sufficient while non-shell app files do not
# reach the platform tree, which was measured true when it was written — assert
# it, so the day a backend starts reading AIRLOCK_ROOT the gate gets widened on
# purpose instead of silently covering less than it claims.
nonshell="$(grep -rlE 'AIRLOCK_ROOT|/install/lib\.sh' "$ROOT/apps" \
  --include='*.py' --include='*.mjs' --include='*.js' --include='*.cjs' 2>/dev/null \
  | grep -v '/patches/' | grep -v '/node_modules/' || true)"
[ -z "$nonshell" ] \
  && ok "no non-shell app file reaches the platform tree (the *.sh scope still covers everything)" \
  || bad "non-shell app files now reach the platform tree — widen check-app-abi.sh to cover them: $nonshell"

# And the control for that control: the pattern must be able to find something.
probe="$FIX/scope-probe"; mkdir -p "$probe/pkg"
printf 'import os\nr = os.environ["AIRLOCK_ROOT"]\n' > "$probe/pkg/backend.py"
[ -n "$(grep -rlE 'AIRLOCK_ROOT|/install/lib\.sh' "$probe" --include='*.py' 2>/dev/null)" ] \
  && ok "the non-shell scope probe is capable of finding a hit (positive control)" \
  || bad "the non-shell scope probe found nothing in a file that plainly matches"

# CI has to run this, or none of the above is load-bearing.
# Matched as an executable `run:` line, not as a substring: the comments above
# each step name the same paths, so a plain grep stays green after someone
# deletes the steps and leaves the prose explaining them.
grep -qE '^ +run: bash install/check-app-abi\.sh *$' "$ROOT/.github/workflows/ci.yml" \
  && ok "ci.yml runs the gate (as a run: step, not merely mentioned)" \
  || bad "ci.yml has no run: step for install/check-app-abi.sh"
grep -qE '^ +run: bash install/test-app-abi\.sh *$' "$ROOT/.github/workflows/ci.yml" \
  && ok "ci.yml runs this suite (as a run: step, not merely mentioned)" \
  || bad "ci.yml has no run: step for install/test-app-abi.sh"

echo "---"
echo "app-abi: $pass ok, $fail failed"
[ "$fail" = 0 ]
