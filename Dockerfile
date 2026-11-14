# apt-cacher (Debian/Ubuntu package caching proxy) for MikroTik RouterOS
# containers.
#
# SINGLE-ARCH BUILD (arm64 ONLY):
#   arm64 (ARMv8) — RB5009UG+S+ (Cortex-A72). Like ../mikrotik-nginx and
#   ../mikrotik-syslog this targets only that router, so there is no arm32
#   variant. apt-cacher is a Perl daemon from the Debian archive, so there is
#   no cross-compile step; the Mac build host is native arm64 (no QEMU needed,
#   see build.sh).
#
# Build arg (default is arm64 so a bare `docker build` works):
#   RUNTIME_BASE   arm64v8/debian:bookworm-slim
#
# RouterOS LAYER RULE: every layer must change the filesystem. RouterOS stores
# layers by content digest and stacks them as overlayfs lowerdirs, so two
# identical layers (e.g. two empty ones) become a duplicate lowerdir and the
# container fails with "could not mount overlayfs root". Hence --chmod on the
# COPYs (a separate `RUN chmod` can be an empty layer) and the config check
# below writes its result into the image. build.sh rejects images with empty
# or duplicate layers.
ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim
FROM ${RUNTIME_BASE}

# apt-cacher       — the caching proxy (stand-alone daemon mode, port 3142).
#                    Installed WITH recommends: they carry the Perl modules the
#                    daemon needs for checksums, IPv6 and lzma index files.
#                    (--no-install-recommends is only used for the extras.)
# logrotate        — the package's own logrotate.d entry restarts the daemon via
#                    invoke-rc.d, which doesn't exist here; apt-cacher.sh drives
#                    logrotate with its own config instead.
# openssh-server   — management access, same pattern as the nginx/syslog images.
# tzdata           — so TZ=Europe/London gives local timestamps.
# curl/procps      — debugging inside the container.
# bash/ca-certificates — scripting + trust store, as in the sibling images.
#
# Like the nginx/syslog images we DO NOT install iptables/iproute2: a caching
# proxy needs no netfilter, so the container also runs unprivileged. cron is
# not installed either; the daily report/cleanup jobs that the package's
# /etc/cron.d entry would run are driven by apt-cacher.sh.
RUN apt-get update && \
    apt-get install -y apt-cacher && \
    apt-get install -y --no-install-recommends \
      logrotate openssh-server tzdata curl procps bash ca-certificates && \
    rm -rf /var/lib/apt/lists/* \
    /etc/cron.d/apt-cacher /etc/logrotate.d/apt-cacher && \
    rm -f /etc/ssh/ssh_host_* && \
    mkdir -p /var/run/sshd

COPY sshd_config /etc/ssh/
COPY --chmod=0644 logrotate.conf /etc/logrotate-apt-cacher.conf
COPY --chmod=0755 apt-cacher.sh /usr/local/bin/apt-cacher.sh

# Build-time check: the installed daemon starts and parses its default config.
# The result is kept in the image so this layer is never empty.
RUN d=/usr/share/mikrotik-apt-cacher; mkdir -p "$d" && \
    { apt-cacher --version > "$d/version.txt" 2>&1 || true; } && \
    { logrotate -d -s /tmp/lr.status /etc/logrotate-apt-cacher.conf > "$d/logrotate-check.txt" 2>&1 \
      || { cat "$d/logrotate-check.txt"; exit 1; }; } && \
    rm -f /tmp/lr.status && \
    cat "$d/version.txt"

# 3142  apt-cacher (HTTP proxy / mirror)    22  management SSH
EXPOSE 3142 22
CMD ["/usr/local/bin/apt-cacher.sh"]
