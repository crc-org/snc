#!/bin/bash

export LC_ALL=C
export LANG=C

set -x

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
OC=${OC:-oc}
DEVELOPER_USER_PASS='developer:$2y$05$paX6Xc9AiLa6VT7qr2VvB.Qi.GJsaqS80TR3Kb78FEIlIL0YyBuyS'

function get_dest_dir {
    if [ ${OPENSHIFT_VERSION} != "" ]; then
        DEST_DIR=$OPENSHIFT_VERSION
    else
        DEST_DIR=$(git describe --exact-match --tags HEAD)
        if [ -z ${DEST_DIR} ]; then
            DEST_DIR="$(date --iso-8601)"
        fi
    fi
}

function create_crc_libvirt_sh {
    local destDir=$1

    hostInfo=$(sudo virsh net-dumpxml ${VM_PREFIX} | grep ${VM_PREFIX}-master-0 | sed "s/^[ \t]*//")
    masterMac=$(sudo virsh dumpxml ${VM_PREFIX}-master-0 | grep "mac address" | sed "s/^[ \t]*//")

    sed "s|ReplaceMeWithCorrectVmName|${CRC_VM_NAME}|g" crc_libvirt.template > $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectBaseDomain|${BASE_DOMAIN}|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectHost|$hostInfo|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectMac|$masterMac|g" $destDir/crc_libvirt.sh

    chmod +x $destDir/crc_libvirt.sh
}

function create_qemu_image {
    local destDir=$1

    if [ -f /var/lib/libvirt/images/${VM_PREFIX}-master-0 ]; then
      sudo cp /var/lib/libvirt/images/${VM_PREFIX}-master-0 $destDir
      sudo cp /var/lib/libvirt/images/${VM_PREFIX}-base $destDir
    else
      sudo cp /var/lib/libvirt/openshift-images/${VM_PREFIX}/${VM_PREFIX}-master-0 $destDir
      sudo cp /var/lib/libvirt/openshift-images/${VM_PREFIX}/${VM_PREFIX}-base $destDir
    fi

    sudo chown $USER:$USER -R $destDir
    ${QEMU_IMG} rebase -b ${VM_PREFIX}-base $destDir/${VM_PREFIX}-master-0
    ${QEMU_IMG} commit $destDir/${VM_PREFIX}-master-0

    # Check which partition is labeled as `root`
    partition=$(${VIRT_FILESYSTEMS} -a $destDir/${VM_PREFIX}-base  -l | grep root | cut -f1 -d' ')

    # Resize the image from the default 1+15GB to 1+30GB
    ${QEMU_IMG} create -o lazy_refcounts=on -f qcow2 $destDir/${CRC_VM_NAME}.qcow2 31G
    ${VIRT_RESIZE} --expand $partition $destDir/${VM_PREFIX}-base $destDir/${CRC_VM_NAME}.qcow2
    if [ $? -ne 0 ]; then
            echo "${VIRT_RESIZE} call failed, disk image was not properly resized, aborting"
            exit 1
    fi

    # TMPDIR must point at a directory with as much free space as the size of the image we want to sparsify
    # Read limitation section of `man virt-sparsify`.
    TMPDIR=$(pwd)/$destDir ${VIRT_SPARSIFY} -o lazy_refcounts=on $destDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}_sparse.qcow2
    rm -f $destDir/${CRC_VM_NAME}.qcow2
    mv $destDir/${CRC_VM_NAME}_sparse.qcow2 $destDir/${CRC_VM_NAME}.qcow2
    rm -fr $destDir/.guestfs-*

    # Before using the created qcow2, check if it has lazy_refcounts set to true.
    ${QEMU_IMG} info ${destDir}/${CRC_VM_NAME}.qcow2 | grep "lazy refcounts: true" 2>&1 >/dev/null
    if [ $? -ne 0 ]; then
        echo "${CRC_VM_NAME}.qcow2 doesn't have lazy_refcounts enabled. This is going to cause disk image corruption when using with hyperkit"
        exit 1;
    fi

    rm -fr $destDir/${VM_PREFIX}-master-0 $destDir/${VM_PREFIX}-base
}

function update_json_description {
    local srcDir=$1
    local destDir=$2

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_rsa_crc"' \
        | ${JQ} '.clusterInfo.kubeConfig = "kubeconfig"' \
        | ${JQ} '.clusterInfo.kubeadminPasswordFile = "kubeadmin-password"' \
        | ${JQ} '.nodes[0].kind[0] = "master"' \
        | ${JQ} '.nodes[0].kind[1] = "worker"' \
        | ${JQ} ".nodes[0].hostname = \"${VM_PREFIX}-master-0\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} '.storage.diskImages[0].format = "qcow2"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "libvirt"' \
        >$destDir/crc-bundle-info.json
}

