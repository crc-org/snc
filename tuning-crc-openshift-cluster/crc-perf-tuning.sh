OC=${OC:-oc}

######
##  Series of steps to inject necessary ENV variables and resources related changes for CRC ##
#####


######
##  Enable v1alpha1/settings API for using Podpresets to set ENV variables while pods get created ##
#####
echo 'Enable Kube V1/alpha API .....'
tuning-crc-openshift-cluster/enable-alpha-api.sh
tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
sleep 60

######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  Thes changes inject ENV variables and changes to the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
tuning-crc-openshift-cluster/make-kube-control-manifests-mutable.sh
tuning-crc-openshift-cluster/update-kube-controlplane.sh
tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'
sleep 180

######
##  From Kube-API server, removing support for v1alpha1/serttings API and pre-compiled webhooks
#####
echo 'Removing support for v1alpha1/serttings APi and pre-compiled webhooks...'
tuning-crc-openshift-cluster/make-kube-control-manifests-mutable.sh
tuning-crc-openshift-cluster/remove-alpha-api.sh
tuning-crc-openshift-cluster/make-kube-control-manifests-immutable.sh
sleep 120

######
##  Apply required RHCOS Kernel parameters
#####
echo 'Apply required Kernel paramters to the CRC VM..'
tuning-crc-openshift-cluster/apply-kernel-parameters.sh

echo 'All the perfomance settings been applied. DONE'
