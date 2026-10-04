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
// predate it carrying more than one edit) applies SEVENTEEN edits every box wants: a
// visible provider-subagent panel subscribes to its parent agent's timeline; the
// fresh-install font-size defaults move to 18 (ui) / 14 (code); the sidebar order
// store points at the airlock ui-state backend so the order follows the owner across
// devices instead of living in one browser; an already-open tab rehydrates that order
// when it becomes visible and polls its revision while it stays visible; the sidebar
// order SHRINKS as well as grows — the shared value stops the backend's 256 KiB cap
// from rejecting every write, because upstream only ever prepends or appends — and the
// one signal that licenses it, "this server handed us its complete workspace list", is
// recorded where the list arrives and withdrawn where a LOCAL CACHE is committed
// instead, rather than borrowed from a hydration flag that also fires when a single
// project is registered; sidebar ordering follows exact daemon placements when their
// view keys change; a device that cannot hover is treated as compact for the tooltip
// gate; a coarse pointer gets the project row's trailing actions without having to
// manufacture a hover first; workspace-row menus use the same touch detection, get a
// finger-sized target, and skip hover preview cards; desktop tab close buttons also
// appear for touch; a sidebar tap stops being swallowed by the long-press/drag
// machinery web never arms; and an archive request waits for the daemon's answer
// instead of timing out and putting the archived row back. The optional browse
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
const PINNED_SHA = "a182df940822df553fd648885dbfe2e31da3cc2f771b56a51f935d364f555645";
// Every bundle shape the fleet is known to carry: the pinned upstream bundle plus a
// SUBSET of this file's edits, keyed by exactly which edits it holds.
//
// 0.8.0 note: this table restarts fresh at the version bump — the 0.2.5-era shape
// history (many partial-adoption rows as edits grew/moved groups over time) does not
// carry forward. Keep the pre-identity 0.8.0 shapes as upgrade inputs and name
// both upgraded shapes explicitly so interrupted/unknown bundle states still fail.
// Rows will accumulate again here exactly as they did for 0.2.5 if an edit grows an
// anchor or moves groups after this pin ships.
//
// Each sha256 covers the whole bundle and was re-derived from the pristine bundle by
// applying exactly the listed edits — order-independent, the twenty sites are disjoint:
//   npm pack @getpaseo/server@0.8.0 && tar xzf getpaseo-server-0.8.0.tgz
//   # apply the subset to package/dist/server/web-ui/_expo/static/js/web/index-*.js
const KNOWN_BUNDLE_SHAPES = [
  { sha: PINNED_SHA, edits: [] },
  // always-on group only (browse = false, the default)
  { sha: "fcb035158faafcc910f05442605c7205eeffab66f1a13a0f803ed2e879da1b39",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "project-actions-coarse-pointer",
            "sidebar-tap-not-swallowed-on-web"] },
  // both groups (browse = true)
  { sha: "d4c12a9ef7725d6f356f065d1156b49b5b27cc6b3cc4c11c58527b031e86549f",
    edits: ["provider-subagent-visible-parent", "appearance-default-font-sizes",
            "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility",
            "tooltip-hover-none-is-compact", "project-actions-coarse-pointer",
            "sidebar-tap-not-swallowed-on-web",
            "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  // Identity-preserving always-on group, with and without optional browse.
  { sha: "9f95e589fc36170d8de126645a5e93262a55f83670fdb481e5179d0440448dc6",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web"] },
  { sha: "d040a555b98bcc8f54888fe80afea6662a4dc93725be42b9fbdea58eae6f98b5",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  // Workspace-row touch menus, with and without optional browse.
  { sha: "bf04870deab659431a33a835a52f06a948f253249e4b756f25587ab34cae30a2",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web"] },
  { sha: "a88f5185f19d419e6b9eab3cd483361920f4825d813c36d73fbcbd030556207c",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },

  // Touch targets reserve the same 44px width as the workspace menu trigger.
  { sha: "4c62edfc2c4cf4937a889e029547857d268e4bc88a260c47fe295e687da8eba6", legacyShas: ["7a2e7d57304b3a4cd6a34eb95c692e1d0bb3fe51cc7b07b50db4b52c1c5d0ce0"],
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web"] },
  { sha: "f5f9c309cdfb66f25b4f0ee58179efb35cdff3ddf48bb16276f29ad55190b4f3", legacyShas: ["b9c19255b8e400b9e312e64111ed796627bd1d37516b667aa929c9f5babfc74b"],
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
  // Wide touch screens reveal the tab close overlay without a hover.
  { sha: "c3786a6f4f5eca713a5ad30ef9bc4f80d08ee8a81762b7a6c0994ef7051f6f80",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web"] },
  { sha: "43674343ee4b14efb9a50ca6f2e79b6894f533aa23ef5de750f904eca4e68850",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },

  // Bounded-sidebar-order rows. The two rows above stay as they are: their sha IS the
  // bytes a fleet bundle currently has, and that is what lets this revision upgrade such
  // a box instead of refusing it. These two are what the boxes have AFTER the upgrade,
  // with and without the optional browse group — without them the very next install run
  // sees a complete group on bytes nothing accepts and dies. Derived the same way, from
  // the pristine 0.8.0 bundle, by applying the listed edits:
  //   npm pack @getpaseo/server@0.8.0 && tar xzf getpaseo-server-0.8.0.tgz
  //   # apply the subset to package/dist/server/web-ui/_expo/static/js/web/index-*.js
  { sha: "9677225d385f2d5c78461412c80f84b6358caf04986b71414a78d4fc47573c3e",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache"] },
  { sha: "d9a3cbcb25807aaccda7897504ca3433e219384ad0033944553807263f38b127",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },

  // Archive-request-timeout rows: what the two bounded-sidebar-order rows above become
  // once the archive request stops timing out at 60 s. Those rows stay as upgrade inputs
  // for the same reason the older ones did. Derived the same way, from the pristine
  // 0.8.0 bundle, by applying the listed edits.
  { sha: "5749b20a3932fd100fb4534b162a49b734517e28921b858b79ac17479a311a47",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache", "workspace-archive-request-timeout"] },
  { sha: "d022d9c7f9f2a1d5478a1db3f9fc5a7492acffa2e25552837f46459e58c9ae85",
    edits: ["sidebar-order-atomic-reconcile", "sidebar-order-stable-identity", "provider-subagent-visible-parent", "appearance-default-font-sizes", "sidebar-order-shared-storage", "sidebar-order-rehydrate-on-visibility", "tooltip-hover-none-is-compact", "project-actions-coarse-pointer", "workspace-hover-card-touch", "workspace-tab-close-touch", "workspace-menu-touch-slot", "workspace-menu-touch-trigger", "workspace-actions-coarse-pointer", "sidebar-tap-not-swallowed-on-web", "sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache", "workspace-archive-request-timeout", "new-browser-gate-vo", "new-browser-gate-Wo", "browserpane-marker"] },
];
const PINNED_VERSION = "@getpaseo/cli@0.8.0 (index-1be98d8895969110732458bbaeac57b2)";

// Each anchor MUST occur exactly once in the pinned bundle (verified).
// The two gate anchors carry minifier-local names, which are NOT stable across
// versions even when the code is unchanged: 0.1.110 -> 0.2.5 renamed ze->Ye,
// Re->Be, qe->at, ie->le and changed nothing else about these two callbacks.
const BROWSE_PATCHES = [
  {
    // 0.8.0 note: handleCreateBrowserTab dropped the separate `paneId && at(...)`
    // side-effect statement 0.2.5 had — paneId now flows entirely through the
    // third argument of the openWorkspaceTabFocused/gt(...) call below, per
    // packages/app/src/screens/workspace/workspace-screen.tsx handleCreateBrowserTab.
    name: "new-browser-gate-vo",
    find: 'if(!pt||!(0,ze.getIsElectron)())return;const{browserId:t}=(0,ue.createWorkspaceBrowser)();gt(pt,{kind:"browser",browserId:t},Ht(e?.paneId))',
    repl: 'if(!pt)return;const{browserId:t}=(0,ue.createWorkspaceBrowser)();gt(pt,{kind:"browser",browserId:t},Ht(e?.paneId))',
  },
  {
    name: "new-browser-gate-Wo",
    find: 'if(!pt||!(0,ze.getIsElectron)())return;const{browserId:t}=(0,ue.createWorkspaceBrowser)({initialUrl:e});gt(pt,{kind:"browser",browserId:t},Q.FOCUSED_PANE_PLACEMENT)',
    repl: 'if(!pt)return;const{browserId:t}=(0,ue.createWorkspaceBrowser)({initialUrl:e});gt(pt,{kind:"browser",browserId:t},Q.FOCUSED_PANE_PLACEMENT)',
  },
  {
    name: "browserpane-marker",
    find: '{style:u.container,children:[v,M,k]}',
    repl: '{style:u.container,dataSet:{paseoBrowserId:w,paseoWorkspaceId:f.workspaceId,paseoServerId:f.serverId},children:[v,M,k]}',
  },
];
// The one place the sidebar order is allowed to SHRINK.
//
// Upstream's reconcile only ever adds (`prependMissingOrderKeys` /
// `computeSidebarOrderUpdates` prepend or append); it never subtracts. A key that
// leaves the box — archived workspace, deleted project, host gone for good — therefore
// stays in the persisted order forever, and because the order is shared across the
// owner's devices it stops being written at all once the accumulated value crosses the
// backend's 256 KiB cap: every PUT is refused with 413 before compare-and-swap even
// runs, so the sidebar falls back to whatever local order each device happens to hold.
// Measured 2026-10-03: 4,213 stored workspace keys for 96 live workspaces, 262 KB of a
// 256 KB budget, and every write to the shared order refused.
//
// So: remove, at the point the effect writes, the keys that a server whose workspace
// list was received IN FULL no longer has. That signal is deliberately its own thing —
// upstream's `hasHydratedWorkspaces` is also switched on by registering a single
// project, and the sidebar list itself renders from a cache snapshot, so trusting
// either would delete keys on a device that simply has not received the directory yet.
// The signal is recorded where the list arrives (`commitSnapshot`) and revoked where a
// LOCAL CACHE is committed instead (`commitCached`), which is what makes it mean "this
// device, right now" rather than "at some point since the page loaded": without the
// revoke, a device that went offline holding a cached list keeps the licence and deletes
// the order position of every workspace another device created while it was away —
// and `prependMissingOrderKeys` then puts them back at the top, so the position is lost
// for good rather than restored on reconnect.
//
// `state` is the upstream persisted shape; `live` is what this device can currently
// see. Returns the SAME object when there is nothing to remove, which is what lets the
// caller skip the write entirely.
//
// Two passes, not one: a project whose last workspace disappeared while it is still on
// screen keeps its stale keys, because those keys are what name the server that owns
// them. Once the project leaves the sidebar, the same pass that deletes the keys also
// drops the projectOrder slot. Emptiness is therefore never inferred from an empty array
// — an empty array names no server, and a record that was empty when we found it is not
// our evidence to act on.
//
// `live.hosts` is EVERY server id the visible list mentions, not just the authorised
// ones: a workspace key is `<serverId>:<workspaceId>`, so a key has to be attributed to
// one server before it can be judged, and upstream's own decoder
// (`resolveStructuralWorkspaceIdentity`) matches host prefixes LONGEST-FIRST for
// exactly that reason. Judging "does any authorised server's prefix match" instead would
// charge `a:b:w` to server `a` and delete it while server `a:b` — hidden, or not yet
// complete — still holds it.
const PRUNE_SIDEBAR_ORDER_SRC = `function pruneSidebarOrder(state, live) {
  // Duck-typed on purpose: an instanceof check would be a cross-realm trap, and the shape
  // this needs is only .size, iteration and .has.
  const servers = live && live.servers && "number" == typeof live.servers.size ? live.servers : null;
  const hosts = live && Array.isArray(live.hosts) ? live.hosts.slice().sort((a, b) => b.length - a.length) : null;
  if (!servers || 0 === servers.size || !hosts || 0 === hosts.length) return state;
  const visible = live && live.visibleProjects && "function" == typeof live.visibleProjects.has ? live.visibleProjects : new Set();
  // The LONGEST matching host owns the key, authorised or not. A key with no matching
  // host belongs to a server this device cannot place and is left alone; a server recorded
  // without a list is skipped rather than read as "it has nothing", because the failure
  // mode of guessing there is a deleted order.
  const isStale = key => {
    if ("string" != typeof key || 0 === key.length) return false;
    for (const host of hosts) {
      if (!key.startsWith(host + ":")) continue;
      const keys = servers.get(host);
      return !!keys && !keys.has(key);
    }
    return false;
  };
  const historyKey = "@airlock:sidebar-placement-keys:v1";
  // Returns the SAME array when nothing was stale. That is what makes "a list that was
  // already empty" fall out of one comparison below instead of needing a special case,
  // and what keeps the early return at the bottom an identity check.
  const kept = order => {
    if (!Array.isArray(order)) return order;
    const next = order.filter(key => !isStale(key));
    return next.length === order.length ? order : next;
  };
  const byProject = state.workspaceOrderByProject && "object" == typeof state.workspaceOrderByProject ? state.workspaceOrderByProject : {};
  const orders = {};
  const emptied = new Set();
  let ordersChanged = false;
  for (const project of Object.keys(byProject)) {
    const order = byProject[project];
    // The history record is a placement log, not a workspace list, and it is a
    // fixed-size one: never a candidate for the shrink, whatever a row in it looks
    // like. The value is shared with devices running other builds, so "the rows we
    // wrote" is an assumption, not a fact.
    let next = project === historyKey ? order : kept(order);
    // A record this pass would EMPTY while its project is still on screen is left as it
    // was. Its stale keys still name the complete server that owns them, so a later pass
    // removes them and the projectOrder slot in the SAME step; an empty array names no
    // server and would leave nothing to act on. A record that was ALREADY empty is not
    // evidence of anything and is never touched either way.
    if (next !== order && 0 === next.length && visible.has(project)) next = order;
    orders[project] = next;
    if (next !== order) {
      ordersChanged = true;
      if (0 === next.length) emptied.add(project);
    }
  }
  const pinned = Array.isArray(state.pinnedWorkspaceOrder) ? kept(state.pinnedWorkspaceOrder) : state.pinnedWorkspaceOrder;
  const projectOrder = Array.isArray(state.projectOrder) ? state.projectOrder : [];
  // A project whose order was removed, and that this device can no longer see, is gone.
  // A VISIBLE one keeps both its slot and its record: dropping it would let the next
  // effect append it straight back and this remove it again. A projectOrder key with NO
  // record at all is left alone — that is a project this device has no evidence about.
  const nextProjectOrder = projectOrder.filter(key => !emptied.has(key));
  if (!ordersChanged && pinned === state.pinnedWorkspaceOrder && nextProjectOrder.length === projectOrder.length) return state;
  for (const project of emptied) delete orders[project];
  return { ...state, projectOrder: nextProjectOrder, pinnedWorkspaceOrder: pinned, workspaceOrderByProject: orders };
}`;
const SIDEBAR_STORAGE_LEGACY ='{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(l=>{const u=e=>"/airlock-ui-state/"+encodeURIComponent(e);return{getItem:async e=>{try{const t=await fetch(u(e),{cache:"no-store"});if(t.ok)return await t.text()}catch(t){}return l.getItem(e)},setItem:async(e,t)=>{await l.setItem(e,t);try{await fetch(u(e),{method:"PUT",headers:{"content-type":"application/json"},body:t})}catch(n){}},removeItem:async e=>{await l.removeItem(e);try{await fetch(u(e),{method:"DELETE"})}catch(t){}}}})(o.default))),partialize:';
const SIDEBAR_STORAGE_DURABLE = '{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(l=>{const u=e=>"/airlock-ui-state/"+encodeURIComponent(e),p=e=>"@airlock-pending:"+e;let q=Promise.resolve(),r=Promise.resolve(),h=0;const v=new Map,x=e=>{const t=q.catch(()=>{}).then(e);return q=t,t},b=e=>{const t=r.catch(()=>{}).then(e);return r=t,t},y=(e,t)=>{const n={i:++h,v:t};return v.set(e,n),n},z=e=>v.get(e).v,s=async(e,t,n)=>{const o=null===t?"":t;if(n&&v.get(e)!==n||await l.getItem(p(e))!==o)return;const c=await fetch(u(e),null===t?{method:"DELETE"}:{method:"PUT",headers:{"content-type":"application/json"},body:t});if(!c.ok)throw Error("ui-state write failed: "+c.status);(n?v.get(e)===n:!v.has(e))&&(await l.getItem(p(e)))===o&&await l.removeItem(p(e))};return{getItem:e=>x(async()=>{if(v.has(e))return z(e);const t=await l.getItem(p(e));if(null!==t){const n=""===t?null:t;try{await s(e,n)}catch(o){}return v.has(e)?z(e):n}try{const t=await fetch(u(e),{cache:"no-store"});if(t.ok){const n=await t.text();if(v.has(e))return z(e);return await l.setItem(e,n),v.has(e)?z(e):n}}catch(t){}return v.has(e)?z(e):l.getItem(e)}),setItem:(e,t)=>{const n=y(e,t),o=b(async()=>{if(v.get(e)!==n)return;await l.setItem(e,t),await l.setItem(p(e),t)});return x(async()=>{await o;if(v.get(e)!==n)return;try{await s(e,t,n)}catch(c){}v.get(e)===n&&v.delete(e)})},removeItem:e=>{const t=y(e,null),n=b(async()=>{if(v.get(e)!==t)return;await l.removeItem(e),await l.setItem(p(e),"")});return x(async()=>{await n;if(v.get(e)!==t)return;try{await s(e,null,t)}catch(o){}v.get(e)===t&&v.delete(e)})}}})(o.default))),partialize:';
const SIDEBAR_STORAGE_REVISIONED_V1 = `{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(local=>{
  const url=key=>"/airlock-ui-state/v2/"+encodeURIComponent(key);
  const pendingKey=key=>"@airlock-pending:"+key;
  const instance=Math.random().toString(36).slice(2)+Date.now().toString(36);
  let networkQueue=Promise.resolve(),localQueue=Promise.resolve(),generation=0;
  const observedRevision=new Map(),observedValue=new Map(),live=new Map();
  const enqueueNetwork=fn=>{const next=networkQueue.catch(()=>{}).then(fn);networkQueue=next;return next};
  const enqueueLocal=fn=>{const next=localQueue.catch(()=>{}).then(fn);localQueue=next;return next};
  const begin=(key,value)=>{const token={id:instance+":"+(++generation),value};live.set(key,token);return token};
  const revision=response=>{const value=response.headers?.get?.("x-airlock-revision");return null!==value&&/^\\d+$/.test(value)?value:null};
  const parsePending=raw=>{if(null===raw)return null;try{const value=JSON.parse(raw);return 1===value?.format&&"string"==typeof value.id&&(null===value.base||"string"==typeof value.base&&/^\\d+$/.test(value.base))&&(null===value.value||"string"==typeof value.value)&&(null==value.prior||"string"==typeof value.prior)?value:{legacy:!0,value:""===raw?null:raw}}catch(error){return{legacy:!0,value:""===raw?null:raw}}};
  const savePending=(key,pending)=>local.setItem(pendingKey(key),JSON.stringify({format:1,id:pending.id,base:pending.base,value:pending.value,prior:pending.prior??null}));
  const writeLocal=async(key,value)=>{null===value?await local.removeItem(key):await local.setItem(key,value)};
  const notifyStale=()=>{"undefined"!=typeof document&&document.dispatchEvent(new Event("airlock-ui-state-stale"))};
  const fetchRemote=async key=>{const response=await fetch(url(key),{cache:"no-store"}),nextRevision=revision(response);if(null===nextRevision)return null;if(200===response.status)return{revision:nextRevision,value:await response.text()};if(404===response.status)return{revision:nextRevision,value:null};return null};
  const send=async(key,pending,token)=>{
    if(null===pending.base||pending.legacy||token&&live.get(key)!==token)return{kind:"unsent"};
    const response=await fetch(url(key),null===pending.value?{method:"DELETE",headers:{"X-Airlock-Base-Revision":pending.base}}:{method:"PUT",headers:{"content-type":"application/json","X-Airlock-Base-Revision":pending.base},body:pending.value});
    const nextRevision=revision(response);
    if(204===response.status&&null!==nextRevision){
      let resultValue=pending.value;
      await enqueueLocal(async()=>{
        observedRevision.set(key,nextRevision);observedValue.set(key,pending.value);
        const current=parsePending(await local.getItem(pendingKey(key))),currentToken=live.get(key);
        if(current&&!current.legacy&&current.id===pending.id)await local.removeItem(pendingKey(key));
        else if(current&&!current.legacy&&(currentToken&&current.id===currentToken.id||current.prior===pending.value)){current.base=nextRevision;await savePending(key,current);resultValue=await local.getItem(key)}
        else if(current)resultValue=await local.getItem(key);
      });
      return{kind:"sent",revision:nextRevision,value:resultValue};
    }
    if(409===response.status&&null!==nextRevision){
      const text=await response.text(),remote=text||null;
      let resultValue=remote;
      await enqueueLocal(async()=>{
        observedRevision.set(key,nextRevision);observedValue.set(key,remote);
        const current=parsePending(await local.getItem(pendingKey(key))),currentToken=live.get(key);
        if(token&&currentToken===token)live.delete(key);
        if(!current||current.id===pending.id){await writeLocal(key,remote);current&&await local.removeItem(pendingKey(key))}
        else resultValue=await local.getItem(key);
      });
      notifyStale();
      return{kind:"conflict",revision:nextRevision,value:resultValue};
    }
    return{kind:"unsent"};
  };
  const integrateRemote=async(key,remote)=>{
    let stale=!1,result;
    await enqueueLocal(async()=>{
      const token=live.get(key),pending=parsePending(await local.getItem(pendingKey(key)));
      if(token){
        if(pending&&!pending.legacy&&pending.id===token.id&&pending.value===token.value&&(pending.base===remote.revision||"0"===remote.revision&&null===remote.value||null!==pending.base&&pending.prior===remote.value)){
          observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);pending.base=remote.revision;await savePending(key,pending);result={value:token.value};return;
        }
        live.delete(key);observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);stale=!0;
        if(pending&&!pending.legacy&&pending.id!==token.id){result={value:await local.getItem(key)};return}
      }
      observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);await writeLocal(key,remote.value);await local.removeItem(pendingKey(key));result=remote;
    });
    stale&&notifyStale();
    return result;
  };
  const refresh=async(key,allowSeed)=>{
    const remote=await fetchRemote(key);if(null===remote)return null;
    if(allowSeed&&"0"===remote.revision&&null===remote.value&&!live.has(key)){
      let seed=null;
      await enqueueLocal(async()=>{if(live.has(key)||null!==await local.getItem(pendingKey(key)))return;const value=await local.getItem(key);if(null!==value){seed={id:instance+":seed:"+(++generation),base:"0",value,prior:null};await savePending(key,seed)}});
      if(seed){const sent=await send(key,seed);if("sent"===sent.kind||"conflict"===sent.kind)return sent;return null}
    }
    return integrateRemote(key,remote);
  };
  const mutate=(key,value)=>{
    const token=begin(key,value);
    const durable=enqueueLocal(async()=>{if(live.get(key)!==token)return;await writeLocal(key,value);await savePending(key,{id:token.id,base:observedRevision.get(key)??null,value,prior:observedValue.has(key)?observedValue.get(key):null})});
    return enqueueNetwork(async()=>{await durable;if(live.get(key)!==token)return;const pending=parsePending(await local.getItem(pendingKey(key)));if(pending&&!pending.legacy&&pending.id===token.id&&null!==pending.base)try{await send(key,pending,token)}catch(error){}live.get(key)===token&&live.delete(key)});
  };
  return{
    getItem:key=>enqueueNetwork(async()=>{if(live.has(key))return live.get(key).value;const pending=parsePending(await local.getItem(pendingKey(key)));if(pending&&!pending.legacy&&null!==pending.base)try{const sent=await send(key,pending);if("sent"===sent.kind||"conflict"===sent.kind)return sent.value}catch(error){return pending.value}try{const remote=await refresh(key,!pending);if(remote)return remote.value}catch(error){}return live.has(key)?live.get(key).value:local.getItem(key)}),
    setItem:(key,value)=>mutate(key,value),
    removeItem:key=>mutate(key,null)
  }
})(o.default))),partialize:`;
const SIDEBAR_STORAGE_REVISIONED = `{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>g.__airlockUiState||(g.__airlockUiState=(local=>{
  const url=key=>"/airlock-ui-state/v2/"+encodeURIComponent(key);
  const pendingKey=key=>"@airlock-pending:"+key;
  const instance=Math.random().toString(36).slice(2)+Date.now().toString(36);
  let networkQueue=Promise.resolve(),localQueue=Promise.resolve(),generation=0;
  const observedRevision=new Map(),observedValue=new Map(),live=new Map(),syncing=new Set();
  const enqueueNetwork=fn=>{const next=networkQueue.catch(()=>{}).then(fn);networkQueue=next;return next};
  const enqueueLocal=fn=>{const next=localQueue.catch(()=>{}).then(fn);localQueue=next;return next};
  const begin=(key,value)=>{const token={id:instance+":"+(++generation),value};live.set(key,token);return token};
  const revision=response=>{const value=response.headers?.get?.("x-airlock-revision");return null!==value&&/^\\d+$/.test(value)?value:null};
  const parsePending=raw=>{if(null===raw)return null;try{const value=JSON.parse(raw);return 1===value?.format&&"string"==typeof value.id&&(null===value.base||"string"==typeof value.base&&/^\\d+$/.test(value.base))&&(null===value.value||"string"==typeof value.value)&&(null==value.prior||"string"==typeof value.prior)?value:{legacy:!0,value:""===raw?null:raw}}catch(error){return{legacy:!0,value:""===raw?null:raw}}};
  const savePending=(key,pending)=>local.setItem(pendingKey(key),JSON.stringify({format:1,id:pending.id,base:pending.base,value:pending.value,prior:pending.prior??null}));
  const writeLocal=async(key,value)=>{null===value?await local.removeItem(key):await local.setItem(key,value)};
  const notifyStale=()=>{"undefined"!=typeof document&&document.dispatchEvent(new Event("airlock-ui-state-stale"))};
  const basedPending=async key=>{const pending=parsePending(await local.getItem(pendingKey(key)));return!!(pending&&!pending.legacy&&null!==pending.base)};
  const fetchRemote=async key=>{const response=await fetch(url(key),{cache:"no-store"}),nextRevision=revision(response);if(null===nextRevision)return null;if(200===response.status)return{revision:nextRevision,value:await response.text()};if(404===response.status)return{revision:nextRevision,value:null};return null};
  const send=async(key,pending,token)=>{
    if(null===pending.base||pending.legacy||token&&live.get(key)!==token)return{kind:"unsent"};
    const response=await fetch(url(key),null===pending.value?{method:"DELETE",headers:{"X-Airlock-Base-Revision":pending.base}}:{method:"PUT",headers:{"content-type":"application/json","X-Airlock-Base-Revision":pending.base},body:pending.value});
    const nextRevision=revision(response);
    if(204===response.status&&null!==nextRevision){
      let resultValue=pending.value;
      await enqueueLocal(async()=>{
        observedRevision.set(key,nextRevision);observedValue.set(key,pending.value);
        const current=parsePending(await local.getItem(pendingKey(key))),currentToken=live.get(key);
        if(current&&!current.legacy&&current.id===pending.id)await local.removeItem(pendingKey(key));
        else if(current&&!current.legacy&&(currentToken&&current.id===currentToken.id||current.prior===pending.value)){current.base=nextRevision;await savePending(key,current);resultValue=await local.getItem(key)}
        else if(current)resultValue=await local.getItem(key);
      });
      return{kind:"sent",revision:nextRevision,value:resultValue};
    }
    if(409===response.status&&null!==nextRevision){
      const text=await response.text(),remote=text||null;
      let resultValue=remote;
      await enqueueLocal(async()=>{
        observedRevision.set(key,nextRevision);observedValue.set(key,remote);
        const current=parsePending(await local.getItem(pendingKey(key))),currentToken=live.get(key);
        if(token&&currentToken===token)live.delete(key);
        if(!current||current.id===pending.id){await writeLocal(key,remote);current&&await local.removeItem(pendingKey(key))}
        else resultValue=await local.getItem(key);
      });
      notifyStale();
      return{kind:"conflict",revision:nextRevision,value:resultValue};
    }
    return{kind:"unsent"};
  };
  const integrateRemote=async(key,remote)=>{
    let stale=!1,result;
    await enqueueLocal(async()=>{
      const token=live.get(key),pending=parsePending(await local.getItem(pendingKey(key)));
      if(token){
        if(pending&&!pending.legacy&&pending.id===token.id&&pending.value===token.value&&(pending.base===remote.revision||"0"===remote.revision&&null===remote.value||null!==pending.base&&pending.prior===remote.value)){
          observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);pending.base=remote.revision;await savePending(key,pending);result={value:token.value};return;
        }
        live.delete(key);observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);stale=!0;
        if(pending&&!pending.legacy&&pending.id!==token.id){result={value:await local.getItem(key)};return}
      }
      observedRevision.set(key,remote.revision);observedValue.set(key,remote.value);await writeLocal(key,remote.value);await local.removeItem(pendingKey(key));result=remote;
    });
    stale&&notifyStale();
    return result;
  };
  const refresh=async(key,allowSeed)=>{
    const remote=await fetchRemote(key);if(null===remote)return null;
    if(allowSeed&&"0"===remote.revision&&null===remote.value&&!live.has(key)){
      let seed=null;
      await enqueueLocal(async()=>{if(live.has(key)||null!==await local.getItem(pendingKey(key)))return;const value=await local.getItem(key);if(null!==value){seed={id:instance+":seed:"+(++generation),base:"0",value,prior:null};await savePending(key,seed)}});
      if(seed){const sent=await send(key,seed);if("sent"===sent.kind||"conflict"===sent.kind)return sent;return null}
    }
    return integrateRemote(key,remote);
  };
  const mutate=(key,value)=>{
    const token=begin(key,value);
    const durable=enqueueLocal(async()=>{if(live.get(key)!==token)return;await writeLocal(key,value);await savePending(key,{id:token.id,base:observedRevision.get(key)??null,value,prior:observedValue.has(key)?observedValue.get(key):null})});
    return enqueueNetwork(async()=>{await durable;if(live.get(key)!==token)return;const pending=parsePending(await local.getItem(pendingKey(key)));if(pending&&!pending.legacy&&pending.id===token.id&&null!==pending.base)try{await send(key,pending,token)}catch(error){}live.get(key)===token&&live.delete(key)});
  };
  return{
    getItem:key=>enqueueNetwork(async()=>{if(live.has(key))return live.get(key).value;const pending=parsePending(await local.getItem(pendingKey(key)));if(pending&&!pending.legacy&&null!==pending.base)try{const sent=await send(key,pending);if("sent"===sent.kind||"conflict"===sent.kind)return sent.value}catch(error){return pending.value}try{const remote=await refresh(key,!pending);if(remote)return remote.value}catch(error){}return live.has(key)?live.get(key).value:local.getItem(key)}),
    setItem:(key,value)=>mutate(key,value),
    sync:key=>{if(syncing.has(key))return Promise.resolve();syncing.add(key);return enqueueNetwork(async()=>{try{if(live.has(key))return;if(await basedPending(key)){notifyStale();return}let remote=null;try{remote=await fetchRemote(key)}catch(error){return}if(null===remote||live.has(key)||await basedPending(key))return;observedRevision.get(key)!==remote.revision&&notifyStale()}finally{syncing.delete(key)}})},
    removeItem:key=>mutate(key,null)
  }
})(o.default))),partialize:`;
// 0.8.0's persistence layer moved from createJSONStorage(() => storage) to
// createValidatedPersistStorage(storage, schema) — same StateStorage shape
// (getItem/setItem/removeItem), passed directly rather than behind a factory
// function (see packages/app/src/storage/validated-persist-storage.ts
// upstream). Reuse the identical custom-storage body, just unwrapped from the
// old factory call and re-wrapped for the new one, second-arg schema (`j`)
// left untouched — the pristine 0.8.0 anchor grows a new `pinnedWorkspaceOrder`
// field, but nothing here reaches into individual field names.
const SIDEBAR_STORAGE_REVISIONED_080 = (() => {
  const prefix = '{name:"sidebar-project-workspace-order",storage:(0,n.createJSONStorage)(()=>';
  const suffix = "),partialize:";
  if (!SIDEBAR_STORAGE_REVISIONED.startsWith(prefix) || !SIDEBAR_STORAGE_REVISIONED.endsWith(suffix)) {
    throw new Error("SIDEBAR_STORAGE_REVISIONED shape changed — update SIDEBAR_STORAGE_REVISIONED_080 by hand");
  }
  const iife = SIDEBAR_STORAGE_REVISIONED.slice(prefix.length, SIDEBAR_STORAGE_REVISIONED.length - suffix.length);
  return `{name:"sidebar-project-workspace-order",storage:(0,p.createValidatedPersistStorage)(${iife},j),partialize:`;
})();
// Interval for the revision-checked poll while the tab stays visible. One tiny GET;
// the store is only touched when the server revision moved (or was never observed).
const SIDEBAR_POLL_MS = 60000;
const SIDEBAR_REHYDRATE_REVISIONED_V1 = '"undefined"!=typeof document&&(()=>{const e=()=>f.persist.rehydrate();document.addEventListener("visibilitychange",()=>{"visible"===document.visibilityState&&e()}),document.addEventListener("airlock-ui-state-stale",e)})()';
const SIDEBAR_REHYDRATE_REVISIONED = '"undefined"!=typeof document&&(()=>{const e=()=>f.persist.rehydrate(),s=()=>g.__airlockUiState?.sync?.("sidebar-project-workspace-order");document.addEventListener("visibilitychange",()=>{"visible"===document.visibilityState&&e()}),document.addEventListener("airlock-ui-state-stale",e),"undefined"!=typeof window&&(window.addEventListener("focus",s),window.addEventListener("online",s),window.setInterval(()=>{"visible"===document.visibilityState&&s()},' + SIDEBAR_POLL_MS + '))})()';
// 0.8.0's store-handle local is named P, not f (module compiled with more
// preceding local bindings) — only the receiver of `.persist.rehydrate()` and
// `f.__airlockUiState?.sync` (unrelated to the store handle) actually changes.
const SIDEBAR_REHYDRATE_REVISIONED_080 = SIDEBAR_REHYDRATE_REVISIONED.replace(
  /const e=\(\)=>f\.persist\.rehydrate\(\)/,
  "const e=()=>P.persist.rehydrate()",
);
const SIDEBAR_REHYDRATE_LEGACY = 'partialize:e=>({projectOrder:e.projectOrder,workspaceOrderByProject:e.workspaceOrderByProject}),version:1,migrate:j}));"undefined"!=typeof document&&document.addEventListener("visibilitychange",()=>{"visible"===document.visibilityState&&f.persist.rehydrate()})},3544,[3368,3273,3276]);';
const SUBAGENT_STREAM_PATCHES = [
  {
    // Persist placement history and migrated orders in ONE Zustand update, and let the
    // same write carry the shrink: the effect is the single place that knows both the
    // freshly reconciled keys and the full persisted order, so pruning here is what stops
    // the shared value from growing until every device's PUT is refused. A reload, failed
    // PUT, or CAS rehydrate must never observe half a transition — and the prune must not
    // become a second, independent write either. `legacyRepls` is the pre-prune form of
    // this same edit: a fleet bundle carries those bytes, names this edit, and must still
    // have it replaced.
    name: "sidebar-order-atomic-reconcile",
    find: 'o.projectOrder&&t.setProjectOrder(o.projectOrder);for(const{projectViewKey:s,order:n}of o.workspaceOrders)t.setWorkspaceOrder(s,n)',
    repl: `((()=>{
  const pruneSidebarOrder = ${PRUNE_SIDEBAR_ORDER_SRC};
  return (()=>{
    // Only a server that handed us its COMPLETE workspace list may judge a key, and only
    // while the sidebar can still see it: a host the list filter drops is indistinguishable
    // from one the directory never mentioned. Attribution, though, runs against every
    // REGISTERED host below — a key has to be pinned to its owning server before any
    // server is allowed to claim it is gone.
    const complete = globalThis.__airlockWorkspaceListComplete;
    const servers = new Map(), visibleProjects = new Set(), listed = [];
    for(const project of J){
      visibleProjects.add(project.viewKey);
      for(const host of project.hosts)listed.push(host.serverId);
    }
    // L is the unfiltered registered-id list. J is narrower than that whenever a host
    // filter is on, and attributing against the narrow list would charge a hidden host's
    // key to whichever registered id happens to be its prefix.
    for(const server of listed)if(complete&&complete.has(server)&&!servers.has(server))servers.set(server,new Set());
    // Longest first, the same order upstream's own workspace-key decoder resolves host
    // prefixes in, so the first match below is the server that owns the key.
    const owned = [...new Set(listed.concat(L))].sort((a, b) => b.length - a.length);
    for(const project of J)for(const workspace of project.workspaces)for(const server of owned){
      if(!workspace.workspaceKey.startsWith(server+":"))continue;
      // Break even when the owning host is not authorised: its keys are not this
      // server's to judge, and charging them to a shorter prefix would delete them.
      servers.get(server)?.add(workspace.workspaceKey);
      break;
    }
    const merged = {
      ...t,
      ...(o.projectOrder?{projectOrder:o.projectOrder}:{}),
      workspaceOrderByProject: Object.assign({}, t.workspaceOrderByProject, Object.fromEntries(o.workspaceOrders.map(({projectViewKey:e,order:t})=>[e,t]))),
    };
    // pruneSidebarOrder returns the SAME object when nothing is stale, so this one
    // comparison covers both halves: reconcile changed nothing AND the prune found
    // nothing. An unchanged tab must not write — every write is a shared-state round
    // trip against every other device's order.
    const next = pruneSidebarOrder(merged, {hosts: owned, servers, visibleProjects});
    if(next === merged && !o.projectOrder && 0 === o.workspaceOrders.length)return;
    f.useSidebarOrderStore.setState({
      projectOrder: next.projectOrder,
      pinnedWorkspaceOrder: next.pinnedWorkspaceOrder,
      workspaceOrderByProject: next.workspaceOrderByProject,
    });
  })();
})())`,
    legacyRepls: ['if(o.projectOrder||o.workspaceOrders.length)f.useSidebarOrderStore.setState({...(o.projectOrder?{projectOrder:o.projectOrder}:{}),workspaceOrderByProject:Object.assign({},t.workspaceOrderByProject,Object.fromEntries(o.workspaceOrders.map(({projectViewKey:e,order:t})=>[e,t])))})'],
  },

  {
    // "The workspace list arrived" is recorded where the list actually arrives, not
    // where a flag that also means "a project was registered" happens to be set. Without
    // this, the sidebar-order prune (above) has no permission to remove anything and a
    // device that has never received the directory is one tab away from deleting every
    // key another device created.
    name: "sidebar-order-workspace-list-complete",
    find: 'commitSnapshot(e,t){this.replace(e);const s=t.flatMap(e=>this.applyDelta(e));return o.useSessionStore.getState().setHasHydratedWorkspaces(this.serverId,!0),s}',
    repl: 'commitSnapshot(e,t){this.replace(e);const s=t.flatMap(e=>this.applyDelta(e));const l=globalThis.__airlockWorkspaceListComplete||(globalThis.__airlockWorkspaceListComplete=new Set);return l.add(this.serverId),this.__airlockGotFullWorkspaceList=!0,o.useSessionStore.getState().setHasHydratedWorkspaces(this.serverId,!0),s}',
  },

  {
    // ...and withdrawn where the list came from the LOCAL CACHE instead. Restoring a
    // checkpoint is not a directory sync: it can happen on a page load that never reaches
    // the box at all. Left standing, the record above would mean "sometime since this page
    // loaded" instead of "right now", and a device that went offline holding a cached
    // list would go on deleting the order position of every workspace another device
    // created while it was away.
    //
    // The revoke is skipped once THIS replica has committed a live snapshot, because
    // `commitCached` merges the checkpoint UNDER the replica's own entries
    // (`[...cached, ...this.workspaces]` — existing wins). It can only add, so it can only
    // make the visible list a superset of the snapshot, and a superset is the safe
    // direction for the prune: extra keys are kept, not deleted. Without that guard a
    // route-driven refresh that resolved before the cache read would hand out the
    // authority and then take it back with no further snapshot to restore it, and the
    // prune would stay off for the rest of the page load — quietly reinstating the
    // oversized-value failure this exists to remove.
    //
    // The flag is per replica instance, so a fresh runtime for the same server starts
    // unearned and a cache restore there still withdraws. `commitCached` is memoised per
    // server (`cacheLoad ??=`, guarded by `cacheAccepted`), so this cannot churn.
    name: "sidebar-order-workspace-list-from-cache",
    find: 'commitCached(e){this.replace({workspaces:new Map([...e.workspaces,...this.workspaces]),projects:new Map([...e.projects,...this.projects])}),o.useSessionStore.getState().setHasWorkspaceDirectorySnapshot(this.serverId,!0)}',
    repl: 'commitCached(e){this.replace({workspaces:new Map([...e.workspaces,...this.workspaces]),projects:new Map([...e.projects,...this.projects])}),o.useSessionStore.getState().setHasWorkspaceDirectorySnapshot(this.serverId,!0),this.__airlockGotFullWorkspaceList||(globalThis.__airlockWorkspaceListComplete&&globalThis.__airlockWorkspaceListComplete.delete(this.serverId))}',
  },

  {
    // viewKey changes when another clone appears/disappears. Reconcile by the
    // daemon's stable serverId/projectId before missing-key append/prepend runs.
    // Existing records are left alone on first load; no historical guessing or
    // bulk migration. After a real transition, the outgoing user's order wins.
    name: "sidebar-order-stable-identity",
    find: 'e.computeSidebarOrderUpdates=function(t){if(0===t.projects.length)return{projectOrder:null,workspaceOrders:[]};const s=K({currentOrder:t.persistedProjectOrder,visibleKeys:t.projects.map(t=>t.viewKey)}),o=s===t.persistedProjectOrder?null:s,c=[];for(const s of t.projects){const o=t.getWorkspaceOrder(s.viewKey),n=I({currentOrder:o,visibleKeys:s.workspaces.map(t=>t.workspaceKey)});n!==o&&c.push({projectViewKey:s.viewKey,order:n})}return{projectOrder:o,workspaceOrders:c}}',
    repl: `e.computeSidebarOrderUpdates=(()=>{
  // A reserved, non-project record keeps placement history inside the existing
  // string-array order schema. Older tabs preserve this record without needing
  // a new strict-schema field. History and order commit atomically in the effect.
  const historyKey="@airlock:sidebar-placement-keys:v1";
  return function(t){
    if(0===t.projects.length)return{projectOrder:null,workspaceOrders:[]};
    const history=t.getWorkspaceOrder(historyKey),previous=new Map();
    for(const record of history){
      try{const row=JSON.parse(record);if(Array.isArray(row)&&3===row.length&&row.every(value=>"string"===typeof value))previous.set(JSON.stringify(row.slice(0,2)),row[2])}catch(error){}
    }
    const visible=new Set(t.projects.map(project=>project.viewKey));
    const current=new Map(),targets=new Map(),sources=new Map();
    const add=(map,key,value)=>{if(!map.has(key))map.set(key,new Set());map.get(key).add(value)};
    for(const project of t.projects)for(const host of project.hosts){
      const identity=JSON.stringify([host.serverId,host.projectId]);
      current.set(identity,project.viewKey);
      const old=previous.get(identity);
      if(void 0!==old&&old!==project.viewKey){add(targets,old,project.viewKey);add(sources,project.viewKey,old)}
    }
    const inherited=new Map();
    for(const [old,next] of targets){
      if(visible.has(old)||1!==next.size)continue;
      const key=next.values().next().value;
      if(1!==sources.get(key).size)continue;
      // An incoming group that another placement kept visible owns its own drag
      // order. Merging into it must not replace that order with a detached row.
      if([...previous].some(([identity,value])=>value===key&&current.get(identity)===key))continue;
      // A shared multi-host equivalence key may split into several placements.
      // Transfer only a one-to-one transition; never assign one clone's slot to
      // another or move a still-visible equivalence group.
      if([...previous].some(([identity,value])=>value===old&&current.get(identity)!==key))continue;
      inherited.set(key,old);
    }
    let projectOrder=t.persistedProjectOrder;
    for(const [key,old] of inherited){
      if(!projectOrder.includes(old))continue;
      projectOrder=projectOrder.filter(value=>value!==key).map(value=>value===old?key:value);
    }
    projectOrder=K({currentOrder:projectOrder,visibleKeys:t.projects.map(project=>project.viewKey)});
    const workspaceOrders=[];
    for(const project of t.projects){
      const own=t.getWorkspaceOrder(project.viewKey),old=inherited.get(project.viewKey);
      const prior=void 0===old?[]:t.getWorkspaceOrder(old);
      // A previously used target key can contain an older drag order. The
      // outgoing key wins on a measured transition, even when both keys exist.
      const base=prior.length?[...new Set([...prior,...own])]:own;
      const order=I({currentOrder:base,visibleKeys:project.workspaces.map(workspace=>workspace.workspaceKey)});
      if(order.length!==own.length||order.some((value,index)=>value!==own[index]))workspaceOrders.push({projectViewKey:project.viewKey,order});
    }
    for(const [identity,key] of current)previous.set(identity,key);
    const nextHistory=[...previous].sort(([a],[b])=>a<b?-1:a>b?1:0).map(([identity,key])=>JSON.stringify([...JSON.parse(identity),key]));
    if(nextHistory.length!==history.length||nextHistory.some((value,index)=>value!==history[index]))workspaceOrders.push({projectViewKey:historyKey,order:nextHistory});
    return{projectOrder:projectOrder===t.persistedProjectOrder?null:projectOrder,workspaceOrders};
  }
})()`,
  },

  {
    name: "provider-subagent-visible-parent",
    find: 'return"agent"===s?.kind?[s.agentId]:[]',
    repl: 'return"agent"===s?.kind?[s.agentId]:"provider_subagent"===s?.kind?[s.parentAgentId]:[]',
  },
  {
    // Fresh-install appearance defaults: ui font size -> 18 and code font size
    // 12 -> 14, inside the clamps the settings UI already enforces (ui 10..21,
    // code 9..22 — left untouched here). Both are per-device settings persisted
    // under `@paseo:app-settings`, so this moves what a device gets when it has
    // NEVER saved settings; a device that already stored a value keeps it and
    // must change it in Settings -> Appearance.
    // 0.8.0 note: upstream's own web default (FONT_SIZE.base) moved to 14 (from
    // whatever it was at 0.2.5) and is now computed via a small function call
    // (`N(E.isNative)`) rather than a bare numeric literal — this patch replaces
    // the call with our literal default outright rather than editing the shared
    // function (which content-font-size also calls). codeFontSize's default
    // (`B=12`) is still a bare literal, unaffected by that change.
    name: "appearance-default-font-sizes",
    find: "const R=N(E.isNative),P=10,L=21;function D(e){return e?16:_.FONT_SIZE.content}const C=D(E.isNative),v=10,j=21,B=12,w=9,M=22,k=200,U=",
    repl: "const R=18,P=10,L=21;function D(e){return e?16:_.FONT_SIZE.content}const C=D(E.isNative),v=10,j=21,B=14,w=9,M=22,k=200,U=",
  },
  {
    // Cross-device sidebar order. Upstream persists the project/workspace order in
    // this ONE store, through AsyncStorage — localStorage on web — so the order is a
    // property of the browser, not of the box, and a drag on the Mac is invisible on
    // the iPad. The daemon has no route that would hold it either. This swaps that
    // store's storage (and only that store's) for the airlock ui-state backend behind
    // the same owner gate, keeping the local one as the write-through cache:
    //   read  — server first, remembering its persistent revision,
    //   write — local/outbox first, then compare-and-swap against that revision.
    // Another device advancing the revision makes this tab rehydrate shared truth;
    // an unreachable or pre-v2 backend remains local-only and is never written to
    // unconditionally.
    // 0.8.0 note: find text updated for createValidatedPersistStorage (see
    // SIDEBAR_STORAGE_REVISIONED_080 above) — no legacyRepls yet, this is the
    // first 0.8.0-shaped derivation of this patch, so there is no older
    // 0.8.0-era fleet shape to migrate from.
    name: "sidebar-order-shared-storage",
    find: '{name:"sidebar-project-workspace-order",storage:(0,p.createValidatedPersistStorage)(o.default,j),partialize:',
    repl: SIDEBAR_STORAGE_REVISIONED_080,
  },
  {
    // A second device commonly already has Paseo open. Persist hydrates only once,
    // so the server-first adapter above does not run again merely because the owner
    // switches back to that tab: the in-memory sidebar keeps the device's old order
    // until a full refresh. Rehydrate when a hidden tab becomes visible. Zustand's
    // persist rehydrate updates the existing store (and therefore the rendered
    // sidebar) without restarting Paseo or reloading the page.
    // 0.8.0 note: gained a pinnedWorkspaceOrder field in the partialize picker
    // (packages/app adds pinned-workspace ordering), migrate's local renamed
    // j->y, and the module tail's id/deps changed (3544->3813, more deps) — the
    // bundle grew, module ids are not stable across versions. No legacyRepls
    // yet, same reasoning as sidebar-order-shared-storage above.
    name: "sidebar-order-rehydrate-on-visibility",
    find: 'partialize:e=>({projectOrder:e.projectOrder,pinnedWorkspaceOrder:e.pinnedWorkspaceOrder,workspaceOrderByProject:e.workspaceOrderByProject}),version:1,migrate:y}))},3813,[1587,3401,3404,3313,3553]);',
    repl: 'partialize:e=>({projectOrder:e.projectOrder,pinnedWorkspaceOrder:e.pinnedWorkspaceOrder,workspaceOrderByProject:e.workspaceOrderByProject}),version:1,migrate:y}));' + SIDEBAR_REHYDRATE_REVISIONED_080 + '},3813,[1587,3401,3404,3313,3553]);',
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
    // 0.8.0 note: field order in the destructure changed (isMobileBreakpoint now comes
    // before isProjectActive) and the combining locals renamed (k=c||we.isNative||l ->
    // y=p||ke.isNative||u); same three-source OR, different letters.
    name: "project-actions-coarse-pointer",
    find: 'overed:p,isMobileBreakpoint:u,isProjectActive:k,onBeginWorkspaceSetup:b,onRemoveProject:v,removeProjectStatus:j}=e,y=p||ke.isNative||u;',
    repl: 'overed:p,isMobileBreakpoint:u,isProjectActive:k,onBeginWorkspaceSetup:b,onRemoveProject:v,removeProjectStatus:j}=e,y=p||ke.isNative||u||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches;',
  },
  {
    // Mobile already omits this hover-only preview. iPad's wide viewport does not,
    // and its synthesized mouseover opens the card while trying to tap the menu.
    name: "workspace-hover-card-touch",
    find: 'f=(0,P.useIsCompactFormFactor)();if(!z.isWeb||f)return u;',
    repl: 'f=(0,P.useIsCompactFormFactor)()||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches;if(!z.isWeb||f)return u;',
  },
  {
    // Wide touch screens cannot hover to reveal the desktop tab close overlay.
    // Keep the tab layout's existing close-button policy and reserved space.
    name: "workspace-tab-close-touch",
    find: 'const Q=Y,Z=S&&(G||y.isNative||N||C);',
    repl: 'const Q=Y,Z=S&&(G||y.isNative||N||C||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches);',
  },
  {
    // hitSlop does not make the 18px desktop trigger a visible touch target.
    // Reserve width only; an absolute trigger must not enlarge the title row.
    name: "workspace-menu-touch-slot",
    find: 'u=c?H.trailingActionSlotReserved:H.trailingActionSlot;',
    repl: 'u=c?"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches?[H.trailingActionSlotReserved,{minWidth:44}]:H.trailingActionSlotReserved:H.trailingActionSlot;',
    legacyRepls: ['u=c?"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches?[H.trailingActionSlotReserved,{minWidth:44,minHeight:44}]:H.trailingActionSlotReserved:H.trailingActionSlot;'],
  },
  {
    name: "workspace-menu-touch-trigger",
    find: 'function G({hovered:e=!1}){return[V.trigger,e&&V.triggerHovered]}const V=u.StyleSheet.create(e=>({trigger:{padding:2,borderRadius:4,marginLeft:2,marginRight:-7}',
    repl: 'function G({hovered:e=!1}){return[V.trigger,"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches&&{position:"absolute",top:-8,right:0,width:44,height:36,padding:0,marginLeft:0,marginRight:0,alignItems:"center",justifyContent:"center"},e&&V.triggerHovered]}const V=u.StyleSheet.create(e=>({trigger:{padding:2,borderRadius:4,marginLeft:2,marginRight:-7}',
    legacyRepls: ['function G({hovered:e=!1}){return[V.trigger,"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches&&{width:44,height:44,padding:0,marginLeft:0,marginRight:0,alignItems:"center",justifyContent:"center"},e&&V.triggerHovered]}const V=u.StyleSheet.create(e=>({trigger:{padding:2,borderRadius:4,marginLeft:2,marginRight:-7}'],
  },
  {
    // Workspace rows use the compact breakpoint as their touch test, so iPad rows
    // have no visible kebab without hover. The shared resolver covers both workspace
    // rows listed under projects and pinned/status workspace rows. Normalize its
    // touch flag once so the menu and its reserved width agree, using the measured
    // project-row pointer query.
    name: "workspace-actions-coarse-pointer",
    find: 'e.resolveTrailingActionVisibility=function({workspace:t,trailing:o,hasArchiveAction:n,isHovered:s,isTouchPlatform:c,showShortcut:l}){const u=',
    repl: 'e.resolveTrailingActionVisibility=function({workspace:t,trailing:o,hasArchiveAction:n,isHovered:s,isTouchPlatform:c,showShortcut:l}){c=c||"undefined"!=typeof window&&!0===window.matchMedia?.("(pointer: coarse)")?.matches;const u=',
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
    find: 'c[14]===Symbol.for("react.memo_cache_sentinel")?(H=e=>{const t=M.current;if(!t||x.current||P.current)return;',
    repl: 'c[14]===Symbol.for("react.memo_cache_sentinel")?(H=o.isWeb?()=>{}:e=>{const t=M.current;if(!t||x.current||P.current)return;',
  },
  {
    // An archived workspace comes back in the sidebar 60 seconds later. The sidebar
    // hides the row before it asks the daemon, and puts it back if the request
    // throws (`archiveWorkspaceOptimistically`). The request inherits the client's
    // 60 s default, but the daemon answers only after it has also torn down and
    // removed the worktree — the record itself is archived within seconds. Measured
    // on a live box 2026-10-04: a human archive took 140 s (the record was archived at
    // +9 s), the row reappeared, they archived it again, and that one timed out too.
    // A timeout is not a failed archive, so this request waits as long as upstream's
    // own long-running calls do (6e5, the CLI's waitForFinish budget).
    name: "workspace-archive-request-timeout",
    find: 'async archiveWorkspace(e,s){return this.sendCorrelatedSessionRequest({requestId:s,message:{type:"archive_workspace_request",workspaceId:e},responseType:"archive_workspace_response"})}',
    repl: 'async archiveWorkspace(e,s){return this.sendCorrelatedSessionRequest({requestId:s,message:{type:"archive_workspace_request",workspaceId:e},responseType:"archive_workspace_response",timeout:6e5})}',
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
  // A legacy replacement still names the edit for shape lookup, but it also raises
  // oldCount because this revision must replace those bytes. Do not let a bundle
  // whose every edit is present in an older form take the idempotent early return.
  if (applied.length === patches.length && oldCount === 0) return { state: "patched", applied };
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
  // `sha` is what this revision produces. legacyShas are exact fleet bytes made by
  // earlier replacements for the same logical edit set; they are accepted only so
  // the named legacyRepls above can migrate them, never as an idempotent endpoint.
  return shape ? [shape.sha, ...(shape.legacyShas ?? [])] : [];
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
  PRUNE_SIDEBAR_ORDER_SRC,
  SIDEBAR_POLL_MS,
  SIDEBAR_REHYDRATE_REVISIONED,
  SUBAGENT_STREAM_PATCHES,
  patchBundleContent,
  patchedName,
  productionShasForEdits,
};

if (require.main === module) main();
