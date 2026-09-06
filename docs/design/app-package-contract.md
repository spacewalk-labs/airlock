# App package contract

> Status: **accepted 2026-08-01; delivered.** This document is the contract itself —
> the decisions (D1–D8) and the fixture specifications (F1–F15) the implementation
> must satisfy. Delivery was staged in four children (#47, #48, #49, #50); all four
> landed and the master task was retired with them (#51), so this is now a record of
> what was built rather than a plan for building it. Code citations were
> verified at `da5c4ee`. Revised once after independent general + adversarial
> review; the material additions were the artifact-declaration ABI, the install
> journal, the digest definition, the removal priority order, and fixtures
> F14–F15. One D6 sentence was clarified during child 2 planning: record-state
> exclusivity is per record, and an upgrade's old committed record coexists
> with the new intent until commit — the record-diff rule below already
> required that; the old wording contradicted it.

Airlock becomes an OS that apps are installed *onto*, not a repository that apps
live *inside*. One packaging contract covers every app source: the in-tree apps
this repo ships, apps maintained in separate repos, and apps a single operator adds
to their own box. An app package staged at an arbitrary local path installs, gates,
smokes, appears on the hub, and deactivates cleanly — with zero edits to installer
code, and with the same fail-closed config validation in-tree apps get today.

## 1. Why

Today the app set is enumerated by hand in ~8 central files, and three couplings
make an out-of-tree app impossible:

1. **Installer path**: `install/airlock-install.sh:90` resolves installers only as
   `$ROOT/apps/$app/install.sh`; a missing installer is *skipped with a log line*,
   not failed (`:95`). The smoke loop (`:154-163`) and `bin/airlock-smoke:20-27`
   hardcode the same shape.
2. **Prerequisite registry**: `install/preflight.sh:100-104,157-161` accepts
   prerequisite declarations (`install/prerequisites.tsv`) only for in-tree owners
   and aborts otherwise.
3. **Schema registry**: `bin/airlock-config:49-83` `APP_DEFAULTS` doubles as the
   defaults table *and* the "known app" registry — an out-of-tree app is a
   permanent warning (`:210-212`) whose schema is never checked (`:268-270`), so
   it gets no key-typo protection.

Beyond the couplings, every one of the eighteen built-in install/smoke scripts
computes the platform root as `$HERE/../..` and finds its own files via
`$ROOT/apps/<id>/…` (e.g. `apps/publish/install.sh:15-18,31`,
`apps/dev-monitor/install.sh:44`, `apps/code-server/install.sh:16-17`) — moving
the orchestrator loop is not enough; the scripts' root assumption moves too (D5).

The config layer is already ~70% open: an unknown `[apps.<name>]` table passes
validation with a warning, reserves ports in the global uniqueness check
(`bin/airlock-config:361-383`), gets env export, and renders a generic hub tile
(`hub/index.html:216-228`). The nginx fragment drop-dirs (`hub-locations.d/`,
`servers.d/`), the `gate/nginx-lib.sh` emitters, `install/lib.sh`, and the smoke
loop are convention-driven and carry over unchanged.

Known gaps this contract closes rather than inherits:

- Disabling an app does not retract its units, fragments, or serve mappings
  (SECURITY.md:130-139). Stale plaintext serves are reclaimed from
  `APP_DEFAULTS`-listed defaults *plus currently configured values*
  (`bin/airlock-config:414-430`) — so a **removed** app's custom port is
  forgotten. Closed by D6 from the ledger's introduction onward. For boxes that
  removed an app *before* the ledger existed, the F15 sweep recovers what the
  built-in manifests can name — files, units, fragments — but a custom serve
  port whose value survives nowhere is genuinely unrecoverable; the existing
  defaults-based reclaim stays as the backstop for those.
- The schema registry is already incomplete for a shipping app: `feedback` reads
  `mail_to` / `mail_from` / `mail_api` / `mail_key_env`
  (`apps/feedback/install.sh:38-42`, advertised in `airlock.toml.example:127-140`)
  but `APP_DEFAULTS` doesn't list them (`bin/airlock-config:72-73`), so the
  closed-vocabulary check rejects documented keys. Closed by the manifest
  migration: the keys become declared schema. (Amended in child 4: F12
  alone does not prevent recurrence — it is an advisory lint, and a package
  can suppress a failed read — but an unknown key in `[apps.X]` stays fatal
  against the manifest schema, which is the enforced half of the closure.)

Prior art surveyed: YunoHost (per-app manifest, core writes the ingress), Homebrew
(a decade of implicit tap trust, then Tap Trust in 6.0 after real incidents), Home
Assistant add-ons (declare a port, platform writes ingress) and HACS (out-of-band
store friction), Umbrel/CasaOS (community stores; CasaOS store outages traced to
its live catalog API), krew (unaudited-code warning on every install; store by
sha256, no version pinning), Cockpit (search-path discovery), Nix flakes (explicit
inputs + lockfile). The decisions cite the specific lessons.

## 2. Decisions

### D1 — Packages are local paths; Airlock is not a package manager

```toml
[packages.my-app]
path = "./packages/my-app"    # relative to airlock.toml; canonicalized (symlinks resolved)

[apps.my-app]
backend_port = 18900
```

Omitting `[packages.X]` means the built-in `$ROOT/apps/X`. Only an explicit
`[packages.X]` may shadow a built-in; `hub` is reserved core and cannot be
shadowed. The package path may point anywhere on the local filesystem — `..` and
absolute paths are allowed. A relative path resolves against the directory of the
**resolved** `airlock.toml` (config-file symlinks are resolved first, so a
symlinked config and its target agree on the base). The canonical resolved
package path — symlinks resolved — is what gets validated, logged, and recorded.
Containment applies to *staged assets*, not the package location: anything the
platform copies out of the package (e.g. a tile icon into the webroot) must
resolve inside the canonical package root.

Packaged app ids match `^[a-z0-9][a-z0-9-]{0,31}$`. This is deliberately
stricter than today's app-name grammar (`bin/airlock-config:45` allows case,
`.`, `_`): env export flattens `-` and `_` to the same character
(`bin/airlock-config:452`), so `a-b` and `a_b` would collide; the tighter
grammar removes that class along with case/length ambiguity. All ten built-in
ids already conform; the legacy fallback keeps the old grammar until it retires.
Two ids are reserved and cannot be packaged: `hub` (the platform entry point) and —
amended in child 3 — `core`, the prerequisites pseudo-owner (F11): a package
named core could masquerade as the immutable platform rows.

We deliberately reject `source = "git+…"` (a runtime installer would inherit
auth, mutable refs, caching, and rollback — that belongs to whatever stages the
path) and `apps.d/` auto-discovery as the public rule (implicit priority +
broken-symlink ambiguity; every package must be an explicit, operator-written
line — the lesson of Homebrew's decade of implicit tap trust). `path` is the
only key `[packages.X]` accepts; anything else is a validation error, which is
what keeps the git-source rejection enforced rather than aspirational. Package
id, manifest id, `[apps.X]`, and `[packages.X]` must agree exactly.

Shadowing substitutes an id, not a capability: dependencies are id-level (D3),
so an operator who shadows `publish` with a package lacking the upload API their
`notepad` calls (`apps/notepad/frontend/notepad.html:247,298`) owns that
breakage — it is the same trust grant as D4, and smoke is where it surfaces.

**Amended in child 4 — the shipped-package class.** With the built-ins
migrated, "omitting `[packages.X]` means the built-in" becomes a named class:
a **shipped package** is an app dir under `$ROOT/apps/<id>` containing a
manifest, resolved implicitly for any configured `[apps.<id>]`; an explicit
`[packages.<id>]` still shadows it. The resolution carries
`source_class ∈ {shipped, explicit}` through `package-info` into every
consumer — trust is a property of the source and must be visible, not
inferred (dry-run execution and the `rooted` artifact class key on it, and
OQ2's possible non-built-in hub labelling would too — OQ2 itself stays
open). Operators add no lines for shipped
apps; every existing `airlock.toml` keeps working across the flip.

### D2 — One manifest per app, static and local

`airlock-app.toml` at the package root, read only by `bin/airlock-config`
(preserving the single-TOML-reader rule, `bin/airlock-config:1-14`):

```toml
contract = 1
id = "my-app"

[dependencies]
apps = ["publish"]            # same-box app ids; id-level, not capability-level (D3)

[config]
[[config.required]]            # keys the operator must set; explicit type, since
name = "api_token"             # there is no default value to infer it from
type = "string"                # one of: string | integer | boolean
[config.defaults]
backend_port = 18900           # value doubles as the type declaration
https_port = 19990
compat_https = 8443
compat_enabled = false
                               # (a key may not be both required and defaulted)
[config.tables.public_target]
allowed_keys = ["mode", "base_url"]
[[config.port_spans]]          # only for apps that bind a derived range:
base = "backend_port"          # ports base..base+count-1 all enter the global
count = "slots"                # uniqueness check, not just the declared scalar
runtime_env = [                # env-var names your installer WRITES, not config:
  "AIRLOCK_MY_APP_STATE_DIR",  # Environment= lines, secret names, test seams.
]                              # No values, not merged, never exported.

[[prerequisites]]              # replaces this app's rows in prerequisites.tsv;
command = "python3"            # an app with no prerequisites declares none —
predicate = "major-gte"        # the manifest itself is the declaration the
expected = "3.11"              # TSV-era "enabled app must have a row" rule
fix = "sudo apt-get install -y python3"   # (install/preflight.sh:157-161) was
note = "Application runtime"   # approximating; that rule retires with the TSV

[artifacts]                    # D6 — everything the app's scripts create outside
units = ["airlock-my-app.service"]        # the package dir and its data. Unit
                                          #   names are LITERAL (amended in
                                          #   child 4 — see D2); the other
                                          #   classes take globs
fragments = ["hub-locations.d/my-app.conf"]  # relative to $CONFD
webroot = ["my-app/"]                     # relative to the webroot
files = ["~/.local/bin/my-app"]           # any other managed path (absolute or
                                          #   ~-relative) — binaries, config the
                                          #   installer writes outside the classes
                                          #   above; app *data* is deliberately
                                          #   not declared and never torn down
serve_ports = ["https_port", "compat_https"] # config keys whose port values the
                                          #   platform maps via `tailscale serve`
                                          #   and reclaims on removal (the
                                          #   plaintext_known mechanism)

[serve.https]
https_port = "backend_port"               # legacy always-on listener → target
compat_https = { target = "backend_port", enabled = "compat_enabled" }
                                          # optional listener; enabled must name
                                          # a boolean [config.defaults] key.
                                          # false omits render and ledger claim.

[tile]                         # replaces this app's entry in hub/index.html APPS;
label = "My App"               # omit the whole table for a no-tile app (as
sub = "one line"               # feedback is today, hub/index.html:211)
cat = "docs"                   # one of: coding | docs | files | system | comms
                               # (the hub's colour palette, hub/index.html:81-85)
path = "/my-app/"              # subpath apps only; public-port apps omit it
icon = "assets/icon.svg"       # image staged from the package (containment-checked),
                               # rendered like today's `brand`; XOR with:
# glyph = "app-notepad"        # a built-in symbol id (hub/index.html:243-244)

[audience]                     # D7 — who this app can serve
supported = ["shared", "owner"]
default = "shared"
```

The manifest schema expresses everything the validator enforces today, not just
key names: per-key TOML type (declared by the default's own type; `required`
keys carry an explicit `type`), the platform-common keys every app table accepts
(`external` — `bin/airlock-config:85-86,271`; `audience` joins it, D7), the
scalar-vs-table conflict rule (`:268-289`, regression-tested at
`install/test-config.sh:272-281`), and unknown manifest fields being themselves
a validation error — fail-closed applies to the manifest too. The `[tile]`
fields are the hub's real tile model (`hub/index.html:185-194`: `label`, `sub`,
`glyph` xor `brand` image, `cat`, optional `path`) — not a subset of it, or the
built-in migration could not pass F13. Prerequisite merging keeps preflight's
existing semantics (F11 enumerates them). Retired-key warnings
(`bin/airlock-config:116-137`) are global, not per-app, and are unaffected.
Allowed config keys are computed as `defaults + required + nested allowed_keys`,
splitting `APP_DEFAULTS`'s two roles while keeping typo detection fail-closed.
Amended in child 3: the manifest and all three lifecycle scripts must be
regular non-symlink files (`lstat`-checked) — the D6 digest records only a
symlink's *target string*, so a symlinked manifest or script could change
behind an unchanged digest. No remote catalog, ever: the CasaOS store outages
traced to its live catalog API are the counterexample.

`[artifacts]` patterns are validated for **disjointness against every other
claim on the box**: the other configured packages *and* every ledger or journal
entry recorded under a different id — a new package cannot claim artifacts an
absent-but-recorded app still owns until that record is removed. (The same id
is exempt: replacing or shadow-upgrading an app is the D6 upgrade path.)
Overlap is fatal at validate. That, not an id-derived naming rule, is the
ownership boundary: real built-ins already own units their id does not prefix
(fileview owns `airlock-fileview.service`),
so ownership must be declared, and declared ownership must be exclusive. A
declared `tile.icon` is staged by the platform to the webroot under
`assets/apps/<id>/`, which the platform auto-records as that app's artifact —
the id-scoped directory makes cross-app collisions impossible. Teardown (D6)
touches only recorded artifacts; anything an operator manually places inside a
recorded artifact path is removed with it — that is part of the D4 trust grant
and the SECURITY.md section says so.

**Amended in child 4 — serve declarations, typed units, rooted artifacts.**
Three manifest surfaces the built-ins need and third parties inherit (except
where marked):

- `serve.https = {port_key -> target_key}` — or
  `{port_key = {target = target_key, enabled = boolean_default_key}}` for an
  operator opt-in listener. A false gate omits the mapping from rendering and
  from the ledger claim; the gate must be a boolean `[config.defaults]` key so
  an omitted operator value is deterministic. The platform executes the exact
  mapping the four owner apps run by hand today
  (`sudo tailscale serve --bg --https=$LISTEN http://127.0.0.1:$TARGET`) and
  the ledger retires it. Mapping identity is `(mode, listen, target)`; the
  teardown off-address is `(mode, listen)` — `off` clears the whole listen
  address, so the guard skips it whenever any other live record or currently
  configured mapping occupies the same `(mode, listen)`, regardless of
  target (a target-sensitive guard would kill a re-targeted successor). The
  stale sweep becomes mode-aware over the same identity.
- `plaintext_redirect = {public_key -> redirect_key}` — the 301 pairing stays
  **orchestrator-owned**: `cmd_plaintext` reads it from manifests instead of
  the registry; creation and retirement stay config-driven, no ledger
  involvement. **Shipped-only** (amended during P1 review): an explicit
  manifest declaring it is fatal at validate — an explicit package's
  manifest vanishes with its config line, so retirement under orchestrator
  ownership would be impossible by construction; shipped manifests persist
  in-tree, and the stale sweep reads every shipped manifest's default
  public port regardless of config (the same defaults backstop removed
  built-ins have today; a customized port remains the documented
  unrecoverable class). Plaintext rows are derived from MODE, never from
  raw port values: `cmd_plaintext` emits exactly the `serve_mappings`
  entries with `mode == "http"` plus the `plaintext_redirect` pairs — a
  package declaring only `serve.https` gets no plaintext row.
- `units` entries are typed `{name, scope}` with bare-string accepted as
  `scope: user`; a manifest may declare `user` or `system` only, and the
  same unit name in both scopes is fatal at validate. Intent expansion
  resolves only the declared scope's path — the legacy both-paths probe
  could adopt a same-named unit from the other scope. **Unit names are
  literal** (amended during P1 review, after a reproduced escalation:
  `units = [{name = "*.service", scope = "system"}]` validated, expanded
  over the whole system unit directory, and tore down decoy `nginx.service`
  and `sshd.service` with `sudo systemctl disable --now` + `sudo rm`; a
  glob also wedged `commit` forever, since the committed `unit_scopes` map
  keys on expanded basenames a pattern can never equal). No shipped or
  plausible app needs a pattern — all fifteen unit names the nine built-ins
  create are literals — so the class costs nothing and the scope typing
  now bounds both WHICH root and HOW MANY units. Rejected at validate and
  again at record load, so a hand-edited record cannot reach expansion.
- `artifacts.rooted` — root-owned non-unit files (orca's nft rule and web
  bundle). **Shipped-source-only**: an explicit-class manifest declaring it
  is fatal at validate (D4 is not extended to third parties). Patterns are
  absolute after substitution, under an allowlist: `/etc/airlock/`,
  `/opt/airlock/`, and `${webroot_parent}/` (a substitution token resolved
  at record time and snapshotted per D6 — the snapshot resolves, it does
  not authorize; see below). Patterns are directory-or-file claims in the
  existing pattern grammar (no `**`; a trailing slash claims the tree
  exactly as `webroot` dir claims do). Removal re-checks canonical
  containment at execution time and may sudo; the leaf is owned
  un-realpath'd exactly as D6 owns leaves. **Authorization is never the
  record's** (amended during P1 review, after a reproduced exploit: a
  hand-written intent carrying `roots.webroot = /etc/attacker-hub` and a
  rooted pattern `/etc/passwd` reached sudo removal): the record's roots
  snapshot resolves `${webroot_parent}` at record time but confers no
  deletion authority — containment against the static allowlist ∪ the
  CURRENT environment's webroot parent is enforced at load/validate for
  intent records and re-checked at execution for every record (a committed
  record's rooted list is gated at execution, where the authorization
  actually matters). The dynamic anchor is itself **conditionally
  admitted**: a webroot whose canonical parent is `/` or an FHS system
  root contributes no anchor at all — otherwise unioning it would grant
  the whole filesystem — so such a box cannot use webroot-parent rooted
  claims and is told to move the webroot deeper. The v4 record carries a
  required `capabilities` list, with rooted expansion/teardown refused
  unless the record itself claims `rooted-artifact` — whether a package may
  declare `rooted` at all is decided once, at admission, in
  `bin/airlock-config`. A legitimate custom-webroot record after a genuine
  webroot change is refused loudly (restore the webroot or remove by
  hand) — the accepted fail-closed trade.

