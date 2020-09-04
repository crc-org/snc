#!/bin/bash

export LC_ALL=C
export LANG=C

set -x

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
OC=${OC:-oc}
DEVELOPER_USER_PASS='developer:$2y$05$paX6Xc9AiLa6VT7qr2VvB.Qi.GJsaqS80TR3Kb78FEIlIL0YyBuyS'
# If the user set OKD_VERSION in the environment, then use it to override OPENSHIFT_VERSION, set BASE_OS, and set USE_LUKS
# Unless, those variables are explicitly set as well.
OKD_VERSION=${OKD_VERSION:-none}
if [[ ${OKD_VERSION} != "none" ]]
then
    OPENSHIFT_VERSION=${OKD_VERSION}
    BASE_OS=fedora-coreos
    USE_LUKS=false
fi
BASE_OS=${BASE_OS:-rhcos}
USE_LUKS=${USE_LUKS:-true}

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

function sparsify {
    local baseDir=$1
    local srcFile=$2
    local destFile=$3

    # Check which partition is labeled as `root`
    partition=$(${VIRT_FILESYSTEMS} -a $baseDir/$srcFile -l --partitions | sort -rk4 -n | sed -n 1p | cut -f1 -d' ')
    
    # https://bugzilla.redhat.com/show_bug.cgi?id=1837765
    export LIBGUESTFS_MEMSIZE=2048
    # Interact with guestfish directly
    # Starting with 4.3, the root partition is an encryption-ready luks partition
    # - virt-sparsify is not able to deal at all with this partition
    # The following commands will do all of the above after mounting the luks partition
    eval $(echo nokey | ${GUESTFISH}  --keys-from-stdin --listen )
    if [ $? -ne 0 ]; then
            echo "${GUESTFISH} failed to start, aborting"
            exit 1
    fi

    guestfish --remote <<EOF
add-drive $baseDir/$srcFile
run
EOF

    if [[ ${USE_LUKS} == "true" ]]
    then
        guestfish --remote <<EOF
luks-open $partition coreos-root
mount /dev/mapper/coreos-root /
EOF
    else
        guestfish --remote mount $partition /
    fi

    guestfish --remote zero-free-space /boot/
    if [ $? -ne 0 ]; then
            echo "Failed to sparsify $baseDir/$srcFile, aborting"
            exit 1
    fi

    ${GUESTFISH} --remote -- exit

    ${QEMU_IMG} convert -p -f qcow2 -O qcow2 -o lazy_refcounts=on $baseDir/$srcFile $baseDir/$destFile
    if [ $? -ne 0 ]; then
            echo "Failed to sparsify $baseDir/$srcFile, aborting"
            exit 1
    fi

    rm -fr $baseDir/.guestfs-*
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

    sparsify $destDir ${VM_PREFIX}-base ${CRC_VM_NAME}.qcow2

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
        | ${JQ} ".nodes[0].internalIP = \"${INTERNAL_IP}\"" \
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
VIRT_FILESYSTEMS=${VIRT_FILESYSTEMS:-virt-filesystems}
GUESTFISH=${GUESTFISH:-guestfish}
DIG=${DIG:-dig}

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

if ! which ${GUESTFISH}; then
    sudo yum -y install /usr/bin/guestfish
fi

if ! which ${DIG}; then
    sudo yum -y install /usr/bin/dig
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
    # Only validate the cert expire time if SNC_VALIDATE_CERT is set to true
    if [ "${SNC_VALIDATE_CERT:-true}" = true ]; then
        exit 1;
    fi
fi

# Add a user developer:developer with htpasswd identity provider and give it sudoer role
${OC} --kubeconfig $1/auth/kubeconfig create secret generic htpass-secret --from-literal=htpasswd=${DEVELOPER_USER_PASS} -n openshift-config
${OC} --kubeconfig $1/auth/kubeconfig apply -f htpasswd_cr.yaml
${OC} --kubeconfig $1/auth/kubeconfig create clusterrolebinding developer --clusterrole=sudoer --user=developer

# Get cluster-kube-apiserver-operator image along with hash and tag it
certImage=$(${OC} --kubeconfig $1/auth/kubeconfig adm release info --image-for=cluster-kube-apiserver-operator)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo podman tag $certImage openshift/cert-recovery

# Remove unused images from container storage
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl images -q | xargs -n 1 sudo crictl rmi 2>/dev/null'

# Replace pull secret with a null json string '{}'
${OC} --kubeconfig $1/auth/kubeconfig replace -f pull-secret.yaml

# Remove the Cluster ID with a empty string.
${OC} --kubeconfig $1/auth/kubeconfig patch clusterversion version -p '{"spec":{"clusterID":""}}' --type merge

# Get the IP of the VM
INTERNAL_IP=$(${DIG} +short api.${CRC_VM_NAME}.${BASE_DOMAIN})

# Disable kubelet service and pull dnsmasq image from quay.io/crcon/dnsmasq
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl disable kubelet
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo podman pull quay.io/crcont/dnsmasq:latest

# Stop the kubelet service so it will not reprovision the pods
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl stop kubelet

# Stop the network time sync
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo timedatectl set-ntp off

# Enable the io.podman.socket service
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl enable io.podman.socket

# Remove all the pods from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl stopp $(sudo crictl pods -q)'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'for i in {1..3}; do sudo crictl rmp $(sudo crictl pods -q) && break || sleep 2; done'

# Remove pull secret from the VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -f /var/lib/kubelet/config.json'

# Download the hyperV daemons and libvarlink-util dependency on host
mkdir $1/packages
sudo yum install -y --downloadonly --downloaddir $1/packages hyperv-daemons libvarlink-util

# SCP the downloaded rpms to VM
${SCP} -r $1/packages core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/

# Install the hyperV and libvarlink-util rpms to VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rpm-ostree install /home/core/packages/*.rpm'

# Remove the packages from VM
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- rm -fr /home/core/packages

# SCP the kubeconfig file to VM
${SCP} $1/auth/kubeconfig core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo mv /home/core/kubeconfig /opt/'

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
ostree_hash=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "cat /proc/cmdline | grep -oP \"(?<=${BASE_OS}-).*(?=/vmlinuz)\"")

