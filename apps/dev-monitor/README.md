# dev-monitor

Per-box observability — CPU, memory, services, scheduled jobs, network, storage, top
processes and recent unit logs — served as a same-origin subpath under the hub at `/monitor/`. No agent, no
`psutil`: the backend reads `/proc` and shells out to `systemctl`/`journalctl`, so it runs
in a minimal container. Observability is visible to the owner and collaborators.

Optionally it also carries an **owner-only message and action console** (`messages = true`,
default off). That half is described below; if you leave it off, everything below is inert.

## Scheduled jobs

The **Cron** tab is the absorbed cron-console: one screen for systemd user/system timers,
the owner's crontab, `/etc/crontab`, `/etc/cron.d`, run-parts directories, and the current
boot's cron journal evidence. Failed, late, unavailable and reboot-unsafe are separate
verdicts; a source that cannot be read stays in `sources[]` and on screen instead of
silently becoming “no jobs”. The collector is part of this backend—there is no sidecar
unit, second port, nginx fragment or separate app package.

When the owner console is enabled, the owner may run, temporarily pause, or resume a
**currently observed user timer**. Every action re-measures the live user-timer allowlist
and uses argv-only `systemctl --user`; system timers and cron files remain read-only.
Writes reuse the existing console boundary (ingress owner identity + nginx-injected proxy
secret + same-origin JSON POST). Pause is `stop`, not `disable`, so a restart restores the
configured schedule. With `messages = false`, scheduled-job health stays visible and its
write controls fail closed with the other owner-only routes.

## The message and action console

The problem it solves: an agent, a cron job or a build finishes something on the box and
you find out when you next happen to look. The console gives those producers one place to
say so, and gives you one place to act on it from a phone.

Two axes, deliberately separated:

- **Messages.** A producer drops a JSON file in a spool. It becomes a *card*. Cards
  coalesce by `group_key` inside a 24h window, so a job that fails hourly is one card with
  a count, not twenty-four notifications. Urgent cards are also delivered to Slack if a
  webhook is configured.
- **Actions.** A card may carry a `recommended_action` — a working directory plus either a
  skill name, a prompt, or an argv list. It does nothing until you approve it. Approving
  derives a canonical plan and hashes it; executing runs that plan in a tmux window you can
  then watch from devterm.

### The storage split (why there are two tables)

An **occurrence** is an immutable ledger row: this event arrived, at this time, with this
payload. A **card** is a mutable projection: read/unread, pinned, archived, dismissed, with
a count of the occurrences behind it. Producers only ever append occurrences; the console
only ever mutates cards. Every state transition happens inside a `BEGIN IMMEDIATE`
transaction with a conditional `UPDATE` plus an audit row, so two clicks racing each other
cannot both win.

### The spool

Maildir-style, at `~/.local/state/airlock/dev-monitor/spool`:

```
spool/tmp/          write here first
spool/new/          hard-link (or rename) here when the file is complete
spool/processing/   the watcher's working area
spool/bad/          rejected payloads, kept for inspection
```

Writing to `tmp/` and only then linking into `new/` is what makes a partially written file
impossible to ingest. See `examples/emit_message.py` for a producer you can copy.

Anything that can write the spool can post a card — treat that as equivalent to console
access. The installer therefore creates a separate system writer identity: it can traverse
the state directory and write only setgid+sticky `tmp/` and `new/`; `processing/`, `bad/`
and the database remain collector-only. nftables permits that UID to use loopback and
rejects every external egress attempt. A boot-enabled system unit reapplies the rule, and
the collector service refuses to start unless that unit is active. Posting is still *not*
equivalent to execution: see [SECURITY.md](../../SECURITY.md).

### Configuration

```toml
[apps.dev-monitor]
backend_port = 19923
messages     = true
# slack_webhook_urgent_env = "DEVMON_SLACK_WEBHOOK_URGENT"   # env NAME, not URL
# slack_webhook_routine_env = "DEVMON_SLACK_WEBHOOK_ROUTINE" # either lane may be empty
# compat_env_path = "/absolute/operator-owned/legacy.env" # temporary producer bridge
# slack_webhook_env = "DEVMON_SLACK_WEBHOOK" # legacy urgent alias; remove by 2026-09-07
# exec_cwd_root     = ""                                # empty = $HOME
# exec_session      = "devmon-exec"
# spool_writer_user  = "airlock-dev-monitor-writer"  # system account name, not UID
# spool_writer_group = "airlock-dev-monitor-writers"
```

