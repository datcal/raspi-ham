#!/usr/bin/env bash
# raspi-ham installer
# run on a fresh raspberry pi os lite (bookworm):
#   curl -sL https://raw.githubusercontent.com/datcal/raspi-ham/main/install.sh | sudo bash
set -euo pipefail

REPO_URL="https://github.com/datcal/raspi-ham.git"
INSTALL_DIR="/opt/raspi-ham"
CONFIG_DIR="/etc/raspi-ham"
BUILD_DIR="/var/tmp/raspi-ham-build"
LOG_FILE="/var/log/raspi-ham-install.log"

TOTAL_STEPS=20
CURRENT_STEP=0

# colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "${GREEN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} $1"
}

warn() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

die() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    exit 1
}

cleanup() {
    rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# start logging
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== raspi-ham install started $(date) ==="

# ---- checks ----

step "checking prerequisites..."

if [ "$EUID" -ne 0 ]; then
    die "run as root: sudo bash install.sh"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "raspbian" ] && [ "${ID:-}" != "debian" ]; then
        warn "expected raspberry pi os, got $ID. continuing anyway..."
    fi
else
    warn "can't detect OS, continuing anyway..."
fi

ARCH=$(uname -m)
if [ "$ARCH" != "armv6l" ] && [ "$ARCH" != "armv7l" ] && [ "$ARCH" != "aarch64" ]; then
    warn "expected ARM architecture, got $ARCH. this is meant for raspberry pi."
fi

echo "  os: ${PRETTY_NAME:-unknown}"
echo "  arch: $ARCH"
echo "  kernel: $(uname -r)"

# ---- system update ----

# prevent interactive prompts during install (like the wireshark dialog)
export DEBIAN_FRONTEND=noninteractive
echo 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections

step "updating system packages (this takes a while on pi zero)..."
apt-get update -qq
apt-get upgrade -y -qq

# ---- dependencies ----

step "installing build dependencies..."
apt-get install -y -qq \
    git \
    cmake \
    build-essential \
    pkg-config \
    libusb-1.0-0-dev \
    libncurses-dev \
    python3 \
    python3-pip \
    python3-gpiozero \
    python3-lgpio \
    ufw \
    unattended-upgrades \
    dkms \
    bc \
    linux-headers-rpi-v6 \
    aircrack-ng \
    tcpdump \
    tshark \
    horst \
    iw \
    mosquitto-clients \
    tmux

# ---- blacklist dvb-t drivers ----

step "blacklisting DVB-T kernel drivers..."
cat > /etc/modprobe.d/blacklist-rtlsdr.conf << 'EOF'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

# unload if currently loaded
rmmod dvb_usb_rtl28xxu 2>/dev/null || true
rmmod rtl2832 2>/dev/null || true
rmmod rtl2830 2>/dev/null || true

# ---- build rtl-sdr blog drivers ----

step "building RTL-SDR Blog drivers from source..."
if command -v rtl_tcp &>/dev/null; then
    echo "  rtl-sdr already installed, skipping build"
else
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    rm -rf rtl-sdr-blog
    git clone --depth 1 https://github.com/rtlsdrblog/rtl-sdr-blog.git
    cd rtl-sdr-blog
    mkdir -p build && cd build
    cmake .. -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
    make -j1  # pi zero has 1 core, -j1 prevents OOM
    make install
    ldconfig
    cp "$BUILD_DIR/rtl-sdr-blog/rtl-sdr.rules" /etc/udev/rules.d/20-rtlsdr.rules
    udevadm control --reload-rules
    udevadm trigger
    rm -rf "$BUILD_DIR/rtl-sdr-blog"
fi

# ---- install dump1090-fa ----

step "installing dump1090-fa..."
if [ -f /usr/bin/dump1090-fa ]; then
    echo "  dump1090-fa already installed, skipping"
else
    # try apt first
    if apt-get install -y -qq dump1090-fa 2>/dev/null; then
        echo "  installed dump1090-fa from apt"
    else
        # fallback: build from source
        warn "dump1090-fa not in apt, building from source..."
        mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
        rm -rf dump1090
        git clone --depth 1 https://github.com/flightaware/dump1090.git
        cd dump1090
        make -j1
        cp dump1090 /usr/bin/dump1090-fa
        rm -rf "$BUILD_DIR/dump1090"
    fi
fi

# disable by default (conflicts with rtl_tcp)
systemctl stop dump1090-fa 2>/dev/null || true
systemctl disable dump1090-fa 2>/dev/null || true

