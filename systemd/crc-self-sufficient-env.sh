#!/bin/bash

set -o pipefail
set -o nounset
set -o errtrace

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

if [[ "${CRC_SELF_SUFFICIENT:-}" ]]; then
    echo "Found CRC_SELF_SUFFICIENT=$CRC_SELF_SUFFICIENT"

    if [[ ! "${CRC_SELF_SUFFICIENT}" =~ ^[01]$ ]]; then
        echo "ERROR: CRC_SELF_SUFFICIENT should be 0 or 1 ..." >&2
        exit 1
    fi

    if [[ "$CRC_SELF_SUFFICIENT" == 1 ]]; then
        exit 0
    else
        exit 1
    fi
fi

TEST_TIMEOUT=120
VSOCK_COMM_PORT=1024

set +o errexit
# set -o errexit disabled to capture the test return code
timeout "$TEST_TIMEOUT" python3 /usr/local/bin/crc-test-vsock.py "$VSOCK_COMM_PORT"
returncode=$?
set -o errexit

case "$returncode" in
    19) # ENODEV
        echo "vsock device doesn't exist, not running self-sufficient bundle" >&2
        exit 1
        ;;
    124)
        echo "ERROR: vsock/${VSOCK_COMM_PORT} test timed out after $TEST_TIMEOUT seconds :/" >&2
        exit 124
        ;;
    1)
        echo "vsock/${VSOCK_COMM_PORT} not working, running with a self-sufficient bundle" >&2
        exit 0
        ;;
    0)
        echo "vsock/${VSOCK_COMM_PORT} works, not running with a self-sufficient bundle" >&2
        exit 1
        ;;
    *)
        echo "ERROR: unexpected return code from the vsock test: $returncode" >&2
        exit "$returncode"
esac

# cannot be reached
