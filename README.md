# Single node cluster (snc) scripts for openshift-4 

## How to use?
- Make sure the one time setup is satisfied. (https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#one-time-setup)
- Clone this repo `git clone https://github.com/code-ready/snc.git`
- cd <directory_to_cloned_repo>
- ./snc.sh

> *Note for building a 4.4 image:* See https://github.com/code-ready/snc/wiki/Workaround-for-4.4--etcd-operator-addition.

## How to create disk image?
- Once your `snc.sh` script run successfully.
- You need to wait for around 30 mins till cluster settle.
- ./createdisk.sh crc-tmp-install-data
