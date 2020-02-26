#!/bin/bash

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"
# Don't run setup-pythia-compute.sh twice
if [ -f $OURDIR/setup-pythia-compute-done ]; then
    echo "setup-pythia already ran; not running again"
    exit 0
fi

logtstart "pythia-compute"

#
# openstack CLI commands seem flakey sometimes on Kilo and Liberty.
# Don't know if it's WSGI, mysql dropping connections, an NTP
# thing... but until it gets solved more permanently, have to retry :(.
#
__openstack() {
    __err=1
    __debug=
    __times=0
    while [ $__times -lt 16 -a ! $__err -eq 0 ]; do
	openstack $__debug "$@"
	__err=$?
        if [ $__err -eq 0 ]; then
            break
        fi
	__debug=" --debug "
	__times=`expr $__times + 1`
	if [ $__times -gt 1 ]; then
	    echo "ERROR: openstack command failed: sleeping and trying again!"
	    sleep 8
	fi
    done
}

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

cd /local
mkdir -p /opt/stack/manifest
chmod -R g+rwX /opt/
chmod -R o+rwX /opt/
maybe_install_packages redis-server python-redis python3-redis python3-pip
service_start redis

echo "*** Installing Rust"
maybe_install_packages python3-pip

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
rustup component add rls

cargo install --path /local/reconstruction
echo "*** Finished installing Rust"

echo -e 'nova\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers

profiler_conf=$(cat <<END
[profiler]
enabled = True
connection_string = redis://localhost:6379
hmac_keys = Devstack1
trace_wsgi_transport = True
trace_message_store = True
trace_management_store = True
trace_sqlalchemy = False
END
)

echo "$profiler_conf" >> /etc/nova/nova.conf
echo "$profiler_conf" >> /etc/keystone/keystone.conf
echo "$profiler_conf" >> /etc/neutron/neutron.conf

for project in "osprofiler" "osc_lib" "python-openstackclient" "nova" "oslo.messaging" "neutron"
do
    pip3 install --force-reinstall --no-deps -U /local/$project
done

chmod o+rX /etc/nova
chmod g+rX /etc/nova
chmod o+r /etc/nova/nova.conf
chmod g+r /etc/nova/nova.conf

service_restart ceilometer-agent-compute.service
service_restart neutron-openvswitch-agent.service
service_restart nova-compute.service
service_restart libvirt-guests.service

touch $OURDIR/setup-pythia-compute-done
logtend "pythia-compute"
exit 0
