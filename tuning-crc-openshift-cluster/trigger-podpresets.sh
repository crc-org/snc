#!/bin/bash

set -exuo pipefail

curdir="$(dirname $0)"
for namespace in $(oc get ns  -ojsonpath='{.items[*].metadata.name}')
do
	if [[ "$namespace" =~ "openshift-" ]]; then
			success=0
			sed 's/NAMESPACE_TO_REPLACE/"'"$namespace"'"/g' "$curdir"/podpreset-template.yaml > $curdir/trigger-podpreset.yaml
			echo 'creating podpreset for the namespace: "'"$namespace"'"' 
			cat $curdir/trigger-podpreset.yaml
			for i in {1..2}; do
				if ${OC} apply -f $curdir/trigger-podpreset.yaml ; then
					success=1
					break
				fi
				sleep 1
			done
			if [ $success != 1 ]; then
				exit 1
			fi
	fi
done
