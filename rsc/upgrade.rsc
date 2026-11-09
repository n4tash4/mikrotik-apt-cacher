# =============================================================================
# Upgrade/redeploy the apt-cacher container — Main Router (192.168.100.1)
#
# Mirrors ../../mikrotik-syslog/rsc/upgrade.rsc: capture the live container's
# settings, stop -> remove -> re-add from the LOCAL tar -> start. The re-add
# uses file=storage/apt-cacher-arm64.tar + cmd=/usr/local/bin/apt-cacher.sh
# (matching 01-router-apt-cacher.rsc STEP 4).
#
# Upload the new apt-cacher-arm64.tar to /storage BEFORE running this. The
# cache and log mounts (/storage/apt-cacher/{cache,log}) and the envs survive
# the re-add, so nothing is re-downloaded.
#
# While the container is down (~1 min) LAN clients' apt runs fail to reach the
# proxy; they simply retry on their next run.
#
# RouterOS 7.25 notes (why this differs from the syslog/nginx upgrade scripts):
#  * There is no `status` property on /container; state is read through the
#    `running` / `stopped` flags with `find`.
#  * The variable is NOT named "hostname": inside `find where hostname=$x` a
#    variable with the same name as the property is shadowed by it, so the
#    filter matches EVERY container and `get` then fails on a multi-item id.
#  * `dns` is read back as an array, so it is hard-coded to match STEP 4.
# =============================================================================

:local cname "apt-cacher-router";
:global LogPrefix "AptCacher";
:local logI do={
    :global LogPrefix;
    :put ($LogPrefix . ": " . $1);
    :log info ($LogPrefix . ": " . $1);
}

/container
:local id [find where hostname=$cname];
:if ([:len $id] != 1) do={
    :error ("AptCacher: expected exactly one container with hostname " . $cname);
}
# Capture the live settings (envs and mounts are referenced by list name).
:local rootdir [get $id root-dir];
:local logging [get $id logging];
:local mounts [get $id mountlists];
:local envlist [get $id envlists];
:local interface [get $id interface];
:local startonboot [get $id start-on-boot];
:local restartpolicy [get $id restart-policy];
:local stoptime [get $id stop-time];

# Stop the container
$logI "Stopping the container...";
:if ([:len [find where hostname=$cname running]] > 0) do={
    stop $id
    :local n 0;
    # Wait for the STOPPED flag, not just !running: while "stopping" it is
    # neither, and remove refuses with "cannot remove running".
    :while (([:len [find where hostname=$cname stopped]] = 0) && ($n < 24)) do={
        $logI "Waiting for the container to stop...";
        :delay 5;
        :set n ($n + 1);
    }
}
$logI "Stopped.";

# Remove the container. No wait loop: `get` on a removed item is an error that
# would abort the script; the pause lets the root-dir be released.
$logI "Removing the container...";
remove $id
:delay 10;
$logI "Removed.";

# Add the container (from the LOCAL tar). cmd is required on RouterOS 7.22+.
$logI "Adding the container...";
add file=storage/apt-cacher-arm64.tar cmd=/usr/local/bin/apt-cacher.sh \
    interface=$interface envlists=$envlist root-dir=$rootdir mountlists=$mounts \
    start-on-boot=$startonboot hostname=$cname dns=192.168.102.1,8.8.8.8 \
    logging=$logging restart-policy=$restartpolicy stop-time=$stoptime \
    comment="apt-cacher Debian/Ubuntu package cache (apt-cacher.dids.atasha.net:3142)"

# Wait for the tar to extract (the new container becomes "stopped").
:local n 0;
:while (([:len [find where hostname=$cname stopped]] = 0) && ($n < 60)) do={
    $logI "Waiting for the container to be added...";
    :delay 5;
    :set n ($n + 1);
}
:if ([:len [find where hostname=$cname stopped]] = 0) do={
    :error "AptCacher: container did not reach the stopped state (extract failed?)";
}
$logI "Added.";

# Start the container
$logI "Starting the container.";
start [find where hostname=$cname]