`config.port_spans` (already in the schema) becomes load-bearing here:
code-server declares `backend_port … backend_port+slots-1` per D8, and the
span joins the uniqueness pool — a slot-range collision that silently passed
the scalar-only check becomes fatal, which is the point of D8, not a
regression.

### D3 — Dependencies have defined semantics, not just a field

`airlock-config apps` today emits TOML input order (`bin/airlock-config:386-389`)
and the real dependency already exists: notepad requires publish
(`apps/notepad/install.sh:19-21`). The contract: the resolver emits a stable
topological order (ties broken by name) consumed identically by validate,
install, and smoke; deactivation runs in reverse order; a dependency that is
missing (no `[apps.dep]` table — there is no other disabled state: presence of
the table *is* enablement) or self-referential is **fatal** at validate time, as
is a cycle. Dependencies are id-level only: a shadowed dependency satisfies the
edge (D1); no capability contract exists at this layer.

Dependency ids are **app** ids, so they follow the app-name grammar
(`bin/airlock-config` `APP_NAME_RE`), not the tighter packaged-id grammar: in
stage 3 a package may legitimately depend on a legacy-named built-in or custom
app. The ledger mirrors that grammar for record `deps` while keeping the tight
grammar for entry keys — a validate-green config must never wedge `plan`,
`remove`, or the per-app teardown escape hatch.

