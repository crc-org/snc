#!/bin/bash

set -x

hostName=$(hostname)

cat << EOF > /etc/dnsmasq.d/crc-dnsmasq.conf
interface=br-ex
expand-hosts
log-queries
local=/crc.testing/
domain=crc.testing
address=/apps-crc.testing/192.168.126.11
address=/api.crc.testing/192.168.126.11
address=/api-int.crc.testing/192.168.126.11
address=/$hostName.crc.testing/192.168.126.11
EOF

