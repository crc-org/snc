#!/usr/bin/env python3
"""CRC Bundle Testing with Macadam Hypervisor - Port of run-with-macadam.sh"""

import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

@dataclass
class Config:
    pass_developer: str
    pass_kubeadmin: str
    crc_bundle_path: Path
    pull_secret_path: Path
    vm_name: str = "crc-ng"

state: Dict[str, Any] = {
    'priv_key_path': None,
    'pub_key_path': None,
    'user_data_path': None,
    'disk_image_path': None,
    'gvproxy_socket_path': None,
    'oc_binary_path': None,
    'kubeconfig_path': None,
    'pull_secret': '',
    'pub_key': '',
}

class MacadamError(Exception):
    pass

class DependencyError(MacadamError):
    pass

class VMError(MacadamError):
    pass

def run_command(
    cmd: List[str],
    *,
    capture_output: bool = False,
    check: bool = True,
    stdout: Any = None,
    stderr: Any = None,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            cmd,
            capture_output=capture_output,
            check=check,
            stdout=stdout,
            stderr=stderr,
            env=env,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        raise MacadamError(f"Command failed: {' '.join(cmd)}") from e
    except FileNotFoundError as e:
        raise MacadamError(f"Command not found: {cmd[0]}") from e

def load_config_from_env() -> Config:
    pull_secret_path_str = os.environ.get("PULL_SECRET_PATH", "")
    if not pull_secret_path_str:
        raise MacadamError("PULL_SECRET_PATH environment variable must be set.")

    pull_secret_path = Path(pull_secret_path_str)
    if not pull_secret_path.exists():
        raise MacadamError(f"Pull secret file not found at {pull_secret_path}.")

    crc_bundle_path_str = os.environ.get(
        "CRC_BUNDLE_PATH",
        str(Path.home() / "Downloads" / "crc_vfkit_4.19.3_arm64.crcbundle")
    )
    crc_bundle_path = Path(crc_bundle_path_str)

    return Config(
        pass_developer=os.environ.get("PASS_DEVELOPER", "P@ssd3v3loper"),
        pass_kubeadmin=os.environ.get("PASS_KUBEADMIN", "P@sskub3admin"),
        crc_bundle_path=crc_bundle_path,
        pull_secret_path=pull_secret_path,
    )

def ensure_dependencies() -> None:
    print("--- Checking dependencies ---")

    # Basic utilities
    basic_deps = ["zstd", "tar", "curl"]

    for dep in basic_deps:
        if shutil.which(dep) is None:
            print(f"'{dep}' not found, attempting to install...")
            try:
                run_command(["sudo", "yum", "-y", "install", dep])
            except MacadamError as e:
                raise DependencyError(
                    f"Failed to install '{dep}'. "
                    f"Please install it manually and try again."
                ) from e

    # QEMU system emulator (architecture-specific)
    # On RHEL, qemu-kvm is installed at /usr/libexec/qemu-kvm
    # macadam expects qemu-system-{arch} to be available
    arch = os.uname().machine

    if arch == "x86_64":
        qemu_binary_name = "qemu-system-x86_64"
        qemu_package = "qemu-kvm"
    elif arch == "aarch64":
        qemu_binary_name = "qemu-system-aarch64"
        qemu_package = "qemu-kvm"
    else:
        raise DependencyError(
            f"Unsupported architecture: {arch}. "
            f"This script requires x86_64 or aarch64."
        )

    qemu_kvm_path = Path("/usr/libexec/qemu-kvm")
    qemu_symlink_path = Path(f"/usr/bin/{qemu_binary_name}")

    # Check if /usr/libexec/qemu-kvm exists
    if qemu_kvm_path.exists():
        # QEMU is installed, create symlink if needed
        if not qemu_symlink_path.exists():
            print(f"Creating symlink: {qemu_symlink_path} -> {qemu_kvm_path}")
            try:
                run_command([
                    "sudo", "ln", "-sf", str(qemu_kvm_path), str(qemu_symlink_path)
                ])
                print(f"Symlink created successfully.")
            except MacadamError as e:
                raise DependencyError(
                    f"Failed to create symlink for {qemu_binary_name}. "
                    f"Please create it manually: sudo ln -s {qemu_kvm_path} {qemu_symlink_path}"
                ) from e
        else:
            print(f"{qemu_binary_name} is already available.")

def generate_ssh_keypair(config: Config) -> None:
    print("--- Generating temporary SSH keypair ---")

    key_file = Path.cwd() / "id_rsa_temp"
    key_file.unlink(missing_ok=True)
    Path(str(key_file) + ".pub").unlink(missing_ok=True)

    try:
        run_command([
            "ssh-keygen", "-t", "rsa", "-b", "4096",
            "-f", str(key_file), "-N", "", "-C", "crc-macadam-ci",
        ])
    except MacadamError as e:
        raise MacadamError("Failed to generate SSH keypair.") from e

    state['priv_key_path'] = key_file
    state['pub_key_path'] = Path(str(key_file) + ".pub")

    print("Temporary SSH keypair generated.")

def load_resources(config: Config) -> None:
    print("--- Loading resources ---")

    if not config.pull_secret_path.exists():
        raise MacadamError(f"Pull secret file not found at {config.pull_secret_path}.")

    if not state['pub_key_path'] or not state['pub_key_path'].exists():
        raise MacadamError(
            f"Public key file not found at {state['pub_key_path']}. "
            "This should have been generated."
        )

    state['pull_secret'] = config.pull_secret_path.read_text().strip()
    state['pub_key'] = state['pub_key_path'].read_text().strip()

def generate_cloud_init(config: Config) -> None:
    print("--- Generating cloud-init user-data ---")

    Path("user-data").unlink(missing_ok=True)

    cloud_init_content = f"""#cloud-config
runcmd:
  - systemctl enable --now kubelet
write_files:
- path: /home/core/.ssh/authorized_keys
  content: '{state['pub_key']}'
  owner: core
  permissions: '0600'
- path: /opt/crc/id_rsa.pub
  content: '{state['pub_key']}'
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
    {state['pull_secret']}
  permissions: '0644'
- path: /opt/crc/pass_kubeadmin
  content: '{config.pass_kubeadmin}'
  permissions: '0644'
- path: /opt/crc/pass_developer
  content: '{config.pass_developer}'
  permissions: '0644'
- path: /opt/crc/ocp-custom-domain.service.done
  permissions: '0644'
"""

    user_data_path = Path.cwd() / "user-data"
    user_data_path.write_text(cloud_init_content)
    state['user_data_path'] = user_data_path

    print("cloud-init user-data file created.")

def extract_disk_image(config: Config) -> None:
    print("--- Extracting VM image from CRC bundle ---")

    if not config.crc_bundle_path.exists():
        raise MacadamError(f"CRC bundle not found at {config.crc_bundle_path}.")

    disk_image_name = "crc.qcow2"
    bundle_stem = config.crc_bundle_path.stem
    if bundle_stem.endswith(".tar"):
        bundle_stem = bundle_stem[:-4]

    tar_path = f"{bundle_stem}/{disk_image_name}"

    with open(disk_image_name, 'wb') as f:
        run_command(
            ["tar", "--zstd", "-O", "-xf", str(config.crc_bundle_path), tar_path],
            stdout=f,
        )

    disk_image_path = Path.cwd() / disk_image_name
    state['disk_image_path'] = disk_image_path

    if not disk_image_path.exists() or disk_image_path.stat().st_size == 0:
        raise MacadamError("Failed to extract disk image from bundle.")

    print(f"VM image extracted to {disk_image_path}.")

def extract_oc_binary(config: Config) -> None:
    print("--- Extracting oc binary from CRC bundle ---")

    if not config.crc_bundle_path.exists():
        raise MacadamError(f"CRC bundle not found at {config.crc_bundle_path}.")

    oc_binary_name = "oc"
    bundle_stem = config.crc_bundle_path.stem
    if bundle_stem.endswith(".tar"):
        bundle_stem = bundle_stem[:-4]

    tar_path = f"{bundle_stem}/{oc_binary_name}"

    with open(oc_binary_name, 'wb') as f:
        run_command(
            ["tar", "--zstd", "-O", "-xf", str(config.crc_bundle_path), tar_path],
            stdout=f,
        )

    oc_binary_path = Path.cwd() / oc_binary_name
    state['oc_binary_path'] = oc_binary_path

    if not oc_binary_path.exists() or oc_binary_path.stat().st_size == 0:
        raise MacadamError("Failed to extract oc binary from bundle.")

    # Make the binary executable
    run_command(["chmod", "+x", str(oc_binary_path)])

    print(f"oc binary extracted to {oc_binary_path}.")

def ensure_macadam_exists() -> None:
    print("--- Setting up macadam ---")

    if shutil.which("macadam") is not None:
        print("macadam is already available in PATH.")
        return

    macadam_opt_path = Path("/opt/macadam/macadam")
    if macadam_opt_path.exists():
        os.environ["PATH"] = f"/opt/macadam:{os.environ['PATH']}"
        print("macadam found in /opt/macadam and added to PATH.")
        return

    print("macadam not found, downloading...")

    version = "v0.3.0"
    url = f"https://github.com/crc-org/macadam/releases/download/{version}/macadam-linux-amd64"

    print(f"Downloading from {url}")

    try:
        run_command(["sudo", "mkdir", "-p", "/opt/macadam"])
        urllib.request.urlretrieve(url, "/tmp/macadam")
        run_command(["sudo", "mv", "/tmp/macadam", "/opt/macadam/macadam"])
        run_command(["sudo", "chmod", "+x", "/opt/macadam/macadam"])
    except Exception as e:
        raise MacadamError("Failed to download macadam.") from e

    os.environ["PATH"] = f"/opt/macadam:{os.environ['PATH']}"
    print("macadam downloaded to /opt/macadam and added to PATH.")

def ensure_gvproxy_exists() -> None:
    print("--- Setting up gvproxy ---")

    gvproxy_path = Path("/usr/local/libexec/podman/gvproxy")
    if gvproxy_path.exists():
        print(f"gvproxy found at {gvproxy_path}.")
        return

    print("gvproxy not found, downloading...")

    version = "v0.8.7"
    url = f"https://github.com/containers/gvisor-tap-vsock/releases/download/{version}/gvproxy-linux-amd64"

    print(f"Downloading from {url}")

    try:
        run_command(["sudo", "mkdir", "-p", str(gvproxy_path.parent)])
        urllib.request.urlretrieve(url, "/tmp/gvproxy")
        run_command(["sudo", "mv", "/tmp/gvproxy", str(gvproxy_path)])
        run_command(["sudo", "chmod", "+x", str(gvproxy_path)])
    except Exception as e:
        raise MacadamError("Failed to download gvproxy.") from e

    print(f"gvproxy downloaded to {gvproxy_path}.")

def start_macadam_vm(config: Config) -> None:
    print("--- Creating VM ---")

    try:
        run_command([
            "macadam", "init", str(state['disk_image_path']),
            "--disk-size", "31", "--memory", "11264", "--name", "crc-ng",
            "--username", "core", "--ssh-identity-path", str(state['priv_key_path']),
            "--cpus", "6", "--cloud-init", str(state['user_data_path']),
            "--log-level", "debug",
        ])
    except MacadamError as e:
        raise VMError("Failed to initialize VM with macadam.") from e

    result = run_command(
        ["macadam", "start", "crc-ng", "--log-level", "debug"],
        check=False,
    )

    if result.returncode != 0:
        print("Machine didn't come up in time")

class UnixStreamHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.socket_path)

