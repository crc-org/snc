#!/bin/bash
if [ -n "$CRC_NG" ] || [ -n "$CRC_CLOUD" ]; then
    exit 0
fi
exit 1