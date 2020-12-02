#!/bin/bash
  
oc  --kubeconfig  /opt/kubeconfig  patch clusterversion version --type json -p "$(cat   /var/home/core/perf-cvo-override-remove-both-olm-cluster-monitoring.yaml)"

oc  --kubeconfig /opt/kubeconfig delete ns openshift-operator-lifecycle-manager &> /dev/null  &
oc  --kubeconfig /opt/kubeconfig delete ns openshift-marketplace  &> /dev/null &
oc  --kubeconfig /opt/kubeconfig delete ns openshift-monitoring  &> /dev/null &
exit 0