def gvproxy_post(endpoint: str, data: Dict[str, Any]) -> None:
    if not state['gvproxy_socket_path']:
        raise MacadamError("gvproxy socket path not set.")

    conn = UnixStreamHTTPConnection(state['gvproxy_socket_path'])

    try:
        headers = {"Content-Type": "application/json"}
        body = json.dumps(data)

        conn.request("POST", f"http://gvproxy{endpoint}", body, headers)
        response = conn.getresponse()

        if response.status != 200:
            raise MacadamError(
                f"gvproxy POST to {endpoint} failed with status {response.status}"
            )
    finally:
        conn.close()

def get_gvproxy_socket_path() -> str:
    try:
        result = run_command(["pgrep", "-af", "gvproxy"], capture_output=True)
    except MacadamError as e:
        raise MacadamError("The gvproxy process is not running.") from e

    gvproxy_cmd = result.stdout.strip()
    match = re.search(r'-services unix://([^ ]+)', gvproxy_cmd)
    if not match:
        raise MacadamError("Could not find the gvproxy socket path.")

    return match.group(1)

def get_ssh_port() -> str:
    try:
        result = run_command(["pgrep", "-af", "gvproxy"], capture_output=True)
    except MacadamError as e:
        raise MacadamError("The gvproxy process is not running.") from e

    gvproxy_cmd = result.stdout.strip()
    match = re.search(r'-ssh-port (\d+)', gvproxy_cmd)
    if not match:
        raise MacadamError("Could not find the SSH port in gvproxy command line.")

    return match.group(1)

