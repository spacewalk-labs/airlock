# Trust and capability contract

Status: **accepted 2026-08-08 (owner); built 2026-08-13.** This records a decision and the
reasoning behind it. The task documents that implemented it were retired from `active/` when
the last card landed; what each one delivered, and what it deliberately left undone, is in
the project's internal task board, which is not part of this repository.

Built through the RETIRE_RECORD stage (2026-08-13): the in-tree bundle entitlement table
(`BUNDLE_ENTITLEMENTS`), one admission decision (`_bundle_admission`), the enumerated vocabulary
(`GRANTABLE_CAPABILITIES`, `BUNDLE_CERTIFICATIONS`, `CAPABILITY_SCHEMA_VERSION`) — all in
`bin/airlock-config` — the `system-unit` gate, the ABI 2 operator surface (`grant` in
`[packages.X]` and `airlock.lock`), and ledger store v5 carrying record `capabilities` plus the
append-only package-lock override event list, plus the independent plaintext retirement sidecar
described in §7. Record shapes and capability meanings remain the v4 contract. **Not built:**
the separate policy and implementation that would make `plaintext-redirect` grantable. The
sections below keep the reasoning as it was written and mark where the tree has since moved
past it.

Supersedes nothing. It extends the app package contract
([`app-package-contract.md`](app-package-contract.md)) at exactly one point: what decides
which privileged capabilities a package may use. D1 (packages are local paths), D4 (trust is
explicit, not sandboxed) and the SECURITY.md invariants are unchanged and constrain this.

---

## 1. Why

`source_class` is decided by **file location**: a directory sitting directly under
`<repo>/apps/<id>`, not a symlink, `realpath`-matching, is `shipped`; everything else is
`explicit` (the shipped-detection loop in `package_specs` in `bin/airlock-config`, which requires
the real path to sit directly under `shipped_root_real`). Two capabilities were `shipped`-only:

| Capability | Gate as written | Who uses it |
|---|---|---|
| `artifacts.rooted` | `source_class == "shipped"`, checked at admission | orca — `/etc/airlock/orca-loopback.nft`, `${webroot_parent}/orca-web/` |
| `plaintext_redirect` | `source_class == "shipped"`, checked at admission | devterm — `public_port → redirect_port` |

Since #119 neither gate is a `source_class` comparison. `_parse_manifest_spec` in
`bin/airlock-config` collects what the manifest requests and `_bundle_admission` answers it from
`BUNDLE_ENTITLEMENTS` (`orca: rooted-artifact, system-unit`; `devterm: plaintext-redirect`); the
refusal messages stay in `_parse_manifest_spec`. Location now decides only whether a package is
the canonical bundle principal — which is the same fact, named honestly.

Location is a real attestation, not a mistake: trust cannot be self-declared, and "it arrived
inside this git tree" is something a package cannot forge (the symlink exclusion and realpath
comparison exist for that). Homebrew core-vs-tap and Debian main-vs-contrib use the same axis.

It stops working for three reasons, all of which the store makes load-bearing:

1. **Two tiers, one blessed root.** `AIRLOCK_SHIPPED_APPS_ROOT` is read in `bin/airlock-config`
   but set only by `install/test-*.sh` — it is a test hook, not a policy surface. Production has
   one root.
2. **"Who vouches" and "what it may do" are the same bit.** Needing a capability forces a
   package into this repo, so a distribution mechanic decides a security policy.
3. **The operator cannot express trust at all.** `CLOSED_SECTIONS` is
   `site`/`auth`/`paths`/`branding` (`CLOSED_SECTIONS` in `bin/airlock-config`); `[auth]` is about *people*,
   not code sources.

A store distributes packages as downloads. A download lands outside `apps/` by definition, so
it is `explicit` by definition, so devterm and orca cannot be store-distributed. Measured, by
forcing each of the four apps the owner named as public through the validator as an explicit
package: devterm and orca are fatal, **markwand and paseo are `ok: config valid`**.

---

## 2. What this is not

