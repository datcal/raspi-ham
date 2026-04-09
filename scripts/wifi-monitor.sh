#!/usr/bin/env bash
# wifi monitoring and capture tools for raspi-ham
# requires: USB WiFi adapter in monitor mode (run: raspi-ham-mode monitor)
# authorized use only - for pentesting engagements, CTF, and educational purposes
set -euo pipefail

CAPTURE_DIR="/opt/raspi-ham/captures"
ACTION="${1:-}"

# find external USB WiFi adapter (not wlan0 = built-in)
find_interface() {
    local iface
    iface=$(iw dev | awk '/Interface/{iface=$2} /addr/{if(iface != "wlan0") print iface}' | head -1)
    if [ -z "$iface" ]; then
        echo "ERROR: no external WiFi adapter found. plug in your USB dongle." >&2
        exit 1
    fi
    echo "$iface"
}

check_monitor() {
    local iface=$1
    local mode
    mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
    if [ "$mode" != "monitor" ]; then
        echo "ERROR: $iface is in '$mode' mode, not monitor mode." >&2
        echo "run first: sudo raspi-ham-mode monitor" >&2
        exit 1
    fi
}

case "$ACTION" in
    scan)
        # quick scan of nearby WiFi networks
        IFACE=$(find_interface)
        check_monitor "$IFACE"
        DURATION="${2:-30}"
        echo "scanning on $IFACE for ${DURATION}s... (ctrl+c to stop early)"
        echo "output: $CAPTURE_DIR/scan-$(date +%Y%m%d-%H%M%S).csv"
        timeout "$DURATION" airodump-ng "$IFACE" \
            --write "$CAPTURE_DIR/scan-$(date +%Y%m%d-%H%M%S)" \
            --write-interval 5 \
            --output-format csv,pcap \
            2>&1 || true
        echo ""
        echo "scan complete. files in $CAPTURE_DIR/"
        ;;

    capture)
        # capture all packets on a channel
        IFACE=$(find_interface)
        check_monitor "$IFACE"
        CHANNEL="${2:-6}"
        OUTFILE="$CAPTURE_DIR/capture-ch${CHANNEL}-$(date +%Y%m%d-%H%M%S)"
        echo "capturing on channel $CHANNEL with $IFACE..."
        echo "output: ${OUTFILE}.pcap"
        echo "ctrl+c to stop"

        # set channel
        iw dev "$IFACE" set channel "$CHANNEL"

        # capture with tcpdump (lighter than airodump for raw capture)
        tcpdump -i "$IFACE" -w "${OUTFILE}.pcap" -c 100000 2>&1 || true
        echo ""
        echo "capture saved to ${OUTFILE}.pcap"
        echo "transfer to your machine: scp pi@$(hostname -I | awk '{print $1}'):${OUTFILE}.pcap ."
        ;;

    channel-hop)
        # hop across channels while capturing
        IFACE=$(find_interface)
        check_monitor "$IFACE"
        OUTFILE="$CAPTURE_DIR/hop-$(date +%Y%m%d-%H%M%S)"
        echo "channel hopping capture on $IFACE..."
        echo "output: ${OUTFILE}*.cap"
        echo "ctrl+c to stop"
        airodump-ng "$IFACE" \
            --write "$OUTFILE" \
            --output-format pcap \
            2>&1 || true
        echo ""
        echo "captures saved to $CAPTURE_DIR/"
        ;;

    deauth-test)
        # deauth test - single target, YOUR OWN network only
        IFACE=$(find_interface)
        check_monitor "$IFACE"
        TARGET_BSSID="${2:-}"
        if [ -z "$TARGET_BSSID" ]; then
            echo "usage: raspi-ham-monitor deauth-test <bssid> [client-mac]"
            echo "  bssid: target AP MAC address (YOUR OWN network)"
            echo "  client: optional specific client MAC"
            echo ""
            echo "WARNING: only use on networks you own or have written authorization to test"
            exit 1
        fi
        CLIENT="${3:---deauth 3}"
        if [ "$3" != "" ] 2>/dev/null; then
            CLIENT="-c $3 --deauth 3"
        fi
        echo "sending 3 deauth frames to $TARGET_BSSID (your own network)"
        aireplay-ng --deauth 3 -a "$TARGET_BSSID" $CLIENT "$IFACE" || true
        ;;

    list)
        # list captured files
        echo "captures in $CAPTURE_DIR/:"
        ls -lh "$CAPTURE_DIR/" 2>/dev/null || echo "  (empty)"
        echo ""
        TOTAL=$(du -sh "$CAPTURE_DIR" 2>/dev/null | awk '{print $1}')
        echo "total size: ${TOTAL:-0}"
        ;;

    clean)
        # clean old captures
        echo "cleaning captures older than 7 days..."
        find "$CAPTURE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
        echo "done"
        ;;

    *)
        echo "raspi-ham WiFi monitor tools"
        echo ""
        echo "usage: raspi-ham-monitor <command> [args]"
        echo ""
        echo "commands:"
        echo "  scan [duration]        - scan nearby networks (default 30s)"
        echo "  capture [channel]      - capture packets on a channel (default ch6)"
        echo "  channel-hop            - capture while hopping all channels"
        echo "  deauth-test <bssid>    - deauth test (YOUR network only)"
        echo "  list                   - list captured files"
        echo "  clean                  - delete captures older than 7 days"
        echo ""
        echo "before using, put the USB WiFi in monitor mode:"
        echo "  sudo raspi-ham-mode monitor"
        echo ""
        echo "authorized use only."
        exit 1
        ;;
esac
