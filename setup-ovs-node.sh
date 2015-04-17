#!/bin/sh

#
# This sets up openvswitch networks (on neutron, the external and data
# networks).  The networkmanager and compute nodes' physical interfaces
# have to get moved into br-ex and br-int, respectively -- on the
# moonshots, that's eth0 and eth1.  The controller is special; it doesn't
# get an openvswitch setup, and gets eth1 10.0.0.3/8 .  The networkmanager
# is also special; it gets eth1 10.0.0.1/8, but its eth0 moves into br-ex,
# and its eth1 moves into br-int.  The compute nodes get IP addrs from
# 10.0.1.1/8 and up, but setup-ovs.sh determines that.
#

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

#
# Figure out which interfaces need to go where.  We already have 
# $EXTERNAL_NETWORK_INTERFACE from setup-lib.sh , and it and its configuration
# get applied to br-ex .  So, we need to find which interface corresponds to
# DATALAN on this node, if any, and move it (and its configuration OR its new
# new DATAIP iff USE_EXISTING_DATA_IPS was set) to br-int
#
EXTERNAL_NETWORK_BRIDGE="br-ex"
#DATA_NETWORK_INTERFACE=`ip addr show | grep "inet $MYIP" | sed -e "s/.*scope global \(.*\)\$/\1/"`
DATA_NETWORK_BRIDGE="br-data"
INTEGRATION_NETWORK_BRIDGE="br-int"

#
# If this is the controller, we don't have to do much network setup; just
# setup the data network with its IP.
#
#if [ "$HOSTNAME" = "$CONTROLLER" ]; then
#    if [ ${USE_EXISTING_DATA_IPS} -eq 0 ]; then
#	ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#    fi
#    exit 0;
#fi

#
# Otherwise, first we need openvswitch.
#
apt-get install -y openvswitch-common openvswitch-switch

# Make sure it's running
service openvswitch restart

#
# Setup the external network
#
ovs-vsctl add-br ${EXTERNAL_NETWORK_BRIDGE}
ovs-vsctl add-port ${EXTERNAL_NETWORK_BRIDGE} ${EXTERNAL_NETWORK_INTERFACE}
#ethtool -K $EXTERNAL_NETWORK_INTERFACE gro off

#
# Now move the $EXTERNAL_NETWORK_INTERFACE and default route config to ${EXTERNAL_NETWORK_BRIDGE}
#
mynetmask=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*Mask:\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
mygw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

DNSDOMAIN=`cat /etc/resolv.conf | grep search | awk '{ print $2 }'`
DNSSERVER=`cat /etc/resolv.conf | grep nameserver | awk '{ print $2 }'`

#
# We need to blow away the Emulab config -- no more dhcp
# This would definitely break experiment modify, of course
#
cat <<EOF > /etc/network/interfaces
#
# Openstack Network Node in Cloudlab/Emulab/Apt/Federation
#

# The loopback network interface
auto lo
iface lo inet loopback

auto ${EXTERNAL_NETWORK_BRIDGE}
iface ${EXTERNAL_NETWORK_BRIDGE} inet static
    address $MYIP
    netmask $mynetmask
    gateway $mygw
    dns-search $DNSDOMAIN
    dns-nameservers $DNSSERVER

auto ${EXTERNAL_NETWORK_INTERFACE}
iface ${EXTERNAL_NETWORK_INTERFACE} inet static
    address 0.0.0.0
EOF

ifconfig ${EXTERNAL_NETWORK_INTERFACE} 0 up
ifconfig ${EXTERNAL_NETWORK_BRIDGE} $MYIP netmask $mynetmask up
route add default gw $mygw

service openvswitch-switch restart

#
# Add the management network config if necessary (if not, it's already a VPN)
#
if [ ! -z "$MGMTLAN" ]; then
    cat <<EOF >> /etc/network/interfaces

