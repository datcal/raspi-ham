#!/usr/bin/env bash
# apply wifi credentials from config file to NetworkManager
set -euo pipefail

CONFIG="/etc/raspi-ham/wifi.conf"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    echo "copy the template first:"
    echo "  sudo cp /opt/raspi-ham/config/wifi.conf.template /etc/raspi-ham/wifi.conf"
    echo "  sudo nano /etc/raspi-ham/wifi.conf"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

# don't let people run this with placeholder creds
if [ "$HOTSPOT_PSK" = "change-me" ] || [ "$HOME_PSK" = "change-me" ]; then
    echo "ERROR: edit $CONFIG first - still has placeholder passwords"
    exit 1
fi

# clean up old profiles
nmcli connection delete raspi-ham-hotspot 2>/dev/null || true
nmcli connection delete raspi-ham-home 2>/dev/null || true

# create hotspot profile (iphone AP)
nmcli connection add type wifi con-name raspi-ham-hotspot \
    ssid "$HOTSPOT_SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$HOTSPOT_PSK" \
    connection.autoconnect no \
    connection.autoconnect-priority 10

# create home wifi profile
nmcli connection add type wifi con-name raspi-ham-home \
    ssid "$HOME_SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$HOME_PSK" \
    connection.autoconnect yes \
    connection.autoconnect-priority 20

# set default boot network
if [ "${DEFAULT_NETWORK:-home}" = "hotspot" ]; then
    nmcli connection modify raspi-ham-hotspot connection.autoconnect yes
    nmcli connection modify raspi-ham-home connection.autoconnect no
fi

echo "done! wifi profiles configured:"
echo "  hotspot: $HOTSPOT_SSID"
echo "  home:    $HOME_SSID"
echo "  default: ${DEFAULT_NETWORK:-home}"
echo ""
echo "reboot or press the buttons to switch networks"
