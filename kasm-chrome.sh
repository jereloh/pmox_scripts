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

# 4. Request LXC Console Root Password (Forced)
while [[ -z "$PASSWORD" ]]; do
  read -p "Enter a temporary root password for the LXC console: " PASSWORD
  if [[ -z "$PASSWORD" ]]; then echo "Error: Password cannot be empty."; fi
done

# 5. Request KasmVNC Web UI Credentials (Forced)
echo -e "\n--- Configure KasmVNC Web Login ---"
while [[ -z "$VNC_USER" ]]; do
  read -p "Enter Web UI Username (e.g., admin): " VNC_USER
  if [[ -z "$VNC_USER" ]]; then echo "Error: Username cannot be empty."; fi
done
while [[ -z "$VNC_PASS" ]]; do
  read -s -p "Enter Web UI Password: " VNC_PASS
  echo ""
  if [[ -z "$VNC_PASS" ]]; then echo "Error: Password cannot be empty."; fi
done

# 6. Request Disk Size
read -p "Enter disk size in GB (Default: 10): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-10}

# 7. Request Privilege Status
read -p "Run as an Unprivileged container? [y/n] (Default: y): " IS_UNPRIV
IS_UNPRIV=${IS_UNPRIV:-y}
if [[ "$IS_UNPRIV" =~ ^[Nn]$ ]]; then
  UNPRIV_FLAG="--unprivileged 0"
else
  UNPRIV_FLAG="--unprivileged 1"
fi

# 8. Request Network Settings
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

echo "[4/4] Provisioning Chrome, Openbox, KasmVNC 1.4.0, and Cloudflared..."
pct exec $CTID -- bash -c "
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo
  
  # Install Google Chrome
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  DEBIAN_FRONTEND=noninteractive apt-get install -y ./google-chrome-stable_current_amd64.deb
  rm google-chrome-stable_current_amd64.deb
  
  # Install KasmVNC 1.4.0 for Noble
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
  
  # AUTOMATED KASMVNC INITIALIZATION
  # Option 1 (Create user) -> Username -> Password -> Confirm Password -> View-only (No) -> Option 1 (Manual xstartup)
  printf '1\n%s\n%s\n%s\nn\n1\n' \"$VNC_USER\" \"$VNC_PASS\" \"$VNC_PASS\" | vncserver
  
  # Install Cloudflared
  curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared.deb
  rm cloudflared.deb
"

# Get the container IP to display at the end
LXC_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo -e "\n========================================="
echo "✅ Kasm-Chrome LXC ($CTID) Provisioned Successfully!"
echo "========================================="
echo "Local Access URL: https://${LXC_IP}:8444"
echo "Username: $VNC_USER"
echo "-----------------------------------------"
echo "Next Step (Optional Cloudflare Tunnel):"
echo "1. Open the LXC console or SSH into it."
echo "2. Run: cloudflared service install [YOUR_TOKEN]"
echo "========================================="
