ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim
FROM ${RUNTIME_BASE}

ARG PKGS_NEEDING_RECOMMENDS="apt-cacher"
ARG PKGS_LEAN="logrotate openssh-server tzdata curl procps bash ca-certificates"

RUN apt-get update && \
    apt-get install -y ${PKGS_NEEDING_RECOMMENDS} && \
    apt-get install -y --no-install-recommends ${PKGS_LEAN} && \
    rm -rf /var/lib/apt/lists/* \
    /etc/cron.d/apt-cacher /etc/logrotate.d/apt-cacher && \
    rm -f /etc/ssh/ssh_host_* && \
    mkdir -p /var/run/sshd

COPY sshd_config /etc/ssh/
COPY --chmod=0644 logrotate.conf /etc/logrotate-apt-cacher.conf
COPY --chmod=0755 apt-cacher.sh /usr/local/bin/apt-cacher.sh

RUN d=/usr/share/mikrotik-apt-cacher; mkdir -p "$d" && \
    { logrotate -d -s /tmp/lr.status /etc/logrotate-apt-cacher.conf > "$d/logrotate-check.txt" 2>&1 \
      || { cat "$d/logrotate-check.txt"; exit 1; }; } && \
    rm -f /tmp/lr.status

EXPOSE 3142 22
CMD ["/usr/local/bin/apt-cacher.sh"]
