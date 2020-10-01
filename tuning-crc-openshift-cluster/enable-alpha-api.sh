SSH_KEYS_OF_MASTER_NODE=../id_rsa_crc
JQ=${JQ:-jq}

set -x
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEYS_OF_MASTER_NODE"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEYS_OF_MASTER_NODE"

${SSH} core@master -- sudo cat /etc/kubernetes/manifests/kube-apiserver-pod.yaml  > current_kubeapiserver_manifest.json
current_args=`cat current_kubeapiserver_manifest.json | jq -r '.spec.containers[]  | select(.name == "kube-apiserver") | .args[0]'`
additional_args=' --runtime-config=settings.k8s.io/v1alpha1=true --enable-admission-plugins=NamespaceAutoProvision,MutatingAdmissionWebhook,PodPreset '
new_args="${current_args} ${additional_args}"
echo $new_args
${JQ}  --arg new_args "$new_args" '(.spec.containers[] | select(.name == "kube-apiserver") | .args[0]) |= $new_args' current_kubeapiserver_manifest.json > updated_kubeapiserver_manifest.json
cat updated_kubeapiserver_manifest.json | jq -c  > unformatted_updated_kubeapiserver_manifest.json
${SCP} -r unformatted_updated_kubeapiserver_manifest.json  core@master:/home/core/enable-alphaapi-kube-apiserver-pod.yaml
${SSH} core@master -- sudo cp /home/core/enable-alphaapi-kube-apiserver-pod.yaml /etc/kubernetes/manifests/kube-apiserver-pod.yaml
## cleanup temp. files created ##
rm current_kubeapiserver_manifest.json updated_kubeapiserver_manifest.json unformatted_updated_kubeapiserver_manifest.json
