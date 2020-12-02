#!/bin/bash
  
set -exuo pipefail



${OC}  patch clusterversion version --type json -p "$(cat  ./tuning-crc-openshift-cluster/enable-cvo-override-level-3.yaml)"

${OC} delete deployment/cluster-monitoring-operator -n openshift-monitoring
sleep 30
${OC} delete deployment/prometheus-operator -n openshift-monitoring
sleep 30

 ${OC} scale --replicas=1 deployment prometheus-adapter -n openshift-monitoring
 ${OC} scale --replicas=1 statefulset alertmanager-main -n openshift-monitoring
 ${OC} scale --replicas=1 statefulset prometheus-k8s -n openshift-monitoring
 ${OC} scale --replicas=1 deployment thanos-querier -n openshift-monitoring

