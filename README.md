# Single node cluster (snc) scripts for openshift-4 

## How to use?
- Make sure the one time setup is satisfied. (https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#one-time-setup)
- Build the installer using the `libvirt` tag. ( https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#build-and-run-the-installer )
- Clone this repo `git clone https://github.com/praveenkumar/snc.git`
- cp <built_installer_binary> <directory_to_cloned_repo>
- cd <directory_to_cloned_repo>
- ./openshift-install create install-config
- Set `compute/replicas` to 0 in `install-config.yaml` file.
- ./snc.sh

## How to create disk image?
- Once your `snc.sh` script run successfully.
- You need to wait for around 24 hours for initial cert rotation for kubelet server/client.
	- https://bugzilla.redhat.com/show_bug.cgi?id=1693951
- ./createdisk.sh test