auto ${MGMT_NETWORK_INTERFACE}
iface ${MGMT_NETWORK_INTERFACE} inet static
    address $MGMTIP
    netmask $MGMTNETMASK
EOF
    if [ -n "$MGMTVLANDEV" ]; then
	cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${MGMTVLANDEV}
EOF
    fi
fi

#
# Make sure we have the integration bridge
#
ovs-vsctl add-br ${INTEGRATION_NETWORK_BRIDGE}

#
# (Maybe) Setup the data network
#
if [ ${SETUP_FLAT_DATA_NETWORK} -eq 1 ]; then
    ovs-vsctl add-br ${DATA_NETWORK_BRIDGE}

    ovs-vsctl add-port ${DATA_NETWORK_BRIDGE} ${DATA_NETWORK_INTERFACE}
    ifconfig ${DATA_NETWORK_INTERFACE} 0 up
    cat <<EOF >> /etc/network/interfaces

auto ${DATA_NETWORK_BRIDGE}
iface ${DATA_NETWORK_BRIDGE} inet static
    address $DATAIP
    netmask $DATANETMASK

auto ${DATA_NETWORK_INTERFACE}
iface ${DATA_NETWORK_INTERFACE} inet static
    address 0.0.0.0
EOF
    if [ -n "$DATAVLANDEV" ]; then
	cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${DATAVLANDEV}
EOF
    fi

    ifconfig ${DATA_NETWORK_BRIDGE} $DATAIP netmask $DATANETMASK up
    # XXX!
    route add -net 10.0.0.0/8 dev ${DATA_NETWORK_BRIDGE}
else
    ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up

    cat <<EOF >> /etc/network/interfaces

auto ${DATA_NETWORK_INTERFACE}
iface ${DATA_NETWORK_INTERFACE} inet static
    address $DATAIP
    netmask $DATANETMASK
EOF
    if [ -n "$DATAVLANDEV" ]; then
	cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${DATAVLANDEV}
EOF
    fi
fi

#
# Set the hostname for later after reboot!
#
echo `hostname` > /etc/hostname

service openvswitch-switch restart

ip route flush cache

# Just wait a bit
#sleep 8

echo "*** Removing Emulab rc.hostnames and rc.ifconfig boot scripts"
mv /usr/local/etc/emulab/rc/rc.hostnames /usr/local/etc/emulab/rc/rc.hostnames.NO
mv /usr/local/etc/emulab/rc/rc.ifconfig /usr/local/etc/emulab/rc/rc.ifconfig.NO

#
# Install a basic ARP reply filter that prevents us from sending ARP replies on
# the control net for anything we're not allowed to use (i.e., we can reply for
# ourselves, and any public addresses we're allowed to use).  Really, we only
# need the public address part on the network manager, but may as well let
# any node reply as any public address we're allowed to use).
#

# Cheat and use our IPADDR/NETMASK instead of NETWORK/NETMASK below...
OURNET=`ip addr show br-ex | sed -n -e 's/.*inet \([0-9\.\/]*\) .*/\1/p'`
# Grab the port that corresponds to our
OURPORT=`ovs-ofctl show br-ex | sed -n -e "s/[ \t]*\([0-9]*\)(${EXTERNAL_NETWORK_INTERFACE).*\$/\1/p"`

ovs-ofctl add-flow br-ex \
    "dl_type=0x0806,nw_proto=0x2,arp_spa=${MYIP},actions=NORMAL"
for addr in $PUBLICADDRS ; do
    ovs-ofctl add-flow br-ex \
	"dl_type=0x0806,nw_proto=0x2,arp_spa=${addr},actions=NORMAL"
done
# Allow any inbound ARP replies on the control network.
ovs-ofctl add-flow br-ex \
    "dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},in_port=${OURPORT},actions=NORMAL"
# Drop any other control network addr ARP replies on the br-ex switch.
ovs-ofctl add-flow br-ex \
    "dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},actions=drop"

exit 0
