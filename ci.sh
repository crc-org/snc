#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync
export PODMAN_VERSION=3.3.1 

./shellcheck.sh
./snc.sh
./createdisk.sh crc-tmp-dir
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
