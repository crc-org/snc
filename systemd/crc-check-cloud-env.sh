#!/bin/bash

if grep -qi 'ec2' /sys/class/dmi/id/product_uuid ||
   grep -qi 'google' /sys/class/dmi/id/product_name ||
   grep -qi 'openstack' /sys/class/dmi/id/product_name ||
   grep -qi '7783-7084-3265-9085-8269-3286-77' /sys/class/dmi/id/chassis_asset_tag; then
    exit 0
else
    exit 1
fi
