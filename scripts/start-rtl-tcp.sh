#!/usr/bin/env bash
# rtl_tcp wrapper - loads config and starts with the right params
set -euo pipefail

# defaults (safe for Pi Zero W)
RTL_TCP_ADDR="0.0.0.0"
RTL_TCP_PORT="1234"
RTL_TCP_SAMPLE_RATE="1024000"
RTL_TCP_BUFFERS="32"
RTL_TCP_GAIN="0"

# override from config if it exists
CONFIG="/etc/raspi-ham/rtl-tcp.conf"
if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

exec /usr/local/bin/rtl_tcp \
    -a "$RTL_TCP_ADDR" \
    -p "$RTL_TCP_PORT" \
    -s "$RTL_TCP_SAMPLE_RATE" \
    -b "$RTL_TCP_BUFFERS" \
    -g "$RTL_TCP_GAIN"
