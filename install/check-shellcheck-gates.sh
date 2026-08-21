#!/usr/bin/env bash
# install/check-shellcheck-gates.sh — the ShellCheck verdicts this repo may not discard.
#
# Why this file exists at all:
#
#   .github/workflows/ci.yml has run ShellCheck since the beginning, and ends the
#   line with `|| true   # TODO: drop \`|| true\` once scripts land`. On 2026-08-07 a
#   backtick inside an unquoted heredoc in apps/paseo/render.sh executed at install
#   time, deleted three words from every rendered paseo unit, and shipped. ShellCheck
#   had been reporting it as SC2006 the whole time. The detector was not missing —
#   its verdict was being thrown away, with a note saying so.
#
# So this is not a new detector. It is the same one, with the `|| true` removed for
# the two verdicts we are prepared to keep green today, run as its own script so it
# can be pointed at a fixture and proven to fail (install/test-shellcheck-gates.sh).
#
# The two rules, and why exactly these:
#
#   1. SC2006 (legacy backticks), everywhere. Measured on 14cd23a: three findings
#      tree-wide, all of them the paseo bug. Zero cleanup cost, and inside an
#      unquoted heredoc the "style" issue is not style — it is command substitution
#      in text that was meant to be a comment.
#   2. `-S style`, on apps/*/render.sh only. These files are heredoc bodies almost
#      end to end, which is where quoting mistakes stop being cosmetic. Measured:
#      3 findings (the same three), against 414 for the whole tree at the same
#      severity. The owner scoped the remaining 411 out; that is a separate task,
#      recorded in docs/tasks/active/live-verification-and-recurrence-gates.md, and
#      the global `|| true` stays until it is done rather than being quietly widened
#      here.
#
# Usage:
#   check-shellcheck-gates.sh              scan this repository
#   check-shellcheck-gates.sh FILE...      scan exactly these files (used by the test
#                                          suite to drive positive/negative controls)
#
# A file is subject to rule 2 when its basename is render.sh — by name, so a fixture
# can exercise the rule without living under apps/.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

command -v shellcheck >/dev/null 2>&1 || {
  # Not a skip. A gate that quietly does nothing when its tool is absent is the
  # shape this whole file exists to remove.
  echo "FAIL shellcheck-gates: shellcheck is not installed — this gate cannot report a verdict" >&2
  exit 2
}

files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # Tracked *.sh under the shipped trees, plus the extensionless bash scripts in
  # bin/. The extension is not the contract: bin/airlock-smoke is bash with no
  # suffix, and the same blind spot in the python-compile step is why
  # bin/airlock-config had never been compiled by CI (see ci.yml's note there).
  #
  # --others --exclude-standard alongside --cached, for the same reason the leak
  # scan passes --untracked: in CI nothing is untracked and it changes nothing, and
  # locally it is the difference between scanning the file you just wrote and
  # scanning the one you committed last time. A new renderer would otherwise be
  # exempt from this gate right up until the moment it stopped being new.
  while IFS= read -r f; do files+=("$ROOT/$f"); done < <(
    git -C "$ROOT" ls-files --cached --others --exclude-standard \
      -- 'bin/*' 'install/*' 'gate/*' 'apps/*' 'hub/*' 'live/*' \
      | while IFS= read -r rel; do
          case "$rel" in
            *.sh) printf '%s\n' "$rel" ;;
            *) [ -f "$ROOT/$rel" ] \
                 && head -1 "$ROOT/$rel" 2>/dev/null | grep -q '^#!.*bash' \
                 && printf '%s\n' "$rel" ;;
          esac
        done
  )
fi

[ "${#files[@]}" -gt 0 ] || { echo "FAIL shellcheck-gates: no files to scan" >&2; exit 2; }

renders=()
for f in "${files[@]}"; do
  [ "$(basename "$f")" = "render.sh" ] && renders+=("$f")
done

status=0

# Rule 1 — SC2006 everywhere.
# -x follows `source`d files so a library's own findings are attributed to it, not
# suppressed. --include restricts the report to this one check, so widening the
# rule set is a deliberate edit here rather than an accident of a shellcheck upgrade.
out="$(shellcheck -x --include=SC2006 -f gcc "${files[@]}" 2>&1)" || true
if [ -n "$out" ]; then
  printf '%s\n' "$out"
  echo "FAIL shellcheck-gates: legacy backticks (SC2006). Inside an unquoted heredoc these RUN."
  status=1
else
  echo "ok   shellcheck-gates: no legacy backticks in ${#files[@]} files (SC2006)"
fi

# Rule 2 — full style severity, renderers only.
if [ "${#renders[@]}" -gt 0 ]; then
  out="$(shellcheck -x -S style -f gcc "${renders[@]}" 2>&1)" || true
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "FAIL shellcheck-gates: style findings in a renderer. These files are heredoc bodies; quoting is behaviour here."
    status=1
  else
    echo "ok   shellcheck-gates: ${#renders[@]} renderers clean at -S style"
  fi
fi

exit "$status"
