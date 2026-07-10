#!/bin/bash
# Proxmox Host Script: Create Kasm-Firefox LXC (Ubuntu 24.04) 
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/kasm-ff.sh)"
# Features: AppArmor Bypass, Auto-Restart, Systemd, Dynamic KasmVNC, Optional iGPU Passthrough, Tint2 Taskbar, Right-Click Menu

echo "=== Kasm-Firefox LXC Provisioning Script (Version Final) ==="

# Pre-flight check for jq dependency on host
which jq >/dev/null || { echo "Installing jq on host..."; apt update && apt install -y jq; }

# 1. Inputs
while [[ -z "$CTID" ]]; do read -p "Enter CT ID (e.g., 305): " CTID; done
read -p "Enter Container Name (Default: Kasm-Firefox): " CTNAME; CTNAME=${CTNAME:-Kasm-Firefox}
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

# Optional Custom DNS
read -p "Enter Custom DNS Server (Leave blank for default): " CUSTOM_DNS
if [ -n "$CUSTOM_DNS" ]; then DNS_FLAG="--nameserver $CUSTOM_DNS"; else DNS_FLAG=""; fi

# Optional Cloudflared Token
read -p "Enter Cloudflare Tunnel Token (Leave blank to skip): " CF_TOKEN

# 2. Interactive iGPU Passthrough Request
HAS_GPU=0
echo -e "\n--- Hardware Acceleration ---"
read -p "Do you want to enable iGPU passthrough to this LXC? [y/n] [n]: " WANT_GPU
WANT_GPU=${WANT_GPU:-n}

if [[ "$WANT_GPU" =~ ^[Yy]$ ]]; then
    HAS_GPU=1
    echo "[+] Enabling hardware passthrough configurations."
    
    if [ ! -c "/dev/dri/renderD128" ]; then
        echo "[i] /dev/dri/renderD128 not found on host. Attempting to force-load Intel iGPU modules..."
        modprobe i915 2>/dev/null
        sleep 3
    fi
    
    if [ ! -c "/dev/dri/renderD128" ]; then
        echo "[!] WARNING: /dev/dri/renderD128 still not found on the Proxmox host."
    else
        echo "[i] Host iGPU rendering node detected successfully. Applying permissions..."
        chmod 666 /dev/dri/card0 2>/dev/null || true
        chmod 666 /dev/dri/renderD128 2>/dev/null || true
    fi
    
    # Firefox handles GPU slightly differently via environment variables
    FIREFOX_ENV="export MOZ_X11_EGL=1; export MOZ_ACCELERATED=1;"
else
    echo "[!] Defaulting to software rendering."
    FIREFOX_ENV=""
fi

# 3. Prepare Configs
cat << EOF > /tmp/xstartup
#!/bin/bash
export \$(dbus-launch)
$FIREFOX_ENV

# Start the tint2 taskbar
tint2 &

# Start Openbox window manager (Replaces the infinite loop)
exec openbox-session
EOF

cat << 'EOF' > /tmp/menu.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Kasm Workspace">
    <item label="Launch Firefox">
      <action name="Execute">
        <command>firefox</command>
      </action>
    </item>
    <item label="Launch Terminal">
      <action name="Execute">
        <command>lxterminal</command>
      </action>
    </item>
    <separator />
    <item label="Restart Window Manager">
      <action name="Restart" />
    </item>
  </menu>
</openbox_menu>
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

# Build KasmVNC YAML Config (Always includes dynamic resizing, injects GPU if selected)
cat << 'EOF' > /tmp/kasmvnc.yaml
desktop:
  allow_resize: true
  pixel_depth: 24
EOF

if [ "$HAS_GPU" -eq 1 ]; then
    cat << 'EOF' >> /tmp/kasmvnc.yaml
  gpu:
    hw3d: true
    drinode: /dev/dri/renderD128
EOF
fi

cat << 'EOF' > /tmp/provision.sh
#!/bin/bash
chmod +x /root/.vnc/xstartup
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl openbox dbus-x11 sudo ca-certificates jq lxterminal tint2 bzip2

