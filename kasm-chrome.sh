#!/bin/bash
# bash -c "$(curl -fsSL https://github.com/jereloh/pmox_scripts/blob/main/kasm-chrome.sh)"
# Proxmox Host Script: Create Kasm-Chrome LXC (Ubuntu 24.04) 
# Features: AppArmor Bypass, Auto-Restart Chrome, Systemd Auto-Start, Dynamic KasmVNC Updates

echo "=== Kasm-Chrome LXC Provisioning Script (Version 6) ==="

# 1. Inputs
while [[ -z "$CTID" ]]; do read -p "Enter CT ID (e.g., 305): " CTID; done
read -p "Enter Container Name (Default: Kasm-Chrome): " CTNAME; CTNAME=${CTNAME:-Kasm-Chrome}
echo -e "\nAvailable storage pools:" ; pvesm status -content rootdir | awk 'NR>1 {print " - " $1}'
while [[ -z "$STORAGE" ]]; do read -p "Enter Storage Pool: " STORAGE; done
while [[ -z "$PASSWORD" ]]; do read -p "Enter root password for LXC: " PASSWORD; done
read -p "Disk Size (GB) [10]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-10}
read -p "Unprivileged? [y/n] [y]: " IS_UNPRIV; IS_UNPRIV=${IS_UNPRIV:-y}
[ "$IS_UNPRIV" == "n" ] && UNPRIV_FLAG="--unprivileged 0" || UNPRIV_FLAG="--unprivileged 1"
read -p "Use DHCP? [y/n] [y]: " USE_DHCP; USE_DHCP=${USE_DHCP:-y}
if [[ "$USE_DHCP" =~ ^[Nn]$ ]]; then
  read -p "Static IP (e.g. 192.168.1.50/24): " STATIC_IP; read -p "Gateway: " STATIC_GW
  NET_CONFIG="name=eth0,bridge=vmbr0,ip=${STATIC_IP},gw=${STATIC_GW}"
else NET_CONFIG="name=eth0,bridge=vmbr0,ip=dhcp"; fi

# 2. Prepare Configs
cat << 'EOF' > /tmp/xstartup
#!/bin/bash
export $(dbus-launch)
openbox-session &
while true; do
    google-chrome --no-sandbox --test-type --disable-gpu --disable-async-dns --start-maximized
    sleep 1
done &
EOF

cat << 'EOF' > /tmp/kasmvnc.service
[Unit]
Description=KasmVNC Server for Kiosk
After=network.target

[Service]
Type=forking
User=root
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStartPre=-/bin/rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
ExecStart=/usr/bin/vncserver :1
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 3. Create Container
pveam update
TEMPLATE=$(pveam available | grep -m 1 'ubuntu-24.04-standard' | awk '{print $2}')
pveam download local $TEMPLATE
pct create $CTID local:vztmpl/${TEMPLATE##*/} --ostype ubuntu --hostname $CTNAME --net0 $NET_CONFIG --storage $STORAGE --rootfs $STORAGE:$DISK_SIZE --password $PASSWORD --memory 2048 --cores 2 --features $UNPRIV_FLAG
echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/$CTID.conf

# 4. Provisioning
pct start $CTID
sleep 15 
pct exec $CTID -- mkdir -p /root/.vnc
pct push $CTID /tmp/xstartup /root/.vnc/xstartup
pct push $CTID /tmp/kasmvnc.service /etc/systemd/system/kasmvnc.service

pct exec $CTID -- bash -c "
  chmod +x /root/.vnc/xstartup
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo ca-certificates jq
  
  # Install Google Chrome
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y ./google-chrome-stable_current_amd64.deb
  rm google-chrome-stable_current_amd64.deb
  
  # Install Latest KasmVNC Dynamically
  LATEST_TAG=\$(curl -s https://api.github.com/repos/kasmtech/KasmVNC/releases/latest | jq -r .tag_name)
  DEB_FILE=\"kasmvncserver_noble_\${LATEST_TAG#v}_amd64.deb\"
  wget -q \"https://github.com/kasmtech/KasmVNC/releases/download/\${LATEST_TAG}/\${DEB_FILE}\"
  apt-get install -y ./\${DEB_FILE}
  rm \${DEB_FILE}
  
  adduser root ssl-cert
  systemctl daemon-reload
  systemctl enable kasmvnc
"

rm /tmp/xstartup /tmp/kasmvnc.service

echo -e "\n========================================="
echo "✅ Provisioning Complete!"
echo "-----------------------------------------"
echo "1. Run: 'pct enter $CTID'"
echo "2. Run: 'vncserver' (Perform one-time setup)"
echo "3. Run: 'systemctl start kasmvnc'"
echo "========================================="
