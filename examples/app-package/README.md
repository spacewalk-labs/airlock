# External app package example

This directory is a runnable, explicit Airlock package. It starts one
loopback-only Python backend and exposes it at the hub path
`/hello-example/`; the hub's existing identity gate protects the fragment.
An explicit package runs arbitrary bash as the installing operator, including
commands it invokes with `sudo`. Review the package before applying it. The
package manifest describes its settings and owned artifacts; installing a
local package does not require registering its path in `airlock.toml`.

## Copy and install

From an Airlock checkout, copy this whole directory somewhere outside the
checkout. Change only `owner` in the copied `airlock.toml`.

```bash
cp -a examples/app-package "$HOME/hello-example"
$EDITOR "$HOME/hello-example/airlock.toml"
AIRLOCK_CONFIG="$HOME/hello-example/airlock.toml" \
  python3 bin/airlock-ledger apply hello-example --source "$HOME/hello-example/package"
```

The source argument must be the absolute package directory containing
`airlock-app.toml` and `install.sh`. The ledger runs the package install hook,
applies its declared ingress, refreshes the nginx site and Hub manifest, and
records the source and artifacts. Open
`https://<your-box>/hello-example/` as the configured owner.

To reinstall or update, change the copied package and run the same `apply`
command with the same package directory. To remove it, run:

```bash
AIRLOCK_CONFIG="$HOME/hello-example/airlock.toml" \
  python3 bin/airlock-ledger remove hello-example
```

Removal uses the artifacts recorded for the app and refreshes the projections;
it does not run `deactivate.sh`. Keep the `[apps.hello-example]` table if you
want to preserve its configured values for a later apply.

[`acceptance.sh`](acceptance.sh) drives the full apply → rerun → update → remove
cycle against this example on a disposable box. [`ACCEPTANCE.md`](ACCEPTANCE.md)
is an earlier transcript of the retired installer and digest-lock flow; its
installer, path-registration, and lock checks are historical.

## What the manifest must say

`package/airlock-app.toml` has the two required identity fields:
`contract = 1` and an `id` that matches both the `[apps.hello-example]` table
and the id passed to `airlock-ledger`. It declares `backend_port` before the
scripts read it, and declares every file the package creates outside its
directory: the user unit and hub fragment.

Add `[config]` entries for every app setting your scripts read, and declare
every externally-created unit, fragment, webroot path, file, served port, or
rooted artifact in `[artifacts]`. The complete schema and special cases are in
the [app package contract](../../docs/design/app-package-contract.md); do not
invent fields that Airlock does not validate.

`install.sh` and `smoke.sh` must be regular, non-symlink files. The manifest
parser also recognizes an optional `deactivate.sh`, but the ledger's `remove`
command removes recorded artifacts without running it.

## D5 lifecycle ABI

Airlock runs `install.sh` from the canonical package directory and sets these
variables:

- `AIRLOCK_ROOT`: the Airlock checkout; source `$AIRLOCK_ROOT/install/lib.sh`.
- `AIRLOCK_APP_DIR`: the canonical package root; locate package-local files here.
- `AIRLOCK_APP_ID`: the package id.

Do not calculate the platform root by walking up from `$0`: an explicit
package can live anywhere. The example locates Airlock and its own files only
through this ABI, then uses the helpers loaded from `install/lib.sh`.

## Apply behavior

- **First apply:** validates the source manifest before running `install.sh`,
  applies the app's ingress, refreshes the nginx site and Hub manifest, then
  records the source and artifacts.
- **Rerun:** `install.sh` runs again, so make writes idempotent. This example
  rewrites the unit and fragment only when changed and restarts the backend
  only when its unit changed.
- **Update:** edit the package in place and run the same `apply` command. If an
  update fails, the ledger reapplies the source path recorded at the start
  once; it reports `restored` or `residue` and returns nonzero either way. A
  local source records its directory path, so keep a copy of the previous
  package contents if you need to restore that version after an in-place edit.
- **Remove:** run `airlock-ledger remove hello-example`. The ledger removes
  recorded artifacts and refreshes projections while preserving unrecorded
  user data.

## A malformed manifest

This was produced by copying this example, appending the invalid TOML line
`invalid = [`, and querying that directory directly:

```bash
AIRLOCK_CONFIG="$HOME/broken/airlock.toml" \
  python3 bin/airlock-config dir-package-info hello-example "$HOME/broken/package"
```

`dir-package-info` exits nonzero and names `airlock-app.toml` as invalid TOML.
It uses the same manifest parser as `apply` and reports the error without
applying the package or changing installed state.