The installer creates the collector-only database and the isolated spool described above,
mints a fresh nginx→backend proxy
secret on every real install (a dry run reuses the deployed one and never rewrites an
existing fragment), and writes `~/.config/airlock/dev-monitor.env` (`0600`). Turning
`messages` back off removes that env file, so the console cannot come back on a restart.
When retiring `compat_env_path`, keep its exact path configured for that `messages = false`
install and clear the key only after the generated bridge is gone. Clearing the path first
relinquishes ownership and intentionally leaves the old file untouched rather than risking
deletion of an unrelated file at an untracked path.

Slack webhooks are bearer capabilities to post in their channels, so — like every other
secret in Airlock — they are *named*, not stored. `slack_webhook_urgent_env` and
`slack_webhook_routine_env` hold environment-variable names; the installer resolves them
into separate urgent and routine lanes. Either lane may be unset without disabling cards
or the feed. The old `slack_webhook_env` key is an urgent-only compatibility alias through
2026-09-07; an explicit urgent key wins and any alias use emits a dated warning.

Each lane proves itself without creating routine noise. The 15-minute maintenance pass
adds a direct, already-read probe only when the routine lane has had no success for 24
hours or the urgent lane has had none for seven days. A recent success suppresses the
probe; a failed probe card also suppresses another until the lane's window expires.

An independent five-second watchdog names a configured lane whose delivery is left open
for 30 minutes, whose first terminal delivery fails before any success, whose terminal
deliveries fail twice after the latest success, or whose last success is older than the
probe window plus 25%. It writes one unpinned local incident card and audit marker before
queueing an operational notice on the configured opposite lane. Continuing observations
update that card without turning the five-second poll count into an occurrence count.
Recovery is confirmed only after 24 consecutive successful health evaluations (nominally
two minutes at the five-second cadence). A delayed pass contributes one observation rather
than turning scheduler delay into either recovery evidence or a permanent 15-second cliff.
Fewer healthy evaluations keep the same incident and its pending crossover notice open;
a failure after a confirmed recovery creates a new card immediately without rewriting the
archived card. Crossover publication is best-effort whenever the opposite webhook is
configured, even when that lane's health is degraded. Terminally failed notices can be
attempted again no more often than every 30 minutes across incident cards, while pending,
claimed and sent notices remain deduplicated. Intentionally removing that lane's webhook
is a non-incident observation and can satisfy the same 24-pass recovery confirmation.
A watchdog evaluation exception is written to stderr but is not evidence of either lane
failure or recovery, and it clears partial recovery evidence. Health timestamps are
validated and ordered by one strict, portable SQL predicate shared by every health index
and query; smoke calls that production health function instead of maintaining a second
Python parser. A retained malformed value—including SQLite's permissive
hour-24 and time-only forms—therefore becomes one coalesced `ledger-invalid` incident
instead of throwing every five seconds or poisoning the latest-success boundary. Separately,
`/api/health` reports `unknown` when its own lane-health evaluation fails. An acknowledged
incident can also age through the existing idle sweep if the process stops before seeing
recovery; if the same failure is observed after restart, that swept projection is reopened
with the same card and notice ledger. Dismissing a card hides it from the feed but likewise
does not re-arm the incident; only a later non-incident observation does. An intentionally
empty lane remains a named startup and `/api/health` fact, not an incident. Loss of the
whole generated environment is reported by the out-of-domain watchdog because this process
cannot start its message half.

The `dev-monitor:` prefix is reserved for direct-inserted system card IDs and groups, so
producer payloads cannot collide with watchdog identity in either direction. When
upgrading from the pre-correction cooldown behavior, the strongest existing notice
outcome (`sent`, then claimed/pending, then `failed`) is adopted onto the oldest canonical card;
redundant open deliveries are retired as `superseded` rather than posted again.

