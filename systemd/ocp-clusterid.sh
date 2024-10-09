#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"
uuid=$(uuidgen)

wait_for_resource clusterversion

oc patch clusterversion version -p "{\"spec\":{\"clusterID\":\"${uuid}\"}}" --type merge
