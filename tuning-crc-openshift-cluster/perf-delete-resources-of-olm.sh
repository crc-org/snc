#!/bin/bash
  
oc  --kubeconfig   /opt/kubeconfig  patch clusterversion version --type json -p "$(cat  ./perf-cvo-override-remove-olm.yaml)"

nohup oc  --kubeconfig /opt/kubeconfig delete ns openshift-operator-lifecycle-manager &
nohup oc  --kubeconfig /opt/kubeconfig delete ns openshift-marketplace &
