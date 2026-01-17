#!/usr/bin/env bash

set -e

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
apt update && apt upgrade -y
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
INSTALLER_URL="https://gist.githubusercontent.com/s265925/84f8fdc90c8b330a1501626a50e983a1/raw/b1fc4e0f283fd48d78861fa1a665fd1cb19b734d/installer.sh"
if ! wget -qO installer.sh --timeout=30 --tries=3 "$INSTALLER_URL"; then
    msg_err "Failed to download installer from $INSTALLER_URL"
    exit 1
fi
if [ ! -s installer.sh ] || [ $(stat -c%s installer.sh) -lt 200 ]; then
    msg_err "Downloaded installer looks too small or empty"
    exit 1
fi
msg_ok "Installer downloaded"

msg_info "Patching installer for LXC (safer edits)"
# Remove lines mentioning docker, compose or systemctl (case-insensitive)
sed -i '/docker/Id' installer.sh || true
sed -i '/compose/Id' installer.sh || true
sed -i '/systemctl/Id' installer.sh || true
# Replace known hardcoded path with target app dir
sed -i "s|/opt/freidntl|${APP_DIR}|g" installer.sh || true
msg_ok "Installer patched"

msg_info "Running installer"
bash installer.sh || { msg_err "Installer script failed"; exit 1; }
msg_ok "Mikrowizard installed"

# ------------------------------------------------------------
# Systemd Service
# ------------------------------------------------------------

msg_info "Creating systemd service (if available)"
if command -v systemctl >/dev/null 2>&1; then
  if [ -f "${APP_DIR}/main.py" ]; then
    cat <<EOF >/etc/systemd/system/${SERVICE}
[Unit]
Description=Mikrowizard Service
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/env python3 ${APP_DIR}/main.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE}
    systemctl start ${SERVICE}
    msg_ok "Service created and started"
  else
    msg_info "No main.py found in ${APP_DIR}; skipping systemd unit creation"
  fi
else
  msg_info "systemd not available in this container; skipping service creation"
fi

# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------

msg_ok "Mikrowizard installation complete"
echo -e "${GN}Access Mikrowizard via the container's IP on its configured port.${CL}"