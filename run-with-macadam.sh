#!/bin/bash

set -euo pipefail

readonly PASS_DEVELOPER="${PASS_DEVELOPER:-P@ssd3v3loper}"
readonly PASS_KUBEADMIN="${PASS_KUBEADMIN:-P@sskub3admin}"
readonly CRC_BUNDLE_PATH="${CRC_BUNDLE_PATH:-$HOME/Downloads/crc_vfkit_4.19.3_arm64.crcbundle}"
readonly VM_NAME="crc-ng"
PRIV_KEY_PATH=""
PUB_KEY_PATH=""
USER_DATA_PATH=""
DISK_IMAGE_PATH=""
PULL_SECRET=""
PUB_KEY=""
GVPROXY_SOCKET_PATH=""

# Cleanup function to be executed on script exit
function cleanup() {
    echo "--- Cleaning up ---"
    rm -f user-data crc.img crc.qcow2 bundle.tar kubeconfig "${PRIV_KEY_PATH}" "${PUB_KEY_PATH}"
    macadam rm crc-ng --force 2>/dev/null || true
}

# Generic error handler
function die() {
    echo "Error: $*" >&2
    exit 1
}

# Generates a temporary SSH keypair for the duration of the script execution.
function generate_ssh_keypair() {
    echo "--- Generating temporary SSH keypair ---"
    local key_file
    key_file="$(pwd)/id_rsa_temp"
    rm -f "${key_file}" "${key_file}.pub"
    if ! ssh-keygen -t rsa -b 4096 -f "${key_file}" -N "" -C "crc-macadam-ci"; then
        die "Failed to generate SSH keypair."
    fi
    PRIV_KEY_PATH="${key_file}"
    PUB_KEY_PATH="${key_file}.pub"
    echo "Temporary SSH keypair generated."
}

# Ensures all required dependencies are available in the PATH
function ensure_deps() {
    echo "--- Checking dependencies ---"
    local deps=("zstd" "tar" "curl")
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            echo "'${dep}' not found, attempting to install with yum..."
            if ! sudo yum -y install "${dep}"; then
                die "Failed to install '${dep}' with yum. Please install it manually and try again."
            fi
        fi
    done
}

# Loads secrets and other resources into variables.
function load_resources() {
    # Unset xtrace to prevent secrets from being exposed if the script is run with -x
    set +x
    echo "--- Loading resources ---"
    if [[ -z "${PULL_SECRET_PATH}" || ! -f "${PULL_SECRET_PATH}" ]]; then
        die "Path to pull secret file must be set via PULL_SECRET_PATH, and the file must exist."
    fi
    if [[ ! -f "${PUB_KEY_PATH}" ]]; then
        die "Public key file not found at ${PUB_KEY_PATH}. This should have been generated."
    fi

    PULL_SECRET=$(cat "${PULL_SECRET_PATH}")
    PUB_KEY=$(cat "${PUB_KEY_PATH}")
}

# Generates cloud-init user-data file for VM configuration
function gen_cloud_init() {
    echo "--- Generating cloud-init user-data ---"
    rm -f user-data
    # Unset xtrace to prevent secrets from being exposed if the script is run with -x
    set +x
    cat <<EOF >user-data
#cloud-config
runcmd:
  - systemctl enable --now kubelet
write_files:
- path: /home/core/.ssh/authorized_keys
  content: '$PUB_KEY'
  owner: core
  permissions: '0600'
- path: /opt/crc/id_rsa.pub
  content: '$PUB_KEY'
  owner: root:root
  permissions: '0644'
- path: /etc/sysconfig/crc-env
  content: |
    CRC_SELF_SUFFICIENT=1
    CRC_NETWORK_MODE_USER=1
  owner: root:root
  permissions: '0644'
- path: /opt/crc/pull-secret
  content: |
    $PULL_SECRET
  permissions: '0644'
- path: /opt/crc/pass_kubeadmin
  content: '$PASS_KUBEADMIN'
  permissions: '0644'
- path: /opt/crc/pass_developer
  content: '$PASS_DEVELOPER'
  permissions: '0644'
- path: /opt/crc/ocp-custom-domain.service.done
  permissions: '0644'
EOF
    USER_DATA_PATH="$(pwd)/user-data"
    echo "cloud-init user-data file created."
}

# Extracts the VM disk image from the CRC bundle
function extract_disk_img() {
    echo "--- Extracting VM image from CRC bundle ---"
    if [[ ! -f "${CRC_BUNDLE_PATH}" ]]; then
        die "CRC bundle not found at ${CRC_BUNDLE_PATH}."
    fi

    local bundle_name
    bundle_name=$(basename "${CRC_BUNDLE_PATH}")
    local disk_image_name
    disk_image_name="crc.qcow2"
    tar --zstd -O -xvf "${CRC_BUNDLE_PATH}" "${bundle_name%.*}"/${disk_image_name} >"${disk_image_name}"
    if [[ ! -s "${disk_image_name}" ]]; then
        die "Failed to extract disk image from bundle."
    fi
    DISK_IMAGE_PATH="$(pwd)/${disk_image_name}"
    echo "VM image extracted to ${DISK_IMAGE_PATH}."
}

# Ensures macadam tool is available
function ensure_macadam_exists() {
    echo "--- Setting up macadam ---"
    if command -v macadam &>/dev/null; then
        echo "macadam is already available in PATH."
        return
    fi

    if [ -f "/opt/macadam/macadam" ]; then
        export PATH="/opt/macadam:$PATH"
        echo "macadam found in /opt/macadam and added to PATH."
        return
    fi

    echo "macadam not found, downloading..."

    local version="latest"
    local url="https://github.com/crc-org/macadam/releases/download/${version}/macadam-linux-amd64"

    echo "Downloading from ${url}"
    sudo mkdir -p /opt/macadam
    if ! curl -fL -o /tmp/macadam "${url}"; then
        die "Failed to download macadam."
    fi
    sudo mv /tmp/macadam /opt/macadam/macadam
    sudo chmod +x /opt/macadam/macadam

    export PATH="/opt/macadam:$PATH"
    echo "macadam downloaded to /opt/macadam and added to PATH."
}

