#!/bin/bash
#
# Atomic Pi Setup Script
# Sets up a fresh Ubuntu 24.04 Atomic Pi with all hardware support
# and the Strands AI agent powered by Amazon Bedrock.
#
# Prerequisites:
#   - Fresh Ubuntu 24.04 Server install on Atomic Pi
#   - Network connectivity (WiFi or Ethernet)
#   - SSM hybrid activation already registered (for AWS credentials)
#
# Usage:
#   sudo ./setup-atomicpi.sh
#
# What this script does:
#   1. System packages and groups
#   2. GPIO access (udev rules, gpio group)
#   3. i2c-gpio-custom kernel module (for BNO055 on bus 50)
#   4. BNO055 IMU setup (instantiate device on i2c-50)
#   5. XMOS audio auto-reset (systemd service)
#   6. GeoCam camera firmware loader (udev rule)
#   7. Strands AI agent (Python venv + script)
#   8. Blacklist SOF audio (suppress harmless error)
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

AGENT_DIR="/opt/atomicpi/venv"
AGENT_SCRIPT="/opt/atomicpi/atomicpi_agent.py"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GEOCAM_DIR="/opt/geocam"
I2C_GPIO_VER="0.1.2"
BEDROCK_REGION="us-west-2"
BEDROCK_MODEL="us.anthropic.claude-sonnet-4-20250514"
ATOMICPI_MDNS_NAME="$(hostname -s)"

# GPIO numbers for BNO055 I2C bus
# These are global GPIO numbers: gpiochip0 base (414) + line offset
BNO055_SDA=574  # gpiochip0 line 62 (but global number depends on kernel)
BNO055_SCL=578  # gpiochip0 line 66

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Checks ─────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo ./setup-atomicpi.sh)"
    exit 1
fi

if [[ -z "${SUDO_USER:-}" ]]; then
    warn "SUDO_USER not set. Defaulting to 'thjared'"
    SUDO_USER="thjared"
fi

info "Setting up Atomic Pi for user: $SUDO_USER"
echo ""

# ─── 1. System Packages ─────────────────────────────────────────────────────

info "Installing system packages..."
apt update -qq
apt install -y -qq \
    build-essential \
    dkms \
    linux-headers-$(uname -r) \
    gpiod \
    i2c-tools \
    alsa-utils \
    espeak-ng \
    opus-tools \
    pulseaudio \
    util-linux-extra \
    git \
    python3-pip \
    python3-venv \
    v4l-utils \
    avahi-daemon \
    libnss-mdns \
    openssl \
    vim \
    zsh \
    > /dev/null 2>&1
ok "System packages installed"

# ─── 1a. Hostname and mDNS ──────────────────────────────────────────────────

info "Configuring mDNS for the current hostname (${ATOMICPI_MDNS_NAME}.local)..."

cat > /etc/avahi/services/atomicpi-agent.service << 'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Atomic Pi Agent on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>5000</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
EOF

systemctl enable --now avahi-daemon
ok "mDNS enabled (${ATOMICPI_MDNS_NAME}.local)"

# ─── 1b. Amazon SSM Agent ────────────────────────────────────────────────────

info "Installing Amazon SSM Agent..."
if snap list amazon-ssm-agent &>/dev/null; then
    ok "SSM Agent already installed"
else
    snap install amazon-ssm-agent --classic
    ok "SSM Agent installed"
fi
echo ""
echo -e "${YELLOW}  To register with SSM after setup, run:${NC}"
echo "    sudo /snap/amazon-ssm-agent/current/amazon-ssm-agent -register \\"
echo "      -code \"<activation-code>\" -id \"<activation-id>\" -region us-west-2"
echo "    sudo snap restart amazon-ssm-agent"
echo ""

# ─── 1c. Shell Environment (oh-my-zsh) ──────────────────────────────────────

info "Setting up oh-my-zsh for $SUDO_USER..."

if [[ -d "/home/$SUDO_USER/.oh-my-zsh" ]]; then
    ok "oh-my-zsh already installed"
