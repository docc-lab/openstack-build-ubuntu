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

# Update repositories
# Update repositories
for repo in "dotfiles" "nova" "neutron" "osc_lib" "oslo.messaging" "osprofiler" "python-openstackclient" "oslo.log" "python-novaclient"
do
    cd /local/$repo
    # no key needed for public repos
    # GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /local/.ssh/$repo" git fetch --all
    git fetch -all
    git checkout $(git status | head -n 1 | awk '{print $3}') -f
    # GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /local/.ssh/$repo" git pull
    git pull
    cd /local
done

# Remove reconstruction repo & clone new pythia repo
echo "y" | rm -r /local/reconstruction/
sudo echo "y" | rm -i /users/geniuser/reconstruction
git clone https://github.com/docc-lab/pythia.git

mkdir -p /opt/stack/manifest
chmod -R g+rwX /opt/
chmod -R o+rwX /opt/
maybe_install_packages chrony redis-server python-redis python3-redis python3-pip
service_start redis

maybe_install_packages python3-pip

# Bring back rustup for compilation error
su geniuser -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
source $HOME/.cargo/env
rustup update stable
echo "**** Mert updating rust for match compile error ***"


chown geniuser -R /local/pythia
su geniuser -c "cargo update --manifest-path /local/pythia/Cargo.toml -p lexical-core"
su geniuser -c "cargo update --manifest-path /local/pythia/pythia_server/Cargo.toml -p lexical-core"
su geniuser -c "cargo install --locked --path /local/pythia"
su geniuser -c "cargo install --locked --path /local/pythia/pythia_server"
sudo ln -s /users/geniuser/.cargo/bin/pythia_server /usr/local/bin/
sudo ln -s /local/pythia /users/geniuser/
sudo ln -s /local/dotfiles /users/geniuser/

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

for project in "osprofiler" "osc_lib" "python-openstackclient" "nova" "oslo.messaging" "neutron" "oslo.log" "python-novaclient"
do
    pip3 install --force-reinstall --no-deps -U /local/$project
done

chmod o+rX /etc/nova
chmod g+rX /etc/nova
chmod o+r /etc/nova/nova.conf
chmod g+r /etc/nova/nova.conf

# sudo sed -i 's/level = .*/level = DEBUG/g' /etc/nova/logging.conf
# sudo sed -i 's/level=.*/level=DEBUG/g' /etc/keystone/logging.conf

service_restart ceilometer-agent-compute.service
service_restart chrony.service
service_restart neutron-openvswitch-agent.service
service_restart nova-compute.service
sudo systemctl stop ntp.service
sudo systemctl disable ntp.service
service_restart libvirt-guests.service

sudo chronyc -a 'burst 4/4'

sudo ln -s /local/pythia/etc/systemd/system/pythia.service /etc/systemd/system/
sudo ln -s /local/pythia/etc/pythia /etc/
chmod -R g+rwX /etc/pythia
chmod -R o+rwX /etc/pythia

sudo systemctl start pythia.service

touch $OURDIR/setup-pythia-compute-done
logtend "pythia-compute"

chown geniuser -R /local
su geniuser -c 'cd /local/dotfiles; ./setup_cloudlab.sh'

sudo chsh geniuser --shell /bin/bash

exit 0
