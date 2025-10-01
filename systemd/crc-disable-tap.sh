#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

echo "Disabling the tap0 network configuration ..."

rm -f /etc/NetworkManager/system-connections/tap0.nmconnection
systemctl disable --now gv-user-network@tap0.service || true

exit 0