else
    sudo -u "$SUDO_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    ok "oh-my-zsh installed"
fi

# Update plugins
sudo -u "$SUDO_USER" sed -i 's/plugins=(git)/plugins=(git aws)/g' "/home/$SUDO_USER/.zshrc"

# Update theme
sudo -u "$SUDO_USER" sed -i 's/robbyrussell/pygmalion/g' "/home/$SUDO_USER/.zshrc"

# Add PATH and aliases
grep -q 'export PATH=\$PATH:\$HOME/bin' "/home/$SUDO_USER/.zshrc" || \
    echo 'export PATH=$PATH:$HOME/bin' >> "/home/$SUDO_USER/.zshrc"
grep -q 'alias ip="ip -c"' "/home/$SUDO_USER/.zshrc" || \
    echo 'alias ip="ip -c"' >> "/home/$SUDO_USER/.zshrc"

# Set zsh as default shell
chsh -s /usr/bin/zsh "$SUDO_USER" 2>/dev/null || true
ok "Shell configured (zsh + pygmalion theme)"

# ─── 2. GPIO Access ─────────────────────────────────────────────────────────

info "Setting up GPIO access..."

# Create gpio group
groupadd -f gpio
usermod -aG gpio "$SUDO_USER"

# Create i2c group
groupadd -f i2c
usermod -aG i2c "$SUDO_USER"

# Add user to audio and video groups
usermod -aG audio "$SUDO_USER"
usermod -aG video "$SUDO_USER"

# GPIO udev rules
cat > /etc/udev/rules.d/99-gpio.rules << 'EOF'
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="gpio", KERNEL=="gpio*", GROUP="gpio", MODE="0660"
EOF

# I2C udev rules
cat > /etc/udev/rules.d/99-i2c.rules << 'EOF'
SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"
EOF

udevadm control --reload-rules
udevadm trigger
ok "GPIO/I2C access configured (groups: gpio, i2c, audio, video)"

# ─── 3. i2c-gpio-custom Kernel Module ───────────────────────────────────────

info "Building i2c-gpio-custom kernel module..."

if dkms status | grep -q "i2c-gpio-custom"; then
    info "i2c-gpio-custom already installed, skipping..."
else
    TMPDIR=$(mktemp -d)
    git clone -q https://github.com/JaredLThompson/i2c-gpio-custom.git "$TMPDIR/i2c-gpio-custom"

    install -d "/usr/src/i2c-gpio-custom-${I2C_GPIO_VER}"
    cp -a "$TMPDIR/i2c-gpio-custom/." "/usr/src/i2c-gpio-custom-${I2C_GPIO_VER}/"

    dkms add -m i2c-gpio-custom -v "$I2C_GPIO_VER" 2>/dev/null || true
    dkms build -m i2c-gpio-custom -v "$I2C_GPIO_VER"
    dkms install -m i2c-gpio-custom -v "$I2C_GPIO_VER"

    rm -rf "$TMPDIR"
fi
ok "i2c-gpio-custom module installed"

# ─── 4. BNO055 IMU Setup ────────────────────────────────────────────────────

info "Setting up BNO055 IMU on I2C bus 50..."

# Create systemd service to load i2c-gpio-custom and instantiate BNO055
cat > /etc/systemd/system/atomicpi-bno055.service << EOF
[Unit]
Description=Atomic Pi BNO055 IMU Setup
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe i2c-gpio && modprobe i2c-gpio-custom bus0=50,${BNO055_SDA},${BNO055_SCL} && sleep 0.5 && echo bno055 0x28 > /sys/bus/i2c/devices/i2c-50/new_device'
ExecStop=/bin/bash -c 'echo 0x28 > /sys/bus/i2c/devices/i2c-50/delete_device 2>/dev/null; rmmod i2c-gpio-custom 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable atomicpi-bno055.service
ok "BNO055 service configured (I2C bus 50, address 0x28)"

# ─── 5. XMOS Audio Reset ────────────────────────────────────────────────────

info "Setting up XMOS audio auto-reset..."

