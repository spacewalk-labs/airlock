# Security model

Airlock exposes **owner-only, high-privilege tools**: a web terminal (shell), a
browser IDE (filesystem + terminal), and AI coding-agent runners (arbitrary code
execution by design). The identity gate is **load-bearing** — if it fails open,
a caller gets remote code execution as the box owner.

The rest of the suite sits one tier down, reachable by the configured
**collaborators** as well — including read **and write** access to files. See
[Two tiers, and what a collaborator actually gets](#two-tiers-and-what-a-collaborator-actually-gets)
before you add a collaborator — fileview serves the whole of that account's home to
them, which is where its credentials are.

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
| `$owner_ok` | `owner` only | Every app on its own https port: **devterm**, **code-server**, **orca**, **paseo** — shells, an IDE, and agent runners. Plus every hub-subpath app whose audience is `owner`: **learning**, and **fileview** by default. |
| `$hub_ok` | `owner` **+ `collaborators`** | The hub server, and the subpath apps that **declare** `audience = "shared"` — today **publish**, **notepad**, **dev-monitor**, **feedback**. |

Two things decide reach, and both must say yes. The hub server gate (`$hub_ok`) is
asserted once at the server level, so no app can forget it or opt out of it. Then
each app **declares who it serves** in its manifest's `[audience]`, and an app that
declares `owner` emits its own `$owner_ok` check inside its location — because
being inside the hub server is not by itself a claim about audience.

**Declaring nothing is not the same as declaring `shared`.** A manifest with no
`[audience]` block resolves to `owner`, and `audience` is then not an operator-
settable key at all: the only way to serve collaborators is to say so. This is
deliberately fail-closed — reach used to be an accident of being inside the hub
server, which meant a package could widen its own audience by omission.

- **fileview → the account's whole home, `owner` by default.** filebrowser runs with
  `--root %h` and serves that home read **and write**. There is no root setting: the
  root is systemd's specifier for the running account's home, and `[paths].code_root`
  stays retired (`bin/airlock-config`'s `RETIRED_KEYS` says so and tells you to delete
  the line). **Two boundaries, and both hold.** The outer one is the unix account the
  user service runs as — the kernel draws it, the app cannot express it. The inner one
  is `--root`: nothing above home is addressable, over `..` chains, encoded `..`,
  absolute paths, or symlinks that leave the tree (measured against the pinned binary
  by `install/test-fileview-home-scope.sh`, with a positive control reading a file
  inside home in the same server). Everything the owner's own account can write
  **inside home** is writable here.

  **This changed on 2026-09-04, and the earlier reasoning is kept rather than
  deleted.** fileview served `--root /` deliberately: with no boundary of its own to
  get wrong, the unix account was the whole boundary and could not be misconfigured.
  That is still true of the outer boundary. The operator then chose a hard home scope
  — home visible, above home not visible at all — so the app now carries an inner
  boundary as well, and it is asserted by tests rather than by this paragraph.

  That is why fileview declares `audience = "owner"`: a whole-home read/write surface
  is not something a box hands to a collaborator by inheriting the hub tier, and
  narrowing the root does not change that — `~/.ssh` and every agent credential are
  inside home. Setting `[apps.fileview] audience = "shared"` opens it, and everything
  below is what you are accepting when you do.

  **Nothing is hidden.** No ignore list, no dotfile rule, no exclusion mechanism.
  `.env` lists, opens, edits and saves through exactly the same path as any other
  file — that is deliberate, not an oversight, and `smoke.sh` asserts it on every
  install. The one setting that could break it from outside our code is
  filebrowser's own `hideDotfiles`, so the installer pins it false rather than
  trusting the default.

  (The old note here about markserv's listing omitting dot entries is gone with
  markserv. There is one listing now, and it shows everything.)

  **Pseudo-filesystems are in the tree, and they read as empty.** `/proc`, `/sys` and
  `/dev` list like any other directory — nothing is hidden — and a read of one of
  their files comes back `200` with **zero bytes**: measured on filebrowser 2.63.4
  against `/proc/self/environ`, `/proc/self/cmdline`, `/dev/zero` and `/dev/urandom`,
  each of which reports size 0 and is served as such. So the two things you would
  expect to go wrong here do not: a process's environment is not readable through the
  viewer, and an endless device does not stream into the browser. The viewer caps
  what it reads anyway — it streams and cancels at the limit rather than buffering
  first — so a future version that did serve those bytes would still not be able to
  fill a tab. This is stated because it is surprising in both directions, and it is a
  measurement of a pinned version, not a guarantee about the next one.

  Symlinks are no longer asymmetric, because there is no longer an inside to leave:
  filebrowser is still pinned to a version with `followExternalSymlinks` and the
  installer still passes `--followExternalSymlinks=false`, but with the root at `/`
  every target is already in scope.
- **publish → `[apps.publish].share_dir`** and the upload directory: collaborators
  can list, upload, and remove shared items.

Consequences to plan around:

- **Opening fileview to a collaborator hands them the account.** With
  `[apps.fileview] audience = "shared"` a collaborator reaches `~/.ssh`, `~/.config`
  (including the token `EnvironmentFile`s the installers write), and every agent
  credential under the home directory — with write access, which on a box whose
  owner runs what is in that tree is also an execution path. The `owner` default
  breaks this chain: it takes an explicit `audience = "shared"` to reach it. If that
  is not what you mean, do not open fileview's audience.
- **Scope is the service account's home, and only that.** fileview runs as a
  `systemctl --user` unit with no `User=` of its own, so it runs as the installing
  account and serves that account's home — the kernel draws the outer line, `%h`
  follows the same account, and neither is a setting to get wrong. Measured on one
  box: `~/.ssh/id_ed25519` and `~/.claude/.credentials.json` are readable **and
  writable**; `/etc/passwd` is readable *to the account* but is **not addressable
  through fileview**, and neither is anything else above home. If that reach is wrong
  for a box, the lever is which account installs it — not a path, and not a config
  key.
- **`~/.devterm-secrets` is no longer out of reach.** The secret drop used to be
  described as "deliberately not under `code_root`". That sentence died with
  `code_root`, and the home scope does not revive it: the drop is in home, so the
  viewer reaches it. What protects those files is their mode (`0700`/`0600`) and
  their TTL; placement protects nothing.
- **Disabling an app does not retract it — but the ledger does.** The sentence that
  stood here predates the installed-state ledger. Today `install/airlock-install.sh`
  runs `bin/airlock-ledger plan` on every run, and a committed app whose package
  changed or disappeared is replayed through its recorded deactivator and its
  recorded artifact list. What is still true is the shape of the hazard for anything
  the ledger never committed: the hub includes `hub-locations.d/*.conf` by wildcard,
  systemd units stay enabled, and files already in the hub webroot keep being served
  by `location /`. For those, retraction is manual and has three parts: delete the
  `hub-locations.d/*.conf`, `disable --now` the unit, and delete the directory under
  the webroot. Then re-render.

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
| Lifetime | platform-owned, **1800s (30 min)** from the last write |
| Who deletes it | the platform `airlock-secret sweep` user timer every minute, plus an opportunistic sweep on every CLI operation — independent of whether devterm is installed or running |
| Cap | 64 live secrets, 64 KB per value |
| Who can read the file | the box's own user — same as `~/.ssh` or `~/.aws/credentials` |

Two boundaries worth stating plainly:

- **Its protection is the mode and the TTL, not its location.** The drop lives at
  `~/.devterm-secrets`, which is inside the tree fileview serves read **and write**,
  so moving it does not protect it. This bullet used to say the drop sits outside
  `code_root`; that stopped being true when the viewer stopped having a configurable
  root, and the home scope does not bring it back — home is exactly where the drop
  is.
- **An `export` outlives the file.** Once a value is exported into a shell it lives in
  that shell and every child process, regardless of the TTL. The UI says so at the point
  of the click; the TTL protects the file, not your environment.

To turn it off entirely, keep the value out of the box: don't use the drop. Delete a file
sooner when its one use is complete; the platform timer is the lifetime floor, not a reason
to retain it until the deadline.

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
