#!/bin/bash
# Proxmox Host Script: Create Kasm-Chrome LXC (Ubuntu 24.04) 
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/kasm-chrome.sh)"
# Features: AppArmor Bypass, Auto-Restart, Systemd, Dynamic KasmVNC, Optional iGPU Passthrough

echo "=== Kasm-Chrome LXC Provisioning Script (Version 8) ==="

# Pre-flight check for jq dependency on host
which jq >/dev/null || { echo "Installing jq on host..."; apt update && apt install -y jq; }

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

# 2. Interactive iGPU Passthrough Request
HAS_GPU=0
if [ -c "/dev/dri/renderD128" ]; then
    read -p "Intel iGPU detected! Do you want to pass it through to this LXC? [y/n] [y]: " WANT_GPU
    WANT_GPU=${WANT_GPU:-y}
    if [[ "$WANT_GPU" =~ ^[Yy]$ ]]; then
        HAS_GPU=1
        echo "[+] Enabling hardware passthrough configurations."
        chmod 666 /dev/dri/card0 2>/dev/null || true
        chmod 666 /dev/dri/renderD128 2>/dev/null || true
        CHROME_FLAGS="--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy --enable-features=VaapiVideoDecoder"
    fi
fi

if [ "$HAS_GPU" -eq 0 ]; then
    echo "[!] Defaulting to software rendering."
    CHROME_FLAGS="--disable-gpu"
fi

# 3. Prepare Configs
cat << EOF > /tmp/xstartup
#!/bin/bash
export \$(dbus-launch)
openbox-session &
while true; do
    google-chrome --no-sandbox --test-type --disable-async-dns --start-maximized $CHROME_FLAGS
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

# Create an isolated provisioning script to run inside the LXC later
cat << 'EOF' > /tmp/provision.sh
#!/bin/bash
chmod +x /root/.vnc/xstartup
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo ca-certificates jq

# Install Google Chrome
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt-get install -y ./google-chrome-stable_current_amd64.deb
rm google-chrome-stable_current_amd64.deb

# GPU Drivers (Only installs if mapped device exists inside LXC)
if [ -c "/dev/dri/renderD128" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y mesa-va-drivers intel-media-va-driver-non-free vainfo intel-gpu-tools
    usermod -aG video,render root
fi

# Install Latest KasmVNC Dynamically
LATEST_TAG=$(curl -s https://api.github.com/repos/kasmtech/KasmVNC/releases/latest | jq -r .tag_name)
DEB_FILE="kasmvncserver_noble_${LATEST_TAG#v}_amd64.deb"
wget -q "https://github.com/kasmtech/KasmVNC/releases/download/${LATEST_TAG}/${DEB_FILE}"
apt-get install -y ./${DEB_FILE}
rm ${DEB_FILE}

adduser root ssl-cert
systemctl daemon-reload
systemctl enable kasmvnc
EOF

# 4. Create Container
pveam update
TEMPLATE=$(pveam available | grep -m 1 'ubuntu-24.04-standard' | awk '{print $2}')
pveam download local $TEMPLATE
pct create $CTID local:vztmpl/${TEMPLATE##*/} --ostype ubuntu --hostname $CTNAME --net0 $NET_CONFIG --storage $STORAGE --rootfs $STORAGE:$DISK_SIZE --password $PASSWORD --memory 2048 --cores 2 --features $UNPRIV_FLAG

# 5. Apply AppArmor & GPU Configs
echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/$CTID.conf
if [ "$HAS_GPU" -eq 1 ]; then
    cat << 'EOF' >> /etc/pve/lxc/$CTID.conf
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
fi

# 6. Execute Provisioning
pct start $CTID
sleep 15 
pct exec $CTID -- mkdir -p /root/.vnc
pct push $CTID /tmp/xstartup /root/.vnc/xstartup
pct push $CTID /tmp/kasmvnc.service /etc/systemd/system/kasmvnc.service
pct push $CTID /tmp/provision.sh /tmp/provision.sh

pct exec $CTID -- bash /tmp/provision.sh

# Cleanup host temp files
rm /tmp/xstartup /tmp/kasmvnc.service /tmp/provision.sh
pct exec $CTID -- rm /tmp/provision.sh

echo -e "\n========================================="
echo "✅ Provisioning Complete!"
if [ "$HAS_GPU" -eq 1 ]; then
    echo "🎮 GPU Passthrough: Enabled & Configured"
else
    echo "💻 GPU Passthrough: Bypassed/Not Found (Software Rendering)"
fi
echo "-----------------------------------------"
echo "1. Run: 'pct enter $CTID'"
echo "2. Run: 'vncserver' (Perform one-time setup)"
echo "3. Run: 'systemctl start kasmvnc'"
echo "========================================="
