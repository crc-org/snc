#!/bin/bash

set -exuo pipefail

wait_for_api_server()
{
        count=1
        while ! ${OC} get etcds cluster >/dev/null 2>&1; do
                if [ $count -lt 40 ]
                then
                        sleep 3
                        count=`expr $count + 1`
                else
                        exit
                fi
        done
}

delete_pods_for_a_namespace() {
 	${OC} delete pods -n  $1 --all
	sleep 60
	wait_for_api_server
}

#delete_pods_for_a_namespace openshift-authentication  
#delete_pods_for_a_namespace openshift-authentication-operator 
delete_pods_for_a_namespace openshift-cluster-machine-approver 
delete_pods_for_a_namespace openshift-cluster-node-tuning-operator 
delete_pods_for_a_namespace openshift-cluster-samples-operator 
delete_pods_for_a_namespace openshift-config-operator  
delete_pods_for_a_namespace openshift-console 
delete_pods_for_a_namespace openshift-console-operator  
#delete_pods_for_a_namespace openshift-controller-manager  
delete_pods_for_a_namespace openshift-controller-manager-operator  
delete_pods_for_a_namespace openshift-dns
delete_pods_for_a_namespace openshift-dns-operator  
delete_pods_for_a_namespace openshift-image-registry   
delete_pods_for_a_namespace openshift-kube-storage-version-migrator 
delete_pods_for_a_namespace openshift-marketplace  
delete_pods_for_a_namespace openshift-multus  
delete_pods_for_a_namespace openshift-network-operator   
delete_pods_for_a_namespace openshift-operator-lifecycle-manager   
delete_pods_for_a_namespace openshift-sdn   
delete_pods_for_a_namespace openshift-service-ca   
delete_pods_for_a_namespace openshift-service-ca-operator    
delete_pods_for_a_namespace openshift-apiserver  
delete_pods_for_a_namespace openshift-apiserver-operator 
delete_pods_for_a_namespace openshift-ingress 
delete_pods_for_a_namespace openshift-ingress-operator 
