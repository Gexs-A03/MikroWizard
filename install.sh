#!/usr/bin/env bash

set -e

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

APP="mikrowizard"
APP_DIR="/opt/${APP}"
SERVICE="${APP}.service"

msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok()   { echo -e "${GN}[OK]${CL} $1"; }
msg_err()  { echo -e "${RD}[ERROR]${CL} $1"; }

# ------------------------------------------------------------
# Environment Checks
# ------------------------------------------------------------

if ! command -v apt >/dev/null 2>&1; then
    msg_err "This installer is designed for Debian/Ubuntu-based Proxmox LXCs."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    msg_err "Please run as root inside the LXC."
    exit 1
fi

# ------------------------------------------------------------
# Install Dependencies
# ------------------------------------------------------------

msg_info "Updating container"
apt update -y && apt upgrade -y
msg_ok "System updated"

msg_info "Installing dependencies"
apt install -y curl wget git python3 python3-pip ffmpeg jq unzip
msg_ok "Dependencies installed"

# ------------------------------------------------------------
# Download Application
# ------------------------------------------------------------

msg_info "Creating application directory"
mkdir -p "$APP_DIR"
cd "$APP_DIR"
msg_ok "Directory ready"

msg_info "Downloading Mikrowizard"
wget -qO installer.sh \
  https://gist.githubusercontent.com/s265925/84f8fdc90c8b330a1501626a50e983a1/raw/b1fc4e0f283fd48d78861fa1a665fd1cb19b734d/installer.sh
msg_ok "Installer downloaded"

msg_info "Patching installer for LXC"
sed -i 's/docker.*//g' installer.sh
sed -i 's/compose.*//g' installer.sh
sed -i 's/systemctl.*//g' installer.sh
sed -i 's/\/opt\/freidntl/'"$APP_DIR"'/g' installer.sh
msg_ok "Installer patched"

msg_info "Running installer"
bash installer.sh
msg_ok "Mikrowizard installed"

# ------------------------------------------------------------
# Systemd Service
# ------------------------------------------------------------

msg_info "Creating systemd service"

cat <<EOF >/etc/systemd/system/${SERVICE}
[Unit]
Description=Mikrowizard Service
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/main.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE}
systemctl start ${SERVICE}

msg_ok "Service created and started"

# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------

msg_ok "Mikrowizard installation complete"
echo -e "${GN}Access Mikrowizard via the container's IP on its configured port.${CL}"