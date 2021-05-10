#!/bin/bash

set -exuo pipefail


function get_dest_dir {
    if [ "${OPENSHIFT_VERSION-}" != "" ]; then
        DEST_DIR=$OPENSHIFT_VERSION
    else
        DEST_DIR=${PULL_NUMBER}
        if [ -z ${DEST_DIR} ]; then
            DEST_DIR="$(date --iso-8601)"
        fi
    fi
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
    eval $(echo nokey | ${GUESTFISH}  --keys-from-stdin --listen )
    if [ $? -ne 0 ]; then
            echo "${GUESTFISH} failed to start, aborting"
            exit 1
    fi

    ${GUESTFISH} --remote <<EOF
add-drive $baseDir/$srcFile
run
EOF

    ${GUESTFISH} --remote mount $partition /

    ${GUESTFISH} --remote zero-free-space /boot/
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

    ocSize=$(du -b $destDir/oc | awk '{print $1}')
    ocSha256Sum=$(sha256sum $destDir/oc | awk '{print $1}')

    podmanSize=$(du -b $destDir/podman-remote | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman-remote | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_ecdsa_crc"' \
        | ${JQ} '.clusterInfo.kubeConfig = "kubeconfig"' \
        | ${JQ} '.nodes[0].kind[0] = "master"' \
        | ${JQ} '.nodes[0].kind[1] = "worker"' \
        | ${JQ} ".nodes[0].hostname = \"${VM_PREFIX}-master-0\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} ".nodes[0].internalIP = \"${INTERNAL_IP}\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} '.storage.diskImages[0].format = "qcow2"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} ".storage.fileList[0].name = \"oc\"" \
        | ${JQ} '.storage.fileList[0].type = "oc-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${ocSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${ocSha256Sum}\"" \
        | ${JQ} ".storage.fileList[1].name = \"podman-remote\"" \
        | ${JQ} '.storage.fileList[1].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[1].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[1].sha256sum = \"${podmanSha256Sum}\"" \
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

    # Copy the kubeconfig file
    cp $1/auth/kubeconfig $destDir/

    # Copy the master public key
    cp id_ecdsa_crc $destDir/
    chmod 400 $destDir/id_ecdsa_crc

    # Copy oc client
    cp openshift-clients/linux/oc $destDir/

    cp podman-remote/linux/podman-remote $destDir/

    update_json_description $srcDir $destDir

    eventually_add_pull_secret $destDir
}

function prepare_hyperV() {
    if [[ ${OKD_VERSION} != "none" ]]; then
        # Install the hyperV and libvarlink-util rpms to VM
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora.repo'
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora-updates.repo'
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rpm-ostree install --allow-inactive hyperv-daemons libvarlink-util'
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora.repo'
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora-updates.repo'
    else
        # Download the hyperV daemons and libvarlink-util dependency on host
        mkdir $1/packages
        sudo yum install -y --downloadonly --downloaddir $1/packages hyperv-daemons

        # SCP the downloaded rpms to VM
        ${SCP} -r $1/packages core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/home/core/

        # Install the hyperV and libvarlink-util rpms to VM
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rpm-ostree install /home/core/packages/*.rpm'

        # Remove the packages from VM
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- rm -fr /home/core/packages

        # Cleanup up packages
        rm -fr $1/packages
    fi

    # Adding Hyper-V vsock support
    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
            echo 'CONST{virt}=="microsoft", RUN{builtin}+="kmod load hv_sock"' > /etc/udev/rules.d/90-crc-vsock.rules
EOF
}

function generate_hyperkit_bundle {
    local srcDir=$1
    local destDir=$2
    local tmpDir=$3
    local kernel_release=$4
    local kernel_cmd_line=$5

    mkdir "$destDir"
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_ecdsa_crc $destDir/
    cp $srcDir/${CRC_VM_NAME}.qcow2 $destDir/
    cp $tmpDir/vmlinuz-${kernel_release} $destDir/
    cp $tmpDir/initramfs-${kernel_release}.img $destDir/

    # Copy oc client
    cp openshift-clients/mac/oc $destDir/

    cp podman-remote/mac/podman $destDir/

    ocSize=$(du -b $destDir/oc | awk '{print $1}')
    ocSha256Sum=$(sha256sum $destDir/oc | awk '{print $1}')

    podmanSize=$(du -b $destDir/podman | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman | awk '{print $1}')

    # Update the bundle metadata info
    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} ".nodes[0].kernel = \"vmlinuz-${kernel_release}\"" \
        | ${JQ} ".nodes[0].initramfs = \"initramfs-${kernel_release}.img\"" \
        | ${JQ} ".nodes[0].kernelCmdLine = \"${kernel_cmd_line}\"" \
        | ${JQ} ".storage.fileList[0].name = \"oc\"" \
        | ${JQ} '.storage.fileList[0].type = "oc-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${ocSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${ocSha256Sum}\"" \
        | ${JQ} ".storage.fileList[1].name = \"podman\"" \
        | ${JQ} '.storage.fileList[1].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[1].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[1].sha256sum = \"${podmanSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "hyperkit"' \
        >$destDir/crc-bundle-info.json

    create_tarball "$destDir"
}

function generate_hyperv_bundle {
    local srcDir=$1
    local destDir=$2

    mkdir "$destDir"

    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_ecdsa_crc $destDir/

    # Copy oc client
    cp openshift-clients/windows/oc.exe $destDir/

    cp podman-remote/windows/podman.exe $destDir/

    ${QEMU_IMG} convert -f qcow2 -O vhdx -o subformat=dynamic $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vhdx

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.vhdx | awk '{print $1}')

    ocSize=$(du -b $destDir/oc.exe | awk '{print $1}')
    ocSha256Sum=$(sha256sum $destDir/oc.exe | awk '{print $1}')

    podmanSize=$(du -b $destDir/podman.exe | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman.exe | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.vhdx\"" \
        | ${JQ} '.storage.diskImages[0].format = "vhdx"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} ".storage.fileList[0].name = \"oc.exe\"" \
        | ${JQ} '.storage.fileList[0].type = "oc-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${ocSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${ocSha256Sum}\"" \
        | ${JQ} ".storage.fileList[1].name = \"podman.exe\"" \
        | ${JQ} '.storage.fileList[1].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[1].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[1].sha256sum = \"${podmanSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "hyperv"' \
        >$destDir/crc-bundle-info.json

    create_tarball "$destDir"
}

function create_tarball {
    local dirName=$1

    tar cSf - --sort=name "$dirName" | ${ZSTD} --no-progress ${CRC_ZSTD_EXTRA_FLAGS} --threads=0 -o "$dirName".crcbundle
}

function download_podman() {
    local version=$1

    mkdir -p podman-remote/linux
    curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-static.tar.gz | tar -zx -C podman-remote/linux podman-remote-static
    mv podman-remote/linux/podman-remote-static podman-remote/linux/podman-remote

    if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
      mkdir -p podman-remote/mac
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-darwin.zip -o podman-remote/mac/podman.zip
      ${UNZIP} -o -d podman-remote/mac/ podman-remote/mac/podman.zip
    fi

    if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
      mkdir -p podman-remote/windows
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-windows.zip -o podman-remote/windows/podman.zip
      ${UNZIP} -o -d podman-remote/windows/ podman-remote/windows/podman.zip
    fi
}
