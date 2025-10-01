#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

# Nothing to do here if CRC needs the TAP interface
if /usr/local/bin/crc-needs-tap.sh; then
    echo "TAP device is required, doing nothing."
    exit 0
fi

echo "TAP device not required, running disable script..."

exec /usr/local/bin/crc-disable-tap.sh
