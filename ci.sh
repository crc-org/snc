#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

./shellcheck.sh
./snc.sh

mkdir -p /tmp/artifacts
export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
openshift-tests run kubernetes/conformance --dry-run  | grep -F -v -f /tmp/ignoretests.txt  | openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