> An admitted package's `install.sh` runs arbitrary bash as the operator, including sudo (D4).
> A package that is admitted at all can therefore edit config, write system files and bind
> ports directly. **This contract is admission control, not containment.** It stops mistakes
> and over-reach by honest packages and it leaves an auditable record of what was authorised.
> It does not stop a malicious package.

This paragraph goes into SECURITY.md verbatim. Snap is honest in the same place —
`snap install --dangerous` always works, because Canonical did not try to stop the owner of
the machine; they made the unvetted path explicit, differently named, and impossible to reach
by accident. Writing a gate without writing this sentence sells a wall that is a doorway.

Containment would mean removing sudo from lifecycle scripts and brokering privileged
operations through a root-owned mediator. That reverses D4 and is a different project.

---

## 3. Decision — identity is a recorded digest, not a signature

**Owner decision, 2026-08-08: digest lock first; signing deferred.**

The store client fetches; the core does not (D1). The naive fix — have the client record where
it fetched from — moves the forgery rather than preventing it: the client, the config, the
package tree and the ledger are all owned by the same unix user, so "came from index X"
becomes an arbitrary byte string the moment it is stored. Two independent surveys of iOS,
Snap, Flatpak, APT, Homebrew, polkit, npm, Nix, Home Assistant, WordPress, Firefox and
Terraform reached the same sentence:

> The answer that actually works is that the verifier performs its own cryptographic check
> over bytes it holds, against a pre-trusted root. The fetcher's *record* is not a separate
> object of trust.

Signing is the strong form of that. We are taking the cheap form first, which Terraform states
plainly: *"this checksum verification is intended to represent a trust on first use
approach"* — the signature bootstraps, the lock holds.

**What a digest lock proves:** the tree admitted today is byte-identical to the tree the
operator admitted the first time. **What it does not prove:** who wrote it. Provenance of
authorship needs signatures and is deferred, not rejected — §8 records what it would take.

Why this order:

- No key management, rotation, revocation or expiry. The Firefox *Armagadd-on 2.0* outage
  (2019-05-04: an intermediate certificate expired and every add-on on earth was disabled
  simultaneously, no attacker involved, recovery dependent on a channel that did not itself
  require a valid signature) is a class of failure a lock cannot have.
- The signature-envelope problem disappears. With signatures we would have to decide the
  envelope format before we could distinguish "unpinned signer" from "pinned signer, broken
  signature" — and a signer identity read out of an unverified blob is untrusted input, so
  branching on it before verification is a fail-open.
- The ledger already computes a SHA-256 tree digest per install for change detection. The lock
  reuses an existing fact rather than introducing a second one.

---

## 4. Decision — grants are per package, and are an acknowledgement

**Owner decision, 2026-08-08: state plainly that the grant is a confirmation step, not a
security boundary.**

Per package, not per source. The trap is named in the surveys — *whole-repo trust that
auto-approves future packages*. Snap does not do this: a reviewer issues a `snap-declaration`
for **that snap**, and the user additionally types `--classic` at install time. Granting a
publisher once, and thereby granting every future package they ship, is a blank cheque.

And honestly labelled. `AIRLOCK_CONFIG` is resolved by existence alone — there is no owner,
mode or writer check in `find_config` in `bin/airlock-config` — and a future store client would run as
the same unix user, so nothing stops it writing the grant line along with the path. polkit
lived this future already: LWN's verdict on it is that *the policy is effectively hard-coded
for most users*, because a brokered capability model degrades to a consent dialog when nobody
authors policy. So:

> A grant is the operator acknowledging what a package will be allowed to do. It is not a
> boundary against an actor who can already write this file.

It still earns its place: it catches accidents and silent scope growth, and it makes
"what did we authorise" answerable after the fact.

---

## 5. The shape

```toml
# airlock.toml — human-written
[packages.hello]
path  = "./store/hello/payload"
grant = ["rooted-artifact"]          # declared capabilities this package may use
```

```toml
# airlock.lock — machine-written at first admission, reviewed by a human in diff
[hello]
digest = "sha256:…"
```

Admission, per package:

1. Compute the tree digest.
2. No lock entry → first use. Record it. (Trust on first use; this is the weak moment and the
   contract says so.)
