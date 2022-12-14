#!/bin/bash

# This script is used by crc developer or internal CI to build patched KAO/KCMO images with 
# 1 year certificates and then push them to quay.io/crcont. The provided pull secret should allow
# push access to `quay.io/crcont` before providing to this script.
#    - Since this script uses rhpkg and kinit commands, it is only tested on linux.
#    - As of now this script works with 4.12 nightly because only the `rhaos-4.12-rhel-8` branch
#      has been created in dist-git and tested.
#    - This script is suppose to run standalone without cloning the snc repo so some code is repeated.
# Usage:
# If you want to build latest candidate stream for 4.12
#   - ./build-patched-kao-kcmo-images.sh
# If you want to build specific version of 4.12.0-ec.3
#   - OPENSHIFT_VERSION=4.12.0-ec.3 ./build-patched-kao-kcmo-images.sh

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

rm -fr crc-cluster-kube-apiserver-operator
rm -fr crc-cluster-kube-controller-manager-operator

readonly OCP_VERSION=4.12

function check_pull_secret() {
        if [ -z "${OPENSHIFT_PULL_SECRET_PATH-}" ]; then
            echo "OpenShift pull secret file path must be specified through the OPENSHIFT_PULL_SECRET_PATH environment variable"
            exit 1
        elif [ ! -f ${OPENSHIFT_PULL_SECRET_PATH} ]; then
            echo "Provided OPENSHIFT_PULL_SECRET_PATH (${OPENSHIFT_PULL_SECRET_PATH}) does not exists"
            exit 1
        fi
}

check_pull_secret

MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp-dev-preview}

# If user defined the OPENSHIFT_VERSION environment variable then use it.
if test -n "${OPENSHIFT_VERSION-}"; then
    OPENSHIFT_RELEASE_VERSION=${OPENSHIFT_VERSION}
    echo "Using release ${OPENSHIFT_RELEASE_VERSION} from OPENSHIFT_VERSION"
else
    OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/latest-${OCP_VERSION}/release.txt | sed -n 's/^ *Version: *//p')"
    if test -n "${OPENSHIFT_RELEASE_VERSION}"; then
        echo "Using release ${OPENSHIFT_RELEASE_VERSION} from the mirror"
    else
        echo "Unable to determine an OpenShift release version. You may want to set the OPENSHIFT_VERSION environment variable explicitly."
        exit 1
    fi
fi

if test -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE-}"; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/release.txt" | sed -n 's/^Pull From: //p')"
elif test -n "${OPENSHIFT_VERSION-}"; then
    echo "Both OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE and OPENSHIFT_VERSION are set, OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE will take precedence"
    echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
    echo "OPENSHIFT_VERSION: $OPENSHIFT_VERSION"
fi
echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

mkdir -p openshift-clients/linux
curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/openshift-client-linux-${OPENSHIFT_RELEASE_VERSION}.tar.gz" | tar -zx -C openshift-clients/linux oc
OC=./openshift-clients/linux/oc

function patch_and_push_image() {
    local image_name=$1
    openshift_version=$(${OC} adm release info -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} -ojsonpath='{.config.config.Labels.io\.openshift\.release}')
    image=$(${OC} adm release info -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=${image_name})
    vcs_ref=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels."vcs-ref"')
    version=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels.version')
    release=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels.release')
    rhpkg clone containers/crc-${image_name}
    pushd crc-${image_name}
    git remote add upstream git://pkgs.devel.redhat.com/containers/ose-${image_name}
    # Just fetch the upstream/rhaos-${OCP_VERSION}-rhel-8 instead of all the branches and tags from upstream
    git fetch upstream rhaos-${OCP_VERSION}-rhel-8 --no-tags
    git checkout --track origin/private-rhaos-${OCP_VERSION}-rhel-8
    git merge --no-ff -m "Merge commit ${vcs_ref} into rhaos-${OCP_VERSION}-rhel-8" -m "MaxFileSize: 104857600" ${vcs_ref}
    git push origin HEAD
    rhpkg container-build --scratch --target crc-1-rhel-8-candidate &> rhpkg.out
    brew_image=$(grep -o 'registry-proxy.engineering.redhat.com.*' rhpkg.out)
    popd
    skopeo copy --dest-authfile ${OPENSHIFT_PULL_SECRET_PATH} --all docker://${brew_image} docker://quay.io/crcont/openshift-crc-${image_name}:${openshift_version}
}

patch_and_push_image cluster-kube-apiserver-operator
patch_and_push_image cluster-kube-controller-manager-operator