def copy_kubeconfig_from_vm() -> None:
    print("Copying kubeconfig from VM...")

    ssh_port = get_ssh_port()
    kubeconfig_path = Path.cwd() / "kubeconfig"

    run_command([
        "scp",
        "-P", ssh_port,
        "-i", str(state['priv_key_path']),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        f"core@127.0.0.1:/opt/kubeconfig",
        str(kubeconfig_path)
    ])

    state['kubeconfig_path'] = kubeconfig_path

    if not kubeconfig_path.exists() or kubeconfig_path.stat().st_size == 0:
        raise MacadamError("Failed to copy kubeconfig from VM.")

    print(f"Kubeconfig copied to {kubeconfig_path}.")

def add_api_server_dns() -> None:
    print("--- Adding DNS entries for API Server ---")

    state['gvproxy_socket_path'] = get_gvproxy_socket_path()

    crc_testing_zone = {
        "Name": "crc.testing.",
        "Records": [
            {"Name": "host", "IP": "192.168.127.254"},
            {"Name": "api", "IP": "192.168.127.2"},
            {"Name": "api-int", "IP": "192.168.127.2"},
            {"Name": "crc", "IP": "192.168.126.11"},
        ]
    }

    apps_crc_testing_zone = {
        "Name": "apps-crc.testing.",
        "DefaultIP": "192.168.127.2"
    }

    for zone in [crc_testing_zone, apps_crc_testing_zone]:
        gvproxy_post("/services/dns/add", zone)

