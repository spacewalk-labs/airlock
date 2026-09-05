#!/usr/bin/env bash
# Offline contract tests for every paseo bundle patch. The fixtures are assembled from
# the small, human-readable reference patches; no @getpaseo bundle, npm, or network is
# involved. Each positive assertion has a deliberately broken-anchor control beside it.
set -uo pipefail
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
PATCH_DIR="$ROOT/apps/paseo/patches"
TMP="$(mktemp -d)" || { echo "FAIL paseo-patch-drift: could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok(){ printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

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
const shapeKey = (sha256, edits) => `${sha256}:${[...edits].sort().join("|")}`;
const manifestShapes = (manifest.web_ui.shapes ?? []).map((shape) =>
  shapeKey(shape.sha256, shape.edits));
const patcherShapes = patcher.KNOWN_BUNDLE_SHAPES.map((shape) =>
  shapeKey(shape.sha, shape.edits));
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
  "depth4-search",
  "claude-model-fable51",
  "claude-model-prune",
  "provider-subagent-stream-filter",
  "image-attachments-persist",
  "orphan-process-guard",
  "orphan-process-group",
  "credential-key-preservation",
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
  throw new Error("anchor manifest does not cover exactly the nine paseo patchers");
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
  ok "anchor manifest: version, shape table, nine patchers, and pair/order contracts"
else
  bad "anchor manifest: version/SHA/coverage/order contract"
  sed 's/^/    /' "$manifest_out"
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
# Assert that main install runs the general group outside the BROWSE=true block and
# treats any half failure as fatal, while browse-host explicitly requests only its
# optional group.
if grep -qF 'node "$WEBUI_PATCHER" --subagent-stream "$WEBUI_DIR"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'die "provider-subagent web-ui subscription patch failed"' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'provider-subagent server filter behavior check failed on candidate' "$ROOT/apps/paseo/install.sh" \
  && grep -qF 'node "$INSTALL_DIR/bin/patch-web-ui.js" --browse "$WEBUI_DIR"' "$ROOT/apps/paseo/browse-host/install.sh"; then
  ok "provider-subagent install wiring: always-on pair is fail-hard and optional browse is explicit"
else
  bad "provider-subagent install wiring: server/UI pair or explicit browse mode is missing"
fi

# ------------------------------------------------------------------ model fable 5.1
# The pin (paseo 0.2.5) predates Fable 5.1, so the picker cannot offer a model the
# installed CLI already runs. Additive sibling of the prune patch; it must retire
# itself (rc 20) the moment upstream ships the rows.
FB51="$TMP/model-manifest-fable51.js"
# The prune preimage carries no Fable rows, so this fixture is built here: the
# minimum shape the patcher anchors on (array head, the Fable 5 sibling it inserts
# above, and the CLAUDE_EFFORT_LEVELS symbol the new entries reference).
cat > "$FB51" <<'FB51EOF'
export const CLAUDE_EFFORT_LEVELS = { xhigh: ["low", "medium", "high", "xhigh", "max"] };
export const CLAUDE_MODEL_MANIFEST = [
    {
        id: "claude-opus-5",
        label: "Opus 5",
        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,
    },
    {
        id: "claude-fable-5[1m]",
        label: "Fable 5 1M",
        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,
    },
    {
        id: "claude-fable-5",
        label: "Fable 5",
        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,
    },
];
FB51EOF
if [ "${PASEO_PATCH_DRIFT_BREAK:-}" = "model-fable51" ]; then
  sed -i '/id: "claude-fable-5\[1m\]"/d' "$FB51"
fi
if positive_js "$PATCH_DIR/claude-model-fable51.mjs" "$FB51"; then
  if grep -qF '[airlock-model-fable51]' "$FB51.paseo-new.mjs" \
    && grep -qF 'id: "claude-fable-5-1",' "$FB51.paseo-new.mjs" \
    && grep -qF 'id: "claude-fable-5-1[1m]",' "$FB51.paseo-new.mjs" \
    && grep -qF 'id: "claude-fable-5",' "$FB51.paseo-new.mjs"; then
    ok "model fable51: adds both 5.1 rows and keeps the Fable 5 family"
  else
    bad "model fable51: patched result did not match the intended manifest"
  fi
else
  bad "model fable51: representative fixture was not patched"
fi
FB51_DONE="$TMP/model-manifest-fable51-done.js"
cp "$FB51.paseo-new.mjs" "$FB51_DONE" 2>/dev/null || cp "$FB51" "$FB51_DONE"
sed -i 's/\[airlock-model-fable51\]/[gone]/' "$FB51_DONE"
cp "$FB51_DONE" "$TMP/model-manifest-fable51-done.before"
if negative_js "$PATCH_DIR/claude-model-fable51.mjs" "$FB51_DONE" 20 "$TMP/model-manifest-fable51-done.before"; then
  ok "model fable51 negative control: upstream already shipping 5.1 is an untouched rc 20 skip"
else
  bad "model fable51 negative control: patch ran on a manifest that already lists 5.1"
fi
FB51_BAD="$TMP/model-manifest-fable51-bad.js"
cp "$FB51" "$FB51_BAD"
sed -i '/id: "claude-fable-5\[1m\]"/d' "$FB51_BAD"
cp "$FB51_BAD" "$TMP/model-manifest-fable51-bad.before"
if negative_js "$PATCH_DIR/claude-model-fable51.mjs" "$FB51_BAD" 20 "$TMP/model-manifest-fable51-bad.before"; then
  ok "model fable51 negative control: missing Fable anchor is an untouched rc 20 skip"
else
  bad "model fable51 negative control: skipped patch did not fail the positive assertion"
fi

# ---------------------------------------------------------------------- model prune
PRUNE="$TMP/model-manifest.js"
reference_preimage "$PATCH_DIR/claude-model-prune.patch" "$PRUNE"
printf '    },\n    {\n        id: "claude-sonnet-5",\n        label: "Sonnet 5",\n    },\n];\n' >> "$PRUNE"
# Test-only fault injection used by the completion check: it makes the positive fixture
# fail without changing a shipped patcher or a tracked reference patch.
if [ "${PASEO_PATCH_DRIFT_BREAK:-}" = "model-prune" ]; then
  sed -i '/export const CLAUDE_MODEL_MANIFEST = \[/d' "$PRUNE"
fi
if positive_js "$PATCH_DIR/claude-model-prune.mjs" "$PRUNE"; then
  if grep -qF '[airlock-model-prune]' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-opus-4-7' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-opus-4-6' "$PRUNE.paseo-new.mjs" \
    && ! grep -qF 'claude-sonnet-4-6' "$PRUNE.paseo-new.mjs" \
    && grep -qF 'claude-opus-5' "$PRUNE.paseo-new.mjs"; then
    ok "model prune: removes superseded IDs and preserves a current model"
  else
    bad "model prune: patched result did not match the intended manifest"
  fi
else
  bad "model prune: representative fixture was not patched"
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
GUARD_CLAUDE="$TMP/claude-agent.js"
GUARD_CODEX="$TMP/codex-agent.js"
reference_preimage "$PATCH_DIR/orphan-process-guard-claude.patch" "$GUARD_CLAUDE"
reference_preimage "$PATCH_DIR/orphan-process-guard-codex.patch" "$GUARD_CODEX"
# The codex reference hunk has only three unchanged context lines around each of these
# edits, while the patcher's all-or-nothing anchors intentionally cover the whole cleanup
# blocks. Complete the synthetic excerpt with those stable old blocks independently of the
# patcher source, just as a tiny hand-written bundle fixture would.
cat >> "$GUARD_CODEX" <<'FIXTURE'
        catch (error) {
            try {
                await this.close();
            }
            catch (closeError) {
                this.logger.warn({ err: closeError, connectError: error }, "Failed to close Codex app-server after connection failure");
            }
            throw error;
        }
        if (this.client) {
            await this.client.dispose();
        }
        this.client = null;
        this.connected = false;
        this.currentThreadId = null;
        this.currentTurnId = null;
FIXTURE
if positive_js "$PATCH_DIR/orphan-process-guard.mjs" "$GUARD_CLAUDE" claude \
  && grep -qF '[paseo-orphan-guard]' "$GUARD_CLAUDE.paseo-new.mjs" \
  && grep -qF 'liveChildProcesses' "$GUARD_CLAUDE.paseo-new.mjs" \
  && grep -qF 'ensureQuery() on a closed session' "$GUARD_CLAUDE.paseo-new.mjs"; then
  ok "orphan guard claude: tracks replacements, gates closed spawns, and handles late children"
else
  bad "orphan guard claude: representative fixture was not patched as intended"
fi
if positive_js "$PATCH_DIR/orphan-process-guard.mjs" "$GUARD_CODEX" codex \
  && grep -qF '[paseo-orphan-guard]' "$GUARD_CODEX.paseo-new.mjs" \
  && grep -qF 'liveAppServerClients' "$GUARD_CODEX.paseo-new.mjs" \
  && grep -qF 'connect() on a closed session' "$GUARD_CODEX.paseo-new.mjs"; then
  ok "orphan guard codex: tracks app-server replacements and gates closed reconnects"
else
  bad "orphan guard codex: representative fixture was not patched as intended"
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
GUARD_CODEX_BAD="$TMP/codex-agent-bad.js"
cp "$GUARD_CODEX" "$GUARD_CODEX_BAD"
sed -i '/this.client = null;/d' "$GUARD_CODEX_BAD"
cp "$GUARD_CODEX_BAD" "$TMP/codex-agent-bad.before"
if negative_js "$PATCH_DIR/orphan-process-guard.mjs" "$GUARD_CODEX_BAD" 20 "$TMP/codex-agent-bad.before" codex; then
  ok "orphan guard codex negative control: missing client anchor is an untouched rc 20 skip"
else
  bad "orphan guard codex negative control: skipped patch did not fail the positive assertion"
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

# ------------------------------------------ platform Claude pool-record contract
# The platform, not paseo or devterm, owns ~/.claude-accounts now. This compact schema
# names the fields a refresh write-back must retain when present and deliberately leaves
# every object open: upstream adds fields without coordinating with this repository, so a
# validator-projected write is data loss even when every currently-known field is listed.
# Pin both the schema vocabulary and a deletion control here, beside the vendored patch it
# governs. A prose reference can drift while remaining plausible; deleting any contracted
# field below must make this test fail.
POOL_SCHEMA_OUT="$TMP/pool-schema.out"
POOL_SCHEMA_RC=0
python3 - "$ROOT/schemas/credentials/pool-record-v1.json" >"$POOL_SCHEMA_OUT" 2>&1 <<'PY' || POOL_SCHEMA_RC=$?
import copy
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

def leaves(value, prefix=""):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{prefix}.{key}" if prefix else key
            yield from leaves(child, child_path)
    else:
        yield prefix, value

def lookup(value, dotted):
    current = value
    for part in dotted.split("."):
        if not isinstance(current, dict) or part not in current:
            raise AssertionError(f"write-back dropped {dotted}")
        current = current[part]
    return current

def assign(value, dotted, replacement):
    parts = dotted.split(".")
    current = value
    for part in parts[:-1]:
        current = current[part]
    current[parts[-1]] = replacement

def remove(value, dotted):
    parts = dotted.split(".")
    current = value
    for part in parts[:-1]:
        current = current[part]
    del current[parts[-1]]

def assert_writeback(before, after, updates):
    assert isinstance(after.get("claudeAiOauth"), dict), "required object was dropped"
    for dotted in required:
        try:
            old = lookup(before, dotted)
        except AssertionError:
            continue
        expected = updates.get(dotted, old)
        assert lookup(after, dotted) == expected, f"write-back changed {dotted} outside its contract"
    for dotted, old in leaves(before):
        if dotted not in updates:
            assert lookup(after, dotted) == old, f"write-back dropped or changed {dotted}"

# Values are inert, local sentinels. The test emits only assertions and counts, never data.
before = {
    "claudeAiOauth": {
        "accessToken": "redacted-old",
        "refreshToken": "redacted-old",
        "expiresAt": 1,
        "refreshTokenExpiresAt": 2,
        "scopes": ["scope-a"],
        "subscriptionType": "kind-a",
        "rateLimitTier": "tier-a",
        "futureProviderField": {"nested": True},
    },
    "_meta": {"email": "account.invalid", "org": None, "kind": "personal", "futureMeta": 3},
    "futureTopLevel": {"nested": 4},
}
updates = {dotted: "redacted-new" for dotted in updates_allowed}
after = copy.deepcopy(before)
for dotted, replacement in updates.items():
    assign(after, dotted, replacement)
assert_writeback(before, after, updates)

for dotted in required:
    broken = copy.deepcopy(after)
    remove(broken, dotted)
    try:
        assert_writeback(before, broken, updates)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"negative control did not detect deletion of {dotted}")

