#!/bin/bash

### Create the disk image as per the level (1,2,3) indicated

if [ $PERF_TUNE_DISK_LEVEL -eq 1 ]
then
        source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-1.sh
elif [ $PERF_TUNE_DISK_LEVEL -eq 2 ]
then
        source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-2.sh
else
        source ./tuning-crc-openshift-cluster/delete-required-resources-for-level-3.sh
fi


  
