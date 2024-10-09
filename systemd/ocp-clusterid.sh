#!/bin/bash

set -x

export KUBECONFIG="/opt/kubeconfig"
uuid=$(uuidgen)

retry=0
max_retry=20
until `oc get clusterversion > /dev/null 2>&1`
do
    [ $retry == $max_retry ] && exit 1
    sleep 5
    ((retry++))
done

oc patch clusterversion version -p "{\"spec\":{\"clusterID\":\"${uuid}\"}}" --type merge
