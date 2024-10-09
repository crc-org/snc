#!/bin/bash

set -x

if [ -z $CRC_CLOUD ]; then
    echo "Not running in crc-cloud mode"
    exit 0
fi

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"
export EIP=$(hostname -i)

STEPS_SLEEP_TIME=30

wait_for_resource secret

# create cert and add as secret
openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout nip.key -out nip.crt -subj "/CN=$EIP.nip.io" -addext "subjectAltName=DNS:apps.$EIP.nip.io,DNS:*.apps.$EIP.nip.io,DNS:api.$EIP.nip.io"
oc create secret tls nip-secret --cert=nip.crt --key=nip.key -n openshift-config
sleep $STEPS_SLEEP_TIME

# patch ingress
    cat <<EOF > ingress-patch.yaml
spec:
  appsDomain: apps.$EIP.nip.io
  componentRoutes:
  - hostname: console-openshift-console.apps.$EIP.nip.io
    name: console
    namespace: openshift-console
    servingCertKeyPairSecret:
      name: nip-secret
  - hostname: oauth-openshift.apps.$EIP.nip.io
    name: oauth-openshift
    namespace: openshift-authentication
    servingCertKeyPairSecret:
      name: nip-secret
EOF
oc patch ingresses.config.openshift.io cluster --type=merge --patch-file=ingress-patch.yaml

# patch API server to use new CA secret
oc patch apiserver cluster --type=merge -p '{"spec":{"servingCerts": {"namedCertificates":[{"names":["api.'$EIP'.nip.io"],"servingCertificate": {"name": "nip-secret"}}]}}}'

# patch image registry route
oc patch -p '{"spec": {"host": "default-route-openshift-image-registry.'$EIP'.nip.io"}}' route default-route -n openshift-image-registry --type=merge

#wait_cluster_become_healthy "authentication|console|etcd|ingress|openshift-apiserver"
