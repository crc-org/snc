#!/bin/bash

set -x

export KUBECONFIG=/opt/kubeconfig

function check_cluster_healthy() {
    WAIT="authentication|console|etcd|ingress|openshift-apiserver"

    until `oc get co > /dev/null 2>&1`
    do
        sleep 2
    done

    for i in $(oc get co | grep -P "$WAIT" | awk '{ print $3 }')
    do
        if [[ $i == "False" ]]
        then
            return 1
        fi
    done
    return 0
}

rm -rf /tmp/.crc-cluster-ready

COUNTER=0
CLUSTER_HEALTH_SLEEP=8
CLUSTER_HEALTH_RETRIES=500

while ! check_cluster_healthy
do
    sleep $CLUSTER_HEALTH_SLEEP
    if [[ $COUNTER == $CLUSTER_HEALTH_RETRIES ]]
    then
        return 1
    fi
    ((COUNTER++))
done

# need to set a marker to let `crc` know the cluster is ready
touch /tmp/.crc-cluster-ready

