#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

function gen_htpasswd() {
    if [ ! -z "${1}" ] && [ ! -z "${2}" ]; then
        podman run --rm -ti xmartlabs/htpasswd $1 $2 >> /tmp/htpasswd.txt
    fi
}

wait_for_resource secret

PASS_DEVELOPER=$(cat /opt/crc/pass_developer)
PASS_KUBEADMIN=$(cat /opt/crc/pass_kubeadmin)

rm -f /tmp/htpasswd.txt
gen_htpasswd developer "${PASS_DEVELOPER}"
gen_htpasswd kubeadmin "${PASS_KUBEADMIN}"

if [ -f /tmp/htpasswd.txt ]; then
    sed -i '/^\s*$/d' /tmp/htpasswd.txt

    oc create secret generic htpass-secret  --from-file=htpasswd=/tmp/htpasswd.txt -n openshift-config --dry-run=client -o yaml > /tmp/htpass-secret.yaml
    oc replace -f /tmp/htpass-secret.yaml
fi
