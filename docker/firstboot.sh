#!/usr/bin/env bash
# First-boot oneshot for the EXPERIMENTAL Docker image (docker/Dockerfile).
# Brings Tailscale up (fail-closed ingress precondition), then runs the STOCK
# installer as the owner user. Idempotent — safe to let it run every boot.
#
# STATUS: unverified on real hardware (see docs/design/macos-container.md §8).
set -euo pipefail

USER_NAME="${AIRLOCK_USER:-airlock}"
REPO_DIR="${AIRLOCK_REPO_DIR:-/airlock}"   # bind-mount target (see docker-compose.yml)

log() { printf '[airlock-firstboot] %s\n' "$*"; }

[ -f "$REPO_DIR/install/airlock-install.sh" ] || {
  log "repo not mounted at $REPO_DIR — nothing to install; leaving container up"; exit 0; }
[ -f "$REPO_DIR/airlock.toml" ] || {
  log "no $REPO_DIR/airlock.toml — copy airlock.toml.example and fill it in, then restart"; exit 0; }

# Tailscale up (TS_AUTHKEY from EnvironmentFile; never baked into the image).
# --ssh enables Tailscale SSH (keyless, identity-gated); access needs an `ssh`
# rule in the tailnet ACL policy.
if ! tailscale status >/dev/null 2>&1; then
  if [ -n "${TS_AUTHKEY:-}" ]; then
    log "tailscale up (authkey)"
    tailscale up --authkey "$TS_AUTHKEY" --hostname "${TS_HOSTNAME:-airlock}" --ssh
  else
    log "no TS_AUTHKEY — run 'docker exec -it airlock tailscale up' once to authenticate, then: docker restart airlock"
    exit 0
  fi
fi

log "running stock installer as $USER_NAME"
# runuser preserves a login-ish env; the installer uses passwordless sudo internally.
runuser -l "$USER_NAME" -c "cd '$REPO_DIR' && bash install/airlock-install.sh"
log "install complete"
