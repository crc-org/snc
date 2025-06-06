#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

pub_key_path="/opt/crc/id_rsa.pub"

if [ ! -f "${pub_key_path}" ]; then
    echo "No pubkey file found"
    exit 1
fi

echo "Updating the public key resource for machine config operator"
pub_key=$(tr -d '\n\r' < ${pub_key_path})
wait_for_resource machineconfig
if ! oc patch machineconfig 99-master-ssh -p "{\"spec\": {\"config\": {\"passwd\": {\"users\": [{\"name\": \"core\", \"sshAuthorizedKeys\": [\"${pub_key}\"]}]}}}}" --type merge;
then
    echo "failed to update public key to machine config operator"
    exit 1
fi