cat > /etc/systemd/system/xmos-audio-reset.service << 'EOF'
[Unit]
Description=Reset XMOS Audio Processor
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'gpioset gpiochip1 8=0 & PID=$$!; sleep 0.1; kill $$PID; wait $$PID 2>/dev/null; gpioset gpiochip1 8=1 & PID=$$!; sleep 0.5; kill $$PID; wait $$PID 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xmos-audio-reset.service
ok "XMOS audio reset service enabled"

# ─── 6. GeoCam Camera Firmware ──────────────────────────────────────────────

info "Setting up GeoCam camera firmware loader..."

mkdir -p "$GEOCAM_DIR"

if [[ ! -f "$GEOCAM_DIR/mxcam" ]]; then
    TMPDIR=$(mktemp -d)
    git clone -q https://github.com/JaredLThompson/geocam-bin.git "$TMPDIR/geocam-bin"
    cp "$TMPDIR/geocam-bin/mxcam" "$GEOCAM_DIR/"
    cp "$TMPDIR/geocam-bin/gc6500_ddrboot_fw.img" "$GEOCAM_DIR/"
    cp "$TMPDIR/geocam-bin/config.json" "$GEOCAM_DIR/"
    cp "$TMPDIR/geocam-bin/sensor_ov2710_mayfield_le.bin" "$GEOCAM_DIR/"
    chmod +x "$GEOCAM_DIR/mxcam"
    rm -rf "$TMPDIR"
fi

cat > /etc/udev/rules.d/99-geocam.rules << 'EOF'
ATTR{idVendor}=="29fe", ATTR{idProduct}=="b00c", MODE="0660", OWNER="root", GROUP="video", RUN+="/opt/geocam/mxcam boot /opt/geocam/gc6500_ddrboot_fw.img /opt/geocam/config.json /opt/geocam/sensor_ov2710_mayfield_le.bin"
EOF

udevadm control --reload-rules
ok "GeoCam firmware loader configured"

# ─── 7. Blacklist SOF Audio ─────────────────────────────────────────────────

info "Blacklisting SOF audio driver (not needed, uses XMOS instead)..."
echo "blacklist snd_sof_acpi_intel_byt" > /etc/modprobe.d/blacklist-sof-byt.conf
ok "SOF audio blacklisted"

# ─── 8. Python Agent Environment ────────────────────────────────────────────

info "Setting up Python virtual environment for AI agent..."

if [[ "$SCRIPT_DIR" != "/opt/atomicpi" && -f "$SCRIPT_DIR/atomicpi_agent.py" ]]; then
    mkdir -p /opt/atomicpi/static /opt/atomicpi/tools
    install -m 0755 "$SCRIPT_DIR/atomicpi_agent.py" "$AGENT_SCRIPT"
    install -m 0644 "$SCRIPT_DIR/static/index.html" /opt/atomicpi/static/index.html
elif [[ ! -f /opt/atomicpi/atomicpi_agent.py ]]; then
    git clone -q https://github.com/JaredLThompson/AtomicPi.git /opt/atomicpi
fi

python3 -m venv "$AGENT_DIR"
"$AGENT_DIR/bin/pip" install -q \
    strands-agents \
    strands-agents-tools \
    smbus2 \
    opencv-python-headless \
    flask

# Keep deployed files manageable by the setup user. The agent service runs as
# root because SSM hybrid credentials are maintained under /root/.aws.
chown -R "$SUDO_USER:$SUDO_USER" /opt/atomicpi

ok "Python venv created at $AGENT_DIR"

# ─── 8b. RTC and NTP Time Sync ───────────────────────────────────────────────

info "Setting up NTP time sync and RTC..."
apt install -y -qq systemd-timesyncd > /dev/null 2>&1
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
# Sync hardware clock to system time
hwclock --systohc 2>/dev/null || true
ok "Time sync enabled, RTC synced"

# ─── 9. Agent Systemd Service ───────────────────────────────────────────────

info "Setting up agent systemd service..."

