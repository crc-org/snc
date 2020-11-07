#!/bin/bash

set -exuo pipefail

######
##  Series of steps to inject necessary ENV variables and resources related changes for CRC ##
#####

######
##  Apply required RHCOS Kernel parameters
#####
#echo 'Apply required Kernel paramters to the CRC VM..'
#tuning-crc-openshift-cluster/apply-kernel-parameters.sh

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Make the API server manifest file immutable
${OC} patch clusterversion version --type json -p "$(cat tuning-crc-openshift-cluster/unmanage_kubeapi.yaml)"


echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
tuning-crc-openshift-cluster/enable-alpha-api.sh

sleep $SLEEP_TIME
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
${OC} login --token  $OC_LOGIN_TOKEN --server=$API_SERVER
### Debug -- Make sure Podpresets are enabled by the API server
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'

######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  Thes changes inject ENV variables and changes to the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
tuning-crc-openshift-cluster/make-kube-control-manifests-mutable.sh
tuning-crc-openshift-cluster/update-kube-controlplane.sh
tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'

sleep $SLEEP_TIME
sleep $SLEEP_TIME

OC_LOGIN_TOKEN=` ${OC} whoami --show-token`

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure Podpresets are enabled by the API server
${OC} login --token  $OC_LOGIN_TOKEN --server=$API_SERVER
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Now that v1alpha1/setting API is enabled, create podpresets across all the namespaces ##
#####
echo 'Create podpresets ....'
tuning-crc-openshift-cluster/trigger-podpresets.sh

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Deploy Mutatingwebhook for specifying the appropriate resources to CRC OpenShift pods ##
##  Source code for this Webhook is located at https://github.com/spaparaju/k8s-mutate-webhook
#####

echo 'Deploy MutatingWebhook for admission controller .....'
${OC} apply -f https://raw.githubusercontent.com/spaparaju/k8s-mutate-webhook/master/deploy/webhook.yaml
echo 'Wait for  MutatingWebhook to be available ....'

sleep $SLEEP_TIME
sleep $SLEEP_TIME

OC_LOGIN_TOKEN=` ${OC} whoami --show-token`
${OC} login --token  $OC_LOGIN_TOKEN --server=$API_SERVER
${OC} get pods
${OC} get svc 
${OC} get MutatingWebhookConfiguration

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Now that Podpresets (across all the openshift- namespaces) Mutatingwebhook(cluster wide) are available, delete CRC OpenShift pods to get them recreated (by the respective operators) with the required ENV variables (from Podpresets) and required resources specified (from MutatingWebhook) ##
#####
echo 'Delete pods to inject ENV. and memroy/cpu initial requests ....'
tuning-crc-openshift-cluster/delete-pods.sh
echo 'Wait for pods to get recreated by the respective operators ....'

sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
OC_LOGIN_TOKEN=` ${OC} whoami --show-token`
${OC} login --token  $OC_LOGIN_TOKEN --server=$API_SERVER
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Remove all the resources related MutatingWebhook (MutatingWebhook, service and the deployment for the webhook) ##
#####
echo 'Removing admission webhooks ..'
tuning-crc-openshift-cluster/remove-admission-webhook.sh
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
OC_LOGIN_TOKEN=` ${OC} whoami --show-token`
${OC} login --token  $OC_LOGIN_TOKEN --server=$SERVER
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Delete all the created podpresets
#####
echo 'Removing podpresets across all the namespaces ..'
tuning-crc-openshift-cluster/remove-podpresets.sh
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
OC_LOGIN_TOKEN=` ${OC} whoami --show-token`
${OC} api-resources  --api-group=settings.k8s.io 
echo '-----------------------------------------------------------------------------------------------------------------------------------'

######
##  From Kube-API server, removing support for v1alpha1/serttings API and pre-compiled webhooks
#####
echo 'Removing support for v1alpha1/serttings API and pre-compiled webhooks...'
tuning-crc-openshift-cluster/remove-alpha-api.sh
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
${OC} login --token  $OC_LOGIN_TOKEN --server=$SERVER
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
###
# Create swap space
###
tuning-crc-openshift-cluster/enable-swap-space.sh
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
${OC} patch clusterversion version --type json -p "$(cat tuning-crc-openshift-cluster/manage_kubeapi.yaml)"
echo '-----------------------------------------------------------------------------------------------------------------------------------'
echo 'All the perfomance settings been applied. DONE'
