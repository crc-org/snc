OC=${OC:-oc}

######
##  Series of steps to inject necessary ENV variables and resources related changes for CRC ##
#####


######
##  Update manifest files for the Kube. control plane (static pods created by Kubelet). ##
##  Thes changes inject ENV variables and changes to the resources related to CRC OpenShift components ##
#####
echo 'Update Kube control plane manifest files ......'
tuning-crc-openshift-cluster/update-kube-controlplane.sh
echo 'Wait for Kube API to be available after the restart (triggered from updating the manifest files) .....'
sleep 180

######
##  Apply required RHCOS Kernel parameters
#####
echo 'Apply required Kernel paramters to the CRC VM..'
tuning-crc-openshift-cluster/apply-kernel-parameters.sh

echo 'All the perfomance settings been applied. DONE'
