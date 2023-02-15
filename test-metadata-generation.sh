#!/bin/bash

set -exuo pipefail

source tools.sh
source createdisk-library.sh
source snc-library.sh

MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp}
OPENSHIFT_RELEASE_VERSION="${OPENSHIFT_VERSION-4.7.0}"

SNC_PRODUCT_NAME=${SNC_PRODUCT_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
VM_PREFIX=${SNC_PRODUCT_NAME}-abcde
VM_IP=192.168.126.11

CRC_ZSTD_EXTRA_FLAGS="--fast"

# Prepare fake directory structure matching create_disk expectations
baseDir="test-metadata-generation"
mkdir $baseDir
cd $baseDir
srcDir=src
destDir=dest

mkdir -p "$srcDir"
mkdir -p "$srcDir/auth"
touch "$srcDir"/auth/kubeconfig
touch id_ecdsa_crc
touch "$srcDir"/vmlinuz-0.0.0
touch "$srcDir"/initramfs-0.0.0.img

echo {} | ${JQ} '.version = "1.2"' \
    | ${JQ} '.type = "snc"' \
    | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
    | ${JQ} ".buildInfo.openshiftInstallerVersion = \"0.0.0\"" \
    | ${JQ} ".buildInfo.sncVersion = \"xxx\"" \
    | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION}\"" \
    | ${JQ} ".clusterInfo.clusterName = \"${SNC_PRODUCT_NAME}\"" \
    | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
    | ${JQ} ".clusterInfo.appsDomain = \"apps-${SNC_PRODUCT_NAME}.${BASE_DOMAIN}\"" >${srcDir}/crc-bundle-info.json

download_oc

mkdir -p "$destDir/linux"
${QEMU_IMG} create -f qcow2 "$destDir/linux/${SNC_PRODUCT_NAME}.qcow2" 64M
copy_additional_files "$srcDir" "$destDir/linux"
create_tarball "$destDir/linux"

generate_hyperv_bundle "$destDir/linux" "$destDir/windows"
generate_hyperkit_bundle "$destDir/linux" "$destDir/macos" "$srcDir" "0.0.0" "init=/init/sh"
