#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";
// Deterministic, fail-loud web-ui bundle patcher.
//
// Usage:
//   node bin/patch-web-ui.js --subagent-stream <web-ui-dir>
//   node bin/patch-web-ui.js --browse <web-ui-dir> <companion-js-path>
//   node bin/patch-web-ui.js <web-ui-dir> <companion-js-path>  # legacy --browse
//
// The always-on subagent-stream group makes a visible provider-subagent panel
// subscribe to its parent agent's timeline. The optional browse group applies
// THREE minimal, verified-unique edits so the self-hosted web runtime can open
// live browser panels:
//   1+2. un-gate the "New browser" button callbacks (vo/Wo) on web;
//   3.   mark the BrowserPane container with data-paseo-* so the companion mounts.
// Then injects the companion <script> into index.html and installs the companion.
//
// Fail-loud, unlike the warn-only depth4 patch: if the
// bundle SHA does not match the pin AND the bundle is not already patched, we
// REFUSE (exit 1) rather than run an unpatched/half-patched build. On a
// @getpaseo/cli version bump the SHA changes -> this fails -> a human re-derives
// the anchors (see "Re-deriving the anchors" in ../README.md).

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const childProcess = require("node:child_process");

// SHA-256 of the ORIGINAL (unpatched) bundle we derived anchors against.
const PINNED_SHA = "435dff4ee752a352ee81ff1eae02338163455b2f7e9b605f1ef30967007ce28c";
const GENERAL_ONLY_SHA = "6cc40f4d39f1bd9a65234c360b134ee6342afd2ac877586e3f61ee35d81a6eff";
// SHA-256 of the fully patched browse group (all FOUR anchors). Until 2026-08-21
// the fourth (coarse-pointer) edit shipped only from the reference box's own tree,
// so this hash was the one labelled "legacy" here — the bytes did not change, the
// owner of the fourth anchor did.
const BROWSE_ONLY_SHA = "769e57f5fbdc31a9a8bbcf32ee8de6602c61f1705102f7e7ff5d9ebbd733117a";
const COMBINED_SHA = "c74929516273d623698ab4646a5ffa826af35edfc714e0997e1ef4581eb5dfe2";
// The transitional shape: a box installed by an earlier revision of THIS patcher
// carries the first three browse edits and not the fourth. It is a state we must
// recognise (not refuse) so such a box gains the fourth anchor on the next install
// instead of failing the SHA pin. Retire these two once no box reports them.
const THREE_ANCHOR_BROWSE_ONLY_SHA = "8a31b87021fc2e0b70b8b2009fd7bf19bd9da89f4ae0c86af2353ae5e1bcb6b9";
const THREE_ANCHOR_COMBINED_SHA = "fa7c2470a1040b886125c5a58ed53b87e0c222b3b6a73f3a81588d502f75540f";
const PINNED_VERSION = "@getpaseo/cli@0.2.5 (index-55db56b9)";

