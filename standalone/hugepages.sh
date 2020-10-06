#!/bin/bash

set -exuo pipefail

top_dir="$(dirname $0)/.."
echo "top dir: $top_dir"
source "$top_dir/tuning-crc-openshift-cluster/crc-env.sh"

######
##  Apply required RHCOS Kernel parameters
#####
echo 'Apply required Kernel paramters to the CRC VM..'
"$top_dir"/tuning-crc-openshift-cluster/apply-kernel-parameters.sh
