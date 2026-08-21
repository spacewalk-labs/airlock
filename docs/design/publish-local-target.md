# publish — local public target (design v2)

> Status: **plan, revised after adversarial review.** Adds a second backend for
> the existing pluggable external-publish target so a single-box Airlock can
> publish to its own domain, with a real TTL and a real expiry sweep, without
> hosting a second ingest service.
>
> v1 was reviewed and rejected (5 blockers, 10 majors). What changed in v2 is
> listed in §11 so the reasoning is auditable.

## 1. What is actually broken today

`apps/publish` ships the **sending half** of external publishing and nothing
else. Verified against `77b8708`:

1. **The published snapshot is never written anywhere by Airlock.**
   `publish_public()` (`backend/airlock-publish.py:339`) bundles a self-contained
   file and POSTs it to `AIRLOCK_PUBLISH_INGEST_URL`. With no target configured,
   `PUBLIC_ENABLED` is false (line 50) and every external endpoint answers
   `external publish not configured`. **No `/ingest` receiver ships with this
   repo** — the operator must build one.

   *Correction to v1:* the UI is not "dead controls" — it hides them
   (`frontend/publish.html:403-431`, `486-508`). The accurate statement is that
   external publishing, TTL, expiry and revoke are **unavailable** on a stock
   install, not that they are shown and broken.

2. **The documented workaround publishes the tailnet-internal share.** Because
   there is no receiver, a deployment guide written against v1 (kept outside this
   repo) tells the operator to serve `share_dir` itself on the public domain:

   ```nginx
   root /opt/airlock/share;               # = [apps.publish] share_dir in airlock.toml
   ```

   That is the same directory nginx serves at `/publish/files/` behind the hub
   identity gate (`apps/publish/install.sh:118-132`), full of symlinks the owner
   added for private viewing — and nginx follows symlinks by default. The same
   guide tells readers snapshots will appear there as `<slug>/`, which per
   defect 1 never happens.

   *(This could not be adjudicated from the Airlock repo alone — the evidence is
   the guide, quoted above.)*

So the gap is not "30-day TTL is missing". **The TTL selector exists
(`frontend/publish.html:296-301`, 24h/7d/14d/30d); the thing that would honour
it does not.** Fix the receiving half and the existing UI comes alive.

## 2. Decision

Turn the pluggable target into a **two-backend** abstraction in the same process:

| target | when | how it stores | who serves the slug |
|---|---|---|---|
| `remote` (today) | `mode = "remote"` (or omitted with `ingest_url` set) | HTTP POST to the operator's ingest | operator's service |
| `local` (new) | `mode = "local"` | writes `<public_dir>/<slug>/index.html` + a state file | the box's own nginx |

Rejected alternatives:

| rejected | why |
|---|---|
| Ship a standalone ingest **HTTP service** in Airlock | Same box, same process, same user — an HTTP hop plus a shared secret buys nothing but a new auth surface to get wrong. |
| Keep serving `share_dir` and add a TTL sweeper over it | Cannot distinguish "snapshot with a TTL" from "symlink the owner published internally"; the sweeper would delete the owner's internal shares, and the leak in §1.2 stays. |
| Do nothing; document expiry as manual | Leaves the leak, and leaves the whole external-publish surface unusable on the path the deployment guide actually teaches. |
| Do it in nginx (`expires`, map files) | nginx cannot delete content; expiry needs a process. |
| **Infer the mode from which keys are present** (v1) | Not back-compatible — see below. |

### 2.1 An explicit `mode`, because inference is not back-compatible

v1 said "infer: `ingest_url` → remote, else `base_url` → local". Review found two
existing config shapes that change behaviour under that rule. Both are
**partially-configured remote** installs that are inert today
(`backend/airlock-publish.py:44-50` requires all three of ingest_url + base_url +
token):

| existing config | today | under v1 inference | under v2 |
|---|---|---|---|
| `base_url` only (token/ingest removed or never added) | disabled | **silently becomes a live public publisher** | disabled + startup warning |
| `ingest_url` only (token missing) | disabled | remote, still disabled | disabled + startup warning |
| all three | remote, enabled | remote | remote |

So: **`mode` is explicit.** `mode = "local"` is the only way to turn local on.
`mode` omitted keeps exactly today's rule (`ingest_url && base_url && token`).
An incomplete config logs one line at startup naming the missing key instead of
failing silently.

## 3. Configuration

```toml
[apps.publish]
backend_port = 18803
share_dir    = "/opt/airlock/share"           # unchanged, tailnet-internal

[apps.publish.public_target]
mode       = "local"                          # "local" | "remote" (default: remote)
base_url   = "https://doc.example.com"        # public URLs are <base_url>/<slug>/
# public_dir = "/opt/airlock/share-public"    # default; nginx serves THIS, not share_dir
```

