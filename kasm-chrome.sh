#!/bin/bash
# Proxmox Host Script: Create Kasm-Chrome LXC (Ubuntu 24.04) + Cloudflared

echo "=== Kasm-Chrome LXC Installer (Ubuntu 24.04) ==="

# 1. Request CT ID (Forced)
while [[ -z "$CTID" ]]; do
  read -p "Enter a valid CT ID (e.g., 305): " CTID
  if [[ -z "$CTID" ]]; then echo "Error: CT ID cannot be empty."; fi
done

# 2. Request Container Name
read -p "Enter Container Name (Default: Kasm-Chrome): " CTNAME
CTNAME=${CTNAME:-Kasm-Chrome}

# 3. Lookup and Request Storage Pool (Forced)
echo -e "\nLooking up available storage pools for containers..."
pvesm status -content rootdir | awk 'NR>1 {print " - " $1}'
echo ""
while [[ -z "$STORAGE" ]]; do
  read -p "Enter the Storage Pool name from the list above (e.g., local-lvm): " STORAGE
  if [[ -z "$STORAGE" ]]; then echo "Error: Storage Pool cannot be empty."; fi
done

# 4. Request Password (Forced)
while [[ -z "$PASSWORD" ]]; do
  read -p "Enter a temporary root password for the LXC: " PASSWORD
  if [[ -z "$PASSWORD" ]]; then echo "Error: Password cannot be empty."; fi
done

# 5. Request Disk Size
read -p "Enter disk size in GB (Default: 10): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-10}

# 6. Request Privilege Status
read -p "Run as an Unprivileged container? [y/n] (Default: y): " IS_UNPRIV
IS_UNPRIV=${IS_UNPRIV:-y}
if [[ "$IS_UNPRIV" =~ ^[Nn]$ ]]; then
  UNPRIV_FLAG="--unprivileged 0"
else
  UNPRIV_FLAG="--unprivileged 1"
fi

# 7. Request Network Settings
read -p "Use DHCP for IP address? [y/n] (Default: y): " USE_DHCP
USE_DHCP=${USE_DHCP:-y}
if [[ "$USE_DHCP" =~ ^[Nn]$ ]]; then
  read -p "  -> Enter Static IP with CIDR (e.g., 192.168.1.50/24): " STATIC_IP
  read -p "  -> Enter Gateway IP (e.g., 192.168.1.1): " STATIC_GW
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP},gw=${STATIC_GW}"
else
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"
fi

echo -e "\nStarting installation...\n"

echo "[1/4] Downloading Ubuntu 24.04 Template..."
pveam update
# CHANGED: Now pulls the 24.04 template instead of 22.04
TEMPLATE=$(pveam available | grep -m 1 'ubuntu-24.04-standard' | awk '{print $2}')

if [ -z "$TEMPLATE" ]; then
  echo "Error: Could not find the Ubuntu 24.04 template. Exiting."
  exit 1
fi

pveam download local $TEMPLATE

echo "[2/4] Creating LXC Container $CTID ($CTNAME) on $STORAGE..."
pct create $CTID local:vztmpl/${TEMPLATE##*/} \
  --ostype ubuntu \
  --hostname $CTNAME \
  --net0 $NET_CONFIG \
  --storage $STORAGE \
  --rootfs $STORAGE:$DISK_SIZE \
  --password $PASSWORD \
  --memory 2048 \
  --cores 2 \
  $UNPRIV_FLAG

echo "[3/4] Starting LXC and waiting for network..."
pct start $CTID
sleep 15 

echo "[4/4] Provisioning Chrome, Openbox, KasmVNC 1.4.0 (Noble), and Cloudflared..."
pct exec $CTID -- bash -c "
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo
  
  # Install Google Chrome
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  DEBIAN_FRONTEND=noninteractive apt-get install -y ./google-chrome-stable_current_amd64.deb
  rm google-chrome-stable_current_amd64.deb
  
  # CHANGED: Install KasmVNC 1.4.0 for Noble (24.04)
  wget -q https://github.com/kasmtech/KasmVNC/releases/download/v1.4.0/kasmvncserver_noble_1.4.0_amd64.deb
  DEBIAN_FRONTEND=noninteractive apt-get install -y ./kasmvncserver_noble_1.4.0_amd64.deb
  rm kasmvncserver_noble_1.4.0_amd64.deb
  adduser root ssl-cert
  
  # Create Chrome Kiosk xstartup script
  mkdir -p /root/.vnc
  cat << 'EOF' > /root/.vnc/xstartup
#!/bin/bash
openbox-session &
google-chrome --no-sandbox --start-maximized --disable-gpu &
EOF
  chmod +x /root/.vnc/xstartup
  
  # Install Cloudflared
  curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared.deb
  rm cloudflared.deb
"

echo -e "\n========================================="
echo "✅ Kasm-Chrome LXC ($CTID) Provisioned Successfully on Ubuntu 24.04!"
echo "========================================="
