# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

SNC (Single Node Cluster) creates OpenShift 4 / OKD / MicroShift bundles for [CRC (CodeReady Containers)](https://github.com/crc-org/crc). It provisions a single-node OpenShift cluster on a libvirt VM, configures it for local development use, then packages the VM disk image into platform-specific `.crcbundle` archives (libvirt/Linux, vfkit/macOS, Hyper-V/Windows).

## Key Commands

```bash
# Lint all shell scripts (downloads shellcheck if missing)
./shellcheck.sh

# Build an OpenShift SNI cluster (requires OPENSHIFT_PULL_SECRET_PATH, libvirt, ~90 min)
./snc.sh

# Build a MicroShift cluster (requires subscription-manager registration)
./microshift.sh

# Package the running VM into .crcbundle archives
./createdisk.sh crc-tmp-install-data

# Full CI pipeline: shellcheck + snc.sh + createdisk.sh + conformance tests
./ci.sh                # OpenShift
./ci_microshift.sh     # MicroShift

# Build patched KAO/KCMO operator images with 1-year certs
./build-patched-kao-kcmo-images.sh

# Wrap bundles into container images for registry distribution
./gen-bundle-image.sh <version> <openshift|okd|microshift>
```

## Architecture

The build pipeline has two phases, each with a library of shared functions:

**Phase 1: Cluster provisioning** (`snc.sh` / `microshift.sh`)
- Sources `tools.sh` (installs host dependencies: yq, jq, qemu-img, virsh, etc.) and `snc-library.sh` (libvirt VM lifecycle, cluster stabilization, cert rotation, preflight checks)
- Creates a libvirt VM from RHCOS/FCOS ISO with single-node ignition config
- Waits for OpenShift install, rotates certificates, configures htpasswd auth, image registry, CSI storage, CVO overrides
- Outputs cluster state to `crc-tmp-install-data/`

**Phase 2: Disk image packaging** (`createdisk.sh`)
- Sources `tools.sh` and `createdisk-library.sh` (VM image sparsification, platform-specific bundle generation, systemd unit installation)
- SSHs into the VM to install additional packages (cloud-init, gvisor-tap-vsock), configure networking (tap device, dnsmasq), deploy systemd services
- Shuts down VM, sparsifies the qcow2 image, generates per-platform bundles (libvirt qcow2, vfkit raw, Hyper-V vhdx)
- Compresses each bundle as `.crcbundle` using zstd

**Bundle types** are determined by the entry script: `snc` (OpenShift), `okd` (OKD/SCOS), `microshift`. MicroShift uses `image-mode/microshift/build.sh` to create a bootc-based ISO instead of the openshift-installer flow.

**Shared function libraries:**
- `tools.sh` -- host tool detection/installation, architecture mapping (`ARCH` -> `yq_ARCH`), `retry` with exponential backoff, libvirt VM lifecycle (`create_vm`, `shutdown_vm`, `start_vm`, `destroy_libvirt_resources`)
- `snc-library.sh` -- preflight checks, OC client download, cluster stabilization (`wait_till_cluster_stable`), cert renewal, PV/CSI provisioner setup, htpasswd generation
- `createdisk-library.sh` -- qcow2 sparsification via guestfish, platform bundle generators (`generate_vfkit_bundle`, `generate_hyperv_bundle`), systemd unit deployment, tarball creation

**Systemd services** in `systemd/` are installed into the VM and handle runtime concerns when CRC starts the bundle: DNS (dnsmasq), route management, cluster CA rotation, custom domains, pull secret injection, node readiness checks.

## Environment Variables

| Variable | Purpose |
|---|---|
| `OPENSHIFT_PULL_SECRET_PATH` | **Required.** Path to OpenShift pull secret JSON |
| `OPENSHIFT_VERSION` | Pin a specific OCP version (otherwise uses latest candidate) |
| `OKD_VERSION` | Build an OKD bundle instead of OCP |
| `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` | Override the release image directly |
| `SNC_PRODUCT_NAME` | VM/cluster name (default: `crc`) |
| `SNC_GENERATE_LINUX_BUNDLE` / `_MACOS_` / `_WINDOWS_` | Set to `0` to skip platform bundle |
| `CRC_ZSTD_EXTRA_FLAGS` | Zstd compression flags (default: `--ultra -22`) |
| `MICROSHIFT_VERSION` | MicroShift version to build (default: `4.22`) |

## Conventions

- All scripts use `set -exuo pipefail` and source `tools.sh` first
- SSH into the VM uses the generated `id_ecdsa_crc` keypair with strict host checking disabled
- The `retry` function (exponential backoff, 14 retries) wraps most `oc` commands to handle transient API failures
- VM IP is `192.168.126.11` on the `crc` libvirt network; DNS is configured via NetworkManager dnsmasq overlay
- Bundle metadata lives in `crc-tmp-install-data/crc-bundle-info.json`

# currentDate
Today's date is 2026-06-03.
