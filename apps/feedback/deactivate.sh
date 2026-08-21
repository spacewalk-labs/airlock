#!/usr/bin/env bash
# feedback deactivate — no app-specific stop step beyond what the ledger's
# generic "units" artifact class already does (stop/disable -> delete ->
# daemon-reload, for airlock-feedback.service; D5 amendment). This script
# exists only so feedback is NOT install/upgrade-only (D6 priority 1) —
# dropping [apps.feedback] from config must be allowed to remove it, not
# refuse. Idempotent by construction (does nothing).
set -euo pipefail
exit 0
