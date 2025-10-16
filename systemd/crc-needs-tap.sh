#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source /etc/sysconfig/crc-env || echo "WARNING: crc-env not found"

EXIT_NEED_TAP=0
EXIT_DONT_NEED_TAP=77
EXIT_ERROR=1

if /usr/local/bin/crc-self-sufficient-env.sh; then
    echo "Running a self-sufficient bundle. Don't need tap0"
    exit "$EXIT_DONT_NEED_TAP"
fi

if /usr/local/bin/crc-user-mode-networking.sh system; then
    echo "Running with CRC and system-mode networking. Don't need tap0. (Fairly rare case.)"
    exit "$EXIT_DONT_NEED_TAP"
fi

# running with CRC (not a self-sufficient bundle)
# running with user-mode networking
# --> vfkit doesn't need tap0
# --> other platforms do need it

virt="$(systemd-detect-virt || true)"

case "${virt}" in
  apple)
    echo "Running with vfkit ($virt) virtualization. Don't need tap0."
    exit "$EXIT_DONT_NEED_TAP"
    ;;
  none)
    echo "Bare metal detected. Don't need tap0."
    exit "$EXIT_DONT_NEED_TAP"
    ;;
  *)
    echo "Running with '$virt' virtualization. Need tap0."
    exit "$EXIT_NEED_TAP"
    ;;
esac
