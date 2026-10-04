# Guarded Paseo 0.8.0 bundle

This directory is the reproducible Airlock input for the guarded Paseo 0.8.0
deployment. The seven npm package tarballs are installed together so npm resolves
the modified `@getpaseo` packages as one version-consistent set.

- Base: upstream Paseo `v0.8.0` (`b8e24677e12b226c7c38c1c3a40649daa9f1152f`)
- License: Apache-2.0 (upstream, since `v0.7`) for the unmodified portions; our own
  overlay is licensed AGPL-3.0-only by our own choice — see `LICENSE` (our AGPL-3.0
  text) and `UPSTREAM-LICENSE` (upstream's Apache-2.0 text) beside this file, and
  `../../patches/README.md` for the full reasoning.

The installer verifies `SHA256SUMS` before changing the npm prefix and records
the checksum-file digest as the installed identity. It also checks the critical
installed files in `INSTALLED_SHA256SUMS` on every run, so replacing the bundle
with a stock package of the same version cannot pass as idempotent. An explicit
`[apps.paseo].version` override selects the ordinary npm registry path instead.

## What is overlaid, and why

The 0.2.5 predecessor of this bundle carried a never-upstreamed fork PR
(`6d13dd8e042de1120ff63ac19c0d690d0ad7c32e` on top of merge-base `6fc491e6220fba
6543bbbe4bf1b1f58cfe59228b`) adding three protections beyond stock Paseo: an MCP
fix so archived sessions stop appearing live, an atomic guard on agent-message
send (`agentMessageSendGuard`), and exact schedule pause/resume state restore
(`scheduleStateRestore`). Comparing that fork commit against the real `v0.8.0`
tag via the GitHub compare API (718 commits apart, never merged) showed:

- The MCP archived-session fix is independently covered by upstream 0.8.0's own
  `includeArchived` filtering (`agent/tools/paseo-tools.js`). Nothing carried
  forward.
- `agentRequestReceipts` — the request-dedup journal the old fork intentionally
  left at capability `false` (it didn't cover keyed agent creation) — is now a
  complete, independent upstream implementation (`agent/requests/index.ts`,
  covering both `create` and `send`) and defaults to `true`. We reuse it as-is;
  it is not part of this overlay.
- `agentMessageSendGuard` and `scheduleStateRestore` were genuinely absent from
  `v0.8.0` (confirmed: no equivalent files, no "restore" logic in
  `schedule/store.ts`, no `expectedStatus`/`expectedUpdatedAt`/
  `expectedArchivedAt` anywhere in `packages/`). Re-derived and re-implemented
  against the current 0.8.0 architecture (not a raw patch-apply — 718 commits of
  drift made the old fork's diff inapplicable as-is) on branch `c2-guard-port`
  of a throwaway clone of `https://github.com/getpaseo/paseo`, as two commits:
  `ad7ced8bf` (agentMessageSendGuard) and `d86a6a310` (scheduleStateRestore).
  Both reuse upstream's own `AgentRequests`/lifecycle-mutation-queue mechanisms
  rather than reintroducing the old fork's now-redundant plumbing.

The server archive overlays this branch's own build output for the eight
`@getpaseo/server` files the port actually touches (`agent/agent-manager.js`,
`agent/agent-prompt.js`, `authorization/operation-permissions.js`,
`schedule/service.js`, `schedule/store.js`,
`session/schedule/schedule-session.js`, `session.js`, `websocket-server.js`),
the protocol archive overlays `messages.js`, `schedule/rpc-schemas.js`, and the
generated validator `generated/validation/ws-outbound.aot.js`, and the client
archive overlays `daemon-client.js`.

On top of that guard-port overlay, four local Airlock patches that have no
runtime behaviour test — just a syntactic anchor match plus `node --check`
(`depth4-search`, `image-attachments-persist`, `claude-model-prune`,
`opencode-grok-defaults`) — are baked into the tarballs too, same as the
0.2.5 predecessor baked in every patch it shipped: a stock re-download of
the same version cannot silently regress any of them, and `install.sh`'s own
patch steps correctly report "already applied" instead of doing redundant
first-install work. `opencode-grok-defaults` needed real re-derivation, not
just anchor drift: 0.8.0's thinking-default selection changed mechanism
(`defaultThinkingOptionId` now reads `thinkingOptions[0].id` off an array
that starts with a synthetic "Default" entry, not `rawVariants.map(...,
isDefault: index === 0)`), so the fix now reorders the assembled
`thinkingOptions` array instead of `rawVariants` — verified by isolating
`buildOpenCodeModelDefinition` and driving it with a mock grok-4.6 model
(`defaultThinkingOptionId` came back `"high"` as intended).

`opencode-grok-defaults` was re-baked again (C2.6, 2026-09-16) to put
`opencode-go/muse-spark-1.3-contributor` first in the picker (ahead of
`xai/grok-4.6`, then `xai/grok-build-0.1`) and default its thinking to `max`
via the same reorder mechanism as grok-4.6's `high`. `max` is not in the
models.dev catalog (it stops at `xhigh`) — it only exists as a variant when a
box's own `~/.config/opencode/opencode.jsonc` defines it (box-local config,
not shipped here), so this half of the patch is a no-op on every box that
hasn't opted into `opencode-go`/muse-spark. Re-baking (rather than leaving
this install-time-only) was required for the same idempotency reason as the
patches below: the sentinel text did not change, so the already-baked file
already satisfied the old patcher's `already applied` check — only replacing
the vendored bytes actually ships the new order.

`opencode-grok-defaults` was re-baked once more (C2.6b, 2026-09-16): the
muse-spark thinking default is `xhigh`, not `max`. Measured on the box, the
`max` variant (a box-local `opencode.jsonc` invention — the models.dev catalog
stops at `xhigh`) is rejected by the provider
(`invalid_request_error: The request contains invalid parameters`), so the
C2.6 default broke effort changes in Paseo. Same reorder mechanism, same
idempotency reason (sentinel still unchanged), same no-op property on boxes
without `opencode-go`/muse-spark.

`provider-subagent-stream-filter` is baked in too, despite having its own
runtime behaviour test (unlike the four above) — that test passes cleanly
against the 0.8.0-derived candidate, so there is no verification gap to
avoid shipping unverified. Needed real re-derivation: 0.8.0 already built
`forwardProviderSubagentUpdate` itself (a per-capability, per-source delivery
method that did not exist in 0.2.5), but it still does not filter by the
VIEWED parent agent — every source that supports the capability still
receives every provider-subagent update, the same over-broadcast the 0.2.5
patch closed. The fix adds the same `viewedTimelineAgentIds`/
`viewedTimelineAgentIdsBySource` checks `forwardAgentStream` (normal agent
streams) already uses, keyed on the update's `parentAgentId`.

`archive-consistency` is baked into `session.js` and
`session/agent-updates/agent-updates-service.js`. Upstream 0.8.0 can archive a
workspace record while leaving its agent record unarchived; the default agent
snapshot used to expose that orphan as live, and a later live/stored
`agent_update` could insert it again. The patch applies the same workspace
archive predicate to the snapshot and subscription boundaries: default updates
emit `remove`, while `includeArchived=true` keeps the diagnostic/recovery
`upsert`. Agents with no or unknown workspace identity keep their existing
snapshot behavior. Its behavior test covers both paths, idempotence, mixed-state
refusal, and anchor drift.

`workspace-remove-delivery` is baked into `session.js` (2026-10-02). A
changes-only resubscription omits unchanged cached workspaces from the session's
last-emitted map; their first archive removal must still be delivered. The
behavior test executes the Session delivery branch and checks the real
DirectorySyncService changes-only bootstrap and removal sequence. Baking this
patch and updating both checksum manifests preserves installer idempotency;
leaving it as an install-time mutation would reinstall and restart on every run.

`orphan-process-guard` (claude) and `orphan-process-group` (claude-agent,
claude-query, codex-transport) are baked in for the same reason as
provider-subagent-stream-filter: both have their own runtime behaviour tests
(`orphan-process-guard.test.mjs`, `orphan-process-group.test.mjs`) and both
pass cleanly against the 0.8.0-derived candidates. codex is not covered any
more: re-checked against 0.8.0, upstream independently rewrote
`CodexAppServerSession`'s `connect()`/`close()` lifecycle (a `this.closed`
gate at three points, `connectionPromise` de-duplication so overlapping
callers cannot each spawn their own app-server, and identity-checked dispose
in every failure branch) — the same fix this patch makes for claude, already
shipped upstream. `orphan-process-group`'s `claude-agent` mode chains on
`orphan-process-guard`'s own output text, so the two ship together: baking
one without the other would leave `claude/agent.js` pinned at a state
`install.sh` never actually produces standalone. Baking both was also
required for a correctness reason, not just a tidiness one: before this,
`orphan-process-guard`/`orphan-process-group` used to drift-skip against
0.8.0 (never mutating `claude/agent.js`), so `INSTALLED_SHA256SUMS`
happened to still hold after a real install. Re-deriving them to actually
apply broke that — install-time-only patches that succeed keep mutating a
pinned file on every run, so the very next idempotency check saw a checksum
mismatch and reinstalled from scratch every time. Baking removes the
mutation from the post-install steady state and restores idempotency.

