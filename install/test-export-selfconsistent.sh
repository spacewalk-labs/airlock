#!/usr/bin/env bash
# install/test-export-selfconsistent.sh — the tree we PUBLISH has to be able to run
# itself.
#
# The boundary in install/public-manifest.sh is per-file, and that is right for deciding
# audience. But some invariants live ACROSS files, and a per-file decision cannot see
# them. One of them is fatal:
#
#   bin/airlock-config carries BUNDLE_ENTITLEMENTS, a table that
#   _assert_bundle_policy_parity() requires to match apps/ EXACTLY, fail-closed.
#
# So holding one app directory back while shipping bin/ — two individually reasonable
# calls — produced a public tree whose own validator refuses to start:
#
#   airlock-config: bundled entitlement table does not exactly match apps/:
#   policy entries without bundled apps: ['learning']
#
# 🔴 That shipped. Measured 2026-08-22 on a real operator's box: the update replaced the
# files, the installer died at the first validate, and the box was left with the new tree
# and the old services. Every box that took that release stopped at the same line — and
# the private CI was green throughout, because the private tree HAS apps/learning.
#
# What this gate adds is the one question no per-file check can ask: after pruning, does
# the artefact still work? It builds the export the release actually builds and runs the
# real validator on it.
#
# Offline: git archive + the repo's own scripts. No network, nothing installed.
set -uo pipefail
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0 fail=0
ok()  { printf 'ok   export: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL export: %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
EXPORT="$scratch/export"; mkdir -p "$EXPORT"

# The same two steps the release performs, in the same order.
git -C "$ROOT" archive HEAD | tar -x -C "$EXPORT" 2>/dev/null \
  || { echo "FAIL export: could not build the export tree" >&2; exit 2; }
while IFS= read -r p; do rm -f "${EXPORT:?}/$p"; done \
  < <(bash "$EXPORT/install/public-manifest.sh" --prune-list --dir "$EXPORT")
find "$EXPORT" -type d -empty -delete

[ -x "$EXPORT/bin/airlock-config" ] || [ -f "$EXPORT/bin/airlock-config" ] \
  || { echo "FAIL export: the export has no bin/airlock-config to run" >&2; exit 2; }

# `catalog` is the right probe: it is the one subcommand that answers with no
# airlock.toml, and it runs the bundle-parity assertion on the way. A command that
# needed a config would fail for a reason that has nothing to do with the export.
out="$(cd "$EXPORT" && AIRLOCK_CONFIG=/dev/null timeout 60 python3 bin/airlock-config catalog 2>&1)"
rc=$?
if [ "$rc" = 0 ]; then
  ok "the pruned tree can run its own airlock-config"
else
  bad "the pruned tree cannot run its own airlock-config (rc=$rc): $(printf '%s' "$out" | head -2)"
fi

# The specific invariant, named, so a failure says WHICH thing diverged rather than
# only that something did.
# The specific invariant, named, so a failure says WHICH thing diverged rather than
# only that something did. Parsed, not grep'ed: a line-range grep also picks up the
# capability strings inside each entry and reports them as phantom apps.
diff_out="$(cd "$EXPORT" && python3 - <<'PYEOF' 2>/dev/null
import ast, pathlib
src = pathlib.Path("bin/airlock-config").read_text(encoding="utf-8")
policy = set()
for node in ast.walk(ast.parse(src)):
    target = None
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        target = node.target.id
    elif isinstance(node, ast.Assign) and node.targets and isinstance(node.targets[0], ast.Name):
        target = node.targets[0].id
    if target == "BUNDLE_ENTITLEMENTS" and isinstance(node.value, ast.Dict):
        policy = {k.value for k in node.value.keys if isinstance(k, ast.Constant)}
        break
physical = {p.name for p in pathlib.Path("apps").iterdir() if p.is_dir()}
print("TABLE_ONLY:" + ",".join(sorted(policy - physical)))
print("APPS_ONLY:" + ",".join(sorted(physical - policy)))
PYEOF
)"
table_only="$(printf '%s\n' "$diff_out" | sed -n 's/^TABLE_ONLY://p')"
apps_only="$(printf '%s\n' "$diff_out" | sed -n 's/^APPS_ONLY://p')"
if [ -z "$table_only" ] && [ -z "$apps_only" ]; then
  ok "the entitlement table and apps/ agree in the export"
else
  bad "entitlement table vs apps/ in the export — 표에만: ${table_only:-없음} | apps/ 에만: ${apps_only:-없음}"
fi

# Positive control. Without it, both checks above pass just as happily on a tree where
# the prune step silently did nothing — and that is exactly the shape of the bug they
# exist to catch, so a green here would mean nothing.
probe="$scratch/probe"; cp -r "$EXPORT" "$probe"
rm -rf "$probe/apps/$(cd "$EXPORT/apps" && ls -d */ | head -1 | tr -d /)"
if (cd "$probe" && AIRLOCK_CONFIG=/dev/null timeout 60 python3 bin/airlock-config catalog >/dev/null 2>&1); then
  bad "positive control: removing an app directory did NOT break the validator — this gate cannot see the defect it exists for"
else
  ok "positive control: removing one app directory really does break the validator"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
