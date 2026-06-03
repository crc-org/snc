#!/bin/bash

set -exuo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h] [BUNDLE1 BUNDLE2]

Compare the last-layer image sizes between two OpenShift release bundles.

Arguments:
  BUNDLE1    First bundle version  (e.g. 4.21.18)
  BUNDLE2    Second bundle version (e.g. 4.22.0-rc.5)

If no arguments are provided, the script will prompt interactively.

Options:
  -h, --help    Show this help message and exit

Examples:
  $(basename "$0") 4.21.18 4.22.0-rc.5
  $(basename "$0")
EOF
    exit "${1:-0}"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

if [[ $# -eq 2 ]]; then
    BUNDLE1="$1"
    BUNDLE2="$2"
elif [[ $# -eq 0 ]]; then
    read -rp "Enter first bundle version (e.g. 4.21.18): " BUNDLE1
    read -rp "Enter second bundle version (e.g. 4.22.0-rc.5): " BUNDLE2
else
    echo "Error: expected 0 or 2 arguments, got $#" >&2
    usage 1
fi

if [[ -z "$BUNDLE1" || -z "$BUNDLE2" ]]; then
    echo "Error: both bundle versions must be non-empty" >&2
    exit 1
fi

BUNDLE1_SAFE="${BUNDLE1//[^a-zA-Z0-9.]/_}"
BUNDLE2_SAFE="${BUNDLE2//[^a-zA-Z0-9.]/_}"

# store payload info
PULL_SECRET_PATH="${OPENSHIFT_PULL_SECRET_PATH:-${HOME}/pull-secret}"
oc adm release info -a "${PULL_SECRET_PATH}" --output=json "quay.io/openshift-release-dev/ocp-release:${BUNDLE1}-x86_64" --size >"${BUNDLE1_SAFE}.json"
oc adm release info -a "${PULL_SECRET_PATH}" --output=json "quay.io/openshift-release-dev/ocp-release:${BUNDLE2}-x86_64" --size >"${BUNDLE2_SAFE}.json"

# extract size info
jq -r '.images | to_entries[] | @text "\(.key) \(.value.layers[-1].size)"' "${BUNDLE1_SAFE}.json" >"last_layer_${BUNDLE1_SAFE}.size"
jq -r '.images | to_entries[] | @text "\(.key) \(.value.layers[-1].size)"' "${BUNDLE2_SAFE}.json" >"last_layer_${BUNDLE2_SAFE}.size"

awk -v b1="$BUNDLE1" -v b2="$BUNDLE2" '
  BEGIN {print "image " b1 " " b2 " growth percent"}
  FNR==NR {b1size[$1] = $2/1024/1024; seen[$1]=1; next}
  {b2size[$1] = $2/1024/1024; seen[$1]=1}
  END {
    for (image in seen) {
      diff = b2size[image] - b1size[image]
      total_diff = total_diff + diff
      printf "%s %d %d %dMB %.0f%%\n", image, b1size[image], b2size[image], diff, b1size[image] !=0 ? diff/b1size[image]*100: 100
    }
  printf "total diff: %gMB\n", total_diff >"/dev/stderr"
  }' "last_layer_${BUNDLE1_SAFE}.size" "last_layer_${BUNDLE2_SAFE}.size" | column -t
