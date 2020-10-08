#!/bin/bash

set -exuo pipefail

curdir="$(dirname $0)"
for namespace in $(oc get ns  -ojsonpath='{.items[*].metadata.name}')
do
	if [[ "$namespace" =~ "openshift-" ]]; then
			sed 's/NAMESPACE_TO_REPLACE/"'"$namespace"'"/g' "$curdir"/podpreset-template.yaml > trigger-podpreset.yaml
			echo 'creating podpreset for the namespace: "'"$namespace"'"' 
			${OC} apply -f trigger-podpreset.yaml
	fi
done
