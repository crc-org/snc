#!/bin/bash

set -exuo pipefail

./shellcheck.sh
./snc.sh
./createdisk.sh crc-tmp-install-data
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