# Get the rhcos kernel release
kernel_release=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'uname -r')

# Get the kernel command line arguments
kernel_cmd_line=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline')

# SCP the vmlinuz/initramfs from VM to Host in provided folder.
${SCP} core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/boot/ostree/${BASE_OS}-${ostree_hash}/* $1

# Add a dummy network interface with internalIP
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "sudo nmcli conn add type dummy ifname eth10 con-name internalEtcd ip4 ${INTERNAL_IP}/24  && sudo nmcli conn up internalEtcd"

# Add internalIP as node IP for kubelet systemd unit file
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "sudo sed -i.back '/kubelet /a\      --node-ip="${INTERNAL_IP}" \\\' /etc/systemd/system/kubelet.service"

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

tar cSf - $libvirtDestDir | xz --threads=0 >$libvirtDestDir.$crcBundleSuffix

# HyperKit image generation
# This must be done after the generation of libvirt image as it reuse some of
# the content of $libvirtDestDir
hyperkitDestDir="crc_hyperkit_${destDirSuffix}"
mkdir $hyperkitDestDir
generate_hyperkit_directory $libvirtDestDir $hyperkitDestDir $1

tar cSf - $hyperkitDestDir | xz --threads=0 >$hyperkitDestDir.$crcBundleSuffix

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
hypervDestDir="crc_hyperv_${destDirSuffix}"
mkdir $hypervDestDir
generate_hyperv_directory $libvirtDestDir $hypervDestDir

tar cSf - $hypervDestDir | xz --threads=0 >$hypervDestDir.$crcBundleSuffix

# Cleanup up packages and vmlinux/initramfs files
rm -fr $1/packages $1/vmlinuz* $1/initramfs*
