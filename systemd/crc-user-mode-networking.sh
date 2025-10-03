#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

EXIT_USER_MODE=0
EXIT_NOT_USER_MODE=1

if [[ -z "${CRC_NETWORK_MODE_USER:-}" ]]; then
    echo "CRC_NETWORK_MODE_USER not set. Assuming user networking."
    exit "$EXIT_USER_MODE"
fi

if (( CRC_NETWORK_MODE_USER == 0 )); then
    echo "network-mode 'system' detected"
    exit "$EXIT_NOT_USER_MODE"
fi

if (( CRC_NETWORK_MODE_USER == 1 )); then
    echo "network-mode 'user' detected"
    exit "$EXIT_USER_MODE"
fi

echo "ERROR: unknown network mode: CRC_NETWORK_MODE_USER=$CRC_NETWORK_MODE_USER (expected 0 or 1). Assuming user networking"

exit "$EXIT_USER_MODE"
