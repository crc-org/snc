#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace

source /usr/local/bin/crc-systemd-common.sh

SECONDS=0
MAX_RETRY=150
WAIT_SEC=2
NODE_NAME=node/crc
# Loop from 1 up to max_retry
for retry in $(seq 1 "$MAX_RETRY"); do
    node_status=$(oc get "$NODE_NAME" --no-headers | awk '{print $2}' || true)
    node_status=${node_status:-"<status unavailable>"}

    # Check if the node status is "Ready"
    if [[ $node_status == "Ready" ]]; then
        echo "CRC node is ready after $SECONDS seconds."
        exit 0
    fi

    echo "CRC node is not ready. Status: $node_status"

    # If it's the last attempt, log a failure message before exiting
    if (( retry == MAX_RETRY )); then
        echo "ERROR: Timed out waiting for the CRC node to be ready after $MAX_RETRY attempts x $WAIT_SEC seconds." >&2
        exit 1
    fi

    # Wait before the next attempt
    echo "Waiting $WAIT_SEC seconds for crc node to be ready ... (Attempt ${retry}/${MAX_RETRY})"
    sleep "$WAIT_SEC"
done

# cannot be reached

exit 1