This adds `session.js` (depth4, provider-subagent-stream-filter,
archive-consistency),
`session/agent-updates/agent-updates-service.js` (archive-consistency),
`agent/providers/claude/agent.js` (image persistence, orphan-process-guard,
orphan-process-group), `agent/providers/claude/query.js`
(orphan-process-group), `agent/providers/claude/model-manifest.js` (model
prune), `agent/providers/opencode-agent.js` (opencode grok defaults),
`agent/providers/codex/app-server-transport.js` (orphan-process-group), and
`agent/providers/codex-feature-definitions.js` plus
`agent/providers/codex-app-server-agent.js` (codex-model-roster), and
`schedule/service.js` (schedule-busy-pending-delivery, schedule-stale-due-run)
to the overlay.
Otherwise every byte in all seven tarballs, including the web UI bundle, is
exactly what `npm pack @getpaseo/<name>@0.8.0` produces from the real
registry. `INSTALLED_SHA256SUMS` pins every overlaid file.

`schedule-busy-pending-delivery` / `schedule-pending-delivery-schema` is
baked in too, for the same reason as `provider-subagent-stream-filter` and
`orphan-process-guard`/`-group` above. Its own runtime behaviour test
(steps ① busy defers without a failed run, ② repeat busy coalesces, ③ idle
delivers exactly once, ④ no duplicate delivery) drives the patched
`ScheduleService` with a stub `agentManager` — the stub was stale for
0.8.0: `executeSchedule`'s agent-target path now goes through the shared
`startAgentRun()` helper (`ensureAgentLoaded` → `tryRunOutOfBand` →
`steerOrReplaceActiveRun` → `startOrReplaceRun`, which is where busy
actually forks into `replaceAgentRun()` vs `streamAgent()`) and
`waitForAgentEvent()`, not the simple `runAgent()` the 0.2.5-era stub
satisfied, so ③④ could not run to a real verdict. Fixed and re-verified
against the real 0.8.0 dist — all four steps pass — so both halves are now
baked in together (the schema half already was; leaving the service half
install-time-only once it started actually succeeding would have repeated
the same idempotency hazard `orphan-process-guard`/`-group` hit: a
non-baked patch that succeeds keeps mutating a pinned file on every run).