Stage-3 exception (amended, child 3): until the built-ins carry manifests, the
resolver has two documented behaviours. With no `[packages.*]` configured,
`apps` emits TOML input order byte-for-byte (the built-in fast path). With
packages, one global Kahn runs over all configured apps, seeded with a
*synthetic input-order chain* `a_i -> a_{i+1}` spanning every configured
`[apps.*]` id — built-ins and shadowed ids alike — so the built-ins' implicit
dependencies (publish before notepad) are honoured by position; manifest
`[dependencies]` edges add constraints on top, ready-queue ties break by
C-collation name order, and a manifest edge that contradicts the input order
makes the union cyclic — fatal, naming the ids: the operator reorders the
TOML. The forward graph is built from configured apps only — a ledger record
alone never satisfies a dependency. Child 4 replaces the synthetic chain with
the built-ins' real manifest edges, retiring the exception.

**Amended in child 4 — the synthetic chain retires.** The stage-3 exception
(a synthetic input-order chain seeded over all configured apps, contradiction
fatal) is replaced: the forward order is a Kahn over **real manifest edges
only**, with the ready queue prioritized by config input order. With no real
edges the order IS input order (the fast path stays byte-identical);
real-edge cycles remain fatal; a config whose input order contradicts a real
edge is **reordered, not rejected** — the old contradiction-fatal outcome
only ever hit configs that were already invalid, so no valid box changes
behaviour. The one in-tree edge is notepad's dependency on publish
(dep → dependent: publish → notepad).

### D4 — Trust is explicit and documented, not sandboxed

An app package runs arbitrary bash as the operator, including sudo. The public
docs say exactly that: adding a `[packages.X] path` line is trusting that code
(Homebrew shipped Tap Trust only in 6.0 after real incidents; krew prints an
unaudited-code warning on every install; Umbrel labels community apps). The
opt-in step comes for free — there is no discovery, only explicit config — but
the SECURITY.md section is part of the contract (F13 gates on it), and the hub
may label non-built-in apps (OQ2).

**Amended in child 4 — the shipped trust boundary.** Shipped packages are
first-party code reviewed in this repository; explicit packages are the
operator's trust grant exactly as above. The one behavioural consequence: a
dry run may execute a *migrated* shipped app's lifecycle scripts (they
certify full `AIRLOCK_DRY_RUN` discipline as part of their migration), which
is what keeps the dry integration suite meaningful across the flip; an
explicit package's scripts are never executed on a dry run, migrated or not.
SECURITY.md carries this boundary in its package-trust section (F13 gates on
the section existing).

### D5 — Lifecycle is three scripts with an objective requirement matrix

| Script | Requirement | On absence |
|---|---|---|
| `install.sh` | required | configured package fails validate (fatal — reversing today's skip-and-log at `install/airlock-install.sh:95`; with out-of-tree paths, skip means a typo installs nothing and reports success) |
| `smoke.sh` | required | fatal at validate. No route-dependent exceptions — "effectively required" is not a rule two implementers read the same way; a package with nothing to probe ships a trivial smoke that asserts its unit is active |
| `deactivate.sh` | optional | package is install/upgrade-only: the platform **refuses to drop it from config** rather than stranding its artifacts (closing SECURITY.md:130-139 instead of extending it to third parties); upgrades follow the D6 record-diff path |

Scripts receive `AIRLOCK_ROOT` (platform: `install/lib.sh`, `gate/`),
`AIRLOCK_APP_DIR` (every package-local asset and backend), and `AIRLOCK_APP_ID`,
with a defined cwd (`AIRLOCK_APP_DIR`). All eighteen built-in install/smoke
scripts, the orchestrator loops, and `bin/airlock-smoke` migrate off
`$HERE/../..` onto this ABI (child 2 carries the loop + lib; child 4 carries the
per-app script migration).

**Amended for the apps/ cutover — the ABI is required, and it is now enforced.**
The migration above left `$HERE/../..` in place as a fallback
(`${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}`) for standalone invocation. That
fallback is not a convenience, it is the coupling this contract exists to remove:
`$0/../..` is the platform only while the package sits in the platform's own
`apps/` tree, so after the cutover it resolves to the app repository and the
script fails late — or, worse, succeeds against the wrong tree. `AIRLOCK_ROOT`
therefore takes `:?` and every caller supplies it, test harnesses included.
`$0`-relative **self**-location is untouched and remains correct: it names the
package, which moves with the package, and is what `AIRLOCK_APP_DIR` falls back to.

Three consequences, all now gated by `install/check-app-abi.sh` (controls in
`install/test-app-abi.sh`, both run in CI):

- **Only `install/lib.sh` and `gate/*` are readable platform paths.** A platform
  internal must be exposed as a lib.sh function first — `airlock_resource_holder_pids`
  was added for `apps/paseo`, which had been reading `install/resource-holder-pids.py`
  by path.
- **A package reaches its own files through `AIRLOCK_APP_DIR`, never `$ROOT/apps/<id>`.**
  `apps/feedback/render.sh` was writing the latter into a systemd unit, which
  would have broken on the first run after the cutover.
- **The gate covers every shell file in the package, not just the lifecycle four.**
  The first sweep fixed `install.sh`/`smoke.sh` and missed three auxiliary
  installers (`dev-monitor/install-spool-hardening.sh`,
  `dev-monitor/install-token-timer.sh`, `paseo/browse-host/install.sh`, the last
  climbing three levels rather than two) carrying the same idiom. That miss is why
  this is a standing gate and not a one-time migration. Shell is found by shebang
  as well as by extension — two shipped app programs have neither
  (`code-server/bin/airlock-code-server-slot`, `devterm/bin/devterm-shell`).

**The gate is an allowlist, and that is not a stylistic choice.** Two rounds of
adversarial review killed the blocklist version of it.

Round one walked six spellings of one climb past a pattern written for the last
spelling: a `cd` subshell, two chained `cd ..` steps, nested `dirname`, a
`${VAR%/*/*}` suffix strip, `..` parked in a variable, and
`$(dirname "$0")/../..`, whose inner `)` slipped through a `[^)]*` pattern.
Banning the `..` segment outright failed in the other direction —
`apps/orca/bin/verify-web-bundle.sh` climbs one level from `bin/` to reach its own
`web-bundle/`, which is self-location and survives the cutover intact.

Round two, against a rule that instead checked how the root was *assigned*, walked
six more: `read -r ROOT`, `printf -v ROOT`, `declare`, an array element, an
assignment tucked inside `if true; then … fi`, and — needing no variable at all —
`. "$(cd "$HERE/../.." && pwd)/install/lib.sh"`. It also showed that an *accepted*
within-package climb could be extended one level and escape
(`P="$(cd "$HERE/../.." && pwd)"; . "$P/../install/lib.sh"`).

The lesson is not that the next pattern would have been better. Shell has unbounded
ways to spell a path, so no blocklist terminates. So the rule inverted: **there is
exactly one accepted way to read the platform** — `"$ROOT/install/lib.sh"` or
`"$ROOT/gate/…"`, where `ROOT` comes from `${AIRLOCK_ROOT:?…}` and is never
rebound — and every other spelling is a violation by construction. All twelve
evasions above are fixtures in `install/test-app-abi.sh` now, and a thirteenth is
not a new hole, because it is not on the list.

What the gate still cannot decide is stated in the file itself: a path assembled at
runtime, a cwd-relative source, an indirect expansion. Those are covered from the
other side by running the real script — `install/test-render-parity.sh` executes
`apps/paseo/browse-host`'s nested installer with `AIRLOCK_ROOT` unset and asserts
it refuses, then with `AIRLOCK_APP_DIR` polluted and asserts it still finds its own
files. A static gate and a runtime probe fail differently, which is why there are
both. Installers stay idempotent and are re-run on every
reconcile, exactly as the orchestrator re-runs them today
(`install/airlock-install.sh:88-96`) — the D6 digest exists to decide removal
trust, never to skip an install. `deactivate.sh` removes units, serve mappings,
and generated nginx; keeps data; and must be idempotent.

**Amended in child 4 — the deactivator's role is narrowed to what the
classes cannot express.** The ledger owns artifact removal end to end: the
atomic unit bundle (stop/disable → delete → daemon-reload, sudo for system
scope) is the ledger's, as is serve-mapping retirement (now including
`--https`) and `rooted` removal. `deactivate.sh` is the app-specific stop
hook that runs before ledger removal in the ordinary flow — anything the
declared classes cannot express — and stays optional per the matrix above.
On the package-gone path the deactivator cannot run (there is no package);
the ledger still removes what the record names and reports what it could
not stop. "Removes units, serve mappings, and generated nginx" above
describes the *removal contract*, whose executor is the ledger; it is not a
list of duties the deactivator script must reimplement.

