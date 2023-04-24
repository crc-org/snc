#!/bin/bash

set -exuo pipefail

function get_dest_dir_suffix {
    local version=$1
    DEST_DIR_SUFFIX="${version}_${yq_ARCH}"
    if [ -n "${PULL_NUMBER-}" ]; then
         DEST_DIR_SUFFIX="$DEST_DIR_SUFFIX.pr${PULL_NUMBER}"
    fi
}

# This removes extra os tree layers, log files, ... from the image
function cleanup_vm_image() {
    local vm_name=$1
    local vm_ip=$2

    # Shutdown and Start the VM to get the latest ostree layer. If packages
    # have been added/removed since last boot, the VM will reboot in a different ostree layer.
    shutdown_vm ${vm_name}
    start_vm ${vm_name} ${vm_ip}

    # Remove miscellaneous unneeded data from rpm-ostree
    ${SSH} core@${vm_ip} -- 'sudo rpm-ostree cleanup --rollback --base --repomd'

    # Remove logs.
    # Note: With `sudo journalctl --rotate --vacuum-time=1s`, it doesn't
    # remove all the journal logs so separate commands are used here.
    ${SSH} core@${VM_IP} -- 'sudo journalctl --rotate'
    ${SSH} core@${VM_IP} -- 'sudo journalctl --vacuum-time=1s'
    ${SSH} core@${vm_ip} -- 'sudo find /var/log/ -iname "*.log" -exec rm -f {} \;'

    # Shutdown and Start the VM after removing base deployment tree
    # This is required because kernel commandline changed, namely
    # ostree=/ostree/boot.1/fedora-coreos/$hash/0 which switches
    # between boot.0 and boot.1 when cleanup is run
    shutdown_vm ${vm_name}
    start_vm ${vm_name} ${vm_ip}
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

function downgrade_kernel() {
    # workaround https://github.com/crc-org/vfkit/issues/11 on macOS 11/12
    local vm_ip=$1
    local arch=$2
    local bodhi_url
    case $arch in
         amd64)
	    # kernel-5.19.16-301.fc37
            bodhi_url="https://bodhi.fedoraproject.org/updates/FEDORA-2022-1c6a1ca835"
	    ;;
         arm64)
	    # kernel-5.18.19-200.fc36
            bodhi_url="https://bodhi.fedoraproject.org/updates/FEDORA-2022-5674f93546"
	    ;;
    esac

    ${SSH} core@${vm_ip} "sudo rpm-ostree override -C replace ${bodhi_url}"
}

function prepare_cockpit() {
    local vm_ip=$1

    install_additional_packages ${vm_ip} cockpit-bridge cockpit-ws cockpit-podman
}

function prepare_hyperV() {
    local vm_ip=$1

    install_additional_packages ${vm_ip} hyperv-daemons

    # Adding Hyper-V vsock support
    ${SSH} core@${vm_ip} 'sudo bash -x -s' <<EOF
            echo 'CONST{virt}=="microsoft", RUN{builtin}+="kmod load hv_sock"' > /etc/udev/rules.d/90-crc-vsock.rules
EOF
}
function prepare_qemu_guest_agent() {
    local vm_ip=$1

    install_additional_packages ${vm_ip} qemu-guest-agent

    # f36 default selinux policy blocks usage of qemu-guest-agent over vsock
    # checkpolicy
    /usr/bin/checkmodule -M -m -o qemuga-vsock.mod qemuga-vsock.te
    # policycoreutils
    /usr/bin/semodule_package -o qemuga-vsock.pp -m qemuga-vsock.mod

    ${SCP} qemuga-vsock.pp core@${vm_ip}:
    ${SSH} core@${vm_ip} 'sudo semodule -i qemuga-vsock.pp && rm qemuga-vsock.pp'
    ${SCP} qemu-guest-agent.service core@${vm_ip}:
    ${SSH} core@${vm_ip} 'sudo mv -Z qemu-guest-agent.service /etc/systemd/system/'
    ${SSH} core@${vm_ip} 'sudo systemctl daemon-reload'
    ${SSH} core@${vm_ip} 'sudo systemctl enable qemu-guest-agent.service'
}

function generate_vfkit_bundle {
    local srcDir=$1
    local destDir=$2

    generate_macos_bundle "vfkit" "$@"

    create_qemu_image "$libvirtDestDir" "fedora-coreos-qemu.${ARCH}.qcow2" "${CRC_VM_NAME}.qcow2"
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
    curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-static-linux_${arch}.tar.gz | tar -zx -C podman-remote/linux podman-remote-static-linux_${arch}
    mv podman-remote/linux/podman-remote-static-linux_${arch} podman-remote/linux/podman-remote
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
