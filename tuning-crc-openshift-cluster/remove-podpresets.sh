#!/bin/bash

set -exuo pipefail

for namespace in $(oc get ns  -ojsonpath='{.items[*].metadata.name}')
do
	if [[ "$namespace" =~ "openshift-" ]]; then
			echo 'Removing podpreset for the namespace: "'"$namespace"'"' 
			${OC} delete podpreset/crc-performance-turning -n $namespace
	fi
done
