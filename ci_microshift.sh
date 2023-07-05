#!/bin/bash

set -exuo pipefail

sudo yum install -y make golang

./shellcheck.sh
./microshift.sh

# Set the zstd compression level to 10 to have faster
# compression while keeping a reasonable bundle size.
export CRC_ZSTD_EXTRA_FLAGS="-10"
./createdisk.sh crc-tmp-install-data

git clone https://github.com/crc-org/crc.git
pushd crc
make cross
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc config set bundle crc_microshift_libvirt_*.crcbundle
crc config set preset microshift
crc setup
crc start -p "${HOME}"/pull-secret

rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
