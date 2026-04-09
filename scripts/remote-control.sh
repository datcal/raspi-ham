#!/usr/bin/env bash
# raspi-ham MQTT remote control daemon
# subscribes to MQTT topic and executes commands from the web panel
set -euo pipefail

CONFIG="/etc/raspi-ham/remote.conf"
SCRIPTS_DIR="/opt/raspi-ham/scripts"

# defaults
MQTT_HOST="your-cluster.s1.eu.hivemq.cloud"
MQTT_PORT="8883"
MQTT_USER="raspi-ham"
MQTT_PASS="change-me"
MQTT_TOPIC_CMD="raspi-ham/cmd"
MQTT_TOPIC_STATUS="raspi-ham/status"
PANEL_URL=""  # optional: your website URL for status reporting

# load config
if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

if [ "$MQTT_PASS" = "change-me" ]; then
    echo "ERROR: edit $CONFIG with your MQTT broker credentials first"
    exit 1
fi

# report current status to MQTT (retained message so panel can read it)
report_status() {
    local wifi_status mode_status
    wifi_status=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 || echo "unknown")
    mode_status=$("$SCRIPTS_DIR/mode-switch.sh" status 2>/dev/null | awk '{print $2}' || echo "unknown")

    local payload="{\"wifi\":\"$wifi_status\",\"mode\":\"$mode_status\",\"ts\":$(date +%s)}"

    mosquitto_pub \
        -h "$MQTT_HOST" \
        -p "$MQTT_PORT" \
        -u "$MQTT_USER" \
        -P "$MQTT_PASS" \
        --capath /etc/ssl/certs \
        -t "$MQTT_TOPIC_STATUS" \
        -m "$payload" \
        -r \
        -q 1 2>/dev/null || true

    # also update web panel DB if URL is configured
    if [ -n "$PANEL_URL" ]; then
        curl -s -X POST "$PANEL_URL?api=status" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --max-time 5 2>/dev/null || true
    fi
}

# handle incoming command
handle_command() {
    local msg="$1"
    local type value

    type=$(echo "$msg" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])" 2>/dev/null || echo "")
    value=$(echo "$msg" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" 2>/dev/null || echo "")

    if [ -z "$type" ] || [ -z "$value" ]; then
        echo "bad command: $msg"
        return
    fi

    echo "$(date): received command: $type → $value"

    case "$type" in
        wifi)
            case "$value" in
                hotspot)
                    nmcli connection down raspi-ham-home 2>/dev/null || true
                    nmcli connection up raspi-ham-hotspot 2>/dev/null || true
                    ;;
                home)
                    nmcli connection down raspi-ham-hotspot 2>/dev/null || true
                    nmcli connection up raspi-ham-home 2>/dev/null || true
                    ;;
            esac
            ;;
        mode)
            "$SCRIPTS_DIR/mode-switch.sh" "$value" 2>/dev/null || true
            ;;
        bias_t)
            case "$value" in
                on)  /usr/local/bin/rtl_biast -b 1 2>/dev/null || true ;;
                off) /usr/local/bin/rtl_biast -b 0 2>/dev/null || true ;;
            esac
            ;;
    esac

    # report back after applying
    sleep 2
    report_status
}

echo "raspi-ham MQTT remote control starting..."
echo "  broker: $MQTT_HOST:$MQTT_PORT"
echo "  topic:  $MQTT_TOPIC_CMD"

# report initial status
report_status

# subscribe and process commands forever
# mosquitto_sub reconnects automatically with --retry-connect
mosquitto_sub \
    -h "$MQTT_HOST" \
    -p "$MQTT_PORT" \
    -u "$MQTT_USER" \
    -P "$MQTT_PASS" \
    --capath /etc/ssl/certs \
    -t "$MQTT_TOPIC_CMD" \
    -q 1 \
    --retry-connect 10 \
    -v | while read -r topic msg; do
        handle_command "$msg" &
    done
