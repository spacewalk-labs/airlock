#!/usr/bin/env bash
# Pins `uname -m` so the setup script's architecture branch does not depend on which
# box runs the test. Everything else falls through to the real uname.
[ "${1:-}" = "-m" ] && { echo "${FAKE_UNAME_M:-arm64}"; exit 0; }
exec /usr/bin/uname "$@"
