#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

CRC_EXTERNAL_IP_FILE_PATH=/opt/crc/eip

if [[ ! -r "$CRC_EXTERNAL_IP_FILE_PATH" ]]; then
    echo "ERROR: CRC external ip file not found ($CRC_EXTERNAL_IP_FILE_PATH)"  >&2
    exit 1
fi

EIP=$(tr -d '\r\n' < "$CRC_EXTERNAL_IP_FILE_PATH")

if [[ -z "$EIP" ]]; then
    echo "ERROR: External IP file is empty: $CRC_EXTERNAL_IP_FILE_PATH" >&2
    exit 1
fi

# Basic IPv4 sanity check; adjust if IPv6 is expected
if [[ ! "$EIP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IPv4 address read from $CRC_EXTERNAL_IP_FILE_PATH: '$EIP'" >&2
    exit 1
fi

wait_for_resource_or_die secret

TMP_KEY_FILE=$(mktemp /tmp/nip.key.XXXXX)
TMP_CRT_FILE=$(mktemp /tmp/nip.crt.XXXXX)

cleanup() {
    rm -f "$TMP_KEY_FILE" "$TMP_CRT_FILE"
    echo "Temp files cleanup complete."
}

# Cleanup happens automatically via trap on error or at script end
trap cleanup ERR EXIT

# create cert and add as secret
openssl req -newkey rsa:2048 -new \
        -nodes -x509 -days 3650 \
        -keyout "$TMP_KEY_FILE" -out "$TMP_CRT_FILE" \
        -subj "/CN=$EIP.nip.io" \
        -addext "subjectAltName=DNS:apps.$EIP.nip.io,DNS:*.apps.$EIP.nip.io,DNS:api.$EIP.nip.io"

oc delete secret nip-secret -n openshift-config --ignore-not-found
oc create secret tls nip-secret \
   --cert="$TMP_CRT_FILE" \
   --key="$TMP_KEY_FILE" \
   -n openshift-config

# patch ingress
wait_for_resource_or_die ingresses.config.openshift.io
jq -n --arg eip "$EIP" '
{
  "spec": {
    "appsDomain": "apps.\($eip).nip.io",
    "componentRoutes": [
      {
        "hostname": "console-openshift-console.apps.\($eip).nip.io",
        "name": "console",
        "namespace": "openshift-console",
        "servingCertKeyPairSecret": {
          "name": "nip-secret"
        }
      },
      {
        "hostname": "oauth-openshift.apps.\($eip).nip.io",
        "name": "oauth-openshift",
        "namespace": "openshift-authentication",
        "servingCertKeyPairSecret": {
          "name": "nip-secret"
        }
      }
    ]
  }
}' | oc patch ingresses.config.openshift.io cluster --type=merge --patch-file=/dev/stdin

# patch API server to use new CA secret
wait_for_resource_or_die apiserver.config.openshift.io
jq -n --arg eip "$EIP" '
{
  "spec": {
    "servingCerts": {
      "namedCertificates": [
        {
          "names": [
            "api.\($eip).nip.io"
          ],
          "servingCertificate": {
            "name": "nip-secret"
          }
        }
      ]
    }
  }
}' | oc patch apiserver cluster --type=merge --patch-file=/dev/stdin

# patch image registry route
wait_for_resource_or_die route.route.openshift.io
jq -n --arg eip "$EIP" '
{
  "spec": {
    "host": "default-route-openshift-image-registry.\($eip).nip.io"
  }
}' | oc patch route default-route -n openshift-image-registry --type=merge --patch-file=/dev/stdin

echo "All done"

exit 0
