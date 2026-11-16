/interface/veth/add name=veth-apt-cacher address=10.0.20.4/24 gateway=10.0.20.1 \
    comment="apt-cacher container"
/interface/bridge/port/add bridge=bridge-containers interface=veth-apt-cacher

# ALLOWED_HOSTS must cover the same clients as the apt-cacher-clients address list below.
/container/envs/add list=apt-cacher key="ALLOWED_HOSTS"         value="10.0.0.0/8"
/container/envs/add list=apt-cacher key="DISTINCT_NAMESPACES"   value="1"
/container/envs/add list=apt-cacher key="DISK_USAGE_LIMIT"      value="20GiB"
/container/envs/add list=apt-cacher key="ALLOWED_SSL_LOCATIONS" value="download.docker.com"
/container/envs/add list=apt-cacher key="AUTHORIZED_KEYS"       value="<your-ssh-public-key>"

/container/mounts/add list=apt-cacher src=/storage/container-data/apt-cacher/cache         dst=/var/cache/apt-cacher mode=rw
/container/mounts/add list=apt-cacher src=/storage/container-data/apt-cacher/log           dst=/var/log/apt-cacher   mode=rw
/container/mounts/add list=apt-cacher src=/storage/container-data/apt-cacher/ssh-host-keys dst=/etc/ssh/host-keys    mode=rw

/container/add file=storage/apt-cacher-arm64.tar interface=veth-apt-cacher \
    envlists=apt-cacher mountlists=apt-cacher hostname=apt-cacher-router \
    dns=10.0.20.1 root-dir=/storage/containers/apt-cacher \
    cmd=/usr/local/bin/apt-cacher.sh start-on-boot=yes logging=yes \
    restart-policy=on-failure stop-time=20s \
    comment="apt-cacher (apt-cacher.example.com:3142)"

# apt-cacher-clients must stay consistent with ALLOWED_HOSTS in the container env above.
/ip/firewall/address-list/add list=apt-cacher-clients address=10.0.1.0/24  comment="apt-cacher: LAN"
/ip/firewall/address-list/add list=apt-cacher-clients address=10.0.10.0/24 comment="apt-cacher: management"
/ip/firewall/filter/add chain=forward action=accept protocol=tcp \
    src-address-list=apt-cacher-clients dst-address=10.0.20.4 dst-port=3142 \
    place-before=0 comment="apt-cacher: clients to cache"

/ip/dns/static/add name="apt-cacher.example.com" type=A address=10.0.20.4 \
    comment="apt-cacher"
