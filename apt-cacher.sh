#!/bin/bash
# apt-cacher container entrypoint for MikroTik RouterOS containers.
#
# Runs apt-cacher (https://manpages.ubuntu.com/manpages/focal/man8/apt-cacher.8.html)
# as a stand-alone caching proxy for Debian/Ubuntu package downloads. Clients on
# the LAN point apt at it (see README). The RouterOS-side plumbing (veth,
# container, mounts, firewall) lives in the rsc/ scripts beside this file.
#
# Process model
# -------------
# PID 1 is this script. apt-cacher's stand-alone mode (-d) forks into the
# background and writes a pidfile, so we supervise it through that pid. The
# container's lifetime follows the daemon: if it dies, everything is stopped
# and the script exits non-zero (pair with RouterOS restart-policy=on-failure).
# On SIGTERM/SIGINT (RouterOS stop-signal) the daemon is stopped before exit.
#
# Long-running steps run in the background + `wait`, because bash only runs a
# trap after the current foreground command returns; `wait` returns as soon as
# a trapped signal arrives.
#
# Nothing high-volume goes to stdout (logging=yes sends it to the router's
# log). Access/error logs live in /var/log/apt-cacher (a persistent mount).
#
# Env contract
# ------------
#   PASSWORD                      root password for management SSH     [optional]
#                                 (unset -> no password login; use
#                                 /container/shell from the router)
#   ALLOWED_HOSTS                 clients allowed to use the cache (apt-cacher
#                                 allowed_hosts syntax: IPs, CIDRs, ranges,
#                                 comma/semicolon separated, or "*").
#                                 Default 192.168.0.0/16. apt-cacher's own
#                                 default allows localhost ONLY.
#   DAEMON_PORT                   TCP port to listen on (default 3142)
#   DISTINCT_NAMESPACES           1 -> keep Debian and Ubuntu (and others) in
#                                 separate cache subdirectories (default 1)
#   PATH_MAP                      optional apt-cacher path_map value, e.g.
#                                 "debian deb.debian.org/debian; ubuntu archive.ubuntu.com/ubuntu"
#   DISK_USAGE_LIMIT              optional cap on the cache size, e.g. "20GiB"
#   ADMIN_EMAIL                   shown on the info page (default root@localhost)
#   MAINTENANCE_INTERVAL_SECONDS  how often the report generator, cache cleaner
#                                 and logrotate run (default 86400 = daily)
#   TZ                            timezone for timestamps (default Europe/London,
#                                 same as the fleet)

export TZ="${TZ:-Europe/London}"

ALLOWED_HOSTS="${ALLOWED_HOSTS:-192.168.0.0/16}"
DAEMON_PORT="${DAEMON_PORT:-3142}"
DISTINCT_NAMESPACES="${DISTINCT_NAMESPACES:-1}"
ADMIN_EMAIL="${ADMIN_EMAIL:-root@localhost}"
MAINTENANCE_INTERVAL_SECONDS="${MAINTENANCE_INTERVAL_SECONDS:-86400}"

CACHE_DIR=/var/cache/apt-cacher
LOG_DIR=/var/log/apt-cacher
PIDFILE=/run/apt-cacher.pid
CONF=/etc/apt-cacher/conf.d/90-container.conf

DAEMON_PID=""
SSHD_PID=""
MAINT_PID=""

stop_children() {
  [[ -n "${SSHD_PID}" ]]  && kill -TERM "${SSHD_PID}"  2>/dev/null
  [[ -n "${MAINT_PID}" ]] && kill -TERM "${MAINT_PID}" 2>/dev/null
  if [[ -n "${DAEMON_PID}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
    kill -TERM "${DAEMON_PID}" 2>/dev/null
    # The daemon is not our child (it forked away), so poll instead of `wait`.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "${DAEMON_PID}" 2>/dev/null || break
      sleep 1
    done
  fi
}

shutdown() {
  trap - TERM INT
  echo "apt-cacher.sh: stop signal received; shutting down"
  stop_children
  exit 0
}
trap shutdown TERM INT

fatal() { echo "apt-cacher.sh FATAL: $1" >&2; exit 1; }

is_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }

is_posint "${DAEMON_PORT}"                   || fatal "DAEMON_PORT must be a positive integer (got '${DAEMON_PORT}')."
is_posint "${MAINTENANCE_INTERVAL_SECONDS}"  || fatal "MAINTENANCE_INTERVAL_SECONDS must be a positive integer (got '${MAINTENANCE_INTERVAL_SECONDS}')."
case "${DISTINCT_NAMESPACES}" in 0|1) ;; *) fatal "DISTINCT_NAMESPACES must be 0 or 1 (got '${DISTINCT_NAMESPACES}')." ;; esac
[ -n "${ALLOWED_HOSTS}" ] || fatal "ALLOWED_HOSTS must not be empty (empty would block every client)."

# ---------------------------------------------------------------------------
# (1) SSH management server prep (same pattern as the nginx/syslog containers).
# Host keys are generated at first start, not build time — per-container keys
# are better practice.
# ---------------------------------------------------------------------------
mkdir -p /var/run/sshd
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi
if [ -n "${PASSWORD:-}" ]; then
  echo "root:${PASSWORD}" | chpasswd
