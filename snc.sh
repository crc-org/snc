#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

# kill all the child processes for this script when it exits
trap 'kill -9 $(jobs -p) || true' EXIT

# If the user set OKD_VERSION in the environment, then use it to override OPENSHIFT_VERSION, MIRROR, and OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
# Unless, those variables are explicitly set as well.
OKD_VERSION=${OKD_VERSION:-none}
if [[ ${OKD_VERSION} != "none" ]]
then
    OPENSHIFT_VERSION=${OKD_VERSION}
    MIRROR=${MIRROR:-https://github.com/openshift/okd/releases/download}
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-quay.io/openshift/okd:${OPENSHIFT_VERSION}}
fi

INSTALL_DIR=crc-tmp-install-data
JQ=${JQ:-jq}
OC=${OC:-oc}
XMLLINT=${XMLLINT:-xmllint}
YQ=${YQ:-yq}
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
CRC_PV_DIR="/mnt/pv-data"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"
ARCH=$(uname -m)
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp}

yq_ARCH=${ARCH}
# yq and install_config.yaml use amd64 as arch for x86_64
if [ "${ARCH}" == "x86_64" ]; then
    yq_ARCH="amd64"
fi

# If user defined the OPENSHIFT_VERSION environment variable then use it.
# Otherwise use the tagged version if available
if test -n "${OPENSHIFT_VERSION-}"; then
    OPENSHIFT_RELEASE_VERSION=${OPENSHIFT_VERSION}
    echo "Using release ${OPENSHIFT_RELEASE_VERSION} from OPENSHIFT_VERSION"
else
    OPENSHIFT_RELEASE_VERSION=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
    if test -n "${OPENSHIFT_RELEASE_VERSION}"; then
        echo "Using release ${OPENSHIFT_RELEASE_VERSION} from local Git tags"
    else
        OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/latest-4.5/release.txt | sed -n 's/^ *Version: *//p')"
        if test -n "${OPENSHIFT_RELEASE_VERSION}"; then
            echo "Using release ${OPENSHIFT_RELEASE_VERSION} from the latest mirror"
        else
            echo "Unable to determine an OpenShift release version.  You may want to set the OPENSHIFT_VERSION environment variable explicitly."
            exit 1
        fi
    fi
fi

function preflight_failure() {
        local msg=$1
        echo "$msg"
        if [ -z "${SNC_NON_FATAL_PREFLIGHT_CHECKS-}" ]; then
                exit 1
        fi
}

function run_preflight_checks() {
        echo "Checking libvirt and DNS configuration"

        LIBVIRT_URI=qemu+tcp://localhost/system

        # check if libvirtd is listening on a TCP socket
        if ! virsh -c ${LIBVIRT_URI} uri >/dev/null; then
                preflight_failure  "libvirtd is not listening for plain-text TCP connections, see https://github.com/openshift/installer/tree/master/docs/dev/libvirt#configure-libvirt-to-accept-tcp-connections"
        fi
	
	#Just warn if architecture is not supported
	case $ARCH in
		x86_64|ppc64le|s390x)
			echo "The host arch is ${ARCH}.";;
		*)	
 			echo "The host arch is ${ARCH}. This is not supported by SNC!";;
	esac	

        # check for availability of a hypervisor using kvm
        if ! virsh -c ${LIBVIRT_URI} capabilities | ${XMLLINT} --xpath "/capabilities/guest/arch[@name='${ARCH}']/domain[@type='kvm']" - &>/dev/null; then
                preflight_failure "Your ${ARCH} platform does not provide a hardware-accelerated hypervisor, it's strongly recommended to enable it before running SNC. Check virt-host-validate for more detailed diagnostics"
                return
        fi

        # check that api.crc.testing either can't be resolved, or resolves to 192.168.126.1[01]
        local ping_status
        ping_status="$(ping -c1 api.crc.testing | head -1 || true >/dev/null)"
        if echo ${ping_status} | grep "PING api.crc.testing (" && ! echo ${ping_status} | grep "192.168.126.1[01])"; then
                preflight_failure "DNS setup seems wrong, api.crc.testing resolved to an IP which is neither 192.168.126.10 nor 192.168.126.11, please check your NetworkManager configuration and /etc/hosts content"
                return
        fi

        # check if firewalld is configured to allow traffic from 192.168.126.0/24 to 192.168.122.1
        # this check is very basic and expects the configuration to match
        # https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld
        # Disabled for now as on stock RHEL8 installs, additional permissions are needed for
        # firewall-cmd --list-services, so this test fails for unrelated reasons
        #
        #local zone
        #if firewall-cmd -h >/dev/null; then
        #        # With older libvirt, the 'libvirt' zone will not exist
        #        if firewall-cmd --get-zones |grep '\<libvirt\>'; then
        #                zone=libvirt
        #        else
        #                zone=dmz
        #        fi
        #        if ! firewall-cmd --zone=${zone} --list-services | grep '\<libvirt\>'; then
        #                preflight_failure "firewalld is available, but it is not configured to allow 'libvirt' traffic in either the 'libvirt' or 'dmz' zone, please check https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld"
        #                return
        #        fi
        #fi

        echo "libvirt and DNS configuration successfully checked"
}

