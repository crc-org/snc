#!/bin/bash

JQ=${JQ:-jq}

QEMU_IMG=${QEMU_IMG:-qemu-img}
VIRT_FILESYSTEMS=${VIRT_FILESYSTEMS:-virt-filesystems}
GUESTFISH=${GUESTFISH:-guestfish}

XMLLINT=${XMLLINT:-xmllint}

UNZIP=${UNZIP:-unzip}
ZSTD=${ZSTD:-zstd}
CRC_ZSTD_EXTRA_FLAGS=${CRC_ZSTD_EXTRA_FLAGS:-"--ultra -22"}
PODMAN=${PODMAN:-podman}
VIRT_INSTALL=${VIRT_INSTALL:-virt-install}

ARCH=$(uname -m)

case "${ARCH}" in
    x86_64)
        yq_ARCH="amd64"
        SNC_GENERATE_MACOS_BUNDLE=1
        SNC_GENERATE_WINDOWS_BUNDLE=1
	;;
    aarch64)
        yq_ARCH="arm64"
        SNC_GENERATE_MACOS_BUNDLE=1
        SNC_GENERATE_WINDOWS_BUNDLE=
	;;
    *)
        yq_ARCH=${ARCH}
        SNC_GENERATE_MACOS_BUNDLE=
        SNC_GENERATE_WINDOWS_BUNDLE=
	;;
esac

# Download yq/jq for manipulating in place yaml configs
if test -z ${YQ-}; then
    echo "Downloading yq binary to manipulate yaml files"
    curl -L https://github.com/mikefarah/yq/releases/download/v4.5.1/yq_linux_${yq_ARCH} -o yq
    chmod +x yq
    YQ=./yq
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

# Add virt-filesystems/guestfish/qemu-img
if ! which ${VIRT_FILESYSTEMS}; then
    sudo yum -y install /usr/bin/virt-filesystems
fi

if ! which ${GUESTFISH}; then
    sudo yum -y install /usr/bin/guestfish
fi

if ! which ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi
# The CoreOS image uses an XFS filesystem
# Beware than if you are running on an el7 system, you won't be able
# to resize the crc VM XFS filesystem as it was created on el8
if ! rpm -q libguestfs-xfs; then
    sudo yum install libguestfs-xfs
fi

if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" -o -n "${SNC_GENERATE_MACOS_BUNDLE}" ];then
    if ! which ${UNZIP}; then
        sudo yum -y install /usr/bin/unzip
    fi
fi

if ! which ${XMLLINT}; then
    sudo yum -y install /usr/bin/xmllint
fi

if ! which ${ZSTD}; then
    sudo yum -y install /usr/bin/zstd
fi

if ! which ${PODMAN}; then
    sudo yum -y install /usr/bin/podman
fi

if ! which ${VIRT_INSTALL}; then
    sudo yum -y install /usr/bin/virt-install
fi

function retry {
    local retries=10
    local count=0
    until "$@"; do
        exit=$?
        wait=$((2 ** $count))
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..." 1>&2
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left." 1>&2
            return $exit
        fi
    done
    return 0
}

function shutdown_vm {
    local vm_name=$1
    retry sudo virsh shutdown ${vm_name}
    # Wait till instance started successfully
    until sudo virsh domstate ${vm_name} | grep shut; do
        echo " ${vm_name} still running"
        sleep 3
    done
}

function start_vm {
    local vm_name=$1
    local vm_ip=$2
    retry sudo virsh start ${vm_name}
    # Wait till ssh connection available
    until ${SSH} core@${vm_ip} -- "exit 0" >/dev/null 2>&1; do
        echo " ${vm_name} still booting"
        sleep 2
    done
}