`ingest_url` + `token_env` keep working exactly as today (remote mode).
`gated_dir` is **not** part of this change — see §10.

New env passed to the unit **and to the cleanup unit** (they must agree):
`AIRLOCK_PUBLISH_PUBLIC_MODE`, `AIRLOCK_PUBLISH_PUBLIC_DIR`,
`AIRLOCK_PUBLISH_STATE_DIR`.

**Startup refusals** (local mode only; each logs and disables public publishing
rather than crashing the whole manager):

- `public_dir` unset or resolving (`realpath`) to `share_dir`, or to a parent or
  child of it → refuse. This is the guard against re-creating §1.2.
- `base_url` unset → refuse.
- `public_dir` not writable by the service user → refuse.

## 4. Local store layout

```
/opt/airlock/share-public/<slug>/index.html      # the snapshot, world-readable
~/.local/state/airlock/publish-public.json       # metadata — OUTSIDE any web root
~/.local/state/airlock/publish-public.lock       # flock target (see §5.3)
```

The state file is deliberately **not** in the served directory: it holds owner
identities and source filenames, and nginx serves dotfiles by default.

```json
{"version": 1, "items": {
  "my-doc-a1b2c3": {"owner": "me@example.com", "src": "my-doc.html",
                    "title": "My doc", "expiry": 1790000000,
                    "created": 1789000000, "bytes": 84213}}}
```

`expiry` is a unix timestamp — the shape the frontend already renders
(`new Date(it.expiry * 1000)`).

### Permissions (spelled out, because the installer must create them)

| path | owner | mode | why |
|---|---|---|---|
| `/opt/airlock/share-public` | the install user | `0755` | the `systemd --user` backend writes it; the nginx worker only reads |
| `<slug>/` and `index.html` | the install user | `0755` / `0644` | written with an explicit `os.chmod` — the service umask is not assumed |
| `~/.local/state/airlock` | the install user | `0700` | contains owner identities |

`/opt` is unconfined under Ubuntu 24.04's default AppArmor profile for nginx, so
serving from there needs no policy change; the deployment guide keeps the
`nginx -t` + reload step that would surface it if a box differs.

## 5. Operations

The four the protocol already defines, plus the reconciliation the review
demanded.

### 5.1 ingest

1. Validate: slug matches `^[a-z0-9][a-z0-9-]{2,63}$`; **owner is non-empty**
   (§5.4); snapshot ≤ `LOCAL_MAX_BYTES` (25 MB) — this cap is **local-only**, the
   remote path keeps today's unlimited behaviour (finding 13).
2. Under the lock: if the slug exists in state with a **different owner**, do not
   write — mint a fresh slug and use that (finding 9). Same for a slug directory
   that exists on disk but not in state.
3. **State first, then content** (finding 10): write the state entry, fsync,
   then write `index.html` to a temp file in the same directory and `os.replace`
   it into place. A crash between the two leaves a state entry with no page,
   which the next reconcile drops (§5.5) — so the failure mode is "the publish
   didn't happen", with nothing public left behind. The reverse order would leave
   **untracked public content**, which is the unsafe direction.
4. Return `{expiry, ttl_hours}`.

Re-publishing the same `(owner, src)` reuses the slug — that logic already lives
in `publish_public()` and stays target-agnostic.

### 5.2 list / revoke / set-expiry

- **list** — this owner's entries, `expired` computed from `now`.
- **revoke** — delete the slug directory immediately, drop the entry.
- **set-expiry** — `expiry = now + ttl_hours*3600`.

Deletion rules: the path must be a direct child of `public_dir` after `realpath`;
the slug directory must not itself be a symlink; only `index.html` and the
directory are removed, never a recursive wipe of arbitrary content.

### 5.3 Locking across processes

A `threading.Lock` is not enough: the cleanup timer is a **separate oneshot
process** (`install.sh:78-85`), so publish and sweep can interleave a
read-modify-write and lose one side (finding 7). Every state mutation takes an
**`fcntl.flock` on `publish-public.lock`**, held across read → modify →
`os.replace`. The in-process lock stays as the cheap inner guard.

### 5.4 Owner identity

`self._owner()` returns `''` when the identity header is absent
(`backend/airlock-publish.py:544`), and today's `public_list('')` drops the owner
filter entirely (line 377). Under a local target that would merge every
headerless caller into one bucket (finding 4, blocker).

