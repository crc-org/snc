#!/bin/bash

# Return true if running under Apple Virtualization or CRC_NG is set, otherwise false

if systemd-detect-virt | grep -q '^apple$' || [ -n "$CRC_NG" ]; then
    rm -f /etc/NetworkManager/system-connections/tap0.nmconnection
fi

exit 0