# ---- build rtl8812au driver (USB WiFi adapter for monitor mode) ----

step "(optional) building RTL8812AU WiFi driver..."
if modinfo 88XXau &>/dev/null; then
    echo "  rtl8812au driver already installed, skipping"
else
    cd "$BUILD_DIR"
    rm -rf rtl8812au
    git clone --depth 1 https://github.com/aircrack-ng/rtl8812au.git
    cd rtl8812au

    # set platform for Pi Zero W (ARM)
    sed -i 's/CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' Makefile
    sed -i 's/CONFIG_PLATFORM_ARM_RPI = n/CONFIG_PLATFORM_ARM_RPI = y/' Makefile

    if make -j1; then
        make install
        modprobe 88XXau 2>/dev/null || true
        echo "  rtl8812au driver installed (supports monitor mode + injection)"
    else
        warn "rtl8812au build failed (Pi Zero W may not have enough RAM)"
        warn "WiFi monitor mode won't work, but everything else will"
        warn "you can try building it later when the Pi is idle:"
        warn "  cd /var/tmp/raspi-ham-build/rtl8812au && sudo make -j1 && sudo make install"
    fi
fi

# ---- create service user ----

step "creating rtlsdr service user..."
if ! id rtlsdr &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -G plugdev rtlsdr
    echo "  created user: rtlsdr"
else
    echo "  user rtlsdr already exists"
fi

# ---- create captures directory ----

step "setting up WiFi capture directory..."
mkdir -p /opt/raspi-ham/captures
chown rtlsdr:rtlsdr /opt/raspi-ham/captures
echo "  captures will be saved to /opt/raspi-ham/captures"

# ---- clone repo ----

step "cloning raspi-ham repo..."
if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    git pull
    echo "  updated existing install"
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    echo "  cloned to $INSTALL_DIR"
fi

