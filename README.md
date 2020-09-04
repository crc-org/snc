# Single node cluster (snc) scripts for OpenShift 4 

## How to use?
- Make sure the one time setup is satisfied. (https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md#one-time-setup)
- Clone this repo `git clone https://github.com/code-ready/snc.git`
- `cd <directory_to_cloned_repo>`
- `./snc.sh`

## How to create disk image?
- Once your `snc.sh` script run successfully.
- You need to wait for around 30 mins till cluster settle.
- `./createdisk.sh crc-tmp-install-data`

## Monitoring

The installation is a [long process](https://github.com/openshift/installer/blob/master/docs/user/overview.md#cluster-installation-process). It can take up to 45 mins.
You can monitor the progress of the installation with `kubectl`.

```
$ export KUBECONFIG=<directory_to_cloned_repo>/crc-tmp-install-data/auth/kubeconfig
$ kubectl get pods --all-namespaces
```

## Building SNC for OKD 4
- Before running `./snc.sh`, you need to create a pull secret file, and set a couple of environment variables to override the default behavior.
- Select the OKD 4 release that you want to build from: [https://origin-release.apps.ci.l2s4.p1.openshiftapps.com](https://origin-release.apps.ci.l2s4.p1.openshiftapps.com)
- For example, to build release: 4.5.0-0.okd-2020-08-12-020541

```bash
# Create a pull secret file

cat << EOF > /tmp/pull_secret.json
{"auths":{"fake":{"auth": "Zm9vOmJhcgo="}}}
EOF

# Set environment for OKD build
export OKD_VERSION=4.5.0-0.okd-2020-08-12-020541
export OPENSHIFT_PULL_SECRET_PATH="/tmp/pull_secret.json"

# Build the Single Node cluster
./snc.sh
```

- When the build is complete, create the disk image as described above.

## Troubleshooting

OpenShift installer will create 2 VMs. It is sometimes useful to ssh inside the VMs.
Add the following lines in your `~/.ssh/config` file. You can then do `ssh master` and `ssh bootstrap`.

```
Host master
    Hostname 192.168.126.11
    User core
    IdentityFile <directory_to_cloned_repo>/id_rsa_crc
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host bootstrap
    Hostname 192.168.126.10
    User core
    IdentityFile <directory_to_cloned_repo>/id_rsa_crc
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```
