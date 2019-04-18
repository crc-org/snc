#!/bin/sh

INSTALL_DIR=crc-tmp-install-data
INSTALLER_RELEASE=v0.14.0
OC=${OC:-oc}
YQ=${YQ:-yq}
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-./openshift-install}
CRC_VM_NAME=${CRC_VM_NAME:-crc}

# Download the oc binary if not present in current directory
if ! which $OC; then
    if [[ ! -e oc ]] ; then
        curl -L https://mirror.openshift.com/pub/openshift-v3/clients/4.0.22/linux/oc.tar.gz -o oc.tar.gz
        tar -xvf oc.tar.gz
        rm -fr oc.tar.gz
    fi
    OC=./oc
fi

# Download yq for manipulating in place yaml configs
if ! which $YQ; then
    if [[ ! -e yq ]]; then
        curl -L https://github.com/mikefarah/yq/releases/download/2.2.1/yq_linux_amd64 -o yq
        chmod +x yq
    fi
    YQ=./yq
fi

# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR destroy cluster --log-level debug

if [ "${OPENSHIFT_PULL_SECRET}" = "" ]; then
    echo "OpenShift pull secret must be specified through the OPENSHIFT_PULL_SECRET environment variable"
    exit 1
fi

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr $INSTALL_DIR && mkdir $INSTALL_DIR && cp install-config.yaml $INSTALL_DIR
${YQ} write --inplace $INSTALL_DIR/install-config.yaml metadata.name $CRC_VM_NAME
${YQ} write --inplace $INSTALL_DIR/install-config.yaml compute[0].replicas 0
${YQ} write --inplace $INSTALL_DIR/install-config.yaml pullSecret "${OPENSHIFT_PULL_SECRET}"
${YQ} write --inplace $INSTALL_DIR/install-config.yaml sshKey "$(cat id_rsa_crc.pub)"

# Create the manifests using the INSTALL_DIR
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create manifests || exit 1

# Copy the config which removes taint from master
cp 99_master-kubelet-no-taint.yaml $INSTALL_DIR/openshift/

# Add worker label to master machine config
${YQ} write --inplace $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.metadata.labels[node-role.kubernetes.io/worker] ""

# Add custom domain to cluster-ingress
${YQ} write --inplace $INSTALL_DIR/manifests/cluster-ingress-02-config.yml spec[domain] apps.tt.testing

# Start the cluster with 10GB memory and 4 CPU create and wait till it finish
export TF_VAR_libvirt_master_memory=10192
export TF_VAR_libvirt_master_vcpu=4
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create cluster --log-level debug
if [ $? -ne 0 ]; then
    echo "This is known to fail with:
'pool master is not ready - timed out waiting for the condition'
see https://github.com/openshift/machine-config-operator/issues/579"
fi

# export the kubeconfig
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

# Once it is finished, disable the CVO
${OC} scale --replicas 0 -n openshift-cluster-version deployments/cluster-version-operator

# Disable the deployment/replicaset/statefulset config for openshift-monitoring namespace
${OC} scale --replicas=0 replicaset --all -n openshift-monitoring
${OC} scale --replicas=0 deployment --all -n openshift-monitoring
${OC} scale --replicas=0 statefulset --all -n openshift-monitoring

# Disable the deployment/replicaset/statefulset config for openshift-marketplace namespace
${OC} scale --replicas=0 deployment --all -n openshift-marketplace
${OC} scale --replicas=0 replicaset --all -n openshift-marketplace

# Delete the pods which are there in Complete state
${OC} delete pod -l 'app in (installer, pruner)' -n openshift-kube-apiserver
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-scheduler
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-controller-manager

# Disable the deployment/replicaset for openshift-machine-api and openshift-machine-config-operator
${OC} scale --replicas=0 deployment --all -n openshift-machine-api
${OC} scale --replicas=0 replicaset --all -n openshift-machine-api
${OC} scale --replicas=0 deployment --all -n openshift-machine-config-operator
${OC} scale --replicas=0 replicaset --all -n openshift-machine-config-operator
