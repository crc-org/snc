#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh

PULL_SECRETS_FILE="/opt/crc/pull-secret"

wait_for_resource_or_die secret

# The pull secret data is piped through stdin and not exposed in command arguments,
# so `set -x` is safe to keep

# check if the .auths field is there
if oc get secret pull-secret \
      -n openshift-config \
      -o jsonpath="{['data']['\.dockerconfigjson']}" \
        | base64 -d \
        | jq -e 'has("auths")' >/dev/null 2>&1
then
    echo "Cluster already has some pull secrets, nothing to do."
    exit 0
fi

echo "Cluster doesn't have the pull secrets. Setting them from $PULL_SECRETS_FILE ..."

if [[ ! -r "$PULL_SECRETS_FILE" ]];
then
    echo "ERROR: $PULL_SECRETS_FILE is missing or unreadable" 1>&2
    exit 1
fi

if ! jq -e 'has("auths")' < "$PULL_SECRETS_FILE" >/dev/null;
then
    echo "ERROR: pull-secrets file doesn't have the required '.auths' field"
    exit 1
fi

# Create the JSON patch in memory and pipe it to the oc command
base64 -w0 < "$PULL_SECRETS_FILE" | \
  jq -R '{"data": {".dockerconfigjson": .}}' | \
  oc patch secret pull-secret \
     -n openshift-config \
     --type merge \
     --patch-file=/dev/stdin

echo "All done"

exit 0
