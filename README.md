# Single node cluster (snc) scripts for OpenShift 4 (This branch is use to create bundle only for podman)

It uses Fedora CoreOS stable channel to create the bundle.

## How to use?
- Clone this repo `git clone https://github.com/code-ready/snc.git`
- `cd <directory_to_cloned_repo>`
- `./snc.sh`

## How to create disk image?
- Once your `snc.sh` script run successfully.
- `./createdisk.sh crc-tmp-dir`

## Creating container image for bundles

After running snc.sh/createdisk.sh, the generated bundles can be uploaded to a container registry using this command:

```
./gen-bundle-image.sh <version> <openshift/okd/podman>
```

Note: a GPG key is needed to sign the bundles before they are wrapped in a container image.

Please note the SNC project is “as-is” on this Github repository. At this time, it is not an offically supported Red Hat solution.
