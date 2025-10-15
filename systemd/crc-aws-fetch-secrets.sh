#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

# set -x is safe, the secrets are passed via stdin

AWS_CLI_IMG=docker.io/amazon/aws-cli
MIN_CHAR_COUNT=8 # minimum number of chars for the secret to be
                 # assumed valid

umask 0077 # 0600 file permission for secrets
install -d -m 0700 /opt/crc # ensure that the target directory exists

PULL_SECRETS_KEY=${1:-}
KUBEADM_PASS_KEY=${2:-}
DEVELOPER_PASS_KEY=${3:-}

if [[ -z "$PULL_SECRETS_KEY" || -z "$KUBEADM_PASS_KEY" || -z "$DEVELOPER_PASS_KEY" ]]; then
    echo "ERROR: expected to receive 3 parameters: PULL_SECRETS_KEY KUBEADM_PASS_KEY DEVELOPER_PASS_KEY"
    exit 1
fi

DELAY=5
TOTAL_PERIOD=$(( 3*60 ))
ATTEMPTS=$(( TOTAL_PERIOD / DELAY))
function retry_compact() {
    for i in $(seq 1 $ATTEMPTS); do
        # If the command succeeds (returns 0), exit the function with success.
        if "$@"; then
            echo "'$*' succeeded after $i attempts "
            return 0
        fi
        echo "'$*' still failing after $i/$ATTEMPTS attempts ..."
        sleep "$DELAY"
    done
    echo "'$*' didn't succeed after $i attempt ..."
    # If the loop finishes, the command never succeeded.
    return 1
}

cleanup() {
    rm -f /tmp/aws-region /opt/crc/pull-secret.tmp /opt/crc/pass_kubeadmin.tmp /opt/crc/pass_developer.tmp
    echo "Temp files cleanup complete."
}

# Cleanup happens automatically via trap on error or at script end
trap cleanup ERR EXIT

SECONDS=0
podman pull --quiet "$AWS_CLI_IMG"
echo "Took $SECONDS seconds to pull the $AWS_CLI_IMG"

check_imds_available_and_get_region() {
    IMDS_TOKEN_COMMAND=(
        curl
        --connect-timeout 1
        -X PUT
        "http://169.254.169.254/latest/api/token"
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
        -Ssf
    )

    if ! TOKEN=$("${IMDS_TOKEN_COMMAND[@]}"); then
        echo "Couldn't fetch the token..." >&2
        return 1
    fi

    # Then, use the token to get the region
    echo "Fetching the AWS region ..."
    curl -Ssf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region > /tmp/aws-region
    echo >> /tmp/aws-region # add EOL at EOF, for consistency
    echo "AWS region: $(< /tmp/aws-region)"
}

(
    set +x # disable the xtrace as the token would be leaked
    echo "Waiting for the AWS IMDS service to be available ..."
    SECONDS=0
    retry_compact check_imds_available_and_get_region
    echo "Took $SECONDS for the IMDS service to become available."
)

save_secret() {
    name=$1
    key=$2
    dest=$3

    # --log-driver=none avoids that the journal captures the stdout
    # logs of podman and leaks the passwords in the journal ...
    if ! podman run \
           --name "cloud-init-fetch-$name" \
           --env AWS_REGION="$(< /tmp/aws-region)" \
           --log-driver=none \
           --rm \
           "$AWS_CLI_IMG" \
           ssm get-parameter \
               --name "$key" \
               --with-decryption \
               --query "Parameter.Value" \
               --output text \
            > "${dest}.tmp"
    then
        rm -f "${dest}.tmp"
        echo "ERROR: failed to get the '$name' secret ... (fetched from $key)"
        return 1
    fi
    char_count=$(wc -c < "${dest}.tmp")
    if (( char_count < MIN_CHAR_COUNT )); then
        echo "ERROR: the content of the '$name' secret is too short ... (fetched from $key)"
        rm -f "${dest}.tmp"
        return 1
    fi

    mv "${dest}.tmp" "${dest}" # atomic creation of the file

    return 0
}

# execution will abort if 'retry_compact' fails.
retry_compact save_secret "pull-secrets" "$PULL_SECRETS_KEY" /opt/crc/pull-secret
retry_compact save_secret "kubeadmin-pass" "$KUBEADM_PASS_KEY" /opt/crc/pass_kubeadmin
retry_compact save_secret "developer-pass" "$DEVELOPER_PASS_KEY" /opt/crc/pass_developer

exit 0