function replace_pull_secret() {
        # Hide the output of 'cat $OPENSHIFT_PULL_SECRET_PATH' so that it doesn't
        # get leaked in CI logs
        set +x
        local filename=$1
        sed -i "s!@HIDDEN_PULL_SECRET@!$(cat $OPENSHIFT_PULL_SECRET_PATH)!" $filename
        set -x
}

function apply_bootstrap_etcd_hack() {
        # This is needed for now due to etcd changes in 4.4:
        # https://github.com/openshift/cluster-etcd-operator/pull/279
        while ! ${OC} get etcds cluster >/dev/null 2>&1; do
            sleep 3
        done
        echo "API server is up, applying etcd hack"
        ${OC} patch etcd cluster -p='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}' --type=merge
}

function create_json_description {
    openshiftInstallerVersion=$(${OPENSHIFT_INSTALL} version)
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.0"' \
            | ${JQ} '.type = "snc"' \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.openshiftInstallerVersion = \"${openshiftInstallerVersion}\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" \
            | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
            | ${JQ} ".clusterInfo.appsDomain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" >${INSTALL_DIR}/crc-bundle-info.json
}

function generate_pv() {
  local pvdir="${1}"
  local name="${2}"
cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    volume: ${name}
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
    - ReadOnlyMany
  hostPath:
    path: ${pvdir}
  persistentVolumeReclaimPolicy: Recycle
EOF
}

function setup_pv_dirs() {
    local dir="${1}"
    local count="${2}"

    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
    for pvsubdir in \$(seq -f "pv%04g" 1 ${count}); do
        mkdir -p "${dir}/\${pvsubdir}"
    done
    if ! chcon -R -t svirt_sandbox_file_t "${dir}" &> /dev/null; then
        echo "Failed to set SELinux context on ${dir}"
    fi
    chmod -R 770 ${dir}
EOF
}

function create_pvs() {
    local pvdir="${1}"
    local count="${2}"

    setup_pv_dirs "${pvdir}" "${count}"

    for pvname in $(seq -f "pv%04g" 1 ${count}); do
        if ! ${OC} get pv "${pvname}" &> /dev/null; then
            generate_pv "${pvdir}/${pvname}" "${pvname}" | ${OC} create -f -
        else
            echo "persistentvolume ${pvname} already exists"
        fi
    done

    # Apply registry pvc to bound with pv0001
    ${OC} apply -f registry_pvc.yaml

    # Add registry storage to pvc
    ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "add", "path": "/spec/storage/pvc", "value": {"claim": "crc-image-registry-storage"}}]' --type=json
    # Remove emptyDir as storage for registry
    ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "remove", "path": "/spec/storage/emptyDir"}]' --type=json
}

# This follows https://blog.openshift.com/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms/
# in order to trigger regeneration of the initial 24h certs the installer created on the cluster
function renew_certificates() {
    # Get the cli image from release payload and update it to bootstrap-cred-manager resource
    cli_image=$(${OC} adm release -a ${OPENSHIFT_PULL_SECRET_PATH} info ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=cli)
    ${YQ} write kubelet-bootstrap-cred-manager-ds.yaml.in spec.template.spec.containers[0].image ${cli_image} >kubelet-bootstrap-cred-manager-ds.yaml

    ${OC} apply -f kubelet-bootstrap-cred-manager-ds.yaml
    rm kubelet-bootstrap-cred-manager-ds.yaml

    # Delete the current csr signer to get new request.
    ${OC} delete secrets/csr-signer-signer secrets/csr-signer -n openshift-kube-controller-manager-operator

    # Wait for 5 min to make sure cluster is stable again.
    sleep 300

    # Remove the 24 hours certs and bootstrap kubeconfig
    # this kubeconfig will be regenerated and new certs will be created in pki folder
    # which will have 30 days validity.
    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo rm -fr /var/lib/kubelet/pki
    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo rm -fr /var/lib/kubelet/kubeconfig
    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl restart kubelet

    # Wait until bootstrap csr request is generated.
    until ${OC} get csr | grep Pending; do echo 'Waiting for first CSR request.'; sleep 2; done
    ${OC} get csr -ojsonpath='{.items[*].metadata.name}' | xargs ${OC} adm certificate approve

    delete_operator "daemonset/kubelet-bootstrap-cred-manager" "openshift-machine-config-operator" "k8s-app=kubelet-bootstrap-cred-manager"
}

