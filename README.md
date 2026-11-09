# apt-cacher for MikroTik Container

Build and configuration to run [apt-cacher](https://manpages.ubuntu.com/manpages/focal/man8/apt-cacher.8.html)
(Debian/Ubuntu package caching proxy) inside a
[MikroTik Container](https://help.mikrotik.com/docs/display/ROS/Container).
LAN machines point `apt` at it; each package is downloaded from the mirrors
once and served from the router's USB disk afterwards.

Structured to match the sibling [`mikrotik-nginx`](../mikrotik-nginx) and
[`mikrotik-syslog`](../mikrotik-syslog) projects: same management-SSH pattern,
same env-driven container, same build model (buildx + skopeo), same `rsc/`
layout. The RouterOS-side plumbing (veth, mounts, container, firewall, DNS)
lives in [`rsc/`](rsc).

Unlike nginx this is **LAN-only**: there is no WAN port-forward, and the
daemon's `allowed_hosts` only admits `192.168.0.0/16`.

## Requirements

RouterOS v7.6+ with the Container package, container `device-mode` enabled, and
the ext4 USB disk (fs-label `router1-containers`) pinned to the fixed
mount-point `/storage`. That pin, the global `layer-dir`/`tmpdir`, and the
`bridge-containers` network were set up for the nginx container and are reused
as-is; see [`../mikrotik-nginx/README.md`](../mikrotik-nginx/README.md) for why
the disk is pinned.

## Build

`build.sh` builds for **arm64 only** (RB5009) and emits one container-archive
tar:

| Output tar | buildx platform | Runtime base |
| ---------- | --------------- | ------------ |
| `apt-cacher-arm64.tar` | `linux/arm64` | `arm64v8/debian:bookworm-slim` |

apt-cacher 1.7.29 comes from the Debian archive, so there is no cross-compile
step. The Mac build host is native arm64, so no QEMU is needed.

```
./build.sh              # -> apt-cacher-arm64.tar
NO_CACHE=1 ./build.sh   # full clean rebuild
```

`build.sh` rejects images with empty or duplicate layers (RouterOS fails with
"could not mount overlayfs root" on those). Upload the tar to `/storage` on the
router; the `.rsc` scripts reference `storage/apt-cacher-arm64.tar`.

## Container environment variables

Set via `/container/envs` (see [`rsc/01-router-apt-cacher.rsc`](rsc/01-router-apt-cacher.rsc)
and [`rsc/secrets.local.rsc`](rsc/secrets.local.rsc)). `apt-cacher.sh` renders
them into `/etc/apt-cacher/conf.d/90-container.conf`.

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `PASSWORD` | (unset) | root password for the management SSH server (only in `secrets.local.rsc`) |
| `ALLOWED_HOSTS` | `192.168.0.0/16` | clients allowed to use the cache (`allowed_hosts` syntax: IPs, CIDRs, ranges, `*`). apt-cacher's own default is localhost only |
| `DAEMON_PORT` | `3142` | TCP listen port |
| `DISTINCT_NAMESPACES` | `1` | keep Debian/Ubuntu/etc. in separate cache subdirectories |
| `PATH_MAP` | (unset) | optional `path_map`, e.g. `debian deb.debian.org/debian; ubuntu archive.ubuntu.com/ubuntu` (mirror-style URLs `http://host:3142/debian/...`) |
| `DISK_USAGE_LIMIT` | (unset; `20GiB` in the rsc) | cap on cache size |
| `ADMIN_EMAIL` | `root@localhost` | shown on the info page |
| `MAINTENANCE_INTERVAL_SECONDS` | `86400` | period of the report, cache cleanup and logrotate loop |
| `TZ` | `Europe/London` | timezone for timestamps |

Invalid values (non-numeric port/interval, empty `ALLOWED_HOSTS`) are fatal:
`apt-cacher.sh` logs the reason and exits non-zero so it shows in the RouterOS
container log.

## How it runs

- `apt-cacher.sh` is PID 1. It prepares the persistent cache/log mounts (the
  package's `install.pl` creates the cache layout), renders the config, starts
  `apt-cacher -d` (which forks) and supervises it through its pidfile.
- On `SIGTERM` (RouterOS stop) it stops the daemon and exits; if the daemon
  dies the container exits non-zero and `restart-policy=on-failure` restarts it.
- The package's cron jobs (daily traffic report, cache cleaner) and logrotate
  entry are replaced by a loop in `apt-cacher.sh` (cron isn't installed, and
  the stock logrotate postrotate needs `invoke-rc.d`). Logs rotate with
  `copytruncate`, so no daemon restart is needed.
- Mounts: `/storage/apt-cacher/cache` -> `/var/cache/apt-cacher`,
  `/storage/apt-cacher/log` -> `/var/log/apt-cacher`. Both survive upgrades.

## RouterOS setup (`rsc/`)

Run on the router (`ssh admin@192.168.100.1`), in this order:

1. Upload `apt-cacher-arm64.tar` to `/storage`.
2. **[`rsc/secrets.local.rsc`](rsc/secrets.local.rsc)** — adds the management
   `PASSWORD` env. **Git-ignored**; run it first.
3. **[`rsc/01-router-apt-cacher.rsc`](rsc/01-router-apt-cacher.rsc)** — the rest,
   in `STEP`/`VERIFY`/`TO REMOVE` form:
   - static veth `192.168.102.4/24` (gateway `192.168.102.1`) on
     `bridge-containers` (`.2` is nginx, `.3` is syslog);
   - the non-secret envs, the cache and log mounts, and the container
     (`hostname=apt-cacher-router`, `start-on-boot`, `restart-policy=on-failure`,
     not privileged);
   - an `apt-cacher-clients` address-list (vlan20, vlan100) with a forward
     accept for tcp `3142`, placed before the `ANYCAST-FW: TODO-DROP`
     catch-all so it keeps working once that is flipped to drop;
   - split DNS `apt-cacher.dids.atasha.net -> 192.168.102.4`.

To redeploy a new image, upload the new tar and run
[`rsc/upgrade.rsc`](rsc/upgrade.rsc) (stop -> remove -> re-add from the local
tar -> start; the cache survives).

## Client configuration

Proxy mode (recommended) on each Debian/Ubuntu client:

```
echo 'Acquire::http::Proxy "http://apt-cacher.dids.atasha.net:3142";' \
  | sudo tee /etc/apt/apt.conf.d/01proxy
```

apt-cacher caches `http://` repositories. `https://` repositories are tunnelled
through with CONNECT and are **not** cached, so keep archive mirrors on
`http://` (apt verifies package signatures itself).

To add another client VLAN, add it to the firewall address-list:

```
/ip/firewall/address-list/add list=apt-cacher-clients address=192.168.21.0/24
```

It must also fall inside `ALLOWED_HOSTS`.

## Management

```
/container/shell [find where hostname="apt-cacher-router"]
# tail /var/log/apt-cacher/access.log   # time|ms|client|HIT/MISS|bytes|file
# cat /etc/apt-cacher/conf.d/90-container.conf
```

Traffic report: `http://apt-cacher.dids.atasha.net:3142/report/` (regenerated
once per maintenance interval). To force a refresh of a corrupt cached file,
request it with `wget --no-cache`. The container also runs sshd (root,
`PASSWORD`) on `192.168.102.4`.
