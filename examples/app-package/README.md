# External app package example

This directory is a runnable, explicit Airlock package. It starts one
loopback-only Python backend and exposes it at the hub path
`/hello-example/`; the hub's existing identity gate protects the fragment.
An explicit package runs arbitrary bash as the installing operator, including
commands it invokes with `sudo`. Review a package before adding its
`[packages.<id>]` line. Config ABI 2 records the reviewed package tree in the
checkout's `airlock.lock` after the first successful real install. A later byte
change is fatal and names both digests until you deliberately re-lock it;
capability `grant` values, when needed, are a separate acknowledgement.

## Copy and install

From an Airlock checkout, copy this whole directory somewhere outside the
checkout. Change only `owner` in the copied `airlock.toml`; its relative
package path is already correct.

```bash
cp -a examples/app-package "$HOME/hello-example"
$EDITOR "$HOME/hello-example/airlock.toml"
AIRLOCK_CONFIG="$HOME/hello-example/airlock.toml" bash install/airlock-install.sh
```

To preview without changing anything:

```bash
AIRLOCK_DRY_RUN=1 AIRLOCK_CONFIG="$HOME/hello-example/airlock.toml" bash install/airlock-install.sh
```

Explicit-package scripts deliberately do not execute in a dry run; Airlock
prints that it *would* install this package. Run the non-dry command above on
a box with Tailscale and nginx ready to install the unit, fragment, and
backend. Then open `https://<your-box>/hello-example/` as the owner.

[`acceptance.sh`](acceptance.sh) drives the full install → rerun → locked
upgrade → remove cycle against this example and asserts each step, for use on a
disposable box. [`ACCEPTANCE.md`](ACCEPTANCE.md) is the earlier 21-check
transcript; current live verification requires 25 checks, adding exact lock
recording, byte-stable rerun, mismatch refusal, and deliberate re-lock evidence.

## What the manifest must say

`package/airlock-app.toml` has the two required identity fields:
`contract = 1` and an `id` that exactly matches both
`[apps.hello-example]` and `[packages.hello-example]`. It declares
`backend_port` before the scripts read it, and declares every file the
installer creates outside the package: the user unit and hub fragment.

Add `[config]` entries for every app setting your scripts read, and declare
every externally-created unit, fragment, webroot path, file, served port, or
rooted artifact in `[artifacts]`. The complete schema and special cases are in
the [app package contract](../../docs/design/app-package-contract.md); do not
invent fields that Airlock does not validate.

`install.sh` and `smoke.sh` must be regular, non-symlink files. `deactivate.sh`
is optional, but omitting it makes config-only removal refuse: use the explicit
teardown command Airlock reports instead. This example includes one; the
ledger removes its declared unit and fragment after the hook runs.

## D5 lifecycle ABI

Airlock runs each lifecycle script from the canonical package directory and
sets these variables:

- `AIRLOCK_ROOT`: the Airlock checkout; source `$AIRLOCK_ROOT/install/lib.sh`.
- `AIRLOCK_APP_DIR`: the canonical package root; locate package-local files here.
- `AIRLOCK_APP_ID`: the package id.

Do not calculate the platform root by walking up from `$0`: an explicit
package can live anywhere. The example locates Airlock and its own files only
through this ABI, then uses the helpers loaded from `install/lib.sh`.

## Lifecycle promises

- **Install:** Airlock validates, journals the declared ownership, runs
  `install.sh`, reloads the gate, then runs `smoke.sh` before committing.
- **Rerun:** `install.sh` runs again, so make writes idempotent. This example
  rewrites the unit/fragment only when changed and restarts the backend only
  when its unit changed.
- **Upgrade:** stage changed package bytes or a new package path, then run the
  same install command. Because this example has `deactivate.sh`, Airlock
  removes its recorded unit and fragment before installing the new version.
  A package without a deactivator instead uses the record-diff path, which
  removes only old declared artifacts the new package no longer owns.
- **Remove:** remove both `hello-example` tables from `airlock.toml`, then run
  the same install command. Airlock runs `deactivate.sh` when it can trust it,
  removes ledger-recorded artifacts, and keeps app data that was never declared.

## A real manifest error

This was produced by copying this example, changing its unit declaration to
`units = ["../not-a-unit.service"]`, and running:

```bash
AIRLOCK_CONFIG="$HOME/hello-example/airlock.toml" python3 bin/airlock-config validate
```

```text
airlock-config: package 'hello-example': artifacts.units entry '../not-a-unit.service' must be a bare unit file name ending in one of ['.service', '.socket', '.timer', '.path', '.target'] (and not option-like, and not a glob — '*', '?', '[' are fatal here) — anything else could resolve outside the unit directories or confuse systemctl
```

The error names `artifacts.units` and the bad value instead of silently
accepting a path that could escape the unit directory.
