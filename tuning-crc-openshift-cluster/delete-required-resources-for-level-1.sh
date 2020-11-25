#!/bin/bash
  
set -exuo pipefail

function delete_operator() {
        local delete_object=$1
        local namespace=$2
        local pod_selector=$3

        pod=$(${OC} get pod -l ${pod_selector} -o jsonpath="{.items[0].metadata.name}" -n ${namespace})

        ${OC} delete ${delete_object} -n ${namespace}
        # Wait until the operator pod is deleted before trying to delete the resources it manages
        ${OC} wait --for=delete pod/${pod} --timeout=120s -n ${namespace} || ${OC} delete pod/${pod} --grace-period=0 --force -n ${namespace} || true
}

${OC}  patch clusterversion version --type json -p "$(cat  ./tuning-crc-openshift-cluster/enable-cvo-override-level-1.yaml)"
delete_operator "deployment/cluster-monitoring-operator" "openshift-monitoring" "app=cluster-monitoring-operator"
delete_operator "deployment/prometheus-operator" "openshift-monitoring" "app.kubernetes.io/name=prometheus-operator"
delete_operator "deployment/prometheus-adapter" "openshift-monitoring" "name=prometheus-adapter"
delete_operator "statefulset/alertmanager-main" "openshift-monitoring" "app=alertmanager"
${OC} delete statefulset,deployment,daemonset,svc --all -n openshift-monitoring

${OC} delete deploy/catalog-operator -n openshift-operator-lifecycle-manager
${OC} delete deploy/olm-operator -n openshift-operator-lifecycle-manager
${OC} delete deploy/packageserver  -n openshift-operator-lifecycle-manager
${OC} delete svc --all -n openshift-operator-lifecycle-manager

${OC} delete deploy/marketplace-operator  -n openshift-marketplace
${OC} delete pods --all  -n openshift-marketplace
${OC} delete svc --all -n openshift-marketplace