// Each anchor MUST occur exactly once in the pinned bundle (verified).
// The two gate anchors carry minifier-local names, which are NOT stable across
// versions even when the code is unchanged: 0.1.110 -> 0.2.5 renamed ze->Ye,
// Re->Be, qe->at, ie->le and changed nothing else about these two callbacks.
const BROWSE_PATCHES = [
  {
    name: "new-browser-gate-vo",
    find: 'if(!Ye||!(0,Be.getIsElectron)())return;e?.paneId&&at(Ye,e.paneId);const{browserId:t}=(0,le.createWorkspaceBrowser)()',
    repl: 'if(!Ye)return;e?.paneId&&at(Ye,e.paneId);const{browserId:t}=(0,le.createWorkspaceBrowser)()',
  },
  {
    name: "new-browser-gate-Wo",
    find: 'if(!Ye||!(0,Be.getIsElectron)())return;const{browserId:t}=(0,le.createWorkspaceBrowser)({initialUrl:e})',
    repl: 'if(!Ye)return;const{browserId:t}=(0,le.createWorkspaceBrowser)({initialUrl:e})',
  },
  {
    name: "browserpane-marker",
    find: '{style:u.container,children:[S,_,I]})',
    repl: '{style:u.container,dataSet:{paseoBrowserId:w,paseoWorkspaceId:f.workspaceId,paseoServerId:f.serverId},children:[S,_,I]})',
  },
  {
    // Project row trailing actions ("+" new worktree, kebab menu). Stock shows them
    // on `isHovered || isNative || isMobileBreakpoint`, and the compact breakpoint is
    // under 720px. A tablet is wide enough to miss the breakpoint and has no hover, so
    // the first tap is spent manufacturing one (and it selects the project instead).
    // Any coarse pointer gets them unconditionally; a phone already qualifies via the
    // breakpoint, so this only changes touch tablets and desktop-width touch screens.
    // Upstream has not fixed it: `(pointer: coarse)` occurs 0x in the 0.2.5 bundle.
    name: "project-actions-coarse-pointer",
    find: ',isProjectActive:d,onBeginWorkspaceSetup:h,onRemoveProject:b,removeProjectStatus:w}=e,k=c||we.isNative||l,',
    repl: ',isProjectActive:d,onBeginWorkspaceSetup:h,onRemoveProject:b,removeProjectStatus:w}=e,k=c||we.isNative||l||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches,',
  },
];
const SUBAGENT_STREAM_PATCHES = [
  {
    name: "provider-subagent-visible-parent",
    find: 'return"agent"===l?.kind?[l.agentId]:[]',
    repl: 'return"agent"===l?.kind?[l.agentId]:"provider_subagent"===l?.kind?[l.parentAgentId]:[]',
  },
];
const GROUPS = {
  browse: BROWSE_PATCHES,
  "subagent-stream": SUBAGENT_STREAM_PATCHES,
};
const SCRIPT_TAG = '<script src="/browse-view-client.js" defer></script>';

function die(msg) {
  console.error("[patch-web-ui] FATAL: " + msg);
  process.exit(1);
}
function log(msg) { console.log("[patch-web-ui] " + msg); }

function occurrences(hay, needle) {
  let n = 0, i = 0;
  for (;;) {
    const j = hay.indexOf(needle, i);
    if (j < 0) break;
    n++; i = j + needle.length;
  }
  return n;
}

function removeSiblings(file) {
  for (const ext of [".br", ".gz"]) {
    try { fs.rmSync(file + ext, { force: true }); } catch {}
  }
}

function findBundle(webuiDir) {
  const dir = path.join(webuiDir, "_expo", "static", "js", "web");
  // Prefer the bundle index.html actually references. This is robust to a
  // half-done cache-bust rename (old + new bundle can briefly coexist after a
  // crash): index.html is the single source of truth for what is served.
  try {
    const html = fs.readFileSync(path.join(webuiDir, "index.html"), "utf8");
    const m = html.match(/index-[0-9a-f]+\.js/);
    if (m && fs.existsSync(path.join(dir, m[0]))) return path.join(dir, m[0]);
  } catch {}
  let files = [];
  try { files = fs.readdirSync(dir); } catch { die(`web-ui js dir not found: ${dir}`); }
  const idx = files.filter((f) => /^index-[0-9a-f]+\.js$/.test(f));
  if (idx.length !== 1) die(`cannot resolve web-ui bundle: index.html references none on disk and found ${idx.length} index-*.js in ${dir}`);
  return path.join(dir, idx[0]);
}

// The patched bundle's cache-busting filename = index-<md5(patched)>.js. Expo
// serves it `immutable, max-age=1yr`, so the URL MUST change when content does.
function patchedName(src) {
  return "index-" + crypto.createHash("md5").update(src).digest("hex") + ".js";
}

