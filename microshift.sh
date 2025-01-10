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
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp-dev-preview}
MICROSHIFT_VERSION=${MICROSHIFT_VERSION:-4.18}
MIRROR_REPO=${MIRROR_REPO:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/microshift/ocp-dev-preview/latest-${MICROSHIFT_VERSION}/el9/os}

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

function create_iso {
  local buildDir=$1
  local extra_args=""
  if [ -n "${MICROSHIFT_PRERELEASE-}" ]; then
    extra_args="-use-unreleased-mirror-repo ${MIRROR_REPO}"
  fi
  BUILDDIR=${buildDir} image-mode/microshift/build.sh -pull_secret_file ${OPENSHIFT_PULL_SECRET_PATH} \
       -lvm_sysroot_size 15360 \
       -authorized_keys_file $(realpath id_ecdsa_crc.pub) \
       -microshift-version ${MICROSHIFT_VERSION} \
       -hostname api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} \
       -base-domain ${SNC_PRODUCT_NAME}.${BASE_DOMAIN} \
       ${extra_args}
}

microshift_pkg_dir=$(mktemp -p /tmp -d tmp-rpmXXX)

create_iso ${microshift_pkg_dir}
sudo cp -Z ${microshift_pkg_dir}/bootiso/install.iso /var/lib/libvirt/${SNC_PRODUCT_NAME}/microshift-installer.iso
OPENSHIFT_RELEASE_VERSION=$(sudo podman run --rm -it localhost/microshift:${MICROSHIFT_VERSION} /usr/bin/rpm -q --qf '%{VERSION}' microshift)
# Change 4.x.0~ec0 to 4.x.0-ec0
# https://docs.fedoraproject.org/en-US/packaging-guidelines/Versioning/#_complex_versioning
OPENSHIFT_RELEASE_VERSION=$(echo ${OPENSHIFT_RELEASE_VERSION} | tr '~' '-')
sudo rm -fr ${microshift_pkg_dir}

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