# Install Firefox via Official Mozilla APT (Bypass Snaps & Fix Dependencies)
install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | tee /etc/apt/sources.list.d/mozilla.list > /dev/null
echo -e "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000" | tee /etc/apt/preferences.d/mozilla
apt-get update && apt-get install -y firefox

# GPU Drivers
if [ -c "/dev/dri/renderD128" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y mesa-va-drivers intel-media-va-driver-non-free vainfo intel-gpu-tools
    usermod -aG video,render root
fi

# Install Latest KasmVNC
LATEST_TAG=$(curl -s https://api.github.com/repos/kasmtech/KasmVNC/releases/latest | jq -r .tag_name)
DEB_FILE="kasmvncserver_noble_${LATEST_TAG#v}_amd64.deb"
wget -q "https://github.com/kasmtech/KasmVNC/releases/download/${LATEST_TAG}/${DEB_FILE}"
apt-get install -y ./${DEB_FILE}
rm ${DEB_FILE}

# Install Cloudflared
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb
rm cloudflared-linux-amd64.deb

adduser root ssl-cert
systemctl daemon-reload
systemctl enable kasmvnc
EOF

if [ -n "$CF_TOKEN" ]; then
    echo "cloudflared service install $CF_TOKEN" >> /tmp/provision.sh
fi

# 4. Create Container
echo "[i] Updating appliance templates..."
pveam update >/dev/null 2>&1
TEMPLATE=$(pveam available | grep -m 1 'ubuntu-24.04-standard' | awk '{print $2}')

if [ -z "$TEMPLATE" ]; then
    echo "[!] Error: Could not find the Ubuntu 24.04 template."
    exit 1
fi

pveam download local "$TEMPLATE"

pct create "$CTID" "local:vztmpl/${TEMPLATE##*/}" \
    --ostype ubuntu \
    --arch amd64 \
    --hostname "$CTNAME" \
    --net0 "$NET_CONFIG" \
    $DNS_FLAG \
    --storage "$STORAGE" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --password "$PASSWORD" \
    --memory 2048 \
    --cores 2 \
    $UNPRIV_FLAG

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
pct start "$CTID"
echo "[i] Waiting for LXC network to initialize..."
sleep 15 

# Directories
pct exec "$CTID" -- mkdir -p /root/.vnc
pct exec "$CTID" -- mkdir -p /root/.config/openbox
pct exec "$CTID" -- mkdir -p /etc/kasmvnc

# Push configs
pct push "$CTID" /tmp/xstartup /root/.vnc/xstartup
pct push "$CTID" /tmp/menu.xml /root/.config/openbox/menu.xml
pct push "$CTID" /tmp/kasmvnc.service /etc/systemd/system/kasmvnc.service
pct push "$CTID" /tmp/kasmvnc.yaml /etc/kasmvnc/kasmvnc.yaml
pct push "$CTID" /tmp/provision.sh /tmp/provision.sh

# Run installer
pct exec "$CTID" -- bash /tmp/provision.sh

# Cleanup host temp files
rm /tmp/xstartup /tmp/menu.xml /tmp/kasmvnc.service /tmp/kasmvnc.yaml /tmp/provision.sh
pct exec "$CTID" -- rm /tmp/provision.sh

echo -e "\n========================================="
echo "✅ Provisioning Complete!"
if [ "$HAS_GPU" -eq 1 ]; then echo "🎮 GPU Passthrough: Enabled & Configured"; else echo "💻 GPU Passthrough: Bypassed/Not Found"; fi
if [ -n "$CF_TOKEN" ]; then echo "☁️  Cloudflared: Installed and Registered"; else echo "☁️  Cloudflared: Installed (Pending)"; fi
echo "-----------------------------------------"
echo "1. Run: 'pct enter $CTID'"
echo "2. Run: 'vncserver' (Follow the wizard: Select [1] to create user, type password, then choose [1] for manual xstartup)"
echo "3. Run: 'systemctl restart kasmvnc'"
echo "4. Access via: https://<Container_IP>:8444"
echo "5. Right-click the desktop inside the web UI to launch Firefox/Terminal."
echo "========================================="
