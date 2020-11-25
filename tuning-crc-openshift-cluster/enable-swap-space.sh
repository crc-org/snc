#!/bin/bash

set -exuo pipefail
if [[ $( sudo swapon -s | wc -c) -ne 0 ]];
then
	sudo mkdir -p /var/home/core/vm
	sudo fallocate -l 6G /var/home/core/vm/swapfile
	sudo chmod 600 /var/home/core/vm/swapfile
	sudo mkswap /var/home/core/vm/swapfile

	echo $'[Unit] \n Description=Turn on swap \n [Swap] \n What=/var/home/core/vm/swapfile \n [Install] \n WantedBy=multi-user.target'  | ${SSH_CMD} sudo tee -a /etc/systemd/system/var-home-core-vm-swapfile.swap
	echo '/var/home/core/vm/swapfile               swap                    swap    defaults        0 0'  | ${SSH_CMD} sudo tee -a /etc/fstab

	sudo systemctl --now enable /etc/systemd/system/var-home-core-vm-swapfile.swap
	sudo systemctl status var-home-core-vm-swapfile.swap
	sudo swapon -a
	sudo swapon -s
else
	echo 'swapfile is already present'
fi
