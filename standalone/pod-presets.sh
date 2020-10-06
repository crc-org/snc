#!/bin/bash

set -exuo pipefail

top_dir=$(dirname $0)/..
echo "top dir: $top_dir"
source "$top_dir/tuning-crc-openshift-cluster/crc-env.sh"

######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
"$top_dir"/tuning-crc-openshift-cluster/enable-alpha-api.sh
sleep 60

######
##  Now that v1alpha1/setting API is enabled, create podpresets across all the namespaces ##
#####
echo 'Create podpresets ....'
"$top_dir"/tuning-crc-openshift-cluster/trigger-podpresets.sh

######
##  Now that Podpresets (across all the openshift- namespaces), delete CRC OpenShift pods to get them recreated (by the respective operators) with the required ENV variables (from Podpresets) ##
#####
echo 'Delete pods to inject ENV. ....'
"$top_dir"/tuning-crc-openshift-cluster/delete-pods.sh
echo 'Wait for pods to get recreated by the respective operators ....'
sleep 60

######
##  Delete all the created podpresets
#####
echo 'Removing podpresets across all the namespaces ..'
"$top_dir"/tuning-crc-openshift-cluster/remove-podpresets.sh
sleep 60

######
##  From Kube-API server, removing support for v1alpha1/serttings API and pre-compiled webhooks
#####
echo 'Removing support for v1alpha1/serttings APi and pre-compiled webhooks...'
"$top_dir"/tuning-crc-openshift-cluster/remove-alpha-api.sh
sleep 120
