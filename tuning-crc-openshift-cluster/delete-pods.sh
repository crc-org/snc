OC=${OC:-oc}

${OC} delete pods -n  openshift-authentication-operator --all
${OC} delete pods -n  openshift-authentication --all
${OC} delete pods -n openshift-cluster-machine-approver --all
${OC} delete pods -n openshift-cluster-node-tuning-operator --all
${OC} delete pods -n openshift-cluster-samples-operator  --all
${OC} delete pods -n openshift-config-operator  --all
${OC} delete pods -n openshift-console-operator  --all
${OC} delete pods -n openshift-console --all
${OC} delete pods -n openshift-controller-manager-operator  --all
${OC} delete pods -n openshift-controller-manager  --all
${OC} delete pods -n openshift-dns-operator  --all
${OC} delete pods -n  openshift-dns --all
${OC} delete pods -n openshift-image-registry   --all
${OC} delete pods -n openshift-kube-storage-version-migrator --all
${OC} delete pods -n openshift-marketplace  --all
${OC} delete pods -n openshift-multus  --all
${OC} delete pods -n openshift-network-operator   --all
${OC} delete pods -n openshift-operator-lifecycle-manager   --all
${OC} delete pods -n openshift-sdn   --all
${OC} delete pods -n openshift-service-ca-operator    --all
${OC} delete pods -n openshift-service-ca   --all
${OC} delete pods -n openshift-apiserver-operator  --all
${OC} delete pods -n openshift-apiserver  --all
${OC} delete pods -n openshift-ingress-operator --all
${OC} delete pods -n openshift-ingress --all
