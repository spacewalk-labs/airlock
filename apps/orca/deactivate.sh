#!/usr/bin/env bash
# orca deactivate — no app-specific stop step. The ledger's generic classes
# cover everything declared: "units" stops/disables/deletes all three units
# — both user-scope (xvfb, serve) and the system-scope firewall unit (D2's
# typed-units surface handles the scope split; no templated-instance gap
# like code-server's, every name here is literal) — and airlock-orca.service
# already reaps its own orphaned app-orca-*.scope children via its own
# ExecStopPost=airlock-orca-reap (apps/orca/render.sh), which fires on ANY
# stop, including the ledger's, so nothing extra is needed here for that;
# "fragments" removes the servers.d fragment; "files" removes the AppImage/
# squashfs/serve.log staging dir, the reap helper, and the pairing-code
# file; "rooted" removes /etc/airlock/orca-loopback.nft and the patched web
# client's serve tree under ${webroot_parent}/orca-web/ (sudo, re-checked
# against the allowlist at execution time — D2's rooted amendment). The
# ledger also retires the serve.https tailscale mapping. Idempotent by
# construction (does nothing).
set -euo pipefail
exit 0
