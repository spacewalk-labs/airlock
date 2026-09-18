# agy-acp — Airlock's fork of google-antigravity-acp

Lets Paseo drive Google Antigravity's `agy` CLI as an ordinary agent provider,
over the Agent Client Protocol (ACP). This directory is a **source fork**, not
a vendored build: unlike Paseo itself (AGPL, so only install-time text patches
against the installed dist are possible — `../patches/`), upstream
`sibbl/google-antigravity-acp` is **MIT**, which permits redistributing the
patched source directly.

## Provenance

- Upstream: <https://github.com/sibbl/google-antigravity-acp>, MIT, Copyright
  (c) 2026 Antigravity ACP Contributors (`LICENSE` in this directory, copied
  from upstream, unmodified — the license and copyright notice are preserved
  verbatim as MIT requires).
- Forked from upstream `main` commit `d3a0163` (npm `google-antigravity-acp@1.1.1`).
- `src/openclaw-plugin.ts` was **not** forked. Upstream ships it to run as a
  plugin inside a separate host application ("OpenClaw"), unrelated to
  Airlock/Paseo; it type-checks only against that host's own SDK package,
  which this fork does not otherwise need as a dependency. Everything else
  (`acp-agent.ts`, `agy-session.ts`, `types.ts`, `binary.ts`, `cli.ts`,
  `one-shot-cli.ts`, `index.ts`) was forked and, where noted below, patched.
- Local patches (the delta from the upstream pin above) are Airlock's own
  work, licensed under this repo's AGPL-3.0 — same basis as `apps/orca`'s
  vendored web client: the upstream MIT base stays MIT-attributed, the patch
  on top is a new work by a different author under a different license. See
  repo-root `NOTICE`.

## What the patches fix (all in `src/agy-session.ts` and `src/acp-agent.ts`)

- **Interrupt/cancel respawn race.** Upstream's `cancel()` killed the running
  `agy` process with SIGINT and immediately cleared the "prompt in progress"
  state; the *next* prompt, sent as soon as the ACP client saw the turn end
  (before the SIGINT'd process had actually exited), either wrote to a dying
  process's stdin or raced its exit handler — the seat wedged. The fix
  detaches the cancelled process (tracked via an `exiting` promise, capped by
  a grace period), and the next `prompt()` waits for that detachment before
  spawning fresh. A prompt cancelled before it was ever written settles
  immediately rather than waiting for a respawn that was never going to carry
  it.
- **`session/load` + `session/resume` keyed by agy's own conversation id, with
  transcript replay.** Upstream never implemented session persistence
  (`loadSession: false`). The fix advertises `loadSession: true` and
  `sessionCapabilities.resume`, sets the ACP session id to agy's own
  `conversation_id` for a new session, and on load re-spawns agy with
  `--conversation=<id>` while replaying this adapter's own transcript (stored
  under `~/.cache/google-antigravity-acp/sessions/`) to the client — agy is
  not asked to replay history itself, only to continue the conversation. If
  agy no longer has that conversation, a mismatch is detected and surfaced to
  the user rather than silently starting a new one under the old id.
- **Config options: model id list from `agy models`, effort, respawn on
  `--conversation`.** No static model list — `getModelCatalog()` shells
  `agy models` and reports whatever comes back. A failed or empty query
  reports an error and is retried on the next request; a fixed fallback list
  must not replace the live catalog. Changing model, effort, or
  mode is deferred to the next prompt (`reconfigure()` + `restartPending`) so
  a running turn is never cut short.
- **Modes** (`bypassPermissions`, `acceptEdits`, `plan`, `readOnly`,
  `sandbox`) as fixed launch-flag sets, since agy runs headless and cannot be
  asked for interactive approval. `bypassPermissions`/`sandbox` are marked
  `_meta.paseo.isUnattended` so an unattended parent agent of another
  provider can create one (Paseo refuses an attended-only create otherwise).
  **The default is `readOnly`, not bypass.** A session opened with no
  explicit `--dangerously-skip-permissions` on the fork's own CLI — the shape
  a child agent spawned by an unattended parent of another provider gets,
  with no chance to opt in — must not silently inherit full tool-approval
  bypass; only an explicit opt-in unlocks `bypassPermissions` as the default
  mode for new sessions.
