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

# Use --rawfile to read the key file directly into a jq variable named 'pub_key'.
# The key's content is never exposed as a command-line argument.
# We use jq's rtrimstr function to remove any trailing newlines from the file.

jq -n --rawfile pub_key "$CRC_PUB_KEY_PATH" '
{
  "spec": {
    "config": {
      "passwd": {
        "users": [
          {
            "name": "core",
            "sshAuthorizedKeys": [
              # Trim trailing newlines and carriage returns from the slurped file content
              $pub_key | rtrimstr("\n") | rtrimstr("\r")
            ]
          }
        ]
      }
    }
  }
}' | oc patch machineconfig 99-master-ssh --type merge --patch-file=/dev/stdin

echo "All done"

exit 0
