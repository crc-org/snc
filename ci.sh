#!/bin/bash

# Force yq download
export YQ=./yq

./snc.sh
if [[ $? -ne 0 ]]; then
  exit 1
fi
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
# Run createdisk script
export SNC_VALIDATE_CERT=false
./createdisk.sh crc-tmp-install-data

# Destroy the cluster
./openshift-install destroy cluster --dir crc-tmp-install-data
