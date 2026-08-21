# live — one full install on a box that has never seen airlock

CI cannot verify this project. On 2026-08-07 six full-tree installs on a real
8 GiB container turned up six defects and CI had caught **none** of them: a
`set -e` leak that silenced nine smokes, discarded npm output, a snap node missing
from the unit PATH, a `| grep -q` SIGPIPE that failed only when the thing *was*
there, a backtick executing inside a heredoc, and `NoNewPrivileges` against a snap
wrapper. A GitHub runner has no snapd, no lingering user session, and no real
nginx or sudo — none of those shapes can exist there.

So the claim "nine apps install and pass their gates on a fresh box" is only worth
what its last measurement is worth, and this directory is the measurement.

```
live/
  verify.sh        the host side: create → deliver → run → record → publish → delete
  in-container.sh  the payload: everything that touches the repository's code
  mkresult.py      assembles the durable local record
  mkcomment.py     redacts it into what gets published
```

## Two rules that shape the design

**Repository code never runs on the host.** The airlock lifecycle runs arbitrary
bash and `sudo` by contract (`SECURITY.md`). `verify.sh` does container lifecycle
and payload delivery; `in-container.sh` and everything it calls run inside a
container that is destroyed afterwards.

**Result before cleanup.** The durable record is written as soon as the container
has finished — before deletion, before publishing. A run that dies during teardown
has still recorded what it found.

## Running it

Nothing site-specific is committed here. This tree is mirrored to a public
repository and a hostname in it is a leak, so every local fact arrives through the
environment:

```bash
export AIRLOCK_LIVE_SSH=<ssh destination that can reach lxc non-interactively>
export AIRLOCK_LIVE_OWNER=<the identity the gate will accept>
export AIRLOCK_LIVE_TSKEY_FILE=~/.config/airlock-live/tskey   # mode 600
export AIRLOCK_LIVE_TAG=tag:ci
export AIRLOCK_LIVE_POOL=<storage pool>
export AIRLOCK_LIVE_ISSUE=<tracking issue number>             # for --publish gh

bash live/verify.sh
```

Set `AIRLOCK_LIVE_DEVMON_MESSAGES=true` to exercise the supported configuration
where the message console is on and neither Slack webhook exists.  The durable
record then contains the effective health states, a zero watchdog snapshot after
the measured soak, and two same-database controls through the production watchdog
entrypoint. A pre-aged open delivery must remain 0/0/0 while both lanes are intentionally
off, then must become +1/+1/+1 when the same lanes are configured. This makes the
off-to-ledger fall-through defect observable immediately instead of asking a 120-second
zero to speak about a 1,800-second threshold. The verdict fails if the request, effective
state, measured elapsed time, zero observation, off-branch discriminator, or configured
positive control disagree.
The natural zero is running-service telemetry, not evidence against the 1,800-second
fall-through defect; the pre-aged off-branch delta is that discriminator.
This mode requires a soak of at least 120 seconds.

Set `AIRLOCK_LIVE_EVIDENCE_DIR` to have the runner itself write an allowlisted
`<run-id>.public.json` after cleanup. The public projection preserves the collector's key
names verbatim and excludes execution identities, logs, credentials, and any hash of an
untracked local record.
Its reproduction is explicitly host-local: the operator supplies the untracked environment
and the exact image fingerprint must already be cached on that environment's LXD host. The
command checks that prerequisite and the exact checked-out commit before launching.
`result.verdict` is recomputed from the full local record; the public projection omits some
verdict inputs and therefore cannot independently derive it.

The auth key is read from a mode-600 file and pushed over stdin into another
mode-600 file inside the container, which deletes it the moment it has been used.
It never appears in argv, in the host's process table, or in the container's. The
script refuses to start if the file is more permissive than 600.

It also refuses to start on a dirty working tree. The payload is `git archive` of
an exact commit, and a result recorded against a SHA that is not what ran is a
false attestation, not a rounding error. `AIRLOCK_LIVE_ALLOW_DIRTY=1` overrides it
and says so in the record.

## The exit code

```
0   installed, every gate passed, ingress checked from the box itself
3   installed, every gate passed, ingress COULD NOT be checked from here
1   something failed
```

`3` is `bin/airlock-smoke`'s own distinction (`:9-19`) and is carried through
rather than flattened. A caller that tests `!= 0` records unverified ingress as
verified — which is the whole reason that exit code exists.

## What the record contains, and why each field is there

| field | why |
|---|---|
| `commit` | the payload was `git archive` of exactly this |
| `image_fingerprint` | `ubuntu:24.04` is a moving target; two runs are only comparable if both name the build |
| `stage` | `never_started` / `ran` / `published` / `publish_failed` are different facts and the weekly watcher needs to tell them apart |
| `units_early` and `units_late` | two readings with a soak between. "Responds once, then crash-loops" is exactly what paseo did on 2026-08-07; one reading taken right after the install would have called it a pass |
| `NRestarts`, `ExecMainStatus` | recorded, not asserted, for orca — its unit execs an extracted AppImage `AppRun` and Electron ships a setuid `chrome-sandbox`, so its passing is observed rather than proven |
| `smoke_rc` | as 0/1/3, never as a boolean |
| `smoke_lines` | the item list, because `bin/airlock-smoke` excludes hub from its own count and a bare fraction hides which convention it used |
| `cleanup_ok` | `null` means teardown was never reached; `false` means a container is still running somewhere |
| `dev_monitor_messages_requested`, `inner.devmon_no_webhook` | requested/effective messages-on state, monotonic measured soak, natural zero telemetry, pre-aged off-branch discriminator, and configured same-path positive control |

## Publishing

The published comment is **redacted**: the tailnet FQDN and the ssh destination are
removed from every string, not just from the fields that hold them — they appear
inside smoke lines too. `verify.sh` then greps the rendered comment for the FQDN
and refuses to post if it survived, because the guard that keeps internal names out
of the public mirror is a scan over the tree and does not see issue comments.

It goes to a comment on a tracking issue rather than to a branch, because a push to
any branch runs CI and CI's leak guard would fail on a result containing a tailnet
name. Issues do not trigger it.

Publishing is its own failure domain. If the run succeeds but the comment cannot be
posted, `PUBLISH-FAILING` is written next to the results and the stage is recorded
as `publish_failed` — because the thing that would normally carry the alarm is the
thing that just failed.

## What this cannot close

**Ingress.** The smoke says so itself: a request sent to the box's own tailnet name
never leaves the box, so "the gate works" and "the gate is reachable from outside"
are different claims. Closing the second one needs a human opening the URL from a
phone once. No amount of harness fixes that, and pretending otherwise is how a
skipped check becomes indistinguishable from a passing one.

**The `AIRLOCK_ALLOW_SNAP_NODE` path.** Now that the manifests prescribe a non-snap
node, a normal run never reaches the override, so it is exercised only by fixtures
in `install/test-snap-node.sh`. A second variant that installs a snap node on
purpose would close it; it has not been built, because it has not been worth the
cost yet.
