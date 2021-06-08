#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

cat > /tmp/ignoretests.txt << EOF
^"\[sig-builds\]\[Feature:Builds\] imagechangetriggers  imagechangetriggers should trigger builds of all types \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-apps\] Daemon set \[Serial\] should rollback without unnecessary restarts \[Conformance\] \[Suite:openshift/conformance/serial/minimal\] \[Suite:k8s\]"
^"\[sig-arch\] Managed cluster should set requests but not limits \[Suite:openshift/conformance/parallel\]"
^"\[sig-auth\]\[Feature:OpenShiftAuthorization\]\[Serial\] authorization  TestAuthorizationResourceAccessReview should succeed \[Suite:openshift/conformance/serial\]"
^"\[Serial\] \[sig-auth\]\[Feature:OAuthServer\] \[RequestHeaders\] \[IdP\] test RequestHeaders IdP \[Suite:openshift/conformance/serial\]"
^"\[sig-cli\] oc adm must-gather runs successfully \[Suite:openshift/conformance/parallel\]"
^"\[sig-cli\] oc adm must-gather runs successfully for audit logs \[Suite:openshift/conformance/parallel\]"
^"\[sig-cli\] oc observe works as expected \[Suite:openshift/conformance/parallel\]"
^"\[sig-autoscaling\] \[Feature:HPA\] Horizontal pod autoscaling (scale resource: CPU) ReplicationController light Should scale from 1 pod to 2 pods \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-etcd\] etcd leader changes are not excessive \[Late\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-cluster-lifecycle\]\[Feature:Machines\]\[Serial\] Managed cluster should grow and decrease when scaling different machineSets simultaneously \[Suite:openshift/conformance/serial\]"
^"\[sig-node\] Managed cluster should report ready nodes the entire duration of the test run \[Late\] \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-imageregistry\]\[Serial\]\[Suite:openshift/registry/serial\] Image signature workflow can push a signed image to openshift registry and verify it \[Suite:openshift/conformance/serial\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should enable openshift-monitoring to pull metrics \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should expose a health check on the metrics port \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should expose prometheus metrics for a route \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should expose the profiling endpoints \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should respond with 503 to unrecognized hosts \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should serve routes that were created from an ingress \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[Feature:Router\] The HAProxy router should support reencrypt to services backed by a serving certificate automatically \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-network\]\[endpoints\] admission TestEndpointAdmission \[Suite:openshift/conformance/parallel\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Dynamic PV (block volmode)\] provisioning should provision storage with snapshot data source \[Feature:VolumeSnapshotDataSource\] \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Dynamic PV (default fs)\] provisioning should provision storage with snapshot data source \[Feature:VolumeSnapshotDataSource\] \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Dynamic Snapshot (delete policy)\] snapshottable\[Feature:VolumeSnapshotDataSource\] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Dynamic Snapshot (retain policy)\] snapshottable\[Feature:VolumeSnapshotDataSource\] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Pre-provisioned Snapshot (delete policy)\] snapshottable\[Feature:VolumeSnapshotDataSource\] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI Volumes \[Driver: csi-hostpath\] \[Testpattern: Pre-provisioned Snapshot (retain policy)\] snapshottable\[Feature:VolumeSnapshotDataSource\] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI mock volume CSI Volume Snapshots \[Feature:VolumeSnapshotDataSource\] volumesnapshotcontent and pvc in Bound state with deletion timestamp set should not get deleted while snapshot finalizer exists \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\] CSI mock volume CSI Volume Snapshots secrets \[Feature:VolumeSnapshotDataSource\] volume snapshot create/delete with secrets \[Suite:openshift/conformance/parallel\] \[Suite:k8s\]"
^"\[sig-storage\]\[Late\] Metrics should report short attach times \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-storage\]\[Late\] Metrics should report short mount times \[Skipped:Disconnected\] \[Suite:openshift/conformance/parallel\]"
^"\[sig-instrumentation\]
EOF

#^"\[sig-storage\]


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
