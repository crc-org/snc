#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG="/opt/kubeconfig"

function gen_htpasswd() {
    if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
        echo "gen_htpasswd needs two arguments: username password" 1>&2
        return 1
    fi

    podman run --rm docker.io/xmartlabs/htpasswd "$1" "$2"
}

wait_for_resource secret

if [ ! -f /opt/crc/pass_developer ]; then
    echo "developer password does not exist"
    exit 1
fi

if [ ! -f /opt/crc/pass_kubeadmin ]; then
    echo "kubeadmin password does not exist"
    exit 1
fi

echo "generating the kubeadmin and developer passwords ..."

set +x # /!\ disable the logging to avoid leaking the passwords

dev_pass=$(gen_htpasswd developer "$(cat /opt/crc/pass_developer)")
adm_pass=$(gen_htpasswd kubeadmin "$(cat /opt/crc/pass_kubeadmin)")

echo "creating the password secret ..."
# use bash <() to use a temporary fd file
# use sed to remove the empty lines
oc create secret generic htpass-secret  \
   --from-file=htpasswd=<(printf '%s\n%s\n' "$dev_pass" "$adm_pass") \
   -n openshift-config \
   --dry-run=client -oyaml \
    | oc apply -f-

echo "all done"
