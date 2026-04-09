#!/usr/bin/env bash
# switch between rtl_tcp (SDR) and dump1090 (ADS-B) modes
# only one can use the dongle at a time
set -euo pipefail

ACTION="${1:-}"

case "$ACTION" in
    sdr)
        echo "switching to SDR mode (rtl_tcp)..."
        systemctl stop raspi-ham-dump1090.service 2>/dev/null || true
        sleep 2  # let the dongle be released by the kernel
        systemctl start rtl-tcp.service
        echo "SDR mode active - connect your app to port 1234"
        ;;
    adsb)
        echo "switching to ADS-B mode (dump1090)..."
        systemctl stop rtl-tcp.service 2>/dev/null || true
        sleep 2
        # enable bias-T for LNA if you're using one with your ADS-B antenna
        /usr/local/bin/rtl_biast -b 1 2>/dev/null || true
        sleep 1
        systemctl start raspi-ham-dump1090.service
        echo "ADS-B mode active - web UI on port 8080"
        ;;
    monitor)
        echo "switching to WiFi monitor mode..."
        # find the external USB WiFi adapter (not wlan0 which is built-in)
        EXT_WLAN=$(iw dev | awk '/Interface/{iface=$2} /addr/{if(iface != "wlan0") print iface}' | head -1)
        if [ -z "$EXT_WLAN" ]; then
            echo "ERROR: no external WiFi adapter found. plug in your USB WiFi dongle."
            exit 1
        fi
        echo "using interface: $EXT_WLAN"
        # put it in monitor mode
        ip link set "$EXT_WLAN" down
        iw "$EXT_WLAN" set monitor control
        ip link set "$EXT_WLAN" up
        echo "monitor mode active on $EXT_WLAN"
        echo "use: raspi-ham-monitor scan    - to scan networks"
        echo "use: raspi-ham-monitor capture - to capture packets"
        ;;
    managed)
        echo "switching USB WiFi back to managed mode..."
        EXT_WLAN=$(iw dev | awk '/Interface/{iface=$2} /addr/{if(iface != "wlan0") print iface}' | head -1)
        if [ -z "$EXT_WLAN" ]; then
            echo "ERROR: no external WiFi adapter found."
            exit 1
        fi
        ip link set "$EXT_WLAN" down
        iw "$EXT_WLAN" set type managed
        ip link set "$EXT_WLAN" up
        echo "$EXT_WLAN back in managed mode"
        ;;
    status)
        if systemctl is-active --quiet rtl-tcp.service; then
            echo "MODE: SDR (rtl_tcp on port 1234)"
        elif systemctl is-active --quiet raspi-ham-dump1090.service; then
            echo "MODE: ADS-B (dump1090 on port 8080)"
        else
            echo "MODE: IDLE (nothing running)"
        fi
        # check WiFi adapter mode
        EXT_WLAN=$(iw dev | awk '/Interface/{iface=$2} /addr/{if(iface != "wlan0") print iface}' | head -1)
        if [ -n "$EXT_WLAN" ]; then
            WLAN_MODE=$(iw dev "$EXT_WLAN" info 2>/dev/null | awk '/type/{print $2}')
            echo "WIFI: $EXT_WLAN ($WLAN_MODE)"
        else
            echo "WIFI: no external adapter detected"
        fi
        ;;
    *)
        echo "usage: raspi-ham-mode {sdr|adsb|monitor|managed|status}"
        exit 1
        ;;
esac
