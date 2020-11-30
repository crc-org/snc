#!/bin/bash
  
oc  --kubeconfig   patch clusterversion version --type json -p "$(cat  ./perf-cvo-override-remove-cluster-monitoring.yaml)"
nohup oc  --kubeconfig /opt/kubeconfig delete ns openshift-monitoring &
