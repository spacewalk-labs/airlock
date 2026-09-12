# Guarded Paseo 0.2.5 bundle

This directory is the reproducible Airlock input for the guarded Paseo 0.2.5
deployment. The six npm package tarballs are installed together so npm resolves
the modified `@getpaseo` packages as one version-consistent set.

- Corresponding source: <https://github.com/ChoSungHyeon/paseo/tree/06697f6f6a2495e8040efdb81d4562f0f839e882>
- Archive-state review: <https://github.com/ChoSungHyeon/paseo/pull/4>
- Original guarded backport review: <https://github.com/ChoSungHyeon/paseo/pull/1>
- Base: upstream Paseo `v0.2.5` (`6fc491e6220fba6543bbbe4bf1b1f58cfe59228b`)
- License: AGPL-3.0; the full text is in `LICENSE` beside this file.

The installer verifies `SHA256SUMS` before changing the npm prefix and records
the checksum-file digest as the installed identity. It also checks the critical
installed files in `INSTALLED_SHA256SUMS` on every run, so replacing the bundle
with a stock package of the same version cannot pass as idempotent. An explicit
`[apps.paseo].version` override selects the ordinary npm registry path instead.

The server archive preserves the existing Airlock web UI and runtime patch set,
then overlays the reviewed archive-state build outputs for `mcp-shared.js`,
`paseo-tools.js`, and `session.js`. Bundle tests pin those three delivered files
as well as the earlier guarded capabilities.
