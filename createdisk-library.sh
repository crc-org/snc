#!/bin/bash

set -exuo pipefail

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
    local sourceDir=$1
    local destDir=$2

    sudo cp /var/lib/libvirt/images/${CRC_VM_NAME}.qcow2 $destDir
    sudo cp ${sourceDir}/fedora-coreos-qemu.${ARCH}.qcow2 $destDir

    sudo chown $USER:$USER -R $destDir
    ${QEMU_IMG} rebase -F qcow2 -b fedora-coreos-qemu.${ARCH}.qcow2 $destDir/${CRC_VM_NAME}.qcow2
    ${QEMU_IMG} commit $destDir/${CRC_VM_NAME}.qcow2

    sparsify $destDir fedora-coreos-qemu.${ARCH}.qcow2 ${CRC_VM_NAME}.qcow2

    # Before using the created qcow2, check if it has lazy_refcounts set to true.
    ${QEMU_IMG} info ${destDir}/${CRC_VM_NAME}.qcow2 | grep "lazy refcounts: true" 2>&1 >/dev/null
    if [ $? -ne 0 ]; then
        echo "${CRC_VM_NAME}.qcow2 doesn't have lazy_refcounts enabled. This is going to cause disk image corruption when using with hyperkit"
        exit 1;
    fi

    # Update the qcow2 image permission from 0600 to 0644
    chmod 0644 ${destDir}/${CRC_VM_NAME}.qcow2

    rm -fr $destDir/fedora-coreos-qemu.${ARCH}.qcow2
}

