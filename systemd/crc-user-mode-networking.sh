#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

EXIT_ERROR=77

target="${1:-}"
if [[ "$target" == user || -z "$target" ]]; then
    # searching for user mode, return 0 if user
    EXIT_USER_MODE=0
    EXIT_NOT_USER_MODE=1
elif [[ "$target" == system ]]; then
    # searching for system mode, return 0 if system
    EXIT_NOT_USER_MODE=0
    EXIT_USER_MODE=1
else
    echo "ERROR: invalid target '$target'. Should be 'user' (default) or 'system'. Got '$target'." >&2
    exit "$EXIT_ERROR"
fi


if /usr/local/bin/crc-self-sufficient-env.sh; then
    echo "Running a self-sufficient bundle. Not user-mode networking."
    if [[ "${CRC_NETWORK_MODE_USER:-}" ]]; then
        echo "WARNING: Ignoring CRC_NETWORK_MODE_USER='$CRC_NETWORK_MODE_USER' in the self-sufficient bundle."
    fi

    exit "$EXIT_NOT_USER_MODE"
fi

# no value --> error
if [[ -z "${CRC_NETWORK_MODE_USER:-}" ]]; then
    echo "ERROR: CRC_NETWORK_MODE_USER not set. Assuming user networking." >&2
    exit "$EXIT_USER_MODE"
fi

# value not in [0, 1] --> error
if [[ ! "${CRC_NETWORK_MODE_USER}" =~ ^[01]$ ]]; then
    echo "ERROR: unknown network mode: CRC_NETWORK_MODE_USER=${CRC_NETWORK_MODE_USER} (expected 0 or 1)" >&2
    exit "$EXIT_ERROR"
fi

# value == 0 --> not user-node
if (( CRC_NETWORK_MODE_USER == 0 )); then
    echo "network-mode 'system' detected"
    exit "$EXIT_NOT_USER_MODE"
fi

# value == 1 --> user-mode
if (( CRC_NETWORK_MODE_USER == 1 )); then
    echo "network-mode 'user' detected"
    exit "$EXIT_USER_MODE"
fi

# anything else --> error (can't be reached)
echo "ERROR: unknown network mode: CRC_NETWORK_MODE_USER=$CRC_NETWORK_MODE_USER." >&2
echo "Assuming user networking." >&2
echo "SHOULD NOT BE REACHED." >&2

exit "$EXIT_ERROR"
