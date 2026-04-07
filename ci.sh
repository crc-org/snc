#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

./shellcheck.sh
./snc.sh

echo "### Extracting openshift-tests binary"
mkdir /tmp/os-test
export TESTS_IMAGE=$(oc --kubeconfig=crc-tmp-install-data/auth/kubeconfig adm release info -a "${HOME}"/pull-secret --image-for=tests)
oc image extract -a "${HOME}"/pull-secret "${TESTS_IMAGE}" --path=/usr/bin/openshift-tests:/tmp/os-test/.
chmod +x /tmp/os-test/openshift-tests
sudo mv /tmp/os-test/openshift-tests /usr/local/bin/

# Run createdisk script
export CRC_ZSTD_EXTRA_FLAGS="-10 --long"
./createdisk.sh crc-tmp-install-data

function destroy_cluster () {
    # Destroy the cluster
    local snc_product_name=crc
    sudo virsh destroy ${snc_product_name} || true
    sudo virsh undefine ${snc_product_name} --nvram || true
    sudo virsh vol-delete --pool ${snc_product_name} ${snc_product_name}.qcow2 || true
    sudo virsh vol-delete --pool ${snc_product_name} rhcos-live.iso || true
    sudo virsh pool-destroy ${snc_product_name} || true
    sudo virsh pool-undefine ${snc_product_name} || true
    sudo virsh net-destroy ${snc_product_name} || true
    sudo virsh net-undefine ${snc_product_name} || true
}

destroy_cluster
# Unset the kubeconfig which is set by snc
unset KUBECONFIG

# Delete the dnsmasq config created by snc
# otherwise snc set the domain entry with 192.168.126.11
# and crc set it in another file 192.168.130.11 so
# better to remove the dnsmasq config after running snc
sudo rm -fr /etc/NetworkManager/dnsmasq.d/*
sudo systemctl reload NetworkManager

git clone https://github.com/code-ready/crc.git
pushd crc
make containerized
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc config set bundle crc_libvirt_*.crcbundle
crc setup
crc start --disk-size 80 -m 24000 -c 10 -p "${HOME}"/pull-secret --log-level debug

mkdir -p crc-tmp-install-data/test-artifacts
export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
openshift-tests run kubernetes/conformance/parallel/minimal --monitor pod-lifecycle -o crc-tmp-install-data/test-artifacts/e2e.log --junit-dir crc-tmp-install-data/test-artifacts/junit
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
