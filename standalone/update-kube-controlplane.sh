#!/bin/bash

set -exuo pipefail

top_dir="$(dirname $0)/.."
echo "top dir: $top_dir"
source "$top_dir/tuning-crc-openshift-cluster/crc-env.sh"

######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  These changes inject ENV variables and changes the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
"$top_dir"/tuning-crc-openshift-cluster/make-kube-control-manifests-mutable.sh
"$top_dir"/tuning-crc-openshift-cluster/update-kube-controlplane.sh
"$top_dir"/tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'
sleep 180
