#!/usr/bin/env bash
# publish deactivate — no app-specific stop step. The ledger's generic
# classes cover everything declared: "units" stops/disables/deletes all
# three units (including the cleanup timer — UNIT_SUFFIXES covers
# .timer), "fragments" removes the hub-locations and public-includes
# fragments, "webroot" removes the manager UI page. Deliberately does NOT
# touch share_dir/public_dir/gated_dir, the htpasswd auth directory,
# ~/uploads, or ~/.local/state/airlock/publish-public.json — none of those
# are declared in [artifacts] (they are retained operator data / platform
# state, never removed by design, per the ADR appendix). Idempotent by
# construction (does nothing).
set -euo pipefail
exit 0