function update_json_description {
    local srcDir=$1
    local destDir=$2
    local podmanVersion=$3

    diskSize=$(du -b $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${CRC_VM_NAME}.qcow2 | awk '{print $1}')

    podmanSize=$(du -b $destDir/podman-remote | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman-remote | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_ecdsa_crc"' \
        | ${JQ} '.nodes[0].kind[0] = "master"' \
        | ${JQ} '.nodes[0].kind[1] = "worker"' \
        | ${JQ} ".nodes[0].hostname = \"${CRC_VM_NAME}\"" \
        | ${JQ} ".nodes[0].podmanVersion = \"${podmanVersion}\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} '.storage.diskImages[0].format = "qcow2"' \
        | ${JQ} ".storage.diskImages[0].size = \"${diskSize}\"" \
        | ${JQ} ".storage.diskImages[0].sha256sum = \"${diskSha256Sum}\"" \
        | ${JQ} ".storage.fileList[0].name = \"podman-remote\"" \
        | ${JQ} '.storage.fileList[0].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${podmanSha256Sum}\"" \
        | ${JQ} '.driverInfo.name = "libvirt"' \
        >$destDir/crc-bundle-info.json
}

function copy_additional_files {
    local srcDir=$1
    local destDir=$2
    local podmanVersion=$3

    # Copy the master public key
    cp id_ecdsa_crc $destDir/
    chmod 400 $destDir/id_ecdsa_crc

    cp podman-remote/linux/podman-remote $destDir/

    update_json_description $srcDir $destDir $podmanVersion
}

function install_additional_packages() {
    local vm_ip=$1
    ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora.repo'
    ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=0/enabled=1/ /etc/yum.repos.d/fedora-updates.repo'
    ${SSH} core@${vm_ip} -- 'sudo rpm-ostree install --allow-inactive cockpit-bridge cockpit-ws cockpit-podman'
    if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
        prepare_hyperV ${vm_ip}
    fi
    ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora.repo'
    ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=1/enabled=0/ /etc/yum.repos.d/fedora-updates.repo'
    ${SSH} core@${vm_ip} -- 'sudo rpm-ostree cleanup --base'
    ${SSH} core@${vm_ip} -- 'sudo rpm-ostree cleanup --repomd'
}

function prepare_hyperV() {
    local vm_ip=$1
    ${SSH} core@${vm_ip} -- 'sudo rpm-ostree install --allow-inactive hyperv-daemons'

    # Adding Hyper-V vsock support
    ${SSH} core@${vm_ip} 'sudo bash -x -s' <<EOF
            echo 'CONST{virt}=="microsoft", RUN{builtin}+="kmod load hv_sock"' > /etc/udev/rules.d/90-crc-vsock.rules
EOF
}

function generate_hyperkit_bundle {
    local srcDir=$1
    local destDir=$2

    mkdir "$destDir"
    generate_macos_bundle "hyperkit" "$@"

    cp $srcDir/${CRC_VM_NAME}.qcow2 $destDir/
    # not needed, we'll reuse the data added when generating the libvirt bundle
    #add_disk_info_to_json_description "${destDir}" "${CRC_VM_NAME}.qcow2" "qcow2"

    create_tarball "$destDir"
}

function generate_vfkit_bundle {
    local srcDir=$1
    local destDir=$2

    mkdir "$destDir"
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

    mkdir -p "$destDir"
    cp $srcDir/id_ecdsa_crc $destDir/
    cp $tmpDir/vmlinuz-${kernel_release} $destDir/
    cp $tmpDir/initramfs-${kernel_release}.img $destDir/

    # aarch64 only supports uncompressed kernels, see
    # https://github.com/code-ready/vfkit/commit/4aaa4fbdc76f9fc0ccec2b9fda25c5235664e7d6
    # for more details
    if [ "${ARCH}" == "aarch64" ]; then
      mv $destDir/vmlinuz-${kernel_release} $destDir/vmlinuz-${kernel_release}.gz
      gunzip $destDir/vmlinuz-${kernel_release}.gz
    fi

    cp podman-remote/mac/podman $destDir/

    podmanSize=$(du -b $destDir/podman | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman | awk '{print $1}')

    # Update the bundle metadata info
    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} ".nodes[0].kernel = \"vmlinuz-${kernel_release}\"" \
        | ${JQ} ".nodes[0].initramfs = \"initramfs-${kernel_release}.img\"" \
        | ${JQ} ".nodes[0].kernelCmdLine = \"${kernel_cmd_line}\"" \
        | ${JQ} ".storage.fileList[0].name = \"podman\"" \
        | ${JQ} '.storage.fileList[0].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${podmanSha256Sum}\"" \
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

    cp $srcDir/id_ecdsa_crc $destDir/

    # Copy podman client
    cp podman-remote/windows/podman.exe $destDir/

    podmanSize=$(du -b $destDir/podman.exe | awk '{print $1}')
    podmanSha256Sum=$(sha256sum $destDir/podman.exe | awk '{print $1}')

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} ".name = \"${destDir}\"" \
        | ${JQ} ".storage.fileList[0].name = \"podman.exe\"" \
        | ${JQ} '.storage.fileList[0].type = "podman-executable"' \
        | ${JQ} ".storage.fileList[0].size = \"${podmanSize}\"" \
        | ${JQ} ".storage.fileList[0].sha256sum = \"${podmanSha256Sum}\"" \
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
    local arch=$2

    mkdir -p podman-remote/linux
    curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-static.tar.gz | tar -zx -C podman-remote/linux podman-remote-static
    mv podman-remote/linux/podman-remote-static podman-remote/linux/podman-remote
    chmod +x podman-remote/linux/podman-remote

    if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
      mkdir -p podman-remote/mac
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-darwin_${arch}.zip -o podman-remote/mac/podman.zip
      ${UNZIP} -o -d podman-remote/mac/ podman-remote/mac/podman.zip
      mv podman-remote/mac/podman-${version}/usr/bin/podman  podman-remote/mac
      chmod +x podman-remote/mac/podman
    fi

    if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
      mkdir -p podman-remote/windows
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-windows_${arch}.zip -o podman-remote/windows/podman.zip
      ${UNZIP} -o -d podman-remote/windows/ podman-remote/windows/podman.zip
      mv podman-remote/windows/podman-${version}/usr/bin/podman.exe  podman-remote/windows
    fi
}
