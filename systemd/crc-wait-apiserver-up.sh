#!/bin/bash

set -x

source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG=/opt/kubeconfig

# $1 resource, $2 retry count, $3 wait time
wait_for_resource node 4 60
