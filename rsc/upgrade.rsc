# =============================================================================
# Upgrade/redeploy the apt-cacher container — Main Router (192.168.100.1)
#
# Mirrors ../../mikrotik-syslog/rsc/upgrade.rsc: capture the live container's
# settings, stop -> remove -> re-add from the LOCAL tar -> start. The re-add
# uses file=storage/apt-cacher-arm64.tar + cmd=/usr/local/bin/apt-cacher.sh
# (matching 01-router-apt-cacher.rsc STEP 4).
#
# Upload the new apt-cacher-arm64.tar to /storage BEFORE running this. The
# cache and log mounts (/storage/apt-cacher/{cache,log}) survive the re-add, so
# nothing is re-downloaded.
#
# While the container is down (~30s) LAN clients' apt runs fail to reach the
# proxy; they simply retry on their next run.
# =============================================================================

# Container identifier
:local hostname "apt-cacher-router";
/container
:local id [find where hostname=$hostname];
:local rootdir [get $id root-dir];
:local dns [get $id dns];
:local logging [get $id logging];
:local status [get $id status];
:local mounts [get $id mountlists];
:local envlist [get $id envlists];
:local interface [get $id interface];
:local startonboot [get $id start-on-boot];
:local restartpolicy [get $id restart-policy];
:local stoptime [get $id stop-time];
:global LogPrefix "AptCacher";
:local logI do={
    :global LogPrefix;
    :put ($LogPrefix . ": " . $1);
    :log info ($LogPrefix . ": " . $1);
}

# Stop the container
$logI "Stopping the container...";
stop $id
:while ($status != "stopped") do={
    $logI "Waiting for the container to stop...";
    :delay 5;
    :set status [get $id status];
}
$logI "Stopped.";

# Remove the container
remove $id
$logI "Removing the container...";
:while ($status = "stopped") do={
    $logI "Waiting for the container to be removed...";
    :delay 5;
    :set status [get $id status];
}
$logI "Removed.";

# Add the container (from the LOCAL tar). cmd is required on RouterOS 7.22+.
:delay 5;
$logI "Adding the container...";
add file=storage/apt-cacher-arm64.tar cmd=/usr/local/bin/apt-cacher.sh \
    interface=$interface envlists=$envlist root-dir=$rootdir mountlists=$mounts \
    start-on-boot=$startonboot hostname=$hostname dns=$dns logging=$logging \
    restart-policy=$restartpolicy stop-time=$stoptime \
    comment="apt-cacher Debian/Ubuntu package cache (apt-cacher.dids.atasha.net:3142)"
:do {
    :set status [get [find where hostname=$hostname] status];
    :if ($status != "stopped") do={
        $logI "Waiting for the container to be added...";
        :delay 5;
    }
} while ($status != "stopped")
$logI "Added."

# Start the container
$logI "Starting the container.";
:set id [find where hostname=$hostname];
start $id
