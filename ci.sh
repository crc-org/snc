#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

cat > /tmp/ignoretests.txt << EOF
"[sig-apps] Daemon set [Serial] should rollback without unnecessary restarts [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps][Feature:DeploymentConfig] deploymentconfigs won't deploy RC with unresolved images when patched with empty image [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-apps][Feature:Jobs] Users should be able to create and run a job in a user project [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-arch] Managed cluster should set requests but not limits [Suite:openshift/conformance/parallel]"
"[sig-auth][Feature:UserAPI] users can manipulate groups [Suite:openshift/conformance/parallel]"
"[sig-builds][Feature:Builds] imagechangetriggers  imagechangetriggers should trigger builds of all types [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-cli] CLI can run inside of a busybox container [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-cli] oc adm must-gather runs successfully [Suite:openshift/conformance/parallel]"
"[sig-cli] oc adm must-gather runs successfully for audit logs [Suite:openshift/conformance/parallel]"
"[sig-cli] oc observe works as expected [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should have a AlertmanagerReceiversNotConfigured alert in firing state [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should provide named network metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should report telemetry if a cloud.openshift.com token is present [Late] [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation][Late] Alerts shouldn't exceed the 500 series limit of total series sent via telemetry from each cluster [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network][Feature:Router] The HAProxy router should expose a health check on the metrics port [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network][endpoints] admission TestEndpointAdmission [Suite:openshift/conformance/parallel]"
"[sig-node] Managed cluster should report ready nodes the entire duration of the test run [Late] [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Dynamic PV (block volmode)] provisioning should provision storage with snapshot data source [Feature:VolumeSnapshotDataSource] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Dynamic PV (default fs)] provisioning should provision storage with snapshot data source [Feature:VolumeSnapshotDataSource] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Dynamic Snapshot (delete policy)] snapshottable[Feature:VolumeSnapshotDataSource] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Dynamic Snapshot (retain policy)] snapshottable[Feature:VolumeSnapshotDataSource] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Pre-provisioned Snapshot (delete policy)] snapshottable[Feature:VolumeSnapshotDataSource] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI Volumes [Driver: csi-hostpath] [Testpattern: Pre-provisioned Snapshot (retain policy)] snapshottable[Feature:VolumeSnapshotDataSource] volume snapshot controller  should check snapshot fields, check restore correctly works after modifying source data, check deletion [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage][Late] Metrics should report short attach times [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage][Late] Metrics should report short mount times [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-imageregistry][Serial][Suite:openshift/registry/serial] Image signature workflow can push a signed image to openshift registry and verify it [Suite:openshift/conformance/serial]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow egress access on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow ingress access from namespace on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should allow ingress access on one named port [Feature:NetworkPolicy] [Skipped:Network/OVNKubernetes] [Skipped:Network/OpenShiftSDN/Multitenant] [Skipped:Network/OpenShiftSDN] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-imageregistry][Feature:ImageTriggers][Serial] ImageStream API TestImageStreamWithoutDockerImageConfig [Suite:openshift/conformance/serial]"
"[sig-auth][Feature:LDAP][Serial] ldap group sync can sync groups from ldap [Suite:openshift/conformance/serial]"
"[sig-autoscaling] [Feature:HPA] Horizontal pod autoscaling (scale resource: CPU) ReplicationController light Should scale from 1 pod to 2 pods [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-imageregistry][Feature:ImageTriggers][Serial] ImageStream admission TestImageStreamAdmitSpecUpdate [Suite:openshift/conformance/serial]"
"[sig-instrumentation] Prometheus when installed on the cluster should have important platform topology metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should have non-Pod host cAdvisor metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should provide ingress metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster should start and expose a secured proxy and unsecured metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-instrumentation] Prometheus when installed on the cluster shouldn't have failing rules evaluation [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network][Feature:Router] The HAProxy router should enable openshift-monitoring to pull metrics [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network][Feature:Router] The HAProxy router should expose prometheus metrics for a route [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-network][Feature:Router] The HAProxy router should expose the profiling endpoints [Skipped:Disconnected] [Suite:openshift/conformance/parallel]"
"[sig-storage] CSI mock volume CSI Volume Snapshots [Feature:VolumeSnapshotDataSource] volumesnapshotcontent and pvc in Bound state with deletion timestamp set should not get deleted while snapshot finalizer exists [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-storage] CSI mock volume CSI Volume Snapshots secrets [Feature:VolumeSnapshotDataSource] volume snapshot create/delete with secrets [Suite:openshift/conformance/parallel] [Suite:k8s]"
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
podman run --rm -v ${PWD}:/data:Z registry.ci.openshift.org/openshift/release:rhel-8-release-golang-1.21-openshift-4.16 /bin/bash -c "cd /data && make cross"
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc config set bundle crc_libvirt_*.crcbundle
crc setup
crc start --disk-size 80 -m 24000 -c 10 -p "${HOME}"/pull-secret

mkdir -p /tmp/artifacts
export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
openshift-tests run experimental/reliability/minimal --dry-run  | grep -F -v -f /tmp/ignoretests.txt  | openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