// Match and replace the bundle without touching the filesystem. The test suite uses this
// seam with a synthetic bundle whose SHA is supplied as `expectedSha`; the CLI keeps the
// real PINNED_SHA default below. Keeping the SHA check in this core is important: the
// fixture test proves the anchor checks, while the CLI still refuses an unrecognised
// pristine @getpaseo bundle.
function patchGroupState(src, name, patches) {
  let oldCount = 0;
  let newCount = 0;
  for (const patch of patches) {
    const oldOccurrences = occurrences(src, patch.find);
    const newOccurrences = occurrences(src, patch.repl);
    if (oldOccurrences === 1 && newOccurrences === 0) oldCount++;
    else if (oldOccurrences === 0 && newOccurrences === 1) newCount++;
    else {
      throw new Error(`bundle half/ambiguous ${name} patch: ${patch.name} old=${oldOccurrences} new=${newOccurrences} — refusing`);
    }
  }
  if (oldCount === patches.length) return "unpatched";
  if (newCount === patches.length) return "patched";
  // Every patch in the group answered unambiguously, but they disagree: some are
  // applied and some are not. That is what a box installed by an earlier revision
  // of this patcher looks like after the group grows an anchor, so it is a state
  // rather than a fault. It is NOT waved through — the caller still has to match a
  // named SHA for it, and "partial" never takes the already-patched early return,
  // so the missing replacements get applied.
  return "partial";
}

function normalizePatchOptions(expectedShaOrOptions) {
  if (typeof expectedShaOrOptions === "string" || expectedShaOrOptions === undefined) {
    return {
      mode: "browse",
      acceptedShas: [expectedShaOrOptions ?? PINNED_SHA],
      validateOtherGroups: false,
    };
  }
  const mode = expectedShaOrOptions.mode ?? "browse";
  if (!Object.hasOwn(GROUPS, mode)) throw new Error(`unknown patch mode: ${mode}`);
  return {
    mode,
    acceptedShas: expectedShaOrOptions.acceptedShas ?? null,
    validateOtherGroups: expectedShaOrOptions.validateOtherGroups ?? true,
  };
}

function productionShasForStates(states) {
  const general = states["subagent-stream"];
  const browse = states.browse;
  if (general === "unpatched" && browse === "unpatched") return [PINNED_SHA];
  if (general === "patched" && browse === "unpatched") return [GENERAL_ONLY_SHA];
  if (general === "unpatched" && browse === "patched") return [BROWSE_ONLY_SHA];
  if (general === "patched" && browse === "patched") return [COMBINED_SHA];
  if (general === "unpatched" && browse === "partial") return [THREE_ANCHOR_BROWSE_ONLY_SHA];
  if (general === "patched" && browse === "partial") return [THREE_ANCHOR_COMBINED_SHA];
  throw new Error(`unsupported patch state: general=${general} browse=${browse}`);
}

// Match and replace one independent group without touching the filesystem.
// The legacy `(src, expectedSha)` form remains the browse-group test seam.
function patchBundleContent(src, expectedShaOrOptions = PINNED_SHA) {
  const options = normalizePatchOptions(expectedShaOrOptions);
  const states = {};
  for (const [name, patches] of Object.entries(GROUPS)) {
    if (name !== options.mode && !options.validateOtherGroups) continue;
    states[name] = patchGroupState(src, name, patches);
  }
  // Historical pure-function tests pass the pristine fixture SHA again on the
  // idempotence call. Preserve that seam only when other-group validation was
  // explicitly disabled; production CLI calls always validate the full state
  // and its SHA below.
  if (!options.validateOtherGroups && states[options.mode] === "patched") {
    return { source: src, alreadyPatched: true, mode: options.mode, states };
  }
  const sha = crypto.createHash("sha256").update(src).digest("hex");
  const acceptedShas = options.acceptedShas ?? productionShasForStates(states);
  if (!acceptedShas.includes(sha)) {
    throw new Error(`bundle SHA mismatch — got ${sha}, accepted ${acceptedShas.join(",")} (${PINNED_VERSION}).\n` +
        `  The @getpaseo/cli web-ui bundle is not a recognised state for ${options.mode}. ` +
        `Re-derive the anchors and state hashes, then re-run. Refusing to modify it.`);
  }
  if (states[options.mode] === "patched") {
    return { source: src, alreadyPatched: true, mode: options.mode, states };
  }

  const patches = GROUPS[options.mode];
  for (const p of patches) src = src.replace(p.find, p.repl);
  for (const p of patches) {
    if (occurrences(src, p.find) !== 0) throw new Error(`post-patch: original anchor ${p.name} still present`);
    if (!src.includes(p.repl)) throw new Error(`post-patch: replacement ${p.name} not applied`);
  }
  return { source: src, alreadyPatched: false, mode: options.mode, states };
}

