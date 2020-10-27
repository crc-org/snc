#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo mkdir -p /var/home/core/vm
${SSH_CMD} sudo fallocate -l 3G /var/home/core/vm/crc-swapfile
${SSH_CMD} sudo chmod 600 /var/home/core/vm/crc-swapfile
${SSH_CMD} sudo mkswap /var/home/core/vm/crc-swapfile

sudo tee -a /etc/systemd/system/var-home-core-vm-swapfile.swap > /dev/null <<EOT
[Unit]
Description=Turn on swap

[Swap]
What=/var/home/core/vm/crc-swapfile

[Install]
WantedBy=multi-user.target

EOT

${SSH_CMD} sudo systemctl --now enable /etc/systemd/system/var-home-core-vm-swapfile.swap
${SSH_CMD} sudo systemctl status var-home-core-vm-swapfile.swap
${SSH_CMD} sudo swapon -s
