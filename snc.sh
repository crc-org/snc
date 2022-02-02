#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

# kill all the child processes for this script when it exits
trap 'jobs=($(jobs -p)); [ -n "${jobs-}" ] && ((${#jobs})) && kill "${jobs[@]}" || true' EXIT

CRC_VM_NAME=${CRC_VM_NAME:-crc-podman}
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"

run_preflight_checks

sudo virsh destroy ${CRC_VM_NAME} || true
sudo virsh undefine --nvram ${CRC_VM_NAME} || true
sudo rm -fr /var/lib/libvirt/images/crc-podman.qcow2

CRC_INSTALL_DIR=crc-tmp-install-data
rm -fr ${CRC_INSTALL_DIR}
mkdir ${CRC_INSTALL_DIR}
current_selinux_context=$(ls -Z | grep ${CRC_INSTALL_DIR} | cut -f1 -d" ")
cp fcos-config.yaml ${CRC_INSTALL_DIR}

# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

${YQ} eval --inplace ".passwd.users[0].ssh_authorized_keys[0] = \"$(cat id_ecdsa_crc.pub)\"" ${CRC_INSTALL_DIR}/fcos-config.yaml

# Create the ign config 
${PODMAN} run -i --rm quay.io/coreos/butane:latest --pretty --strict < ${CRC_INSTALL_DIR}/fcos-config.yaml > ${CRC_INSTALL_DIR}/fcos-config.ign

# Validate ign config
${PODMAN} run --pull=always --rm -i quay.io/coreos/ignition-validate:release - < ${CRC_INSTALL_DIR}/fcos-config.ign

# Download the latest fedora coreos latest qcow2
${PODMAN} run --pull=always --rm -v ${PWD}/${CRC_INSTALL_DIR}:/data:Z -w /data quay.io/coreos/coreos-installer:release download -a ${ARCH} -s stable -p qemu -f qcow2.xz --decompress
mv ${CRC_INSTALL_DIR}/fedora-coreos-*-qemu.${ARCH}.qcow2 ${CRC_INSTALL_DIR}/fedora-coreos-qemu.${ARCH}.qcow2

# Update the selinux context for ign config and ${CRC_INSTALL_DIR}
chcon --verbose ${current_selinux_context} ${CRC_INSTALL_DIR}
chcon --verbose unconfined_u:object_r:svirt_home_t:s0 ${CRC_INSTALL_DIR}/fcos-config.ign
sudo setfacl -m u:qemu:rx $HOME
sudo systemctl restart libvirtd

create_json_description

# Start the VM using virt-install command
sudo ${VIRT_INSTALL} --name=${CRC_VM_NAME} --vcpus=2 --ram=2048 --arch=${ARCH}\
	--import --graphics=none \
	--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${PWD}/${CRC_INSTALL_DIR}/fcos-config.ign" \
	--disk=size=31,backing_store=${PWD}/${CRC_INSTALL_DIR}/fedora-coreos-qemu.${ARCH}.qcow2 \
	--os-variant=fedora-coreos-stable \
	--noautoconsole --quiet
sleep 120