Approved actions run in tmux, so the *action* half needs `tmux` — and only that half.
Without it cards, coalescing, Slack and the whole feed work normally, and an approval is
refused immediately with a line in the journal instead of leaving a card that looks like it
is running. It is deliberately not an install prerequisite (that would fail the install of
a monitor whose console is off); the installer and `smoke.sh` both warn instead.

## Credential freshness (`token_freshness = true`, default off)

Nothing on a dev box reads a credential's expiry until something fails. Claude Code
refreshes its OAuth token *reactively*, after an HTTP 401/403; paseo's plan panel caches
for five minutes and re-asks nobody; and no timer anywhere looks at `expiresAt`. So the
first sign that a token died is a job that did not run.

Two halves, both off unless you turn them on, and deliberately switched on separately:

| | what it is | how it is turned on |
|---|---|---|
| the card | `GET /monitor/api/tokens` + a **Credentials** panel on the dashboard | `token_freshness = true` |
| the check | `airlock-token-freshness.timer` (a `--user` timer) | `bash install-token-timer.sh` |

The config key makes the verdict *visible*; the timer makes it *happen*. A standing job on
the operator's box is not something a config default should start, so the installer says so
once instead of doing it.

```toml
[apps.dev-monitor]
token_freshness             = true
# token_freshness_warn_hours  = 24   # claude: warn this long before the refresh deadline
# token_freshness_stale_hours = 24   # codex: warn once last_refresh is this old
```

```
bash apps/dev-monitor/install-token-timer.sh [--oncalendar 'daily'] [--no-messages]
bash apps/dev-monitor/install-token-timer.sh --uninstall
```

**Four verdicts, and `unknown` is not `ok`.** `ok` / `expiring-soon` / `expired` /
`unknown`. A missing or unparseable credentials file is `unknown` and renders as a warning
— a checker that scores an absent file green is worse than no checker.

**Which field is the deadline.** For Claude the access token in `expiresAt` turns over by
itself every few hours, so on its own it is noise; what needs a human is
`refreshTokenExpiresAt`, and that drives the verdict when it is present. Codex's
`auth.json` has no expiry field at all — `tokens.last_refresh` is the only field that
proves the session is still alive, so the codex verdict is an *age* verdict and never
claims `expired`, because staleness cannot prove death.

**It never reads, logs or publishes a token value** — only field presence and timestamps.
`test-backend.py` asserts that against a fixture whose token values are a sentinel string.

**Where the warning goes.** Into the message console that already exists: a run publishes
one `info` card per unhealthy provider to the spool, and the collector's 24-hour coalescing
makes that one card per provider per day whatever the schedule. So this half wants
`messages = true`; without it the timer still writes its snapshot and the dashboard card
still shows the verdict, but nothing pushes — and `install-token-timer.sh` refuses to wire
a timer whose loud channel is absent unless you pass `--no-messages` and mean it.

**A dead checker is visible as staleness, not silence.** Every run writes
`~/.local/state/airlock/dev-monitor/token-freshness.json` whatever the verdict, and the
card shows how old it is (`never`, if the timer has not been wired). The unit also carries
`OnFailure=airlock-token-freshness-failed.service`, which leaves evidence on the box and
posts an urgent card — because a watchdog that dies quietly leaves the card showing its
last verdict, and the last verdict was green.

### Failure behaviour

Nothing here is allowed to take observability down with it. A half-set gate, a corrupt or
locked database, an unwritable state directory: each is logged with its reason, the owner
routes return 404, and the monitor keeps serving. `messages` in the startup banner and in
`GET /monitor/api/health` reports what actually started, not what the config asked for, so
a half-configured install is visible to a script and not only in the boot log.

### Tests

```
python3 backend/test_devmon.py                     # 209 offline checks, no install required
python3 test-backend.py                            # the backend's own half, incl. credential freshness
bash "$AIRLOCK_ROOT"/install/test-token-freshness-timer.sh  # timer templates, substitution, installer refusals
#   (that suite lives in the PLATFORM checkout, not in this package — after the
#    apps/ split there is no ../.. that reaches it)
```

Covers validation, dedup, coalescing, crash recovery, urgency promotion, read≠notified,
sweep, flood detection, lane probes and watchdog crossover, the approval/run state
machine and the Slack outbox.
