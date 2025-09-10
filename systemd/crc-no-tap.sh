#!/bin/bash

# Return true if running under Apple Virtualization or CRC_SELF_SUFFICIENT is set, otherwise false

if systemd-detect-virt | grep -q '^apple$' || [ -n "$CRC_SELF_SUFFICIENT" ]; then
    rm -f /etc/NetworkManager/system-connections/tap0.nmconnection
    systemctl disable --now gv-user-network@tap0.service
fi

exit 0
