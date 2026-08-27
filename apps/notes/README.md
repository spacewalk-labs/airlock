# Notes

One owner-only Airlock tile for a configured set of plaintext Markdown vaults:

- Perlite 1.6.1 readers run as Docker containers from immutable image digest
  `sha256:e4912b9a014b5f68b0f29386244e5600e935de09e66906fb13e849f54d2b300c`.
  The image identifies upstream revision
  `2869faaaf06320bbf84f46d211fc22594fc430fd` and the MIT license.
- SilverBullet 2.10.0 provides editing for entries with `writable = true`; its
  release asset is SHA-256 pinned in `install.sh`.
- `[apps.notes.vaults]` is the only hand-authored vault registry. Runtime and
  browser plans are generated from it; the browser plan never contains paths.

Example:

```toml
[apps.notes]
reader_port = 19960
editor_port_base = 19961
vault_slots = 2

[apps.notes.vaults]
default_vault = "docs"
entries = [
  { id = "docs", label = "Docs", path = "$HOME/docs", home_file = "README", writable = true },
  { id = "wiki", label = "Wiki", path = "$HOME/wiki", home_file = "README", writable = false },
]
```

Images must already exist locally. The package uses `--pull=never`, creates no
named network or volume, and bind-mounts the extracted Perlite application root
over the image's declared `VOLUME` so Docker does not create an anonymous one.
Vault mounts are read-only in every reader container. Vault directories are
retained operator data and are never package artifacts.

A reconcile of the same package revision preserves the ledger's committed
container IDs. If the vault plan changes while Notes is installed, the
installer therefore fails before any Docker mutation. Run
one normal install with the complete `[apps.notes]` subtree temporarily
removed, then restore the changed subtree and install again. The first run
reclaims the recorded runtime; the second records a fresh nonce and object set.

The only public route is the hub's same-origin `/notes/` subtree. Every reader
and editor location explicitly returns 403 when `$owner_ok = 0`; the package
does not create a Tailscale serve mapping. Container removal belongs to the
Airlock ledger (contract D9), not `deactivate.sh`, so package loss and an
intent-only crash still use immutable runtime IDs and exact ownership labels.
