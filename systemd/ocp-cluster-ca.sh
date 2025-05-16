#!/bin/bash

# The steps followed to generate CA and replace system:admin cert are from:
# https://access.redhat.com/solutions/5286371
# https://access.redhat.com/solutions/6054981

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource configmap

custom_ca_path=/opt/crc/custom-ca.crt
external_ip_path=/opt/crc/eip

if [ ! -f ${custom_ca_path} ]; then
    echo "Cert bundle /opt/crc/custom-ca.crt not found, generating one..."
    # generate a ca bundle and use it, overwrite custom_ca_path
    CA_SUBJ="/OU=openshift/CN=admin-kubeconfig-signer-custom"
    openssl genrsa -out /tmp/custom-ca.key 4096
    openssl req -x509 -new -nodes -key /tmp/custom-ca.key -sha256 -days 365 -out "${custom_ca_path}" -subj "${CA_SUBJ}"
fi

if [ ! -f /opt/crc/pass_kubeadmin ]; then
    echo "kubeadmin password file not found"
    exit 1
fi

PASS_KUBEADMIN="$(cat /opt/crc/pass_kubeadmin)"
oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path}
oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'
oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path} \
    --dry-run=client -o yaml | oc replace -f -

rm -f /opt/crc/custom-ca.crt

# create CSR
openssl req -new -newkey rsa:4096 -nodes -keyout /tmp/newauth-access.key -out /tmp/newauth-access.csr -subj "/CN=system:admin"

cat << EOF >> /tmp/newauth-access-csr.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: newauth-access
spec:
  signerName: kubernetes.io/kube-apiserver-client
  groups:
  - system:authenticated
  request: $(cat /tmp/newauth-access.csr | base64 -w0)
  usages:
  - client auth
EOF

oc create -f /tmp/newauth-access-csr.yaml

until `oc adm certificate approve newauth-access > /dev/null 2>&1`
do
    echo "Unable to approve the csr newauth-access"
    sleep 5
done

cluster_name=$(oc config view -o jsonpath='{.clusters[0].name}')
apiserver_url=$(oc config view -o jsonpath='{.clusters[0].cluster.server}')

if [ -f "${external_ip_path}" ]; then
    apiserver_url=api.$(cat "${external_ip_path}").nip.io
fi

updated_kubeconfig_path=/opt/crc/kubeconfig

oc get csr newauth-access -o jsonpath='{.status.certificate}' | base64 -d > /tmp/newauth-access.crt
oc config set-credentials system:admin --client-certificate=/tmp/newauth-access.crt --client-key=/tmp/newauth-access.key --embed-certs --kubeconfig="${updated_kubeconfig_path}"
oc config set-context system:admin --cluster="${cluster_name}" --namespace=default --user=system:admin --kubeconfig="${updated_kubeconfig_path}"
oc get secret localhost-recovery-client-token -n openshift-kube-controller-manager -ojsonpath='{.data.ca\.crt}'| base64 -d > /tmp/bundle-ca.crt
oc config set-cluster "${cluster_name}" --server="${apiserver_url}" --certificate-authority=/tmp/bundle-ca.crt \
    --kubeconfig="${updated_kubeconfig_path}" --embed-certs

echo "Logging in again to update $KUBECONFIG with kubeadmin token"
COUNTER=0
MAXIMUM_LOGIN_RETRY=500
until `oc login --insecure-skip-tls-verify=true -u kubeadmin -p "$PASS_KUBEADMIN" https://api.crc.testing:6443 --kubeconfig /opt/crc/newkubeconfig > /dev/null 2>&1`
do
    if [ $COUNTER == $MAXIMUM_LOGIN_RETRY ]; then
        echo "Unable to login to the cluster..., installation failed."
        exit 1
    fi
    echo "Logging into OpenShift with updated credentials try $COUNTER, hang on...."
    sleep 5
    ((COUNTER++))
done
