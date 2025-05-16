#!/bin/bash

if grep -qi 'ec2' /sys/class/dmi/id/product_uuid ||
   grep -qi 'google' /sys/class/dmi/id/product_name ||
   grep -qi 'openstack' /sys/class/dmi/id/product_name ||
   grep -qi 'microsoft' /sys/class/dmi/id/sys_vendor; then
    exit 0
else
    exit 1
fi
