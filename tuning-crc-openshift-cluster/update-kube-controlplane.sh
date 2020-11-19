#!/bin/bash

set -exuo pipefail

 update_kube_apiserver_manifests() {
    ${SSH_CMD} sudo cat $1  > current_manifest.json
    new_memory_value=$2
    new_cpu_value=$3
    ${JQ}  --arg new_memory_value "$new_memory_value" '(.spec.containers[].resources.requests.memory) |= $new_memory_value' current_manifest.json > updated_wth_memory_manifest.json
    ${JQ}  --arg new_cpu_value "$new_cpu_value" '(.spec.containers[].resources.requests.cpu) |= $new_cpu_value' updated_wth_memory_manifest.json > updated_wth_cpu_manifest.json
    ${JQ} '.spec.containers[].env |= . + [{"name": "GOGC", "value": "10"}, {"name": "GODEBUG", "value": "madvdontneed=1"}] ' updated_wth_cpu_manifest.json > updated_with_env_manifest.json
    new_kubeapi_cpu_value=$4
    ${JQ}  --arg new_kubeapi_cpu_value "$new_kubeapi_cpu_value" '(.spec.containers[] | select(.name == "kube-apiserver") | .resources.requests.cpu) |= $new_kubeapi_cpu_value' updated_with_env_manifest.json > final_manifest.json 
 #   ${JQ}  --arg new_kubeapi_cpu_value "$new_kubeapi_cpu_value" '(.spec.containers[] | select(.name == "kube-apiserver") | .resources.requests.cpu) |= $new_kubeapi_cpu_value' updated_with_env_manifest.json > updated_with_cpu_requests_manifest.json 
 #   kubeapi_limit_cpu_value=$5
 #   ${JQ}  --arg kubeapi_limit_cpu_value "$kubeapi_limit_cpu_value" '(.spec.containers[] | select(.name == "kube-apiserver") | .resources.limits.cpu) |= $kubeapi_limit_cpu_value' updated_with_cpu_requests_manifest.json  > final_manifest.json
    cat final_manifest.json | ${JQ} -c '.' > unformatted_final_manifest.json

    ${SCP} -r unformatted_final_manifest.json ${SSH_HOST}:/home/core/updated-kube-apiserver-manifest.yaml
    ${SSH_CMD} sudo cp /home/core/updated-kube-apiserver-manifest.yaml $1
    ## Remove temp. files created
    rm current_manifest.json updated_wth_memory_manifest.json updated_wth_cpu_manifest.json updated_with_env_manifest.json  final_manifest.json unformatted_final_manifest.json
}

 update_kube_controller_manifests() {
    ${SSH_CMD} sudo cat $1  > current_manifest.json
    new_memory_value=$2
    new_cpu_value=$3
    ${JQ}  --arg new_memory_value "$new_memory_value" '(.spec.containers[].resources.requests.memory) |= $new_memory_value' current_manifest.json > updated_wth_memory_manifest.json
    ${JQ}  --arg new_cpu_value "$new_cpu_value" '(.spec.containers[].resources.requests.cpu) |= $new_cpu_value' updated_wth_memory_manifest.json > updated_wth_cpu_manifest.json
    ${JQ} '.spec.containers[].env |= . + [{"name": "GOGC", "value": "10"}, {"name": "GODEBUG", "value": "madvdontneed=1"}] ' updated_wth_cpu_manifest.json > updated_with_env_manifest.json
    new_kube_controller_cpu_value=$4
    ${JQ}  --arg new_kube_controller_cpu_value "$new_kube_controller_cpu_value" '(.spec.containers[] | select(.name == "kube-controller-manager") | .resources.requests.cpu) |= $new_kube_controller_cpu_value' updated_with_env_manifest.json  > final_manifest.json
   # kube_controller_limit_cpu_value=$5
   # ${JQ}  --arg kube_controller_limit_cpu_value "$kube_controller_limit_cpu_value" '(.spec.containers[] | select(.name == "kube-controller-manager") | .resources.limits.cpu) |= $kube_controller_limit_cpu_value' updated_with_cpu_requests_manifest.json  > final_manifest.json
    cat final_manifest.json | ${JQ} -c '.' > unformatted_final_manifest.json

    ${SCP} -r unformatted_final_manifest.json ${SSH_HOST}:/home/core/updated-kube-control-manager-manifest.yaml
    ${SSH_CMD} sudo cp /home/core/updated-kube-control-manager-manifest.yaml $1
    ## Remove temp. files created
    rm current_manifest.json updated_wth_memory_manifest.json updated_wth_cpu_manifest.json updated_with_env_manifest.json final_manifest.json unformatted_final_manifest.json
}

 update_kube_scheduler_manifests() {
    ${SSH_CMD} sudo cat $1  > current_manifest.json
    new_memory_value=$2
    new_cpu_value=$3
    ${JQ}  --arg new_memory_value "$new_memory_value" '(.spec.containers[].resources.requests.memory) |= $new_memory_value' current_manifest.json > updated_wth_memory_manifest.json
    ${JQ}  --arg new_cpu_value "$new_cpu_value" '(.spec.containers[].resources.requests.cpu) |= $new_cpu_value' updated_wth_memory_manifest.json > updated_wth_cpu_manifest.json
    ${JQ} '.spec.containers[].env |= . + [{"name": "GOGC", "value": "10"}, {"name": "GODEBUG", "value": "madvdontneed=1"}] ' updated_wth_cpu_manifest.json  > final_manifest.json
    cat final_manifest.json | ${JQ} -c '.' > unformatted_final_manifest.json

    ${SCP} -r unformatted_final_manifest.json ${SSH_HOST}:/home/core/updated-kube-scheduler-manifest.yaml
    ${SSH_CMD} sudo cp /home/core/updated-kube-scheduler-manifest.yaml $1
    ## Remove temp. files created
    rm current_manifest.json updated_wth_memory_manifest.json updated_wth_cpu_manifest.json  final_manifest.json unformatted_final_manifest.json
}

 update_etcd_manifests() {
    ${SSH_CMD} sudo cat $1  > current_manifest.yaml
    new_memory_value=$2
    new_cpu_value=$3
    ${YQ} r -j current_manifest.yaml | ${JQ}  --arg new_memory_value "$new_memory_value" '(.spec.containers[].resources.requests.memory) |= $new_memory_value' -  | ${YQ} r  - > updated_memory_manifest.yaml
    ${YQ} r -j updated_memory_manifest.yaml | ${JQ}  --arg new_cpu_value "$new_cpu_value" '(.spec.containers[].resources.requests.cpu) |= $new_cpu_value' -  | ${YQ} r  - > updated_cpu_manifest.yaml
    ${YQ} r -j updated_cpu_manifest.yaml | ${JQ}  --arg new_memory_value "$new_memory_value" '(.spec.initContainers[].resources.requests.memory) |= $new_memory_value' -  | ${YQ} r  - > updated_init_containers_memory_manifest.yaml
    ${YQ} r -j updated_init_containers_memory_manifest.yaml | ${JQ}  --arg new_cpu_value "$new_cpu_value" '(.spec.initContainers[].resources.requests.cpu) |= $new_cpu_value' -  | ${YQ} r  - > updated_init_containers_cpu_manifest.yaml
    ${YQ} r -j updated_init_containers_cpu_manifest.yaml | ${JQ} '.spec.containers[].env |= . + [{"name": "GOGC", "value": "10"}, {"name": "GODEBUG", "value": "madvdontneed=1"}] ' -  | ${YQ} r  - > updated_with_env_manifest.yaml
    ${YQ} r -j updated_with_env_manifest.yaml | ${JQ} '.spec.initContainers[].env |= . + [{"name": "GOGC", "value": "10"}, {"name": "GODEBUG", "value": "madvdontneed=1"}] ' -  | ${YQ} r  - > updated_init_containers_with_env_manifest.yaml
    new_etcd_cpu_value=$4
    ${YQ} r -j updated_init_containers_with_env_manifest.yaml | ${JQ}  --arg new_etcd_cpu_value "$new_etcd_cpu_value" '(.spec.containers[] | select(.name == "etcd") | .resources.requests.cpu) |= $new_etcd_cpu_value' -  > updated_final_manifest.yaml
#    etcd_cpu_limit_value=$5
 #   ${YQ} r -j updated_with_new_cpu_request_manifest.yaml | ${JQ}  --arg etcd_cpu_limit_value "$etcd_cpu_limit_value" '(.spec.containers[] | select(.name == "etcd") | .resources.limits.cpu) |= $etcd_cpu_limit_value' -  > updated_final_manifest.yaml

    ${SCP} -r updated_final_manifest.yaml ${SSH_HOST}:/home/core/updated-etcd-final-manifest.yaml
    ${SSH_CMD} sudo cp /home/core/updated-etcd-final-manifest.yaml $1
    ## Remove temp. files created
#    rm  current_manifest.yaml updated_memory_manifest.yaml updated_cpu_manifest.yaml updated_init_containers_memory_manifest.yaml updated_with_env_manifest.yaml updated_init_containers_with_env_manifest.yaml updated_init_containers_cpu_manifest.yaml updated_final_manifest.yaml
}