for dotted in ("claudeAiOauth.futureProviderField", "_meta.futureMeta", "futureTopLevel"):
    broken = copy.deepcopy(after)
    remove(broken, dotted)
    try:
        assert_writeback(before, broken, updates)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"negative control did not detect deletion of {dotted}")
PY
if [ "$POOL_SCHEMA_RC" -eq 0 ]; then
  ok "platform pool schema: canonical shape pins every known preservation field"
  ok "platform pool schema negative controls: known and unknown field deletion is rejected"
else
  bad "platform pool schema: shape or deletion controls"
  sed 's/^/    /' "$POOL_SCHEMA_OUT"
fi

# ------------------------------------------------- credential key preservation
# The point of this patch is what SURVIVES the write-back, so the fixture assertions
# check that the refreshed-token merge is applied to the object read from disk (the
# raw JSON / onDisk spread) and not to zod's stripped output.
CRED_CLAUDE="$TMP/quota-claude.js"
reference_preimage "$PATCH_DIR/credential-key-preservation-claude.patch" "$CRED_CLAUDE"
if positive_js "$PATCH_DIR/credential-key-preservation.mjs" "$CRED_CLAUDE" claude \
  && grep -qF '[paseo-cred-preserve]' "$CRED_CLAUDE.paseo-new.mjs" \
  && grep -qF 'const existing = JSON.parse(await fs.readFile(credPath, "utf8"));' "$CRED_CLAUDE.paseo-new.mjs" \
  && grep -qF 'existing.claudeAiOauth = { ...(existing.claudeAiOauth ?? {}), ...oauth };' "$CRED_CLAUDE.paseo-new.mjs" \
  && ! grep -qF 'existing.claudeAiOauth = oauth;' "$CRED_CLAUDE.paseo-new.mjs"; then
  ok "credential preservation claude: merges the refreshed tokens into the on-disk JSON"
