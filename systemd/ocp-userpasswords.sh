#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /usr/local/bin/crc-systemd-common.sh

CRC_PASS_KUBEADMIN_PATH=${1:-}
CRC_PASS_DEVELOPER_PATH=${2:-}

if [[ -z "$CRC_PASS_KUBEADMIN_PATH" || -z "$CRC_PASS_DEVELOPER_PATH" ]]; then
    echo "ERROR: expected to receive the kubeadmin password file as 1st arg and the dev password file as 2nd arg. Got '$CRC_PASS_KUBEADMIN_PATH' and '$CRC_PASS_DEVELOPER_PATH'"
    exit 1
fi

CRC_HTPASSWD_IMAGE=registry.access.redhat.com/ubi10/httpd-24

function gen_htpasswd() {
    if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
        echo "gen_htpasswd needs two arguments: username password" >&2
        return 1
    fi

    podman run --rm "$CRC_HTPASSWD_IMAGE" htpasswd -nb "$1" "$2"
}

# enforced by systemd
if [[ ! -r "$CRC_PASS_DEVELOPER_PATH" ]]; then
    echo "ERROR: CRC developer password does not exist ($CRC_PASS_DEVELOPER_PATH)"
    exit 1
fi

# enforced by systemd
if [[ ! -r "$CRC_PASS_KUBEADMIN_PATH" ]]; then
    echo "ERROR: CRC kubeadmin password does not exist ($CRC_PASS_KUBEADMIN_PATH)"
    exit 1
fi

echo "Pulling $CRC_HTPASSWD_IMAGE ..."
podman pull --quiet "$CRC_HTPASSWD_IMAGE"

wait_for_resource_or_die secret

echo "Generating the kubeadmin and developer passwords ..."
set +x # disable the logging to avoid leaking the passwords

dev_pass=$(gen_htpasswd developer "$(cat "$CRC_PASS_DEVELOPER_PATH")")
adm_pass=$(gen_htpasswd kubeadmin "$(cat "$CRC_PASS_KUBEADMIN_PATH")")

echo "creating the password secret ..."
# use bash "<()" to use a temporary fd file (safer to handle secrets)
oc create secret generic htpass-secret  \
   --from-file=htpasswd=<(printf '%s\n%s\n' "$dev_pass" "$adm_pass") \
   -n openshift-config \
   --dry-run=client -oyaml \
    | oc apply -f-

echo "All done"

exit 0
