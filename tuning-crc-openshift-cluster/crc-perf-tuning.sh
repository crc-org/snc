OC=${OC:-oc}

######
##  Series of steps to inject necessary ENV variables and resources related changes for CRC ##
#####


######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
./enable-alpha-api.sh
./make-kube-control-manifests-immutable.sh
sleep 60

######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  Thes changes inject ENV variables and changes to the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
./make-kube-control-manifests-mutable.sh
./update-kube-controlplane.sh
./make-kube-control-manifests-immutable.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'
sleep 180

######
##  Now that v1alpha1/setting API is enabled, create podpresets across all the namespaces ##
#####
echo 'Create podpresets ....'
./trigger-podpresets.sh

######
##  Deploy Mutatingwebhook for specifying the appropriate resources to CRC OpenShift pods ##
##  Source code for this Webhook is located at https://github.com/spaparaju/k8s-mutate-webhook
#####
echo 'Deploy MutatingWebhook for admission controller .....'
oc apply -f admission-webhook.yaml
echo 'Wait for  MutatingWebhook to be available ....'
sleep 120

######
##  Now that Podpresets (across all the openshift- namespaces) Mutatingwebhook(cluster wide) are available, delete CRC OpenShift pods to get them recreated (by the respective operators) with the required ENV variables (from Podpresets) and required resources specified (from MutatingWebhook) ##
#####
echo 'Delete pods to inject ENV. and memroy/cpu initial requests ....'
./delete-pods.sh
echo 'Wait for pods to get recreated by the respective operators ....'
sleep 60

######
##  Remove all the resources related MutatingWebhook (MutatingWebhook, service and the deployment for the webhook) ##
#####
echo 'Removing admission webhooks ..'
./remove-admission-webhook.sh
sleep 60

######
##  Delete all the created podpresets
#####
echo 'Removing podpresets across all the namespaces ..'
./remove-podpresets.sh
sleep 60

######
##  From Kube-API server, removing support for v1alpha1/serttings API and pre-compiled webhooks 
#####
echo 'Removing support for v1alpha1/serttings APi and pre-compiled webhooks...'
./make-kube-control-manifests-mutable.sh
./remove-alpha-api.sh
./make-kube-control-manifests-immutable.sh
sleep 120

echo 'All the perfomance settings been applied. DONE'
