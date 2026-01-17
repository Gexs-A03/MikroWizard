#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------
# Colors & Messages
# ------------------------------------------------------------
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"

msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok()   { echo -e "${GN}[OK]${CL} $1"; }
msg_err()  { echo -e "${RD}[ERROR]${CL} $1"; }

# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------
if ! command -v pveversion >/dev/null 2>&1; then
  msg_err "This script must be run on a Proxmox VE host."
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  msg_info "Installing whiptail for menus"
  apt-get update -y >/dev/null
  apt-get install -y whiptail >/dev/null
  msg_ok "whiptail installed"
fi

# ------------------------------------------------------------
# Helper: get next free CT ID
# ------------------------------------------------------------
get_next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null || echo "200"
}

# ------------------------------------------------------------
# Storage selection (rootdir-capable)
# ------------------------------------------------------------
get_storage_list() {
  awk '
    $1 ~ /^[a-zA-Z0-9_-]+$/ && $1 != "dir" && $1 != "zfspool" { st=$1 }
    /content/ && /rootdir/ { print st }
  ' /etc/pve/storage.cfg 2>/dev/null
}

select_storage() {
  local storages=()
  while IFS= read -r line; do
    storages+=("$line" "" "OFF")
  done < <(get_storage_list)

  if [ ${#storages[@]} -eq 0 ]; then
    msg_err "No storage with 'rootdir' content found in /etc/pve/storage.cfg"
    exit 1
  fi

  whiptail --title "Container Storage" \
    --radiolist "Select storage for the container root disk:" 18 70 8 \
    "${storages[@]}" 3>&1 1>&2 2>&3
}

# ------------------------------------------------------------
# Debian template selection (latest)
# ------------------------------------------------------------
select_debian_template() {
  msg_info "Updating Proxmox template list"
  pveam update >/dev/null 2>&1 || true

  local latest
  latest=$(pveam available | awk '/debian-.*-standard_.*_amd64\.tar\.zst/ {print $2}' | sort -V | tail -n1)

  if [ -z "${latest:-}" ]; then
    msg_err "No Debian standard template found via pveam."
    exit 1
  fi

  echo "$latest"
}

# ------------------------------------------------------------
# Menu: basic CT parameters
# ------------------------------------------------------------
CTID_DEFAULT=$(get_next_ctid)
HOSTNAME_DEFAULT="mikrowizard"
DISK_DEFAULT="8"
RAM_DEFAULT="1024"
CORE_DEFAULT="2"

CTID=$(whiptail --inputbox "Enter CT ID" 10 60 "$CTID_DEFAULT" --title "Container ID" 3>&1 1>&2 2>&3) || exit 1
HN=$(whiptail --inputbox "Enter hostname" 10 60 "$HOSTNAME_DEFAULT" --title "Hostname" 3>&1 1>&2 2>&3) || exit 1
STORAGE=$(select_storage)
DISK_SIZE=$(whiptail --inputbox "Disk size (GB)" 10 60 "$DISK_DEFAULT" --title "Disk Size" 3>&1 1>&2 2>&3) || exit 1
RAM=$(whiptail --inputbox "Memory (MB)" 10 60 "$RAM_DEFAULT" --title "Memory" 3>&1 1>&2 2>&3) || exit 1
CORES=$(whiptail --inputbox "CPU cores" 10 60 "$CORE_DEFAULT" --title "CPU Cores" 3>&1 1>&2 2>&3) || exit 1

# ------------------------------------------------------------
# Network configuration
# ------------------------------------------------------------
NET_MODE=$(whiptail --title "Network Mode" --radiolist "Select network configuration:" 15 60 4 \
  "dhcp"  "Use DHCP" ON \
  "static" "Use static IP" OFF 3>&1 1>&2 2>&3) || exit 1

BRIDGE_DEFAULT="vmbr0"
VLAN_DEFAULT=""
IP_DEFAULT="192.168.1.50/24"
GW_DEFAULT="192.168.1.1"

BRIDGE=$(whiptail --inputbox "Linux bridge" 10 60 "$BRIDGE_DEFAULT" --title "Bridge" 3>&1 1>&2 2>&3) || exit 1
VLAN_TAG=$(whiptail --inputbox "VLAN tag (empty for none)" 10 60 "$VLAN_DEFAULT" --title "VLAN Tag" 3>&1 1>&2 2>&3) || exit 1

if [ "$NET_MODE" = "static" ]; then
  IPADDR=$(whiptail --inputbox "Static IP (CIDR)" 10 60 "$IP_DEFAULT" --title "Static IP" 3>&1 1>&2 2>&3) || exit 1
  GATEWAY=$(whiptail --inputbox "Gateway IP" 10 60 "$GW_DEFAULT" --title "Gateway" 3>&1 1>&2 2>&3) || exit 1
else
  IPADDR="dhcp"
  GATEWAY=""
fi

# ------------------------------------------------------------
# Root password
# ------------------------------------------------------------
ROOT_PW=$(whiptail --passwordbox "Set root password for the container" 10 60 --title "Root Password" 3>&1 1>&2 2>&3) || exit 1

# ------------------------------------------------------------
# Summary & confirmation
# ------------------------------------------------------------
SUMMARY="CT ID:        $CTID
Hostname:     $HN
Storage:      $STORAGE
Disk:         ${DISK_SIZE}G
RAM:          ${RAM}MB
Cores:        $CORES
Bridge:       $BRIDGE
VLAN:         ${VLAN_TAG:-none}
IP mode:      $NET_MODE
IP address:   ${IPADDR:-dhcp}
Gateway:      ${GATEWAY:-auto}
Template:     latest Debian standard"

whiptail --title "Confirm Settings" --yesno "$SUMMARY" 20 70 3>&1 1>&2 2>&3 || {
  msg_err "User cancelled."
  exit 1
}

# ------------------------------------------------------------
# Get template & create CT
# ------------------------------------------------------------
TEMPLATE=$(select_debian_template)
msg_ok "Using template: $TEMPLATE"

msg_info "Ensuring template is present on storage '$STORAGE'"
if ! pveam list "$STORAGE" | grep -q "$TEMPLATE"; then
  msg_info "Downloading template to $STORAGE"
  pveam download "$STORAGE" "$TEMPLATE" >/dev/null
  msg_ok "Template downloaded"
fi

NETCONF="name=eth0,bridge=${BRIDGE}"
[ -n "$VLAN_TAG" ] && NETCONF="${NETCONF},tag=${VLAN_TAG}"
if [ "$NET_MODE" = "static" ]; then
  NETCONF="${NETCONF},ip=${IPADDR},gw=${GATEWAY}"
else
  NETCONF="${NETCONF},ip=dhcp"
fi

msg_info "Creating container CT $CTID"
pct create "$CTID" "${STORAGE}:vztmpl/${TEMPLATE}" \
  -hostname "$HN" \
  -password "$ROOT_PW" \
  -storage "$STORAGE" \
  -rootfs "${STORAGE}:${DISK_SIZE}" \
  -memory "$RAM" \
  -cores "$CORES" \
  -net0 "$NETCONF" \
  -features nesting=1 \
  -ostype debian \
  -unprivileged 1 >/dev/null

msg_ok "Container created"

msg_info "Starting container"
pct start "$CTID"
sleep 5
msg_ok "Container started"

# ------------------------------------------------------------
# Inside-CT installer (your Mikrowizard logic)
# ------------------------------------------------------------
msg_info "Installing Mikrowizard inside CT $CTID"

pct exec "$CTID" -- bash -s <<'EOF_CT'
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

if ! command -v apt >/dev/null 2>&1; then
    msg_err "This installer is designed for Debian-based containers."
    exit 1
fi

msg_info "Updating container"
apt-get update -y >/dev/null
apt-get upgrade -y >/dev/null
msg_ok "System updated"

msg_info "Installing dependencies"
apt-get install -y curl wget git python3 python3-pip ffmpeg jq unzip >/dev/null
msg_ok "Dependencies installed"

msg_info "Creating application directory"
mkdir -p "$APP_DIR"
cd "$APP_DIR"
msg_ok "Directory ready"

msg_info "Downloading Mikrowizard installer"
INSTALLER_URL="https://gist.githubusercontent.com/s265925/84f8fdc90c8b330a1501626a50e983a1/raw/b1fc4e0f283fd48d78861fa1a665fd1cb19b734d/installer.sh"
if ! wget -qO installer.sh --timeout=30 --tries=3 "$INSTALLER_URL"; then
    msg_err "Failed to download installer from $INSTALLER_URL"
    exit 1
fi
if [ ! -s installer.sh ] || [ \$(stat -c%s installer.sh) -lt 200 ]; then
    msg_err "Downloaded installer looks too small or empty"
    exit 1
fi
chmod +x installer.sh
msg_ok "Installer downloaded"

msg_info "Patching installer for LXC"
sed -i '/docker/Id' installer.sh || true
sed -i '/compose/Id' installer.sh || true
sed -i '/systemctl/Id' installer.sh || true
sed -i "s|/opt/freidntl|${APP_DIR}|g" installer.sh || true
msg_ok "Installer patched"

msg_info "Running Mikrowizard installer"
bash installer.sh || { msg_err "Installer script failed"; exit 1; }
msg_ok "Mikrowizard installed"

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
    systemctl enable ${SERVICE} >/dev/null
    systemctl start ${SERVICE}
    msg_ok "Service created and started"
  else
    msg_info "No main.py found in ${APP_DIR}; skipping systemd unit creation"
  fi
else
  msg_info "systemd not available in this container; skipping service creation"
fi

msg_ok "Mikrowizard installation complete inside container"
EOF_CT

msg_ok "Mikrowizard installed in CT $CTID"

IP_OUT=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "CT_IP")

echo
echo -e "${GN}Mikrowizard LXC deployment complete.${CL}"
echo -e "${YW}Container ID:${CL} $CTID"
echo -e "${YW}Hostname:   ${CL} $HN"
echo -e "${YW}IP address: ${CL} ${IP_OUT:-unknown}"
echo -e "${YW}Access Mikrowizard via the container's IP on its configured port.${CL}"
