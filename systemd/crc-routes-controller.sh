#!/bin/bash

set -x

export KUBECONFIG=/opt/kubeconfig

retry=0
max_retry=20
until `oc get pods > /dev/null 2>&1`
do
    [ $retry == $max_retry ] && exit 1
    sleep 5
    ((retry++))
done

oc apply -f /opt/crc/routes-controller.yaml

