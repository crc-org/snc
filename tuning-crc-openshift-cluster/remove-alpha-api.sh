#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo cat /etc/kubernetes/manifests/kube-apiserver-pod.yaml  > current_kubeapiserver_manifest.json
current_args=`cat current_kubeapiserver_manifest.json | jq -r '.spec.containers[]  | select(.name == "kube-apiserver") | .args[0]'`
new_args=$(echo "$current_args" | sed "s/--runtime-config=settings.k8s.io\/v1alpha1=true/ /")
yes_args=$(echo "$new_args" | sed "s/--enable-admission-plugins=MutatingAdmissionWebhook,PodPreset/ /")
${JQ}  --arg yes_args "$yes_args" '(.spec.containers[] | select(.name == "kube-apiserver") | .args[0]) |= $yes_args' current_kubeapiserver_manifest.json > updated_kubeapiserver_manifest.json
cat updated_kubeapiserver_manifest.json | ${JQ} -c '.' > unformatted_updated_kubeapiserver_manifest.json
${SCP} -r unformatted_updated_kubeapiserver_manifest.json  ${SSH_HOST}:/home/core/enable-alphaapi-kube-apiserver-pod.yaml
${SSH_CMD} sudo cp /home/core/enable-alphaapi-kube-apiserver-pod.yaml /etc/kubernetes/manifests/kube-apiserver-pod.yaml

# cleanup temp. files created ##
rm current_kubeapiserver_manifest.json updated_kubeapiserver_manifest.json unformatted_updated_kubeapiserver_manifest.json
