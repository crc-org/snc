#!/bin/bash

set -exuo pipefail

./shellcheck.sh
./snc.sh
./createdisk.sh crc-tmp-install-data

git clone https://github.com/code-ready/crc.git
pushd crc
make cross
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc config set bundle crc_podman_libvirt_*.crcbundle
crc config set preset podman
crc setup
crc start

rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
