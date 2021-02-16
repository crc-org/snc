#!/bin/bash

set -exuo pipefail
./shellcheck.sh
./snc.sh
set +exuo pipefail

# wait till the cluster is stable
sleep 5m
export KUBECONFIG=crc-tmp-install-data/auth/kubeconfig
# Remove all the failed Pods
oc delete pods --field-selector=status.phase=Failed -A
# Wait till all the pods are either running or pending or completed or in terminating state
while oc get pod --no-headers --all-namespaces | grep -v Running | grep -v Completed | grep -v Terminating | grep -v Pending; do
   sleep 2
done
# Check the cluster operator output, status for available should be true for all operators
while oc get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}' | grep -v True; do
   sleep 2
done

set -exuo pipefail
# Run createdisk script
export CRC_ZSTD_EXTRA_FLAGS="-10 --long"
./createdisk.sh crc-tmp-install-data
set +exuo pipefail

# Destroy the cluster
./openshift-baremetal-install destroy cluster --dir crc-tmp-install-data