3. Lock entry present and matching → proceed.
4. Lock entry present and **not** matching → **fatal**, naming the package and both digests,
   and saying that re-approval means updating the lock deliberately.
5. Declared capabilities ⊄ `grant` → **fatal**. This is the successor to today's
   `"only to shipped"` message.

Two files on purpose: the lock is machine-written and belongs in a diff, the grant is human.
Mixing them makes it impossible to see which lines a tool wrote.

### Built-in apps do not use this surface

Adding `[packages.orca]` to point at a built-in makes it `explicit` — an explicit `[packages.X]`
suppresses shipped detection in `package_specs` in `bin/airlock-config` — and orca's `rooted`
declaration then becomes fatal, because `_bundle_admission` hands out a bundle entitlement only
to the canonical direct child of the bundle root. Attaching entitlements to built-ins through
`[packages.X]` therefore breaks them.

The nine bundled apps get their entitlements from an **in-tree table that is not operator
editable**, keyed by app id, and shipped detection is untouched. This table had to land before
any new gate, for the reason in §6.

**It has.** `BUNDLE_ENTITLEMENTS` in `bin/airlock-config` is that table, with no env or file
override, and `_assert_bundle_policy_parity` requires it to match `apps/` exactly in both
directions — a tenth bundled app added without a reviewed entry fails parity instead of
inheriting privilege.

---

## 6. Capabilities are enumerated, and one is missing today

A closed vocabulary. No wildcards: a wildcard silently grants every capability added later.

**Elevated — requires a grant (or a bundle entitlement):**

| Capability | Trigger | When this was written | Now |
|---|---|---|---|
| `rooted-artifact` | `artifacts.rooted` non-empty | `shipped`-only | entitlement lookup in `_bundle_admission`; in `GRANTABLE_CAPABILITIES`, but no operator surface exists yet to grant from |
| `plaintext-redirect` | `[plaintext_redirect]` present | `shipped`-only | entitlement lookup; deliberately **not** grantable — the reason is in §7 |
| `system-unit` | any `artifacts.units` entry with `scope = "system"` | **no gate at all** | refused at admission unless admitted, and claimed in the ledger record |

`system-unit` was new here. At the time only two `source_class` gates existed in
`bin/airlock-config`; `scope = "system"` was checked for legality in `_validate_artifacts` and
then expanded into `/etc/systemd/system` through `_artifact_roots`' `unit_system` root, with
teardown running `sudo systemctl disable` and `sudo rm` in `_teardown_unit` in
`bin/airlock-ledger`. A third-party package could plant a root-owned system unit with nothing
standing in the way — heavier than `rooted`, and ungated.

**#119 closed it.** `_parse_manifest_spec` adds `system-unit` to the requested set for any
`scope = "system"` unit and dies when `_bundle_admission` does not admit it. The v4-compatible
record shape records the claim, and `_require_system_unit_scope_claim`, `_committed_artifacts` and `_teardown_unit` in
`bin/airlock-ledger` refuse to record, commit or tear down a system unit that no claim stands
behind. There are no `source_class` authorisation gates left in `bin/airlock-config` at all — the
field survives there as provenance only.

**It was not free to add.** `apps/orca/airlock-app.toml` declares
`{ name = "airlock-orca-firewall.service", scope = "system" }` in its `[artifacts].units`, and the
nft section of `apps/orca/install.sh` really writes it and runs `sudo systemctl enable --now`.
Gating `system-unit` before the bundle entitlement table existed would have broken orca. Hence
the ordering in §5 — and the two landed in the same change.

**Not made grantable:**

- `dry-run-exec` (then: shipped-only, decided by the `_dry_certified` branch in
  `install/airlock-install.sh`). This is a *certification* fact, not a trust fact — the child-4
  migration certified nine apps' `AIRLOCK_DRY_RUN` discipline in this repo's CI. A vendor
  endorsement does not demonstrate that discipline. Terraform is the cautionary case:
  `terraform plan` executes provider code, and Snyk obtained reverse shells from a read-only
  speculative plan. #119 wrote the distinction into the code: `dry-run-exec` is a member of
  `BUNDLE_CERTIFICATIONS` in `bin/airlock-config`, a set disjoint from `GRANTABLE_CAPABILITIES`,
  and `_dry_certified` now reads the derived certification out of package-info instead of
  re-deciding by origin.
