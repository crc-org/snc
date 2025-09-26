#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource secret

set +x # disable the logging to avoid leaking the pull secrets

# check if existing pull-secret is valid if not add the one from /opt/crc/pull-secret
existingPsB64=$(oc get secret pull-secret -n openshift-config -o jsonpath="{['data']['\.dockerconfigjson']}")
existingPs=$(echo "${existingPsB64}" | base64 -d)

# check if the .auths field is there
if echo "${existingPs}" | jq -e 'has("auths")' >/dev/null 2>&1; then
    echo "Cluster already has the pull secrets, nothing to do"
    exit 0
fi

echo "Cluster doesn't have the pull secrets. Setting them from /opt/crc/pull-secret ..."
pullSecretB64=$(base64 -w0 < /opt/crc/pull-secret)
# Create the JSON patch in memory and pipe it to the oc command
printf '{"data":{".dockerconfigjson": "%s"}}' "${pullSecretB64}" | \
    oc patch secret pull-secret -n openshift-config --type merge --patch-file=/dev/stdin

exit 0
