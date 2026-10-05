#!/usr/bin/env bash
# Offline contract tests for every paseo bundle patch. The fixtures are assembled from
# the small, human-readable reference patches; no @getpaseo bundle, npm, or network is
# involved. Each positive assertion has a deliberately broken-anchor control beside it.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATCH_DIR="$ROOT/apps/paseo/patches"
TMP="$(mktemp -d)" || { echo "FAIL paseo-patch-drift: could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

airlock_test_counters_init

if ! command -v node >/dev/null 2>&1; then
  bad "node is required for paseo patch drift tests"

  printf 'paseo-patch-drift: %s ok, %s failed\n' "$pass" "$fail"
  exit 1
fi

# Reference .patch files contain only the relevant upstream excerpts. Reconstruct their
# preimage into a synthetic target: context + removed lines, never added lines. Keeping
# this source separate from the patcher literals means changing an anchor in the patcher
# makes the positive test fail instead of silently changing the fixture with it.
reference_preimage() {
  local reference="$1" target="$2"
  awk '
    /^@@/ { in_hunk=1; next }
    in_hunk && ($0 ~ /^ / || $0 ~ /^-/) { print substr($0, 2) }
  ' "$reference" > "$target"
}

# image-attachments-persist.patch is a prose reference with Markdown sections rather
# than a unified diff. Its old/context lines have one leading space and new lines have +.
image_preimage() {
  local reference="$1" target="$2"
  awk '
    /^## \([0-9]+\)/ { in_hunk=1; next }
    in_hunk && /^ / { print substr($0, 2) }
  ' "$reference" > "$target"
}

run_js_patch() {
  local patcher="$1" target="$2"
  shift 2
  node "$patcher" "$@" "$target"
}

positive_js() {
  local patcher="$1" target="$2"
  shift 2
  local rc=0
  rm -f "$target.paseo-new.mjs"
  run_js_patch "$patcher" "$target" "$@" >"$target.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$target.paseo-new.mjs" ]; then
    printf '%s\n' "$(cat "$target.log")" | sed 's/^/    /'
    return 1
  fi
  return 0
}

