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
// The always-on general group (CLI flag `--subagent-stream`, kept for callers that
// predate it carrying more than one edit) applies SEVEN edits every box wants: a
// visible provider-subagent panel subscribes to its parent agent's timeline; the
// fresh-install font-size defaults move to 18 (ui) / 14 (code); the sidebar order
// store points at the airlock ui-state backend so the order follows the owner across
// devices instead of living in one browser; an already-open tab rehydrates that order
// when it becomes visible; a device that cannot hover is treated as
// compact for the tooltip gate; a coarse pointer gets the project row's trailing
// actions without having to manufacture a hover first; and a sidebar tap stops being
// swallowed by the long-press/drag machinery web never arms. The optional browse
// group applies THREE minimal, verified-unique edits so the self-hosted web runtime
// can open live browser panels:
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
// Every bundle shape the fleet is known to carry: the pinned upstream bundle plus a
// SUBSET of this file's edits, keyed by exactly which edits it holds.
//
// Two things put a box on an older subset. A group GROWS an anchor (this happened
// three times to the general group and once to browse), and an edit MOVES between
// groups — `project-actions-coarse-pointer` did, when it stopped riding on the
// optional browse group and joined the always-on one. Either way the box must be
// RECOGNISED and completed on the next install rather than refused, and a subset
// nobody ever shipped must still be refused. That is why this is a table of shapes
// and not "any subset goes": the SHA pin still names what upstream's bytes are.
//
// Each sha256 covers the whole bundle and was re-derived from the pristine bundle by
// applying exactly the listed edits — order-independent, the nine sites are disjoint:
//   npm pack @getpaseo/server@0.2.5 && tar xzf getpaseo-server-0.2.5.tgz
//   # apply the subset to package/dist/server/web-ui/_expo/static/js/web/index-*.js
const KNOWN_BUNDLE_SHAPES = [
  { sha: PINNED_SHA, edits: [] },

  // --- the always-on general group, one era per row (browse never applied) ---
  { sha: "6cc40f4d39f1bd9a65234c360b134ee6342afd2ac877586e3f61ee35d81a6eff",
    edits: ["provider-subagent-visible-parent"] },
  { sha: "c0e1972ed7be9fff2df9d4c1fb9c90ba4dc39fd412a522d98ae3776fb0741de6",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes"] },
  { sha: "670b7048aaac21d29a04e4a7e44fcee049c65d81b98ded03fad71b79e8afadba",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage"] },
  // The shape every browse-less box carried before the coarse-pointer edit moved in.
  { sha: "702134b78675e2323e094db041086c53f70020f19aa0b1bc32492d2cb2cebaea",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "tooltip-hover-none-is-compact"] },
  // ...and the shape this revision installs there instead: the tablet "+" fix no
  // longer costs a 150MB chromium download to receive.
  { sha: "6a6acb81ced1dfd6982f19e0c5f0c7fa80fea7738ef4f4def28dbe6eb1ca064e",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "tooltip-hover-none-is-compact",
            "project-actions-coarse-pointer"] },
  // A device that was already open now rehydrates the shared order when its tab
  // becomes visible.
  { sha: "b9aa1eac972a2030f03e8c786830a07d40f13839c658664c20c628dcb47c0cea",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "project-actions-coarse-pointer"] },
  // ...and the current browse-less shape: a sidebar tap is no longer swallowed by the
  // long-press/drag machinery web never arms. A browse box passes through here too —
  // the always-on group runs first, so this is also its mid-install state.
  { sha: "e77864d635f9699e555e83d5a456425694b78745b98cc8249a010ac0c10223d3",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "project-actions-coarse-pointer",
            "sidebar-tap-not-swallowed-on-web"] },

  // --- the same eras again on a box that also runs the browse group ---
  // `project-actions-coarse-pointer` shipped FROM the browse group until this
  // revision, so every pre-move browse box already holds it: that is why it appears
  // beside a general group that is otherwise one, two, three or four edits old.
  { sha: "8a31b87021fc2e0b70b8b2009fd7bf19bd9da89f4ae0c86af2353ae5e1bcb6b9",
    edits: ["new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  { sha: "769e57f5fbdc31a9a8bbcf32ee8de6602c61f1705102f7e7ff5d9ebbd733117a",
    edits: ["new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  { sha: "fa7c2470a1040b886125c5a58ed53b87e0c222b3b6a73f3a81588d502f75540f",
    edits: ["provider-subagent-visible-parent",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  { sha: "c74929516273d623698ab4646a5ffa826af35edfc714e0997e1ef4581eb5dfe2",
    edits: ["provider-subagent-visible-parent",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  { sha: "7702c7e018ebadbaef91d40440c3e898ac419bb417b2bf9494924c6be6ee0164",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  { sha: "67646ec71d1e64db703b1b0d5277dc1898501b73ab67b048884c6b578e704549",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  { sha: "9f5c599500b78a69b8771ff3df7cb05dc58982354d4b22df24d9072182cf65bb",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  { sha: "f89ae3ae99905c0c1e1c8e6090e0e44dcd10fd8043c80338aa1792704fcb0e67",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  { sha: "0d175c93d202803e17ea539ab4ce17fd109004fb062141ffa72d2e0e6bbbd82a",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "tooltip-hover-none-is-compact",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  // Fully patched: identical bytes before and after the move, because the move
  // changed which group owns an edit and not which edits the bundle carries.
  { sha: "32719926ca9df3ce3600cd11aef9c4d7ceb1d5ee9a36e9b8e64310eca301aabd",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "tooltip-hover-none-is-compact",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  // Fully patched, including visibility-triggered shared-order rehydration.
  { sha: "9f0ef2a3fd13ec714d4d9b95324d6b21136ef85bcb1ecf3e1e1baee81339a8b6",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "new-browser-gate-vo",
            "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer"] },
  // Fully patched, this revision: the same browse box after the sidebar-tap fix.
  { sha: "9dc8c8fbd96032688977bc3b219587884930a3e53c94309d04a297fd76cb9d3c",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "new-browser-gate-vo",
            "new-browser-gate-Wo", "browserpane-marker",
            "project-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web"] },
];
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
];
const SIDEBAR_STORAGE_LEGACY = '{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(l=>{const u=e=>"/airlock-ui-state/"+encodeURIComponent(e);return{getItem:async e=>{try{const t=await fetch(u(e),{cache:"no-store"});if(t.ok)return await t.text()}catch(t){}return l.getItem(e)},setItem:async(e,t)=>{await l.setItem(e,t);try{await fetch(u(e),{method:"PUT",headers:{"content-type":"application/json"},body:t})}catch(n){}},removeItem:async e=>{await l.removeItem(e);try{await fetch(u(e),{method:"DELETE"})}catch(t){}}}})(o.default))),partialize:';
const SIDEBAR_STORAGE_DURABLE = '{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(l=>{const u=e=>"/airlock-ui-state/"+encodeURIComponent(e),p=e=>"@airlock-pending:"+e;let q=Promise.resolve(),r=Promise.resolve(),h=0;const v=new Map,x=e=>{const t=q.catch(()=>{}).then(e);return q=t,t},b=e=>{const t=r.catch(()=>{}).then(e);return r=t,t},y=(e,t)=>{const n={i:++h,v:t};return v.set(e,n),n},z=e=>v.get(e).v,s=async(e,t,n)=>{const o=null===t?"":t;if(n&&v.get(e)!==n||await l.getItem(p(e))!==o)return;const c=await fetch(u(e),null===t?{method:"DELETE"}:{method:"PUT",headers:{"content-type":"application/json"},body:t});if(!c.ok)throw Error("ui-state write failed: "+c.status);(n?v.get(e)===n:!v.has(e))&&(await l.getItem(p(e)))===o&&await l.removeItem(p(e))};return{getItem:e=>x(async()=>{if(v.has(e))return z(e);const t=await l.getItem(p(e));if(null!==t){const n=""===t?null:t;try{await s(e,n)}catch(o){}return v.has(e)?z(e):n}try{const t=await fetch(u(e),{cache:"no-store"});if(t.ok){const n=await t.text();if(v.has(e))return z(e);return await l.setItem(e,n),v.has(e)?z(e):n}}catch(t){}return v.has(e)?z(e):l.getItem(e)}),setItem:(e,t)=>{const n=y(e,t),o=b(async()=>{if(v.get(e)!==n)return;await l.setItem(e,t),await l.setItem(p(e),t)});return x(async()=>{await o;if(v.get(e)!==n)return;try{await s(e,t,n)}catch(c){}v.get(e)===n&&v.delete(e)})},removeItem:e=>{const t=y(e,null),n=b(async()=>{if(v.get(e)!==t)return;await l.removeItem(e),await l.setItem(p(e),"")});return x(async()=>{await n;if(v.get(e)!==t)return;try{await s(e,null,t)}catch(o){}v.get(e)===t&&v.delete(e)})}}})(o.default))),partialize:';
const SUBAGENT_STREAM_PATCHES = [
  {
    name: "provider-subagent-visible-parent",
    find: 'return"agent"===l?.kind?[l.agentId]:[]',
    repl: 'return"agent"===l?.kind?[l.agentId]:"provider_subagent"===l?.kind?[l.parentAgentId]:[]',
  },
  {
    // Fresh-install appearance defaults: DEFAULT_UI_FONT_SIZE 16 -> 18 and
    // DEFAULT_CODE_FONT_SIZE 12 -> 14, inside the clamps the settings UI already
    // enforces (ui 11..24, code 9..22 — left untouched here). Both are per-device
    // settings persisted under `@paseo:app-settings`, so this moves what a device
    // gets when it has NEVER saved settings; a device that already stored a value
    // keeps it and must change it in Settings -> Appearance.
    name: "appearance-default-font-sizes",
    find: "b=1e4,S=0,h=1e6,_=16,O=11,T=24,F=12,I=9,E=22,N=200",
    repl: "b=1e4,S=0,h=1e6,_=18,O=11,T=24,F=14,I=9,E=22,N=200",
  },
  {
    // Cross-device sidebar order. Upstream persists the project/workspace order in
    // this ONE store, through AsyncStorage — localStorage on web — so the order is a
    // property of the browser, not of the box, and a drag on the Mac is invisible on
    // the iPad. The daemon has no route that would hold it either. This swaps that
    // store's storage (and only that store's) for the airlock ui-state backend behind
    // the same owner gate, keeping the local one as the write-through cache:
    //   read  — server first; 404 or unreachable falls back to what this device kept,
    //   write — local first (so an offline reorder still sticks), then the server.
    // The fallback is what keeps a non-airlock or service-down box working exactly as
    // upstream does, instead of losing the order to a failed fetch.
    name: "sidebar-order-shared-storage",
    find: '{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>o.default),partialize:',
    repl: SIDEBAR_STORAGE_DURABLE,
    // PR #256 shipped the first adapter without an outbox or write queue. Treat its
    // exact bytes as a named migration source: the SHA still has to match a known
    // fleet shape, then this patch upgrades it in place.
    legacyRepls: [SIDEBAR_STORAGE_LEGACY],
  },
  {
    // A second device commonly already has Paseo open. Persist hydrates only once,
    // so the server-first adapter above does not run again merely because the owner
    // switches back to that tab: the in-memory sidebar keeps the device's old order
    // until a full refresh. Rehydrate when a hidden tab becomes visible. Zustand's
    // persist rehydrate updates the existing store (and therefore the rendered
    // sidebar) without restarting Paseo or reloading the page.
    name: "sidebar-order-rehydrate-on-visibility",
    find: 'partialize:e=>({projectOrder:e.projectOrder,workspaceOrderByProject:e.workspaceOrderByProject}),version:1,migrate:j}))},3544,[3368,3273,3276]);',
    repl: 'partialize:e=>({projectOrder:e.projectOrder,workspaceOrderByProject:e.workspaceOrderByProject}),version:1,migrate:j}));"undefined"!=typeof document&&document.addEventListener("visibilitychange",()=>{"visible"===document.visibilityState&&f.persist.rehydrate()})},3544,[3368,3273,3276]);',
  },
  {
    // Tooltips are gated on useIsCompactFormFactor() — the xs/sm breakpoint — and a
    // phone in landscape is ~850px wide, so it does not qualify: hover tooltips stay
    // enabled and iOS Safari's synthesized mouseover opens one on a tap. Nothing then
    // closes it (the trigger's own press is what dismisses it, and the tap that opened
    // it landed on a neighbour), so the tooltip parks over the composer and swallows
    // the send control. Reported from a phone, 2026-08-28.
    // A device that cannot hover is treated as compact for this gate only, which is
    // the branch upstream already wrote for phones: `enabled` becomes enabledOnMobile
    // (false at all but two call sites) and the two that opt in switch to open-on-tap.
    // Desktop is untouched — the media query is false there. `(hover: none)` occurs 0x
    // in the 0.2.5 bundle, so upstream has not fixed this.
    name: "tooltip-hover-none-is-compact",
    find: "const[E,S]=j(C),P=(0,y.useIsCompactFormFactor)(),z=P?w:v;",
    repl: 'const[E,S]=j(C),P=(0,y.useIsCompactFormFactor)()||"undefined"!=typeof window&&!0===window.matchMedia?.("(hover: none)")?.matches,z=P?w:v;',
  },
  {
    // Project row trailing actions ("+" new worktree, kebab menu). Stock shows them
    // on `isHovered || isNative || isMobileBreakpoint`, and the compact breakpoint is
    // under 720px. A tablet is wide enough to miss the breakpoint and has no hover, so
    // the first tap is spent manufacturing one (and it selects the project instead).
    // Any coarse pointer gets them unconditionally; a phone already qualifies via the
    // breakpoint, so this only changes touch tablets and desktop-width touch screens.
    // Upstream has not fixed it: `(pointer: coarse)` occurs 0x in the 0.2.5 bundle.
    // Shipped from the OPTIONAL browse group until 2026-09-01, which made a touch fix
    // conditional on an unrelated feature: a box with `browse = false` — the default —
    // silently never received it, and reaching it cost a ~150MB chromium download it
    // has no other use for. Measured on two boxes the same day: the browse box had the
    // edit, the browse-less one did not, same paseo build. It belongs here, where every
    // box gets it.
    // `(pointer: coarse)` is the right query, MEASURED on the reporting device rather
    // than assumed: an iPad Pro (1366x1024) WITH the Magic Keyboard attached answers
    // pointer:coarse=true, any-pointer:fine=false, hover:none=true — iPadOS does not
    // report the trackpad as a pointing device at all, so `any-pointer` would widen the
    // gate without fixing anything here (2026-09-01).
    name: "project-actions-coarse-pointer",
    find: ',isProjectActive:d,onBeginWorkspaceSetup:h,onRemoveProject:b,removeProjectStatus:w}=e,k=c||we.isNative||l,',
    repl: ',isProjectActive:d,onBeginWorkspaceSetup:h,onRemoveProject:b,removeProjectStatus:w}=e,k=c||we.isNative||l||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches,',
  },
  {
    // A tap on a sidebar row does nothing; the SECOND tap navigates. Reported from an
    // iPad, 2026-09-05 — "the left tab needs a double click".
    // Both sidebar rows (project and workspace) wrap their press as
    //   didLongPressRef.current ? (didLongPressRef.current = false) : onPress()
    // so a raised flag eats exactly one tap and clears itself, which is precisely the
    // two-tap symptom. The flag belongs to useLongPressDragInteraction, whose
    // handleTouchMove raises it as soon as decideLongPressMove reports `vertical_scroll`
    // (>6px, dy-dominant) or `cancel_long_press` (>10px total) — a range an ordinary
    // finger tap covers.
    // On web the flag guards nothing. The same hook already disables its long-press and
    // context-menu timers with `o.isWeb||(...)`, and this bundle's platform module
    // reports isWeb=true / isNative=false, so dragArmed, didStartDrag and the menu flag
    // can never become true and handleLongPress is a no-op. The handler still writes its
    // own scratch refs, but the only effect that ESCAPES the hook on web — the only one
    // anything outside can observe — is poisoning didLongPressRef. So web gets the no-op
    // handler outright, on the same predicate upstream already gates the timers with —
    // not a slop-threshold tweak, which would keep swallowing taps that drift further.
    // The platform test sits OUTSIDE the handler, in the hook body, deliberately: the
    // handler declares its own `const o={x:c,y:u}` for the current point, so an
    // `o.isWeb` written INSIDE it resolves to that local in its temporal dead zone and
    // throws on every touchmove. Measured — the first draft of this edit did exactly
    // that, and `node --check` cannot see it; driving the extracted hook is what did.
    // What now cancels a press that was really a scroll is the browser: react-native-web's
    // PressResponder fires onPress from the DOM `onClick` handler, and a browser does not
    // synthesise `click` after a touch that scrolled. That is the mechanism, read out of
    // this bundle; it is NOT an iOS measurement, so scroll-then-release and end-of-list
    // overscroll are what to watch on a real tablet. Desktop is unaffected outright — a
    // mouse emits no touchmove at all.
    name: "sidebar-tap-not-swallowed-on-web",
    find: 'c[13]===Symbol.for("react.memo_cache_sentinel")?(B=e=>{const t=R.current;if(!t||p.current||x.current)return;',
    repl: 'c[13]===Symbol.for("react.memo_cache_sentinel")?(B=o.isWeb?()=>{}:e=>{const t=R.current;if(!t||p.current||x.current)return;',
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
// Returns { state, applied } — `applied` names the group's edits this bundle already
// carries, which is what identifies its shape below. Group state alone cannot: two
// different subsets of the same group both read "partial".
function patchGroupState(src, name, patches) {
  let oldCount = 0;
  const applied = [];
  for (const patch of patches) {
    const oldOccurrences = occurrences(src, patch.find);
    const newOccurrences = occurrences(src, patch.repl);
    const legacyOccurrences = (patch.legacyRepls ?? []).reduce(
      (count, legacy) => count + occurrences(src, legacy),
      0,
    );
    if (oldOccurrences === 1 && newOccurrences === 0 && legacyOccurrences === 0) oldCount++;
    else if (oldOccurrences === 0 && newOccurrences === 1 && legacyOccurrences === 0) applied.push(patch.name);
    else if (oldOccurrences === 0 && newOccurrences === 0 && legacyOccurrences === 1) {
      // The old adapter is a shipped edit (so include it in the shape lookup) but
      // still needs this revision applied (so count it as old for group state).
      applied.push(patch.name);
      oldCount++;
    }
    else {
      throw new Error(`bundle half/ambiguous ${name} patch: ${patch.name} old=${oldOccurrences} new=${newOccurrences} legacy=${legacyOccurrences} — refusing`);
    }
  }
  if (oldCount === patches.length) return { state: "unpatched", applied };
  if (applied.length === patches.length) return { state: "patched", applied };
  // Every patch in the group answered unambiguously, but they disagree: some are
  // applied and some are not. That is what a box installed by an earlier revision
  // of this patcher looks like after the group grows an anchor, so it is a state
  // rather than a fault. It is NOT waved through — the caller still has to match a
  // named SHA for it, and "partial" never takes the already-patched early return,
  // so the missing replacements get applied.
  return { state: "partial", applied };
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

// The bundle's shape is the SET of our edits it carries, across BOTH groups — not the
// per-group state, which cannot tell two different partial subsets apart. Exactly one
// known shape may hold that set; anything else is a bundle we did not ship and the
// caller refuses it on the SHA below. Returns [] (not a throw) for an unknown set so
// the refusal stays one message, naming the bytes as well as the shape.
function productionShasForEdits(appliedEdits) {
  // A SET, so both sides are deduplicated as well as sorted. Production visits each
  // patch once and cannot repeat a name, but the argument is a plain list and the
  // lookup's whole contract is set equality: a repeated name matching nothing would
  // read as "unknown bundle" and refuse a box for a reason that is not about bytes.
  const key = (edits) => [...new Set(edits)].sort().join("|");
  const want = key(appliedEdits);
  const shape = KNOWN_BUNDLE_SHAPES.find((candidate) => key(candidate.edits) === want);
  return shape ? [shape.sha] : [];
}

// Match and replace one independent group without touching the filesystem.
// The legacy `(src, expectedSha)` form remains the browse-group test seam.
function patchBundleContent(src, expectedShaOrOptions = PINNED_SHA) {
  const options = normalizePatchOptions(expectedShaOrOptions);
  const states = {};
  const applied = [];
  for (const [name, patches] of Object.entries(GROUPS)) {
    if (name !== options.mode && !options.validateOtherGroups) continue;
    const group = patchGroupState(src, name, patches);
    states[name] = group.state;
    applied.push(...group.applied);
  }
  // Historical pure-function tests pass the pristine fixture SHA again on the
  // idempotence call. Preserve that seam only when other-group validation was
  // explicitly disabled; production CLI calls always validate the full state
  // and its SHA below.
  if (!options.validateOtherGroups && states[options.mode] === "patched") {
    return { source: src, alreadyPatched: true, mode: options.mode, states };
  }
  const sha = crypto.createHash("sha256").update(src).digest("hex");
  const acceptedShas = options.acceptedShas ?? productionShasForEdits(applied);
  if (!acceptedShas.includes(sha)) {
    const accepted = acceptedShas.length
      ? acceptedShas.join(",")
      : `none — no known bundle shape holds exactly [${[...applied].sort().join(", ")}]`;
    throw new Error(`bundle SHA mismatch — got ${sha}, accepted ${accepted} (${PINNED_VERSION}).\n` +
        `  The @getpaseo/cli web-ui bundle is not a recognised state for ${options.mode}. ` +
        `Re-derive the anchors and shape hashes, then re-run. Refusing to modify it.`);
  }
  if (states[options.mode] === "patched") {
    return { source: src, alreadyPatched: true, mode: options.mode, states };
  }

  const patches = GROUPS[options.mode];
  for (const p of patches) {
    if (src.includes(p.find)) src = src.replace(p.find, p.repl);
    else {
      const legacy = (p.legacyRepls ?? []).find((candidate) => src.includes(candidate));
      if (legacy) src = src.replace(legacy, p.repl);
    }
  }
  for (const p of patches) {
    if (occurrences(src, p.find) !== 0) throw new Error(`post-patch: original anchor ${p.name} still present`);
    for (const legacy of p.legacyRepls ?? []) {
      if (occurrences(src, legacy) !== 0) throw new Error(`post-patch: legacy replacement ${p.name} still present`);
    }
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
  KNOWN_BUNDLE_SHAPES,
  PINNED_SHA,
  SUBAGENT_STREAM_PATCHES,
  patchBundleContent,
  patchedName,
  productionShasForEdits,
};

if (require.main === module) main();
