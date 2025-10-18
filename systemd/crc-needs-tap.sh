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
