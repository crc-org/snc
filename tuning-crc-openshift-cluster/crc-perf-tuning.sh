#!/bin/bash

set -exuo pipefail

wait_for_api_server()
{
	count=1
	while ! ${OC} api-resources  >/dev/null 2>&1; do
 		if [ $count -lt 100 ]
		then
			sleep 3
  			count=`expr $count + 1`
		else
			exit
		fi
	done
}


######
##  Series of steps to inject necessary ENV variables and resources related changes for CRC ##
#####

######
##  Apply required RHCOS Kernel parameters
#####
#echo 'Apply required Kernel paramters to the CRC VM..'
#tuning-crc-openshift-cluster/apply-kernel-parameters.sh

### Create the disk image as per the level (1,2,3) indicated

if [ $PERF_TUNE_DISK_LEVEL -eq 1 ]
then
	source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-1.sh 
elif [ $PERF_TUNE_DISK_LEVEL -eq 2 ]
then
	source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-2.sh
else
	source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-3.sh	
fi


echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
source ./tuning-crc-openshift-cluster/enable-alpha-api.sh

sleep $SLEEP_TIME
wait_for_api_server


echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Now that v1alpha1/setting API is enabled, create podpresets across all the namespaces ##
#####
echo 'Create podpresets ....'
source ./tuning-crc-openshift-cluster/trigger-podpresets.sh

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
while ! ${OC} get MutatingWebhookConfiguration >/dev/null 2>&1; do
  sleep 6
done

${OC} get pods
${OC} get svc 
${OC} get MutatingWebhookConfiguration

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Now that Podpresets (across all the openshift- namespaces) Mutatingwebhook(cluster wide) are available, delete CRC OpenShift pods to get them recreated (by the respective operators) with the required ENV variables (from Podpresets) and required resources specified (from MutatingWebhook) ##
#####
echo 'Delete pods to inject ENV. and memroy/cpu initial requests ....'
source ./tuning-crc-openshift-cluster/delete-pods.sh
echo 'Wait for pods to get recreated by the respective operators ....'

sleep $SLEEP_TIME
sleep $SLEEP_TIME

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
### Debug -- Make sure Podpresets are enabled by the API server
${OC} api-resources  --api-group=settings.k8s.io 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Remove all the resources related MutatingWebhook (MutatingWebhook, service and the deployment for the webhook) ##
#####
echo 'Removing admission webhooks ..'
source ./tuning-crc-openshift-cluster/remove-admission-webhook.sh
sleep $SLEEP_TIME
wait_for_api_server

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
${OC} api-resources 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  Delete all the created podpresets
#####
echo 'Removing podpresets across all the namespaces ..'
source ./tuning-crc-openshift-cluster/remove-podpresets.sh

echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
${OC} api-resources 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
######
##  From Kube-API server, removing support for v1alpha1/serttings API and pre-compiled webhooks
#####
echo 'Removing support for v1alpha1/settings API and pre-compiled webhooks...'
source ./tuning-crc-openshift-cluster/remove-alpha-api.sh
sleep $SLEEP_TIME
wait_for_api_server


echo '-----------------------------------------------------------------------------------------------------------------------------------'
### Debug -- Make sure API server is up and running
${OC} api-resources 

echo '-----------------------------------------------------------------------------------------------------------------------------------'
###
# Create swap space
###
#tuning-crc-openshift-cluster/enable-swap-space.sh
${SCP} -r ./tuning-crc-openshift-cluster/enable-swap-space.sh ${SSH_HOST}:/home/core/enable-swap-space.sh

######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  Thes changes inject ENV variables and changes to the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
source ./tuning-crc-openshift-cluster/make-kube-control-manifests-mutable.sh
source ./tuning-crc-openshift-cluster/update-kube-controlplane.sh
source ./tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'

sleep $SLEEP_TIME
wait_for_api_server

## Remove ValidatingWebhooks 
${OC} delete ValidatingWebhookConfiguration --all 

${OC} delete pods --all -n openshift-etcd
sleep $SLEEP_TIME
wait_for_api_server

${OC} delete pods --all -n openshift-kube-apiserver
sleep $SLEEP_TIME
wait_for_api_server

${OC} delete pods --all -n openshift-kube-controller-manager
sleep $SLEEP_TIME
wait_for_api_server

## Reduce replicas under openshift-console namespace
source ./tuning-crc-openshift-cluster/reduce-replicas-for-console.sh 
