#!/bin/bash

JQ=${JQ:-jq}

QEMU_IMG=${QEMU_IMG:-qemu-img}
VIRT_FILESYSTEMS=${VIRT_FILESYSTEMS:-virt-filesystems}
GUESTFISH=${GUESTFISH:-guestfish}
VIRSH=${VIRSH:-virsh}
VIRT_INSTALL=${VIRT_INSTALL:-virt-install}

XMLLINT=${XMLLINT:-xmllint}

DIG=${DIG:-dig}
UNZIP=${UNZIP:-unzip}
ZSTD=${ZSTD:-zstd}
CRC_ZSTD_EXTRA_FLAGS=${CRC_ZSTD_EXTRA_FLAGS:-"--ultra -22"}

HTPASSWD=${HTPASSWD:-htpasswd}
PATCH=${PATCH:-patch}

ARCH=$(uname -m)

case "${ARCH}" in
    x86_64)
        yq_ARCH="amd64"
        SNC_GENERATE_MACOS_BUNDLE=${SNC_GENERATE_MACOS_BUNDLE:-1}
        SNC_GENERATE_WINDOWS_BUNDLE=${SNC_GENERATE_WINDOWS_BUNDLE:-1}
        SNC_GENERATE_LINUX_BUNDLE=${SNC_GENERATE_LINUX_BUNDLE:-1}
	;;
    aarch64)
        yq_ARCH="arm64"
        SNC_GENERATE_MACOS_BUNDLE=${SNC_GENERATE_MACOS_BUNDLE:-1}
        SNC_GENERATE_WINDOWS_BUNDLE=${SNC_GENERATE_WINDOWS_BUNDLE:-0}
        SNC_GENERATE_LINUX_BUNDLE=${SNC_GENERATE_LINUX_BUNDLE:-0}
	;;
    *)
        yq_ARCH=${ARCH}
        SNC_GENERATE_MACOS_BUNDLE=${SNC_GENERATE_MACOS_BUNDLE:-0}
        SNC_GENERATE_WINDOWS_BUNDLE=${SNC_GENERATE_WINDOWS_BUNDLE:-0}
        SNC_GENERATE_LINUX_BUNDLE=${SNC_GENERATE_LINUX_BUNDLE:-1}
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

if ! which ${VIRSH}; then
    sudo yum -y install /usr/bin/virsh
fi

if ! which ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi

if ! which ${VIRT_INSTALL}; then
    sudo yum -y install /usr/bin/virt-install
fi

# The CoreOS image uses an XFS filesystem
# Beware than if you are running on an el7 system, you won't be able
# to resize the crc VM XFS filesystem as it was created on el8
if ! rpm -q libguestfs-xfs; then
    sudo yum install libguestfs-xfs
fi

if [ "${SNC_GENERATE_WINDOWS_BUNDLE}" != "0" -o "${SNC_GENERATE_MACOS_BUNDLE}" != "0" ];then
    if ! which ${UNZIP}; then
        sudo yum -y install /usr/bin/unzip
    fi
fi

if ! which ${XMLLINT}; then
    sudo yum -y install /usr/bin/xmllint
fi

if ! which ${DIG}; then
    sudo yum -y install /usr/bin/dig
fi

if ! which ${ZSTD}; then
    sudo yum -y install /usr/bin/zstd
fi

if ! which ${HTPASSWD}; then
    sudo yum -y install /usr/bin/htpasswd
fi

if ! which ${PATCH}; then
    sudo yum -y install /usr/bin/patch
fi

function retry {
    # total wait time = 2 ^ (retries - 1) - 1 seconds
    local retries=14

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

function get_vm_prefix {
    local crc_vm_name=$1
    # This random_string is created by installer and added to each resource type,
    # in installer side also variable name is kept as `random_string`
    # so to maintain consistancy, we are also using random_string here.
    random_string=$(sudo virsh list --all | grep -m1 -oP "(?<=${crc_vm_name}-).*(?=-master-0)")
    if [ -z $random_string ]; then
        echo "Could not find virtual machine created by snc.sh"
        exit 1;
    fi
    echo ${crc_vm_name}-${random_string}
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

function wait_for_ssh {
    local vm_name=$1
    local vm_ip=$2
    until ${SSH} core@${vm_ip} -- "exit 0" >/dev/null 2>&1; do
        echo " ${vm_name} still booting"
        sleep 2
    done
}

function start_vm {
    local vm_name=$1
    local vm_ip=$2
    retry sudo virsh start ${vm_name}
    # Wait till ssh connection available
    wait_for_ssh ${vm_name} ${vm_ip}
}

function destroy_libvirt_resources {
    local iso=$1

    sudo virsh destroy ${SNC_PRODUCT_NAME} || true
    sudo virsh undefine ${SNC_PRODUCT_NAME} --nvram || true
    sudo virsh vol-delete --pool ${SNC_PRODUCT_NAME} ${SNC_PRODUCT_NAME}.qcow2 || true
    sudo virsh vol-delete --pool ${SNC_PRODUCT_NAME} ${iso} || true
    sudo virsh pool-destroy ${SNC_PRODUCT_NAME} || true
    sudo virsh pool-undefine ${SNC_PRODUCT_NAME} || true
    sudo virsh net-destroy ${SNC_PRODUCT_NAME} || true
    sudo virsh net-undefine ${SNC_PRODUCT_NAME} || true
}

function create_libvirt_resources {
   sudo virsh pool-define-as ${SNC_PRODUCT_NAME} --type dir --target /var/lib/libvirt/${SNC_PRODUCT_NAME}
   sudo virsh pool-start --build ${SNC_PRODUCT_NAME}
   sudo virsh pool-autostart ${SNC_PRODUCT_NAME}
   sed -e "s|NETWORK_NAME|${SNC_PRODUCT_NAME}|" \
       -e "s|CLUSTER_NAME|${SNC_PRODUCT_NAME}|" \
       -e "s|BASE_DOMAIN|${BASE_DOMAIN}|" \
       host-libvirt-net.xml.template > host-libvirt-net.xml
   sudo virsh net-create host-libvirt-net.xml
   rm -fr host-libvirt-net.xml
}

function create_vm {
    local iso=$1

    sudo ${VIRT_INSTALL} \
        --name ${SNC_PRODUCT_NAME} \
        --vcpus ${SNC_CLUSTER_CPUS} \
        --memory ${SNC_CLUSTER_MEMORY} \
        --arch=${ARCH} \
        --disk path=/var/lib/libvirt/${SNC_PRODUCT_NAME}/${SNC_PRODUCT_NAME}.qcow2,size=${CRC_VM_DISK_SIZE} \
        --network network="${SNC_PRODUCT_NAME}",mac=52:54:00:ee:42:e1 \
        --os-variant rhel9-unknown \
        --nographics \
        --cdrom /var/lib/libvirt/${SNC_PRODUCT_NAME}/${iso} \
        --events on_reboot=restart \
        --autoconsole none \
        --boot uefi \
        --wait
}

function generate_htpasswd_file {
   local auth_file_dir=$1
   local pass_file=$2
   random_password=$(cat $1/auth/kubeadmin-password)
   ${HTPASSWD} -c -B -b ${pass_file} developer developer
   ${HTPASSWD} -B -b ${pass_file} kubeadmin ${random_password}
}