`schedule-stale-due-run` is baked in on top of it, and had to be: the tick it
anchors on is the one `schedule-busy-pending-delivery` writes, so leaving it
install-time-only would mutate a pinned `schedule/service.js` on every run and
reinstall the bundle from scratch each time — exactly the idempotency hazard
described above. It closes two defects that only show once the schedule
directory is large. The daemon's tick is `setInterval(..., 1000)`
fire-and-forget, so a slow tick is re-entered; `runSchedule` then receives a due
snapshot the on-disk record has already moved past, and 0.8.0's
`appendRunningRun` appends unconditionally — so a `maxRuns: 1` one-shot gets a
second run, which is what makes a delivery receipt read `unavailable`. Measured
on a pilot box 2026-09-23: 21 of 415 delivery schedules carried two succeeded
runs. The patch revalidates inside `store.update`'s atomic section (active,
`nextRunAt === scheduledFor`, not past expiry/maxRuns), returns null on refusal
and never calls the runner. It also moves the append inside `try`: 0.8.0 leaves
it outside, so a throwing append skips `finally` and strands the id in
`runningScheduleIds` forever. Second, `tick()` called `store.list()` twice per
second and `list()` reads and parses every JSON in the directory — 2,760 files
was ~5,520 reads/sec; the second call now reuses the first snapshot, which is
only safe *because* of the revalidation above, so the two ship as one patch.
Its behaviour test drives the patched service with stub seats and the
precursor's own test is re-run against the same candidate.

`schedule-pending-batch` is baked in on top of `schedule-stale-due-run`
(2026-10-03), for the same idempotency reason. session-delivery creates one
one-shot schedule per message, so a seat that stays busy collects several
pending schedules; delivering one holds the seat for the whole turn and the
others wait a turn each. Measured on a pilot box 2026-10-03: 15 deliveries queued
for one seat, delivery lag p50 of 1.3–2.3 h in the worst hours. The patch
claims every pending schedule of an idle seat and delivers them in one turn,
each schedule still getting exactly one run (the session-delivery receipt
contract). It also puts the pending bit back when a claimed schedule's append
is refused, instead of leaving it until the next cron hour. Only
`dist/server/server/schedule/service.js` changed in the tarball.

`claude-model-prune` was re-baked (2026-09-24) to add Opus 5.5
(`claude-opus-5-5`, released 2026-09-22) at the top of the Claude picker and relabel
Opus 5 as the previous release. Same reason as the other re-bakes: the sentinel is
unchanged, so only replacing the vendored bytes ships the new roster. Only
`model-manifest.js` differs from the previous server tarball; both checksum files
are updated.

