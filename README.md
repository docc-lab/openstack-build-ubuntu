These are a collection of scripts that install and configuration
Openstack Juno on Ubuntu 14 and onwards, within an Emulab/Apt/Cloudlab
testbed experiment.

# Starting OpenStack

1. Go to cloudlab.us
2. Start an experiment with the `pythia-openstack` project.
3. Parameters: The only parameters tested to work are # of compute nodes and
   disk image. For disk image, use `tracing-pythia-PG0//base-with-repos` for
   both node types (compute/controller).
4. Select your cluster (I usually use Utah) and schedule creation/create
   immediately.
5. Wait for ~1 hours until you get an email saying openstack is ready. Before
   this, the setup **will** be unusable.

# What is this repo

It is forked from https://gitlab.flux.utah.edu/johnsond/openstack-build-ubuntu
and keeping it updated may be a good idea. The scripts to set up pythia are
called `setup-pythia.sh` and `setup-pythia-compute.sh`, they should be
self-explanatory. They pull the latest repos from github using ssh keys inside
the disk image and install them to overwrite whatever the rest of the scripts
install, also they partially install pythia.

# When to update this

When a new openstack package is forked (e.g., to add more instrumentation), add
it to setup pythia scripts similar to how nova is done currently. Also, use the
pythia scripts to change the configuration of openstack services if necessary.

# Using OpenStack
Inside the dotfiles repository, there should be some aliases (in
`cloudlab.bashrc`). For example, `create_vm` `pythia_status`. Other than that,
check openstack docs.
