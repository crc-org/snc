#!/bin/bash

set -exuo pipefail
./shellcheck.sh
./snc.sh

# Run createdisk script
export CRC_ZSTD_EXTRA_FLAGS="-10 --long"
./createdisk.sh crc-tmp-install-data
set +exuo pipefail

# Destroy the cluster
./openshift-baremetal-install destroy cluster --dir crc-tmp-install-data