# deletes an operator and wait until the resources it manages are gone.
function delete_operator() {
        local delete_object=$1
        local namespace=$2
        local pod_selector=$3

        pod=$(${OC} get pod -l ${pod_selector} -o jsonpath="{.items[0].metadata.name}" -n ${namespace})

        ${OC} delete ${delete_object} -n ${namespace}
        # Wait until the operator pod is deleted before trying to delete the resources it manages
        ${OC} wait --for=delete pod/${pod} --timeout=120s -n ${namespace} || ${OC} delete pod/${pod} --grace-period=0 --force -n ${namespace} || true
}

# Download the oc binary if not present in current directory
if ! which ${OC}; then
    if [[ ! -e oc ]] ; then
        curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/openshift-client-linux-${OPENSHIFT_RELEASE_VERSION}.tar.gz" | tar zx oc
    fi
    OC=./oc
fi

# Download yq for manipulating in place yaml configs
if ! "${YQ}" -V; then
    if [[ ! -e yq ]]; then
        curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_${yq_ARCH} -o yq
        chmod +x yq
    fi
    YQ=./yq
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

if ! which ${XMLLINT}; then
    sudo yum -y install /usr/bin/xmllint
fi

run_preflight_checks

if [ -z "${OPENSHIFT_PULL_SECRET_PATH-}" ]; then
    echo "OpenShift pull secret file path must be specified through the OPENSHIFT_PULL_SECRET_PATH environment variable"
    exit 1
elif [ ! -f ${OPENSHIFT_PULL_SECRET_PATH} ]; then
    echo "Provided OPENSHIFT_PULL_SECRET_PATH (${OPENSHIFT_PULL_SECRET_PATH}) does not exists"
    exit 1
fi

if test -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE-}"; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(curl -l "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/release.txt" | sed -n 's/^Pull From: //p')"
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
elif test -n "${OPENSHIFT_VERSION-}"; then
    echo "Both OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE and OPENSHIFT_VERSION are set, OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE will take precedence"
    echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
    echo "OPENSHIFT_VERSION: $OPENSHIFT_VERSION"
fi
echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Extract openshift-install binary if not present in current directory
if test -z ${OPENSHIFT_INSTALL-}; then
    echo "Extracting installer binary from OpenShift baremetal-installer image"
    baremetal_installer_image=$(${OC} adm release -a ${OPENSHIFT_PULL_SECRET_PATH} info ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=baremetal-installer)
    ${OC} image -a ${OPENSHIFT_PULL_SECRET_PATH} extract ${baremetal_installer_image} --confirm --path /usr/bin/openshift-install:.
    chmod +x openshift-install
    OPENSHIFT_INSTALL=./openshift-install
fi

# Extract oc binary from the payload and use it for all following operations
if ! test -f oc; then
    echo "Extracting oc binary from OpenShift payload image"
    oc_image=$(${OC} adm release -a ${OPENSHIFT_PULL_SECRET_PATH} info ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=cli-artifacts)
    ${OC} image -a ${OPENSHIFT_PULL_SECRET_PATH} extract ${oc_image} --confirm --path /usr/bin/oc:.
    chmod +x oc
    OC=./oc
fi

# Allow to disable debug by setting SNC_OPENSHIFT_INSTALL_NO_DEBUG in the environment
if test -z "${SNC_OPENSHIFT_INSTALL_NO_DEBUG-}"; then
        OPENSHIFT_INSTALL_EXTRA_ARGS="--log-level debug"
else
        OPENSHIFT_INSTALL_EXTRA_ARGS=""
fi

# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} destroy cluster ${OPENSHIFT_INSTALL_EXTRA_ARGS} || echo "failed to destroy previous cluster.  Continuing anyway"
# Generate a new ssh keypair for this cluster

rm id_rsa_crc* || true
ssh-keygen -N "" -f id_rsa_crc -C "core"


# Clean up old DNS overlay file
if [ -f /etc/NetworkManager/dnsmasq.d/openshift.conf ]; then
    sudo rm /etc/NetworkManager/dnsmasq.d/openshift.conf
fi

