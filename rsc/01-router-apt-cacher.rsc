# =============================================================================
# apt-cacher container (Debian/Ubuntu package cache) — Main Router
# Device: MikroTik RB5009UG+S+ (arm64), RouterOS 7.25.1. Management address
#         192.168.100.1 (vlan100); run with: ssh admin@192.168.100.1
# Bridge: existing "bridge-containers", subnet 192.168.102.0/24, gateway
#         192.168.102.1, DHCP pool "continers" 192.168.102.10-200. The container
#         joins it on a NEW veth with a STATIC address OUTSIDE the pool.
# Storage: the ext4 USB disk (fs-label "router1-containers") is pinned to the
#   FIXED mount-point "storage" (see ../../mikrotik-nginx/rsc/01-router-nginx.rsc
#   STEP 0a for why), so the image tar, root-dir, layers and the cache/log
#   mounts all live under /storage and never shift between usbN slots.
#
# ROLE — a LAN-only caching proxy for apt. Clients on the LAN point apt at
#        http://apt-cacher.dids.atasha.net:3142; packages are downloaded from
#        the Debian/Ubuntu mirrors once and served from the USB disk after that.
#        Unlike the nginx container this is NOT exposed on the WAN: there is no
#        dstnat rule, and the container's allowed_hosts only admits 192.168/16.
#
# Image: upload the arm64 tar built by ../build.sh -> apt-cacher-arm64.tar
#        to /storage on the router.
# =============================================================================
# ADDRESSING:
#   bridge-containers gateway ....... 192.168.102.1  (router, already assigned)
#   DHCP pool "continers" ........... 192.168.102.10-200  (avoid — use static)
#   nginx container (veth-nginx) .... 192.168.102.2/24
#   syslog container (veth-syslog) .. 192.168.102.3/24
#   apt-cacher (veth-apt-cacher) .... 192.168.102.4/24  (NEW — this script)
#
# Container ports (image, apt-cacher.sh / Dockerfile):  3142 apt-cacher   22 SSH
#
# *** RUN rsc/secrets.local.rsc FIRST *** — it adds the management-SSH PASSWORD
# to list=apt-cacher. This script adds every OTHER env and must not contain it.
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 0: Prerequisites (verify — do NOT blindly re-run base router setup)
# -----------------------------------------------------------------------------
#   /system/resource/print          ; architecture-name: arm64 -> apt-cacher-arm64.tar
#   /system/device-mode/print       ; container: yes (required to add containers)
#   /interface/bridge/print where name=bridge-containers   ; must exist
#   /disk/print                     ; container disk MOUNTED at "storage"
#   /container/config/print         ; layer-dir=/storage/layers tmpdir=/storage/tmp
#   /file/print where name=storage/apt-cacher-arm64.tar    ; image uploaded
# All of these were already in place for the nginx and syslog containers; this
# script does not touch the disk pin or the global container config.

# -----------------------------------------------------------------------------
# STEP 1: New veth for the container on the EXISTING container bridge
# -----------------------------------------------------------------------------
# Static 192.168.102.4 (outside the DHCP pool .10-200, next free after
# nginx .2 and syslog .3). Gateway is the bridge address 192.168.102.1 (the
# router), which is also the container's route to the internet for mirror
# fetches (srcnat masquerade on ether1 already covers the container subnet,
# as it does for nginx's certbot traffic).
/interface/veth/add \
    name=veth-apt-cacher \
    address=192.168.102.4/24 \
    gateway=192.168.102.1 \
    comment="apt-cacher container veth (Debian/Ubuntu package cache)"

/interface/bridge/port/add \
    bridge=bridge-containers \
    interface=veth-apt-cacher

# -----------------------------------------------------------------------------
# STEP 2: Container environment (NON-secret envs only)
# -----------------------------------------------------------------------------
# PASSWORD (management-SSH root password) is added by rsc/secrets.local.rsc —
# RUN THAT FIRST. Omit it entirely to disable password login (host keys are
# still generated at startup; use /container/shell instead).
#
# DISK_USAGE_LIMIT caps the cache so it cannot fill the shared 30GB USB disk
# (~28GB free when this was written, also used by nginx, syslog and swap).
#
# ALLOWED_HOSTS is who may use the cache. apt-cacher's own default is
# localhost only, so this must be set; 192.168.0.0/16 covers every LAN VLAN.
# (The guest VLAN 40 is rejected earlier by the router's forward chain.)
/container/envs/add list=apt-cacher key="ALLOWED_HOSTS"        value="192.168.0.0/16"
/container/envs/add list=apt-cacher key="DISTINCT_NAMESPACES"  value="1"
/container/envs/add list=apt-cacher key="DISK_USAGE_LIMIT"     value="20GiB"
/container/envs/add list=apt-cacher key="TZ"                   value="Europe/London"
#
# Optional envs (uncomment to use):
#   /container/envs/add list=apt-cacher key="DAEMON_PORT"                  value="3142"
#   /container/envs/add list=apt-cacher key="ADMIN_EMAIL"                  value="n@atasha.net"
#   /container/envs/add list=apt-cacher key="MAINTENANCE_INTERVAL_SECONDS" value="86400"
#   /container/envs/add list=apt-cacher key="PATH_MAP" \
#       value="debian deb.debian.org/debian; ubuntu archive.ubuntu.com/ubuntu"

# -----------------------------------------------------------------------------
# STEP 3: Mounts — PERSIST the package cache and the logs
# -----------------------------------------------------------------------------
# Without the cache mount every container re-add would start with an empty
# cache and re-download everything (and the cache would eat the root-dir).
# Backed by /storage so it survives reboots, slot changes and container re-adds
# (upgrade.rsc). The container creates the layout inside on first start.
/container/mounts/add \
    list=apt-cacher \
    src=/storage/apt-cacher/cache \
    dst=/var/cache/apt-cacher \
    mode=rw

