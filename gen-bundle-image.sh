#!/bin/bash

set -exuo pipefail

GPG_SECRET_KEY_PASSPHRASE_PATH=${GPG_SECRET_KEY_PASSPHRASE:-gpg_key_pass}

function set_bundle_variables {
   local version=$1
   local preset=$2
   vfkit_bundle=crc_vfkit_${version}_amd64.crcbundle
   libvirt_bundle=crc_libvirt_${version}_amd64.crcbundle
   hyperv_bundle=crc_hyperv_${version}_amd64.crcbundle

   if [[ ${preset} = "podman" ]]; then
       vfkit_bundle_arm64=crc_podman_vfkit_${version}_arm64.crcbundle
       vfkit_bundle=crc_podman_vfkit_${version}_amd64.crcbundle
       libvirt_bundle=crc_podman_libvirt_${version}_amd64.crcbundle
       hyperv_bundle=crc_podman_hyperv_${version}_amd64.crcbundle
   fi
}

function generate_image {
   local preset=$1

   if [[ ${preset} = "podman" ]]; then
       cat <<EOF | podman build --os darwin --arch arm64 --tag podman-bundle:darwin-arm64 -f - .
FROM scratch
COPY ${vfkit_bundle_arm64} ${vfkit_bundle_arm64}.sig /
EOF
   fi

   cat <<EOF | podman build --os darwin --arch amd64 --tag ${preset}-bundle:darwin-amd64 -f - .
FROM scratch
COPY ${vfkit_bundle} ${vfkit_bundle}.sig /
EOF

   cat <<EOF | podman build --os windows --arch amd64 --tag ${preset}-bundle:windows-amd64 -f - .
FROM scratch
COPY ${hyperv_bundle} ${hyperv_bundle}.sig /
EOF

   cat <<EOF | podman build --os linux --arch amd64 --tag ${preset}-bundle:linux-amd64 -f - .
FROM scratch
COPY ${libvirt_bundle} ${libvirt_bundle}.sig /
EOF
}

function generate_manifest {
   local version=$1
   local preset=$2
   podman manifest rm ${preset}-bundle:${version} || true
   podman manifest create ${preset}-bundle:${version}
   if [[ ${preset} = "podman" ]]; then
      podman manifest add ${preset}-bundle:${version} containers-storage:localhost/${preset}-bundle:darwin-arm64
   fi
   podman manifest add ${preset}-bundle:${version} containers-storage:localhost/${preset}-bundle:darwin-amd64
   podman manifest add ${preset}-bundle:${version} containers-storage:localhost/${preset}-bundle:windows-amd64
   podman manifest add ${preset}-bundle:${version} containers-storage:localhost/${preset}-bundle:linux-amd64
   podman manifest inspect ${preset}-bundle:${version}
}

function sign_bundle_files {
  local preset=$1
  rm -fr *.sig
  if [[ ${preset} = "podman" ]]; then
     gpg --batch --default-key crc@crc.dev --pinentry-mode=loopback --passphrase-file ${GPG_SECRET_KEY_PASSPHRASE_PATH} --armor --output ${vfkit_bundle_arm64}.sig --detach-sig ${vfkit_bundle_arm64}
  fi
  gpg --batch --default-key crc@crc.dev --pinentry-mode=loopback --passphrase-file ${GPG_SECRET_KEY_PASSPHRASE_PATH} --armor --output ${vfkit_bundle}.sig --detach-sig ${vfkit_bundle}
  gpg --batch --default-key crc@crc.dev --pinentry-mode=loopback --passphrase-file ${GPG_SECRET_KEY_PASSPHRASE_PATH} --armor --output ${hyperv_bundle}.sig --detach-sig ${hyperv_bundle}
  gpg --batch --default-key crc@crc.dev --pinentry-mode=loopback --passphrase-file ${GPG_SECRET_KEY_PASSPHRASE_PATH} --armor --output ${libvirt_bundle}.sig --detach-sig ${libvirt_bundle}
}

if [[ $# -ne 2 ]]; then
   echo "You need to provide the bundle version and preset (openshift/podman/okd)"
   exit 1
fi

set_bundle_variables "$1" "$2"
sign_bundle_files "$2"
generate_image "$2"
generate_manifest "$1" "$2"
