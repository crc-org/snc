#!/bin/sh

INSTALL_DIR=test
INSTALLER_RELEASE=v0.14.0

# Download the oc binary if not present in current directory
if [[ ! -e oc ]]; then
    curl -L https://mirror.openshift.com/pub/openshift-v3/clients/4.0.22/linux/oc.tar.gz -o oc.tar.gz
    tar -xvf oc.tar.gz
    rm -fr oc.tar.gz
fi

# Download yq for manipulating in place yaml configs
if [[ ! -e yq ]]; then
    curl -L https://github.com/mikefarah/yq/releases/download/2.2.1/yq_linux_amd64 -o yq
    chmod +x yq
fi 

# Destroy an existing cluster and resources
./openshift-install --dir $INSTALL_DIR destroy cluster --log-level debug

if [ "${OPENSHIFT_PULL_SECRET}" = "" ]; then
    echo "OpenShift pull secret must be specified through the OPENSHIFT_PULL_SECRET environment variable"
    exit 1
fi

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr $INSTALL_DIR && mkdir $INSTALL_DIR && cp install-config.yaml $INSTALL_DIR
./yq write --inplace $INSTALL_DIR/install-config.yaml compute[0].replicas 0
./yq write --inplace $INSTALL_DIR/install-config.yaml pullSecret ${OPENSHIFT_PULL_SECRET}

# Create the manifests using the INSTALL_DIR
./openshift-install --dir $INSTALL_DIR create manifests

# Copy the config which removes taint from master
cp 99_master-kubelet-no-taint.yaml $INSTALL_DIR/openshift/

# Add worker label to master machine config
./yq write --inplace $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.metadata.labels[node-role.kubernetes.io/worker] ""

# Add custom domain to cluster-ingress
./yq write --inplace test/manifests/cluster-ingress-02-config.yml spec[domain] apps.tt.testing

# Start the cluster with 10GB memory and 4 CPU create and wait till it finish
export TF_VAR_libvirt_master_memory=10192
export TF_VAR_libvirt_master_vcpu=4
./openshift-install --dir $INSTALL_DIR create cluster --log-level debug

# export the kubeconfig
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

# Once it is finished, disable the CVO
./oc scale --replicas 0 -n openshift-cluster-version deployments/cluster-version-operator

# Disable the deployment/replicaset/statefulset config for openshift-monitoring namespace
./oc scale --replicas=0 replicaset --all -n openshift-monitoring
./oc scale --replicas=0 deployment --all -n openshift-monitoring
./oc scale --replicas=0 statefulset --all -n openshift-monitoring

# Disable the deployment/replicaset/statefulset config for openshift-marketplace namespace
./oc scale --replicas=0 deployment --all -n openshift-marketplace
./oc scale --replicas=0 replicaset --all -n openshift-marketplace 

# Delete the pods which are there in Complete state
./oc delete pod -l 'app in (installer, pruner)' -n openshift-kube-apiserver
./oc delete pods -l 'app in (installer, pruner)' -n openshift-kube-scheduler
./oc delete pods -l 'app in (installer, pruner)' -n openshift-kube-controller-manager 

# Disable the deployment/replicaset for openshift-machine-api and openshift-machine-config-operator
./oc scale --replicas=0 deployment --all -n openshift-machine-api
./oc scale --replicas=0 replicaset --all -n openshift-machine-api
./oc scale --replicas=0 deployment --all -n openshift-machine-config-operator
./oc scale --replicas=0 replicaset --all -n openshift-machine-config-operator
