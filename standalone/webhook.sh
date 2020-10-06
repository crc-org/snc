#!/bin/bash

set -exuo pipefail

top_dir="$(dirname $0)/.."
echo "top dir: $top_dir"
source "$top_dir/tuning-crc-openshift-cluster/crc-env.sh"

######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
"$top_dir"/tuning-crc-openshift-cluster/enable-alpha-api.sh
sleep 60

######
##  Deploy Mutatingwebhook for specifying the appropriate resources to CRC OpenShift pods ##
##  Source code for this Webhook is located at https://github.com/spaparaju/k8s-mutate-webhook
#####
echo 'Deploy MutatingWebhook for admission controller .....'
${OC} apply -f https://raw.githubusercontent.com/spaparaju/k8s-mutate-webhook/master/deploy/webhook.yaml
echo 'Wait for  MutatingWebhook to be available ....'
sleep 120

######
##  Now that Mutatingwebhook(cluster wide) are available, delete CRC OpenShift pods to get them recreated (by the respective operators) with the required resources specified (from MutatingWebhook) ##
#####
echo 'Delete pods to inject memory/cpu initial requests ....'
"$top_dir"/tuning-crc-openshift-cluster/delete-pods.sh
echo 'Wait for pods to get recreated by the respective operators ....'
sleep 60

######
##  Remove all the resources related MutatingWebhook (MutatingWebhook, service and the deployment for the webhook) ##
#####
echo 'Removing admission webhooks ..'
"$top_dir"/tuning-crc-openshift-cluster/remove-admission-webhook.sh
sleep 60

######
##  From Kube-API server, removing support for v1alpha1/settings API and pre-compiled webhooks
#####
echo 'Removing support for v1alpha1/settings API and pre-compiled webhooks...'
"$top_dir"/tuning-crc-openshift-cluster/remove-alpha-api.sh
sleep 120