# Set NetworkManager DNS overlay file
cat << EOF | sudo tee /etc/NetworkManager/dnsmasq.d/crc-snc.conf
server=/${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.1
address=/apps-${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.11
EOF

# Reload the NetworkManager to make DNS overlay effective
sudo systemctl reload NetworkManager

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr ${INSTALL_DIR} && mkdir ${INSTALL_DIR} && cp install-config.yaml ${INSTALL_DIR}
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml compute[0].architecture ${yq_ARCH}
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml controlPlane.architecture ${yq_ARCH}
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml baseDomain ${BASE_DOMAIN}
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml metadata.name ${CRC_VM_NAME}
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml compute[0].replicas 0
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml pullSecret "@HIDDEN_PULL_SECRET@"
replace_pull_secret ${INSTALL_DIR}/install-config.yaml
${YQ} write --inplace ${INSTALL_DIR}/install-config.yaml sshKey "$(cat id_rsa_crc.pub)"

# Create the manifests using the INSTALL_DIR
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create manifests || exit 1

# Add custom domain to cluster-ingress
${YQ} write --inplace ${INSTALL_DIR}/manifests/cluster-ingress-02-config.yml spec[domain] apps-${CRC_VM_NAME}.${BASE_DOMAIN}
# Add master memory to 12 GB and 6 cpus 
# This is only valid for openshift 4.3 onwards
${YQ} write --inplace ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value[domainMemory] 14336
${YQ} write --inplace ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value[domainVcpu] 6
# Add master disk size to 31 GB
# This is only valid for openshift 4.5 onwards
${YQ} write --inplace ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value.volume[volumeSize] 33285996544
# Add network resource to lower the mtu for CNV
cp cluster-network-03-config.yaml ${INSTALL_DIR}/manifests/
# Add codeReadyContainer as invoker to identify it with telemeter
export OPENSHIFT_INSTALL_INVOKER="codeReadyContainers"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

apply_bootstrap_etcd_hack &

${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create cluster ${OPENSHIFT_INSTALL_EXTRA_ARGS} || echo "failed to create the cluster, but that is expected.  We will block on a successful cluster via a future wait-for."

renew_certificates

# Wait for install to complete, this provide another 30 mins to make resources (apis) stable
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} wait-for install-complete ${OPENSHIFT_INSTALL_EXTRA_ARGS}

# Set the VM static hostname to crc-xxxxx-master-0 instead of localhost.localdomain
HOSTNAME=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} hostnamectl status --transient)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} sudo hostnamectl set-hostname ${HOSTNAME}

create_json_description


# Create persistent volumes
create_pvs "${CRC_PV_DIR}" 30

# Mark some of the deployments unmanaged by the cluster-version-operator (CVO)
# https://github.com/openshift/cluster-version-operator/blob/master/docs/dev/clusterversion.md#setting-objects-unmanaged
${OC} patch clusterversion version --type json -p "$(cat cvo_override.yaml)"

# Clean-up 'openshift-monitoring' namespace
delete_operator "deployment/cluster-monitoring-operator" "openshift-monitoring" "app=cluster-monitoring-operator"
delete_operator "deployment/prometheus-operator" "openshift-monitoring" "app.kubernetes.io/name=prometheus-operator"
delete_operator "deployment/prometheus-adapter" "openshift-monitoring" "name=prometheus-adapter"
delete_operator "statefulset/alertmanager-main" "openshift-monitoring" "app=alertmanager"
${OC} delete statefulset,deployment,daemonset --all -n openshift-monitoring

# Delete the pods which are there in Complete state
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-apiserver
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-scheduler
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-controller-manager

# Clean-up 'openshift-machine-api' namespace
delete_operator "deployment/machine-api-operator" "openshift-machine-api" "k8s-app=machine-api-operator"
${OC} delete statefulset,deployment,daemonset --all -n openshift-machine-api

# Clean-up 'openshift-machine-config-operator' namespace
delete_operator "deployment/machine-config-operator" "openshift-machine-config-operator" "k8s-app=machine-config-operator"
${OC} delete statefulset,deployment,daemonset --all -n openshift-machine-config-operator

# Clean-up 'openshift-insights' namespace
${OC} delete statefulset,deployment,daemonset --all -n openshift-insights

# Clean-up 'openshift-cloud-credential-operator' namespace
${OC} delete statefulset,deployment,daemonset --all -n openshift-cloud-credential-operator

# Clean-up 'openshift-cluster-storage-operator' namespace
delete_operator "deployment.apps/csi-snapshot-controller-operator" "openshift-cluster-storage-operator" "app=csi-snapshot-controller-operator"
${OC} delete statefulset,deployment,daemonset --all -n openshift-cluster-storage-operator

# Clean-up 'openshift-kube-storage-version-migrator-operator' namespace
${OC} delete statefulset,deployment,daemonset --all -n openshift-kube-storage-version-migrator-operator

# Delete the v1beta1.metrics.k8s.io apiservice since we are already scale down cluster wide monitioring.
# Since this CRD block namespace deletion forever.
${OC} delete apiservice v1beta1.metrics.k8s.io

# Scale route deployment from 2 to 1
${OC} scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator

# Set default route for registry CRD from false to true.
${OC} patch config.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
