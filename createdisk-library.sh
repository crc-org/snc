#!/bin/bash

set -exuo pipefail

function get_dest_dir_suffix {
    local version=$1
    DEST_DIR_SUFFIX="${version}_${yq_ARCH}"
    if [ -n "${PULL_NUMBER-}" ]; then
         DEST_DIR_SUFFIX="${DEST_DIR_SUFFIX}_${PULL_NUMBER}"
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
    ${SSH} core@${vm_ip} -- 'sudo journalctl --rotate'
    ${SSH} core@${vm_ip} -- 'sudo journalctl --vacuum-time=1s'
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

    export LIBGUESTFS_BACKEND=direct
    # Check which partition is labeled as `root`
    partition=$(${VIRT_FILESYSTEMS} -a $baseDir/$srcFile -l --partitions | sort -rk4 -n | sed -n 1p | cut -f1 -d' ')
    # check if the base image has the lvm named as `rhel/root`
    if ${VIRT_FILESYSTEMS} --lvs -a ${baseDir}/${srcFile}  | grep -q "rhel/root"; then
      partition="/dev/rhel/root"
    fi

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
    local tempFile="temp_${SNC_PRODUCT_NAME}"

    sudo cp /var/lib/libvirt/${SNC_PRODUCT_NAME}/${SNC_PRODUCT_NAME}.qcow2 ${destDir}/${tempFile}

    sudo chown $USER:$USER -R ${destDir}

    sparsify ${destDir} ${tempFile} ${SNC_PRODUCT_NAME}.qcow2

    chmod 0644 ${destDir}/${tempFile}

    rm -fr ${destDir}/${tempFile}
}

function update_json_description {
    local srcDir=$1
    local destDir=$2
    local vm_name=$3

    diskSize=$(du -b $destDir/${SNC_PRODUCT_NAME}.qcow2 | awk '{print $1}')
    diskSha256Sum=$(sha256sum $destDir/${SNC_PRODUCT_NAME}.qcow2 | awk '{print $1}')

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
        | ${JQ} ".nodes[0].hostname = \"${vm_name}\"" \
        | ${JQ} ".nodes[0].diskImage = \"${SNC_PRODUCT_NAME}.qcow2\"" \
        | ${JQ} ".nodes[0].internalIP = \"${VM_IP}\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${SNC_PRODUCT_NAME}.qcow2\"" \
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
    local vm_name=$3

    # Copy the kubeconfig file
    cp $1/auth/kubeconfig $destDir/

    # Copy the master public key
    cp id_ecdsa_crc $destDir/
    chmod 400 $destDir/id_ecdsa_crc

    # Copy oc client
    cp openshift-clients/linux/oc $destDir/

    cp podman-remote/linux/podman-remote $destDir/

    update_json_description $srcDir $destDir $vm_name

    eventually_add_pull_secret $destDir
}

function install_additional_packages() {
    local vm_ip=$1
    shift
    if [[ ${BASE_OS} = "fedora-coreos" ]]; then
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=0/enabled=1/g /etc/yum.repos.d/centos.repo'
        ${SSH} core@${vm_ip} -- "sudo rpm-ostree install --allow-inactive $ADDITIONAL_PACKAGES"
        ${SSH} core@${vm_ip} -- 'sudo sed -i -z s/enabled=1/enabled=0/g /etc/yum.repos.d/centos.repo'
    else
        # Download the hyperV daemons dependency on host
        local pkgDir=$(mktemp -d tmp-rpmXXX)
        mkdir -p ${pkgDir}/packages
        sudo yum download --downloadonly --downloaddir ${pkgDir}/packages ${ADDITIONAL_PACKAGES} --resolve --alldeps

        # SCP the downloaded rpms to VM
        ${SCP} -r ${pkgDir}/packages core@${vm_ip}:/home/core/

        # Create local repo of downloaded RPMs in the VM
        ${SSH} core@${vm_ip} 'sudo bash -x -s' <<EOF
            podman run --rm -v /home/core/packages:/packages:Z quay.io/centos/centos:stream9 sh -c "dnf install -y createrepo && createrepo /packages"
            podman rmi quay.io/centos/centos:stream9
EOF
        ${SSH} core@${vm_ip} "sudo bash -c 'cat > /etc/yum.repos.d/local.repo << EOF
[local]
name=Local repo
baseurl=file:///home/core/packages/
enabled=1
gpgcheck=0
EOF'"
        # Install these rpms to VM
        ${SSH} core@${vm_ip} -- "sudo rpm-ostree install $ADDITIONAL_PACKAGES $PRE_DOWNLOADED_ADDITIONAL_PACKAGES"

        # Remove the packages and repo from VM
        ${SSH} core@${vm_ip} -- sudo rm -fr /home/core/packages
        ${SSH} core@${vm_ip} -- sudo rm -fr /etc/yum.repos.d/local.repo

        # Cleanup up packages
        rm -fr ${pkgDir}
    fi
}

function prepare_hyperV() {
    local vm_ip=$1

    ADDITIONAL_PACKAGES+=" hyperv-daemons"

    # Adding Hyper-V vsock support
    ${SSH} core@${vm_ip} 'sudo bash -x -s' <<EOF
            echo 'CONST{virt}=="microsoft", RUN{builtin}+="kmod load hv_sock"' > /etc/udev/rules.d/90-crc-vsock.rules
EOF
}

