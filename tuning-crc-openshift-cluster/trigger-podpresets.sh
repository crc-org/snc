#!/bin/bash

set -exuo pipefail

for i in {1..60}
do
	namespace=`oc get ns |  awk 'NR=="'"$i"'"{print $1}'`
	if [[ "$namespace" =~ "openshift-" ]]; then
			sed 's/NAMESPACE_TO_REPLACE/"'"$namespace"'"/g' podpreset-template.yaml > trigger-podpreset.yaml
			echo 'creating podpreset for the namespace: "'"$namespace"'"' 
			${OC} apply -f trigger-podpreset.yaml
	fi
done
