#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

root_partition=$(/usr/sbin/blkid -t TYPE=xfs -o device)
/usr/bin/growpart "${root_partition%?}" "${root_partition#/dev/???}"

rootFS="/sysroot"
mount -o remount,rw "${rootFS}"
xfs_growfs "${rootFS}"

#mount -o remount,ro "${rootFS}"

echo "All done"

exit 0
