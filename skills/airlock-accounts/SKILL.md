---
name: airlock-accounts
description: Restore a Claude account-pool login on an Airlock box when the active account is wrong, expired, missing, or cannot be switched. Use without printing credential material.
---

# airlock-accounts

`airlock-accounts` keeps named Claude OAuth slots and safely switches the live
Claude credential. A slot name is the identity returned by login (for example,
an email plus personal/team kind), not a nickname. Never copy or edit credential
files by hand.

## 1. Inspect the pool and the live login

Run as the box user that runs Claude/DevTerm.

```bash
ROOT="$(git -C /path/to/airlock rev-parse --show-toplevel)"
"$ROOT/bin/airlock-accounts" list --usage
"$ROOT/bin/airlock-accounts-status" login-state --json
```

`list` reveals no tokens. It reports the active slot, access-token state,
refresh-token expiry, and (when available) 5-hour/7-day utilization. A usage
API `429` is a read-only probe throttle, not proof that the account is spent.

Use the result to choose one path:

- The desired slot is present and its refresh token is valid: switch it.
- The desired slot is absent, or marked dead because its refresh token expired:
  re-login it.
- The live Claude login works but is not yet in the pool: add it once.
- `login-state --json` says Codex is unavailable: use Codex's normal login flow;
  do not put its credentials into the Claude account pool. For xAI, inspect it
  separately with `"$ROOT/bin/airlock-accounts-status" --xai` and use that
  provider's normal login flow.

## 2. Switch to a healthy pooled account

Copy the exact account name from `list` and use `swap`. It saves back rotated
credentials before replacing the live credential, and it refreshes a
near-expiry access token when possible.

```bash
"$ROOT/bin/airlock-accounts" swap '<account name from list>'
"$ROOT/bin/airlock-accounts" list
```

For an interactive terminal where resuming the previous conversation is wanted,
use `to '<account name>'` instead; it switches and launches `claude --continue`.

If the command says the account does not exist, return to section 3. If refresh
fails and the access token is expired, the account requires a browser re-login;
retrying `swap` will not revive it.

## 3. Re-login or seed the pool

For a browser re-login, prefer the DevTerm account popup: its return-code path
passes the one-time value to `airlock-accounts login-code` over protected stdin,
never process argv or an environment variable. Do **not** run
`login-code '<code>#<state>'` manually: the CLI rejects argv input. The DevTerm
popup is the supported approval-code path.

After the isolated-session re-login completes, verify and explicitly select the
returned slot:

```bash
"$ROOT/bin/airlock-accounts" list
"$ROOT/bin/airlock-accounts" swap '<account name from list>'
"$ROOT/bin/airlock-accounts" list
```

The re-login only renews the live credential automatically when the CLI can
prove the live identity is the same. If the UI/CLI warned that it could not
identify live, or the failed action persists, the explicit `swap` above is
required before retrying.

If an already-working live Claude login is simply missing from the pool:

```bash
"$ROOT/bin/airlock-accounts" add
"$ROOT/bin/airlock-accounts" list
```

Run `"$ROOT/bin/airlock-accounts" login`, complete `/login` in its isolated
session, then `/exit`. It stores the result without changing the live account
unless the pool was empty; follow it with the explicit `list` and `swap`
sequence above.

On a first-run Claude terminal, the isolated session can show a text-style
chooser before it accepts commands. Select a style; it may then show **Select
login method**. For a Claude account-pool re-login, choose **Claude account
with subscription**, which prints the browser URL. These choices only finish
terminal/login-method setup and are not the account-login approval. Stop at the
printed browser URL for the account owner's approval. Do not paste a returned
code into a shell command; use the DevTerm account popup.

## 4. Verify and avoid destructive cleanup

After a switch or re-login, run the two commands in section 1 and retry the
failed Claude action. If DevTerm alone still shows stale status, inspect its
user service before changing credentials:

```bash
systemctl --user status airlock-devterm-gate --no-pager
```

`prune --yes` and `remove <name> --yes` delete pool slots. They are not normal
login recovery: leave dead slots in place unless the operator explicitly wants
them removed, and never remove the active slot. A cancelled subscription can
look token-healthy, so preserve the `list` output and escalate if re-login
succeeds but the provider still rejects the account.
