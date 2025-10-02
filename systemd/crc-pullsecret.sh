#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh

wait_for_resource_or_die secret

# The pull secret data is piped through stdin and not exposed in command arguments,
# so `set -x` is safe to keep

# check if the .auths field is there
if oc get secret pull-secret \
      -n openshift-config \
      -o jsonpath="{['data']['\.dockerconfigjson']}" \
        | base64 -d \
        | jq -e 'has("auths")' >/dev/null 2>&1;
then
    echo "Cluster already has some pull secrets, nothing to do."
    exit 0
fi

echo "Cluster doesn't have the pull secrets. Setting them from /opt/crc/pull-secret ..."

if [ ! -r /opt/crc/pull-secret ]; then
    echo "/opt/crc/pull-secret is missing or unreadable" 1>&2
    exit 1
fi

# Create the JSON patch in memory and pipe it to the oc command
base64 -w0 < /opt/crc/pull-secret | \
  jq -R '{"data": {".dockerconfigjson": .}}' | \
  oc patch secret pull-secret \
     -n openshift-config \
     --type merge \
     --patch-file=/dev/stdin

echo "All done"

exit 0
