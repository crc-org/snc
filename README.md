# Single node cluster (snc) scripts for openshift-4 

## How to use?
- Make sure the one time setup is satisfied. (https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#one-time-setup)
  In the snc case, the NetworkManager DNS overlay file at `/etc/NetworkManager/dnsmasq.d/openshift.conf` should contain:
  ```
  server=/crc.testing/192.168.126.1
  address=/apps-crc.testing/192.168.126.11
  ```
- Build the installer using the `libvirt` tag. ( https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#build-and-run-the-installer )
- If you want to build the installer for an official OpenShift release, you
  should also set `RELEASE_IMAGE` when building the installer:
  ```
  RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.1.0-rc.1 TAGS=libvirt hack/build.sh
  ```
- Clone this repo `git clone https://github.com/code-ready/snc.git`
- cp <built_installer_binary> <directory_to_cloned_repo>
- cd <directory_to_cloned_repo>
- ./snc.sh

## How to create disk image?
- Once your `snc.sh` script run successfully.
- You need to wait for around 24 hours for initial cert rotation for kubelet server/client.
	- https://bugzilla.redhat.com/show_bug.cgi?id=1693951
- ./createdisk.sh crc-tmp-install-data