# make scripts executable
chmod +x "$INSTALL_DIR"/scripts/*.sh

# ---- config ----

step "setting up config..."
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/wifi.conf" ]; then
    cp "$INSTALL_DIR/config/wifi.conf.template" "$CONFIG_DIR/wifi.conf"
    chmod 600 "$CONFIG_DIR/wifi.conf"
    echo "  created $CONFIG_DIR/wifi.conf (edit this with your WiFi creds)"
else
    echo "  $CONFIG_DIR/wifi.conf already exists, not overwriting"
fi

if [ ! -f "$CONFIG_DIR/rtl-tcp.conf" ]; then
    cp "$INSTALL_DIR/config/rtl-tcp.conf" "$CONFIG_DIR/rtl-tcp.conf"
    echo "  created $CONFIG_DIR/rtl-tcp.conf"
else
    echo "  $CONFIG_DIR/rtl-tcp.conf already exists, not overwriting"
fi

if [ ! -f "$CONFIG_DIR/remote.conf" ]; then
    cp "$INSTALL_DIR/config/remote.conf.template" "$CONFIG_DIR/remote.conf"
    chmod 600 "$CONFIG_DIR/remote.conf"
    echo "  created $CONFIG_DIR/remote.conf (edit with your MQTT broker creds)"
else
    echo "  $CONFIG_DIR/remote.conf already exists, not overwriting"
fi

# ---- systemd services ----

step "installing systemd services..."
cp "$INSTALL_DIR/systemd/rtl-tcp.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/raspi-ham-dump1090.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/wifi-switch.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/raspi-ham-remote.service" /etc/systemd/system/
systemctl daemon-reload

systemctl enable rtl-tcp.service
systemctl enable wifi-switch.service
systemctl enable raspi-ham-remote.service
# dump1090 stays disabled - start manually with: raspi-ham-mode adsb
echo "  enabled: rtl-tcp, wifi-switch, remote-control"
echo "  disabled (on-demand): raspi-ham-dump1090"

# ---- dump1090 runtime dir ----

mkdir -p /run/dump1090-fa
chown rtlsdr:rtlsdr /run/dump1090-fa

# ---- firewall ----

step "configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 1234/tcp comment 'rtl_tcp'
ufw allow 8080/tcp comment 'dump1090 web'
ufw allow 30005/tcp comment 'dump1090 beast'
ufw --force enable
echo "  firewall active: SSH(22), rtl_tcp(1234), dump1090(8080,30005)"

# ---- pi tweaks ----

step "optimizing pi config..."

# minimize GPU memory (headless, no display)
CONFIG_TXT="/boot/firmware/config.txt"
if [ ! -f "$CONFIG_TXT" ]; then
    CONFIG_TXT="/boot/config.txt"  # older pi os
fi

if [ -f "$CONFIG_TXT" ]; then
    if ! grep -q 'gpu_mem=' "$CONFIG_TXT"; then
        echo 'gpu_mem=16' >> "$CONFIG_TXT"
        echo "  set gpu_mem=16"
    else
        echo "  gpu_mem already configured"
    fi
fi

# ---- SSH ----

step "enabling SSH + tmux auto-attach..."
systemctl enable ssh
systemctl start ssh

# auto-start tmux on SSH login so you can resume sessions from any device
# only triggers on interactive SSH sessions, not scp/sftp
TMUX_AUTOSTART='
# raspi-ham: auto-attach tmux on SSH login
if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ] && command -v tmux &>/dev/null; then
    tmux attach-session -t ham 2>/dev/null || tmux new-session -s ham
fi'

# add to the actual user's bashrc (not root)
REAL_USER="${SUDO_USER:-datcal}"
REAL_HOME=$(eval echo "~$REAL_USER")
if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q "raspi-ham: auto-attach tmux" "$REAL_HOME/.bashrc"; then
    echo "$TMUX_AUTOSTART" >> "$REAL_HOME/.bashrc"
    echo "  tmux auto-attach enabled for $REAL_USER"
fi

# tmux config: show useful status bar
if [ ! -f "$REAL_HOME/.tmux.conf" ]; then
    cat > "$REAL_HOME/.tmux.conf" << 'TMUXCONF'
# raspi-ham tmux config
set -g mouse on
set -g history-limit 10000
set -g status-bg black
set -g status-fg green
set -g status-left '[#S] '
set -g status-right '#(hostname -I | awk "{print $1}") | #(raspi-ham-mode status 2>/dev/null || echo "?") | %H:%M'
set -g status-right-length 60
TMUXCONF
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.tmux.conf"
    echo "  tmux config created"
fi

echo "  SSH enabled"

# ---- convenience symlinks ----

step "creating convenience commands..."
ln -sf "$INSTALL_DIR/scripts/mode-switch.sh" /usr/local/bin/raspi-ham-mode
ln -sf "$INSTALL_DIR/scripts/setup-wifi.sh" /usr/local/bin/raspi-ham-setup-wifi
ln -sf "$INSTALL_DIR/scripts/wifi-monitor.sh" /usr/local/bin/raspi-ham-monitor
echo "  raspi-ham-mode       - switch between SDR, ADS-B, monitor"
echo "  raspi-ham-setup-wifi - apply WiFi credentials"
echo "  raspi-ham-monitor    - WiFi capture/scanning tools"

# ---- auto security updates ----

step "enabling automatic security updates..."
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true

# ---- validate ----

step "validating RTL-SDR dongle..."
if timeout 5 rtl_test -t 2>&1 | head -5; then
    echo -e "  ${GREEN}dongle detected!${NC}"
else
    warn "dongle not detected. plug it in and try: rtl_test -t"
fi

# ---- done ----

echo ""
echo "============================================"
echo -e "${GREEN} raspi-ham installed successfully!${NC}"
echo "============================================"
echo ""
echo "next steps:"
echo ""
echo "  1. edit your WiFi credentials:"
echo "     sudo nano /etc/raspi-ham/wifi.conf"
echo ""
echo "  2. apply WiFi config:"
echo "     sudo raspi-ham-setup-wifi"
echo ""
echo "  3. reboot:"
echo "     sudo reboot"
echo ""
echo "  4. connect your iPad to the same network"
echo "     open your SDR app, connect to this pi's IP on port 1234"
echo ""
echo "useful commands:"
echo "  raspi-ham-mode sdr       - start SDR mode (rtl_tcp)"
echo "  raspi-ham-mode adsb      - start ADS-B mode (dump1090)"
echo "  raspi-ham-mode status    - check current mode"
echo "  raspi-ham-monitor scan   - scan nearby WiFi networks"
echo "  raspi-ham-monitor capture - capture packets to pcap"
echo "  journalctl -u rtl-tcp -f   - watch rtl_tcp logs"
echo "  journalctl -u wifi-switch -f - watch button press logs"
echo ""
echo "log saved to: $LOG_FILE"
echo "=== raspi-ham install finished $(date) ==="