else
  bad "credential preservation claude: representative fixture was not patched as intended"
fi
CRED_CLAUDE_BAD="$TMP/quota-claude-bad.js"
cp "$CRED_CLAUDE" "$CRED_CLAUDE_BAD"
sed -i '/existing.claudeAiOauth = oauth;/d' "$CRED_CLAUDE_BAD"
cp "$CRED_CLAUDE_BAD" "$TMP/quota-claude-bad.before"
if negative_js "$PATCH_DIR/credential-key-preservation.mjs" "$CRED_CLAUDE_BAD" 20 "$TMP/quota-claude-bad.before" claude; then
  ok "credential preservation claude negative control: save-body drift is an untouched rc 20 skip"
else
  bad "credential preservation claude negative control: skipped patch did not fail the positive assertion"
fi

CRED_CODEX="$TMP/quota-codex.js"
reference_preimage "$PATCH_DIR/credential-key-preservation-codex.patch" "$CRED_CODEX"
if positive_js "$PATCH_DIR/credential-key-preservation.mjs" "$CRED_CODEX" codex \
  && grep -qF '[paseo-cred-preserve]' "$CRED_CODEX.paseo-new.mjs" \
  && grep -qF 'onDisk = JSON.parse(await fs.readFile(authPath, "utf8"));' "$CRED_CODEX.paseo-new.mjs" \
  && grep -qF 'onDisk = { ...original };' "$CRED_CODEX.paseo-new.mjs" \
  && grep -qF '...(onDisk.tokens ?? {}),' "$CRED_CODEX.paseo-new.mjs" \
  && ! grep -qF '                ...original,' "$CRED_CODEX.paseo-new.mjs"; then
  ok "credential preservation codex: merges the refreshed tokens into the on-disk auth.json"