- strict config-read lint (the `AIRLOCK_STRICT_CONFIG_SCAN` gate in `cmd_validate` in
  `bin/airlock-config`) — CI on our own code. It is the other member of `BUNDLE_CERTIFICATIONS`,
  as `strict-config-scan`.
- `--adopt` — presupposes an in-tree manifest.

**Baseline is not the same as safe.** Every admitted package already gets `lifecycle` (arbitrary
bash and sudo), user-owned artifacts including **absolute paths** that teardown removes
recursively (the `artifacts.files` path-syntax check in `_validate_artifacts` in
`bin/airlock-config`, the `files` expansion in `expand_declared` and the removal in
`_remove_artifact_path` in `bin/airlock-ledger`), a persistent user
unit, an nginx fragment inside the gated server that the orchestrator validates and reloads
with sudo, and a `tailscale serve` mapping. The vocabulary is a list of things the platform
mediates on a package's behalf. It is not an OS privilege taxonomy. Narrowing the permitted
roots for `artifacts.files` is worth its own design and is out of scope here.

---

## 7. Consequences that are not obvious

**This is a config ABI change, and it must be versioned as one.** `_validate_shape` in
`bin/airlock-config` rejects any top-level section it does not know (`known` is
`CLOSED_SECTIONS | {apps, packages}`), and the unknown-key check in `package_specs` rejects every
`[packages.X]` key but `path`. Both are still exactly that. A config carrying `grant`, or an `airlock.lock`, is not
readable by today's core. The migration error an old core produces is part of the design, not
an afterthought.

**Capability derivation was not in one place.** When this was written `source_class` appeared 55
times across `bin/airlock-config` (10), `bin/airlock-ledger` (43) and
`install/airlock-install.sh` (2), and the decision was remade at admission, package-info
validation, intent expansion, stored-record validation, teardown, dry-run policy, the
known-builtin path and the plaintext default scan. A fixture that passes a normal install proves
nothing about adopt, ledger repair, removal, stale-port sweep or dry-run. The work computes an
effective-capability result once and makes every other path consume it; the completion criteria
are per-path negative tests, not a grep.

**#119 did that.** `_bundle_admission` is the one admission decision; the later paths consume the
`capabilities` and `certifications` it produced, off the spec and off the ledger record.
`source_class` remains as provenance only, on 6 lines in `bin/airlock-config`, 22 in
`bin/airlock-ledger` (including the two version-3 historical rooted assertions) and 1 in
`install/airlock-install.sh` — a comment saying provenance is not authorization. Deletion was
never the target: taking `source_class` out of the store record rather than demoting it to an
input would require another store-schema change.

**The retirement substrate is separate from the ledger.** `plaintext_redirect` remains
shipped-only: `_parse_manifest_spec` still refuses it for explicit packages and
`plaintext-redirect` remains outside `GRANTABLE_CAPABILITIES`. This work opens the retirement
precondition, not the grant.

The measured failure is stronger than “the ledger was lost.” Today's ledger never records a
`plaintext_redirect` pair, so removing config and payload already makes a custom public port
unknowable even while `app-ledger.json` is healthy. Adding the pair to a future ledger would
still be insufficient: `_read_ledger` treats a missing file as valid empty state and a corrupt
file as fatal. `_shipped_plaintext_redirect_defaults` only recovers a still-in-tree shipped
manifest's default. A diagnostic-only design cannot manufacture the missing ownership fact;
listing every live plaintext Tailscale listener would conflate operator mappings with Airlock
mappings and still could not say which one to remove.

The chosen substrate is `<state>/plaintext-retirement.json`, owned independently of
`app-ledger.json`. It stores only `package`, `listen`, `target`, and a two-state ownership
protocol:

1. `cmd_plaintext_retirement_record` atomically writes and syncs an `intent` before the
   orchestrator invokes the persistent `tailscale serve --bg --http` mutation.
