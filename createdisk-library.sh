#!/bin/bash

set -exuo pipefail


function get_dest_dir {
    if [ "${OPENSHIFT_VERSION-}" != "" ]; then
        DEST_DIR=$OPENSHIFT_VERSION
    else
        set +e
        DEST_DIR=$(git describe --exact-match --tags HEAD)
        set -e
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

    ${QEMU_IMG} convert -f qcow2 -O qcow2 -o lazy_refcounts=on $baseDir/$srcFile $baseDir/$destFile
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
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_ecdsa_crc"' \
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

function eventually_add_pull_secret {
    local destDir=$1

    if [ "${BUNDLED_PULL_SECRET_PATH-}" != "" ]
    then
      cat "$BUNDLED_PULL_SECRET_PATH" > "$destDir/default-pull-secret"
      cat $destDir/crc-bundle-info.json \
          | ${JQ} '.clusterInfo.openshiftPullSecret = "default-pull-secret"' \
          >$destDir/crc-bundle-info.json.tmp
      mv $destDir/crc-bundle-info.json.tmp $destDir/crc-bundle-info.json
    fi
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
    cp id_ecdsa_crc $destDir/
    chmod 400 $destDir/id_ecdsa_crc

    # Copy oc client
    cp openshift-clients/linux/oc $destDir/

    update_json_description $srcDir $destDir

    eventually_add_pull_secret $destDir
}

function generate_hyperkit_directory {
    local srcDir=$1
    local destDir=$2
    local tmpDir=$3
    local kernel_release=$4
    local kernel_cmd_line=$5

    cp $srcDir/kubeadmin-password $destDir/
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_ecdsa_crc $destDir/
    cp $srcDir/${CRC_VM_NAME}.qcow2 $destDir/
    cp $tmpDir/vmlinuz-${kernel_release} $destDir/
    cp $tmpDir/initramfs-${kernel_release}.img $destDir/

    # Copy oc client
    cp openshift-clients/mac/oc $destDir/

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
    cp $srcDir/id_ecdsa_crc $destDir/

    # Copy oc client
    cp openshift-clients/windows/oc.exe $destDir/

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

function create_tarball {
    local dirName=$1

    tar cSf - --sort=name "$dirName" | xz --threads=0 >"$dirName".crcbundle"
}
