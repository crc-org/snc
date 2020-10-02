#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-apiserver-pod.yaml
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-controller-manager-pod.yaml
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/kube-scheduler-pod.yaml
${SSH_CMD} sudo chattr +i  /etc/kubernetes/manifests/etcd-pod.yaml
