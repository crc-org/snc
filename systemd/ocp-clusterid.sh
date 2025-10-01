#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource_or_die clusterversion

uuid=$(uuidgen)

jq -n --arg id "${uuid}" '{spec: {clusterID: $id}}' \
    | oc patch clusterversion version --type merge --patch-file=/dev/stdin

echo "All done"

exit 0
