#!/usr/bin/env bash
set -euo pipefail
: "${AIRLOCK_WEBROOT:?}"
rm -rf -- "$AIRLOCK_WEBROOT/zz-install-recovery-fail"