function copy_additional_files {
    local srcDir=$1
    local destDir=$2

    # Generate the libvirt sh file in source directory to test the disk image if required.
    # Don't include this in the destDir so it will not be part of final disk tarball.
    create_crc_libvirt_sh $srcDir

    # Copy the kubeconfig and kubeadm password file
    cp $1/auth/kube* $destDir/

    # Copy the master public key
    cp id_rsa_crc $destDir/
    chmod 400 $destDir/id_rsa_crc

    update_json_description $srcDir $destDir
}

function generate_vbox_directory {
    local srcDir=$1
    local destDir=$2

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/

    ${QEMU_IMG} convert -f qcow2 -O vmdk $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vmdk
    
    diskSize=$(du -b $destDir/${CRC_VM_NAME}.vmdk | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.vmdk | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.vmdk\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.vmdk\"" \
        | ${JQ} '.storage.diskImages[0].format = "vmdk"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "virtualbox"' \
        >$destDir/crc-bundle-info.json
}

function generate_hyperkit_directory {
    local srcDir=$1
    local destDir=$2
    local tmpDir=$3

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/
    cp $srcDir/${CRC_VM_NAME}.qcow2 $destDir/
    cp $tmpDir/vmlinuz-${kernel_release} $destDir/
    cp $tmpDir/initramfs-${kernel_release}.img $destDir/

    # Update the bundle metadata info
    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].kernel = \"vmlinuz-${kernel_release}\"" \
        | ${JQ} ".nodes[0].initramfs = \"initramfs-${kernel_release}.img\"" \
        | ${JQ} ".nodes[0].kernelCmdLine = \"${kernel_cmd_line}\"" \
        | ${JQ} '.driverInfo.name = "hyperkit"' \
        >$destDir/crc-bundle-info.json
}

function generate_hyperv_directory {
    local srcDir=$1
    local destDir=$2

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_rsa_crc $destDir/

    ${QEMU_IMG} convert -f qcow2 -O vhdx -o subformat=dynamic $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vhdx

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} '.storage.diskImages[0].format = "vhdx"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "hyperv"' \
        >$destDir/crc-bundle-info.json
}

# CRC_VM_NAME: short VM name to use in crc_libvirt.sh
# BASE_DOMAIN: domain used for the cluster
# VM_PREFIX: full VM name with the random string generated by openshift-installer
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
JQ=${JQ:-jq}
VIRT_RESIZE=${VIRT_RESIZE:-virt-resize}
QEMU_IMG=${QEMU_IMG:-qemu-img}
VIRT_SPARSIFY=${VIRT_SPARSIFY:-virt-sparsify}
VIRT_FILESYSTEMS=${VIRT_FILESYSTEMS:-virt-filesystems}

