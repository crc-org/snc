#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

source tools.sh
source createdisk-library.sh

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i id_ecdsa_crc"

CRC_VM_NAME=${CRC_VM_NAME:-crc-podman}
BASE_OS=fedora-coreos

if [[ $# -ne 1 ]]; then
   echo "You need to provide crc-tmp-install-data"
   exit 1
fi


VM_IP=$(arp -an | grep $(sudo virsh dumpxml ${CRC_VM_NAME} | grep '<mac' | grep -o '\([0-9a-f][0-9a-f]:\)\+[0-9a-f][0-9a-f]') | grep -o '\([0-9]\{1,3\}\.\)\+[0-9]\{1,3\}')

# Remove audit logs
${SSH} core@${VM_IP} -- 'sudo find /var/log/ -iname "*.log" -exec rm -f {} \;'

install_additional_packages ${VM_IP}

# Add gvisor-tap-vsock
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock --privileged --net=host -v /etc/resolv.conf:/etc/resolv.conf -it quay.io/crcont/gvisor-tap-vsock:3231aba53905468c22e394493a0debc1a6cc6392
  podman generate systemd --restart-policy=no gvisor-tap-vsock > /etc/systemd/system/gvisor-tap-vsock.service
  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock.service
EOF

# Change the ownership of authorized_keys file
# https://bugzilla.redhat.com/show_bug.cgi?id=1956739
${SSH} core@${VM_IP} -- 'touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys'

# Shutdown and Start the VM after installing the hyperV daemon packages.
# This is required to get the latest ostree layer which have those installed packages.
shutdown_vm ${CRC_VM_NAME}
start_vm ${CRC_VM_NAME} ${VM_IP}

# Enable cockpit socket
${SSH} core@${VM_IP} -- 'sudo systemctl enable cockpit.socket'

# Only used for hyperkit bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # Get the rhcos ostree Hash ID
    ostree_hash=$(${SSH} core@${VM_IP} -- "cat /proc/cmdline | grep -oP \"(?<=${BASE_OS}-).*(?=/vmlinuz)\"")

    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@${VM_IP} -- 'cat /proc/cmdline')

    # SCP the vmlinuz/initramfs from VM to Host in provided folder.
    ${SCP} -r core@${VM_IP}:/boot/ostree/${BASE_OS}-${ostree_hash}/* $1
fi

podman_version=$(${SSH} core@${VM_IP} -- 'rpm -q --qf %{version} podman')

# Remove the journal logs.
# Note: With `sudo journalctl --rotate --vacuum-time=1s`, it doesn't
# remove all the journal logs so separate commands are used here.
${SSH} core@${VM_IP} -- 'sudo journalctl --rotate'
${SSH} core@${VM_IP} -- 'sudo journalctl --vacuum-time=1s'

# Shutdown the VM
shutdown_vm ${CRC_VM_NAME}

# Download podman clients
download_podman $podman_version

# libvirt image generation
destDirSuffix="${podman_version}"

libvirtDestDir="crc_podman_libvirt_${destDirSuffix}"
mkdir "$libvirtDestDir"

create_qemu_image "$1" "$libvirtDestDir"
copy_additional_files "$1" "$libvirtDestDir" "$podman_version"
create_tarball "$libvirtDestDir"

# HyperKit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    hyperkitDestDir="crc_podman_hyperkit_${destDirSuffix}"
    generate_hyperkit_bundle "$libvirtDestDir" "$hyperkitDestDir" "$1" "$kernel_release" "$kernel_cmd_line"
fi

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    hypervDestDir="crc_podman_hyperv_${destDirSuffix}"
    generate_hyperv_bundle "$libvirtDestDir" "$hypervDestDir"
fi

# Cleanup up vmlinux/initramfs files
rm -fr "$1/vmlinuz*" "$1/initramfs*"