// Patch the bundle AND cache-bust it. Expo serves index-<hash>.js as
// `immutable, max-age=1yr`; patching in place keeps the same URL, so browsers
// that cached the pre-patch bundle serve STALE bytes forever (dead "New browser"
// button — observed live 2026-07-22). We write the patched bytes under a NEW
// content-hash filename. Crash-safety (adversarial review P1): we WRITE the new
// bundle but keep the old one — the caller repoints index.html FIRST, then
// cleanupOldBundles() removes stragglers. So at every crash point index.html
// still references a bundle that exists on disk, and a re-run self-heals
// (findBundle keys off index.html). Returns {filename, oldFilename}.
function checkBundleSyntax(bundlePath) {
  const result = childProcess.spawnSync(process.execPath, ["--check", bundlePath], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`patched bundle failed node --check: ${result.stderr || result.stdout || `exit ${result.status}`}`);
  }
}

function patchBundle(bundlePath, mode) {
  const dir = path.dirname(bundlePath);
  const curName = path.basename(bundlePath);
  let src = fs.readFileSync(bundlePath, "utf8");
  let result;
  try {
    result = patchBundleContent(src, { mode });
  }
  catch (err) {
    die(String(err instanceof Error ? err.message : err));
  }
  src = result.source;

  if (result.alreadyPatched) {
    // Already patched. Migrate a bundle patched in place under the ORIGINAL name
    // to its content-hash name so immutable-cached clients stop getting stale bytes.
    const want = patchedName(src);
    if (curName === want) {
      try { checkBundleSyntax(bundlePath); }
      catch (err) { die(String(err instanceof Error ? err.message : err)); }
      log(`${mode} bundle already patched + cache-busted (idempotent) ✓`);
      return { filename: curName, oldFilename: curName };
    }
    fs.writeFileSync(path.join(dir, want), src); // keep curName until index.html is repointed
    removeSiblings(path.join(dir, want));
    try { checkBundleSyntax(path.join(dir, want)); }
    catch (err) {
      try { fs.rmSync(path.join(dir, want), { force: true }); } catch {}
      die(String(err instanceof Error ? err.message : err));
    }
    log(`${mode} bundle already patched → cache-busting rename ✓ ${curName} → ${want}`);
    return { filename: want, oldFilename: curName };
  }

  const newName = patchedName(src);
  fs.writeFileSync(path.join(dir, newName), src); // keep curName until index.html is repointed
  removeSiblings(path.join(dir, newName));         // no stale compressed siblings for the new bundle
  try { checkBundleSyntax(path.join(dir, newName)); }
  catch (err) {
    try { fs.rmSync(path.join(dir, newName), { force: true }); } catch {}
    die(String(err instanceof Error ? err.message : err));
  }
  log(`${mode} bundle patched (${GROUPS[mode].length} edits) + cache-busted ✓ ${curName} → ${newName}`);
  return { filename: newName, oldFilename: curName };
}

// Repoint index.html's bundle reference to the cache-busted filename. index.html
// is served no-cache, so this is what makes every client re-fetch the new URL.
function updateBundleRef(webuiDir, oldFilename, newFilename) {
  if (oldFilename === newFilename) return;
  const htmlPath = path.join(webuiDir, "index.html");
  let html = fs.readFileSync(htmlPath, "utf8");
  if (!html.includes(oldFilename)) {
    if (html.includes(newFilename)) { log("index.html bundle ref already cache-busted ✓"); return; }
    die(`index.html references neither ${oldFilename} nor ${newFilename} — cannot repoint bundle`);
  }
  html = html.split(oldFilename).join(newFilename);
  fs.writeFileSync(htmlPath, html);
  removeSiblings(htmlPath);
  log(`index.html bundle ref cache-busted ✓ ${oldFilename} → ${newFilename}`);
}