else
  bad "credential preservation codex: representative fixture was not patched as intended"
fi
CRED_CODEX_BAD="$TMP/quota-codex-bad.js"
cp "$CRED_CODEX" "$CRED_CODEX_BAD"
sed -i '/^                    \.\.\.original\.tokens,$/d' "$CRED_CODEX_BAD"
cp "$CRED_CODEX_BAD" "$TMP/quota-codex-bad.before"
if negative_js "$PATCH_DIR/credential-key-preservation.mjs" "$CRED_CODEX_BAD" 20 "$TMP/quota-codex-bad.before" codex; then
  ok "credential preservation codex negative control: save-body drift is an untouched rc 20 skip"
else
  bad "credential preservation codex negative control: skipped patch did not fail the positive assertion"
fi

# The behaviour check install.sh runs after applying, exercised here offline against the
# same fixtures — with the unpatched preimage as its control, because a check that passes
# on the pristine bundle would be asserting nothing.
for cred_mode in claude codex; do
  case "$cred_mode" in
    claude) cred_pre="$CRED_CLAUDE" ;;
    *) cred_pre="$CRED_CODEX" ;;
  esac
  cred_rc=0
  node "$PATCH_DIR/credential-key-preservation.test.mjs" "$cred_mode" "$cred_pre.paseo-new.mjs" \
    >"$TMP/cred-$cred_mode.out" 2>&1 || cred_rc=$?
  cred_pristine_rc=0
  node "$PATCH_DIR/credential-key-preservation.test.mjs" "$cred_mode" "$cred_pre" \
    >/dev/null 2>&1 || cred_pristine_rc=$?
  if [ "$cred_rc" -eq 0 ] && [ "$cred_pristine_rc" -ne 0 ]; then
    ok "credential preservation $cred_mode behaviour: patched save keeps every field the pristine one drops"
  else
    bad "credential preservation $cred_mode behaviour: patched rc=$cred_rc, pristine control rc=$cred_pristine_rc"
    sed 's/^/    /' "$TMP/cred-$cred_mode.out"
  fi
done

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
    find: 'if(!Ye||!(0,Be.getIsElectron)())return;e?.paneId&&at(Ye,e.paneId);const{browserId:t}=(0,le.createWorkspaceBrowser)()',
    repl: 'if(!Ye)return;e?.paneId&&at(Ye,e.paneId);const{browserId:t}=(0,le.createWorkspaceBrowser)()',
  },
  {
    find: 'if(!Ye||!(0,Be.getIsElectron)())return;const{browserId:t}=(0,le.createWorkspaceBrowser)({initialUrl:e})',
    repl: 'if(!Ye)return;const{browserId:t}=(0,le.createWorkspaceBrowser)({initialUrl:e})',
  },
  {
    find: '{style:u.container,children:[S,_,I]})',
    repl: '{style:u.container,dataSet:{paseoBrowserId:w,paseoWorkspaceId:f.workspaceId,paseoServerId:f.serverId},children:[S,_,I]})',
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

printf 'paseo-patch-drift: %s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
