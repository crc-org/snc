#!/bin/bash

set -exuo pipefail

## These admission webhook components (deployed with admission-webhook.yaml) enable updates to resource requests/limits to the Pod specs. 
## The source-code for this admission controller is located at 'https://github.com/spaparaju/k8s-mutate-webhook'. 
## Once all the OpenShift pods update their pod spec with the required resource requests/limits, these webhook related components are removed  so that the created CRC disk-image  does not contain any NON-standard OpenShift components.

${OC} delete MutatingWebhookConfiguration/mutateme svc/mutateme deploy/mutateme