**Local mode refuses an empty owner** on all four operations with
`identity header missing — the hub gate is not in front of this request`. The
hub always sets it; an empty owner means the request bypassed the gate, which is
exactly when we should not be publishing.

### 5.5 Corrupt or missing state — fail safe, then reconcile

v1 said "start from empty and log". Review (finding 6, blocker) showed that
orphans public content forever: nginx keeps serving it while revoke and sweep
both refuse to touch anything not in state.

v2:

1. Unreadable/invalid JSON → move it aside to `publish-public.json.corrupt-<n>`,
   log loudly, and continue with an empty state.
2. **Reconcile on every load**: scan `public_dir` for `<slug>/` directories not
   present in state and adopt them as
   `{owner: null, src: null, expiry: now + RECONCILE_GRACE (24h)}`.
   Adopted entries are listed to no one but **are** swept — so orphaned content
   disappears within a day instead of never.
3. State entries whose directory is gone are dropped on the same pass.

This makes "content on disk" and "state" converge from either direction.

### 5.6 Expiry actually removes content

Two triggers: the existing hourly `--cleanup` timer (which now also sweeps public
snapshots and therefore needs the same env as the service — finding 11), and a
lazy sweep at the top of every local `list`/`ingest`. Worst case an expired page
is reachable for up to an hour; minimum TTL is 24h, so the docs say "within an
hour" and mean it.

## 6. Safety rules (each becomes a test)

| risk | rule |
|---|---|
| `rm -rf` via a crafted slug | slug regex + `realpath` direct-child check + refuse symlinked slug dirs |
| ~~publishing a file outside the share dir~~ | **Review finding 5 rejected.** It proposed realpath containment on the main document because `bundle_single_file()` follows the symlink at `:284` while `safe_resolve()` is lexical (`:114-123`). But a symlink in the share dir pointing at a file elsewhere **is the documented way to publish** (`README.md:6-11`: "Symlink or drop files here"), `list_items()` renders those targets, and `unpublish()` exists precisely to unlink them. The backend runs as the same user that made the symlink, so no privilege boundary is crossed — containment here would break the primary workflow, not close a hole. Asset refs keep their containment (`:252-265`), where the path comes from page content rather than a deliberate owner action. |
| cross-owner read/write | exact owner match on list/revoke/set-expiry; ingest mints a new slug rather than overwriting a foreign one |
| empty owner | refused in local mode (§5.4) |
| disk fill | 25 MB cap, local path only |
| half-written page served | temp file + `os.replace`, state written first |
| lost update between service and timer | `flock` (§5.3) |
| corrupt state orphaning public content | fail-safe + reconcile (§5.5) |
| internal share leaking | installer and backend both refuse `public_dir` overlapping `share_dir` (§3) |

## 7. Frontend

Nothing is needed for TTL — the selector, expiry chips and "Change expiry"
already call these endpoints. Only: `/api/list` and `/api/health` gain
`public_mode` (`local`/`remote`) so the UI can label the destination.

## 8. Migration for anyone who followed the old workaround

Someone who followed the v1 deployment guide (§1.2) is publicly serving
`share_dir` right now. The upgrade must not leave them worse off, and must not
silently keep the leak.

1. Installer: if local mode is configured and `public_dir` overlaps `share_dir`,
   **refuse and print the exact fix** rather than starting.
2. The guide gains an "already serving `share_dir`?" step: repoint the nginx
   `root` to `share-public`, reload, and verify that a file that only exists in
   `share_dir` now returns 404 on the public domain.
3. That 404 check joins the guide's verification list, so closing the leak is
   *measured*, not assumed.

## 9. Verification plan

Review found §9 (v1) insufficient (finding 15). Every row below must pass.

| # | check | how |
|---|---|---|
| 1 | happy path publish → list → set-expiry → revoke | backend on temp dirs, over loopback |
| 2 | slug abuse: `../x`, `.`, `a/b`, 200 chars, symlinked slug dir | each refused, directory untouched |
| 3 | symlinked source still publishes | `share/x.html -> ~/repo/x.html` must publish normally (guards against wrongly adopting finding 5) |
| 4 | empty owner | all four ops refused in local mode |
| 5 | owner collision on ingest | second owner gets a different slug; first file untouched |
| 6 | crash between state and content | simulate; the entry is reconciled away and nothing public remains |
| 7 | concurrent publish + `--cleanup` | run both in a loop; no lost update (state item count is conserved) |
| 8 | corrupt state | truncated JSON → moved aside, orphan dirs adopted and swept |
| 9 | real permissions | `/opt` dir created by installer, backend writes, `www-data` reads |
| 10 | timer env | cleanup unit sweeps the *same* public dir the service writes |
| 11 | **expiry → real 404** | backdate an entry, run the timer, `curl` the public URL |
| 12 | remote-mode regression across **all four config shapes** (§2.1) | mode, health JSON, UI flag and error text unchanged vs `main` |
| 13 | remote-mode functional regression | stub ingest server; publish/list/revoke byte-compatible payloads |
| 14 | no size regression for remote | a >25 MB snapshot still publishes remotely |
| 15 | `apps/publish/smoke.sh` | extended with a local round trip when local mode is configured |
| 16 | leak-guard | `airlock-publish-sync` gate before anything reaches the public mirror |

