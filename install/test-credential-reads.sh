#!/usr/bin/env bash
# install/test-credential-reads.sh — controls for check-credential-reads.sh.
#
# The live gate is green in P3: dev-monitor and learning use the platform CLI. These
# scratch package trees prove each forbidden spelling can really turn the gate red,
# while clean packages and prose look-alikes stay green. The live-tree case pins that
# completed state rather than accepting an arbitrary rc=0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/check-credential-reads.sh"
pass=0; fail=0
ok()  { echo "ok   credential-reads: $1"; pass=$((pass+1)); }
bad() { echo "FAIL credential-reads: $1"; fail=$((fail+1)); }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# Each case is one package tree holding one source file, scanned on its own, so
# a verdict can never be attributed to another fixture. Setup is asserted before
# the gate runs: rc=1 without the gate's verdict line is a broken harness, not a
# positive control.
scan() {  # scan <case> <relative-path> <source-body>
  local name="$1" path="$2" body="$3"
  local d="$FIX/$name"
  mkdir -p "$d/$(dirname "$path")" \
    || { echo "FIXTURE-SETUP-FAILED mkdir"; return; }
  printf '%s\n' "$body" > "$d/$path" \
    || { echo "FIXTURE-SETUP-FAILED write"; return; }
  chmod +x "$d/$path" 2>/dev/null || :
  [ -s "$d/$path" ] || { echo "FIXTURE-SETUP-FAILED empty"; return; }
  local out; out="$(bash "$GATE" --dir "$FIX/$name" 2>&1)"
  printf 'rc=%s\n%s\n' "$?" "$out"
}

refuses() {  # refuses <case> <relative-path> <source-body> <what>
  local r; r="$(scan "$1" "$2" "$3")"
  if grep -q '^rc=1$' <<<"$r" \
     && grep -q '^FAIL check-credential-reads: [1-9]' <<<"$r" \
     && grep -q '^::error::apps/.\+:[0-9]\+:' <<<"$r"; then
    ok "refuses $4"
  else
    bad "accepted $4 — or the fixture never ran: $(tr '\n' ' ' <<<"$r")"
  fi
}

accepts() {  # accepts <case> <relative-path> <source-body> <what>
  local r; r="$(scan "$1" "$2" "$3")"
  if grep -q '^rc=0$' <<<"$r" \
     && grep -qE '^ok check-credential-reads: [1-9][0-9]* shell/Python file' <<<"$r"; then
    ok "accepts $4"
  else
    bad "refused $4 — or the fixture never ran: $(tr '\n' ' ' <<<"$r")"
  fi
}

# ---------------------------------------------------------- positive controls
# shellcheck disable=SC2016  # fixture source is literal; the scratch shell expands it
refuses pool install.sh '#!/usr/bin/env bash
cp "$HOME/.claude-accounts/active.json" /tmp/account.json' \
  'a shell package reading ~/.claude-accounts'

refuses claude_live backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
print((Path.home() / ".claude" / ".credentials.json").read_text())' \
  'Python reading .claude/.credentials.json through pathlib composition'

refuses claude_legacy backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
print((Path.home() / ".claude.json").read_text())' \
  'Python reading .claude.json'

refuses codex backend/probe.py '#!/usr/bin/env python3
import json, os
print(json.load(open(os.path.join(os.environ["HOME"], ".codex/auth.json"))))' \
  'Python reading .codex/auth.json'

# shellcheck disable=SC2016  # fixture source is literal; the scratch shell expands it
refuses grok install.sh '#!/usr/bin/env bash
test -r "$HOME/.grok/auth.json"' \
  'shell reading .grok/auth.json'

refuses codex_quote_split install.sh '#!/usr/bin/env bash
test -r "$HOME/.codex"/auth.json' \
  'shell reading .codex/auth.json with the quote closed before the filename'

refuses opencode backend/probe.py '#!/usr/bin/env python3
import os
print(open(os.path.join(os.environ["HOME"], ".local/share/opencode/auth.json")).read())' \
  'Python reading opencode/auth.json'

# This is the exact split spelling in dev-monitor: neither physical line holds
# the forbidden path, but the two assignments still resolve to one direct read.
refuses split_join backend/probe.py '#!/usr/bin/env python3
import os
def credential(home):
    base = os.path.join(home, ".claude")
    return open(os.path.join(base, ".credentials.json")).read()' \
  'a Python path assembled across two os.path.join calls'

# Extensionless env-dispatched shell is real package surface in this repository;
# checking *.sh alone would make shell coverage silently incomplete.
# shellcheck disable=SC2016  # fixture source is literal; the scratch shell expands it
refuses noext_shell bin/probe '#!/usr/bin/env bash
test -r "$HOME/.codex/auth.json"' \
  'a violation in an extensionless env-dispatched shell program'

refuses path_args backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
print(Path(Path.home(), ".codex", "auth.json").read_text())' \
  'a credential path passed as several Path constructor arguments'

refuses dot_segment backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
print((Path.home() / ".codex" / "." / "auth.json").read_text())' \
  'a credential path containing a redundant dot segment'

refuses module_constant backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
CLAUDE_DIR = ".claude"
def credential():
    return (Path.home() / CLAUDE_DIR / ".credentials.json").read_text()' \
  'a module path component combined inside a function'

# ---------------------------------------------------------- negative controls
accepts cli backend/probe.py '#!/usr/bin/env python3
import os, subprocess
subprocess.run([os.environ["AIRLOCK_ACCOUNTS_BIN"], "list", "--json"], check=True)' \
  'a package calling the platform account CLI handed in through the ABI'

accepts generic backend/probe.py '#!/usr/bin/env python3
from pathlib import Path
print((Path("fixtures") / "auth.json").read_text())' \
  'an unrelated package-local auth.json'

accepts prose backend/probe.py '#!/usr/bin/env python3
"""Do not read ~/.claude/.credentials.json or ~/.codex/auth.json directly."""
# ~/.claude-accounts is platform-owned too.
print("clean")' \
  'Python comments and docstrings that explain the rule'

accepts shell_prose install.sh '#!/usr/bin/env bash
# Never read ~/.claude/.credentials.json or opencode/auth.json from an app.
echo clean' \
  'shell comments that explain the rule'

# No app path has an allowance, including a similarly named devterm file.
refuses writer_neighbor devterm/backend/other.py '#!/usr/bin/env python3
from pathlib import Path
print((Path.home() / ".claude.json").read_text())' \
  'a devterm file is held to the same platform-only boundary'

# Missing and empty scans are errors rather than silent passes.
bash "$GATE" --dir "$FIX/missing" >/dev/null 2>&1; rc=$?
mkdir -p "$FIX/empty"; bash "$GATE" --dir "$FIX/empty" >/dev/null 2>&1; rc2=$?
if [ "$rc" = 2 ] && [ "$rc2" = 2 ]; then
  ok "a missing or empty --dir is an error, not a silent pass"
else
  bad "empty scan did not error (missing rc=$rc, empty rc=$rc2)"
fi

# ------------------------------------------------------------ the live green set
# P3's completion signal is the real apps tree returning the gate's success verdict.
live="$(bash "$GATE" 2>&1)"; live_rc=$?
if [ "$live_rc" = 0 ] \
   && grep -q '^ok check-credential-reads: [1-9][0-9]* shell/Python file' <<<"$live"; then
  ok "the live apps tree reaches provider credentials only through the platform ABI"
else
  bad "the live credential ownership gate is not green (rc=$live_rc): $live"
fi

echo "---"
echo "credential-reads: $pass ok, $fail failed"
[ "$fail" = 0 ]
