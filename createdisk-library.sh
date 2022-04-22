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
    DEST_DIR="${DEST_DIR}_${yq_ARCH}"
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
    local base=$2
    local overlay=$3

    if [ -f /var/lib/libvirt/images/${overlay} ]; then
      sudo cp /var/lib/libvirt/images/${overlay} ${destDir}
      sudo cp /var/lib/libvirt/images/${base} ${destDir}
    else
      sudo cp /var/lib/libvirt/openshift-images/${VM_PREFIX}/${overlay} ${destDir}
      sudo cp /var/lib/libvirt/openshift-images/${VM_PREFIX}/${base} ${destDir}
    fi

    sudo chown $USER:$USER -R ${destDir}
    ${QEMU_IMG} rebase -f qcow2 -F qcow2 -b ${base} ${destDir}/${overlay}
    ${QEMU_IMG} commit ${destDir}/${overlay}

    sparsify ${destDir} ${base} ${overlay}

    chmod 0644 ${destDir}/${overlay}

    rm -fr ${destDir}/${base}
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

function install_additional_packages() {
    local vm_ip=$1
    shift
    if [[ ${BASE_OS} = "fedora-coreos" ]]; then
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora.repo'
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora-updates.repo'
        ${SSH} core@${vm_ip} -- "sudo rpm-ostree install --allow-inactive $*"
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora.repo'
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora-updates.repo'
    else
        # Download the hyperV daemons dependency on host
        local pkgDir=$(mktemp -d tmp-rpmXXX)
        mkdir -p ${pkgDir}/packages
        sudo yum download --downloadonly --downloaddir ${pkgDir}/packages "$*" --resolve

        # SCP the downloaded rpms to VM
        ${SCP} -r ${pkgDir}/packages core@${vm_ip}:/home/core/

        # Install these rpms to VM
        ${SSH} core@${vm_ip} -- 'sudo rpm-ostree install /home/core/packages/*.rpm'

        # Remove the packages from VM
        ${SSH} core@${vm_ip} -- rm -fr /home/core/packages

        # Cleanup up packages
        rm -fr ${pkgDir}
    fi
}

function prepare_hyperV() {
    local vm_ip=$1

    install_additional_packages ${vm_ip} hyperv-daemons

    # Adding Hyper-V vsock support
    ${SSH} core@${vm_ip} 'sudo bash -x -s' <<EOF
            echo 'CONST{virt}=="microsoft", RUN{builtin}+="kmod load hv_sock"' > /etc/udev/rules.d/90-crc-vsock.rules
EOF
}

function generate_vfkit_bundle {
    local srcDir=$1
    local destDir=$2

    generate_macos_bundle "vfkit" "$@"

    ${QEMU_IMG} convert -f qcow2 -O raw $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.img
    add_disk_info_to_json_description "${destDir}" "${CRC_VM_NAME}.img" "raw"

    create_tarball "$destDir"
}

function generate_macos_bundle {
    local bundleType=$1
    local srcDir=$2
    local destDir=$3
    local tmpDir=$4
    local kernel_release=$5
    local kernel_cmd_line=$6

    mkdir "$destDir"
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_ecdsa_crc $destDir/
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
        | ${JQ} ".driverInfo.name = \"${bundleType}\"" \
        >$destDir/crc-bundle-info.json
}

function add_disk_info_to_json_description {
    local destDir=$1
    local imageFilename=$2
    local imageFormat=$3

    diskSize=$(du -b $destDir/$imageFilename | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/$imageFilename | awk '{print $1}')


    cat $destDir/crc-bundle-info.json \
        | ${JQ} ".nodes[0].diskImage = \"${imageFilename}\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${imageFilename}\"" \
        | ${JQ} ".storage.diskImages[0].format = \"${imageFormat}\"" \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" >$destDir/crc-bundle-info.json.tmp
    mv $destDir/crc-bundle-info.json.tmp $destDir/crc-bundle-info.json
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

    ocSize=$(du -b $destDir/oc.exe | awk '{print $1}')
    ocSha256Sum=$(sha256sum $destDir/oc.exe | awk '{print $1}')

    podmanSize=$(du -b $destDir/podman.exe | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman.exe | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
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

    ${QEMU_IMG} convert -f qcow2 -O vhdx -o subformat=dynamic $srcDir/${CRC_VM_NAME}.qcow2 $destDir/${CRC_VM_NAME}.vhdx
    add_disk_info_to_json_description "${destDir}" "${CRC_VM_NAME}.vhdx" vhdx

    create_tarball "$destDir"
}

function create_tarball {
    local dirName=$1

    tar cSf - --sort=name "$dirName" | ${ZSTD} --no-progress ${CRC_ZSTD_EXTRA_FLAGS} --threads=0 -o "${dirName}".crcbundle
}

function download_podman() {
    local version=$1

    mkdir -p podman-remote/linux
    curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-static.tar.gz | tar -zx -C podman-remote/linux podman-remote-static
    mv podman-remote/linux/podman-remote-static podman-remote/linux/podman-remote
    chmod +x podman-remote/linux/podman-remote

    if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
      mkdir -p podman-remote/mac
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-darwin.zip -o podman-remote/mac/podman.zip
      ${UNZIP} -o -d podman-remote/mac/ podman-remote/mac/podman.zip
      mv podman-remote/mac/podman-${version}/podman  podman-remote/mac
      chmod +x podman-remote/mac/podman
    fi

    if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
      mkdir -p podman-remote/windows
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-windows.zip -o podman-remote/windows/podman.zip
      ${UNZIP} -o -d podman-remote/windows/ podman-remote/windows/podman.zip
      mv podman-remote/windows/podman-${version}/podman.exe  podman-remote/windows
    fi
}