`claude-model-prune` was re-baked again (2026-09-29) to add Sonnet 5.5
(`claude-sonnet-5-5`) to the picker. Its 1M context and `high` default effort
match Anthropic's model specification; Paseo's existing Claude thinking default
already selects `high`. Sonnet 5 is labelled as the previous release. The
server tarball and both checksum files are updated together.

`codex-model-roster` is baked into the two Codex provider modules. Paseo obtains
the picker from Codex app-server's live `model/list`, so the overlay keeps that
availability boundary and filters only the retired exact ID `gpt-5.5`. The Fast
capability table adds `gpt-6-sol` and `gpt-6-luna`; the rows therefore appear
only after the signed-in ChatGPT account receives them, but arrive with the Fast
control on the first eligible refresh. Both modules and their behavior test are
applied as one unit, and both installed files are pinned below.

`workspace-git-watch-recovery` is baked into `server/workspace-git-service.js`. It is a
backport of upstream getpaseo/paseo `8ffe7c75d` ("Keep the daemon responsive when file
watching fails", #3056), working-tree path only, with upstream's constant names so the
overlay can simply be dropped when the pin moves past it. In 0.8.0 a working-tree watcher
that misses its 10s subscribe deadline falls back to a 5s poll (four git commands per
tick) and gives up recovering after three attempts, so one slow moment — typically a
daemon boot with many workspaces — becomes polling that lasts until the next restart.
Measured on a pilot box 2026-09-25: that fallback was the top git refresh source (610 per
30s window) and the git queue peaked at 552 waiting. The patch keeps retrying (backoff
capped at 300s) and doubles a quiet poll's interval up to 60s, returning to 5s as soon as
a refresh changes the snapshot fingerprint. Its behaviour test drives the two patched
methods directly and reads the delays handed to `setTimeout`.

`workspace-git-emergency-policy` and `workspace-reconciliation-emergency-policy`
are baked into their two service modules (2026-10-04). Automatic cached Git
refreshes, repo fetches and whole-inventory reconciliation admit one in 20 per
target/service; explicit, forced and boot work remains available. Reconciliation
accounts for 405/423 Git calls in the measured 30-second overload trace and bypasses
the snapshot pipeline, so both envelopes are necessary. Explicit full work queued
behind automatic metadata retains its exemption. The two patchers generate their
scale parsing from `patches/background-git-policy-source.mjs`.
Both installed files are checksum-pinned; installation sees `ALREADY` and does
not alter them, preventing checksum mismatch/reinstall/restart on every re-run.
Only those two tar members changed; both checksum files and reference patches
were regenerated. This is a temporary freshness tradeoff pending a durable fix
to observation demand and metadata fanout.

The web-ui patcher (`browse-host/bin/patch-web-ui.js`) is re-derived for
0.8.0 — all 10 anchors updated (the bundle's persistence layer alone moved
from `createJSONStorage` to a validated wrapper,
`createValidatedPersistStorage`, confirmed against upstream source) and
verified against the real extracted 0.8.0 web-ui bundle: both
`--subagent-stream` and `--browse` apply cleanly, idempotently, with hashes
matching `KNOWN_BUNDLE_SHAPES`. It is not baked into these tarballs — it
patches the separately-shipped web-ui `dist` directory at install time, not
`@getpaseo/server`'s own files — so `install.sh`'s two call sites
(`apps/paseo/install.sh` for `--subagent-stream`,
`apps/paseo/browse-host/install.sh` for `--browse`) still wrap it in
`if ... then ... else warn ...` for defense in depth against a future bundle
shape neither anchor set covers, per its own CLI's fail-loud design ("REFUSE
(exit 1) rather than run an unpatched/half-patched build") — but a real
end-to-end `bash apps/paseo/install.sh` run against this exact bundle takes
the success branch on both, not the warning one.

Verification before vendoring: 76 new tests (guard e2e, schedule-restore e2e,
store, service) plus a 359-test regression sweep of the directly-touched files
(agent-manager, agent-prompt, session, websocket-server notifications,
wire-compat) green under the upstream repo's own `vitest`, re-run independently
(not just taking the porting agent's word for it) against the final committed
state. `npm run build` for all seven packages (and their build-order
dependencies) succeeds clean. A real `npm i -g` of these seven tarballs into a
scratch prefix lands `@getpaseo/*` as siblings (no nesting under `cli`, the
layout `install.sh` depends on), `paseo --version` reports `0.8.0`, and a real
`bash apps/paseo/install.sh` run against that tree (the actual installer, not
a fixture) applies all ten baked-in patches (depth4, image-attachments-
persist, claude-model-prune, opencode-grok-defaults,
provider-subagent-stream-filter, orphan-process-guard, orphan-process-group,
schedule-busy-pending-delivery, archive-consistency, codex-model-roster)
idempotently, restarts the
daemon, and installs successfully end to end.
