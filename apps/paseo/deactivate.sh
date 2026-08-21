#!/usr/bin/env bash
# paseo deactivate — no app-specific stop step. The ledger's generic classes
# cover everything declared: "units" stops/disables/deletes both
# airlock-paseo.service and airlock-paseo-browse-host.service (both literal,
# non-templated names — unlike code-server's slot template, there is no
# numbered-instance gap here: the daemon's own child processes, spawned
# provider CLIs included, live in its unit's cgroup and go down with it);
# "fragments" removes the servers.d fragment and the paseo/ icon dir;
# "files" removes the pinned ~/.npm-global tree, the paseo bin symlink, and
# the browse-host sidecar's install dir. The ledger also retires the
# serve.https tailscale mapping. ~/.paseo/ (config.json, patched in place)
# and ~/.cache/ms-playwright/ (a shared cache) are retained data — never
# declared, so never touched. Idempotent by construction (does nothing).
set -euo pipefail
exit 0
