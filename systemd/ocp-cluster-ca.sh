#!/bin/bash

# The steps followed to generate CA and replace system:admin cert are from:
# https://access.redhat.com/solutions/5286371
# https://access.redhat.com/solutions/6054981

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource configmap

external_ip_path=/opt/crc/eip

if oc get configmap client-ca-custom -n openshift-config; then
    echo "API Server Client CA already rotated..."
    exit 0
fi

# generate CA
CA_FILE_PATH="/tmp/custom-ca.crt"
CA_KEY_FILE_PATH="/tmp/custom-ca.key"
CLIENT_CA_FILE_PATH="/tmp/client-ca.crt"
CLIENT_CA_KEY_FILE_PATH="/tmp/client-ca.key"
CLIENT_CSR_FILE_PATH="/tmp/client-csr.csr"
CA_SUBJ="/OU=openshift/CN=admin-kubeconfig-signer-custom"
CLIENT_SUBJ="/O=system:masters/CN=system:admin"
VALIDITY=365

# generate the CA private key
openssl genrsa -out ${CA_KEY_FILE_PATH} 4096
# Create the CA certificate
openssl req -x509 -new -nodes -key ${CA_KEY_FILE_PATH} -sha256 -days $VALIDITY -out ${CA_FILE_PATH} -subj "${CA_SUBJ}"
# create CSR
openssl req -new -newkey rsa:4096 -nodes -keyout ${CLIENT_CA_KEY_FILE_PATH} -out ${CLIENT_CSR_FILE_PATH} -subj "${CLIENT_SUBJ}"
# sign the CSR with above CA
openssl x509 -extfile <(printf "extendedKeyUsage = clientAuth") -req -in ${CLIENT_CSR_FILE_PATH} -CA ${CA_FILE_PATH} \
    -CAkey ${CA_KEY_FILE_PATH} -CAcreateserial -out ${CLIENT_CA_FILE_PATH} -days $VALIDITY -sha256

oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=${CA_FILE_PATH}
oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'

cluster_name=$(oc config view -o jsonpath='{.clusters[0].name}')
apiserver_url=$(oc config view -o jsonpath='{.clusters[0].cluster.server}')

if [ -f "${external_ip_path}" ]; then
    apiserver_url=https://api.$(cat "${external_ip_path}").nip.io:6443
fi

updated_kubeconfig_path=/opt/crc/kubeconfig
rm -rf "${updated_kubeconfig_path}"

oc config set-credentials system:admin --client-certificate=${CLIENT_CA_FILE_PATH} --client-key=${CLIENT_CA_KEY_FILE_PATH} \
    --embed-certs --kubeconfig="${updated_kubeconfig_path}"
oc config set-context system:admin --cluster="${cluster_name}" --namespace=default --user=system:admin --kubeconfig="${updated_kubeconfig_path}"
oc config set-cluster "${cluster_name}" --server="${apiserver_url}" --insecure-skip-tls-verify=true --kubeconfig="${updated_kubeconfig_path}"

COUNTER=0
until oc get co --context system:admin --kubeconfig="${updated_kubeconfig_path}";
do
    if [ $COUNTER == 90 ]; then
        echo "Unable to access API server using new client certitificate..."
        exit 1
    fi
    echo "Acess API server with new client cert, try $COUNTER, hang on...."
    sleep 2
    ((COUNTER++))
done

oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=${CA_FILE_PATH} \
    --dry-run=client -o yaml | oc replace -f -

# copy the new kubeconfig to /opt/kubeconfig
rm -rf /opt/kubeconfig
cp /opt/crc/kubeconfig /opt/kubeconfig
chmod 0666 /opt/kubeconfig
