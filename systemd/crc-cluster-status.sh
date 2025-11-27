#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

MAXIMUM_LOGIN_RETRY=10
RETRY_DELAY=5

if [ ! -f /opt/crc/pass_kubeadmin ]; then
    echo "kubeadmin password file not found"
    exit 1
fi

rm -rf /tmp/.crc-cluster-ready

SECONDS=0
if ! oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=10m; then
    exit 1
fi

echo "Cluster took $SECONDS seconds to stabilize."

echo "Logging into OpenShift with kubeadmin user to update the KUBECONFIG"

try_login() {
    (   # use a `(set +x)` subshell to avoid leaking the password
        set +x
        set +e # don't abort on error in this subshell
        oc login --insecure-skip-tls-verify=true \
	   --kubeconfig=/tmp/kubeconfig \
           -u kubeadmin \
           -p "$(cat /opt/crc/pass_kubeadmin)" \
           https://api.crc.testing:6443 > /dev/null 2>&1
    )
    local success="$?"
    if [[ "$success" == 0 ]]; then
        echo "Login succeeded"
    else
        echo "Login did not complete ..."
    fi

    return "$success"
}

for ((counter=1; counter<=MAXIMUM_LOGIN_RETRY; counter++)); do
    echo "Login attempt $counter/$MAXIMUM_LOGIN_RETRY…"
    if try_login; then
        break
    fi
    if (( counter == MAXIMUM_LOGIN_RETRY )); then
        echo "Unable to login to the cluster after $counter attempts; authentication failed."
        exit 1
    fi
    sleep "$RETRY_DELAY"
done

# need to set a marker to let `crc` know the cluster is ready
touch /tmp/.crc-cluster-ready

echo "All done after $SECONDS seconds "

exit 0
