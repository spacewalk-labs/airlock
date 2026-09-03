#!/usr/bin/env bash
# orca deactivate — one app-specific stop step: the AppArmor profile.
#
# Everything else is covered by the ledger's generic classes: "units"
# stops/disables/deletes all three units — both user-scope (xvfb, serve) and
# the system-scope firewall unit (D2's typed-units surface handles the scope
# split; no templated-instance gap like code-server's, every name here is
# literal) — and airlock-orca.service already reaps its own orphaned
# app-orca-*.scope children via its own ExecStopPost=airlock-orca-reap
# (apps/orca/render.sh), which fires on ANY stop, including the ledger's, so
# nothing extra is needed here for that; "fragments" removes the servers.d
# fragment; "files" removes the AppImage/squashfs/serve.log staging dir, the
# reap helper, and the pairing-code file; "rooted" removes
# /etc/airlock/orca-loopback.nft and the patched web client's serve tree under
# ${webroot_parent}/orca-web/ (sudo, re-checked against the allowlist at
# execution time — D2's rooted amendment). The ledger also retires the
# serve.https tailscale mapping.
#
# 🔴 /etc/apparmor.d/airlock-orca (install.sh section 4b) canNOT ride the
# "rooted" class: that allowlist admits only /etc/airlock, /opt/airlock and
# ${webroot_parent}, and an AppArmor profile has to live in /etc/apparmor.d to
# be loaded at boot. So it is removed here instead. Idempotent: rm -f and an
# unload of an already-absent profile are both no-ops.
set -euo pipefail

AA_PROFILE=/etc/apparmor.d/airlock-orca
[ -e "$AA_PROFILE" ] || exit 0
# Unload before deleting — removing the file alone leaves the profile resident
# in the kernel until the next reboot.
sudo apparmor_parser -R "$AA_PROFILE" 2>/dev/null || true
sudo rm -f "$AA_PROFILE"
exit 0
