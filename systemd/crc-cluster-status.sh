#!/bin/bash

set -x

export KUBECONFIG=/opt/kubeconfig

rm -rf /tmp/.crc-cluster-ready

if ! oc adm wait-for-stable-cluster --minimum-stable-period=3m --timeout=10m; then
    exit 1
fi

# need to set a marker to let `crc` know the cluster is ready
touch /tmp/.crc-cluster-ready

