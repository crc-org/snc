#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

BUNDLE_TYPE="microshift"
INSTALL_DIR=crc-tmp-install-data
SNC_PRODUCT_NAME=${SNC_PRODUCT_NAME:-crc}
SNC_CLUSTER_MEMORY=${SNC_CLUSTER_MEMORY:-2048}
SNC_CLUSTER_CPUS=${SNC_CLUSTER_CPUS:-2}
CRC_VM_DISK_SIZE=${CRC_VM_DISK_SIZE:-31}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp}
OPENSHIFT_MINOR_VERSION=${OPENSHIFT_MINOR_VERSION:-4.14}

if ! grep -q -i "release 9" /etc/redhat-release
then
  echo "This script only works for RHEL-9"
  exit 1
fi

echo "Check if system is registered"
# Check the subscription status and register if necessary
if ! sudo subscription-manager status >& /dev/null ; then
   echo "machine must be registered using subscription-manager"
   exit 1
fi

run_preflight_checks ${BUNDLE_TYPE}
rm -fr ${INSTALL_DIR} && mkdir ${INSTALL_DIR}

destroy_libvirt_resources microshift-installer.iso
create_libvirt_resources

# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

# This requirement is taken from https://github.com/openshift/microshift/blob/main/scripts/image-builder/configure.sh
# Also https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/composing_a_customized_rhel_system_image/installing-composer_composing-a-customized-rhel-system-image
# list out the dependencies and usecase.
# lorax packages which install mkksiso is required for embedding kickstart file to iso file
# podman package is required to run the ostree-container to serve the rpm-ostree content
# createrepo package is required to create localrepo for microshift and it's dependenices
# yum-utils package is required for reposync utility to synchronize packages of a remote DNF repository to a local directory
function configure_host {
    sudo dnf install -y git osbuild-composer composer-cli ostree rpm-ostree \
      cockpit-composer cockpit-machines bash-completion lorax \
      yum-utils createrepo
    sudo dnf install -y podman --setopt=install_weak_deps=True
    sudo systemctl start osbuild-composer.socket
    sudo systemctl start cockpit.socket
    sudo firewall-cmd --add-service=cockpit
}

function enable_repos {
    sudo subscription-manager repos \
       --enable rhocp-${OPENSHIFT_MINOR_VERSION}-for-rhel-9-$(uname -i)-rpms \
       --enable fast-datapath-for-rhel-9-$(uname -i)-rpms
}

function download_microshift_rpm {
    local pkgDir=$1
    local extra_opts=""
    local nvr_suffix=""
    if [ -n "${MICROSHIFT_PRERELEASE-}" ]; then
        extra_opts="--setopt=reposdir=./repos"
    elif [ -n "${MICROSHIFT_NVR-}" ]; then
        nvr_suffix="-${MICROSHIFT_NVR-}"
    fi
    sudo yum download ${extra_opts} --downloaddir ${pkgDir} --downloadonly microshift${nvr_suffix} microshift-networking${nvr_suffix} microshift-release-info${nvr_suffix} microshift-selinux${nvr_suffix} microshift-greenboot${nvr_suffix} microshift-olm${nvr_suffix}
}

function create_iso {
    local pkgDir=$1
    rm -fr microshift
    git clone -b release-${OPENSHIFT_MINOR_VERSION} https://github.com/openshift/microshift.git
    cp podman_changes.ks microshift/
    pushd microshift
    sed -i '/# customizations/,$d' scripts/image-builder/config/blueprint_v0.0.1.toml
    cat << EOF >> scripts/image-builder/config/blueprint_v0.0.1.toml
[[packages]]
name = "microshift-release-info"
version = "*"
[[packages]]
name = "cloud-utils-growpart"
version = "*"
[[packages]]
name = "qemu-guest-agent"
version = "*"
EOF
    sed -i 's/redhat/core/g' scripts/image-builder/config/kickstart.ks.template
    sed -i "/--bootproto=dhcp/a\network --hostname=api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN}" scripts/image-builder/config/kickstart.ks.template
    sed -i 's/clearpart --all --initlabel/clearpart --all --disklabel gpt/g' scripts/image-builder/config/kickstart.ks.template
    sed -i "/clearpart --all/a\part biosboot --fstype=biosboot --size=1" scripts/image-builder/config/kickstart.ks.template
    sed -i '$i\grub2-install --target=i386-pc /dev/vda' scripts/image-builder/config/kickstart.ks.template
    sed -i '$e cat podman_changes.ks' scripts/image-builder/config/kickstart.ks.template
    scripts/image-builder/cleanup.sh -full
    # The home dir and files must have read permissions to group
    # and others because osbuilder is running from another non-priviledged user account
    # and allow it to read the files on current user home (like reading yum repo which is created as part of build script), it is required.
    # https://github.com/openshift/microshift/blob/main/scripts/image-builder/configure.sh#L29-L32
    chmod 0755 $HOME

    scripts/image-builder/build.sh -microshift_rpms ${pkgDir} -pull_secret_file ${OPENSHIFT_PULL_SECRET_PATH} -lvm_sysroot_size 15360 -authorized_keys_file $(realpath ../id_ecdsa_crc.pub)
    popd
}

configure_host

enable_repos
microshift_pkg_dir=$(mktemp -p /tmp -d tmp-rpmXXX)
# This directory contains the microshift rpm  passed to osbuilder, worker for osbuilder
# running as non-priviledged user and this tmp directory have 0700 permission. To allow
# worker to read/execute this file we need to change the permission to 0755
chmod 0755 ${microshift_pkg_dir}
download_microshift_rpm ${microshift_pkg_dir}
create_iso ${microshift_pkg_dir}
sudo cp -Z microshift/_output/image-builder/microshift-installer-*.iso /var/lib/libvirt/${SNC_PRODUCT_NAME}/microshift-installer.iso
OPENSHIFT_RELEASE_VERSION=$(rpm -qp  --qf '%{VERSION}' ${microshift_pkg_dir}/microshift-4.*.rpm)
# Change 4.x.0~ec0 to 4.x.0-ec0
# https://docs.fedoraproject.org/en-US/packaging-guidelines/Versioning/#_complex_versioning
OPENSHIFT_RELEASE_VERSION=$(echo ${OPENSHIFT_RELEASE_VERSION} | tr '~' '-')
rm -fr ${microshift_pkg_dir}

# Download the oc binary for specific OS environment
OC=./openshift-clients/linux/oc
download_oc

create_json_description ${BUNDLE_TYPE}

# For microshift we create an empty kubeconfig file
# to have it as part of bundle because we don't run microshift
# service as part of bundle creation which creates the kubeconfig
# file.
mkdir -p ${INSTALL_DIR}/auth
touch ${INSTALL_DIR}/auth/kubeconfig

# Start the VM with generated ISO
create_vm microshift-installer.iso
