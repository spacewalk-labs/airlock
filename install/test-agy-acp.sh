#!/usr/bin/env bash
# install/test-agy-acp.sh — unit tests + fake-agy matrix for the agy-acp fork
# (apps/paseo/agy-acp/). No real agy binary, no real Paseo daemon, no network
# beyond `npm ci` for the fork's own two runtime deps — fast and hermetic.
# The heavier real-daemon proof (Paseo's own ACP client, a daemon restart) is
# install/test-agy-acp-daemon.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FORK_DIR="$ROOT/apps/paseo/agy-acp"

cd "$FORK_DIR"
npm ci --no-audit --no-fund
npm run build
node --test --test-timeout=15000 tests/*.test.mjs