- **Tool titles/details.** `describeTool()` maps agy's raw `tool_info` (a
  flat, tool-specific parameter bag) to a human title, an ACP `kind`
  (execute/read/edit/search/fetch), and structured `rawInput`/`locations` —
  upstream showed only `Executing <raw_tool_name>`.
- **Slash commands via a separate `agy --print`.** agy's stream-json session
  refuses (and exits on) most `/command` input; local commands (`/usage`,
  `/model`, `/effort`, …) now run as a one-shot `agy --print /command`
  invocation instead of being sent into the live session. Paseo's `/` picker
  is fed `available_commands_update` with those local commands **plus the
  skills agy itself resolves** (workspace `.agents/skills`,
  `~/.gemini/config/skills`, `skills.json` entries — never workspace
  `.claude/skills`, which agy does not read), so `/share-docs` etc. show up;
  picking one just sends the text to agy, which expands the skill.
- **Images → temp file + `--add-dir`.** agy's stream-json input accepts text
  only; an attached image is written to a per-session temp directory added to
  agy's workspace via `--add-dir`, and the prompt references its path so agy
  can `view_file` it.
- **agy ERROR → turn failure**, except when agy answered anyway before
  reporting an error (observed: a 503 after the reply streamed) — that case
  keeps the reply and appends a note, rather than discarding an answer the
  user already has.
- **`realpath` cwd.** agy's permission check compares resolved paths; a
  symlinked workspace previously had its own files denied.
- **SIGKILL fallback with a process-tree kill.** If a cancelled/reconfigured
  agy process does not exit within the grace period, the fallback signals its
  whole process group (agy is spawned `detached: true`, making it its own
  group leader) so a tool subprocess it left running dies with it — a plain
  `child.kill('SIGKILL')` reaches only agy itself.
- **No auto-download without a digest.** `binary.ts`'s `downloadAgy()` fails
  closed if a release manifest entry carries neither `sha256` nor `sha512` —
  an unverified binary executed as `agy` is the whole trust boundary this
  package hands to Paseo, so a manifest gap is refused rather than installed
  anyway. In practice this path is rarely hit at all: `resolveAgy()` prefers
  an already-installed official `agy` (via `AGY_PATH`, `~/.gemini/bin/agy`,
  `~/.local/bin/agy`, then `PATH`) and downloads only as a last resort.

## Registration with Paseo

Config-only — no Paseo source patch, no `apps/paseo/patches/` entry:
`~/.paseo/config.json` → `agents.providers.agy` = `{"extends": "acp",
"command": [...]}`, no `models` key (the fork's `getModelCatalog()` probes
`agy models` itself, over ACP). `"extends": "acp"` is Paseo's existing generic
ACP provider type (`GenericACPAgentClient`), which is why no Paseo dist patch
is involved. `install.sh` writes this entry (see below) plus
`~/.gemini/config/skills.json` (absolute path to `~/.claude/skills`, since `~`
is not expanded by whatever reads it).

If `config.json` already carries `agy-*` provider entries pointing at the
pre-fork global install (`.../node_modules/google-antigravity-acp/dist/cli.js`
— the shape an earlier exploratory session hand-wrote as `agy-low`/
`agy-opus`/`agy-gpt`, one per model, before this fork or its config-option
model picker existed), `configure-agy-acp.py` removes exactly those entries
when it writes `agy`. An `agy-*` entry that does not match that path — an
operator's own, differently configured — is left alone.

## Installing