// Remove every index-*.js (and compressed siblings) that is NOT the served
// bundle. Runs AFTER index.html is repointed, so deleting the old bundle can
// never leave index.html pointing at a missing file. Idempotent.
function cleanupOldBundles(webuiDir, keepFilename) {
  const dir = path.join(webuiDir, "_expo", "static", "js", "web");
  let files = [];
  try { files = fs.readdirSync(dir); } catch { return; }
  for (const f of files) {
    if (/^index-[0-9a-f]+\.js$/.test(f) && f !== keepFilename) {
      try { fs.rmSync(path.join(dir, f), { force: true }); } catch {}
      removeSiblings(path.join(dir, f));
      log(`removed stale bundle ${f}`);
    }
  }
}

function injectHtml(webuiDir) {
  const htmlPath = path.join(webuiDir, "index.html");
  let html;
  try { html = fs.readFileSync(htmlPath, "utf8"); } catch { die(`index.html not found: ${htmlPath}`); }
  if (html.includes(SCRIPT_TAG)) { log("index.html already injected (idempotent) ✓"); return; }
  if (!html.includes("</body>")) die("index.html has no </body> to inject before");
  html = html.replace("</body>", "  " + SCRIPT_TAG + "\n</body>");
  fs.writeFileSync(htmlPath, html);
  removeSiblings(htmlPath); // force plaintext serve so the <script> takes effect
  log("index.html companion <script> injected ✓");
}

function installCompanion(webuiDir, companionPath) {
  if (!fs.existsSync(companionPath)) die(`companion js not found: ${companionPath}`);
  const dest = path.join(webuiDir, "browse-view-client.js");
  fs.copyFileSync(companionPath, dest);
  removeSiblings(dest);
  log("companion browse-view-client.js installed ✓");
}

function main() {
  let mode;
  let webuiDir;
  let companionPath;
  if (process.argv[2] === "--subagent-stream") {
    mode = "subagent-stream";
    webuiDir = process.argv[3];
    if (!webuiDir || process.argv[4]) die("usage: patch-web-ui.js --subagent-stream <web-ui-dir>");
  }
  else if (process.argv[2] === "--browse") {
    mode = "browse";
    webuiDir = process.argv[3];
    companionPath = process.argv[4];
    if (!webuiDir || !companionPath || process.argv[5]) die("usage: patch-web-ui.js --browse <web-ui-dir> <companion-js-path>");
  }
  else {
    // Backward compatibility for callers predating the explicit mode split.
    mode = "browse";
    webuiDir = process.argv[2];
    companionPath = process.argv[3];
    if (!webuiDir || !companionPath || process.argv[4]) die("usage: patch-web-ui.js <web-ui-dir> <companion-js-path>");
  }
  if (!fs.existsSync(webuiDir)) die(`web-ui dir not found: ${webuiDir}`);
  const bundlePath = findBundle(webuiDir);
  const { filename, oldFilename } = patchBundle(bundlePath, mode);
  updateBundleRef(webuiDir, oldFilename, filename); // repoint FIRST (index.html is no-cache)
  cleanupOldBundles(webuiDir, filename);            // THEN drop the old bundle — never orphan index.html
  if (mode === "browse") {
    injectHtml(webuiDir);
    installCompanion(webuiDir, companionPath);
  }
  log("done.");
}

module.exports = {
  BROWSE_PATCHES,
  BROWSE_ONLY_SHA,
  COMBINED_SHA,
  GENERAL_ONLY_SHA,
  PINNED_SHA,
  THREE_ANCHOR_BROWSE_ONLY_SHA,
  THREE_ANCHOR_COMBINED_SHA,
  SUBAGENT_STREAM_PATCHES,
  patchBundleContent,
  patchedName,
  productionShasForStates,
};

if (require.main === module) main();