def forward_port_gvproxy() -> None:
    print("--- Exposing port ---")

    expose_req = {
        "local": "127.0.0.1:6443",
        "remote": "192.168.127.2:6443",
        "protocol": "tcp"
    }

    gvproxy_post("/services/forwarder/expose", expose_req)

def update_hosts_file() -> None:
    print("--- Updating /etc/hosts ---")

    hostname = "api.crc.testing"
    ip_address = "127.0.0.1"
    hosts_entry = f"{ip_address} {hostname}"

    result = run_command(["sudo", "bash", "-c", f"echo '{hosts_entry}' >> /etc/hosts"])
    if result.returncode != 0:
        raise MacadamError("unable to add api.crc.testing entry to hosts file")

    print(f"Successfully added '{hosts_entry}' to /etc/hosts")

def wait_for_ssh() -> None:
    print("Waiting for SSH to be available...")

    while True:
        result = run_command(
            ["macadam", "ssh", "crc-ng", "--", "echo", "SSH_READY"],
            check=False,
            capture_output=True,
        )

        if result.stdout and "SSH_READY" in result.stdout:
            print("SSH is available.")
            break

        time.sleep(5)
        print("Retrying SSH connection...")

def wait_for_api_server() -> None:
    print("VM is running. Waiting for kubeconfig file in VM...")

    # Wait for kubeconfig to exist in VM
    while True:
        result = run_command(
            ["macadam", "ssh", "crc-ng", "--", "[ -f /opt/crc/kubeconfig ] && echo KUBECONFIG_READY"],
            check=False,
            capture_output=True,
        )
        if result.stdout and "KUBECONFIG_READY" in result.stdout:
            print("Kubeconfig file found in VM.")
            copy_kubeconfig_from_vm()
            break
        time.sleep(10)
        print("Waiting for kubeconfig file...")

    print("Waiting for API server...")
    while True:
        result = run_command(
            [
                str(state['oc_binary_path']), "get", "node",
                "--kubeconfig", str(state['kubeconfig_path']),
                "--context", "admin"
            ],
            check=False,
            capture_output=True,
        )

        if result.stdout and "Ready" in result.stdout:
            print("API server is ready.")
            break

        time.sleep(30)
        print("Waiting for certificate rotation and API server to be ready...")

def check_cluster_status() -> None:
    print("--- Waiting for cluster and checking status ---")
    print("Waiting 3mins for VM to start...")
    time.sleep(180)

    # Wait for SSH to be available
    wait_for_ssh()

    # Wait for API server to be ready
    wait_for_api_server()

    # Run cluster stability check using local oc binary
    print("--- Checking cluster stability ---")

    while True:
        result = run_command(
            [
                str(state['oc_binary_path']), "adm", "wait-for-stable-cluster",
                "--minimum-stable-period=1m", "--timeout=10m",
                "--kubeconfig", str(state['kubeconfig_path']),
                "--context", "admin"
            ],
            check=False,
            capture_output=True,
        )

        if result.stdout or result.stderr:
            output = result.stdout + result.stderr
            if ("progressing" not in output.lower() and
                len(output.strip()) > 0):
                print("Cluster is stable and ready.")
                break

        time.sleep(30)
        print("Retrying cluster stability check...")

def main() -> int:
    try:
        config = load_config_from_env()

        ensure_dependencies()
        generate_ssh_keypair(config)
        load_resources(config)
        generate_cloud_init(config)
        extract_disk_image(config)
        extract_oc_binary(config)
        ensure_macadam_exists()
        ensure_gvproxy_exists()
        start_macadam_vm(config)
        add_api_server_dns()
        forward_port_gvproxy()
        update_hosts_file()
        check_cluster_status()

        print("--- Bundle started successfully ---")
        return 0

    except MacadamError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted by user.", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())

