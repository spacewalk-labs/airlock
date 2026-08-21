# Airlock — EXPERIMENTAL systemd-in-Docker image (alternative to the OrbStack
# machine path, which is recommended; see docs/design/macos-container.md §2).
#
# This image boots systemd as PID 1 so Airlock's `systemctl --user` units, the
# publish timer, and orca's system unit run unchanged. That requires the
# container to run with cgroup access (see docker-compose.yml). It is provided
# as a reproducible artifact; it is NOT verified on real hardware.
#
# Build for amd64 (Rosetta on Apple Silicon) only if you need orca, the one
# x86_64-only app; everything else has a pinned arm64 asset:
#   docker buildx build --platform linux/amd64 -t airlock:latest -f docker/Dockerfile .
FROM --platform=${TARGETPLATFORM:-linux/amd64} ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Base prerequisites the installers need but don't install themselves.
# systemd + systemd-sysv so /sbin/init works as PID 1.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      nginx curl ca-certificates tar gnupg python3 tmux nftables sudo \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Strip systemd units that make no sense in a container (getty, etc.) to speed boot.
RUN find /etc/systemd/system /lib/systemd/system \
      \( -name 'systemd-udevd*' -o -name 'getty*' -o -name 'console-getty*' \) \
      -exec ln -sf /dev/null {} \; 2>/dev/null || true

# Non-root owner account. The installer runs as this user and uses passwordless
# sudo for the /opt, /etc and system-nginx steps. UID 1000 matches the typical
# first Mac user for clean bind-mount ownership; override at build if needed.
ARG AIRLOCK_UID=1000
ARG AIRLOCK_USER=airlock
RUN useradd -m -u ${AIRLOCK_UID} -s /bin/bash ${AIRLOCK_USER} \
    && echo "${AIRLOCK_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/airlock \
    && loginctl enable-linger ${AIRLOCK_USER} 2>/dev/null || true

# The repo is bind-mounted at runtime (see compose) rather than baked in, so you
# edit one copy and re-run the installer without rebuilding. A first-boot oneshot
# runs the installer once Tailscale is up.
COPY docker/firstboot.sh /usr/local/sbin/airlock-firstboot.sh
COPY docker/airlock-firstboot.service /etc/systemd/system/airlock-firstboot.service
RUN chmod +x /usr/local/sbin/airlock-firstboot.sh \
    && systemctl enable airlock-firstboot.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