update_kubelet_systemd_service() {
    ${SSH_CMD} sudo cat $1  > current_kubelet.conf
    ${YQ} w  current_kubelet.conf systemReserved.cpu $3  > updated_cpu_kubelet.conf
    ${YQ} w  updated_cpu_kubelet.conf systemReserved.memory $2  > updated_memory_kubelet.conf
    ${YQ} w  updated_memory_kubelet.conf containerLogMaxSize $4  > updated_container_max_log_kubelet.conf
    ${YQ} w  updated_container_max_log_kubelet.conf failSwapOn $5  > updated_swapon_kubelet.conf
    ${YQ} w  updated_swapon_kubelet.conf kubeAPIQPS $6  > updated_kube_api_qps_kubelet.conf
    ${YQ} w  updated_kube_api_qps_kubelet.conf kubeAPIBurst $7  > updated_api_burst_kubelet.conf
    ${YQ} w  updated_api_burst_kubelet.conf rotateCertificates $8  > updated_final_kubelet.conf

    ${SCP} -r updated_final_kubelet.conf ${SSH_HOST}:/home/core/updated-kubelet.conf
    ${SSH_CMD} sudo cp /home/core/updated-kubelet.conf $1
    ## clean up temp. files created
    rm current_kubelet.conf updated_cpu_kubelet.conf updated_memory_kubelet.conf updated_final_kubelet.conf
}


echo '------------- Applying changes to Kubelet -----------'
update_kubelet_systemd_service /etc/kubernetes/kubelet.conf 150Mi 200m 2Mi false 800 250 false

echo '------------- Applying changes to Kube API server  -----------'
update_kube_apiserver_manifests   /etc/kubernetes/manifests/kube-apiserver-pod.yaml 10Mi 30m 600m 
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-apiserver-pod.yaml
sleep $SLEEP_TIME

echo '------------- Applying changes to Kube Scheduler  -----------'
update_kube_scheduler_manifests  /etc/kubernetes/manifests/kube-scheduler-pod.yaml 10Mi 15m
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-scheduler-pod.yaml
sleep $SLEEP_TIME

echo '------------- Applying changes to Kube Control manager  -----------'
update_kube_controller_manifests /etc/kubernetes/manifests/kube-controller-manager-pod.yaml 10Mi 10m 100m 
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-controller-manager-pod.yaml
sleep $SLEEP_TIME

echo '------------- Applying changes to Etcd -----------'
update_etcd_manifests   /etc/kubernetes/manifests/etcd-pod.yaml 10Mi 10m 300m
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/etcd-pod.yaml
sleep $SLEEP_TIME

