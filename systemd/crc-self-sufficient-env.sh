#!/bin/bash
set -euo pipefail
# Optional: load env if unit forgot EnvironmentFile
[ -r /etc/sysconfig/crc-env ] && . /etc/sysconfig/crc-env
if [ "${CRC_SELF_SUFFICIENT:-}" = "1" ] || [ "${CRC_CLOUD:-}" = "1" ]; then
    exit 0
fi
exit 1