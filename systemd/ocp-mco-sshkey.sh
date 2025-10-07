#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh

CRC_PUB_KEY_PATH="${1:-}"

if [[ -z "$CRC_PUB_KEY_PATH" ]]; then
    echo "ERROR: expected to receive the path to the pub key file as first argument."
    exit 1
fi

# enforced by systemd
if [[ ! -r "$CRC_PUB_KEY_PATH" ]]; then
    echo "ERROR: CRC pubkey file does not exist ($CRC_PUB_KEY_PATH)"
    exit 1
fi

wait_for_resource_or_die machineconfig/99-master-ssh

echo "Updating the public key resource for machine config operator"
pub_key=$(cat "$CRC_PUB_KEY_PATH" | tr -d '\n\r')

jq -n --arg key "${pub_key}" '
{
  "spec": {
    "config": {
      "passwd": {
        "users": [
          {
            "name": "core",
            "sshAuthorizedKeys": [ $key ]
          }
        ]
      }
    }
  }
}' | oc patch machineconfig 99-master-ssh --type merge --patch-file=/dev/stdin

echo "All done"

exit 0
