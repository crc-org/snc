#!/bin/bash

# To generate the custom-ca.crt
# USER="system:admin"
# GROUP="system:masters"
# USER_SUBJ="/O=${GROUP}/CN=${USER}"
# NAME="custom"
# CA_SUBJ="/OU=openshift/CN=admin-kubeconfig-signer-custom"
# VALIDITY=3650

# openssl genrsa -out $NAME-ca.key 4096
# openssl req -x509 -new -nodes -key $NAME-ca.key -sha256 -days $VALIDITY -out $NAME-ca.crt -subj "$CA_SUBJ"
# openssl req -nodes -newkey rsa:2048 -keyout $USER.key -subj "$USER_SUBJ" -out $USER.csr
# openssl x509 -extfile <(printf "extendedKeyUsage = clientAuth") -req -in $USER.csr \
#    -CA $NAME-ca.crt -CAkey $NAME-ca.key -CAcreateserial -out $USER.crt -days $VALIDITY -sha256

set -x

if [ -z $CRC_CLOUD ]; then
    echo "Not running in crc-cloud mode"
    exit 0
fi

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource configmap

custom_ca_path=/opt/crc/custom-ca.crt

retry=0
max_retry=20
until `ls ${custom_ca_path} > /dev/null 2>&1`
do
    [ $retry == $max_retry ] && exit 1
    sleep 5
    ((retry++))
done

oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path}
oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'
oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path} \
--dry-run -o yaml | oc replace -f -

