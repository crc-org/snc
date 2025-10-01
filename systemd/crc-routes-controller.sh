#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

ROUTE_CONTROLLER=/opt/crc/routes-controller.yaml

source /usr/local/bin/crc-systemd-common.sh

export KUBECONFIG=/opt/kubeconfig

wait_for_resource_or_die pods
wait_for_resource_or_die deployments

oc apply -f "$ROUTE_CONTROLLER"

echo "All done."

exit 0
