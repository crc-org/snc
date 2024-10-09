#!/bin/bash

set -x

if [[ ${CRC_NETWORK_MODE_USER} -eq 0 ]]; then
    echo -n "network-mode 'system' detected: skipping routes-controller pod deployment"
    exit 0
fi

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG=/opt/kubeconfig

wait_for_resource pods

oc apply -f /opt/crc/routes-controller.yaml

