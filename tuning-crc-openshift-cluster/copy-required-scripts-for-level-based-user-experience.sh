#!/bin/bash

set -exuo pipefail

${SCP} -r ./tuning-crc-openshift-cluster/perf-cvo-override-remove-olm.yaml ${SSH_HOST}:/home/core/perf-cvo-override-remove-olm.yaml
${SCP} -r ./tuning-crc-openshift-cluster/perf-cvo-override-remove-cluster-monitoring.yaml ${SSH_HOST}:/home/core/perf-cvo-override-remove-cluster-monitoring.yaml
${SCP} -r ./tuning-crc-openshift-cluster/perf-delete-resources-of-olm.sh ${SSH_HOST}:/home/core/perf-delete-resources-of-olm.sh
${SCP} -r ./tuning-crc-openshift-cluster/perf-delete-resources-of-cluster-monitoring.sh ${SSH_HOST}:/home/core/perf-delete-resources-of-cluster-monitoring.sh

