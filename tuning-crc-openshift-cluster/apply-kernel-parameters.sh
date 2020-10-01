SSH_KEYS_OF_MASTER_NODE=../id_rsa_crc
set -x
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEYS_OF_MASTER_NODE"

${SSH} core@master -- sudo grubby --update-kernel=ALL --args="transparent_hugepage=never "
