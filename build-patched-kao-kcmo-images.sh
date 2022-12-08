#!/bin/bash

# This script is used by crc developer or internal CI to build patched KAO/KCMO images with 
# 1 year certificates and then push them to quay.io/crcont. The provided pull secret should allow
# push access to `quay.io/crcont` before providing to this script.
#    - Since this script uses rhpkg and kinit commands, it is only tested on linux.
#    - As of now this script works with 4.11 releases because only the `rhaos-4.11-rhel-8` branch
#      has been created in dist-git and tested.
#    - This script is suppose to run standalone without cloning the snc repo so some code is repeated.
# Usage:
# If you want to build latest candidate stream for 4.11
#   - ./internal.sh
# If you want to build specific version of 4.11.3
#   - OPENSHIFT_VERSION=4.11.3 ./internal.sh

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

rm -fr crc-cluster-kube-apiserver-operator
rm -fr crc-cluster-kube-controller-manager-operator
rm -fr crc-dnsmasq
rm -fr crc-routes-controller

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

MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp}

# If user defined the OPENSHIFT_VERSION environment variable then use it.
if test -n "${OPENSHIFT_VERSION-}"; then
    OPENSHIFT_RELEASE_VERSION=${OPENSHIFT_VERSION}
    echo "Using release ${OPENSHIFT_RELEASE_VERSION} from OPENSHIFT_VERSION"
else
    OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/candidate-4.11/release.txt | sed -n 's/^ *Version: *//p')"
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
OC=./openshift-clients/linux/oc
if [ -f "$OC" ]; then
	current_oc_version=$(${OC} version --client -o json |jq -r .releaseClientVersion)
fi
echo "OC version: ${current_oc_version-}"
if [ ${current_oc_version-} = ${OPENSHIFT_RELEASE_VERSION} ]; then
    echo "No need to download oc, local oc is already version ${OPENSHIFT_RELEASE_VERSION}"
else
    curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/openshift-client-linux-${OPENSHIFT_RELEASE_VERSION}.tar.gz" | tar -zx -C openshift-clients/linux oc
fi

function patch_and_push_image() {
    local image_name=$1
    image=$(${OC} adm release info -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=${image_name})
    vcs_ref=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels."vcs-ref"')
    version=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels.version')
    release=$(${OC} image info -a ${OPENSHIFT_PULL_SECRET_PATH} ${image} -ojson | jq -r '.config.config.Labels.release')
    rhpkg clone containers/crc-${image_name}
    pushd crc-${image_name}
    git remote add upstream git://pkgs.devel.redhat.com/containers/ose-${image_name}
    # Just fetch the upstream/rhaos-4.11-rhel-8 instead of all the branches and tags from upstream
    git fetch upstream rhaos-4.11-rhel-8 --no-tags
    git checkout --track origin/rhaos-4.11-rhel-8
    git merge --no-ff -m "Merge commit ${vcs_ref} into rhaos-4.11-rhel-8" -m "MaxFileSize: 104857600" ${vcs_ref}
    git push origin HEAD
    rhpkg container-build  --target crc-1-rhel-8-candidate
    popd
    skopeo copy --dest-authfile ${OPENSHIFT_PULL_SECRET_PATH} --all docker://registry-proxy.engineering.redhat.com/rh-osbs/openshift-crc-${image_name}:${version}-${release} docker://quay.io/crcont/openshift-crc-${image_name}:${openshift_version}
}

function update_base_image() {
    local brew_repo=$1
    local base_image=$2

    rhpkg clone containers/${brew_repo}
    pushd ${brew_repo}
    git checkout --track origin/crc-1-rhel-8
    git checkout --track origin/private-cfergeau
    git reset --hard origin/crc-1-rhel-8
    sed -i "s!^FROM openshift/ose-base.*!FROM $base_image!" Dockerfile
    git add Dockerfile
    git commit -m "Use OpenShift ${openshift_version} base image"
    git push origin -f HEAD:private-cfergeau
    rhpkg container-build --scratch --target crc-1-rhel-8-candidate
    popd

    skopeo copy --dest-authfile ${OPENSHIFT_PULL_SECRET_PATH} --all docker://registry-proxy.engineering.redhat.com/rh-osbs/${brew_repo}:latest docker://quay.io/crcont/${brew_repo#crc-}:${openshift_version}
    skopeo copy --dest-authfile ${OPENSHIFT_PULL_SECRET_PATH} --all docker://registry-proxy.engineering.redhat.com/rh-osbs/${brew_repo}:latest docker://quay.io/crcont/${brew_repo#crc-}:latest
}

openshift_version=$(${OC} adm release info -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} -ojsonpath='{.config.config.Labels.io\.openshift\.release}')

patch_and_push_image cluster-kube-apiserver-operator
patch_and_push_image cluster-kube-controller-manager-operator

base_image=$(grep "^FROM openshift/ose-base" crc-cluster-kube-apiserver-operator/Dockerfile | sed 's/^FROM //')

update_base_image crc-dnsmasq "${base_image}"
update_base_image crc-routes-controller "${base_image}"