### D6 — An installed-state ledger makes removal possible

Desired config alone cannot deactivate what is no longer in it: deleting
`[packages.X]` + `[apps.X]` deletes the path, the manifest, and the deactivator
with it. The ledger closes that, with these definitions:

**Digest** = SHA-256 over the package tree with an unambiguous serialization:
entries in byte-sorted relative-path order, each hashed as a length-prefixed
tuple of (path, type, mode, content — the file bytes, or the symlink target
string). Hardlinks hash as regular files; any other special file type in a
package is fatal at validate. Computed immediately before `install.sh` runs;
recorded at commit. "The package changed" means exactly: this value differs.

**Two-phase record.** Before running `install.sh` the platform journals an
*intent* entry `{id, canonical path, digest, declared artifact patterns}` —
patterns as written in the manifest, since nothing is expanded yet; after
install + smoke succeed it expands those patterns against the live system and
*commits* the entry `{id, canonical path, digest, lifecycle capability,
expanded artifact list}`. Journal entries live in the same store as the ledger
and follow the same lock and atomic-replace rules; every record is exactly one
of intent or committed, never an ambiguous middle state. A first install holds
only an intent record and commit atomically replaces it with a committed one;
during an **upgrade** the old committed record and the new intent coexist until
the commit write — the record diff below requires the old expansion to survive
exactly that long — and the commit write replaces both in one atomic step.
A run that dies between journal and commit
leaves the intent entry; on the next run, an intent entry whose app is desired
is repaired by reinstalling, and an intent entry whose app is no longer desired
is torn down from its declared patterns — a first install that crashes
mid-artifact can therefore still be cleaned up after the operator deletes the
config lines (without the journal, that box would carry those artifacts
forever).

Amended in child 3 — store v2 and removal order. Every record (intent and
committed) carries a `deps` snapshot of the app's dependency ids at record
time; a v1 store is validated against the v1 shape and normalised in memory
(`deps: []`), read-only paths never write, and the first mutation atomically
rewrites the whole store as v2. Removal follows ONE procedure: build the graph
from the selected records — per entry exactly one snapshot, committed winning
over intent, never a union (two individually-acyclic snapshots can union into
a cycle) — include every referenced id (absent ones as virtual nodes), run the
same C-collation Kahn, reverse the entire order, then emit only the ids with a
destructive action. A cyclic selection fails closed naming the ids; the exit
is the explicit per-app teardown, which needs no order. A declared `tile.icon`
adds one synthetic entry to the intent's declared artifacts — the id-scoped
staging directory `assets/apps/<id>` — journaled BEFORE the platform copies
anything (record before mutate), so a crash between copy and install leaves an
artifact the repair paths already know how to reclaim.

**One writer.** The platform holds an exclusive lock across
validate → mutate → commit; a second concurrent run either waits or fails fast
before mutating. Ledger writes are atomic replaces — a killed run leaves the
previous ledger intact and readable.

The lock serialises **Airlock's own writers**, and nothing else: the digest is
a snapshot of the tree as it was read, not an attestation that the bytes the
lifecycle scripts later execute are the same ones. Anyone able to rewrite the
package directory between the digest and the `bash install.sh` (or `smoke.sh`,
or `deactivate.sh`) that follows it can substitute what runs. That is a
**bounded, accepted limitation under D4**, not a gap the digest was meant to
close: the same actor already has write access to a tree whose code the
platform executes as the operator, so they could equally have staged the
content before the run. The digest's job is change *detection* across runs —
"the package changed" — and the last platform step before `install.sh`
re-reads the tree and refuses to proceed when it no longer matches the
journaled intent. Commit does NOT re-read it: the recorded digest is the
pre-install snapshot by definition, because an installer may legitimately
write inside its own package tree.

Neither available way of closing the window is proportionate here. Executing
`install.sh` from a held file descriptor would pin that one file while
leaving every helper it sources unpinned. Executing from a staged immutable
copy would redefine `AIRLOCK_APP_DIR`, the working directory, and that same
legitimate self-write — a lifecycle-ABI redesign. Child 3 deliberately does
neither, and states the boundary instead.

Amended in child 3 — **nothing is removed through a path that was redirected
after its record was written.** Declared patterns expand with `glob()`, which
walks a symlinked intermediate directory, and canonicalisation then hides
that it did: a claim on `~/a/owned` whose `a` became a link to `/victim`
canonicalises to `/victim/owned`, an ordinary-looking path the deletion
boundary would wave through. So each intent record also stores an **anchor**
per declared pattern — where that pattern's fixed prefix resolved AT RECORD
TIME — and teardown refuses when the anchor no longer matches. That is the
precise statement: not "an ancestor is a symlink" (a box whose `~/.local`
points into a dotfiles checkout is ordinary, and its artifacts must stay
removable — the F15 crash-then-remove sequence has to end clean, not
stranded) but "this declaration now names somewhere else". Committed records
hold canonical paths instead of patterns, so their deletion boundary checks
the ancestor chain directly. Both fail closed and KEEP the record: the
operator restores the path, or tears the app down before moving it. Recording
stays permissive by design — an aliased claim is canonicalised into the one
claim space (D2), which is what makes an alias and its real path collide. The
leaf itself may still be a symlink: that is owned, and removed, as a link.

**Removal**, in strict priority order:

1. The record says the package shipped no deactivator → dropping it from config
   is refused while the record exists. The one exit is the explicit platform
   teardown command, which removes every recorded artifact, logs that no
   deactivator ran, and drops the record. (There is deliberately no
   "restore-and-deactivate" exit: a restored tree either lacks a deactivator or
   no longer matches the recorded digest, so it would never be trusted to run.)
2. Recorded deactivator + package present at the recorded path + digest matches
   → run `deactivate.sh`, then remove any recorded artifacts it left behind,
   then drop the record.
3. Otherwise (path gone, or digest mismatch) → the recorded artifact list alone
   is sufficient: the platform removes each recorded artifact directly, logging
   that the package's own deactivator did not run, and drops the record.

**Upgrade.** Same path + changed digest, or changed path for the same id. An
upgrade is exactly a removal of the old entry under the priority rules above —
so a vanished old path or a mutated old tree takes branch 3, not a fourth path —
followed by a fresh install, with one exception: a recorded entry *without* a
deactivator does not refuse (priority 1 governs config *removal*; the id is
still desired). There, no deactivation step exists: the installer runs over the
live install (idempotence, D5), then the platform removes recorded artifacts of
the old entry that the new expansion no longer claims — the record diff —
**before** committing the new entry. Teardown of an already-absent artifact is
a no-op, so a crash on either side of the diff step leaves a state the next run
repairs; the reverse order (commit first, then diff) would let a crash orphan
the old-only artifacts with no record naming them.

