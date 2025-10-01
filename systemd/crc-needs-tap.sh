#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

running_on_aws() {
    # Set a timeout for the curl command
    TIMEOUT=1

    # Check the DMI registry
    if dmidecode | grep -q "Amazon EC2"; then
        echo "✅ Running on an AWS EC2 instance (detected via DMI)."
        return 0

    # As a fallback, check the metadata service
    elif curl -s -m $TIMEOUT http://169.254.169.254/latest/meta-data/instance-id > /dev/null 2>&1; then
        echo "✅ Running on an AWS EC2 instance."
        return 0
    else
        echo "❌ Not running on an AWS EC2 instance."
        return 1
    fi
}

NEED_TAP=0
DONT_NEED_TAP=1

if running_on_aws ; then
    echo "Running on AWS. Don't need tap0."
    exit "$DONT_NEED_TAP"
fi

virt="$(systemd-detect-virt || true)"

if [[ "${virt}" == "apple" ]] ; then
    echo "Running with 'virt' virtualization. Don't need tap0."
    exit "$DONT_NEED_TAP"
fi

if [[ "${virt}" =~ ^(kvm|microsoft)$ ]] ; then
    echo "Running with '$virt' virtualization. Need tap0."
    exit "$NEED_TAP"
fi

if /usr/local/bin/crc-self-sufficient-env.sh; then
    echo "Running with a self-sufficient bundle. Don't keep tap0"
    exit "$DONT_NEED_TAP"
fi

echo "No particular environment detected. Don't keep tap0"

exit "$DONT_NEED_TAP"
