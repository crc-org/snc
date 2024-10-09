#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

echo "Updating the public key resource for machine config operator"
local pub_key=$(tr -d '\n\r' < /opt/crc/id_rsa.pub)
wait_for_resource machineconfig
oc patch machineconfig 99-master-ssh -p "{\"spec\": {\"config\": {\"passwd\": {\"users\": [{\"name\": \"core\", \"sshAuthorizedKeys\": [\"${pub_key}\"]}]}}}}" --type merge
[ "$?" != 0 ] && "failed to update public key to machine config operator"
