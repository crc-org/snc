#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo fallocate -l 3G /var/home/core/crc-swapfile
${SSH_CMD} sudo chmod 600 /var/home/core/crc-swapfile
${SSH_CMD} sudo mkswap /var/home/core/crc-swapfile
${SSH_CMD} sudo swapon /var/home/core/crc-swapfile
${SSH_CMD} sudo echo '/var/home/core/crc-swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
${SSH_CMD} sudo swapon -s
