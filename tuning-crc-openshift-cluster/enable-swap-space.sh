#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo mkdir -p /var/home/core/vm
${SSH_CMD} sudo fallocate -l 3G /var/home/core/vm/swapfile
${SSH_CMD} sudo chmod 600 /var/home/core/vm/swapfile
${SSH_CMD} sudo mkswap /var/home/core/vm/swapfile

echo $'[Unit] \n Description=Turn on swap \n [Swap] \n What=/var/home/core/vm/swapfile \n [Install] \n WantedBy=multi-user.target'  | ${SSH_CMD} sudo tee -a /etc/systemd/system/var-home-core-vm-swapfile.swap
echo '/var/home/core/vm/swapfile               swap                    swap    defaults        0 0'  | ${SSH_CMD} sudo tee -a /etc/fstab

${SSH_CMD} sudo systemctl --now enable /etc/systemd/system/var-home-core-vm-swapfile.swap
${SSH_CMD} sudo systemctl status var-home-core-vm-swapfile.swap
${SSH_CMD} sudo swapon -a
${SSH_CMD} sudo swapon -s
