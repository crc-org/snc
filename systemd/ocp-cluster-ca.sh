#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"
PASS_KUBEADMIN="$(cat /opt/crc/password_kubeadmin)"

wait_for_resource configmap

custom_ca_path=/opt/crc/custom-ca.crt

if [[ ! -f ${custom_ca_path} ]]; then
    echo "Cert bundle /opt/crc/custom-ca.crt not found"
    exit 0
fi

oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path}
oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'
oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path} \
--dry-run -o yaml | oc replace -f -

rm -f /opt/crc/custom-ca.crt

echo "Logging in again to update $KUBECONFIG"
COUNTER=0
MAXIMUM_LOGIN_RETRY=500
until `oc login --insecure-skip-tls-verify=true -u kubeadmin -p "$PASS_KUBEADMIN" https://api.crc.testing:6443 > /dev/null 2>&1`
do
    [ $COUNTER == $MAXIMUM_LOGIN_RETRY ] && echo "Unable to login to the cluster..., installation failed."
    echo "Logging into OpenShift with updated credentials try $COUNTER, hang on...."
    sleep 5
    ((COUNTER++))
done
