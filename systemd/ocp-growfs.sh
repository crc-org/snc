#!/bin/bash

set -x

root_partition=$(/usr/sbin/blkid -t TYPE=xfs -o device)
/usr/bin/growpart "${root_partition%?}" "${root_partition#/dev/???}"

rootFS="/sysroot"
mount -o remount,rw "${rootFS}"
xfs_growfs "${rootFS}"
#mount -o remount,ro "${rootFS}"
