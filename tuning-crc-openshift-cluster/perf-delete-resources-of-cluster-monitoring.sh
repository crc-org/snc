#!/bin/bash
  
oc  --kubeconfig   /opt/kubeconfig  patch clusterversion version --type json -p "$(cat   /var/home/core/perf-cvo-override-remove-cluster-monitoring.yaml)"
oc  --kubeconfig /opt/kubeconfig delete ns openshift-monitoring  &> /dev/null &
exit 0
