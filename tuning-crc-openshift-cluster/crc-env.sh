JQ=${JQ:-jq}
OC=${OC:-oc}
YQ=${YQ:-yq}

export JQ
export OC
export YQ

CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
SSH_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.crc/machines/crc/id_rsa"
SSH_HOST="core@api.${CRC_VM_NAME}.${BASE_DOMAIN}"
SSH_CMD="ssh ${SSH_ARGS} ${SSH_HOST} --"
MASTER_HOST="master"
SSH_GRUBBY_CMD="ssh ${SSH_ARGS} ${MASTER_HOST} --"
SCP="scp ${SSH_ARGS}"

export SSH_CMD
export SSH_HOST
export SCP
