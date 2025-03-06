#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

wait_for_resource configmap

custom_ca_path=/opt/crc/custom-ca.crt

oc create configmap client-ca-custom -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path}
oc patch apiserver cluster --type=merge -p '{"spec": {"clientCA": {"name": "client-ca-custom"}}}'
oc create configmap admin-kubeconfig-client-ca -n openshift-config --from-file=ca-bundle.crt=${custom_ca_path} \
--dry-run -o yaml | oc replace -f -

rm -f /opt/crc/custom-ca.crt
