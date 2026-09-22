# paseo patches — AGPL-3.0-only (our own choice, on an Apache-2.0 base)

`agent-history-delete-guard.mjs` refuses CLI permanent deletion before connecting
or cancelling agents; see [automatic cleanup](../README.md#automatic-cleanup).

**License: `AGPL-3.0-only`** — marked separately from the repo's own AGPL-3.0,
because the basis is different (see below).

Paseo (`@getpaseo/cli`, upstream https://github.com/getpaseo/paseo) is licensed
**Apache License, Version 2.0** (changed from AGPL-3.0 as of upstream `v0.7`;
confirmed against the upstream `LICENSE` file at the pinned `v0.8.0` tag). The
files in this directory modify Paseo's own bundle, so they are **derivative
works of Paseo**. Apache-2.0 §4(b) lets a licensee "provide additional or
different license terms and conditions for use, reproduction, or distribution
of Your modifications" — we exercise that permission and license our own
modifications **AGPL-3.0-only**, independently of the licence the rest of
Airlock happens to carry, for the same reason the core itself is AGPL-3.0:
the copyright holder's own choice, not an inherited requirement from Paseo.
The portions of each patched file that remain upstream's own unmodified work
are still covered by upstream's Apache-2.0 grant — its full text is vendored
at `UPSTREAM-LICENSE` beside this file, per Apache-2.0 §4(a)'s requirement to
give recipients a copy of the License. Before upstream `v0.7` these files were
derivatives of an AGPL-3.0 work and had no choice in the matter; the AGPL-3.0
election here is now made *by us*, and would remain AGPL-3.0-only even if
upstream changed licence again.

## What is here

- **`schedule-busy-pending-delivery.mjs`** (+ `.patch`, `.test.mjs`) and its schema half
  **`schedule-pending-delivery-schema.mjs`** (+ `.patch`) — when an agent-target schedule fires while
  that seat is mid-turn, upstream records a FAILED run and jumps to the next cadence: the tick is
  lost, failed runs eat `maxRuns`, and masters learn to end turns early so they are idle when their
  clock ticks (pilot box 2026-09-13: 5 of 17 agent-target runs were exactly `already has an active
  run`). The patch folds busy into one `pendingAgentDelivery` bit — no failed run, no queue — and
  the next tick delivers exactly once as soon as the seat is idle. The schema half keeps the bit
  across restarts (zod strips unknown keys); the two halves are safe in either order and alone.
  Same discipline as the others: sentinel, all-or-nothing anchors, `node --check`, plus a behaviour
  check that drives the candidate with stub seats before it is installed.

- **`depth4-search.patch`** — caps the add-project name search to `maxDepth: 4`
  (paseo's default full-scans `$HOME` and times out on a large home). This is the
  reference / re-derivation copy of the edit; `../install.sh` applies it via an
  idempotent `sed` against the installed bundle.

- **`image-attachments-persist.mjs`** (+ `image-attachments-persist.patch`, the
  reference copy) — an image pasted into paseo's web UI reaches the model only as an
  inline base64 vision block: the model sees it, but no file exists, so the agent's
  `Read` tool has no path and "look at this screenshot, then edit the file" dead-ends.
  The patch keeps the inline block and *also* writes the bytes under the session cwd
  (`<cwd>/.paseo-attachments/`, self-ignored via its own `.gitignore`, name
  content-addressed so a re-paste dedups), then appends a sibling text block naming the
  absolute path. Same discipline as the others: sentinel (idempotent), all-or-nothing
  (three anchors or none), `node --check` before it replaces the file, exit 20 on
  upstream drift so the install continues without the feature.

- **`claude-model-prune.mjs`** (+ `claude-model-prune.patch`, the reference copy)
  — removes superseded entries (Opus 4.7/4.6, Sonnet 4.6) from paseo's
  `CLAUDE_MODEL_MANIFEST` so the picker is the handful people actually choose. Picker-only: the manifest
  is not on the execution path, so an agent already pinned to a removed model
  keeps running (it just loses the known context-window maximum in the gauge).
  Decomposes the array into entry blocks and refuses to write unless they
  reassemble byte-for-byte, so an upstream format change skips instead of
  mangling the file. Edit `PRUNE_IDS` to change which models are hidden.

- **`opencode-grok-defaults.mjs`** (+ `opencode-grok-defaults.patch`, the reference copy)
  — OpenCode's catalog order treats the first variant key as the thinking default
  (`low`) and lists models in provider-catalog order, not Airlock's preference. The
  patch sorts the picker so `opencode-go/muse-spark-1.3-contributor` is first,
  `xai/grok-4.6` second, and `xai/grok-build-0.1` third, and moves each of their
  thinking defaults (`xhigh` for muse-spark, `high` for grok-4.6) to the front so new
  sessions start there. muse-spark's `xhigh` is the top of the models.dev catalog
  (which stops at `xhigh`); the earlier box-local `max` variant was rejected by the
  provider, so no box-local variant is needed. Picker/create-form only: an already-running
  agent's model and thinking stay on the session record. Both anchors or none.

- **`provider-subagent-stream-filter.mjs`** (+ reference patch and behavior test)
  — Paseo 0.2.5 forwards `agent.provider_subagents.update` through connection-wide
  `Session.emit()`, so every capable browser receives every provider-owned child
  update regardless of its viewed-agent subscription. The patch routes `upsert`,
  `timeline`, and `remove` by the existing parent-agent subscription, per WebSocket
  source. Selective clients receive only a viewed parent; legacy clients retain the
  old broadcast fallback. This server edit is inseparable from the always-on
  `--subagent-stream` group in `../browse-host/bin/patch-web-ui.js`: a child-only tab
  must project its `parentAgentId` into the same subscription set or a server-only
  filter would freeze that tab. The main installer validates the server candidate,
  applies and syntax-checks the UI group, then replaces the server file and restarts
  once. Both correctness halves fail hard on the pinned 0.2.5 layout; the unrelated
  optional `--browse` group remains warn-only. The behavior test extracts the shipped
  forwarding method and drives selective A/B sources, a legacy source, an unsupported
  source, every payload kind, and the no-source fallback.

- **`orphan-process-guard.mjs`** (+ `orphan-process-guard-{claude,codex}.patch`, the
  reference copies, and `orphan-process-guard.test.mjs`, a behaviour check) — paseo
  leaks the agent processes it spawns. Both providers track exactly one live child
  (`this.childProcess` / `this.client`) and terminate it behind an `if (handle)` with
  no else branch, and neither honours the closed flag on its spawn entry point
  (`ensureQuery()` / `connect()`). A control-plane call landing during or after close —
  `setMode`, `setModel`, `listCommands`, `revertFiles`, a codex reconnect, or the
  in-flight spawn simply finishing late — starts a **replacement** process on a session
  nothing will ever close again; it runs until the box is rebooted. close() reports
  success because at that instant there was genuinely nothing to kill, and the
  surrounding `session_close.start/complete` lines are `logger.trace`, which the
  daemon's info-level logger never emits — so the whole class of leak was unobservable.
  Measured on the pilot box 2026-08-05: 18 orphans, 2.9G RSS + 1.9G swap.
  The patch makes ownership a `Set` (a replaced handle is still terminated), gates both
  spawn entry points, terminates a late arrival on the spot instead of storing it, and
  `logger.warn`s every branch that used to be silent. Two independent targets, one
  invocation each (`claude` / `codex`) so a drift in one does not disable the other;
  anchors must be present **and unique** or it exits 20. Deliberately out of scope:
  `detached: true` + process-group kill, which would also cover MCP children orphaned
  when the leader exits first — that changes the signal/session semantics of the
  provider spawn and needs its own change and observation window; this patch logs that
  case loudly instead. Verify after install:
  `node orphan-process-guard.test.mjs <installed>/providers/claude/agent.js`.

- **`orphan-process-group.mjs`** (+ `orphan-process-group.test.mjs`) — closes the one
  leak the guard above deliberately left open. When the agent **leader** exits before we
  terminate it, `terminateWithTreeKill` returns `"already-exited"` and stops — and by then
  the leader's MCP children have been reparented, so a ppid-walking tree-kill can no longer
  find them; they survive as orphans. A **process group outlives its leader**, so killing
  the group reaches them. Controlled experiment (pilot box, 2026-08-06):

  | spawn | pgid | leader kill | `kill(-pid)` |
  |---|---|---|---|
  | `detached: false` | ≠ pid | grandchild orphaned | **ESRCH** (no such group — harmless) |
  | `detached: true` | = pid | grandchild orphaned | grandchild **dies** ✅ |

  In both cases the child stays in `airlock-paseo.service`'s cgroup, so `KillMode=control-group`
  still sweeps everything on daemon restart — `detached` does not escape the cgroup. That
  ESRCH result is what makes the sweep safe if the spawn edit ever fails to apply: a group id
  *is* its leader's pid, so `kill(-pid)` can only reach the group led by that same process.
  codex already spawned its app-server detached upstream and merely never killed the group;
  claude needed both halves. 🔴 Apply **after** `orphan-process-guard.mjs` — the
  `claude-agent` anchors are text that patch introduces (otherwise exit 20 = skip, not a
  half-fix). The behaviour check spawns real detached processes and asserts the shipped
  sweep reaps a survivor, because this is the half that signals other processes.

- **`acp-context-gauge.mjs`** (+ `.test.mjs`) — agy runs over Paseo's generic ACP
  provider. `usage_update` is parsed and dropped (`handleUsageUpdate` was `void
  update;`) — no context-window gauge for any ACP provider. `handlePromptResponse`
  then OVERWRITES `currentTurnUsage` at turn end instead of merging, so even a turn
  that did see a mid-turn `usage_update` loses those fields the moment it ends. A
  `config_option_update` that only touches model or thinking reassigns
  `availableModes` from a mode-state-less `deriveModesFromACP` call, blanking any
  mode list that came from `session/new` rather than a config option. And an ACP
  agent's own advertised unattended mode (`_meta.paseo.isUnattended`) never reaches
  the mode list or the catalog probe's `defaultModeId`. Five edit sites, one file,
  same discipline as the others: sentinel, all-or-nothing anchors, `node --check`,
  plus a behaviour test that drives the extracted methods directly (merge-not-
  overwrite, mode-list survival, event shape).

- **`acp-cross-provider-mode-default.mjs`** (+ `.test.mjs`) — once a generic ACP
  agent (agy) advertises modes, `paseo run --provider agy` with no `--mode` from an
  **attended** agent of a *different* provider is refused ("cannot inherit mode").
  The base `ACPAgentClient` already bypasses this, but only for an unattended create
  or an unattended parent (`resolveACPCreateConfig`, `acp-agent.js`) — attended
  cross-provider callers still hit the throw. A plain method override on
  `GenericACPAgentClient` would be dead code against 0.8.0: the base constructor
  assigns `this.resolveCreateConfig` as an *own instance property*, which always
  shadows a subclass's same-named prototype method. The patch instead captures that
  already-assigned function in the subclass constructor and wraps it — bypass for
  the attended-cross-provider-no-mode case, fall through to the captured base
  function (preserving its auto-accept feature-value injection) otherwise. Same
  codebase pattern the base class itself already uses for provider dispatch.

- **`acp-model-rejection.mjs`** (+ `.test.mjs`) — rejects unavailable legacy
  models and model config choices with an error after the existing warning.
  This prevents AgentManager from recording a requested model that the ACP
  consumer did not select. Tests drive the real bundled selection helpers,
  session methods, and manager method; invalid choices preserve previous state,
  while valid choices reach the ACP connection. The ACP module is not pinned in
  `INSTALLED_SHA256SUMS`, so this follows the existing install-time ACP overlays
  without rebaking the vendor bundle.

- **`agent-resolve-by-id.mjs`** (+ `.test.mjs`) — `paseo agent archive`, `detach` and `reload`
  resolve their target by scanning the `includeArchived` agent list, which the server caps at
  200 (`session.js` `limit ?? 200`; the CLI passes no `--page`). On a box with thousands of
  archived agents an old or stopped seat sorts past the cap and the command answers `Agent not
  found` — precisely the seat you are trying to clean up or reload (a 24h sweep on 2026-09-21
  hit 17/17 failures). The sibling commands `stop`/`delete` already resolve a single id straight
  from the daemon with `fetchAgent({agentId})`; this patch gives the three list-scanning commands
  the same fast path, leaving prefix/name on the list (the daemon cannot resolve those directly).
  CLI modules only, so **no daemon restart** — same class as `agent-history-delete-guard`.
  **Remove this overlay when upstream resolves single ids in the CLI** (a `--page` loop or an id
  lookup); the anchors disappear with the fix, so the patcher then skips with exit 20.

- **`anchor-manifest.json`** — records the pinned Paseo/web-ui version, the pristine
  web-ui SHA, the **shape table** (every bundle state the fleet is known to carry: the
  pinned bundle plus a named subset of the web-ui edits), every patcher's representative
  bundle anchors, and the guard-before-group dependency. The offline drift test compares
  the shape table against `patch-web-ui.js` as data and checks that the manifest still
  agrees with the installer and patcher sources; it does not vendor any upstream bundle.
  `paseo_version` tracks `install.sh`'s pin (checked independently); `web_ui.*` tracks
  `patch-web-ui.js`'s own `PINNED_SHA`/`PINNED_VERSION`/`KNOWN_BUNDLE_SHAPES` (checked
  independently too) — the two can legitimately lag each other, as they do right now:
  `paseo_version` is `0.8.0` but `web_ui.*` still describes the 0.2.5 web-ui bundle,
  because the web-ui patcher's 10 anchors have not been re-derived yet (tracked
  follow-up — see `../vendor/guarded-0.8.0/README.md`). Once that lands, `web_ui.*`
  and `patch-web-ui.js`'s constants move together.

The browse-host sidecar carries one more AGPL derivative outside this directory:
**`../browse-host/bin/patch-web-ui.js`** (`SPDX-License-Identifier:
AGPL-3.0-only`). Its always-on `--subagent-stream` group fixes the provider-child
subscription boundary, sets the fresh-install font-size defaults (ui 18 / code 14
instead of upstream's 16 / 12 — a device that already saved settings keeps its own),
shares the sidebar order across devices, and makes touch devices usable (tooltips do
not park over the composer; a coarse pointer gets the project row's `+` without first
manufacturing a hover; one tap on a sidebar row navigates, instead of being eaten by
the long-press/drag machinery web never arms); its optional `--browse` group contains
the three live-panel edits. Both share fail-loud state classification, syntax gating,
and content-hash cache busting. Everything else under `../browse-host/` is an independent sidecar, AGPL-3.0 like the rest of the repo.

## Why the rest of Airlock is not a derivative of Paseo

Airlock runs Paseo as a **separate process** and communicates with it over
IPC/WebSocket. The Airlock core and the `apps/paseo/` installer + `browse-host/`
sidecar (our own code) do not incorporate Paseo's source, so they are *mere
aggregation*: Paseo's licence does not reach them. Only the modifications **to
Paseo itself** (here) are derivatives.

Since 2026-09-08 the core is AGPL-3.0 too, chosen by the copyright holder rather
than inherited. Keeping the two reasons apart still matters — the core's licence
was always the holder's to choose; for these files, Apache-2.0 §4(b) is *why*
there is a choice to make at all (a pre-`v0.7` AGPL-3.0 upstream would have left
none).

> This is not legal advice. Confirm against the Apache-2.0 and AGPL-3.0 terms —
> and consider asking the Paseo maintainers for explicit interop guidance —
> before publishing.

## AGPL §13 (network use)

Because we license these patches (and the web-ui patcher) AGPL-3.0-only by our
own choice, AGPL-3.0 §13 attaches to them regardless of Paseo's own upstream
licence: if you offer a modified Paseo carrying these patches to users over a
network, AGPL-3.0 requires you to offer them the corresponding source. Airlock's
own core is independently AGPL-3.0 too (the copyright holder's own choice), so
this obligation also holds at the whole-product level. Operators of an Airlock
deployment that exposes Paseo are responsible for this.

## TODO before public release

- [x] Vendor the full AGPL-3.0 license text into this directory (`LICENSE`) and
      the upstream Apache-2.0 text (`UPSTREAM-LICENSE`, required by Apache-2.0
      §4(a) for the unmodified portions of each patched file).
- [ ] Audit each patch/anchor to confirm only minimal, interoperability-necessary
      excerpts of Paseo source are reproduced (prefer install-time anchor derivation
      over shipping verbatim upstream lines where feasible).
