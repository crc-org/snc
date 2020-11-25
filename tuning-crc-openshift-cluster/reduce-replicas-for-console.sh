#!/bin/bash

set -exuo pipefail

${OC} patch console.operator.openshift.io cluster -p='{"spec": {"managementState": "Unmanaged"}}' --type merge
${OC} scale --replicas=1 deployment downloads -n openshift-console
${OC} scale --replicas=1 deployment console -n openshift-console

