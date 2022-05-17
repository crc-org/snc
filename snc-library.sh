#!/bin/bash

set -exuo pipefail

function preflight_failure() {
        local msg=$1
        echo "$msg"
        if [ -z "${SNC_NON_FATAL_PREFLIGHT_CHECKS-}" ]; then
                exit 1
        fi
}

function run_preflight_checks() {
	if ! sudo virsh net-info default &> /dev/null; then
		echo "Installing libvirt default network configuration"
		sudo dnf install -y libvirt-daemon-config-network || exit 1
	fi
	echo "default libvirt network is available"

	#Check if default libvirt network is Active
	if [[ $(sudo virsh net-info default | awk '{print $2}' | sed '3q;d') == "no" ]]; then
		echo "Default network is not active, starting it"
		sudo virsh net-start default || exit 1
	fi

	#Just warn if architecture is not supported
	case $ARCH in
		x86_64|ppc64le|s390x|aarch64)
			echo "The host arch is ${ARCH}.";;
		*)
 			echo "The host arch is ${ARCH}. This is not supported by SNC!";;
	esac

        # check for availability of a hypervisor using kvm
        if ! sudo virsh capabilities | ${XMLLINT} --xpath "/capabilities/guest/arch[@name='${ARCH}']/domain[@type='kvm']" - &>/dev/null; then
                preflight_failure "Your ${ARCH} platform does not provide a hardware-accelerated hypervisor, it's strongly recommended to enable it before running SNC. Check virt-host-validate for more detailed diagnostics"
                return
        fi
}

function create_json_description {
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.4"' \
            | ${JQ} '.type = "podman"' \
            | ${JQ} ".arch = \"${yq_ARCH}\"" \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" >${CRC_INSTALL_DIR}/crc-bundle-info.json
}

