#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

./shellcheck.sh
./snc.sh
./createdisk.sh crc-tmp-install-data
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
