SSH_KEYS_OF_MASTER_NODE=../id_rsa_crc

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEYS_OF_MASTER_NODE"

${SSH} core@master -- sudo chattr +i  /etc/kubernetes/manifests/kube-apiserver-pod.yaml 
${SSH} core@master -- sudo chattr +i  /etc/kubernetes/manifests/kube-controller-manager-pod.yaml
${SSH} core@master -- sudo chattr +i  /etc/kubernetes/manifests/kube-scheduler-pod.yaml
${SSH} core@master -- sudo chattr +i  /etc/kubernetes/manifests/etcd-pod.yaml
