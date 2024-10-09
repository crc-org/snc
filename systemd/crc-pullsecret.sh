#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource secret

# check if existing pull-secret is valid if not add the one from /opt/crc/pull-secret
existingPsB64=$(oc get secret pull-secret -n openshift-config -o jsonpath="{['data']['\.dockerconfigjson']}")
existingPs=$(echo "${existingPsB64}" | base64 -d)

echo "${existingPs}" | jq -e '.auths'

if [[ $? != 0 ]]; then
    pullSecretB64=$(cat /opt/crc/pull-secret | base64 -w0)
    oc patch secret pull-secret -n openshift-config --type merge -p "{\"data\":{\".dockerconfigjson\":\"${pullSecretB64}\"}}"
    rm -f /opt/crc/pull-secret
fi