function prepare_qemu_guest_agent() {
    local vm_ip=$1

    # f36+ default selinux policy blocks usage of qemu-guest-agent over vsock, we have to install
    # our own selinux rules to allow this.
    #
    # we need to disable pipefail for the `checkmodule | grep check` as we expect `checkmodule`
    # to fail on rhel8.
    set +o pipefail
    if ! checkmodule -c 19 2>&1 |grep 'invalid option' >/dev/null; then
	    # RHEL8 checkmodule does not have this arg
	    MOD_VERSION_ARG="-c 19"
    fi
    set -o pipefail
    /usr/bin/checkmodule ${MOD_VERSION_ARG-} -M -m -o qemuga-vsock.mod qemuga-vsock.te
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

    ${QEMU_IMG} convert -f qcow2 -O raw $srcDir/${SNC_PRODUCT_NAME}.qcow2 $destDir/${SNC_PRODUCT_NAME}.img
    add_disk_info_to_json_description "${destDir}" "${SNC_PRODUCT_NAME}.img" "raw"

    create_tarball "$destDir"
}

function generate_macos_bundle {
    local bundleType=$1
    local srcDir=$2
    local destDir=$3


    mkdir -p "$destDir"
    cp $srcDir/kubeconfig $destDir/
    cp $srcDir/id_ecdsa_crc $destDir/

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

    ${QEMU_IMG} convert -f qcow2 -O vhdx -o subformat=dynamic $srcDir/${SNC_PRODUCT_NAME}.qcow2 $destDir/${SNC_PRODUCT_NAME}.vhdx
    add_disk_info_to_json_description "${destDir}" "${SNC_PRODUCT_NAME}.vhdx" vhdx

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
    curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-static-linux_${arch}.tar.gz | tar -zx -C podman-remote/linux
    mv podman-remote/linux/bin/podman-remote-static-linux_${arch} podman-remote/linux/podman-remote
    chmod +x podman-remote/linux/podman-remote

    if [ "${SNC_GENERATE_MACOS_BUNDLE}" != "0" ]; then
      mkdir -p podman-remote/mac
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-darwin_${arch}.zip -o podman-remote/mac/podman.zip
      ${UNZIP} -o -d podman-remote/mac/ podman-remote/mac/podman.zip
      mv podman-remote/mac/podman-${version}/usr/bin/podman  podman-remote/mac
      chmod +x podman-remote/mac/podman
    fi

    if [ "${SNC_GENERATE_WINDOWS_BUNDLE}" != "0" ]; then
      mkdir -p podman-remote/windows
      curl -L https://github.com/containers/podman/releases/download/v${version}/podman-remote-release-windows_${arch}.zip -o podman-remote/windows/podman.zip
      ${UNZIP} -o -d podman-remote/windows/ podman-remote/windows/podman.zip
      mv podman-remote/windows/podman-${version}/usr/bin/podman.exe  podman-remote/windows
    fi
}

function remove_pull_secret_from_disk() {
    case "${BUNDLE_TYPE}" in
      "microshift")
        ${SSH} core@${VM_IP} -- sudo rm -f /etc/crio/openshift-pull-secret
	;;
    esac
}

function copy_systemd_units() {
    case "${BUNDLE_TYPE}" in
        "snc"|"okd")
            export APPS_DOMAIN="apps-crc.testing"
            envsubst '${APPS_DOMAIN}' < systemd/dnsmasq.sh.template > systemd/crc-dnsmasq.sh
            unset APPS_DOMAIN
            ;;
        "microshift")
            export APPS_DOMAIN="apps.crc.testing"
            envsubst '${APPS_DOMAIN}' < systemd/dnsmasq.sh.template > systemd/crc-dnsmasq.sh
            unset APPS_DOMAIN
            ;;
    esac

    ${SSH} core@${VM_IP} -- 'mkdir -p /home/core/systemd-units && mkdir -p /home/core/systemd-scripts'
    ${SCP} systemd/crc-*.service core@${VM_IP}:/home/core/systemd-units/
    ${SCP} systemd/crc-*.sh core@${VM_IP}:/home/core/systemd-scripts/

    case "${BUNDLE_TYPE}" in
        "snc"|"okd")
            ${SCP} systemd/ocp-*.service core@${VM_IP}:/home/core/systemd-units/
            ${SCP} systemd/ocp-*.sh core@${VM_IP}:/home/core/systemd-scripts/
            ;;
    esac

    ${SSH} core@${VM_IP} -- 'sudo cp /home/core/systemd-units/* /etc/systemd/system/ && sudo cp /home/core/systemd-scripts/* /usr/local/bin/'
    ${SSH} core@${VM_IP} -- 'ls /home/core/systemd-scripts/ | xargs -t -I % sudo chmod +x /usr/local/bin/%'
    ${SSH} core@${VM_IP} -- 'sudo restorecon -rv /usr/local/bin'

    ${SSH} core@${VM_IP} -- 'ls /home/core/systemd-units/*.service | xargs basename -a | xargs sudo systemctl enable'

    ${SSH} core@${VM_IP} -- 'rm -rf /home/core/systemd-units /home/core/systemd-scripts'
}