negative_js() {
  local patcher="$1" target="$2" expected_rc="$3" snapshot="$4"
  shift 4
  local positive_rc=0 rc=0
  positive_js "$patcher" "$target" "$@" >/dev/null 2>&1 || positive_rc=$?
  rm -f "$target.paseo-new.mjs"
  run_js_patch "$patcher" "$target" "$@" >"$target.log" 2>&1 || rc=$?
  if [ "$positive_rc" -eq 0 ] || [ "$rc" -ne "$expected_rc" ] \
    || [ -f "$target.paseo-new.mjs" ] || ! cmp -s "$snapshot" "$target" \
    || ! grep -qF 'SKIP:' "$target.log"; then
    printf '    positive assertion rc=%s, expected skip rc=%s, got rc=%s\n' "$positive_rc" "$expected_rc" "$rc"
    sed 's/^/    /' "$target.log"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- manifest
manifest_out="$TMP/manifest.out"
manifest_rc=0
node - "$ROOT" >"$manifest_out" 2>&1 <<'NODE' || manifest_rc=$?
const fs = require("node:fs");
const path = require("node:path");

const root = process.argv[2];
const manifestPath = path.join(root, "apps/paseo/patches/anchor-manifest.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const install = fs.readFileSync(path.join(root, "apps/paseo/install.sh"), "utf8");
const versionMatch = install.match(/PASEO_VER="\$\{AIRLOCK_PASEO_VERSION:-([^}]+)\}"/);
if (!versionMatch || manifest.paseo_version !== versionMatch[1]) {
  throw new Error("anchor manifest version does not match install.sh PASEO_VER");
}

const webPath = path.join(root, "apps/paseo/browse-host/bin/patch-web-ui.js");
const web = fs.readFileSync(webPath, "utf8");
if (!web.includes(`const PINNED_SHA = "${manifest.web_ui.sha256}";`)) {
  throw new Error("anchor manifest web-ui SHA does not match patch-web-ui.js");
}
if (!web.includes(`const PINNED_VERSION = "${manifest.web_ui.version}";`)) {
  throw new Error("anchor manifest web-ui version does not match patch-web-ui.js");
}
// The manifest's shape table must mirror patch-web-ui.js exactly. Compared as data,
// not by grepping for constant names: the shapes ARE the pin, and a manifest that
// merely looks similar would let a box in an unlisted state be refused at install
// time on a box nobody tested. Order-insensitive on the edits within a shape, since
// the eight edit sites are disjoint and the set is what identifies the bytes.
const patcher = require(webPath);
const shapeKey = (sha256, edits, legacyShas = []) =>
  `${sha256}:${[...legacyShas].sort().join(",")}:${[...edits].sort().join("|")}`;
const manifestShapes = (manifest.web_ui.shapes ?? []).map((shape) =>
  shapeKey(shape.sha256, shape.edits, shape.legacy_sha256s));
const patcherShapes = patcher.KNOWN_BUNDLE_SHAPES.map((shape) =>
  shapeKey(shape.sha, shape.edits, shape.legacyShas));
if (manifestShapes.length !== patcherShapes.length
    || [...manifestShapes].sort().join("\n") !== [...patcherShapes].sort().join("\n")) {
  throw new Error("anchor manifest shape table does not match patch-web-ui.js KNOWN_BUNDLE_SHAPES");
}
// Every edit a shape names must be a real anchor in one of the two groups, or the
// shape can never match and the box carrying it is refused for no reason.
const editNames = new Set([
  ...patcher.SUBAGENT_STREAM_PATCHES.map((patch) => patch.name),
  ...patcher.BROWSE_PATCHES.map((patch) => patch.name),
]);
for (const shape of manifest.web_ui.shapes) {
  for (const edit of shape.edits) {
    if (!editNames.has(edit)) throw new Error(`anchor manifest shape names an unknown edit: ${edit}`);
  }
}
// The tablet "+" fix is an always-on edit, not a browse-group one. It shipped from
// the optional group until 2026-09-01, which silently withheld it from every box
// running the default `browse = false`.
if (!patcher.SUBAGENT_STREAM_PATCHES.some((patch) => patch.name === "project-actions-coarse-pointer")) {
  throw new Error("project-actions-coarse-pointer left the always-on group");
}

const expected = new Set([
  "agent-history-delete-guard",
  "depth4-search",
  "claude-model-prune",
  "codex-model-roster",
  "opencode-grok-defaults",
  "provider-subagent-stream-filter",
  "image-attachments-persist",
  "orphan-process-guard",
  "orphan-process-group",
  "acp-context-gauge",
  "acp-cross-provider-mode-default",
  "acp-model-rejection",
  "acp-agy-shared-catalog",
  "agent-resolve-by-id",
  "archive-consistency",
  "send-keep-pending-permissions",
  "schedule-pending-delivery-schema",
  "schedule-busy-pending-delivery",
  "schedule-stale-due-run",
  "schedule-pending-batch",
  "workspace-git-watch-recovery",
  "workspace-git-identity",
  "workspace-remove-delivery",
  "patch-web-ui",
]);
const seen = new Set();
for (const patch of manifest.patches) {
  seen.add(patch.id);
  const source = fs.readFileSync(path.join(root, patch.source), "utf8");
  for (const anchor of patch.anchors) {
    if (!source.includes(anchor)) {
      throw new Error(`${patch.id}: manifest anchor is absent from ${patch.source}`);
    }
  }
}
if (seen.size !== expected.size || [...expected].some((id) => !seen.has(id))) {
  throw new Error("anchor manifest does not cover exactly the registered paseo patchers");
}
const group = manifest.patches.find((patch) => patch.id === "orphan-process-group");
if (!group.requires || !group.requires.includes("orphan-process-guard")) {
  throw new Error("anchor manifest lost the guard-before-group dependency");
}
const subagent = manifest.patches.find((patch) => patch.id === "provider-subagent-stream-filter");
if (subagent.paired_with !== "patch-web-ui:subagent-stream") {
  throw new Error("provider-subagent server patch lost its always-on web-ui pair");
}
console.log("manifest agrees with the pinned version, SHA, anchors, and ordering");
NODE
if [ "$manifest_rc" -eq 0 ]; then
  ok "anchor manifest: version, shape table, registered patchers, and pair/order contracts"
else
  bad "anchor manifest: version/SHA/coverage/order contract"
  sed 's/^/    /' "$manifest_out"
fi

# --------------------------------------------------------------- Codex model roster
CODEX_DIR="$TMP/codex-roster"
mkdir -p "$CODEX_DIR"
CODEX_FEATURE="$CODEX_DIR/codex-feature-definitions.js"
CODEX_CATALOG="$CODEX_DIR/codex-app-server-agent.js"
cat >"$CODEX_FEATURE" <<'EOF'
const CODEX_FAST_MODE_SUPPORTED_MODELS = new Set([
    "gpt-6-astra",
    "gpt-5.6",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
]);
function normalizeCodexModelId(modelId) {
    const normalized = typeof modelId === "string" ? modelId.trim() : "";
    return normalized.length > 0 ? normalized : null;
}
export function codexModelSupportsFastMode(modelId) {
    const normalizedModelId = normalizeCodexModelId(modelId);
    if (!normalizedModelId) return false;
    return CODEX_FAST_MODE_SUPPORTED_MODELS.has(normalizedModelId);
}
EOF
cat >"$CODEX_CATALOG" <<'EOF'
import { buildCodexFeatures, codexModelSupportsFastMode } from "./codex-feature-definitions.js";
async function fixture(parsedResponse) {
            const models = parsedResponse.success ? (parsedResponse.data.data ?? []) : [];
            return models;
}
void buildCodexFeatures; void codexModelSupportsFastMode; void fixture;
EOF
cp "$CODEX_FEATURE" "$TMP/codex-feature.before"
cp "$CODEX_CATALOG" "$TMP/codex-catalog.before"
codex_ok=1
positive_js "$PATCH_DIR/codex-model-roster.mjs" "$CODEX_FEATURE" feature || codex_ok=0
positive_js "$PATCH_DIR/codex-model-roster.mjs" "$CODEX_CATALOG" catalog || codex_ok=0
if [ "$codex_ok" -eq 1 ]; then
  mv "$CODEX_FEATURE.paseo-new.mjs" "$CODEX_FEATURE"
  mv "$CODEX_CATALOG.paseo-new.mjs" "$CODEX_CATALOG"
  node --check "$CODEX_FEATURE" >/dev/null 2>&1 || codex_ok=0
  node --check "$CODEX_CATALOG" >/dev/null 2>&1 || codex_ok=0
  node "$PATCH_DIR/codex-model-roster.test.mjs" "$CODEX_FEATURE" "$CODEX_CATALOG" >/dev/null 2>&1 || codex_ok=0
fi
if [ "$codex_ok" -eq 1 ]; then
  ok "Codex model roster: dynamic GPT-6 readiness and exact GPT-5.5 retirement"
else
  bad "Codex model roster: behaviour contract"
fi

printf '%s\n' '// drift' >"$CODEX_FEATURE"
if negative_js "$PATCH_DIR/codex-model-roster.mjs" "$CODEX_FEATURE" 20 "$CODEX_FEATURE" feature; then
  ok "Codex model roster: feature anchor drift refuses without a candidate"
else
  bad "Codex model roster: feature drift control"
fi
printf '%s\n' '// drift' >"$CODEX_CATALOG"
if negative_js "$PATCH_DIR/codex-model-roster.mjs" "$CODEX_CATALOG" 20 "$CODEX_CATALOG" catalog; then
  ok "Codex model roster: catalog anchor drift refuses without a candidate"
else
  bad "Codex model roster: catalog drift control"
fi

if grep -qF 'CODEX_ROSTER_PATCHER="$HERE/patches/codex-model-roster.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'Codex model roster verified (GPT-6 Sol/Luna ready; GPT-5.5 retired)' "$ROOT/apps/paseo/install.sh"; then
  ok "Codex model roster: installer wiring is present"
else
  bad "Codex model roster: installer wiring is missing"
fi

# --------------------------------------------------------------------- depth4 inline sed
DEPTH="$TMP/session.js"
DEPTH_ANCHOR='confidentResultScanThreshold: searchesWorkspace ? undefined : 5000,'
DEPTH_LINE='                maxDepth: searchesWorkspace ? undefined : 4,'
printf 'const result = {\n%s\n    includeFiles,\n};\n' "$DEPTH_ANCHOR" > "$DEPTH"
cp "$DEPTH" "$TMP/session-pristine.js"

if grep -qF 'grep -qF "$PATCH_ANCHOR" "$SESSION_JS"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'sed -i "/$(printf' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'maxDepth: searchesWorkspace ? undefined : 4' "$ROOT/apps/paseo/install.sh"; then
  ok "depth4 inline sed: install call site still checks the anchor and inserts the line"
else
  bad "depth4 inline sed: install call site wiring is missing"
fi

apply_depth4_fixture() {
  local target="$1" escaped
  if grep -qF "$DEPTH_LINE" "$target"; then
    return 10
  fi
  if ! grep -qF "$DEPTH_ANCHOR" "$target"; then
    printf 'SKIP: depth4 anchor missing (inline installer sed)\n' >&2
    return 20
  fi
  escaped="$(printf '%s' "$DEPTH_ANCHOR" | sed 's/[.[\*^$]/\\&/g')"
  sed -i "/$escaped/a\\$DEPTH_LINE" "$target" || return 1
  grep -qF "$DEPTH_LINE" "$target"
}

depth_rc=0
apply_depth4_fixture "$DEPTH" >"$TMP/depth.out" 2>&1 || depth_rc=$?
depth_count="$(grep -Fc "$DEPTH_LINE" "$DEPTH" || true)"
if [ "$depth_rc" -eq 0 ] && [ "$depth_count" -eq 1 ]; then
  ok "depth4 inline sed: inserts maxDepth 4 immediately after its anchor"
else
  bad "depth4 inline sed: positive fixture was not patched"
  sed 's/^/    /' "$TMP/depth.out"
fi

DEPTH_BAD="$TMP/session-bad.js"
cp "$TMP/session-pristine.js" "$DEPTH_BAD"
sed -i "/confidentResultScanThreshold/d" "$DEPTH_BAD"
cp "$DEPTH_BAD" "$TMP/session-bad.before"
if apply_depth4_fixture "$DEPTH_BAD" >"$TMP/depth-bad.out" 2>&1; then
  bad "depth4 inline sed negative control: missing anchor was accepted"
else
  depth_bad_rc=0
  apply_depth4_fixture "$DEPTH_BAD" >/dev/null 2>&1 || depth_bad_rc=$?
  if [ "$depth_bad_rc" -eq 20 ] && grep -qF 'SKIP:' "$TMP/depth-bad.out" \
    && cmp -s "$TMP/session-bad.before" "$DEPTH_BAD"; then
    ok "depth4 inline sed negative control: skip is a failed positive assertion (rc 20 classification)"
  else
    bad "depth4 inline sed negative control: missing anchor did not remain an untouched rc 20 skip"
    sed 's/^/    /' "$TMP/depth-bad.out"
  fi
fi

# ------------------------------------------------ provider-subagent source filtering
SUBAGENT_PATCHER="$PATCH_DIR/provider-subagent-stream-filter.mjs"
SUBAGENT_TEST="$PATCH_DIR/provider-subagent-stream-filter.test.mjs"
SUBAGENT_OUT="$TMP/provider-subagent.out"
subagent_rc=0
node "$SUBAGENT_TEST" --self-test "$SUBAGENT_PATCHER" >"$SUBAGENT_OUT" 2>&1 || subagent_rc=$?
if [ "$subagent_rc" -eq 0 ]; then
  ok "provider-subagent server filter: extracted-method matrix, pristine rejection, rc10, and rc20 controls"
else
  bad "provider-subagent server filter: behavior/drift contract"
  sed 's/^/    /' "$SUBAGENT_OUT"
fi

# The server filter and child->parent UI subscription are one correctness unit.
# Assert that main install runs the general group outside the BROWSE=true block, that
# the server candidate is installed only inside the branch where the UI patch
# succeeded (a UI failure discards it — never the new server against the old UI),
# and that browse-host explicitly requests only its optional group. Since 2026-09-12
# a lookup miss (target, anchor, patcher) is a warning, not a platform rollback; only
# the served tree being wrong (invalid JS, failed rename) stays fatal.
if grep -qF 'node "$WEBUI_PATCHER" --subagent-stream "$WEBUI_DIR"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'log "warning: provider-subagent web-ui subscription patch failed' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'die "provider-subagent web-ui patch produced invalid JS"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'die "provider-subagent server filter mv failed"' "$ROOT/apps/paseo/install.sh" \
  && ! grep -qF 'die "session.js not found' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$INSTALL_DIR/bin/patch-web-ui.js" --browse "$WEBUI_DIR"' "$ROOT/apps/paseo/browse-host/install.sh"; then
  ok "provider-subagent install wiring: pair installs together, lookups warn, served-tree faults die, optional browse is explicit"
else
  bad "provider-subagent install wiring: server/UI pair contract or explicit browse mode is missing"
fi
# Ordering, not just presence: the mv must sit inside the UI-success branch.
ui_ok_line="$(grep -nF 'if node "$WEBUI_PATCHER" --subagent-stream "$WEBUI_DIR"; then' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
mv_line="$(grep -nF 'mv "$sf_tmp" "$SESSION_JS"' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
ui_fail_line="$(grep -nF 'log "warning: provider-subagent web-ui subscription patch failed' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
if [ -n "$ui_ok_line" ] && [ -n "$mv_line" ] && [ -n "$ui_fail_line" ] \
  && [ "$ui_ok_line" -lt "$mv_line" ] && [ "$mv_line" -lt "$ui_fail_line" ]; then
  ok "provider-subagent install wiring: server candidate is renamed only after the UI patch succeeded"
else
  bad "provider-subagent install wiring: server candidate rename is not gated on UI success (ui_ok=$ui_ok_line mv=$mv_line ui_fail=$ui_fail_line)"
fi

# ---------------------------------------------------------------------- model prune
PRUNE="$TMP/model-manifest.js"
reference_preimage "$PATCH_DIR/claude-model-prune.patch" "$PRUNE"
printf '    },\n    {\n        id: "claude-sonnet-5",\n        label: "Sonnet 5",\n    },\n];\n' >> "$PRUNE"
if positive_js "$PATCH_DIR/claude-model-prune.mjs" "$PRUNE"; then
  if grep -qF '[airlock-model-prune]' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-opus-4-7' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-opus-4-6' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-sonnet-4-6' "$PRUNE.paseo-new.mjs" \
    && grep -qF 'claude-opus-5' "$PRUNE.paseo-new.mjs" \
    && grep -qF 'id: "claude-opus-5-5",' "$PRUNE.paseo-new.mjs" \
    && grep -qF 'id: "claude-sonnet-5-5",' "$PRUNE.paseo-new.mjs" \
    && grep -qF 'description: "Opus 5 · Previous release",' "$PRUNE.paseo-new.mjs"; then
    ok "model prune: removes superseded IDs, adds Opus and Sonnet 5.5"
  else
    bad "model prune: patched result did not match the intended manifest"
  fi
else
  bad "model prune: representative fixture was not patched"
fi
# Upgrade path of an installed box: a manifest with Opus 5.5 already baked in
# (sentinel present, no Sonnet 5.5) must gain Sonnet, then be final.
PRUNE_OLD="$TMP/model-manifest-old.js"
cp "$PRUNE.paseo-new.mjs" "$PRUNE_OLD"
perl -0pi -e 's/    \{\n        id: "claude-sonnet-5-5",\n.*?\n    \},\n//s' "$PRUNE_OLD"
old_rc=0; node "$PATCH_DIR/claude-model-prune.mjs" "$PRUNE_OLD" >/dev/null 2>&1 || old_rc=$?
again_rc=0
if [ "$old_rc" = 0 ]; then
  node "$PATCH_DIR/claude-model-prune.mjs" "$PRUNE_OLD.paseo-new.mjs" >/dev/null 2>&1 || again_rc=$?
fi
if [ "$old_rc" = 0 ] && grep -qF 'id: "claude-opus-5-5",' "$PRUNE_OLD" \
  && ! grep -qF 'id: "claude-sonnet-5-5",' "$PRUNE_OLD" \
  && grep -qF 'id: "claude-opus-5-5",' "$PRUNE_OLD.paseo-new.mjs" \
  && grep -qF 'id: "claude-sonnet-5-5",' "$PRUNE_OLD.paseo-new.mjs" \
  && node --check "$PRUNE_OLD.paseo-new.mjs" 2>/dev/null && [ "$again_rc" = 10 ]; then
  ok "model prune upgrade: an Opus 5.5 manifest gains Sonnet 5.5"
else
  bad "model prune upgrade: already-pruned manifest (rc=$old_rc, rerun rc=$again_rc) did not converge on Sonnet 5.5"
fi
PRUNE_BAD="$TMP/model-manifest-bad.js"
cp "$PRUNE" "$PRUNE_BAD"
sed -i '/export const CLAUDE_MODEL_MANIFEST = \[/d' "$PRUNE_BAD"
cp "$PRUNE_BAD" "$TMP/model-manifest-bad.before"
if negative_js "$PATCH_DIR/claude-model-prune.mjs" "$PRUNE_BAD" 20 "$TMP/model-manifest-bad.before"; then
  ok "model prune negative control: missing array anchor is an untouched rc 20 skip"
else
  bad "model prune negative control: skipped patch did not fail the positive assertion"
fi

# ---------------------------------------------------------- OpenCode grok defaults
OPENCODE_GROK="$TMP/opencode-agent.js"
reference_preimage "$PATCH_DIR/opencode-grok-defaults.patch" "$OPENCODE_GROK"
if positive_js "$PATCH_DIR/opencode-grok-defaults.mjs" "$OPENCODE_GROK"; then
  if grep -qF '[airlock-opencode-grok-defaults]' "$OPENCODE_GROK.paseo-new.mjs" \
    && grep -qF 'const preferred = ["opencode-go/muse-spark-1.3-contributor", "xai/grok-4.6", "xai/grok-build-0.1"];' "$OPENCODE_GROK.paseo-new.mjs" \
    && grep -qF 'rawVariants.includes("high")' "$OPENCODE_GROK.paseo-new.mjs" \
    && grep -qF 'rawVariants.includes("xhigh")' "$OPENCODE_GROK.paseo-new.mjs"; then
    ok "opencode grok defaults: muse-first picker order, xhigh default, high default"
  else
    bad "opencode grok defaults: patched result did not contain muse/grok order or xhigh/high defaults"
  fi
else
  bad "opencode grok defaults: representative fixture was not patched"
fi
OPENCODE_GROK_BAD="$TMP/opencode-agent-bad.js"
cp "$OPENCODE_GROK" "$OPENCODE_GROK_BAD"
sed -i '/const rawVariants = model.variants/d' "$OPENCODE_GROK_BAD"
cp "$OPENCODE_GROK_BAD" "$TMP/opencode-agent-bad.before"
if negative_js "$PATCH_DIR/opencode-grok-defaults.mjs" "$OPENCODE_GROK_BAD" 20 "$TMP/opencode-agent-bad.before"; then
  ok "opencode grok defaults negative control: missing thinking anchor is an untouched rc 20 skip"
else
  bad "opencode grok defaults negative control: skipped patch did not fail the positive assertion"
fi

# --------------------------------------------------------------- image persistence
IMAGE="$TMP/agent-image.js"
image_preimage "$PATCH_DIR/image-attachments-persist.patch" "$IMAGE"
if positive_js "$PATCH_DIR/image-attachments-persist.mjs" "$IMAGE"; then
  if grep -qF '[paseo-attachments-persist]' "$IMAGE.paseo-new.mjs" \
    && grep -qF 'randomUUID, createHash' "$IMAGE.paseo-new.mjs" \
    && grep -qF 'persistPastedImage(this.config.cwd, chunk, this.logger)' "$IMAGE.paseo-new.mjs" \
    && grep -qF 'Pasted image also saved to' "$IMAGE.paseo-new.mjs"; then
    ok "image persistence: keeps the vision block and appends the saved-path text block"
  else
    bad "image persistence: patched result did not contain the persistence helper/branch"
  fi
else
  bad "image persistence: representative fixture was not patched"
fi
IMAGE_BAD="$TMP/agent-image-bad.js"
cp "$IMAGE" "$IMAGE_BAD"
sed -i '/else if (chunk.type === "image") {/d' "$IMAGE_BAD"
cp "$IMAGE_BAD" "$TMP/agent-image-bad.before"
if negative_js "$PATCH_DIR/image-attachments-persist.mjs" "$IMAGE_BAD" 20 "$TMP/agent-image-bad.before"; then
  ok "image persistence negative control: one branch anchor missing means no partial patch"
else
  bad "image persistence negative control: skipped patch did not fail the positive assertion"
fi

# ---------------------------------------------------------------- orphan process guard
# codex has no fixture here any more: 0.8.0 independently rewrote CodexAppServerSession's
# connect()/close() lifecycle (closed-flag gate at three points, connectionPromise
# de-duplication, identity-checked dispose in every failure branch) -- the patcher only
# accepts "claude" now. See orphan-process-guard.mjs's header for the full comparison.
GUARD_CLAUDE="$TMP/claude-agent.js"
reference_preimage "$PATCH_DIR/orphan-process-guard-claude.patch" "$GUARD_CLAUDE"
if positive_js "$PATCH_DIR/orphan-process-guard.mjs" "$GUARD_CLAUDE" claude \
  && grep -qF '[paseo-orphan-guard]' "$GUARD_CLAUDE.paseo-new.mjs" \
  && grep -qF 'liveChildProcesses' "$GUARD_CLAUDE.paseo-new.mjs" \
  && grep -qF 'ensureQuery() on a closed session' "$GUARD_CLAUDE.paseo-new.mjs"; then
  ok "orphan guard claude: tracks replacements, gates closed spawns, and handles late children"
else
  bad "orphan guard claude: representative fixture was not patched as intended"
fi

GUARD_CLAUDE_BAD="$TMP/claude-agent-bad.js"
cp "$GUARD_CLAUDE" "$GUARD_CLAUDE_BAD"
sed -i '/this.childProcess = null;/d' "$GUARD_CLAUDE_BAD"
cp "$GUARD_CLAUDE_BAD" "$TMP/claude-agent-bad.before"
if negative_js "$PATCH_DIR/orphan-process-guard.mjs" "$GUARD_CLAUDE_BAD" 20 "$TMP/claude-agent-bad.before" claude; then
  ok "orphan guard claude negative control: missing ownership anchor is an untouched rc 20 skip"
else
  bad "orphan guard claude negative control: skipped patch did not fail the positive assertion"
fi
GUARD_MODE_BAD_OUT="$TMP/orphan-guard-codex-mode.out"
guard_mode_bad_rc=0
node "$PATCH_DIR/orphan-process-guard.mjs" codex "$GUARD_CLAUDE" >"$GUARD_MODE_BAD_OUT" 2>&1 || guard_mode_bad_rc=$?
if [ "$guard_mode_bad_rc" -eq 1 ] && grep -qF 'usage:' "$GUARD_MODE_BAD_OUT"; then
  ok "orphan guard: codex mode was removed on purpose (usage error, not a silent no-op)"
else
  bad "orphan guard: codex mode should refuse with a usage error (rc=$guard_mode_bad_rc)"
fi

# ------------------------------------------------------------- process-group sweep
# claude-agent is intentionally applied in sequence: group anchors are guard output,
# so an unguarded bundle must skip rather than acquire a half-fix.
GROUP_CLAUDE_AGENT="$TMP/claude-agent-group.js"
cp "$GUARD_CLAUDE.paseo-new.mjs" "$GROUP_CLAUDE_AGENT"
if positive_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_CLAUDE_AGENT" claude-agent \
  && grep -qF '[paseo-process-group]' "$GROUP_CLAUDE_AGENT.paseo-new.mjs" \
  && grep -qF 'process.kill(-pid, "SIGKILL")' "$GROUP_CLAUDE_AGENT.paseo-new.mjs" \
  && grep -qF 'sweepProcessGroup(pid, reason)' "$GROUP_CLAUDE_AGENT.paseo-new.mjs"; then
  ok "process group claude-agent: adds the group sweep after the guard"
else
  bad "process group claude-agent: guard-derived representative fixture was not patched"
fi

GROUP_ORDER_BAD="$TMP/claude-agent-order-bad.js"
cp "$GUARD_CLAUDE" "$GROUP_ORDER_BAD"
cp "$GROUP_ORDER_BAD" "$TMP/claude-agent-order-bad.before"
if negative_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_ORDER_BAD" 20 "$TMP/claude-agent-order-bad.before" claude-agent; then
  ok "process group ordering: guard-unapplied bundle is an untouched rc 20 skip"
else
  bad "process group ordering: group patch did not refuse an unapplied guard"
fi

GROUP_AGENT_BAD="$TMP/claude-agent-group-bad.js"
cp "$GUARD_CLAUDE.paseo-new.mjs" "$GROUP_AGENT_BAD"
sed -i '/else if (result === "already-exited") {/d' "$GROUP_AGENT_BAD"
cp "$GROUP_AGENT_BAD" "$TMP/claude-agent-group-bad.before"
if negative_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_AGENT_BAD" 20 "$TMP/claude-agent-group-bad.before" claude-agent; then
  ok "process group claude-agent negative control: guard-derived anchor drift skips rc 20"
else
  bad "process group claude-agent negative control: skipped patch did not fail the positive assertion"
fi

GROUP_QUERY="$TMP/claude-query.js"
reference_preimage "$PATCH_DIR/orphan-process-group-claude-query.patch" "$GROUP_QUERY"
if positive_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_QUERY" claude-query \
  && grep -qF 'detached: process.platform !== "win32"' "$GROUP_QUERY.paseo-new.mjs"; then
  ok "process group claude-query: makes the leader a detached process-group owner"
else
  bad "process group claude-query: representative fixture was not patched"
fi
GROUP_QUERY_BAD="$TMP/claude-query-bad.js"
cp "$GROUP_QUERY" "$GROUP_QUERY_BAD"
sed -i '/signal: spawnOptions.signal,/d' "$GROUP_QUERY_BAD"
cp "$GROUP_QUERY_BAD" "$TMP/claude-query-bad.before"
if negative_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_QUERY_BAD" 20 "$TMP/claude-query-bad.before" claude-query; then
  ok "process group claude-query negative control: spawn-anchor drift skips rc 20"
else
  bad "process group claude-query negative control: skipped patch did not fail the positive assertion"
fi

GROUP_CODEX="$TMP/codex-transport.js"
reference_preimage "$PATCH_DIR/orphan-process-group-codex-transport.patch" "$GROUP_CODEX"
if positive_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_CODEX" codex-transport \
  && grep -qF 'sweepProcessGroup(this.child ? this.child.pid : undefined, "dispose")' "$GROUP_CODEX.paseo-new.mjs" \
  && grep -qF 'process.kill(-pid, "SIGKILL")' "$GROUP_CODEX.paseo-new.mjs"; then
  ok "process group codex: sweeps the detached app-server group on dispose"
else
  bad "process group codex: representative fixture was not patched"
fi
GROUP_CODEX_BAD="$TMP/codex-transport-bad.js"
cp "$GROUP_CODEX" "$GROUP_CODEX_BAD"
sed -i '/if (result === "kill-timeout") {/d' "$GROUP_CODEX_BAD"
cp "$GROUP_CODEX_BAD" "$TMP/codex-transport-bad.before"
if negative_js "$PATCH_DIR/orphan-process-group.mjs" "$GROUP_CODEX_BAD" 20 "$TMP/codex-transport-bad.before" codex-transport; then
  ok "process group codex negative control: dispose-anchor drift skips rc 20"
else
  bad "process group codex negative control: skipped patch did not fail the positive assertion"
fi

# ACP invalid model rejection: real offline vendored module and manager methods,
# plus missing/duplicate/partial anchor and complete idempotence controls.
ACP_MODEL_OUT="$TMP/acp-model-rejection.out"
if node "$PATCH_DIR/acp-model-rejection.test.mjs" --self-test "$PATCH_DIR/acp-model-rejection.mjs" >"$ACP_MODEL_OUT" 2>&1; then
  ok "ACP model rejection: invalid selection preserves manager state; valid selection and drift controls"
else
  bad "ACP model rejection: behaviour/drift contract"
  sed 's/^/    /' "$ACP_MODEL_OUT"
fi
if grep -qF 'apply_acp_gap "ACP invalid model rejection" "$ACPMODEL_PATCHER" "$ACP_AGENT_JS" "$ACPMODEL_TEST"' "$ROOT/apps/paseo/install.sh"; then
  ok "ACP model rejection: official installer applies and verifies the candidate"
else
  bad "ACP model rejection: official installer wiring is absent"
fi

# ----------------------------------------------------- agy ACP gap: context gauge
# Synthetic excerpts of the five anchor blocks acp-context-gauge.mjs edits, each on
# its own class so a fixture change to one cannot accidentally satisfy another.
ACPGAUGE="$TMP/acp-agent.js"
cat > "$ACPGAUGE" <<'FIXTURE'
class A {
    build() {
        return {
            modes: modeState.availableModes.map((mode) => ({
                id: mode.id,
                label: mode.name,
                description: mode.description ?? undefined,
            })),
            currentModeId: modeState.currentModeId ?? null,
        };
    }
}
class B {
    probe() {
            return {
                models: this.modelTransformer ? this.modelTransformer(models) : models,
                modes: modeInfo.modes,
            };
    }
}
class C {
    route(update) {
        switch (update.sessionUpdate) {
            case "usage_update":
                this.handleUsageUpdate(update);
                return pendingUserEvents;
        }
    }
}
class D {
    handleConfigOptionUpdate(update) {
        const nextMode = modeInfo.currentModeId;
        const nextModel = deriveCurrentConfigValue(this.configOptions, "model");
        const nextThinkingOptionId = deriveCurrentConfigValue(this.configOptions, "thought_level");
        this.availableModes = modeInfo.modes;
    }
}
class E {
    handleUsageUpdate(update) {
        void update;
    }
    handlePromptResponse(response, turnId) {
        this.currentTurnUsage = mapACPUsage(response.usage) ?? this.currentTurnUsage;
    }
}
FIXTURE
if positive_js "$PATCH_DIR/acp-context-gauge.mjs" "$ACPGAUGE" \
  && grep -qF '[paseo-acp-context-gauge]' "$ACPGAUGE.paseo-new.mjs" \
  && grep -qF 'isUnattended: true' "$ACPGAUGE.paseo-new.mjs" \
  && grep -qF 'defaultModeId: modeInfo.currentModeId' "$ACPGAUGE.paseo-new.mjs" \
  && grep -qF 'return [...pendingUserEvents, ...this.handleUsageUpdate(update)];' "$ACPGAUGE.paseo-new.mjs" \
  && grep -qF 'if (nextMode !== null) {' "$ACPGAUGE.paseo-new.mjs" \
  && grep -qF 'type: "usage_updated",' "$ACPGAUGE.paseo-new.mjs"; then
  ok "agy ACP context gauge: all five edit sites land"
else
  bad "agy ACP context gauge: representative fixture was not patched as intended"
fi
ACPGAUGE_BAD="$TMP/acp-agent-bad.js"
cp "$ACPGAUGE" "$ACPGAUGE_BAD"
sed -i '/void update;/d' "$ACPGAUGE_BAD"
cp "$ACPGAUGE_BAD" "$TMP/acp-agent-bad.before"
if negative_js "$PATCH_DIR/acp-context-gauge.mjs" "$ACPGAUGE_BAD" 20 "$TMP/acp-agent-bad.before"; then
  ok "agy ACP context gauge negative control: missing usage-handler anchor is an untouched rc 20 skip"
else
  bad "agy ACP context gauge negative control: skipped patch did not fail the positive assertion"
fi

# ------------------------------------- agy ACP gap: cross-provider mode default
ACPMODE="$TMP/generic-acp-agent.js"
cat > "$ACPMODE" <<'FIXTURE'
class GenericACPAgentClient extends ACPAgentClient {
    constructor(options) {
        const providerParams = parseGenericACPProviderParams(options.providerParams);
        super({
            provider: "acp",
            logger: options.logger,
        });
        this.command = options.command;
        this.providerId = options.providerId;
    }
}
FIXTURE
if positive_js "$PATCH_DIR/acp-cross-provider-mode-default.mjs" "$ACPMODE" \
  && grep -qF '[paseo-acp-cross-provider-mode-default]' "$ACPMODE.paseo-new.mjs" \
  && grep -qF 'const baseResolveCreateConfig = this.resolveCreateConfig;' "$ACPMODE.paseo-new.mjs" \
  && grep -qF 'return { modeId: undefined, featureValues: input.featureValues };' "$ACPMODE.paseo-new.mjs"; then
  ok "agy ACP cross-provider mode default: wraps the base resolver"
else
  bad "agy ACP cross-provider mode default: representative fixture was not patched as intended"
fi
ACPMODE_BAD="$TMP/generic-acp-agent-bad.js"
cp "$ACPMODE" "$ACPMODE_BAD"
sed -i '/this.command = options.command;/d' "$ACPMODE_BAD"
cp "$ACPMODE_BAD" "$TMP/generic-acp-agent-bad.before"
if negative_js "$PATCH_DIR/acp-cross-provider-mode-default.mjs" "$ACPMODE_BAD" 20 "$TMP/generic-acp-agent-bad.before"; then
  ok "agy ACP cross-provider mode default negative control: missing constructor-tail anchor is an untouched rc 20 skip"
else
  bad "agy ACP cross-provider mode default negative control: skipped patch did not fail the positive assertion"
fi

# ----------------------------------------- agy ACP gap: shared model catalogue
ACPCAT="$TMP/provider-registry.js"
cat > "$ACPCAT" <<'FIXTURE'
function wrapClientProvider(provider, inner, profileModels, additionalModels, profileModelsAreAdditive) {
    const listImportableSessions = inner.listImportableSessions?.bind(inner);
    const importSession = inner.importSession?.bind(inner);
    const listFeatures = inner.listFeatures?.bind(inner);
    return {
        provider,
        capabilities: inner.capabilities,
    };
}
function buildCustom(providerId, override, command) {
    return {
                createBaseClient: (logger) => {
                    const acpOptions = { logger, command, providerId };
                    if (providerId === "cursor") {
                        return new CursorACPAgentClient(acpOptions);
                    }
                    return new GenericACPAgentClient(acpOptions);
                },
                contract: null,
    };
}
FIXTURE
if positive_js "$PATCH_DIR/acp-agy-shared-catalog.mjs" "$ACPCAT" \
  && grep -qF '[paseo-acp-agy-shared-catalog]' "$ACPCAT.paseo-new.mjs" \
  && node "$PATCH_DIR/acp-agy-shared-catalog.test.mjs" "$ACPCAT.paseo-new.mjs" >"$TMP/acpcat.out" 2>&1 \
  && ! node "$PATCH_DIR/acp-agy-shared-catalog.test.mjs" "$ACPCAT" >/dev/null 2>&1; then
  ok "agy ACP shared catalogue: agy gets the host key and the wrapper forwards it"
else
  bad "agy ACP shared catalogue: representative fixture was not patched as intended"
  sed 's/^/    /' "$TMP/acpcat.out" 2>/dev/null
fi
ACPCAT_BAD="$TMP/provider-registry-bad.js"
cp "$ACPCAT" "$ACPCAT_BAD"
sed -i '/return new GenericACPAgentClient(acpOptions);/d' "$ACPCAT_BAD"
cp "$ACPCAT_BAD" "$TMP/provider-registry-bad.before"
if negative_js "$PATCH_DIR/acp-agy-shared-catalog.mjs" "$ACPCAT_BAD" 20 "$TMP/provider-registry-bad.before"; then
  ok "agy ACP shared catalogue negative control: missing generic-client anchor is an untouched rc 20 skip"
else
  bad "agy ACP shared catalogue negative control: skipped patch did not fail the positive assertion"
fi

# ------------------------------------------ platform Claude pool-record contract
# The platform, not paseo or devterm, owns ~/.claude-accounts now. This compact schema
# names the fields a refresh write-back must retain when present and deliberately leaves
# every object open: upstream adds fields without coordinating with this repository, so a
# validator-projected write is data loss even when every currently-known field is listed.
# Pin the schema vocabulary here, beside the vendored patch it governs, so a prose
# reference cannot drift while remaining plausible.
POOL_SCHEMA_OUT="$TMP/pool-schema.out"
POOL_SCHEMA_RC=0
python3 - "$ROOT/schemas/credentials/pool-record-v1.json" >"$POOL_SCHEMA_OUT" 2>&1 <<'PY' || POOL_SCHEMA_RC=$?
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_bytes()
schema = json.loads(raw)
canonical = (json.dumps(schema, sort_keys=True, separators=(",", ":")) + "\n").encode()
assert raw == canonical, "schema must use the repository's canonical one-line JSON form"

required = [
    "_meta.email",
    "_meta.kind",
    "_meta.org",
    "claudeAiOauth.accessToken",
    "claudeAiOauth.expiresAt",
    "claudeAiOauth.rateLimitTier",
    "claudeAiOauth.refreshToken",
    "claudeAiOauth.refreshTokenExpiresAt",
    "claudeAiOauth.scopes",
    "claudeAiOauth.subscriptionType",
]
updates_allowed = [
    "claudeAiOauth.accessToken",
    "claudeAiOauth.rateLimitTier",
    "claudeAiOauth.refreshToken",
    "claudeAiOauth.subscriptionType",
]
assert schema["schema_id"] == "airlock-claude-pool-record"
assert schema["scope"] == "public-contract-index" and schema["version"] == 1
assert schema["required_objects"] == ["claudeAiOauth"]
assert schema["open_objects"] == ["$", "_meta", "claudeAiOauth"]
assert schema["preserve_unknown_fields"] is True
assert schema["required_writeback_fields_if_present"] == required
assert schema["allowed_refresh_updates"] == updates_allowed
assert sorted(schema["field_types"]) == required
PY
if [ "$POOL_SCHEMA_RC" -eq 0 ]; then
  ok "platform pool schema: canonical shape pins every known preservation field"
else
  bad "platform pool schema: shape or deletion controls"
  sed 's/^/    /' "$POOL_SCHEMA_OUT"
fi

# ------------------------------------------------------------------------ web-ui core
# patch-web-ui.js is deliberately SHA-pinned and its CLI refuses drift with exit 1 (the
# browse-host installer downgrades that to a warning). Its pure matching core accepts the
# fixture SHA as a test seam, so this test can exercise the real four replacements without
# copying a real AGPL bundle or weakening the shipped PINNED_SHA.
WEB_OUT="$TMP/web-ui.out"
WEB_RC=0
node - "$ROOT" >"$WEB_OUT" 2>&1 <<'NODE' || WEB_RC=$?
const crypto = require("node:crypto");
const path = require("node:path");
const { patchBundleContent } = require(path.join(process.argv[2], "apps/paseo/browse-host/bin/patch-web-ui.js"));

const patches = [
  {
    find: 'if(!pt||!(0,ze.getIsElectron)())return;const{browserId:t}=(0,ue.createWorkspaceBrowser)();gt(pt,{kind:"browser",browserId:t},Ht(e?.paneId))',
    repl: 'if(!pt)return;const{browserId:t}=(0,ue.createWorkspaceBrowser)();gt(pt,{kind:"browser",browserId:t},Ht(e?.paneId))',
  },
  {
    find: 'if(!pt||!(0,ze.getIsElectron)())return;const{browserId:t}=(0,ue.createWorkspaceBrowser)({initialUrl:e});gt(pt,{kind:"browser",browserId:t},Q.FOCUSED_PANE_PLACEMENT)',
    repl: 'if(!pt)return;const{browserId:t}=(0,ue.createWorkspaceBrowser)({initialUrl:e});gt(pt,{kind:"browser",browserId:t},Q.FOCUSED_PANE_PLACEMENT)',
  },
  {
    find: '{style:u.container,children:[v,M,k]}',
    repl: '{style:u.container,dataSet:{paseoBrowserId:w,paseoWorkspaceId:f.workspaceId,paseoServerId:f.serverId},children:[v,M,k]}',
  },
];
// The coarse-pointer edit is deliberately absent: it moved to the always-on group on
// 2026-09-01, and this fixture drives the legacy `(source, expectedSha)` seam, which
// is browse-only. Its own coverage lives in patch-web-ui.test.js.
const pristine = patches.map((patch) => patch.find).join("\n");
const fixtureSha = crypto.createHash("sha256").update(pristine).digest("hex");

function assertPatched(source, expectedSha = fixtureSha) {
  const result = patchBundleContent(source, expectedSha);
  if (result.alreadyPatched) throw new Error("pristine fixture was reported already patched");
  if (!result.source.includes("dataSet:{paseoBrowserId:")) throw new Error("marker missing after patch");
  for (const patch of patches) {
    if (result.source.includes(patch.find)) throw new Error("original anchor survived");
    if (!result.source.includes(patch.repl)) throw new Error("replacement missing");
  }
  return result.source;
}

const patched = assertPatched(pristine);
const idempotent = patchBundleContent(patched, fixtureSha);
if (!idempotent.alreadyPatched) throw new Error("patched fixture was not idempotent");

const broken = pristine.replace(patches[1].find, "if(!Ye)return;broken-anchor");
let negativeFailed = false;
try {
  const brokenSha = crypto.createHash("sha256").update(broken).digest("hex");
  assertPatched(broken, brokenSha);
} catch (err) {
  negativeFailed = /new-browser-gate-Wo/.test(String(err));
}
if (!negativeFailed) throw new Error("missing web-ui anchor did not fail the positive assertion");
console.log("three replacements, marker, idempotence, and missing-anchor refusal asserted");
NODE
if [ "$WEB_RC" -eq 0 ]; then
  ok "web-ui patch core: patches all three browse anchors and rejects a missing-anchor fixture"
else
  bad "web-ui patch core: synthetic fixture contract"
  sed 's/^/    /' "$WEB_OUT"
fi

WEB_STATES_OUT="$TMP/web-ui-states.out"
web_states_rc=0
node "$ROOT/apps/paseo/browse-host/bin/patch-web-ui.test.js" >"$WEB_STATES_OUT" 2>&1 \
  || web_states_rc=$?
if [ "$web_states_rc" -eq 0 ]; then
  ok "web-ui patch groups: general/browse transitions, three-anchor migration, idempotence, and refusal controls"
else
  bad "web-ui patch groups: state transition contract"
  sed 's/^/    /' "$WEB_STATES_OUT"
fi

# Exercise CLI refusal against the actual pinned package entry point.
history_bundle="$ROOT/apps/paseo/vendor/guarded-0.8.0"
if tar -xOf "$history_bundle/getpaseo-cli-0.8.0.tgz" package/dist/commands/agent/delete.js > "$TMP/history-delete.js" \
  && node "$PATCH_DIR/agent-history-delete-guard.test.mjs" "$TMP/history-delete.js"; then
  ok "CLI deletion guard: refuses before connecting/cancelling and refuses drift"
else
  bad "CLI deletion guard: pinned package behaviour"
fi

# --------------------------------------------------- resolve archive/detach/reload by id
# Behaviour against the actual pinned bundle (same shape as the CLI deletion guard above):
# the check re-patches its own copies, so it covers anchors, idempotence and drift too —
# a full id resolves via fetchAgent and never consults the capped list; a prefix reverses.
rbid_bundle_ok=1
for rb in archive detach reload; do
  tar -xOf "$history_bundle/getpaseo-cli-0.8.0.tgz" "package/dist/commands/agent/$rb.js" \
    > "$TMP/rbid-bundle-$rb.js" 2>/dev/null || rbid_bundle_ok=0
done
if [ "$rbid_bundle_ok" = 1 ] \
  && node "$PATCH_DIR/agent-resolve-by-id.test.mjs" \
       "$TMP/rbid-bundle-archive.js" "$TMP/rbid-bundle-detach.js" "$TMP/rbid-bundle-reload.js" >/dev/null 2>&1; then
  ok "resolve-by-id: pinned bundle — full id skips the 200-cap list, prefix falls back"
else
  bad "resolve-by-id: pinned bundle behaviour"
fi

# --------------------------------------------------- archive/workspace consistency
# The self-test applies the atomic two-file patch, drives the initial snapshot and
# stored/live updates, and checks mixed/drift refusal. The pinned bundle is checked
# as a pair too. A v1 bundle (session-only patch from before the update-path fix) is
# intentionally accepted only as a mixed state that the new patcher refuses; the
# final guarded bundle must carry both sentinels and pass the behavior check.
ARCHIVE_CONSISTENCY_OUT="$TMP/archive-consistency.out"
archive_consistency_rc=0
node "$PATCH_DIR/archive-consistency.test.mjs" --self-test "$PATCH_DIR/archive-consistency.mjs" \
  >"$ARCHIVE_CONSISTENCY_OUT" 2>&1 || archive_consistency_rc=$?
if [ "$archive_consistency_rc" -eq 0 ]; then
  ok "archive/workspace consistency: live+persisted projection, archive predicate, includeArchived, and drift controls"
else
  bad "archive/workspace consistency: behavior/drift contract"
  sed 's/^/    /' "$ARCHIVE_CONSISTENCY_OUT"
fi
archive_consistency_bundle_session="$TMP/archive-consistency-bundle-session.js"
archive_consistency_bundle_updates="$TMP/archive-consistency-bundle-updates.js"
archive_consistency_bundle_rc=0
tar -xOf "$history_bundle/getpaseo-server-0.8.0.tgz" package/dist/server/server/session.js \
  >"$archive_consistency_bundle_session" 2>/dev/null || archive_consistency_bundle_rc=$?
tar -xOf "$history_bundle/getpaseo-server-0.8.0.tgz" package/dist/server/server/session/agent-updates/agent-updates-service.js \
  >"$archive_consistency_bundle_updates" 2>/dev/null || archive_consistency_bundle_rc=$?
if [ "$archive_consistency_bundle_rc" -ne 0 ]; then
  bad "archive/workspace consistency: pinned bundle targets could not be extracted"
else
  bundle_session_patched=0
  bundle_updates_patched=0
  grep -qF 'paseo-archive-consistency' "$archive_consistency_bundle_session" && bundle_session_patched=1
  grep -qF 'paseo-archive-consistency' "$archive_consistency_bundle_updates" && bundle_updates_patched=1
  if [ "$bundle_session_patched" -eq 1 ] && [ "$bundle_updates_patched" -eq 1 ]; then
    if node "$PATCH_DIR/archive-consistency.test.mjs" \
      "$archive_consistency_bundle_session" "$archive_consistency_bundle_updates" >/dev/null 2>&1; then
      pinned_patch_rc=0
      node "$PATCH_DIR/archive-consistency.mjs" \
        "$archive_consistency_bundle_session" "$archive_consistency_bundle_updates" >/dev/null 2>&1 \
        || pinned_patch_rc=$?
      if [ "$pinned_patch_rc" -eq 10 ]; then
        ok "archive/workspace consistency: pinned bundle pair is patched, idempotent, and behavior-valid"
      else
        bad "archive/workspace consistency: pinned bundle pair did not report already-applied (rc=$pinned_patch_rc)"
      fi
    else
      bad "archive/workspace consistency: pinned bundle pair behavior"
    fi
  elif [ "$bundle_session_patched" -eq 1 ] || [ "$bundle_updates_patched" -eq 1 ]; then
    mixed_before_session="$(sha256sum "$archive_consistency_bundle_session" | cut -d' ' -f1)"
    mixed_before_updates="$(sha256sum "$archive_consistency_bundle_updates" | cut -d' ' -f1)"
    mixed_patch_rc=0
    node "$PATCH_DIR/archive-consistency.mjs" \
      "$archive_consistency_bundle_session" "$archive_consistency_bundle_updates" >/dev/null 2>&1 \
      || mixed_patch_rc=$?
    if [ "$mixed_patch_rc" -eq 20 ] \
      && [ ! -f "$archive_consistency_bundle_session.paseo-new.mjs" ] \
      && [ ! -f "$archive_consistency_bundle_updates.paseo-new.mjs" ] \
      && [ "$mixed_before_session" = "$(sha256sum "$archive_consistency_bundle_session" | cut -d' ' -f1)" ] \
      && [ "$mixed_before_updates" = "$(sha256sum "$archive_consistency_bundle_updates" | cut -d' ' -f1)" ]; then
      ok "archive/workspace consistency: pinned v1 mixed bundle is refused without candidates"
    else
      bad "archive/workspace consistency: mixed pinned bundle was not refused atomically (rc=$mixed_patch_rc)"
    fi
  else
    pristine_patch_rc=0
    node "$PATCH_DIR/archive-consistency.mjs" \
      "$archive_consistency_bundle_session" "$archive_consistency_bundle_updates" >/dev/null 2>&1 \
      || pristine_patch_rc=$?
    if [ "$pristine_patch_rc" -eq 0 ] \
      && node --check "$archive_consistency_bundle_session.paseo-new.mjs" >/dev/null 2>&1 \
      && node --check "$archive_consistency_bundle_updates.paseo-new.mjs" >/dev/null 2>&1 \
      && node "$PATCH_DIR/archive-consistency.test.mjs" \
        "$archive_consistency_bundle_session.paseo-new.mjs" \
        "$archive_consistency_bundle_updates.paseo-new.mjs" >/dev/null 2>&1; then
      ok "archive/workspace consistency: pristine pinned bundle produces behavior-valid pair candidates"
    else
      bad "archive/workspace consistency: pristine pinned bundle pair patch failed (rc=$pristine_patch_rc)"
    fi
  fi
fi
if grep -qF 'ARCHIVE_CONSISTENCY_PATCHER="$HERE/patches/archive-consistency.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'ARCHIVE_CONSISTENCY_TEST="$HERE/patches/archive-consistency.test.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$ARCHIVE_CONSISTENCY_TEST" "$ac_session_tmp" "$ac_updates_tmp"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$ARCHIVE_CONSISTENCY_TEST" "$SESSION_JS" "$ARCHIVE_CONSISTENCY_UPDATES"' "$ROOT/apps/paseo/install.sh"; then
  ok "archive/workspace consistency: installer applies, verifies candidate, and rechecks installed bytes"
else
  bad "archive/workspace consistency: installer wiring is absent"
fi

# ------------------------------------------------ send keeps pending permissions
# Pristine pinned protocol/server/client files must yield three behavior-valid candidates;
# a second pass over the patched trio is ALREADY, and a mixed trio is refused with no candidates.
SK_DIR="$TMP/send-keep"
mkdir -p "$SK_DIR"
sk_extract_rc=0
tar -xOf "$history_bundle/getpaseo-protocol-0.8.0.tgz" package/dist/messages.js >"$SK_DIR/messages.js" 2>/dev/null || sk_extract_rc=$?
tar -xOf "$history_bundle/getpaseo-server-0.8.0.tgz" package/dist/server/server/session.js >"$SK_DIR/session.js" 2>/dev/null || sk_extract_rc=$?
tar -xOf "$history_bundle/getpaseo-client-0.8.0.tgz" package/dist/daemon-client.js >"$SK_DIR/daemon-client.js" 2>/dev/null || sk_extract_rc=$?
if [ "$sk_extract_rc" -ne 0 ]; then
  bad "send-keep-pending-permissions: pinned bundle targets could not be extracted"
elif [ "$(grep -lF 'paseo-send-keep-pending-permissions' "$SK_DIR/messages.js" "$SK_DIR/session.js" "$SK_DIR/daemon-client.js" | wc -l)" -eq 3 ]; then
  # Baked into the vendored tarballs: the installer must see ALREADY and leave the pinned files alone.
  sk_baked_rc=0
  node "$PATCH_DIR/send-keep-pending-permissions.mjs" "$SK_DIR/messages.js" "$SK_DIR/session.js" "$SK_DIR/daemon-client.js" >/dev/null 2>&1 || sk_baked_rc=$?
  if [ "$sk_baked_rc" -eq 10 ] \
    && node --check "$SK_DIR/messages.js" >/dev/null 2>&1 \
    && node --check "$SK_DIR/session.js" >/dev/null 2>&1 \
    && node --check "$SK_DIR/daemon-client.js" >/dev/null 2>&1; then
    ok "send-keep-pending-permissions: pinned bundle trio is baked, syntax-valid and idempotent"
  else
    bad "send-keep-pending-permissions: baked pinned trio did not report already-applied (rc=$sk_baked_rc)"
  fi
else
  sk_rc=0
  node "$PATCH_DIR/send-keep-pending-permissions.mjs" "$SK_DIR/messages.js" "$SK_DIR/session.js" "$SK_DIR/daemon-client.js" >/dev/null 2>&1 || sk_rc=$?
  if [ "$sk_rc" -eq 0 ] \
    && node --check "$SK_DIR/session.js.paseo-new.mjs" >/dev/null 2>&1 \
    && node --check "$SK_DIR/daemon-client.js.paseo-new.mjs" >/dev/null 2>&1 \
    && node --check "$SK_DIR/messages.js.paseo-new.mjs" >/dev/null 2>&1; then
    # The behaviour test imports zod via the protocol package, which the vendored tarballs do not
    # carry; the installer runs it against the real installed tree before any mv.
    ok "send-keep-pending-permissions: pristine pinned bundle produces syntax-valid trio candidates"
  else
    bad "send-keep-pending-permissions: pristine pinned bundle trio patch failed (rc=$sk_rc)"
  fi
  # Mixed: only the server file patched -> exit 20 and no new candidates.
  cp "$SK_DIR/session.js.paseo-new.mjs" "$SK_DIR/session-mixed.js"
  rm -f "$SK_DIR"/*.paseo-new.mjs
  sk_mixed_rc=0
  node "$PATCH_DIR/send-keep-pending-permissions.mjs" "$SK_DIR/messages.js" "$SK_DIR/session-mixed.js" "$SK_DIR/daemon-client.js" >/dev/null 2>&1 || sk_mixed_rc=$?
  if [ "$sk_mixed_rc" -eq 20 ] && ! ls "$SK_DIR"/*.paseo-new.mjs >/dev/null 2>&1; then
    ok "send-keep-pending-permissions: mixed trio is refused without candidates"
  else
    bad "send-keep-pending-permissions: mixed trio was not refused atomically (rc=$sk_mixed_rc)"
  fi
  # Drift: a broken client anchor -> exit 20 and no candidates.
  sed 's/options?\.images/options?.imagez/' "$SK_DIR/daemon-client.js" >"$SK_DIR/client-drift.js"
  sk_drift_rc=0
  node "$PATCH_DIR/send-keep-pending-permissions.mjs" "$SK_DIR/messages.js" "$SK_DIR/session.js" "$SK_DIR/client-drift.js" >/dev/null 2>&1 || sk_drift_rc=$?
  if [ "$sk_drift_rc" -eq 20 ] && ! ls "$SK_DIR"/*.paseo-new.mjs >/dev/null 2>&1; then
    ok "send-keep-pending-permissions: anchor drift is refused without candidates"
  else
    bad "send-keep-pending-permissions: anchor drift was not refused (rc=$sk_drift_rc)"
  fi
fi
if grep -qF 'SENDKEEP_PATCHER="$HERE/patches/send-keep-pending-permissions.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$SENDKEEP_TEST" "${sk_files[0]}.paseo-new.mjs"' "$ROOT/apps/paseo/install.sh"; then
  ok "send-keep-pending-permissions: installer applies and verifies candidates before mv"
else
  bad "send-keep-pending-permissions: installer wiring is absent"
fi

# ------------------------------------------------------- schedule stale-due + single list
# The reference preimage carries the *already busy-pending-patched* tick as context, because
# that is what this patcher anchors on. Order is the contract: without the precursor the
# patcher must refuse (rc 20) rather than write half a fix.
STALEDUE="$TMP/schedule-service-staledue.js"
reference_preimage "$PATCH_DIR/schedule-stale-due-run.patch" "$STALEDUE"
if positive_js "$PATCH_DIR/schedule-stale-due-run.mjs" "$STALEDUE"; then
  if grep -qF '[paseo-schedule-stale-due]' "$STALEDUE.paseo-new.mjs" \
    && grep -qF 'appendRunningRun(scheduleId, runningRun, manual)' "$STALEDUE.paseo-new.mjs" \
    && grep -qF 'schedule.nextRunAt !== runningRun.scheduledFor' "$STALEDUE.paseo-new.mjs" \
    && grep -qF 'return appended ? existing : null;' "$STALEDUE.paseo-new.mjs" \
    && ! grep -qF 'for (const schedule of await this.store.list()) {' "$STALEDUE.paseo-new.mjs"; then
    ok "schedule stale-due: revalidates the due snapshot inside the atomic update and stops the second full read"
  else
    bad "schedule stale-due: patched result did not carry the revalidation or still reads the directory twice"
  fi
else
  bad "schedule stale-due: representative fixture was not patched"
fi
STALEDUE_BAD="$TMP/schedule-service-staledue-bad.js"
cp "$STALEDUE" "$STALEDUE_BAD"
sed -i '/async appendRunningRun(scheduleId, runningRun) {/d' "$STALEDUE_BAD"
cp "$STALEDUE_BAD" "$TMP/schedule-service-staledue-bad.before"
if negative_js "$PATCH_DIR/schedule-stale-due-run.mjs" "$STALEDUE_BAD" 20 "$TMP/schedule-service-staledue-bad.before"; then
  ok "schedule stale-due negative control: a missing append anchor is an untouched rc 20 skip"
else
  bad "schedule stale-due negative control: skipped patch did not fail the positive assertion"
fi
# The ordering contract itself: strip the precursor's marker and the patcher must refuse.
STALEDUE_NOPRE="$TMP/schedule-service-staledue-noprecursor.js"
reference_preimage "$PATCH_DIR/schedule-stale-due-run.patch" "$STALEDUE_NOPRE"
sed -i '/\[paseo-schedule-pending\] pending 은 due 보다 먼저/d' "$STALEDUE_NOPRE"
cp "$STALEDUE_NOPRE" "$TMP/schedule-service-staledue-noprecursor.before"
if negative_js "$PATCH_DIR/schedule-stale-due-run.mjs" "$STALEDUE_NOPRE" 20 \
  "$TMP/schedule-service-staledue-noprecursor.before"; then
  ok "schedule stale-due ordering: refuses to apply before schedule-busy-pending-delivery"
else
  bad "schedule stale-due ordering: applied without its precursor (half a fix)"
fi
# Re-applying must be a no-op, not a second rewrite.
cp "$STALEDUE.paseo-new.mjs" "$TMP/schedule-service-staledue-applied.js"
staledue_again_rc=0
node "$PATCH_DIR/schedule-stale-due-run.mjs" "$TMP/schedule-service-staledue-applied.js" \
  >/dev/null 2>&1 || staledue_again_rc=$?
if [ "$staledue_again_rc" -eq 10 ] && [ ! -f "$TMP/schedule-service-staledue-applied.js.paseo-new.mjs" ]; then
  ok "schedule stale-due: re-applying an already patched file is an untouched rc 10 skip"
else
  bad "schedule stale-due: re-apply was not a clean rc 10 skip (rc=$staledue_again_rc)"
fi
if grep -qF 'SCHEDSTALE_PATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")/patches" 2>/dev/null && pwd || true)/schedule-stale-due-run.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'apply_schedpend stale-due "$SCHEDSTALE_PATCHER" "$SCHEDULE_SERVICE_JS" "$SCHEDSTALE_TEST"' "$ROOT/apps/paseo/install.sh"; then
  ok "schedule stale-due: installer applies it after the busy-pending service patch"
else
  bad "schedule stale-due: installer wiring is absent"
fi

# ------------------------------------------------------- schedule pending batch (one turn per seat)
SCHEDBATCH="$TMP/schedule-service-batch.js"
reference_preimage "$PATCH_DIR/schedule-pending-batch.patch" "$SCHEDBATCH"
if positive_js "$PATCH_DIR/schedule-pending-batch.mjs" "$SCHEDBATCH"; then
  if grep -qF '[paseo-schedule-pending-batch]' "$SCHEDBATCH.paseo-new.mjs" \
    && grep -qF 'async runPendingBatch(claimed, now) {' "$SCHEDBATCH.paseo-new.mjs" \
    && grep -qF 'await this.restorePendingDelivery(schedule.id);' "$SCHEDBATCH.paseo-new.mjs" \
    && ! grep -qF 'await this.runSchedule({ ...schedule, pendingAgentDelivery: false }, now);' "$SCHEDBATCH.paseo-new.mjs"; then
    ok "schedule pending-batch: a seat's pending schedules go out in one turn and a refused claim keeps its bit"
  else
    bad "schedule pending-batch: patched result did not carry the batch or the bit restore"
  fi
else
  bad "schedule pending-batch: representative fixture was not patched"
fi
SCHEDBATCH_NOPRE="$TMP/schedule-service-batch-noprecursor.js"
reference_preimage "$PATCH_DIR/schedule-pending-batch.patch" "$SCHEDBATCH_NOPRE"
sed -i '/return appended ? existing : null;/d' "$SCHEDBATCH_NOPRE"
cp "$SCHEDBATCH_NOPRE" "$TMP/schedule-service-batch-noprecursor.before"
if negative_js "$PATCH_DIR/schedule-pending-batch.mjs" "$SCHEDBATCH_NOPRE" 20 \
  "$TMP/schedule-service-batch-noprecursor.before"; then
  ok "schedule pending-batch ordering: refuses to apply before schedule-stale-due-run"
else
  bad "schedule pending-batch ordering: applied without its precursor (half a fix)"
fi
cp "$SCHEDBATCH.paseo-new.mjs" "$TMP/schedule-service-batch-applied.js"
schedbatch_again_rc=0
node "$PATCH_DIR/schedule-pending-batch.mjs" "$TMP/schedule-service-batch-applied.js" \
  >/dev/null 2>&1 || schedbatch_again_rc=$?
if [ "$schedbatch_again_rc" -eq 10 ] && [ ! -f "$TMP/schedule-service-batch-applied.js.paseo-new.mjs" ]; then
  ok "schedule pending-batch: re-applying an already patched file is an untouched rc 10 skip"
else
  bad "schedule pending-batch: re-apply was not a clean rc 10 skip (rc=$schedbatch_again_rc)"
fi
if grep -qF 'apply_schedpend pending-batch "$SCHEDBATCH_PATCHER" "$SCHEDULE_SERVICE_JS" "$SCHEDBATCH_TEST"' "$ROOT/apps/paseo/install.sh"; then
  ok "schedule pending-batch: installer applies it after stale-due"
else
  bad "schedule pending-batch: installer wiring is absent"
fi

# ------------------------------------------------------- working-tree watch recovery (upstream #3056)
WATCHREC="$TMP/workspace-git-service.js"
reference_preimage "$PATCH_DIR/workspace-git-watch-recovery.patch" "$WATCHREC"
if positive_js "$PATCH_DIR/workspace-git-watch-recovery.mjs" "$WATCHREC"; then
  if grep -qF '[paseo-watch-recovery]' "$WATCHREC.paseo-new.mjs" \
    && grep -qF 'WATCH_RECOVERY_MAX_DELAY_MS = 300000' "$WATCHREC.paseo-new.mjs" \
    && grep -qF 'DEGRADED_GIT_POLL_MAX_INTERVAL_MS = 60000' "$WATCHREC.paseo-new.mjs" \
    && ! grep -qF 'target.recovery.attemptCount >= WATCH_RECOVERY_MAX_ATTEMPTS) {' "$WATCHREC.paseo-new.mjs"; then
    ok "watch recovery: keeps retrying (300s cap) and backs a quiet poll off (60s cap)"
  else
    bad "watch recovery: patched result still gives up or keeps a fixed 5s poll"
  fi
else
  bad "watch recovery: representative fixture was not patched"
fi
WATCHREC_BAD="$TMP/workspace-git-service-bad.js"
cp "$WATCHREC" "$WATCHREC_BAD"
sed -i '/scheduleWorkingTreeWatchRecovery(target) {/d' "$WATCHREC_BAD"
cp "$WATCHREC_BAD" "$TMP/workspace-git-service-bad.before"
if negative_js "$PATCH_DIR/workspace-git-watch-recovery.mjs" "$WATCHREC_BAD" 20 "$TMP/workspace-git-service-bad.before"; then
  ok "watch recovery negative control: a missing recovery anchor is an untouched rc 20 skip"
else
  bad "watch recovery negative control: skipped patch did not fail the positive assertion"
fi
if grep -qF 'WATCHREC_PATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")/patches" 2>/dev/null && pwd || true)/workspace-git-watch-recovery.mjs"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$WATCHREC_TEST" "$wr_tmp"' "$ROOT/apps/paseo/install.sh"; then
  ok "watch recovery: installer applies it and runs its behaviour check on the candidate"
else
  bad "watch recovery: installer wiring is absent"
fi

# Cached workspace removal after an unchanged reconnect bootstrap.
REMOVE_FIXTURE="$TMP/workspace-remove-session.js"
cat > "$REMOVE_FIXTURE" <<'JS'
class Session {
    shouldSkipWorkspaceRemoval(lastEmitted, removedProjectId) {
        if (lastEmitted?.kind === "remove") {
            return !removedProjectId || lastEmitted.removedProjectId === removedProjectId;
        }
        return !lastEmitted && !removedProjectId;
    }
}
JS
if positive_js "$PATCH_DIR/workspace-remove-delivery.mjs" "$REMOVE_FIXTURE" \
  && node --check "$REMOVE_FIXTURE.paseo-new.mjs"; then
  ok "workspace removal: unchanged cached rows receive archive removal"
else
  bad "workspace removal: representative target failed"
fi
cp "$REMOVE_FIXTURE" "$TMP/workspace-remove-bad.js"
sed -i '/return !lastEmitted && !removedProjectId;/d' "$TMP/workspace-remove-bad.js"
cp "$TMP/workspace-remove-bad.js" "$TMP/workspace-remove-bad.before"
if negative_js "$PATCH_DIR/workspace-remove-delivery.mjs" "$TMP/workspace-remove-bad.js" 20 "$TMP/workspace-remove-bad.before"; then
  ok "workspace removal: anchor drift leaves source untouched"
else
  bad "workspace removal: anchor drift changed source"
fi
remove_rc=0
node "$PATCH_DIR/workspace-remove-delivery.mjs" "$REMOVE_FIXTURE.paseo-new.mjs" > /dev/null || remove_rc=$?
if [ "$remove_rc" = 10 ]; then
  ok "workspace removal: repeat patch is idempotent"
else
  bad "workspace removal: repeat patch failed"
fi

# Identity pair: independent fixtures cover both anchors and no partial writes.
IDENTITY_SERVICE="$TMP/identity-service.js"
IDENTITY_CHECKOUT="$TMP/identity-checkout.js"
cat >"$IDENTITY_SERVICE" <<'EOF'
import { getCheckoutShortstat, getCheckoutStatus, getCheckoutWorktreeState } from "../utils/checkout-git.js";
function deps() {
    return {
        getCheckoutStatus,
        getCheckoutShortstat,
    };
}
export class WorkspaceGitServiceImpl {
    async getCheckout(normalizedCwd) {
        const status = await this.deps.getCheckoutStatus(normalizedCwd, {});
        return status;
    }
}
EOF
# Preserve the actual call's multiline anchor, independent of patcher literals.
sed -i 's/(normalizedCwd, {});/(normalizedCwd, {\n        });/' "$IDENTITY_SERVICE"
cat >"$IDENTITY_CHECKOUT" <<'EOF'
export async function getCheckoutStatus(cwd, context) {
    const facts = await getCheckoutSnapshotFacts(cwd, context);
    if (!facts.isGit) return { isGit: false };
    const worktreeRoot = facts.worktreeRoot;
    const currentBranch = facts.currentBranch;
    const remoteUrl = facts.remoteUrl;
    const paseoWorktree = facts.paseoWorktree;
    const baseRef = facts.resolvedBaseRef;
    const mainRepoRoot = facts.mainRepoRoot;
    if (paseoWorktree.isPaseoOwnedWorktree && baseRef) {
        return {
            isGit: true,
            repoRoot: worktreeRoot,
            mainRepoRoot: mainRepoRoot ?? worktreeRoot,
            currentBranch,
            remoteUrl,
            isPaseoOwnedWorktree: true,
        };
    }
    return {
        isGit: true,
        repoRoot: worktreeRoot,
        mainRepoRoot: mainRepoRoot && resolve(mainRepoRoot) !== resolve(worktreeRoot) ? mainRepoRoot : null,
        currentBranch,
        remoteUrl,
        isPaseoOwnedWorktree: false,
    };
}
// Workspace history stays complete;
EOF
identity_rc=0
node "$PATCH_DIR/workspace-git-identity.mjs" "$IDENTITY_SERVICE" "$IDENTITY_CHECKOUT" > /dev/null || identity_rc=$?
if [ "$identity_rc" = 0 ] && node --check "$IDENTITY_SERVICE.paseo-new.mjs" && node --check "$IDENTITY_CHECKOUT.paseo-new.mjs"; then
  ok "checkout identity: both candidates have valid syntax"
else bad "checkout identity: positive pair failed"; fi
identity_rc=0
node "$PATCH_DIR/workspace-git-identity.mjs" "$IDENTITY_SERVICE.paseo-new.mjs" "$IDENTITY_CHECKOUT.paseo-new.mjs" > /dev/null || identity_rc=$?
[ "$identity_rc" = 10 ] && ok "checkout identity: idempotent pair" || bad "checkout identity: repeat not accepted"
for target in "$IDENTITY_SERVICE" "$IDENTITY_CHECKOUT"; do
  cp "$target" "$target.before"
  sed -i 's/getCheckoutStatus/getDriftedStatus/g' "$target"
  rm -f "$IDENTITY_SERVICE.paseo-new.mjs" "$IDENTITY_CHECKOUT.paseo-new.mjs"
  identity_rc=0
  node "$PATCH_DIR/workspace-git-identity.mjs" "$IDENTITY_SERVICE" "$IDENTITY_CHECKOUT" > /dev/null || identity_rc=$?
  if [ "$identity_rc" = 20 ] && [ ! -e "$IDENTITY_SERVICE.paseo-new.mjs" ] && [ ! -e "$IDENTITY_CHECKOUT.paseo-new.mjs" ]; then
    ok "checkout identity: drift on $(basename "$target") writes neither candidate"
  else bad "checkout identity: partial write on drift"; fi
  mv "$target.before" "$target"
done

# K05: a readable package list is sufficient input; package count and checksums
# remain development bundle tests, not installation admission.
if (
  HERE="$TMP/bundle-selection"; mkdir -p "$HERE"
  PASEO_BUNDLE_DIR="$HERE"
  PASEO_BUNDLE_SUMS="$HERE/SHA256SUMS"
  printf 'stale-digest only-package.tgz\n' >"$PASEO_BUNDLE_SUMS"
  NPM_GBIN="$TMP/bin"; PASEO_VER=0.8.0
  unset AIRLOCK_PASEO_VERSION
  log() { :; }; die() { printf '%s\n' "$*" >&2; exit 1; }
  eval "$(sed -n '/^if \[ -n "${AIRLOCK_PASEO_VERSION:-}" \]; then/,/^export PATH=/p' "$ROOT/apps/paseo/install.sh")"
  [ "${#paseo_packages[@]}" = 1 ] && [ "$PASEO_SOURCE" = bundle ]
); then ok "K05 readable bundle list is accepted without whole checksum or exact package count";
else bad "K05 bundle list admission still rejects a readable input"; fi

printf 'paseo-patch-drift: %s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