# start the VM
function start_macadam_vm() {
    echo "--- Creating VM ---"
    macadam init \
        "${DISK_IMAGE_PATH}" \
        --disk-size 31 \
        --memory 11264 \
        --name crc-ng \
        --username core \
        --ssh-identity-path "${PRIV_KEY_PATH}" \
        --cpus 6 \
        --cloud-init "${USER_DATA_PATH}" \
        --log-level debug

    if ! macadam start crc-ng --log-level debug; then
        echo "Machine didn't come up in time"
    fi
}

# Exposes a port from the VM to the host
function forward_port_gvproxy() {
    echo "--- Exposing port ---"
    local expose_req='{"local":"127.0.0.1:6443","remote":"192.168.127.2:6443","protocol":"tcp"}'
    if ! curl -f \
        --unix-socket "${GVPROXY_SOCKET_PATH}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "${expose_req}" \
        http://gvproxy/services/forwarder/expose; then
        die "Failed to forward API server port: ${expose_req}"
    fi
}

# add dns entries for API server and console
function add_api_server_dns() {
    echo "--- Adding DNS entries for API Server ---"
    local CRC_TESTING_ZONE='{
    "Name": "crc.testing.",
    "Records": [
        {
            "Name": "host",
            "IP": "192.168.127.254"
        },
        {
            "Name": "api",
            "IP": "192.168.127.2"
        },
        {
            "Name": "api-int",
            "IP": "192.168.127.2"
        },
        {
            "Name": "crc",
            "IP": "192.168.126.11"
        }
    ]
}'
    local APPS_CRC_TESTING_ZONE='{"Name": "apps-crc.testing.","DefaultIP": "192.168.127.2"}'

    local gvproxy_cmd
    if ! gvproxy_cmd=$(pgrep -af gvproxy); then
        die "The gvproxy process is not running."
    fi

    GVPROXY_SOCKET_PATH=$(echo "${gvproxy_cmd}" | sed -n 's/.*-services unix:\/\/\([^ ]*\).*/\1/p')
    if [[ -z "${GVPROXY_SOCKET_PATH}" ]]; then
        die "Could not find the gvproxy socket path."
    fi

    local zones_json
    zones_json=(
        "${CRC_TESTING_ZONE}"
        "${APPS_CRC_TESTING_ZONE}"
    )

    for zone_json in "${zones_json[@]}"; do
        if ! curl -f \
            --unix-socket "${GVPROXY_SOCKET_PATH}" \
            -X POST \
            -H 'Content-Type: application/json' \
            -d "${zone_json}" \
            http://gvproxy/services/dns/add; then
            die "Failed to add DNS zone: ${zone_json}"
        fi
    done
}

# Waits for the VM to be ready and retrieves the kubeconfig
function get_kubeconfig() {
    echo "--- Waiting for cluster and retrieving kubeconfig ---"
    echo "Waiting 3mins for VM to start..."
    sleep 180

    local VM_IP="127.0.0.1"
    # get the SSH port from the `gvproxy` process's command line args
    # the port is provided with the flag '-ssh-port' the argument for
    # this flag will have the port to use
    local gvproxy_cmd
    if ! gvproxy_cmd=$(pgrep -af gvproxy); then
        die "The gvproxy process is not running."
    fi
    local ssh_port
    ssh_port=$(echo "${gvproxy_cmd}" | sed -n 's/.*-ssh-port \([0-9]*\).*/\1/p')
    if [[ -z "${ssh_port}" ]]; then
        die "Could not find the ssh port from gvproxy."
    fi

    local ssh_cmd="macadam ssh crc-ng"
    local scp_cmd="scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ${PRIV_KEY_PATH} -P ${ssh_port}"

    echo "Waiting for SSH to be available..."
    until ${ssh_cmd} -- exit 0; do
        sleep 5
        echo "Retrying SSH connection..."
    done

    echo "VM is running. Waiting for API server..."

    until ${ssh_cmd} -- 'sudo oc get node --kubeconfig /opt/crc/kubeconfig --context system:admin'; do
        sleep 30
        echo "Waiting for certificate rotation and API server to be ready..."
    done

    echo "API server is up. Fetching kubeconfig."
    ${scp_cmd} "core@${VM_IP}":/opt/kubeconfig .
    oc config set "clusters.api-${VM_NAME}-testing:6443.server" "https://${VM_IP}:6443" --kubeconfig ./kubeconfig
    oc config set "clusters.crc.server" "https://${VM_IP}:6443" --kubeconfig ./kubeconfig
    echo "kubeconfig retrieved and updated."
}

# Checks the status of the OpenShift cluster
function check_cluster_status() {
    echo "--- Checking cluster status ---"
    export KUBECONFIG=./kubeconfig
    if ! oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=10m; then
        die "Cluster didn't start successfully."
    fi
}

# --- Main execution ---
function main() {
    trap cleanup EXIT

    ensure_deps
    generate_ssh_keypair
    load_resources
    gen_cloud_init
    extract_disk_img
    ensure_macadam_exists
    start_macadam_vm
    add_api_server_dns
    forward_port_gvproxy
    get_kubeconfig

    if ! check_cluster_status; then
        die "Bundle failed to start correctly with macadam."
    fi

    echo "--- Bundle started successfully ---"
}

main "$@"