if [[ ! -f /etc/atomicpi-agent.env ]]; then
    umask 0077
    printf '%s\nATOMICPI_API_TOKEN=%s\n%s\nATOMICPI_ENABLE_SELF_MODIFICATION=0\n' \
        '# Bearer token required by every protected HTTP API endpoint.' \
        "$(openssl rand -hex 32)" \
        '# Set to 1 to let the agent create and load Python tools in /opt/atomicpi/tools.' \
        > /etc/atomicpi-agent.env
fi
chown root:"$SUDO_USER" /etc/atomicpi-agent.env
chmod 0640 /etc/atomicpi-agent.env

cat > /etc/systemd/system/atomicpi-agent.service << EOF
[Unit]
Description=Atomic Pi AI Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=${AGENT_DIR}/bin/python3 ${AGENT_SCRIPT} --mode server --host 0.0.0.0
Restart=always
RestartSec=5
Environment=HOME=/root
EnvironmentFile=/etc/atomicpi-agent.env
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/atomicpi

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable atomicpi-agent.service
ok "Agent service enabled (starts on boot in server mode, port 5000)"

# ─── 10. Summary ────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Atomic Pi Setup Complete!                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Hardware configured:"
echo "  ✅ GPIO access (gpiochip0-3, udev rules)"
echo "  ✅ I2C bus 50 (BNO055 IMU at 0x28)"
echo "  ✅ XMOS audio (auto-resets at boot)"
echo "  ✅ GeoCam camera (auto-loads firmware)"
echo "  ✅ SOF audio blacklisted"
echo ""
echo "Software installed:"
echo "  ✅ gpiod, i2c-tools, alsa-utils, v4l-utils, espeak-ng"
echo "  ✅ i2c-gpio-custom DKMS module"
echo "  ✅ Amazon SSM Agent"
echo "  ✅ Python venv: $AGENT_DIR"
echo "  ✅ strands-agents, opencv, smbus2, flask"
echo ""
echo "Services enabled:"
echo "  ✅ atomicpi-bno055.service  (IMU on I2C bus 50)"
echo "  ✅ xmos-audio-reset.service (XMOS audio at boot)"
echo "  ✅ atomicpi-agent.service   (AI agent API on port 5000)"
echo "  ✅ avahi-daemon             (${ATOMICPI_MDNS_NAME}.local)"
echo "  🔒 Custom tool creation/loading is disabled by default"
echo ""
echo "Next steps:"
echo "  1. Register with SSM so its rotating Bedrock credentials are available"
echo "     under /root/.aws/credentials to the root-run agent service:"
echo "     sudo /snap/amazon-ssm-agent/current/amazon-ssm-agent -register \\"
echo "       -code \"<code>\" -id \"<id>\" -region us-west-2"
echo "     sudo snap restart amazon-ssm-agent"
echo ""
echo "  2. Reboot to activate all services:"
echo "     sudo reboot"
echo ""
echo "  3. After reboot, verify:"
echo "     curl http://localhost:5000/health"
echo "     TOKEN=\$(sudo sed -n 's/^ATOMICPI_API_TOKEN=//p' /etc/atomicpi-agent.env)"
echo "     curl -X POST http://localhost:5000/ask \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -H \"Authorization: Bearer \$TOKEN\" \\"
echo "       -d '{\"message\": \"Hello! Blink your LEDs.\"}'"
echo ""
echo "     Web UI: http://${ATOMICPI_MDNS_NAME}.local:5000"
echo "     Token: sudo sed -n 's/^ATOMICPI_API_TOKEN=//p' /etc/atomicpi-agent.env"
echo ""
echo "  Custom Python tools:"
echo "     Disabled by default with ATOMICPI_ENABLE_SELF_MODIFICATION=0."
echo "     Set it to 1 in /etc/atomicpi-agent.env and restart atomicpi-agent"
echo "     to let the agent create/load /opt/atomicpi/tools/*.py."
echo -e "     ${YELLOW}WARNING: custom tools execute as root.${NC}"
echo ""
echo -e "${YELLOW}NOTE: Log out and back in for group membership to take effect.${NC}"
