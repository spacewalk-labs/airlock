# Learning — redesign for someone else's box (design v2, draft)

> Status: **draft, reviewed once on two axes.** Owner decisions of 2026-08-21 are
> recorded under "Settled" and are not open. Everything else is.
>
> The bias is stated up front because it decided several of the calls below:
> **UX first.** Where a safety control and a smooth first run disagree, this
> design picks the smooth first run unless the control protects something the
> owner cannot get back — their documents.
>
> v1 was reviewed by two independent models: one on user experience, one on
> architecture and the package contract. Both found real errors in v1, and they
> converged from opposite directions on the same central change (see "What both
> reviews found"). Corrections are marked **[v1 was wrong]** where v1 asserted
> something the code contradicts.
>
> Base: `e8cda09`. Measurements are from the reference box, 2026-08-21.

## The problem in one paragraph

The app on the reference box is not a personal toy — it is the most active
pipeline there: 167 study documents, its content repo at PR #232, an ingest run
completed the morning this was written — and another landed *while this document
was being written*, which moved both numbers by one. But it does not install for anyone else,
and the reason is not configuration. **A third of the app lives inside the
owner's content repository**, and the procedure that produces a document routes
through a git worktree, a pull request and a merge. Point it at another folder
and it returns 500 before drawing anything.

## Settled (owner, 2026-08-21)

1. **Name.** Package id `learning`, display `Learning`, subtitle `Learning
   Library`. `-manager` is dropped: it named the old relationship, in which the
   app managed the publication state of a repository it did not own.
2. **Starred/archived state lives inside the library**, in each document's YAML
   frontmatter, not in an app-side JSON. Reason given: the library should be
   liftable into a wiki later, and a document should carry its own marks.
3. **Ingest ships with the app.** The platform's baseline assumption is that some
   agent CLI is logged in on the box, so the app may depend on that.
4. **Publishing stays first-party**, but published documents leave through the
   same exit as shared documents — the `publish` app's.

Three more, taken after the two reviews:

5. **The model is never exposed.** The app detects a logged-in CLI and picks;
   the user pastes a link and nothing else. Advanced users go through config.
6. **No automatic commits in v1.** Git is read-side only — it improves sort
   order and nothing else. `git_post_save` is deferred, not shipped disabled.
7. **The publish API's first-party scope is not surfaced.** To the user the
   share button either works or does not; smoke is where a mismatch appears.

## What both reviews found

The UX review and the architecture review were given different questions and
reached the same conclusion from opposite ends:

- **From the user's side:** the markdown file already exists at step 4 of the
  ingest procedure — roughly four minutes in, once the git steps are gone. The UI
  waits for the completion marker at step 8 and shows nothing until then. So the
  fifteen-minute wait is not a slow pipeline, it is **a readable document held
  back for ten minutes.**
- **From the contract side:** step 8 emits a single DONE only after save,
  rendering, git *and* publishing all succeed. Keep that shape and a document
  that saved perfectly is reported as a failed ingest because publishing failed.

Same fix. **Success is not one event.** It splits into `document_saved` (the
document exists and validates), `rendered`, and `published`. The first one is
what the list waits on; the rest are badges on a row that is already there.

This is the central change in v2.

## What is actually coupled today

Measured. The app is 6,513 lines (backend 2,935 + a single-file frontend 3,578).
Five things reach into the content repository:

| What | Where | If it is absent |
|---|---|---|
| Listing producer `python3 scripts/learn.py manifest --json` | `learning-manager.py:463` | **500 — the app does not draw** |
| Four hardcoded topics `{engineering, business, science, other}` | `:38`, a regex at `:80`, a path classifier at `:889` — **and again in the frontend** (`index.html:1279-1284`, keys plus Korean labels) | Documents in any other folder are invisible |
| Sort timestamps `git log --diff-filter=A` | `:800` | Already degrades to date order |
| Worktree awareness `git worktree list` | `:849` | Only worktree-copy detection is lost |
| Output verification + skill execution (cwd=repo) | `ingest_runner.py:434` | Ingest only |

Two facts reframe this:

- **The app's own code never talks to a remote.** No `push`, `fetch`, `pull`,
  `clone` or `remote` in either backend file; git is local only — `log`,
  `worktree list`, `rev-parse`, `cat-file`, `diff`, `show`. The scope matters:
  the *procedure the app spawns* does reach a hosting service, because
  `SKILL.md` §7 pushes and opens a pull request. So the app is coupled to *a
  folder that happens to be a git repository*, and the remote arrives through
  the procedure — which is exactly the part this design removes.
- **[v1 was wrong] The listing contract is not four fields.** v1 said the
  producer contract is "exactly `{path, added, title, mutable}`". Items also
  require `html_path` (`learning-manager.py:692-701`), and the envelope requires
  `schema_version`, `repo_head`, `items` and `warnings` (`:704-714`). Publish
  eligibility additionally reads `video_id`, `source` and `html_path`
  (`:720-758`). The seam is real but wider than v1 claimed, and `repo_head` is
  the part that does not survive a bare folder.

### ~2,990 lines of app living in the content repo, plus their tests

`learn.py` (539 — listing/save/index), `SKILL.md` (612 — the ingest procedure),
`transcribe.py` (259 — captions, local whisper fallback), `chunks.py` (411),
`check-publish.py` (406), `templates/` (217 — summary, quiz and publish-fragment
rules plus the published-page HTML shell), `make-fixture-repo.py` (157),
`preflight.py` (130), `transcript-block.py` (126), `timestamp-links.py` (118),
`test-regression.sh` (15). **Total 2,990.**

Their tests are in the same place and move with them: `tests/` is 2,736 lines
across ten Python files — nine regression suites covering manifest, save, index,
publish, chunks, transcribe and the skill, plus `conftest.py`.

None of that is content. Counting only the shipping code, install the app alone
and about **31%** of it is missing (2,990 of 9,503); counting the tests too,
nearly half.

### [v1 was wrong] and ~3,578 lines of scar tissue in the frontend

v1 counted only what moves *in*. The existing single-file frontend is not a
sketch to be replaced — it is a year of incidents written down as code: the
server-owned ingest queue with polling (so closing the tab does not kill a run),
optimistic starring with a per-document mutation queue that merges rapid clicks
and rolls back on failure (`index.html:3214-3227`), an early-title marker so the
card gets a title before the run finishes (`LEARNING-INGEST-META`,
`learning-manager.py:88-93`), an LLM one-line summary of a failure log instead of
a log tail (`failure_summary`), IME composition guards, and a background render
that swaps only the ingest slot so scroll position and focus survive.

**This is a port, not a rewrite.** Say so in the task card, or the rewrite will
happen by default and every one of those fixes will be re-learned.

### The deepest coupling is the procedure, not the code

`SKILL.md` §3-b creates a git worktree; §4 saves inside it; §7 commits, opens a
PR, merges and syncs; §8 then prints the completion marker the headless runner
treats as **the only evidence of success**. On a box with no repo, no remote and
no PR habit this breaks first — and it breaks *after* the expensive part
(transcription and summarisation) has already run.

The procedure also assumes one CLI's delegation primitives — `Agent(...)`, a
named model, specific tool names (`SKILL.md:11-35`, `:181-207`). "Runs on
whichever agent CLI is logged in" is not free.

## The new boundary

One sentence: **if I delete it and reinstall the app, should it come back?**
If yes it is the app; if no it is the library.

| App (ships in the package) | Library (the user's folder) |
|---|---|
| Listing, save, index | The markdown files |
| Ingest procedure + prompts | Folders — which *are* the categories |
| Summary/quiz/publish-fragment templates | Frontmatter marks (`starred`, `archived`) |
| Renderer + published-page shell | (optional) git history |
| Transcription, link checker, preflight | |

State splits the same way:

- **The document's → frontmatter:** `starred`, `archived`.
- **The app's → `.learning/` inside the library:** resurface timestamps,
  last-viewed, the ingest queue and its logs.

Today's `starred.json` is keyed by repo-relative path, so moving a file silently
drops its star. Frontmatter fixes that as a side effect.

## First run

**[v1 was wrong] There is no folder-picker screen.** v1 opened with "pick a
folder". A stranger has no opinion about a folder yet, and a decision is a bad
first thing to owe someone. Create `~/learning` silently and open the app.
Changing it lives in settings.

The empty library, in full:

- Centre of the screen, large: **one input, already focused.** Placeholder:
  paste a YouTube link.
- One line under it: "One link becomes one document — summary, full transcript,
  a comprehension quiz."
- One quiet line: "Already have markdown? Put it in `~/learning` and it shows up
  here · change folder".
- A third line **only if no agent CLI is logged in**, and it does not block
  browsing.

Install to first document: **open, paste, done. Zero decisions.** The first
ingest is the onboarding — the stage card teaches what the app does while it
works. No tour, no sample content.

The current pre-flight confirmation sheet ("this is the plan", showing cwd, the
executable and the account) is removed from the normal path. It was a dev-box
diagnostic. **One case keeps a sheet**, because it is a real decision:
this video is already in the library → open it, or ingest again?

## The ingest, as states

The runner already parses one marker; add a phase marker beside it. States:
`queued → fetching → transcribing (only when captions are missing) →
summarizing → saved → enriching → done`, plus terminal `failed(stage)` and
`cancelled`.

- **5s** — the card appears above the list: spinner, the URL, "checking the
  video". The input clears so a second link can go in immediately.
- **~30s** — the metadata marker lands: thumbnail (derivable from the video id,
  no API key), title, channel, duration. A four-step checklist replaces any
  progress bar — a percentage here would be a lie — plus elapsed time and an
  honest estimate computed from the app's own past runs.
- **transcribing** — say why and say the arithmetic: "no captions, transcribing —
  about 5 minutes for a 30-minute video". A wait you understand is a different
  wait.
- **~2m** — the checklist advances; one live line from the runner log underneath.
  One line, not a log window: evidence of life, not a debugger.
- **~4m, `saved` — the moment this design is built around.** The document appears
  at the top of the list and opens. The card collapses into a small badge on that
  row: "finishing quiz and cleanup".
- **`done`** — the badge disappears, the quiz opens. No toast; the reader is
  probably already reading. A "new" dot until first open.

**Ingest belongs to the backend, not the browser** — this is already true and
should be written down rather than rediscovered. Close the tab, reopen on a
phone, the card is where it was. One addition: set the document title to
"(ingesting) Learning" so a backgrounded tab shows state in the tab bar.

Failure gives two things a log tail cannot:

1. **Resume from the stage that failed.** Once the procedure belongs to the app,
   each stage can be idempotent on its artifact. If saving succeeded and the quiz
   failed, the document stays in the list with a "quiz failed · retry" badge.
   Nobody re-runs a four-minute summary because of a quiz.
2. **Retry with one more line.** A large share of failures are "the agent asked a
   question and there was no next turn". A small text field next to Retry, whose
   contents are appended to the prompt, turns a dead end into a conversation.
   Implementation is string concatenation.

## Provider neutrality

The unit of neutrality is an adapter, not an argv swap. Minimum interface:

- `probe()` — installed, and logged in?
- `build_argv(prompt, cwd)` and `build_env()`
- `skill_target` — the discovery path for that CLI
- `normalize_output(raw)` — **progress display only, never success**
- `process_ownership = attached` — the run and all its descendants stay in the
  process group the runner created

Today the executable and argv are fixed to one CLI (`ingest_runner.py:180-199`,
`:662-675`) and stdout parsing interprets that CLI's event stream (`:245-306`,
`:330-370`). The skill ships once in the package and is symlinked into each CLI's
discovery path; the procedure splits into a common body (fetch, save, validate,
artifact contract) and a per-provider appendix supplying the delegation
primitive.

### Success without a stream format

1. The runner mints an `attempt_id` and a nonce.
2. A **deterministic save helper that ships with the app** writes the document
   atomically — same-directory temp file, fsync, `os.replace`, directory fsync.
3. That helper — not the agent — writes a receipt:
   `{schema_version, attempt_id, nonce, document, video_id, content_digest, size}`.
4. Success requires **exit 0 AND a matching receipt AND direct validation of the
   file as it exists now**: a regular file inside the library root, not a
   symlink, above a minimum size, valid frontmatter, the requested `video_id`.

A receipt the agent could write itself is no stronger than the marker it
replaces. The digest proves *the file at save time*; later metadata edits
(starring) must not invalidate it, so the runner compares at judgement time
rather than demanding permanent equality.

### The optional git step

Only when the library is a repo **and** the user opted in. Run by the app's own
post-save job, not the agent. Stage exactly the paths ingest wrote; no worktree,
no push, no PR. A git failure never reverses a saved document. **Default off** —
an automatic commit would sweep in the user's unrelated edits and their stars.

## Listing

Two producers behind one normalizer:

- `builtin` — an **in-process** scanner over the folder. No subprocess: a
  protocol between the app and itself is a failure mode with no upside.
- `legacy` — the existing `scripts/learn.py`, still a subprocess, so the owner's
  library keeps working with **no change to their repo**.
- `auto` picks legacy when the script is present, builtin otherwise. If legacy is
  chosen and then fails, **it fails loudly** — no silent fallback that quietly
  changes what the list means.

The canonical item becomes `path, added, title, starred, archived, category`,
with optional `source`, `source_id`, `rendered_path`, `publishable`, and
producer metadata `revision` (nullable — `repo_head` has no meaning for a bare
folder) plus `warnings`.

## Frontmatter as state

The unrecoverable thing here is not a lost star, it is a damaged document.

- Patch only the known keys. **Never parse and re-serialise the whole YAML** —
  that would reorder keys, drop comments and rewrite quoting across every document.
- Same atomic write as above. The app already has this exact durability pattern
  for its JSON state (`learning-manager.py:1139-1165`); reuse it.
- Re-compare the source digest immediately before writing. If it changed, do not
  overwrite — re-read and re-apply once, or return a conflict.
- Ingest's save helper and the state patcher share a per-document lock. The
  existing `state_lock` does not cover this: it guards sidecar state and
  deliberately excludes the ingest queue (`:1116-1132`).
- **No frontmatter:** the document still lists; starring is disabled with a
  reason. **Malformed frontmatter:** read-only, do not repair. Do not prepend a
  block to a file whose format was misread — not for a star.

The interaction itself stays exactly as it is today: click, the star fills
instantly, nothing else happens. Optimistic update, merged rapid clicks,
rollback on failure. **No batch mode, no save button** — a save button on a star
is the safest and worst design available. In a git library the one-line diff is
a feature: it proves where the state lives.

One constraint falls out: **the default sort key must be frontmatter `added`,
not file mtime.** Starring touches mtime, and a row that jumps when you star it
makes the click feel heavy.

## Categories

Folders are the **only** truth. **[v1 was wrong]** — v1 kept a `topic`
frontmatter field *and* said folders are the categories. Two truths always
diverge; `topic` is demoted to a legacy field that is written but not read.

- Reading: always. One folder, one tab. The four hardcoded topics die.
- **A flat library renders no tab row at all** — not an "All" chip alone. Someone
  with no structure should not be shown the wreckage of structure. Create a
  folder and the tabs appear.
- The app creates a folder in exactly two cases: the user moves a document to a
  new one, or ingest picks a category that does not exist yet.
- **Ingest chooses from the folders that exist**, not from a fixed list — the
  user's own vocabulary. A flat library saves to the root and does not classify.
  Then, on the `saved` row, one line for one day: "filed under engineering ·
  change". A visible, one-tap-reversible classification costs nothing when wrong,
  which is why it does not need to be asked about first.

## Publishing

**[v1 was wrong] `public_target` must not be duplicated into this app's
config.** That schema is owned by `publish`'s manifest
(`apps/publish/airlock-app.toml:36-38`) and its runtime owns `ingest_url`,
`base_url`, `public_dir`, `gated_dir` and the token handling (`:18-30`).

The dependency edge itself is **not new platform work** — the package contract
already defines `[dependencies] apps = [...]`, with validation, topological
install/validate/smoke order and reverse-order deactivate
(`docs/design/app-package-contract.md:141-152`, `:323-365`).

But that edge is id-level, not capability-level. **[v1 was wrong]** — v1 said
password-gated sharing "comes along for free" with the dependency. It does not:
a dependency guarantees install order, not an upload API.

**[both reviews understated how much of this already exists.]** The review round
called the upload path "new, if small, first-party work". It is smaller than
that: `/publish/api/` is an existing proxied API family (`render.sh:102`) with
`upload-image`, `upload-file` (`apps/publish/backend/airlock-publish.py:1718`, `:1722`),
`list` (`:1657`) and `uploads-cleanup` (`:1670`), `publish`'s smoke already
probes it (`smoke.sh:23-35`), and **`notepad` is already a consumer** — it
declares `[dependencies] apps = ["publish"]` (`apps/notepad/airlock-app.toml:15-16`)
and posts to `/publish/api/upload-image` and `/publish/api/upload-file` from its
frontend (`apps/notepad/frontend/notepad.html:251`, `:302`).

So `learning` is not inventing a channel. It is the **second app to use one that
ships**, and what it adds is one more endpoint in that family — take a rendered
document plus a name and a visibility, return a URL and a receipt. Same-origin
through the hub proxy, so no endpoint injection and no config duplication.

**When to promote this to a platform capability:** when a third consumer needs a
target `publish` does not own, or an app outside this repo wants in. Until then a
capability contract would have one implementer and one-and-a-half consumers,
which is a guess wearing an abstraction. The promotion is additive — discovery in
front of an endpoint that does not change.

The boundary:

- **Learning owns** markdown semantics, templates, the renderer, the finished
  HTML, and the document's stable name and metadata.
- **Publish owns** receiving that HTML, placing it in the public or gated target,
  tokens and htpasswd, the final URL and the publication receipt, and retraction.

So Learning hands over a **rendered artifact**, not a source document plus a
template — otherwise `publish` becomes Learning's renderer and the ownership
line inverts. This is also the smallest possible change: the app already
validates a rendered `html_path` (`learning-manager.py:1587-1601`) and links it
into the public directory itself (`:1652-1713`); only the placement and serving
move.

One consequence for the UI: the current master split — the list means *published*
and the archive means *everything else* — is repo-workflow residue and goes away.
The list is **every markdown file in the folder**; the archive is
`archived: true`; publishing demotes to a per-document share action.

## Package contract

- **Prerequisites:** `python3`, `systemctl`, and *at least one logged-in agent
  CLI*.

  **[v1 was wrong about why the last one is new.]** v1 claimed no packaged app
  supervises an agent CLI as a background worker. It does not survive a full
  sweep of `apps/`: **`paseo` already does exactly that** — a daemon shipped as
  the user unit `airlock-paseo.service` that "spawns provider CLIs as child
  processes", with the unit PATH deliberately wired to where `claude` and
  `codex` land (`apps/paseo/install.sh:2-12`, `:249-258`). `dev-monitor` is a
  weaker second case: it assembles a `claude` argv and runs it in a tmux pane
  (`apps/dev-monitor/backend/action_runner.py:54-82`).

  What is actually new is **declaring** it. `paseo`'s manifest carries eight
  prerequisites — `node`, `npm`, `systemctl`, `tailscale`, `python3`, `curl`,
  `ss`, `sudo` — and **no agent CLI**. Its installer is explicit that the CLI may
  not exist yet ("added whether or not it exists YET", `install.sh:253`), and the
  comment beside it records what happens when the PATH is wrong: paseo "came up
  with a UI and no working providers" (`:257-258`). That is an installer comment
  recording an observed incident, not a code path — paseo's daemon is upstream
  npm, so its degradation behaviour cannot be verified from this repo.

  `learning` has no equivalent degraded mode: without a CLI its central feature
  is dead. So it would be the first app whose manifest states the dependency
  instead of tolerating its absence. A sweep of all nine `apps/*/airlock-app.toml`
  finds no agent CLI declared as a prerequisite anywhere — including
  `dev-monitor`, which actually runs one. That is a smaller and truer claim than
  v1's.
- **Dependencies:** `publish`.
- **Config:** `library_dir`, `listing.provider` (auto), `ingest.provider` (auto),
  `backend_port`. **Not** `public_target`, and **not** `git_post_save` —
  deferred by decision 6.
- **Moves in:** the 2,990 lines above and their 2,736 lines of tests, plus a
  port — not a rewrite — of the existing frontend.

## Resolved here: two questions the settled decisions already answered

**Multiple libraries stay cheap, because the state decision did the hard part.**
With document state in frontmatter and app state in `.learning/`, every library
already carries what describes it. What stays global is enumerable: known library
paths, which was open last, `backend_port`, provider config. A second library is
a registry entry, not a schema change.

One thing must be anticipated now or it gets expensive: **the API should resolve
a library id from config** rather than reading one global path, even while
exactly one exists and the id never appears in a URL. Building multi-library UI
now is not warranted; letting the single-library path assume singularity is what
would cost.

**The wiki lift is a folder copy, and that is the whole feature — by
construction.** No export button in v1. The library is kept vault-compatible on
purpose: plain markdown with YAML frontmatter; folders as the only taxonomy;
nothing app-owned above the dot (`.learning/` is skipped by vault indexers, and
no index file or database sits beside the documents); relative cross-document
links, so a structure-preserving copy keeps them; `video_id` as the stable
identity. An export button remains possible later as a `publish`-shaped feature,
but it buys nothing the copy does not.

## The riskiest assumption

**That the agent process and all its descendants stay inside the process group
the runner owns.** If that is false, a run the UI has reported as cancelled or
failed keeps writing into the library, and it can collide with the next ingest or
a frontmatter edit and overwrite a document. The runner already starts a new
session and signals the whole group, and its own comments warn about surviving
descendants (`ingest_runner.py:202-242`, `:672-675`, `:747-758`) — but the
restart sweep only marks `running` rows failed; it never looks for orphaned
processes (`learning-manager.py:307-319`, `ingest_runner.py:772-776`).

So: before declaring a second provider supported, an integration test that
cancels a real run and restarts the worker, and shows no writer left behind. If
that cannot be guaranteed, put each attempt in its own systemd scope and kill the
scope before reconciling the database.

## Closed, 2026-08-21

All three open questions were answered by the owner as recommended, and one memo
came back with them: *is doing this independently the right call?* — asked of the
publish connection.

**It is, and it is not even independent.** The pattern ships: `notepad` already
declares the dependency and posts to `/publish/api/`. Doing it for `learning`
follows the house pattern rather than starting a private one, and the general
capability stays available later at no extra cost, because promotion is additive.

Nothing in this design is waiting on a decision.

## How this was measured

```
wc -l backend/learning-manager.py backend/ingest_runner.py frontend/index.html
wc -l scripts/* templates/* .claude/skills/*/SKILL.md   # app code in the content repo
wc -l tests/*.py tests/*.sh                             # its tests, same place
grep -n '"push"\|"fetch"\|"pull"\|"clone"\|"remote"' backend/*.py   # zero hits
find business engineering other science -name '*.md' | wc -l         # 167
#   counts are as of 2026-08-21 17:22 and move — the pipeline is live.
#   Do NOT use `find ... -type f | xargs wc -l` for app size: it counts .pyc.
```
