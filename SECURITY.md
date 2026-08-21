# Security model

Airlock exposes **owner-only, high-privilege tools**: a web terminal (shell), a
browser IDE (filesystem + terminal), and AI coding-agent runners (arbitrary code
execution by design). The identity gate is **load-bearing** — if it fails open,
a caller gets remote code execution as the box owner.

The rest of the suite sits one tier down, reachable by the configured
**collaborators** as well — including read **and write** access to files. See
[Two tiers, and what a collaborator actually gets](#two-tiers-and-what-a-collaborator-actually-gets)
before you add a collaborator or point `code_root` anywhere wide.

An admitted package's `install.sh` runs arbitrary bash as the operator, including sudo (D4).
A package that is admitted at all can therefore edit config, write system files and bind
ports directly. **This contract is admission control, not containment.** It stops mistakes
and over-reach by honest packages and it leaves an auditable record of what was authorised.
It does not stop a malicious package.

A grant is the operator acknowledging what a package will be allowed to do. It is not a
boundary against an actor who can already write this file.

## Trust model (v1: Tailscale, fail-closed)

Airlock v1 authenticates **only** via Tailscale identity, and derives its safety
from three facts that must ALL hold:

1. **Single ingress.** `tailscale serve` is the only path to the gates. The
   installer verifies this and **refuses to start (fails closed)** if Tailscale
   is not configured as the ingress.
2. **Injected identity.** Tailscale injects the `Tailscale-User-Login` header;
   clients on the tailnet cannot forge it because Tailscale sets it at the proxy.
3. **Loopback backends.** Every gate and backend binds to loopback. Backends that
   must bind `0.0.0.0` (e.g. orca) are additionally firewalled to loopback via nft.
4. **TLS only.** No page, API, or WebSocket is served over plain http. The
   plaintext tailnet ports (`hub.http_port`, `devterm.public_port`) are wired to a
   redirect-only server that answers `301 https://<FQDN>…` and nothing else — the
   FQDN literal, because the short tailnet hostname has no certificate. The
   installer fails closed if the tailnet does not issue TLS certificates, rather
   than leaving a working-but-plaintext fallback: the injected identity header is
   a bearer credential and must not cross the network in the clear. Because
   `tailscale serve --bg` persists until it is explicitly turned off, the
   installer also retires plaintext mappings for ports the config no longer asks
   for — otherwise removing an app would leave its cleartext listener behind.

The gate then checks the identity against the configured `owner` (+ `collaborators`).

## Password-gated public snapshots

A gated snapshot is served at `/g/<slug>/` behind nginx `auth_basic`. That is a
**shared secret for one document**, not an identity: anyone holding the password
is the same anonymous visitor as anyone else holding it, there is no session, and
there is no record of who opened it. It is the right control for "this link needs
a password before it is public", and the wrong one for "only these people".

Three properties hold it up, and each was a real defect before it was one:

- **One password opens one document.** Each slug gets its own credential file and
  the nginx location binds the file to the slug it captured from the URI
  (`auth_basic_user_file <htpasswd_dir>/$gslug.htpasswd`). This matters because
  `auth_basic_user_file` answers *"is this user in this file"* and nothing more —
  it never compares the username to the path. A single shared file would let any
  gated password open every gated document, with the slug-as-username looking
  like a scope while being only a label. `install/test-render.sh` asserts the
  negative case against a running nginx: slug A's credentials on slug B must be
  401.
- **The credential files are readable by the nginx worker** — `0644` in a `0755`
  directory, outside `$HOME`. The worker opens one on every request, so a `0600`
  file under a `0700` home is not a stronger gate, it is a gate that returns 500
  for every request. This does not materially widen local access: the same local
  users can already read the `0755` gated snapshot directory, so the content is
  reachable without the hash.
- **The credential directory may not sit under anything nginx serves**, and
  `gated_dir` may not overlap `public_dir` or `share_dir`. Either overlap turns
  the gate off in a way that leaves the files behind: gated content served through
  the open root with no authentication, or the bcrypt records themselves offered
  for download. The installer refuses these outright rather than warning, because
  disabling the gate does not unpublish what was already published.

Publishing an already-public document as gated deletes the open copy first and
refuses the publish if that delete fails — a stale unauthenticated copy alongside
a password-protected link is the failure this design exists to prevent.

Gated publishing is **local mode only**. The gate is enforced by this box's nginx,
so there is nothing to enforce it with when the target is an ingest service you
host elsewhere; a remote gated publish is refused rather than quietly downgraded
to an open link.

## Two tiers, and what a collaborator actually gets

The renderer emits two identity maps (`install/render-nginx.sh`):

| Tier | Admits | Reaches |
|---|---|---|
| `$owner_ok` | `owner` only | Every app on its own https port: **devterm**, **code-server**, **orca**, **paseo** — shells, an IDE, and agent runners. |
| `$hub_ok` | `owner` **+ `collaborators`** | The hub server and everything included into it from `hub-locations.d/` — today **markwand**, **publish**, **notepad**, **dev-monitor**, **feedback**. |

The rule, not the list, is what holds: **anything the hub server can serve is
collaborator-reachable** — a proxy fragment dropped into `hub-locations.d/`, *and*
any file placed in the hub webroot, which `location /` serves directly (that is how
notepad and the markwand/publish/dev-monitor frontends are delivered, with no
fragment of their own). The gate is asserted once at the server level, so neither
route can forget it — and neither can opt out of it.

**Collaborators are not a read-only tier.** Two file surfaces come with `$hub_ok`:

- **markwand → `[paths].code_root`.** markserv renders it; filebrowser **writes**
  it. Everything under that root is in scope, dotfiles included — the viewer treats
  `.env` as an ordinary editable file. There is **no exclusion mechanism** in
  either upstream: no ignore list, and no rule that keeps a path out of reach.

  One display detail is easy to misread as one. markserv's own directory listing
  omits dot entries, so `.env` is not a link you can click *there*; it is served in
  full on a direct URL, and the split-pane tree — built from filebrowser, not
  markserv — lists it normally. Measured on the pinned versions (markserv 1.17.4,
  filebrowser 2.63.18). Nothing is hidden from reach, only from one of two
  listings; do not treat a missing row as an absent file.

  Symlinks leaving the root are **asymmetric**, so do not reason about them as one
  thing. filebrowser refuses them: it is pinned to a version with
  `followExternalSymlinks`, the installer passes `--followExternalSymlinks=false`,
  and that is also the upstream default — so the *editor* stays inside the root.
  markserv has no equivalent setting and renders whatever a link points at, so the
  *viewer* reads through it. A curated directory of symlinks is therefore a
  convenience, not a boundary: it stops writes, and leaks reads. Since a read of
  `~/.ssh/id_ed25519` is already the whole loss, treat the link target as exposed.
- **publish → `[apps.publish].share_dir`** and the upload directory: collaborators
  can list, upload, and remove shared items.

Consequences to plan around:

- Setting `code_root` to `~` while `collaborators` is non-empty hands them
  `~/.ssh`, `~/.config` (including the token `EnvironmentFile`s the installers
  write), and every agent credential under the home directory — with write access,
  which on a box whose owner runs what is in that tree is also an execution path.
  `validate` warns about this case, but the check is a heuristic: it cannot see
  through a bind mount, so silence is not a clearance.
- Scope is further bounded by the service account's own Unix permissions —
  markwand runs as a user service, so it reaches what that user reaches.
- **Disabling an app does not retract it.** The orchestrator installs only enabled
  apps, but nothing removes what a previous run left behind: the hub includes
  `hub-locations.d/*.conf` by wildcard, systemd units stay enabled, and files
  already in the hub webroot keep being served by `location /`. Removing
  `[apps.markwand]` and later adding a collaborator therefore exposes the *old*
  markwand to them; removing `[apps.notepad]` — which ships no fragment and no unit
  at all, only `notepad/index.html` in the webroot — retracts nothing whatsoever.
  Retracting an app is manual and has three parts: delete its
  `hub-locations.d/*.conf`, `disable --now` its unit, and delete its directory
  under the webroot. Then re-render.

## The secret drop: what lands on disk, and when it goes away

devterm's **secret drop** exists so that a key never has to be typed into a chat prompt
or a shell. You paste the value into a modal; the value is written to a file on the box
and what comes back out is the **path**, not the value:

```
[secret:GH_TOKEN](~/.devterm-secrets/GH_TOKEN.txt)     # for an agent
export GH_TOKEN=$(cat ~/.devterm-secrets/GH_TOKEN.txt) # for a shell
```

A path is safe to repeat into scrollback, terminal history and logs. The value is not.

It is **on by default** when devterm is enabled, so here is exactly what that means:

| | |
|---|---|
| Where | `~/.devterm-secrets/<name>.txt` — the installing user's home |
| Modes | directory `0700`, files `0600`, created that way (never widened afterwards) |
| Lifetime | `[apps.devterm] secret_ttl_sec`, **default 1800s (30 min)** from the last write |
| Who deletes it | a sweep task inside devterm-gate, every `min(60, ttl/4)` seconds — not only when someone opens the UI |
| Cap | 64 live secrets, 64 KB per value |
| Who can read the file | the box's own user — same as `~/.ssh` or `~/.aws/credentials` |

Two boundaries worth stating plainly:

- **It is deliberately not under `[paths].code_root`.** markwand serves that tree read
  **and write** to the owner *and* every collaborator, so a secret written there would be
  readable through a file viewer. `~/.devterm-secrets` is outside it.
- **An `export` outlives the file.** Once a value is exported into a shell it lives in
  that shell and every child process, regardless of the TTL. The UI says so at the point
  of the click; the TTL protects the file, not your environment.

To turn it off entirely, keep the value out of the box: don't use the drop. If you want a
shorter blast radius, lower `secret_ttl_sec`; the sweep interval follows it.

## The message & action console: who can post, who can run

dev-monitor's console (`[apps.dev-monitor] messages = true`, **off by default**) does two
different things, and they have different trust levels. Anything that can write the spool
can **post a card**. Only the owner, clicking in the console, can **run one**.

| | |
|---|---|
| Who can post | the installing user and the configured system spool-writer identity. The latter can write only `tmp/`/`new/`, cannot enter collector-only lanes, and has external egress blocked by nftables; there is no network intake |
| Who can read the console | the owner only. Not collaborators — this is the one dev-monitor surface that is owner-scoped |
| Who can run an action | the owner, per card, per click. There is no auto-run and no "approve all" |
| Where state lives | `~/.local/state/airlock/dev-monitor/`: execute-only traversal for the writer group, setgid+sticky `spool/tmp` and `spool/new`, and collector-only database/processing/bad state |

Three boundaries hold that up:

- **The owner routes are authenticated twice.** `/monitor/api/owner/` requires both the
  ingress-injected identity (the owner, and only the owner) *and* a proxy secret that only
  nginx knows, so reaching the loopback port directly is not enough. The secret is minted
  fresh on every install and lives in two `0600` files — the unit's env file and the nginx
  fragment. On every other `/monitor/api/` route nginx blanks both headers, so a browser
  cannot smuggle its own copy in.
- **Almost nothing here is readable cross-origin.** Because identity is injected by the
  ingress rather than carried in a cookie, any origin the API echoes back can read owner
  data with the owner's own authority. Exactly one route opts in — the unread-badge preview
  the return widget polls from the tools that run on their own ports — and it is echoed only
  for this box's own hostnames, compared whole. A name that merely *starts* with the box's
  name (`<box>.somewhere-else.example`) is not this box.
- **Approval is pinned to a plan, not to a card.** Approving derives a canonical plan
  (real path of the working directory, the skill or prompt, the reason) and hashes it. If
  the card changes between approval and execution the hash disagrees and the run is
  refused — a card cannot be edited into something else after you approve it.
- **Where a run may run is bounded.** `exec_cwd_root` (default `$HOME`) must strictly
  contain the working directory; the root itself is refused, and so is anything outside it.
  The runner re-checks it after `chdir`, by realpath, so a symlink swapped in after approval
  does not move the run.

There is no allow-list of skills, and the one that used to be here was removed rather than
documented better (owner, 2026-08-10). `skill_allow` filtered the `skill` field of an action
and only that field: the same card sent as a `prompt` naming the same skill ran anyway, so
the list bounded nothing an author could not step around by changing which field they used.
A control that reads as a lock and is not one is worse than no control, because it is the
one people stop looking past. If you set that key on an older install, `airlock-config` now
names it and tells you this.

The control that actually bounds what runs is the one at the top of this section: an action
runs because the owner read the derived plan and clicked, and it runs that plan or nothing.

Configured only partially, the console does not come up: `devmon_owner` refuses a
half-set gate, dev-monitor logs why and keeps serving observability with the owner routes
returning 404. There is no state in which some of the checks are on and the rest are off.

If you do not want a local process to be able to raise cards on your box at all, leave
`messages = false`: no spool or database is created, the console never starts, and the
nginx owner route is never written at all.

## What is NOT sufficient (why header name alone is unsafe)

Checking only the **value** of an identity header is **not** authentication. If a
reverse proxy that forwards a client-controlled `Tailscale-User-Login` header can
reach a loopback gate, it obtains owner access. Therefore:

- **A reverse proxy in front of Airlock MUST NOT forward client-supplied identity
  headers.** It must strip and re-inject them from a trusted source.
- **Do not** deploy v1 without Tailscale by "just changing the header name in
  config" — that produces an insecure-by-default deployment. v1 does not accept an
  arbitrary header name as a valid provider.

## Roadmap (later updates)

- `auth.provider = "trusted-proxy"` with a trusted-proxy CIDR allowlist and
  header re-injection, and `oauth2-proxy` integration, each fail-closed and tested
  against forged-header requests.


## Package trust (D4)

Airlock does not sandbox apps. An app package's lifecycle scripts run
arbitrary bash as the operator, including sudo. What bounds that is
explicitness, not isolation:

- **Explicit packages** — every third-party package is one operator-written
  `[packages.X] path` line; there is no discovery, no store, no implicit
  tap. Writing that line is trusting that code, exactly as adding a Homebrew
  tap or installing a krew plugin is. Airlock never executes an explicit
  package's scripts on a dry run.
- **Shipped packages** — the nine apps in this repository resolve
  implicitly from `apps/<id>` and are first-party code, reviewed here. A dry
  run may execute a *migrated* shipped app's lifecycle scripts — those that
  certify full `AIRLOCK_DRY_RUN` discipline as part of their migration;
  never an explicit package's. Shipped entitlements are immutable repository
  policy; an explicit package instead needs an operator grant for root-owned
  artifacts or system units. Their removal remains confined to the recorded
  capability claim and the execution-time rooted allowlist.
- The installed-state ledger records what every package **declares and the
  install expands** — not a byte-level provenance trail — and is the only
  thing that deletes it; removal never follows a path the record does not
  name, and operator data is never declared removable. The corollary cuts
  both ways: a file you place by hand inside a directory a record claims
  (say, under an app's webroot tree) is removed with that tree when the app
  is torn down. Keep manual files out of recorded artifact directories.

## Reporting

**Preferred — report privately through GitHub:**
[Report a vulnerability](https://github.com/spacewalk-labs/airlock/security/advisories/new)
(the button on this repository's Security tab). Private vulnerability reporting
is enabled here, so the report is visible only to the maintainers and arrives in
the place they already watch.

**Without a GitHub account:** <cho@spacewalk.tech>. Say it is a security report
in the subject. Do not open a public issue with the details in it.

What helps, in rough order: the version or commit, which gate or app is
involved, what an attacker gets, and the smallest reproduction you have. A
report without a reproduction is still worth sending.

There is no timeline commitment here on purpose. This is a small project; a
contact that exists and is read beats a disclosure policy that promises a
response window nobody is staffed to meet.