The ledger also closes the removed-custom-plaintext-port gap noted in §1, and
F15 covers the one case a ledger cannot: artifacts of an app removed before the
ledger existed.

**Amended in child 4 — store v3.** The record gains five fields
(`source_class` joined during P1 review) and the store version bumps to 3 — the new fields are required exact-shape in v3 (a
corrupted v3 record cannot pass as legacy), while v1/v2 records
read-normalize and the first mutation rewrites the store as v3 (the
established v1→v2 pattern):

- `serve_mappings: {key: {listen, mode, target}}` on intent and committed
  shapes. Legacy intent synthesizes from `serve_port_values` as
  `{listen: port, mode: "http", target: port}`; legacy committed records
  lost the keys, so synthesis keys by the port string.
- `unit_scopes: {name: user|system|both}`. Migration writes `both` for
  legacy records' units — `both` means today's dual-probe, preserved so an
  interrupted old install's system unit is not orphaned; a manifest cannot
  declare `both`.
- `rooted` in `artifacts_declared` and committed `artifacts`, with anchors
  recorded like `files` patterns. The upgrade diff treats `rooted` as one
  more member of the cross-class path union — a path migrating between
  classes across versions is never removed as old-only.
- `order` — a store-global monotonically-increasing rank assigned when the
  intent is journaled (max existing + 1; the observable contract is that
  ranks reproduce install order within a store, not that they restart per
  run). Removal keeps its mechanics (forward Kahn over the records'
  `deps` snapshots, whole order then reversed) and the rank changes only
  the ready-queue tie-break: virtual dependency nodes sort FIRST
  (`(0, name)` — they stand for retained, already-installed deps), then
  ranked records by ASCENDING rank (`(1, rank)`; descending would
  double-invert through the final reversal). The refinement applies only
  when every selected real record carries a pairwise-distinct rank;
  otherwise everything, virtual nodes included, uses C-collation name-order
  (today's behaviour). Deps-safety is unconditional.

**Amended in child 4 — record-less teardown (`--adopt`).** For artifacts of
a known builtin that predate the ledger (no config entry, no record),
`bin/airlock-teardown --adopt <id>` first re-verifies under the ledger
lock — no config entry, no existing record, manifest regular/non-symlink
with `contract = 1`, and claim-disjointness against the full model
(`_recorded_claims` of every other id, platform claims, and the declared
claims of every currently-configured app, recorded or not) — then writes a
**synthetic intent record** (anchors, roots, `serve_mappings` from manifest
default port values with the assumption printed, unranked) and runs the
ordinary teardown machinery. Partial failure keeps the durable intent, and
the retry path IS the ordinary teardown; `--adopt` on an id with an
existing record errors, naming `bin/airlock-teardown <id>` and the next
reconcile as the ways forward.

### D7 — Apps declare an audience; the platform enforces it end to end

Two audience classes already exist in the gate layer — they are just not part of
any contract. *Shared* apps sit behind the hub gate (owner + collaborators,
`$hub_ok`, `install/render-nginx.sh:36-38,78`). *Owner* apps sit behind the
owner identity map (`$owner_ok`, emitted at `install/render-nginx.sh:38`) — but
not through one code path: devterm and orca consume it via `emit_owner_gate`
(`apps/devterm/install.sh:242`, `apps/orca/install.sh:436`), code-server via its
slot gate (`apps/code-server/install.sh:197`), and paseo writes its nginx
config directly (`apps/paseo/install.sh:334`). The contract formalizes the
*class*, and every consuming path — emitter-driven or app-written — must follow
the declared audience, which is why F14's stage-4 leg checks all four.

- The manifest declares which audiences the app supports and its default
  (`[audience]` above). The operator picks per box: `[apps.X] audience = "owner"`
  — a platform-common key like `external`; a value outside the manifest's
  `supported` list is a validation error. Audience is rendered configuration,
  not ledger state: nginx and serve wiring are regenerated every run, so
  changing it takes effect on the next install run.
- The hub follows the gate: `webjson` (`bin/airlock-config:498-530`) gains a
  per-app `audience` field, `/whoami` (`install/render-nginx.sh:89`) gains a
  `role` field (`owner` | `collaborator`, derived from the same identity map
  nginx already holds), and the hub renders an owner-only tile only when
  `role == "owner"`. Today every tile is shown to every allowed viewer
  regardless of whether the gate behind it will refuse them.
- A third class — *personal* apps visible to exactly one named collaborator on a
  multi-user box — is deliberately deferred (OQ4), not a phase-1 class.

### D8 — The platform owns wiring the app declares

Ports were already central — with a known limit the manifest closes: the
uniqueness check covers declared `*_port` scalars only
(`bin/airlock-config:361-383`), while code-server actually binds
`backend_port … backend_port+slots-1` (`apps/code-server/install.sh:25-26`,
`apps/code-server/manager/manager.py:37`); `config.port_spans` (D2) puts the
whole derived range into the check. Tile metadata moves from the central JS
table into the manifest, flowing through `webjson` so the hub needs no per-app
edits. nginx fragments stay app-written *for now* (the emitters in
`gate/nginx-lib.sh` already cover the common shapes); a later child may promote
the Home-Assistant-style "declare a port, the platform writes the ingress"
pattern — OQ1, not a phase-1 requirement.

### D9 — Containers are recorded runtime objects, not successful commands

A container-backed package declares the namespace it owns in
`[artifacts].containers`. Contract 1 accepts literal container names and one
bounded pattern form: a non-empty literal prefix followed by a final `*`.
Nothing else is a pattern; `/`, whitespace, option-like names, and wildcard
characters anywhere but that final position are validation errors. Container
claims participate in the same package-to-package and recorded-state
disjointness check as the filesystem classes.

```toml
[artifacts]
containers = ["airlock-notes-*"]
```

The Docker implementation uses two ownership labels:
`io.airlock.package=<id>` and `io.airlock.install-nonce=<nonce>`. The platform
generates a cryptographically random nonce for each fresh install, records it in
intent, and makes it available to an installer as `AIRLOCK_INSTALL_NONCE` on
that script's first `airlock_load <its-package-id>`; a container package must
load its own config before its first runtime create. The platform passes the
recorded nonce directly to a deactivator. Every container create must apply both
labels. A same-digest
reconcile reuses the
committed nonce and admits only the committed full ids with their exact recorded
names and labels. An upgrade removes and proves absence of the old set before it
journals a fresh nonce. A desired intent left by a crash is first torn down by its
recorded nonce; only after the exact-label set is proven empty may the platform
replace that intent with a fresh one and retry. All other runtime objects whose
names match the declared namespace and do not carry both labels for the active
record are foreign collisions. The platform must never relabel, stop, or remove
a foreign collision. An unrecorded object carrying both active-record labels is
instead an unexpected owned object, and whether it blocks lifecycle admission
turns on its name. The load gate is consumed again from a package's smoke —
after that package created this run's objects, and before the commit that would
record them — so an object carrying the active labels under a **declared** name
is this run's own work and is admitted. Refusing it there would make that commit
unreachable and leave every later run fresh, so the refusal could never clear
itself. A name **outside** the declaration blocks admission and commit alike.
Generic teardown includes both by nonce.

Images, volumes, and networks do not become owned merely because a container
uses them. Contract-1 container packages use only images already present by
immutable digest (`docker run --pull=never`), bind mounts, `tmpfs`, and a built-in
network mode; they must not pull/build images or create named volumes or
networks. D4 permits arbitrary trusted lifecycle code, so this is a reviewed
package obligation rather than a sandbox guarantee: shipped packages prove it
with fake-runtime argument assertions and a real-runtime before/after inventory.
A package needing to create one of those runtime objects requires a future
explicit artifact class first. Operator data bind-mounted into a container is
retained data and is never a container artifact.

The D6 journal closes the crash window in two steps:

1. Intent records the validated name declarations, package label, and fresh
   install nonce before a lifecycle script may load it and create a container.
2. Commit enumerates objects by exact package and nonce labels, then validates
   every returned name against the declaration and records each full immutable
   runtime id and name alongside the nonce. An object carrying only one label, a
   namespace collision, or a nonce-owned object outside the declaration aborts
   commit and keeps intent. The last case remains recoverable because teardown
   enumerates the nonce, not only the declared names.

This is store v6 (v5 already added the audit-event stream). Both record shapes
gain an exact-shape `container_runtime`
field: `null` for a package with no container declarations; otherwise intent
stores `{runtime: "docker", daemon_identity, install_nonce, declarations}` and
committed stores `{runtime: "docker", daemon_identity, install_nonce,
declarations, objects: [{id, name}]}`. `daemon_identity` is
`docker:<Engine.ID>` from `docker info --format '{{.ID}}'`; it is checked again
at every runtime read or mutation. Direct and sudo-mediated clients may share
one identity only when they reach that same engine. An unavailable or changed
identity is UNKNOWN and retains the ledger record rather than interpreting the
other daemon's empty namespace as absence.
Stores v1-v5 read-normalize this field to `null`; as with the prior migrations,
read-only commands do not write and the first mutation atomically rewrites the
whole store as v6. A committed nonce therefore remains authoritative after its
intent has been replaced.

Removal is evidence-driven. The app-specific deactivator runs when D6 permits
it, but is never the only removal path. Generic teardown takes the union of
recorded immutable ids and every object found by the record's two exact labels,
including nonce-owned objects outside the declaration. It lists by labels and
post-filters the two exact label values in code; it does not trust Docker's name
filter. Declared literal/prefix name semantics classify collisions and validate
commit, but never exclude an exact-nonce object from teardown. Immediately
before removal it inspects each full immutable id and requires the recorded id,
package label, and nonce to agree; recorded objects must also retain their exact
name. It passes that full id, never a name or prefix, to `docker rm -f`, then
inspects that id again.

Runtime queries have three results: PRESENT with full identity, ABSENT only
when a structured re-query of the runtime's own object list exits successfully
and no longer carries that id, and UNKNOWN for every other error. Absence is
never read out of an error message. The runtime has shipped more than one
phrasing for a missing object and changes their casing between releases, so a
wording match fails in both directions: it disbelieves a finished removal the
day the phrasing moves, and it would retire an object that is still listed on
the strength of a reply that merely reads like an absence. An identity mismatch, UNKNOWN result, non-zero `rm`, or PRESENT
post-check is a teardown failure and retains the record for retry; even when a
non-zero `rm` is followed by ABSENT, that attempt fails and the next retry may
discharge the now absent record without issuing another removal. After all
per-id checks pass, teardown re-enumerates the exact package+nonce label set and
requires it to be empty immediately before the ledger write. This final oracle
catches an object created with a new id during removal. Namespace-matching
objects with other or incomplete labels are never removed; they block install,
but during teardown are only reported as collisions and do not prevent the
package's proven-empty nonce record from dropping. Thus path loss, digest
mismatch, and intent-only crash recovery have the same container cleanup
guarantee as an ordinary configured deactivation.

Contract 1's first container runtime is Docker. Supporting another runtime is a
new contract decision, not an executable name hidden in per-box config: runtime
identity, immutable object identity, filters, and a structured way to prove
absence must have one specified meaning before the ledger can trust them.

## 3. Fixture specifications

Each fixture is specified here and made executable by the child that implements
the behaviour — shown **red** (failing for the specified reason, or, where the
behaviour is new, demonstrably absent) before **green**. IDs are stable;
children 2–4 reference them. "Stage" names the owning child. Unless stated
otherwise, fixtures run against a scratch config/webroot the way
`install/test-config.sh` and `install/test-integration.sh` already do — no live
units, no sudo.

Fixture packages live in a temp directory *outside* the repo checkout
(`mktemp -d`), so a fixture can never pass by accidentally resolving
`$ROOT/apps`.

**F1 — Out-of-tree round trip (stage 2).** Stage a minimal package (manifest
with an `[artifacts]` declaration and a data path, `install.sh` that writes a
declared marker artifact and a data file using only the D5 ABI variables,
`smoke.sh` that asserts the marker, `deactivate.sh` that removes the marker but
keeps the data) at a temp path; configure `[packages.t1]` + `[apps.t1]`.
Assert: validate passes; the installer runs with `AIRLOCK_ROOT`,
`AIRLOCK_APP_DIR`, `AIRLOCK_APP_ID` set and cwd = `AIRLOCK_APP_DIR`; smoke runs
from the same resolution; the committed ledger entry carries the canonical
path, the D6 digest, the lifecycle capability, and the expanded artifact list.
Variants in the same fixture: (a) the package path given *relative* to a config
in its own temp dir, with the run started from an unrelated cwd — resolution
must base on the resolved config's directory, not the cwd; (b) a second,
fully-formed package present in a sibling directory but named in no
`[packages]` table is never resolved, installed, or listed (pins the rejection
of `apps.d/`-style discovery). Then drop both tables and reconcile:
`deactivate.sh` ran (and, invoked directly a second time, exits clean — the
idempotence check runs against the script, since after the record drops a
second reconcile correctly has nothing to do), the data file survives, and no
orphan unit/fragment/webroot file/serve mapping/ledger entry remains. Red today: `install/airlock-install.sh:90`
resolves only `$ROOT/apps/$app/install.sh` and skips with a log line (`:95`).

**F2 — Id agreement (stages 2, 3).** (a) `[packages.X]` with no `[apps.X]` →
fatal at validate (stage 2: a package line that configures nothing is a typo,
not a no-op). (b) Manifest `id` differing from `X` → fatal naming both ids
(stage 3).

**F3 — Reserved core and shadowing (stage 2).** (a) `[packages.hub]` → fatal:
`hub` is reserved platform core (the tenth `APP_DEFAULTS` entry keeps its
schema centrally). (b) `[packages.notepad] path=…` shadowing a built-in →
accepted; resolution, logs, and the ledger all show the canonical override
path, and nothing resolves from `$ROOT/apps/notepad`.

**F4 — Staged-asset escape (stage 3).** A manifest whose `tile.icon` is
`../outside.svg`, an absolute path, or a symlink inside the package pointing
outside the package root → fatal at validate; nothing is staged into the
webroot. The check runs on fully resolved paths (symlinks resolved on both
sides) against the canonical package root — D1's containment rule.

**F5 — Dependency semantics (stage 3).** A missing dependency (no `[apps.dep]`
table), a self-dependency, and a two-package cycle → each fatal at validate
with the app ids in the message. Order: with notepad depending on publish,
`airlock-config apps` emits publish before notepad regardless of TOML input
order, and the same order feeds validate, install, and smoke; deactivation
order is the exact reverse. Red today: `cmd_apps` emits input order
(`bin/airlock-config:386-389`) and the notepad→publish dependency is enforced
only by an ad-hoc grep inside its installer (`apps/notepad/install.sh:19-21`).

**F6 — Lifecycle matrix (stages 3, 4).** A configured package missing
`install.sh` → fatal at validate; missing `smoke.sh` → fatal; missing
`deactivate.sh` → accepted, and the ledger records install/upgrade-only (stage
3, manifest-bearing packages). Stage 4 flips the same rule for built-ins: after
the migration, a missing installer for any configured app is fatal — reversing
today's skip-and-log (`install/airlock-install.sh:95`), which the fixture pins
as red first.

**F7 — The deactivator-less package (stage 2).** Ledger records an
install/upgrade-only package. (a) The operator drops it from config: the run
fails, names the app, and names the one exit — the explicit platform teardown;
no artifact was touched. The refusal holds whether the package path still
exists or not (D6 priority 1 outranks the path-state branches). (b) The
explicit teardown: every recorded artifact is removed, the removal is logged as
platform-performed, the record is dropped. (c) Upgrade: point the package at a
v2 tree (changed digest) whose expansion no longer includes one old artifact —
install succeeds with no deactivation step, and once the run ends the platform
has removed exactly the artifact the new expansion stopped claiming, before
committing the new entry (the D6 record diff and its ordering).

**F8 — Path gone / digest mismatch (stage 2).** Ledger records a package *with*
a deactivator; delete the package directory (variant: mutate any single file in
the package tree — content, mode, or symlink target, per the D6 digest
definition). Drop it from config and reconcile. Assert: teardown proceeds from
the recorded artifact list alone, logs that the package's deactivator did not
run, removes every recorded artifact, drops the record.

**F9 — Ledger integrity (stage 2).** (a) Corruption: truncate the ledger /
replace it with garbage → validate, install, and reconcile all fail closed with
a diagnostic naming the ledger file; a corrupt ledger is **not** treated as
empty (that would orphan every recorded artifact and re-install over live
state). (b) Atomicity, observably: kill a run after `install.sh` has written
its artifacts but before commit — the previous ledger is intact and readable,
an intent entry exists, and the next run repairs (reinstall if still desired;
teardown from declared patterns if the operator has since removed the config —
the first-install-crash-then-remove sequence must end clean, not stranded).
(c) One writer: a second run started while the first holds the lock waits or
fails fast before mutating; afterwards the ledger parses and matches exactly
one of the two runs' outcomes.

**F10 — Config and manifest fail-closed (stage 3, resolver cases stage 2).**
Each of these alone is fatal at validate, with the key and reason in the
message: an unknown key in `[packages.X]` (e.g. `source = "git+…"` — the D1
rejection, pinned); a package id violating the D1 grammar (`My.App`, `a_b`); an
unknown top-level or nested manifest field; a key present in both
`config.required` and `config.defaults`; a required key absent from the
operator's `[apps.X]`; an operator value whose TOML type contradicts the
declared/inferred type; `audience` outside the manifest's `supported` list; a
`[tile]` carrying both `glyph` and `icon`; a `port_spans` expansion that
collides with another app's port; two packages whose `[artifacts]` patterns
overlap (the D2 disjointness rule, including against a recorded entry of a
different id); a nested table on a scalar key (preserving
`install/test-config.sh:272-281`); and — amended in child 3 — a `contract`
that is missing, boolean/non-integer, or an unsupported version: `contract = 1`
is REQUIRED in every manifest. (The packages feature never shipped outside
this repo's own fixtures, so there is no external manifest to stay compatible
with; all in-repo fixtures were upgraded in the same change.)

**F11 — Prerequisite merge (stage 3).** Manifest-declared prerequisites merge
into preflight with the TSV's full semantics, enumerated: every field
(`command`, `predicate`, `expected`, `fix`, `note`) required
(`install/preflight.sh:93-96`); the predicate drawn from the closed allowlist
(`present` | `major-gte`, `:107-118`), and `major-gte` only for commands that
have a version probe (python3 and node today, `:114-116` — a manifest asking
for a version of anything else is fatal, exactly as the TSV is); duplicate
owner+command rejected; conflicting `fix` for the same command rejected;
`present` + `major-gte` for the same command merge to the stricter
requirement, and two `major-gte` to the higher version (`:132-142`); the
mandatory core commands (python3, nginx, sudo, systemctl, tailscale, curl,
flock — seven since child 2 added the install lock; the earlier six-command
list here was stale) and their core-owned rows unaffected by any manifest.
Amended in child 3 — the responsibility split is explicit: `airlock-config
prereqs` owns ASSEMBLY (TSV rows pass through in file order; rows owned by a
manifest-bearing id are dropped — a shadowing package replaces the built-in's
rows; manifest rows append with owner = the package id; per-row validity,
rc 2 on violation), and preflight keeps EVALUATION — every cross-row rule
above runs there unchanged on the assembled inventory, captured to a temp
file whose producer exit status is checked directly. The built-in-only path
reads the raw TSV exactly as before. A manifest
declaring *zero* prerequisites is valid — the manifest itself is the
declaration the TSV-era per-app row requirement (`:157-161`) was
approximating, and that rule retires with the TSV; the nonempty-inventory
check (`:150-151`) continues to hold over the core TSV that remains.

**F12 — Key inventory (stage 3).** For every app, statically scan the package
tree for config reads — `airlock_config get apps.<id>.<key>` call sites and
`AIRLOCK_<ID>_<KEY>` env-name references (the real `_envkey` shape,
`bin/airlock-config:452-453`: id upper-cased, `-` flattened to `_`) — and
compare the found key set
with the manifest's allowed set, both directions: a key read but not declared
is reported (and fails for a shipped strict-scan package); a key declared but
never referenced warns, except for a port key as described below. The mechanical
whole-table env export (`bin/airlock-config:452`, `install/lib.sh:41`) does not
count as a read — otherwise nothing could ever warn. Dynamically constructed
key names are a stated limitation of the scan; that is why the undeclared
direction is the failing one.

Amended in child 3 — **the scan reports; it does not gate.** Every F12
finding is a warning: an undeclared read, a key the scanner cannot resolve
(`$…`, command substitution, an ANSI-C escape), and a declared-but-unread key
alike. Making undeclared-read fatal requires the scan to decide, reliably,
which text in a package is a call site — i.e. to be a shell parser. Eleven
review rounds of exactly that produced a quote stack, here-doc masking and
arithmetic-span logic that traded one edge case for another every time, in
BOTH directions: one round a real call site was missed, the next a correct
installer was blocked by a usage message.

Amended again 2026-08-07, in two halves that only work together.

**`[config].runtime_env`.** A live install printed ninety warning lines of the
form *"references `AIRLOCK_PUBLISH_GATED_DIR`, but 'gated_dir' is not a declared
config key (the export will not exist)"*, across eighteen distinct names. The
wording implies eighteen bugs. There were none: seventeen of the eighteen are
names the installer **writes** — `Environment=` lines on a rendered unit, the
name of the variable holding a token, a test seam the source explicitly marks as
unsupported — and one is an operator knob read as a raw string. The scan had no
way to say *written, not read*, so it said the only thing it could.

Declaring them as config keys would have been worse than the warnings, and for
two of them it changes behaviour: `AIRLOCK_PASEO_ALLOW_UNBACKED_MEM` is compared
against the literal `1`, so a boolean declaration exports `"true"` and stops
matching; `AIRLOCK_DEV_MONITOR_CORS_HOSTS` is measured by the installer from the
box's own FQDN, so declaring it creates a knob that does nothing.

So `runtime_env` is a field of `[config]` — inheriting the fail-closed unknown-key
handling, and safe because `resolved()` merges only `defaults` — holding full
env-var **names**, no values, not merged, not exported. Three rules stop it being
an escape hatch, all fatal at manifest-validate time: the name must carry the
package's own prefix, it may not appear twice, and it may not collide with a
declared config key. And it does **not** excuse a literal
`airlock_config get apps.<id>.<key>` — that really is a config read and really
does fail at runtime, whatever the manifest says about an env-var name.

**Strict mode, narrowly.** With the eighteen declared, the remaining findings are
real, so `AIRLOCK_STRICT_CONFIG_SCAN=1` promotes them to fatal — for **shipped
packages only**, and only for **fully literal** references. External packages keep
today's advisory behaviour: this must never block somebody else's install over a
lint whose own history is eleven rounds of failing to become a shell parser. A
dynamically built key stays a warning under strict for the same reason, and a
declared-but-unread non-port key stays a warning because it is untidy, not broken.
CI sets the variable; nothing else does.

**Port-ownership amendment (2026-08-30).** A private package declared
`port = 18832`, but its unit and ingress independently hard-coded 18832. The newer
`learning.backend_port` legitimately owned the same number. Validation passed for
two separate reasons: the global sweep recognised only names ending in `_port`,
and F12 treated the dead bare `port` declaration as advisory. The losing service
then restarted indefinitely.

Port declarations are therefore the narrow fail-closed exception to F12's advisory
rule. Both the exact key `port` and names ending in `_port` enter the same global
uniqueness pool, including leaves under `[config.tables]`. The read gate also covers
keys that have port semantics by explicit
manifest declaration: `artifacts.serve_ports`, `serve.https` targets, both sides of
`plaintext_redirect`, and a `config.port_spans` base and count. A package declaring
one of those ownership inputs must contain a canonical shell variable assignment
whose RHS expands `AIRLOCK_<ID>_<KEY>`, an active expansion passed to a
port-shaped command option (`--port` or `--*-port`, including a shell-continued
logical line), a Python AST environment `Load`, or a canonical shell assignment
whose command substitution runs
`airlock_config get apps.<id>.<key>`; otherwise validation fails for shipped
and external packages, independent of strict mode. A dynamic read is not proof here:
if the platform cannot prove which declared value governs the listener set, it cannot
honestly claim global port ownership. Non-port dead declarations retain the
warning-only behavior above.

For this fatal subset, documentation, dotfiles, and inert data files are not runtime
read evidence; the literal consumption must appear in executable/package runtime
source. A token in a Python docstring/inert/store expression, an arbitrary shell
argument, quoted heredoc, escaped expansion, or single-quoted string is not evidence.
Port-shaped command options are admitted because packages commonly pass a platform
value straight to their renderer or installer without an intermediate assignment.
This is a syntactic admission proof, not a general program-semantics proof.
A shell no-op (`: "${AIRLOCK_…_PORT}"` or `true --port "${AIRLOCK_…_PORT}"`)
and an `airlock_config get` whose output
is explicitly discarded are also not consumption evidence: both can be added without
changing any rendered/runtime value, which would recreate the incident's escape hatch.
Package CI must additionally bind its concrete unit/backend/ingress artifacts to the
same declaration and exercise mutations that change the runtime port after assignment.
Keys used as the listen side of `[serve.https]`, its optional boolean control,
or the public side of `[plaintext_redirect]` are different: the platform itself
consumes those values. Active listeners remain in the global uniqueness pool,
but these platform-owned keys do not require a meaningless package read. Their
target-side keys are package-owned and retain the fatal consumption gate.

Be precise about what is and is not enforced as a result. An undeclared read
usually surfaces on its own — `airlock-config get apps.<id>.<undeclared>`
exits non-zero with `key not found` — but a package that suppresses the
failure (`… 2>/dev/null || true`, which this repo's own `feedback` and
`publish` installers use) sees an empty value, and the platform cannot
distinguish that from a legitimately empty one. So in stage 3 general F12
findings remain an **advisory lint for the package author**; the port-ownership
exception above enforces the part of the declaration contract required for
listener uniqueness. The operator's side stays enforced: an unknown key in `[apps.X]` is
fatal against the manifest schema, which is where config typos live. The
reader still expands what the shell expands for free (quotes, backslash
escapes, splices) so a warning names the key that would really be read;
comment lines are skipped; dynamically-built names remain a stated
limitation. Child 4 revisits gating once the built-ins carry manifests and
every call site is in-tree — at which point the fatal direction can be
reintroduced against a known corpus rather than against arbitrary shell.
(Amended in child 4 — the revisit's conclusion: the fatal direction is NOT
reintroduced. The in-tree corpus is now manifest-declared, but the lint
still cannot parse arbitrary shell, and the child-3 counter-example rounds
apply to in-tree scripts equally. General F12 findings stay advisory; the later
port-ownership amendment is the narrow exception. The manifest schema itself also
remains enforced — an unknown key in `[apps.X]` is fatal.)

**F13 — Built-in equivalence gate (stage 4).** Defined so it is actually
measurable — `install/test-integration.sh` runs dry-run only (`:33,65`) and
writes no units, so live-artifact byte-comparison is not available there.
Instead: (a) nginx — `install/render-nginx.sh` and the fragment writers
rendered to a scratch `CONFD`, byte-compared before/after the migration; (b)
units — unit text captured via an injectable destination for
`write_if_changed`, byte-compared; (c) hub — a semantic projection: the old
central `APPS` table + old webjson merged into the tile model the hub renders,
field-compared against the new manifest-driven webjson across the *complete*
tile model — `label`, `sub`, `glyph`/`brand`→`icon`, `cat`, `path`, and
feedback's no-tile case (byte identity is impossible: the fields move files).
Plus the registry retirement itself: after the flip, the nine non-hub
`APP_DEFAULTS` rows, the per-app `prerequisites.tsv` rows, and the
`hub/index.html` `APPS` table are gone; a missing manifest is fatal; and
SECURITY.md carries the D4 trust section (the doc is part of the contract).

*(Amended in child 4 — measurement mechanics for (b): five installers write
units by direct `cat`/sudo-`tee`, not `write_if_changed`, and two of those
heredocs never execute on a dry run, so injection alone cannot capture them.
The migration extracts every unit/fragment heredoc into a sourceable render
library per app — verbatim copies proven byte-equal to the inline text by a
dual-render fixture BEFORE any write site moves — and the baselines are the
render-library outputs across per-app variable sets enumerated to cover
every artifact-producing branch, committed with the dual-render proof. The
byte-comparison of (a)/(b) is against those committed baselines.)*

**F14 — Audience end to end (stages 3, 4).** Stage 3, on a manifest-bearing
package: scratch-rendered nginx guards the app with `$owner_ok` when the
operator sets `audience = "owner"` and with `$hub_ok` when `"shared"`; webjson
carries the app's `audience`; `/whoami` output includes `role` (amended,
child 3: in stage 3 `role` is emitted only when a configured package declares
`[audience]`, so the built-in-only render stays byte-identical — stage 4 makes
it unconditional); flipping the
audience in config changes the rendered gate on the next run with no manual
step; and the F1 package's tile fields flow into webjson. Stage 4, on the
migrated built-ins: the four owner-gated apps — devterm and orca
(`emit_owner_gate`), code-server (slot gate), paseo (app-written nginx) —
render owner-guarded from their manifests' audience alone, byte-equal to
today's output (folds into F13a), so an audience mechanism that only covers the
emitter path cannot pass. For out-of-tree packages that write their own nginx
(D8), honouring the operator's audience is a package obligation under D4 — the
platform cannot structurally force a fragment it did not write; the structural
fix is OQ1's platform-written ingress.