## 10. The password gate: cut from v2, built afterwards

v1 folded an optional `gated_dir` into this change and review cut it — a second
webroot, a second base URL, a UI branch and a shared slug namespace, all for
something a plain nginx `auth_basic` recipe already covered by hand. The cut
named a specific precondition for ever building it: *"if the app ever grows a
gate, it gets its own design with the public↔gated transition specified."*

**It has since been built.** This section records what was built and why, so the
"Cut" above is not read as current.

### What ships

`auth_basic`, with **one credential file per slug**:

```nginx
location ~ "^/g/(?<gslug>[a-z0-9][a-z0-9-]{2,63})(?<gpath>/.*)?$" {
    auth_basic "Restricted document";
    auth_basic_user_file <htpasswd_dir>/$gslug.htpasswd;
    alias <gated_dir>/$gslug$gpath;
}
```

Three properties are load-bearing, and each of them was a shipped defect first:

- **Per-slug credential files.** `auth_basic_user_file` answers "is this user in
  this file", *not* "may this user have this URI". A single shared file therefore
  let any gated password open any gated document — the username was a label, not a
  scope. Binding the file path to the captured slug is what makes the password
  document-specific. `install/test-render.sh` proves it against a running nginx:
  slug A's credentials against slug B must be 401.
- **The credential directory is readable by the nginx worker** (`0755`/`0644`,
  outside `$HOME`). The worker opens that file on every request, so a `0600` file
  under a `0700` home is not "more secure", it is a gate that returns 500 for
  every request. This does not widen local access in practice: the same local
  users can already read the `0755` gated snapshot directory.
- **The directories may not overlap.** `gated_dir` inside `public_dir` serves
  gated content through the open root with no authentication, and `htpasswd_dir`
  under any served root publishes the bcrypt records themselves. The installer
  refuses both rather than warning, because disabling the gate does not remove
  files that were already published.

### The public↔gated transition

This was finding 8's objection and it is the reason the transition is specified
here rather than left to the implementation. Publishing an already-public
document as gated **deletes the open copy first, and refuses the publish if that
delete fails.** The failure mode being avoided is the one that made the original
cut correct: a stale unauthenticated copy still being served while the UI shows a
password-protected link.

### What is deliberately not built

An identity-aware gate — a login page, sessions, per-viewer access. That needs a
service that is always running and a session store, which is the thing v1's review
refused, and nothing here changes that judgement. `auth_basic` is a shared secret
for one document, and the README says so.

**Remote mode does not get this.** The gate is enforced by *this box's* nginx, so
there is nothing to enforce it with when the target is someone else's ingest
service. A remote gated publish is refused outright rather than silently
downgraded to an open link — handing back an unprotected URL to someone who asked
for a password is worse than an error.

## 11. What changed from v1 (audit trail)

| v1 | v2 | driver |
|---|---|---|
| "dead UI" | UI hides the controls; feature simply unavailable | finding 1 |
| defect 2 asserted without a quote | quoted the deployment guide's own nginx block | finding 2 |
| mode inferred | explicit `mode`, with the four config shapes tabulated | finding 3 |
| owner match unspecified for empty | empty owner refused | finding 4 |
| — | **rejected** — containment would break symlink publishing, the documented workflow | finding 5 |
| corrupt state → empty | fail-safe + reconcile orphans with a grace TTL | finding 6 |
| `threading.Lock` | `flock` across processes | finding 7 |
| gated_dir optional feature | cut from v2; built afterwards under §10's stated precondition | findings 8, 12 |
| ingest overwrite unspecified | foreign slug → mint a new one | finding 9 |
| content/state ordering unspecified | state first, then content | finding 10 |
| paths listed only | ownership/mode table + cleanup unit env | finding 11 |
| 25 MB cap in `publish_public` | local path only | finding 13 |
| "diff the remote branch" | all four config shapes tested | finding 14 |
| 6 checks | 16 checks incl. real timer→404 | finding 15 |
| migration unmentioned | installer refusal + a migration step in the guide | gemini-slot review gap |
