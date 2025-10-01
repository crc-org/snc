#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

if (( ${CRC_SELF_SUFFICIENT:-0} == 1 )); then
    echo "Running with a self sufficient bundle"
    exit 0
fi

echo "Not running in a self-sufficient or cloud environment"

exit 1
