#!/bin/bash

# The steps followed to generate CA and replace system:admin cert are from:
# https://access.redhat.com/solutions/5286371
# https://access.redhat.com/solutions/6054981

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

source /usr/local/bin/crc-systemd-common.sh

wait_for_resource_or_die configmap

CRC_EXTERNAL_IP_FILE_PATH=/opt/crc/eip # may or may not be there. See below ...

if oc get configmap client-ca-custom -n openshift-config 2>/dev/null; then
    echo "API Server Client CA already rotated..."
    exit 0
fi

echo "API Server Client CA not rotated. Doing it now ..."

# generate CA
CA_FILE_PATH="/tmp/custom-ca.crt"
CA_KEY_FILE_PATH="/tmp/custom-ca.key"
CLIENT_CA_FILE_PATH="/tmp/client-ca.crt"
CLIENT_CA_KEY_FILE_PATH="/tmp/client-ca.key"
CLIENT_CSR_FILE_PATH="/tmp/client-csr.csr"
CA_SUBJ="/OU=openshift/CN=admin-kubeconfig-signer-custom"
CLIENT_SUBJ="/O=system:masters/CN=system:admin"
VALIDITY=365

cleanup() {
    rm -f "$CA_FILE_PATH" "$CA_KEY_FILE_PATH" \
       "$CLIENT_CA_FILE_PATH" "$CLIENT_CA_KEY_FILE_PATH" "$CLIENT_CSR_FILE_PATH"
    echo "Temp files cleanup complete."
}

# keep cleanup bound to EXIT; no need to clear ERR early
trap cleanup ERR EXIT

# generate the CA private key
openssl genrsa -out "$CA_KEY_FILE_PATH" 4096
# Create the CA certificate
openssl req -x509 -new -nodes -key "$CA_KEY_FILE_PATH" -sha256 -days "$VALIDITY" -out "$CA_FILE_PATH" -subj "$CA_SUBJ"
# create CSR
openssl req -new -newkey rsa:4096 -nodes -keyout "$CLIENT_CA_KEY_FILE_PATH" -out "$CLIENT_CSR_FILE_PATH" -subj "$CLIENT_SUBJ"
# sign the CSR with above CA
openssl x509 -extfile <(printf "extendedKeyUsage = clientAuth") -req -in "$CLIENT_CSR_FILE_PATH" -CA "$CA_FILE_PATH" \
    -CAkey "$CA_KEY_FILE_PATH" -CAcreateserial -out "$CLIENT_CA_FILE_PATH" -days "$VALIDITY" -sha256

oc create configmap client-ca-custom \
   -n openshift-config \
   --from-file=ca-bundle.crt="$CA_FILE_PATH" \
   --dry-run=client -o yaml \
    | oc apply -f -

jq -n '
{
  "spec": {
    "clientCA": {
      "name": "client-ca-custom"
    }
  }
}' | oc patch apiserver cluster --type=merge --patch-file=/dev/stdin

cluster_name=$(oc config view -o jsonpath='{.clusters[0].name}')

if [[ -r "$CRC_EXTERNAL_IP_FILE_PATH" ]]; then
    external_ip=$(tr -d '\r\n' < "$CRC_EXTERNAL_IP_FILE_PATH")
    apiserver_url=https://api.${external_ip}.nip.io:6443
    echo "INFO: CRC external IP file found. Using apiserver_url='$apiserver_url'."
else
    apiserver_url=$(oc config view -o jsonpath='{.clusters[0].cluster.server}')
    echo "INFO: CRC external IP file does not exist ($CRC_EXTERNAL_IP_FILE_PATH). Using apiserver_url='$apiserver_url'."
fi

export KUBECONFIG=/opt/crc/kubeconfig
rm -rf "$KUBECONFIG"

oc config set-credentials admin \
   --client-certificate="$CLIENT_CA_FILE_PATH" \
   --client-key="$CLIENT_CA_KEY_FILE_PATH" \
   --embed-certs

oc config set-context admin --cluster="$cluster_name" --namespace=default --user=admin
oc config set-cluster "$cluster_name" --server="$apiserver_url" --insecure-skip-tls-verify=true
oc config use-context admin

wait_for_resource_or_die clusteroperators 90 2

oc create configmap admin-kubeconfig-client-ca \
   -n openshift-config \
   --from-file=ca-bundle.crt="$CA_FILE_PATH" \
   --dry-run=client -oyaml \
    | oc apply -f-

# copy the new kubeconfig to /opt/kubeconfig
rm -f /opt/kubeconfig
cp /opt/crc/kubeconfig /opt/kubeconfig
chmod 0666 /opt/kubeconfig # keep the file readable by everyone in the system, this is safe

# cleanup will apply here

echo "All done"

exit 0
