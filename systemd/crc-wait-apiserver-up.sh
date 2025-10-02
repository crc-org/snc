#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /usr/local/bin/crc-systemd-common.sh

echo "Waiting for the node resource to be available ..."
# $1 resource, $2 retry count, $3 wait time
wait_for_resource_or_die node 60 5

echo "node resource available, APIServer is ready."

echo "All done"

exit 0
