# mikrotik-apt-cacher

[apt-cacher](https://manpages.debian.org/bookworm/apt-cacher/apt-cacher.8.en.html) in a [RouterOS container](https://help.mikrotik.com/docs/display/ROS/Container).

apt-cacher is a caching proxy for Debian and Ubuntu packages. LAN machines send `apt` through it, so each package comes from the mirror once and from the router's disk after that.

The cache is for LAN use only. Don't forward a WAN port to it.

The examples use a container on `10.0.20.4` and the name `apt-cacher.example.com`. Replace them with your own values.

## Requirements

- RouterOS 7.6 or later with the `container` package, and container mode enabled.
- An ext4 disk mounted at `/storage`. The [mikrotik-nginx README](https://github.com/n4tash4/mikrotik-nginx#pin-the-disk-to-storage) explains why to pin the mount point.
- A router with an arm64 CPU. The image is arm64 only.
- To build: Docker with Buildx, and `skopeo`.

## Build

```sh
./build.sh              # writes apt-cacher-arm64.tar
NO_CACHE=1 ./build.sh   # clean rebuild
```

The image is based on `arm64v8/debian:bookworm-slim`, and apt-cacher comes from the Debian bookworm archive. `build.sh` fails if the image has an empty or duplicate layer, because RouterOS can't mount such an image.

## Deploy

1. Upload the image:

	```sh
	scp -O apt-cacher-arm64.tar admin@<router>:storage/apt-cacher-arm64.tar
	```

2. In `rsc/01-router-apt-cacher.rsc`, set `AUTHORIZED_KEYS`, `ALLOWED_HOSTS`, and the addresses for your network.
3. Upload the script and import it:

	```sh
	scp -O rsc/01-router-apt-cacher.rsc admin@<router>:
	ssh admin@<router> '/import file-name=01-router-apt-cacher.rsc'
	```

4. Start the container:

	```
	/container/start [find where comment~"apt-cacher"]
	```

The script creates the veth, the env and mount lists, and the container. It also adds the address list `apt-cacher-clients`, a forward accept rule for port 3142 placed first in the forward chain (`place-before=0`), and a static DNS entry for the cache name. If you later add a drop rule above it, move the accept rule back to the top.

The container starts on boot (`start-on-boot=yes`).

## Configure

### Environment variables

Set these in the `apt-cacher` env list. RouterOS reads an env list only when you add the container, so after a change, remove the container and add it again (see [Upgrade](#upgrade)).

`apt-cacher.sh` writes most of these to `/etc/apt-cacher/conf.d/90-container.conf` at start. `AUTHORIZED_KEYS`, `MAINTENANCE_INTERVAL_SECONDS`, and `TZ` configure the container itself and are not written there.

| Variable | Default | Description |
|---|---|---|
| `ALLOWED_HOSTS` | `192.168.0.0/16` | Clients that may use the cache, in apt-cacher `allowed_hosts` syntax. apt-cacher's own default is localhost only. |
| `AUTHORIZED_KEYS` | unset | OpenSSH public keys for `root`, one per line. If unset, nobody can log in over SSH. |
| `DAEMON_PORT` | `3142` | TCP port. |
| `DISTINCT_NAMESPACES` | `1` | `1` keeps each distribution in its own cache directory. `0` shares one directory. |
| `ALLOWED_SSL_LOCATIONS` | unset | Comma-separated host names that clients may reach with HTTPS `CONNECT`. apt-cacher tunnels these and does not cache them. |
| `PATH_MAP` | unset | apt-cacher `path_map`, for example `debian deb.debian.org/debian; ubuntu archive.ubuntu.com/ubuntu`. |
| `DISK_USAGE_LIMIT` | unset | Maximum cache size, for example `20GiB`. |
| `ADMIN_EMAIL` | `root@localhost` | Contact address shown on the info page. |
| `MAINTENANCE_INTERVAL_SECONDS` | `86400` | Seconds between runs of the report, the cache cleanup, and logrotate. |
| `TZ` | `Europe/London` | Time zone for timestamps. |

An empty value counts as unset, so it falls back to the default. `apt-cacher.sh` logs the reason and exits if `DAEMON_PORT` or `MAINTENANCE_INTERVAL_SECONDS` is not a positive integer, or if `DISTINCT_NAMESPACES` is not `0` or `1`.

### Paths on the router

| Path | Purpose |
|---|---|
| `/storage/apt-cacher-arm64.tar` | Image file. |
| `/storage/containers/apt-cacher` | Container root-dir. RouterOS deletes it when you remove the container. |
| `/storage/container-data/apt-cacher/cache` | Mounted at `/var/cache/apt-cacher`. The package cache. |
| `/storage/container-data/apt-cacher/log` | Mounted at `/var/log/apt-cacher`. Access, error, and maintenance logs. |
| `/storage/container-data/apt-cacher/ssh-host-keys` | Mounted at `/etc/ssh/host-keys`. SSH host keys. |

### Ports

| Port | Use |
|---|---|
| 3142/tcp | apt-cacher. |
| 22/tcp | SSH, public key only. |

### Clients

On each client, point apt at the cache:

```sh
echo 'Acquire::http::Proxy "http://apt-cacher.example.com:3142";' | sudo tee /etc/apt/apt.conf.d/01proxy
```

apt-cacher caches `http://` repositories only. For an `https://` repository, it tunnels the connection only if the host is in `ALLOWED_SSL_LOCATIONS`. Any other HTTPS host fails with `403 SSL CONNECT proxying not configured`.

Keep the Debian and Ubuntu mirrors on `http://`. apt checks the package signatures itself.

To allow another HTTPS repository, change the variable, then remove and add the container again:

```
/container/envs/set [find where list=apt-cacher key=ALLOWED_SSL_LOCATIONS] value="download.docker.com,apt.releases.hashicorp.com"
```

To allow another client subnet, add it to the address list. The subnet must also be inside `ALLOWED_HOSTS`.

```
/ip/firewall/address-list/add list=apt-cacher-clients address=10.0.2.0/24
```

## Verify

1. Check that the container is running:

	```
	/container/print where comment~"apt-cacher"
	```

2. From a client, fetch the traffic report. An HTTP response from apt-cacher means the client can reach the proxy. A `403` means `ALLOWED_HOSTS` does not include the client:

	```sh
	curl -sI http://apt-cacher.example.com:3142/report/
	```

3. On the client, run `sudo apt update`, then read the access log:

	```sh
	ssh root@10.0.20.4 'tail /var/log/apt-cacher/access.log'
	```

	The log shows a request for each repository. A second `apt update` or `apt install` of the same package is served from the cache.

## Upgrade

If other containers on the router use the same Debian base, stop all of them before you add the new image. When a container that shares a layer is running, extraction fails with `Text file busy`.

1. Upload the new `apt-cacher-arm64.tar`.
2. Stop every container: `/container stop [find]`.
3. Remove the apt-cacher container.
4. Add it again with the same settings. Wait until its status is `stopped`.
5. Start all containers.

The cache is on a data mount, so it survives.

## Remove

1. Stop and remove the container:

	```
	/container/stop [find where comment~"apt-cacher"]
	/container/remove [find where comment~"apt-cacher"]
	```

2. Remove the veth, bridge port, env list, mount list, firewall rule, address list, and DNS entry that `01-router-apt-cacher.rsc` created.
3. To delete the cache and the SSH host keys, remove `/storage/container-data/apt-cacher`. To free the image space, remove `/storage/apt-cacher-arm64.tar`.
4. Remove the `Acquire::http::Proxy` line from `/etc/apt/apt.conf.d/01proxy` on each client.

## How it runs

`apt-cacher.sh` is PID 1. It prepares the cache and log directories, writes the config, starts `apt-cacher -d`, and watches its PID file.

On `SIGTERM` or `SIGINT`, it stops the daemon and exits with status 0. If the daemon dies, the container exits with status 1, and `restart-policy=on-failure` restarts it.

The Debian package uses cron for its report and cache cleanup. The image has no cron, so `apt-cacher.sh` runs both, and logrotate, every `MAINTENANCE_INTERVAL_SECONDS`. Their output goes to `/var/log/apt-cacher/maintenance.log`. `logrotate.conf` rotates the logs weekly or at 32 MB, keeps 8 rotations, and compresses them.

### SSH

`sshd` accepts public keys only. At start, `apt-cacher.sh` writes `AUTHORIZED_KEYS` to `/root/.ssh/authorized_keys`. It creates the ed25519 and RSA host keys in `/etc/ssh/host-keys` if they are missing, so the keys survive a container re-add.

TCP forwarding is off (`AllowTcpForwarding no`), so you can't tunnel through the container.

If SSH is unreachable, open a shell from RouterOS with `/container/shell`.