2. Only after that exact mutation succeeds does `cmd_plaintext_retirement_commit` promote the
   row to `committed`. An abandoned intent names the package and port in a fatal diagnostic but
   is never automatic removal authority; this prevents a failed mapping attempt from claiming
   an operator-owned listener already using the port.
3. Only committed rows feed `cmd_plaintext_known` and `ts_stale_plaintext_ports`. A failed
   `tailscale serve ... off` retains the row for retry. A successful off drops it; a confirmed
   already-absent mapping also clears it. Thus the record is an outstanding cleanup
   responsibility, not a permanent reservation that could later seize an operator's reuse.

Every sidecar mutation shares the orchestrator's `app-ledger.lock`, including the directly
dispatchable manual drop command. A sidecar-only box also enters that whole-run lock. Thus
manual recovery cannot erase an intent between the persistent mapping mutation and its
ownership commit.

The sidecar has a closed versioned shape, rejects symlinks and malformed data, and treats
corruption as fatal. Its atomic writer has the same two-stage durability boundary as
`cmd_lock_finalize`: file sync and a pre-replace directory barrier precede the commit point;
post-replace directory-sync failure is a loud committed success. When the ledger is corrupt,
its existing fatal diagnostic appends any sidecar package/port facts so manual recovery knows
what plaintext listeners to verify. Losing both independent stores remains unrecoverable by
definition; this contract is specifically the required survival of ledger loss.

orca has no equivalent retirement precondition: `rooted-artifact` is a pure trust question.

**A hard gate needs a way back.** Armagadd-on's recovery depended on a channel that did not
itself require a valid signature. A lock has no expiry, but a digest mismatch on a package the
box needs is the same shape of outage. The escape hatch is
`--dangerously-admit-unverified=<package-id>`: explicit, differently named, and unreachable by
accident — Snap's `--dangerous`, not a flag that looks like a retry. Naming one configured
explicit package prevents a global bypass; the install log and ledger retain the exceptional
admission. An environment variable is deliberately not an alias because an exported value
would persist into later invocations and silently make the exception ambient.

---

## 8. Deferred, with what it would take

- **Signatures.** Adds authorship provenance, which a lock cannot give. Requires an envelope
  format binding package id, tree digest, signer identity and capability vocabulary version;
  a pinned-key surface; and a revocation story. Note from the surveys: the signer must be the
  **author**, not the index. Firefox has Mozilla hold the key and got Armagadd-on; WordPress
  has no signing and got the ACF takeover, where the channel operator pushed its own fork to
  every installation over a governance dispute. Whoever operates the update channel holds a
  standing arbitrary-code-push capability unless the author signs.
- **Transparency log provenance** (npm/Sigstore). Overkill with no index and zero external
  packages.
- **Per-collaborator (personal) apps.** Still OQ4.
- **Narrowed roots for `artifacts.files`.** Own design.
- **Containment.** §2.

---

## 9. Rejected

| Rejected | Why |
|---|---|
| Record the fetch source (index identity) in the ledger and trust it | Same unix user writes the ledger; the record is forgeable. Moves the forgery, does not remove it |
| A tier enum (`tier = "vendor"`) instead of enumerated capabilities | A tier that gains a member silently widens every holder's authority |
| Per-signer or per-source blanket grants | Auto-approves every future package from that source. Snap grants per snap |
| Capability wildcards | Retroactive grant of capabilities added later |
| Making `dry-run-exec`, strict lint or `--adopt` grantable | Certification facts, not trust facts (§6) |
| Adding manifest keys / bumping `contract` | The surface is operator config, not the package manifest. The config ABI bump is real and separate (§7) |
| Caching verification results between processes | A second source of truth for a fact that is cheap to recompute |
| Transport metadata (URLs) in the ledger "for display" | An unverifiable field produces false confidence |
| Promoting a package to `shipped` by placing it under `apps/` | Third-party `install.sh` would then execute during dry run (the `_dry_certified` branch in `install/airlock-install.sh`). Since #119 it does not get that far: `_assert_bundle_policy_parity` refuses any directory under `apps/` with no reviewed entitlement-table entry |
| Splitting the shared goldens per app so new apps can land in parallel | Treats the symptom. Keeping new apps out of `apps/` removes the cause |