if [[ $# -ne 1 ]]; then
   echo "You need to provide the running cluster directory to copy kubeconfig"
   exit 1
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

if ! which ${VIRT_RESIZE}; then
    sudo yum -y install /usr/bin/virt-resize libguestfs-xfs
fi

if ! which ${VIRT_FILESYSTEMS}; then
    sudo yum -y install /usr/bin/virt-filesystems
fi

# The CoreOS image uses an XFS filesystem
# Beware than if you are running on an el7 system, you won't be able
# to resize the crc VM XFS filesystem as it was created on el8
if ! rpm -q libguestfs-xfs; then
    sudo yum install libguestfs-xfs
fi

if ! which ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi

# This random_string is created by installer and added to each resource type,
# in installer side also variable name is kept as `random_string`
# so to maintain consistancy, we are also using random_string here.
random_string=$(sudo virsh list --all | grep -oP "(?<=${CRC_VM_NAME}-).*(?=-master-0)")
if [ -z $random_string ]; then
    echo "Could not find virtual machine created by snc.sh"
    exit 1;
fi
VM_PREFIX=${CRC_VM_NAME}-${random_string}

# First check if cert rotation happened.
# Initial certificate is only valid for 24 hours, after rotation, it's valid for 30 days.
# We check if it's valid for more than 25 days rather than 30 days to give us some
# leeway regarding when we run the check with respect to rotation time
if ! ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem; then
    echo "Certs are not yet rotated to have 30 days validity"
    exit 1;
fi

# Add a user developer:developer with htpasswd identity provider and give it sudoer role
${OC} --config $1/auth/kubeconfig create secret generic htpass-secret --from-literal=htpasswd=${DEVELOPER_USER_PASS} -n openshift-config
${OC} --config $1/auth/kubeconfig apply -f htpasswd_cr.yaml
${OC} --config $1/auth/kubeconfig create clusterrolebinding developer --clusterrole=sudoer --user=developer

# Replace pull secret with a null json string '{}'
${OC} --config $1/auth/kubeconfig replace -f pull-secret.yaml

# Remove the Cluster ID with a empty string.
${OC} --config $1/auth/kubeconfig patch clusterversion version -p '{"spec":{"clusterID":""}}' --type merge

# Disable kubelet service and pull dnsmasq image from quay.io/crcon/dnsmasq
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl disable kubelet
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo podman pull quay.io/crcont/dnsmasq:latest

# Stop the kubelet service so it will not reprovision the pods
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl stop kubelet

# Remove all the pods from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl stopp $(sudo crictl pods -q)'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl rmp $(sudo crictl pods -q)'

# Remove pull secret from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -f /var/lib/kubelet/config.json'

# Download the hyperV daemons dependency on host
mkdir $1/hyperv
sudo yum install -y --downloadonly --downloaddir $1/hyperv hyperv-daemons

# SCP the downloaded rpms to VM
${SCP} -r $1/hyperv core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/

# Install the hyperV rpms to VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rpm-ostree install /home/core/hyperv/*.rpm'

# Remove the packages from VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- rm -fr /home/core/hyperv

# Shutdown and Start the VM after installing the hyperV daemon packages.
# This is required to get the latest ostree layer which have those installed packages.
sudo virsh shutdown ${VM_PREFIX}-master-0
# Wait till instance started successfully
until sudo virsh domstate ${VM_PREFIX}-master-0 | grep shut; do
    echo " ${VM_PREFIX}-master-0 still running"
    sleep 3
done

sudo virsh start ${VM_PREFIX}-master-0
# Wait till it is started properly.
until ping -c1 api.${CRC_VM_NAME}.${BASE_DOMAIN} >/dev/null 2>&1; do
    echo " ${VM_PREFIX}-master-0 still booting"
    sleep 2
done

# Get the rhcos ostree Hash ID
ostree_hash=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline | grep -oP "(?<=rhcos-).*(?=/vmlinuz)"')

# Get the rhcos kernel release
kernel_release=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'uname -r')

# Get the kernel command line arguments
kernel_cmd_line=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline')

# SCP the vmlinuz/initramfs from VM to Host in provided folder.
${SCP} core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/boot/ostree/rhcos-${ostree_hash}/* $1

# Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=1729603
# TODO: Should be removed once latest podman available or the fix is backported.
# Issue found in podman version 1.4.2-stable2 (podman-1.4.2-5.el8.x86_64)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -fr /etc/cni/net.d/100-crio-bridge.conf'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -fr /etc/cni/net.d/200-loopback.conf'

# Remove the journal logs.
# Note: With `sudo journalctl --rotate --vacuum-time=1s`, it doesn't 
# remove all the journal logs so separate commands are used here.
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo journalctl --rotate'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo journalctl --vacuum-time=1s'

# Shutdown the VM
sudo virsh shutdown ${VM_PREFIX}-master-0
# Wait till instance shutdown gracefully
until sudo virsh domstate ${VM_PREFIX}-master-0 | grep shut; do
    echo " ${VM_PREFIX}-master-0 still running"
    sleep 3
done

# instead of .tar.xz we use .crcbundle
crcBundleSuffix=crcbundle

# libvirt image generation
get_dest_dir
destDirSuffix="${DEST_DIR}"

libvirtDestDir="crc_libvirt_${destDirSuffix}"
mkdir $libvirtDestDir

create_qemu_image $libvirtDestDir

copy_additional_files $1 $libvirtDestDir

tar cJSf $libvirtDestDir.$crcBundleSuffix $libvirtDestDir

# HyperKit image generation
# This must be done after the generation of libvirt image as it reuse some of
# the content of $libvirtDestDir
hyperkitDestDir="crc_hyperkit_${destDirSuffix}"
mkdir $hyperkitDestDir
generate_hyperkit_directory $libvirtDestDir $hyperkitDestDir $1

tar cJSf $hyperkitDestDir.$crcBundleSuffix $hyperkitDestDir

# VirtualBox image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
vboxDestDir="crc_virtualbox_${destDirSuffix}"
mkdir $vboxDestDir
generate_vbox_directory $libvirtDestDir $vboxDestDir

tar cJSf $vboxDestDir.$crcBundleSuffix $vboxDestDir


# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
hypervDestDir="crc_hyperv_${destDirSuffix}"
mkdir $hypervDestDir
generate_hyperv_directory $libvirtDestDir $hypervDestDir

tar cJSf $hypervDestDir.$crcBundleSuffix $hypervDestDir
