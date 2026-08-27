#!/usr/bin/env bash
# Containers are removed by the platform ledger from immutable ids and exact
# ownership labels. Keeping that authority out of this app-local hook is what
# preserves cleanup when this package path is missing or its digest changed.
set -euo pipefail
exit 0