**F15 — Pre-ledger adoption sweep (stage 4).** On a box state resembling a real
upgrade: artifacts of a built-in that was installed and then removed from
config *before* the ledger existed (e.g. notepad's `$WEBROOT/notepad/`,
`apps/notepad/install.sh:24-26`, per SECURITY.md:130-139 never retracted).
First ledger-enabled run: the sweep detects artifacts matching a known
built-in's manifest `[artifacts]` patterns with no desired config and no ledger
entry, reports them loudly with the explicit teardown invocation, and does
**not** delete anything on its own; the teardown command then removes them.
A desired-and-installed built-in needs no adoption path at all: the ordinary
packaged install runs (D5's idempotent re-run rule) — intent → install →
commit — and record-before-mutate holds by construction; inferring a
committed record from live state would bypass the journal and lose the
repair path. (Sentence amended in child 4; the original promised a silent
live-state commit.)

*(Amended in child 4 — detection contract: the sweep runs on EVERY
ledger-enabled install run, not only the first — "first ledger-enabled run"
above describes when it first fires on an upgraded box, not a once-only
trigger — and the ledger gate itself is amended so a box with any known
builtin enters it (closing the hub-only escape at
`install/airlock-install.sh:31`). For each known-builtin id with no config
entry and no ledger record, expand its manifest `[artifacts]` patterns
against the current environment roots — home, webroot, confd, and both unit
roots — plus rooted anchors, and probe existence read-only via `lstat`. An
id becomes an ADOPTION CANDIDATE (reported with the `--adopt` line and the
list of paths found) iff at least one expanded path exists AND the same
prospective synthetic-intent admission check `--adopt` performs passes; an
id with existing paths that fails admission is reported separately as an
EXCLUSION diagnostic ("overlaps live state — resolve by hand"), never with
a command. One predicate, two call sites: a printed `--adopt` line can
never be refused for a reason detection could see. `airlock-config
known-builtins` is the channel: shipped ids with parseable regular
non-symlink manifests, hub/core excluded, shadowed builtins excluded.)*

**F16 — Container intent, collision, and runtime-proven removal.** A fixture
package declares `containers = ["airlock-t16-*"]`; intent records a fresh nonce,
and its installer creates two Docker-fixture objects carrying the exact package
and nonce labels. Assert: intent is durable before the first create; commit
records the nonce and two full immutable ids; a normal config removal and a
digest-mismatch/path-gone removal each leave exact id and two-label runtime
queries ABSENT before the ledger entry disappears. Repeat from an intent-only
crash after the first create and get the same result before a fresh-nonce retry;
a same-digest reconcile instead reuses and admits exactly the committed set.
Negative controls: (a) a matching name with no labels, one label, different
labels, or the exact package label but another nonce is untouched, blocks
install, and is diagnostic-only during removal; (b) runtime query failure, `rm`
returning zero while the object remains, non-zero `rm` followed by absence, and
immutable-id replacement each fail with the ledger entry retained; (c) an
object with the exact two labels outside the declared namespace blocks commit
but is still removed by nonce-driven teardown; (d) name-filter substring
lookalikes never enter the candidate set; (e) a new same-nonce id appearing
after per-id removal makes the final label-set oracle fail, then remains an
unexpected owned teardown candidate rather than a foreign collision; (f) fake-runtime
arguments plus a real-runtime inventory prove the package did not pull/build an
image or create a named volume/network; (g) the package's smoke loads its own
config in the window between the creates and the commit — this run's own
exact-label objects are admitted there, while a foreign namespace collision
appearing in that same window still blocks with a collision refusal; (h) a
completed removal still converges when the runtime rewords its object-not-found
reply, and an object the runtime still lists is never retired on the strength of
such a reply. The fixture driver is a stateful fake
runtime so it runs in CI; the Notes app acceptance additionally exercises one
real Docker install and asks Docker itself for post-deactivation absence.

## 4. Delivery

Four children, ordered, tracked in the master task doc. Sequencing rule:
**nothing flips to fatal until the built-ins satisfy the contract.** Children 2
and 3 land resolver, ledger, and manifest support behind a legacy fallback
(registry-driven, current behaviour byte-for-byte); child 4 writes the nine
built-in manifests and deactivators, migrates the eighteen scripts to the D5
ABI, then flips enforcement and deletes the registries in the same change. At
no commit on main is the repo in a state where `airlock-install.sh` fails on
the shipped apps.

## 5. Open questions

- **OQ1** Platform-written ingress from a declared port (HA pattern) — adopt in
  a later child or keep app-written fragments indefinitely?
- **OQ2** Should the hub visually label non-built-in packages (Umbrel's
  community badge), or is the operator's explicit config line enough?
- **OQ3** Version/update surface: packages are paths, so "update" is "stage a
  new path and re-run". The ledger records a content digest per install — is
  that enough history, or do we want an explicit lockfile at this layer too? (A
  release layer composing Airlock + packages keeps its own lock regardless.)
- **OQ4** — *decided 2026-08-01: deferred.* Only the owner installs packages in
  phase 1. Personal apps (D7's third audience class — an app a named
  collaborator installs for themselves) stay out of the contract until designed
  separately: they need a per-user gate variant, per-user tile filtering, and a
  site policy key, and the trust model (D4) makes a collaborator-installed
  package a real privilege boundary, not just a visibility question.
