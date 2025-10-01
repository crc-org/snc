#!/bin/bash

set -x


source /usr/local/bin/crc-systemd-common.sh
export KUBECONFIG=/opt/kubeconfig

wait_for_resource pods

oc apply -f /opt/crc/routes-controller.yaml

