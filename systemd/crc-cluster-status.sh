#!/bin/bash

set -x

export KUBECONFIG=/opt/kubeconfig

if [ ! -f /opt/crc/pass_kubeadmin ]; then
    echo "kubeadmin password file not found"
    exit 1
fi

PASS_KUBEADMIN="$(cat /opt/crc/pass_kubeadmin)"

rm -rf /tmp/.crc-cluster-ready

if ! oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=10m; then
    exit 1
fi

echo "Logging in again to update $KUBECONFIG with kubeadmin token"
COUNTER=0
MAXIMUM_LOGIN_RETRY=10
until `oc login --insecure-skip-tls-verify=true -u kubeadmin -p "$PASS_KUBEADMIN" https://api.crc.testing:6443 --kubeconfig "${updated_kubeconfig_path}" > /dev/null 2>&1`
do
    if [ $COUNTER == $MAXIMUM_LOGIN_RETRY ]; then
        echo "Unable to login to the cluster..., installation failed."
        exit 1
    fi
    echo "Logging into OpenShift with updated credentials try $COUNTER, hang on...."
    sleep 5
    ((COUNTER++))
done

# need to set a marker to let `crc` know the cluster is ready
touch /tmp/.crc-cluster-ready

