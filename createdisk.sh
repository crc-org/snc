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

INSTALL_DIR=${1:-crc-tmp-install-data}

VM_IP=$(sudo virsh domifaddr ${CRC_VM_NAME} | grep vnet | awk '{print $4}' | sed 's;/24;;')

# Remove moby-engine package
${SSH} core@${VM_IP} -- 'sudo rpm-ostree override remove moby-engine'

prepare_cockpit ${VM_IP}
prepare_hyperV ${VM_IP}
prepare_qemu_guest_agent ${VM_IP}

# Add gvisor-tap-vsock
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock --privileged --net=host -v /etc/resolv.conf:/etc/resolv.conf -it quay.io/crcont/gvisor-tap-vsock:latest
  podman generate systemd --restart-policy=no gvisor-tap-vsock > /etc/systemd/system/gvisor-tap-vsock.service
  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock.service
EOF

cleanup_vm_image ${CRC_VM_NAME} ${VM_IP}

# Only used for macOS bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@${VM_IP} -- 'cat /proc/cmdline')

    # Get the rhcos ostree Hash ID
    ostree_hash=$(echo ${kernel_cmd_line} | grep -oP "(?<=${BASE_OS}-).*(?=/vmlinuz)")

    # SCP the vmlinuz/initramfs from VM to Host in provided folder.
    ${SCP} -r core@${VM_IP}:/boot/ostree/${BASE_OS}-${ostree_hash}/* $INSTALL_DIR
fi

podman_version=$(${SSH} core@${VM_IP} -- 'rpm -q --qf %{version} podman')

# Shutdown the VM
shutdown_vm ${CRC_VM_NAME}

# Download podman clients
download_podman $podman_version ${yq_ARCH}

# libvirt image generation
get_dest_dir_suffix "${podman_version}"
destDirSuffix="${DEST_DIR_SUFFIX}"

libvirtDestDir="crc_podman_libvirt_${destDirSuffix}"
mkdir "$libvirtDestDir"

create_qemu_image "$libvirtDestDir" "fedora-coreos-qemu.${ARCH}.qcow2" "${CRC_VM_NAME}.qcow2"
copy_additional_files "$INSTALL_DIR" "$libvirtDestDir" "$podman_version"
create_tarball "$libvirtDestDir"

# vfkit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    vfkitDestDir="crc_podman_vfkit_${destDirSuffix}"
    generate_vfkit_bundle "$libvirtDestDir" "$vfkitDestDir" "$INSTALL_DIR" "$kernel_release" "$kernel_cmd_line"
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
rm -fr "$INSTALL_DIR/vmlinuz*" "$INSTALL_DIR/initramfs*"
