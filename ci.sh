#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

cat > /tmp/ignoretests.txt << EOF
^"\[sig-arch\] Managed cluster should ensure control plane pods do not run in best-effort QoS \[Suite:openshift/conformance/parallel\]"
^"\[Serial\] \[sig-auth\]\[Feature:OAuthServer\] \[RequestHeaders\] \[IdP\] test RequestHeaders IdP \[Suite:openshift/conformance/serial\]"
^"\[sig-auth\]\[Feature:SCC\]\[Early\] should not have pod creation failures during install \[Suite:openshift/conformance/parallel\]"
^"\[sig-auth\]\[Feature:OpenShiftAuthorization\]\[Serial\] authorization  TestAuthorizationResourceAccessReview should succeed \[Suite:openshift/conformance/serial\]"
^"\[sig-cli\] oc adm must-gather runs successfully for audit logs \[Suite:openshift/conformance/parallel\]"
^"\[sig-cli\] oc adm must-gather runs successfully \[Suite:openshift/conformance/parallel\]"
^"\[sig-cli\] oc observe works as expected \[Suite:openshift/conformance/parallel\]"
^"\[sig-cluster-lifecycle\]\[Feature:Machines\]\[Serial\] Managed cluster should grow and decrease when scaling different machineSets simultaneously \[Suite:openshift/conformance/serial\]"
^"\[sig-imageregistry\]\[Feature:Image\] oc tag should change image reference for internal images \[Suite:openshift/conformance/parallel\]"
^"\[sig-arch\] \[Conformance\] FIPS TestFIPS \[Suite:openshift/conformance/parallel/minimal\]"
^"\[sig-builds\]\[Feature:Builds\] Multi-stage image builds should succeed \[Suite:openshift/conformance/parallel\]"
^"\[sig-apps\] Daemon set \[Serial\] should rollback without unnecessary restarts \[Conformance\] \[Suite:openshift/conformance/serial/minimal\] \[Suite:k8s\]"
^"\[sig-instrumentation\]
^"\[sig-network\]
^"\[sig-node\]
^"\[sig-scheduling\]
^"\[sig-storage\]
EOF


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

# Destroy the cluster
./openshift-baremetal-install destroy cluster --dir crc-tmp-install-data

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
make cross
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc setup
crc start --disk-size 80 -m 24000 -c 10 -p "${HOME}"/pull-secret -b crc_libvirt_*.crcbundle

mkdir -p /tmp/artifacts
export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
openshift-tests run openshift/conformance --dry-run  | grep -v -f /tmp/ignoretests.txt  | openshift-tests run --timeout 15m -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
