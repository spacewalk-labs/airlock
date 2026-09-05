#!/usr/bin/env bash
# A recording stand-in for the OrbStack `orb` CLI, used by install/test-setup-progress.sh.
#
# Every command docker/orbstack-machine-setup.sh sends to the Linux machine goes
# through `orb`, so intercepting this one name drives the whole script offline: no
# OrbStack, no VM, no network, no machine state touched anywhere. The script's only
# other external calls are `command -v`, `uname -m` and `python3`.
#
# It RECORDS as well as answers. The recording is the stronger oracle of the two the
# test uses: a transcript proves what the operator sees, but the call log proves what
# the machine was actually asked to do — which is the thing that must not change when
# progress reporting is added.
#
# Fails closed: an unset ORB_LOG aborts rather than silently running unrecorded.
set -u
# %q per argument, not "$*". Joining with spaces destroys argument boundaries, so
# `["a b", "c"]` and `["a", "b c"]` record identically — and the call log is the
# strongest oracle the test has. It must not be able to call two different commands
# the same thing.
{ printf 'orb';
  if [ "${STUB_RECORD_EXECUTABLE:-0}" = 1 ]; then printf ' executable=%q' "$0"; fi
  printf ' %q' "$@"; printf '\n'; } \
  >> "${ORB_LOG:?ORB_LOG must be set — refusing to run unrecorded}"
case "${1:-}" in
  list)
    # STUB_NO_MACHINE=1 takes the CREATE branch instead of the idempotent one; both
    # halves of that `if` need exercising, and only one of them is the fresh install
    # a first-run launcher will actually hit.
    [ "${STUB_NO_MACHINE:-0}" = 1 ] || echo "${STUB_MACHINE:-airlock}"
    ;;
  create) ;;
  -m)
    shift 2                                    # -m <machine>
    [ "${1:-}" = "-u" ] && shift 2             # -u <user>
    case "$*" in
      *whoami*)                    echo "airlockuser" ;;
      *"printf %s"*'"$HOME"'*)   printf '/home/airlockuser' ;;
      *"tailscale status --json"*)
        # STUB_BAD_FQDN=1 makes the parse fail, which the script tolerates by design
        # (`|| true`) and reports as a placeholder URL.
        [ "${STUB_BAD_FQDN:-0}" = 1 ] && { printf 'not json at all'; exit 0; }
        printf '{"Self":{"DNSName":"airlock.example.ts.net."}}'
        ;;
      *"tailscale up"*)
        # Shaped like the real thing: the login URL arrives as one line among several,
        # which is why the script has to scan rather than capture.
        if [ "${STUB_TS_NO_NEWLINE:-0}" = 1 ]; then
          # The URL as the LAST thing printed, with no trailing newline — the shape a
          # prompt takes. Plain `while read` discards that line, losing exactly the
          # URL the json branch exists to find.
          printf 'To authenticate, visit:\n\n        https://login.tailscale.com/a/abc123def456'
        else
          printf 'To authenticate, visit:\n\n        https://login.tailscale.com/a/abc123def456\n\n'
        fi
        [ "${STUB_TS_FAIL:-0}" = 1 ] && exit 1
        ;;
      # Two separate `test -f` calls, and the stub must be able to fail EITHER — an
      # always-succeeding answer silently hid both of section 4's die paths, which is
      # where the multi-line message that used to break the JSON event lives.
      *"test -f"*airlock.toml*) exit "${STUB_NO_CONFIG:-0}" ;;
      *"test -f"*)              exit "${STUB_NO_REPO:-0}" ;;
    esac
    ;;
esac
exit 0