fi

# ---------------------------------------------------------------------------
# (2) Cache + log directories. Both are persistent RouterOS mounts, which arrive
# empty and root-owned on first start, so hand them to the daemon's user and
# let the package's install.pl create the layout it expects (packages/, headers/,
# private/, import/, ...). It is idempotent and takes ownership from the
# directory it is pointed at.
# ---------------------------------------------------------------------------
mkdir -p "${CACHE_DIR}" "${LOG_DIR}"
chown www-data:www-data "${CACHE_DIR}" "${LOG_DIR}"
/usr/share/apt-cacher/install.pl >/dev/null || fatal "install.pl failed to prepare ${CACHE_DIR}."
touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
chown www-data:www-data "${LOG_DIR}"/*.log
rm -f "${PIDFILE}"

# ---------------------------------------------------------------------------
# (3) Render the config fragment. conf.d is read after apt-cacher.conf, so
# these override the package defaults; later duplicates win.
# ---------------------------------------------------------------------------
{
  echo "# Generated by apt-cacher.sh from the container env. Do not edit."
  echo "daemon_port = ${DAEMON_PORT}"
  echo "allowed_hosts = ${ALLOWED_HOSTS}"
  echo "distinct_namespaces = ${DISTINCT_NAMESPACES}"
  echo "admin_email = ${ADMIN_EMAIL}"
  echo "cache_dir = ${CACHE_DIR}"
  echo "log_dir = ${LOG_DIR}"
  [ -n "${PATH_MAP:-}" ]         && echo "path_map = ${PATH_MAP}"
  [ -n "${DISK_USAGE_LIMIT:-}" ] && echo "disk_usage_limit = ${DISK_USAGE_LIMIT}"
} > "${CONF}"
echo "apt-cacher.sh: wrote ${CONF}:"
sed 's/^/  /' "${CONF}"

# ---------------------------------------------------------------------------
# (4) Start the daemon. -d forks into the background and writes the pidfile;
# -R 3 retries the port bind (the veth can be slow to come up at boot).
# ---------------------------------------------------------------------------
/usr/sbin/apt-cacher -R 3 -d -p "${PIDFILE}" || fatal "apt-cacher failed to start (see ${LOG_DIR}/error.log)."

for _ in $(seq 1 30); do
  [ -s "${PIDFILE}" ] && break
  sleep 1
done
[ -s "${PIDFILE}" ] || fatal "apt-cacher did not write ${PIDFILE} (see ${LOG_DIR}/error.log)."
DAEMON_PID="$(cat "${PIDFILE}")"
kill -0 "${DAEMON_PID}" 2>/dev/null || fatal "apt-cacher (pid ${DAEMON_PID}) is not running (see ${LOG_DIR}/error.log)."
echo "apt-cacher.sh: apt-cacher started (pid ${DAEMON_PID}) on port ${DAEMON_PORT}; allowed_hosts=${ALLOWED_HOSTS}"

# ---------------------------------------------------------------------------
# (5) Maintenance loop — replaces the package's /etc/cron.d entry. Each pass:
# regenerate the traffic report, clean obsolete packages, rotate logs. The
# first pass waits one full interval so a restart loop never hammers the
# cleaner. Failures are logged to the log dir, not stdout.
# ---------------------------------------------------------------------------
(
  sp=""
  trap '[[ -n "$sp" ]] && kill -TERM "$sp" 2>/dev/null; exit 0' TERM INT
  while :; do
    sleep "${MAINTENANCE_INTERVAL_SECONDS}" & sp=$!; wait "$sp"
    /usr/share/apt-cacher/apt-cacher-report.pl  >>"${LOG_DIR}/maintenance.log" 2>&1 \
      || echo "apt-cacher.sh: report failed ($?), see ${LOG_DIR}/maintenance.log" >&2
    /usr/share/apt-cacher/apt-cacher-cleanup.pl >>"${LOG_DIR}/maintenance.log" 2>&1 \
      || echo "apt-cacher.sh: cleanup failed ($?), see ${LOG_DIR}/maintenance.log" >&2
    logrotate -s "${LOG_DIR}/.logrotate.status" /etc/logrotate-apt-cacher.conf \
      >>"${LOG_DIR}/maintenance.log" 2>&1 \
      || echo "apt-cacher.sh: logrotate failed ($?), see ${LOG_DIR}/maintenance.log" >&2
  done
) &
MAINT_PID=$!
echo "apt-cacher.sh: maintenance (report, cleanup, logrotate) every ${MAINTENANCE_INTERVAL_SECONDS}s"

# ---------------------------------------------------------------------------
# (6) SSH.
# ---------------------------------------------------------------------------
/usr/sbin/sshd -D &
SSHD_PID=$!

# Container lifetime follows the daemon. Poll in short `wait`s so the TERM/INT
# trap fires promptly.
while kill -0 "${DAEMON_PID}" 2>/dev/null; do
  sleep 5 & wait $!
done
echo "apt-cacher.sh: apt-cacher (pid ${DAEMON_PID}) exited; stopping container" >&2
stop_children
exit 1