`install.sh`, config-gated (`agy = true` under `[apps.paseo]` in
`airlock.toml`) and warn-only, called from `../install.sh` **before** that
script's own daemon restart decision (not after, alongside
`browse-host` — a same-process sidecar with no such coupling). Registering a
provider means writing `agents.providers.agy` into `config.json`, which only
takes effect the next time the daemon reads it at startup; written after the
restart it would sit unread until some unrelated later one. `install.sh`
exits `2` (not `0`) when it actually wrote a change, and the caller folds
that into its own restart decision — see the comment at the call site in
`../install.sh`.

It never runs `npm install -g`: the fork is staged and built under
`$HOME/.local/share/agy-acp` (LICENSE included), then referenced from
`config.json` by absolute path — same pattern as `../browse-host/install.sh`.
The real `agy` binary itself is resolved by the fork's own `src/binary.ts`
(`resolveAgy()`) at launch time, following `AGY_PATH`, `~/.gemini/bin/agy`,
`~/.local/bin/agy`, then `PATH`, downloading only as a last resort — this
installer never reads or copies
`~/.gemini/antigravity-cli/antigravity-oauth-token`.

## Testing

- `npm test` (or `install/test-agy-acp.sh`) — unit tests
  (`tests/agy-session*.test.mjs`, `tests/acp-agent.test.mjs`,
  `tests/binary.test.mjs` — the digest-required-or-refuse download path) plus
  the "fake-agy matrix" (`tests/fake-agy-matrix.test.mjs`): `AntigravityAcpAgent`
  driven through the real ACP protocol (in-process, via the SDK's
  client↔agent direct connection) against `tests/fixtures/fake-agy.mjs`, an
  offline stand-in shaped after real agy 1.2.3's observed timing and
  behavior. No real `agy` binary, no real Paseo daemon, no network beyond
  `npm ci` for this package's own two runtime dependencies.
- `install/test-agy-acp-daemon.sh` — the same fork driven through a real,
  isolated Paseo 0.2.5 daemon (own scratch `$HOME`, own port, fake-agy again
  standing in for `agy`), proving the interrupt/respawn fix survives Paseo's
  own ACP client and a daemon restart mid-conversation.
- `install/test-agy-acp-install.sh` — `install.sh` itself: the config gate,
  the build, and `configure-agy-acp.py`'s idempotent
  `config.json`/`skills.json` writes (including that a pre-existing
  `config.json` with other providers is preserved, not overwritten).

## Known limitations

- **MCP servers are not passed to agy.** `session/new|load|resume`'s
  `mcpServers` parameter is received but not forwarded — there is no evidence
  in any capture this fork is built from that agy's CLI accepts an MCP server
  list at all. Wiring one up needs confirming against a real `agy
  --help`/docs first (an unverified flag risks a silent behavior change worse
  than the current gap). Paseo's own MCP tools (`list`/`send`/`create`/
  `archive` agents, `browser_*`) are unaffected — they run through Paseo's
  daemon-side MCP endpoint regardless of provider.
- **The transcript cache has no TTL or size cap.** `~/.cache/google-antigravity-acp/sessions/`
  grows by one `.jsonl` (+ optionally one `.meta.json`) per session; the only
  cleanup path today is an explicit `session/delete` (which this fork does
  implement — see above). A TTL or cap is out of this fork's own scope; it is
  not ledger/snapshot-tracked either, by the same "retained data" precedent
  `~/.paseo/config.json` itself already sets — see `apps/paseo/airlock-app.toml`'s
  artifacts Appendix.
- **"Child seat does not inherit bypass" is proven on this fork's own half
  only.** `tests/fake-agy-matrix.test.mjs`'s `[S9]` case proves an
  unconfigured agy session defaults to `readOnly` and carries no
  `_meta.paseo.isUnattended` tag — the only signal this fork emits toward
  Paseo's own cross-provider default-mode propagation
  (`create-agent-mode.js`). It does not exercise that Paseo-side logic itself
  (owned by C2's patches, and needs the 0.8.0 server this fork's tests do not
  vendor) — a real agy-parent-creates-Claude-child regression test belongs to
  C2.5's combined-revision suite.
