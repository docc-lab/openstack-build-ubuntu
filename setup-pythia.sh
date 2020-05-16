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
# Don't run setup-pythia.sh twice
if [ -f $OURDIR/setup-pythia-done ]; then
    echo "setup-pythia already ran; not running again"
    exit 0
fi

logtstart "pythia"

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

maybe_install_packages pssh chrony
PSSH='/usr/bin/parallel-ssh -t 0 -O StrictHostKeyChecking=no '
PSCP='/usr/bin/parallel-scp -t 0 -O StrictHostKeyChecking=no '

cd /local

# Update repositories
for repo in "dotfiles" "nova" "neutron" "osc_lib" "oslo.messaging" "osprofiler" "python-openstackclient" "reconstruction" "oslo.log"
do
    cd /local/$repo
    GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /local/.ssh/$repo" git pull
    cd /local
done

PHOSTS=""
mkdir -p $OURDIR/pssh.setup-pythia.stdout $OURDIR/pssh.setup-pythia.stderr

for node in $COMPUTENODES
do
    PHOSTS="$PHOSTS -H $node"
done

echo "*** Setting up Pythia on compute nodes: $PHOSTS"
$PSSH -v $PHOSTS -o $OURDIR/pssh.setup-pythia.stdout \
    -e $OURDIR/pssh.setup-pythia.stderr $DIRNAME/setup-pythia-compute.sh

maybe_install_packages python3-pip
chown emreates -R /local/reconstruction
su emreates -c "cargo install --path /local/reconstruction"
su emreates -c "cargo install --path /local/reconstruction/pythia_server"
sudo ln -s /users/emreates/.cargo/bin/pythia_server /usr/local/bin/

mkdir -p /opt/stack/manifest
chmod -R g+rwX /opt/
chmod -R o+rwX /opt/
maybe_install_packages redis-server python-redis python3-redis python3-pip
service_start redis

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
echo "$profiler_conf" >> /etc/cinder/cinder.conf
echo "$profiler_conf" >> /etc/neutron/neutron.conf
echo "$profiler_conf" >> /etc/glance/glance-api.conf

for project in "osprofiler" "osc_lib" "python-openstackclient" "nova" "oslo.messaging" "neutron" "oslo.log"
do
    pip3 install --force-reinstall --no-deps -U /local/$project
done

chmod o+rX /etc/nova
chmod g+rX /etc/nova
chmod o+r /etc/nova/nova.conf
chmod g+r /etc/nova/nova.conf

# sudo sed -i 's/level = .*/level = DEBUG/g' /etc/nova/logging.conf
# sudo sed -i 's/level=.*/level=DEBUG/g' /etc/keystone/logging.conf

service_restart apache2.service
service_restart ceilometer-agent-central.service
service_restart ceilometer-agent-notification.service
service_restart chrony.service
sudo systemctl stop ntp.service
sudo systemctl disable ntp.service
service_restart cinder-scheduler.service
service_restart cinder-volume.service
service_restart designate-api.service
service_restart designate-central.service
service_restart designate-mdns.service
service_restart designate-producer.service
service_restart designate-worker.service
service_restart glance-api.service
service_restart gnocchi-metricd.service
service_restart heat-api-cfn.service
service_restart heat-api.service
service_restart heat-engine.service
service_restart magnum-api.service
service_restart magnum-conductor.service
service_restart manila-api.service
service_restart manila-scheduler.service
service_restart manila-share.service
service_restart memcached.service
service_restart neutron-dhcp-agent.service
service_restart neutron-l3-agent.service
service_restart neutron-lbaasv2-agent.service
service_restart neutron-metadata-agent.service
service_restart neutron-metering-agent.service
service_restart neutron-openvswitch-agent.service
service_restart neutron-ovs-cleanup.service
service_restart neutron-server.service
service_restart nginx.service
service_restart nova-api.service
service_restart nova-conductor.service
service_restart nova-consoleauth.service
service_restart nova-novncproxy.service
service_restart nova-scheduler.service
service_restart rabbitmq-server.service
service_restart redis-server.service
service_restart sahara-engine.service
service_restart swift-account-auditor.service
service_restart swift-account-reaper.service
service_restart swift-account-replicator.service
service_restart swift-account.service
service_restart swift-container-auditor.service
service_restart swift-container-replicator.service
service_restart swift-container-sync.service
service_restart swift-container-updater.service
service_restart swift-container.service
service_restart swift-object-auditor.service
service_restart swift-object-reconstructor.service
service_restart swift-object-replicator.service
service_restart swift-object-updater.service
service_restart swift-object.service
service_restart swift-proxy.service
service_restart trove-api.service
service_restart trove-conductor.service
service_restart trove-taskmanager.service

sudo chronyc -a 'burst 4/4'

wget https://download.cirros-cloud.net/0.4.0/cirros-0.4.0-${ARCH}-disk.img
openstack image create --file cirros-0.4.0-${ARCH}-disk.img cirros

sudo ln -s /local/reconstruction/etc/systemd/system/pythia.service /etc/systemd/system/
sudo ln -s /local/reconstruction/etc/pythia /etc/
chmod -R g+rwX /etc/pythia
chmod -R o+rwX /etc/pythia

sudo systemctl start pythia.service

touch $OURDIR/setup-pythia-done
logtend "pythia"
chown emreates -R /local
su emreates -c 'cd /local/dotfiles; ./setup_cloudlab.sh'
exit 0
