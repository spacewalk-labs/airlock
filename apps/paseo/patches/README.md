# paseo patches — AGPL-3.0-only

**License: `AGPL-3.0-only`** (not the repo's Apache-2.0).

Paseo (`@getpaseo/cli`, upstream https://github.com/getpaseo/paseo) is licensed
**AGPL-3.0**. The files in this directory modify Paseo's own bundle, so they are
**derivative works of Paseo** and are licensed **AGPL-3.0-only**, independent of
the Apache-2.0 license that covers the rest of Airlock.

## What is here

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

- **`credential-key-preservation.mjs`** (+ `credential-key-preservation-{claude,codex}.patch`,
  the reference copies) — paseo's quota fetchers refresh the OAuth token when the usage
  API answers 401/403, and they write it back through a zod `z.object`, which **strips
  unknown keys at every level**. So the write-back does not update the credential file,
  it replaces it with the four fields the schema happens to name.
  `~/.claude/.credentials.json` loses `claudeAiOauth.expiresAt`, `refreshTokenExpiresAt`
  and `scopes` — and the whole top-level `_meta` block (email/org/kind) our account
  switcher reads. `~/.codex/auth.json` loses `tokens.id_token` and the top-level
  `auth_mode` / `OPENAI_API_KEY` / `last_refresh` (the field that says whether a green
  Codex panel is backed by a token that is actually alive). Both write paths sit inside
  a bare `catch {}`, so the loss is silent. The patch merges the refreshed token fields
  into the object **parsed from disk** instead of into zod's output, and gives the claude
  side's swallowed catch a `logger.warn` (the codex provider is constructed without a
  logger). Data preservation only: refresh timing and the 401/403 trigger are untouched,
  and the stale `expiresAt` is preserved rather than recomputed — a past expiry makes
  Claude Code refresh on its own next call, an absent one leaves its state ambiguous.
  Two independent targets, one invocation each (`claude` / `codex`); anchors must be
  present **and** unique or it exits 20. `credential-key-preservation.test.mjs` is the
  behaviour check — it slices each save method back out of the installed bundle and drives
  it against an in-memory fs and invented fixtures, because "what survives a write-back"
  is precisely what a text anchor cannot assert. It never reads a real credential file.
  Verify after install:
  `node credential-key-preservation.test.mjs claude <installed>/quota-fetcher/providers/claude.js`.

- **`anchor-manifest.json`** — records the pinned Paseo/web-ui version, the pristine
  web-ui SHA, the **shape table** (every bundle state the fleet is known to carry: the
  pinned bundle plus a named subset of the web-ui edits), every patcher's representative
  bundle anchors, and the guard-before-group dependency. The offline drift test compares
  the shape table against `patch-web-ui.js` as data and checks that the manifest still
  agrees with the installer and patcher sources; it does not vendor any upstream bundle.

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
and content-hash cache busting. Everything else under `../browse-host/` is an independent Apache-2.0 sidecar.

## Why the rest of Airlock can stay Apache-2.0

Airlock runs Paseo as a **separate process** and communicates with it over
IPC/WebSocket. The Airlock core and the `apps/paseo/` installer + `browse-host/`
sidecar (our own code) do not incorporate Paseo's source, so they are *mere
aggregation* and remain Apache-2.0. Only the modifications **to Paseo itself** (here) are
AGPL-3.0.

> This is not legal advice. Confirm against the AGPL-3.0 terms — and consider
> asking the Paseo maintainers for explicit interop guidance — before publishing.

## AGPL §13 (network use)

If you offer a modified Paseo to users over a network, AGPL-3.0 requires you to
offer them the corresponding source. Operators of an Airlock deployment that
exposes Paseo are responsible for this.

## TODO before public release

- [ ] Vendor the full AGPL-3.0 license text into this directory (`LICENSE`).
- [ ] Audit each patch/anchor to confirm only minimal, interoperability-necessary
      excerpts of Paseo source are reproduced (prefer install-time anchor derivation
      over shipping verbatim upstream lines where feasible).