/container/mounts/add \
    list=apt-cacher \
    src=/storage/apt-cacher/log \
    dst=/var/log/apt-cacher \
    mode=rw

# -----------------------------------------------------------------------------
# STEP 4: Add the container
# -----------------------------------------------------------------------------
# cmd is required on RouterOS 7.22+. NOT privileged: apt-cacher is a userspace
# proxy and needs no NET_ADMIN/netfilter. restart-policy=on-failure restarts it
# if the daemon dies (apt-cacher.sh exits non-zero then); stop-time gives the
# SIGTERM handler room to stop the daemon. dns points at the bridge gateway
# first, then a public resolver as a backstop.
/container/add \
    file=storage/apt-cacher-arm64.tar \
    interface=veth-apt-cacher \
    envlists=apt-cacher \
    mountlists=apt-cacher \
    hostname=apt-cacher-router \
    dns=192.168.102.1,8.8.8.8 \
    root-dir=storage/containers/apt-cacher \
    cmd=/usr/local/bin/apt-cacher.sh \
    start-on-boot=yes \
    logging=yes \
    restart-policy=on-failure \
    stop-time=20s \
    comment="apt-cacher Debian/Ubuntu package cache (apt-cacher.dids.atasha.net:3142)"

# -----------------------------------------------------------------------------
# STEP 5: Firewall — allow LAN clients to reach the cache
# -----------------------------------------------------------------------------
# The clients are the LAN VLANs below, kept in an address-list so adding a VLAN
# is one line instead of a new rule. Today the ANYCAST-FW catch-all still
# accepts everything, but these accepts are placed BEFORE it so the cache keeps
# working when that catch-all is flipped from log+accept to drop (same
# placement as the syslog rules; (...->0) is the first-match anchor).
/ip/firewall/address-list/add list=apt-cacher-clients address=192.168.20.0/24  comment="apt-cacher: LAN (vlan20)"
/ip/firewall/address-list/add list=apt-cacher-clients address=192.168.100.0/24 comment="apt-cacher: mgmt (vlan100)"

/ip/firewall/filter/add \
    chain=forward \
    src-address-list=apt-cacher-clients \
    dst-address=192.168.102.4 \
    protocol=tcp \
    dst-port=3142 \
    action=accept \
    comment="apt-cacher: allow LAN->cache tcp 3142" \
    place-before=([/ip/firewall/filter/find where comment~"ANYCAST-FW: TODO-DROP"]->0)

# No dstnat / port-forward on purpose: the cache is LAN-only. The router itself
# (192.168.102.1, the container bridge) reaches it without a forward rule.

# -----------------------------------------------------------------------------
# STEP 6: Split DNS — a stable name for the cache
# -----------------------------------------------------------------------------
# So clients configure a name, not an IP, and the container can be re-addressed
# later without touching every client.
/ip/dns/static/add \
    name="apt-cacher.dids.atasha.net" \
    type=A \
    address=192.168.102.4 \
    ttl=5m \
    comment="apt-cacher: LAN package cache container"
/ip/dns/cache/flush

# -----------------------------------------------------------------------------
# STEP 7: Start the container
# -----------------------------------------------------------------------------
/container/start [find where hostname="apt-cacher-router"]

# =============================================================================
# VERIFY
# =============================================================================
#   /container/print                                      ; status running
#   /ip/firewall/filter/print where comment~"apt-cacher:" ; accept, above the
#                                                         ; ANYCAST catch-all
#   /ip/dns/static/print where name="apt-cacher.dids.atasha.net"
#   /file/print where name~"storage/apt-cacher"           ; cache/ and log/ exist
#
#   # inside the container:
#   /container/shell [find where hostname="apt-cacher-router"]
#     tail /var/log/apt-cacher/access.log /var/log/apt-cacher/error.log
#     cat /etc/apt-cacher/conf.d/90-container.conf
#
#   # from a LAN client (MISS the first time, HIT the second):
#     curl -sI http://apt-cacher.dids.atasha.net:3142/deb.debian.org/debian/dists/bookworm/InRelease
#     curl -s  http://apt-cacher.dids.atasha.net:3142/report/ | head
#
# *** CLIENT CONFIGURATION (proxy mode, recommended) ***
#   On each Debian/Ubuntu client:
#     echo 'Acquire::http::Proxy "http://apt-cacher.dids.atasha.net:3142";' \
#       | sudo tee /etc/apt/apt.conf.d/01proxy
#   apt-cacher proxies http:// repos. https:// repos are CONNECTed straight
#   through (not cached) — keep mirrors on http:// (apt verifies signatures
#   itself, so http is safe for Debian/Ubuntu archives).
#
# TO REMOVE:
#   /container/stop   [find where hostname="apt-cacher-router"]
#   /container/remove [find where hostname="apt-cacher-router"]
#   /ip/firewall/filter/remove       [find comment~"apt-cacher:"]
#   /ip/firewall/address-list/remove [find list=apt-cacher-clients]
#   /ip/dns/static/remove            [find comment~"apt-cacher:"]
#   /interface/bridge/port/remove [find interface=veth-apt-cacher]
#   /interface/veth/remove [find name=veth-apt-cacher]
#   /container/envs/remove   [find where list=apt-cacher]
#   /container/mounts/remove [find where list=apt-cacher]
#   (the cache on /storage/apt-cacher is left in place; delete it with
#   /file/remove if you want the space back)
# =============================================================================
