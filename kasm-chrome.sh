#!/bin/bash
# Proxmox Host Script: Create Kasm-Chrome LXC (Ubuntu 24.04) + Cloudflared

echo "=== Kasm-Chrome LXC Installer (Ubuntu 24.04) ==="

# 1. Request CT ID
while [[ -z "$CTID" ]]; do
  read -p "Enter a valid CT ID (e.g., 305): " CTID
  if [[ -z "$CTID" ]]; then echo "Error: CT ID cannot be empty."; fi
done

# 2. Request Container Name
read -p "Enter Container Name (Default: Kasm-Chrome): " CTNAME
CTNAME=${CTNAME:-Kasm-Chrome}

# 3. Lookup and Request Storage Pool
echo -e "\nLooking up available storage pools for containers..."
pvesm status -content rootdir | awk 'NR>1 {print " - " $1}'
echo ""
while [[ -z "$STORAGE" ]]; do
  read -p "Enter the Storage Pool name from the list above (e.g., local-lvm): " STORAGE
  if [[ -z "$STORAGE" ]]; then echo "Error: Storage Pool cannot be empty."; fi
done

# 4. Request LXC Console Root Password
while [[ -z "$PASSWORD" ]]; do
  read -p "Enter a temporary root password for the LXC console: " PASSWORD
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

# --- GENERATE CONFIG ON HOST ---
cat << 'EOF' > /tmp/xstartup
#!/bin/bash
# Start a fake dbus session so Chrome thinks a network manager exists
export $(dbus-launch)

openbox-session &

# Disable async-dns to force Chrome to use the working LXC network
google-chrome --no-sandbox --test-type --disable-gpu --disable-async-dns --start-maximized &
EOF
# --------------------------------

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
  --features nesting=1 \
  $UNPRIV_FLAG

# --- THE APPARMOR OVERRIDE ---
echo "Applying AppArmor bypass to fix Chrome networking..."
echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/$CTID.conf

echo "[3/4] Starting LXC and injecting configurations..."
pct start $CTID
sleep 15 

# Push configuration into the LXC safely
pct exec $CTID -- mkdir -p /root/.vnc
pct push $CTID /tmp/xstartup /root/.vnc/xstartup

# Cleanup temp files on host
rm /tmp/xstartup

echo "[4/4] Provisioning Chrome, Openbox, KasmVNC 1.4.0, and Cloudflared..."
pct exec $CTID -- bash -c "
  chmod +x /root/.vnc/xstartup

  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  # Installing ca-certificates and dbus-x11 for full network/dbus support
  DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo ca-certificates
  
  # Install Google Chrome
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  DEBIAN_FRONTEND=noninteractive apt-get install -y ./google-chrome-stable_current_amd64.deb
  rm google-chrome-stable_current_amd64.deb
  
  # Install KasmVNC 1.4.0 for Noble
  wget -q https://github.com/kasmtech/KasmVNC/releases/download/v1.4.0/kasmvncserver_noble_1.4.0_amd64.deb
  DEBIAN_FRONTEND=noninteractive apt-get install -y ./kasmvncserver_noble_1.4.0_amd64.deb
  rm kasmvncserver_noble_1.4.0_amd64.deb
  adduser root ssl-cert
  
  # Install Cloudflared
  curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared.deb
  rm cloudflared.deb
"

LXC_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo -e "\n========================================="
echo "✅ Kasm-Chrome LXC ($CTID) Provisioned Successfully!"
echo "========================================="
echo "The container is ready, but you must initialize KasmVNC manually."
echo ""
echo "NEXT STEPS:"
echo "1. Log into the LXC console in Proxmox (User: root)."
echo "2. Run: vncserver"
echo "3. Press 'y' to accept the EULA."
echo "4. Select [1] to create a new user with write access."
echo "5. Create your desired username and password."
echo "6. Select [1] (Manually edit xstartup) for the Desktop Environment."
echo "   (Just press Ctrl+X to exit the editor, the config is already there)."
echo ""
echo "Once done, access your browser at: https://${LXC_IP}:8444"
echo "-----------------------------------------"
echo "Optional Cloudflare Tunnel Setup:"
echo "In the LXC console, run: cloudflared service install [YOUR_TOKEN]"
echo "========================================="
