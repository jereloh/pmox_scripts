#!/usr/bin/env bash
# ==============================================================================
# Ubuntu 24.04 Openbox + Firefox + Selkies Browser Jumpbox for Proxmox VE
# ==============================================================================
#
# ==============================================================================
# Quick Start
# ==============================================================================
#
# Interactive:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/selkies-openbox-jumpbox-ff.sh)"
#
# Unattended:
#
#   CTID=305 \
#   STORAGE=local-lvm \
#   SELKIES_USER=webtop \
#   SELKIES_PASSWORD='ChangeMe123!' \
#   ASSUME_YES=1 \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/selkies-openbox-jumpbox-ff.sh)"
#
# ==============================================================================
# Architecture
#
#   Proxmox VE host
#   └── Ubuntu 24.04 unprivileged LXC
#       ├── Openbox window manager
#       ├── Firefox (native Mozilla DEB, always auto-started)
#       ├── PCManFM file manager
#       ├── QTerminal
#       ├── PulseAudio virtual output
#       ├── Selkies 2.x native Ubuntu package
#       │   ├── Browser client on one HTTPS port
#       │   ├── HTTP Basic authentication
#       │   ├── Server-to-client audio
#       │   ├── Clipboard synchronization
#       │   └── File upload/download
#       └── cloudflared tunnel (optional)
#
# Design goals
#   - No Docker, Webtop image, nested container runtime, or GPU passthrough.
#   - Software rendering and encoding for portability.
#   - Unprivileged LXC with no AppArmor override.
#   - Interactive Proxmox storage/network wizard.
#   - Environment variables may preseed prompts for unattended deployment.
#   - Preserve a failed LXC for inspection, or offer rollback interactively.
#
# Default access
#   Local:  https://<LXC-IP>:8080/
#   Remote: configure a Cloudflare public hostname to origin http://127.0.0.1:8080
#           only if SELKIES_ENABLE_HTTPS=false is selected manually later; this
#           installer keeps Selkies HTTPS enabled, so use noTLSVerify at origin
#           or point the tunnel at https://127.0.0.1:8080.
#
# Run on the Proxmox host as root:
#   chmod +x install-selkies-jumpbox.sh
#   ./install-selkies-jumpbox.sh
#
# Example unattended invocation:
#   CTID=305 STORAGE=local-lvm NET_MODE=dhcp \
#   SELKIES_USER=webtop SELKIES_PASSWORD='change-me-now' \
#   ASSUME_YES=1 ./install-selkies-jumpbox.sh
#
# References used for this implementation:
#   https://docs.selkies.io/latest/native
#   https://docs.selkies.io/latest/settings
#   https://docs.selkies.io/latest/secure-mode
#   https://support.mozilla.org/kb/install-firefox-linux
#   https://pkg.cloudflare.com/
# ==============================================================================
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
SCRIPT_NAME="selkies-jumpbox"
HOST_TMP="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"
CT_CREATED=0
CTID="${CTID:-}"

if [[ -t 1 ]]; then
  RST=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'
else
  RST=""; RED=""; GRN=""; YLW=""; BLU=""
fi
log()  { printf '%s[+]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

cleanup() { rm -rf "$HOST_TMP"; }
on_err() {
  local rc=$? line="${1:-unknown}"
  trap - ERR
  warn "Installation failed at host-script line ${line} (exit ${rc})."
  if [[ "$CT_CREATED" == 1 && -n "${CTID:-}" ]]; then
    warn "Container ${CTID} exists but provisioning did not complete."
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then
      warn "Leaving CT ${CTID} for inspection: pct enter ${CTID}"
    else
      local ans
      read -r -p "Destroy CT ${CTID} and roll back? [y/N]: " ans || true
      if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
        pct stop "$CTID" >/dev/null 2>&1 || true
        pct destroy "$CTID" --purge >/dev/null 2>&1 || true
        ok "Rolled back CT ${CTID}."
      else
        warn "Preserved CT ${CTID}: pct enter ${CTID}"
      fi
    fi
  fi
  cleanup
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT
trap 'exit 130' INT TERM

need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
ask() {
  local var="$1" prompt="$2" default="${3:-}" value="${!1:-}"
  [[ -n "$value" ]] && return 0
  if [[ "${ASSUME_YES:-0}" == 1 ]]; then
    [[ -n "$default" ]] || die "$var must be pre-set when ASSUME_YES=1."
    printf -v "$var" '%s' "$default"
    return
  fi
  read -r -p "$prompt${default:+ [$default]}: " value
  printf -v "$var" '%s' "${value:-$default}"
}
ask_optional() {
  local var="$1" prompt="$2" value
  [[ -n "${!1+x}" ]] && return 0
  if [[ "${ASSUME_YES:-0}" == 1 ]]; then printf -v "$var" ''; return; fi
  read -r -p "$prompt (blank to skip): " value
  printf -v "$var" '%s' "${value:-}"
}
ask_secret() {
  local var="$1" prompt="$2" min="${3:-12}" a b existing="${!1:-}"
  if [[ -n "$existing" ]]; then
    (( ${#existing} >= min )) || die "$var must contain at least $min characters."
    return
  fi
  [[ "${ASSUME_YES:-0}" != 1 ]] || die "$var must be pre-set when ASSUME_YES=1."
  while true; do
    read -r -s -p "$prompt: " a; echo
    read -r -s -p "Confirm password: " b; echo
    [[ "$a" == "$b" ]] || { warn "Passwords do not match."; continue; }
    (( ${#a} >= min )) || { warn "Minimum length is $min characters."; continue; }
    printf -v "$var" '%s' "$a"
    return
  done
}
choose() {
  local var="$1" prompt="$2"; shift 2
  local -a vals=("$@")
  ((${#vals[@]})) || die "No choices available for $prompt"
  if [[ -n "${!var:-}" ]]; then return; fi
  if [[ "${ASSUME_YES:-0}" == 1 ]]; then printf -v "$var" '%s' "${vals[0]}"; return; fi
  echo "$prompt"
  local i n
  for i in "${!vals[@]}"; do printf '  %d) %s\n' "$((i+1))" "${vals[$i]}"; done
  while true; do
    read -r -p "Select [1]: " n
    n="${n:-1}"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#vals[@]})) && {
      printf -v "$var" '%s' "${vals[$((n-1))]}"; return;
    }
    warn "Invalid selection."
  done
}
valid_ipv4() {
  local ip="$1" IFS=. a b c d
  read -r a b c d <<<"$ip" || return 1
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a<=255 && b<=255 && c<=255 && d<=255))
}
valid_cidr() {
  local value="$1" ip="${1%/*}" cidr="${1#*/}"
  [[ "$value" == */* && "$cidr" =~ ^[0-9]+$ ]] || return 1
  valid_ipv4 "$ip" && ((cidr>=1 && cidr<=32))
}

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox VE host."
for cmd in pveversion pvesh pvesm pveam pct curl awk grep base64; do need "$cmd"; done
PVE_VERSION="$(pveversion | sed -n 's|^pve-manager/\([^/]*\)/.*|\1|p')"
log "Detected Proxmox VE ${PVE_VERSION:-unknown}."

mapfile -t ROOT_STORAGES < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
DEFAULT_STORAGE="$(pvesm status |awk '$2=="lvmthin" && $3=="active" {print $1; exit}')"
mapfile -t TPL_STORAGES < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
((${#ROOT_STORAGES[@]})) || die "No active storage supports LXC rootdir content."
((${#TPL_STORAGES[@]})) || die "No active storage supports vztmpl content."
((${#BRIDGES[@]})) || BRIDGES=(vmbr0)

NEXTID="$(pvesh get /cluster/nextid)"
ask CTID "Container ID" "$NEXTID"
[[ "$CTID" =~ ^[0-9]+$ ]] && ((CTID>=100)) || die "CTID must be numeric and >= 100."
! pct status "$CTID" >/dev/null 2>&1 || die "CT/VM ID $CTID is already in use."
ask CTNAME "Container hostname" "browser-jumpbox"
[[ "$CTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid hostname."
ask STORAGE "Storage pool for rootfs" "${DEFAULT_STORAGE:-${ROOT_STORAGES[0]}}"
printf '%s\n' "${ROOT_STORAGES[@]}" | grep -qx "$STORAGE" || die "Storage '$STORAGE' is not an active rootdir-capable storage."
choose TPL_STORAGE "Select Ubuntu template storage:" "${TPL_STORAGES[@]}"
choose BRIDGE "Select network bridge:" "${BRIDGES[@]}"
ask DISK_SIZE "Disk size in GB" "12"
ask MEMORY "Memory in MiB" "4096"
ask SWAP "Swap in MiB" "1024"
ask CORES "CPU cores" "2"
for pair in DISK_SIZE MEMORY SWAP CORES; do [[ "${!pair}" =~ ^[0-9]+$ ]] || die "$pair must be numeric."; done
((DISK_SIZE>=8 && MEMORY>=1024 && CORES>=1)) || die "Minimums: 8 GB disk, 1024 MiB RAM, 1 core."

ask NET_MODE "IPv4 mode: dhcp or static" "dhcp"
NET_MODE="${NET_MODE,,}"
[[ "$NET_MODE" == dhcp || "$NET_MODE" == static ]] || die "NET_MODE must be dhcp or static."
if [[ "$NET_MODE" == static ]]; then
  ask STATIC_IP "Static IPv4 with CIDR" "192.168.1.50/24"
  ask STATIC_GW "IPv4 gateway" "192.168.1.1"
  valid_cidr "$STATIC_IP" || die "Invalid static IPv4/CIDR."
  valid_ipv4 "$STATIC_GW" || die "Invalid IPv4 gateway."
  NET0="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${STATIC_GW}"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi
ask_optional DNS_SERVER "DNS server IP; blank inherits from Proxmox"
[[ -z "$DNS_SERVER" ]] || valid_ipv4 "$DNS_SERVER" || die "Invalid DNS IPv4 address."
ask_optional SEARCH_DOMAIN "DNS search domain"
ask_optional VLAN_TAG "VLAN tag"
if [[ -n "$VLAN_TAG" ]]; then
  [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && ((VLAN_TAG>=1 && VLAN_TAG<=4094)) || die "VLAN must be 1-4094."
  NET0+=",tag=${VLAN_TAG}"
fi
ask TIMEZONE "Timezone" "Asia/Singapore"
ask SELKIES_PORT "Selkies HTTPS port" "8080"
[[ "$SELKIES_PORT" =~ ^[0-9]+$ ]] && ((SELKIES_PORT>=1 && SELKIES_PORT<=65535)) || die "Invalid Selkies port."
ask SELKIES_USER "Selkies login username" "webtop"
[[ "$SELKIES_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid Selkies username."
ask_secret SELKIES_PASSWORD "Selkies login password" 12
[[ "$SELKIES_PASSWORD" =~ ^[A-Za-z0-9@%+=:,._-]+$ ]] || die "Selkies password may use letters, numbers, and @%+=:,._- only."
ask_optional CF_TUNNEL_TOKEN "Cloudflare Tunnel token"

cat <<SUMMARY

================ Configuration ================
CT:          ${CTID} (${CTNAME})
OS:          Ubuntu 24.04, unprivileged LXC
Resources:   ${CORES} vCPU, ${MEMORY} MiB RAM, ${SWAP} MiB swap, ${DISK_SIZE} GB disk
Storage:     ${STORAGE} (rootfs), ${TPL_STORAGE} (template)
Network:     ${NET0}
DNS:         ${DNS_SERVER:-inherited}${SEARCH_DOMAIN:+, search ${SEARCH_DOMAIN}}
Desktop:     Openbox + PCManFM + QTerminal
Browser:     Firefox native DEB, always auto-started
Streaming:   Selkies native package, software encoding, HTTPS:${SELKIES_PORT}
Audio:       Enabled
Cloudflare:  $([[ -n "$CF_TUNNEL_TOKEN" ]] && echo enabled || echo disabled)
================================================
SUMMARY
if [[ "${ASSUME_YES:-0}" != 1 ]]; then
  read -r -p "Create and provision this jumpbox? [Y/n]: " go
  [[ "${go:-y}" =~ ^[Yy]$ ]] || die "Aborted."
fi

log "Refreshing Ubuntu template catalog."
pveam update >/dev/null 2>&1 || warn "pveam update failed; trying cached catalog."
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|xz|gz)$' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || die "No Ubuntu 24.04 amd64 standard template found."
TPL_VOLID="${TPL_STORAGE}:vztmpl/${TEMPLATE##*/}"
if ! pveam list "$TPL_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TPL_VOLID"; then
  log "Downloading ${TEMPLATE##*/}."
  pveam download "$TPL_STORAGE" "$TEMPLATE"
else
  ok "Using cached template ${TEMPLATE##*/}."
fi

PCT_ARGS=(
  "$CTID" "$TPL_VOLID"
  --ostype ubuntu --arch amd64 --hostname "$CTNAME"
  --rootfs "${STORAGE}:${DISK_SIZE}"
  --memory "$MEMORY" --swap "$SWAP" --cores "$CORES"
  --net0 "$NET0" --unprivileged 1 --onboot 1 --start 0
  --tags "selkies;firefox;jumpbox"
)
[[ -n "$DNS_SERVER" ]] && PCT_ARGS+=(--nameserver "$DNS_SERVER")
[[ -n "$SEARCH_DOMAIN" ]] && PCT_ARGS+=(--searchdomain "$SEARCH_DOMAIN")
log "Creating unprivileged LXC ${CTID}."
pct create "${PCT_ARGS[@]}"
CT_CREATED=1
pct start "$CTID"

log "Waiting for network and DNS."
NET_OK=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 2
done
((NET_OK)) || die "LXC network/DNS did not become ready."
CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
ok "LXC network ready at ${CT_IP:-unknown}."

# Encode secrets so they are not interpreted by the host or guest shell while staging.
SELKIES_USER_B64="$(printf '%s' "$SELKIES_USER" | base64 -w0)"
SELKIES_PASS_B64="$(printf '%s' "$SELKIES_PASSWORD" | base64 -w0)"
TIMEZONE_B64="$(printf '%s' "$TIMEZONE" | base64 -w0)"
CF_TOKEN_B64="$(printf '%s' "$CF_TUNNEL_TOKEN" | base64 -w0)"

cat >"${HOST_TMP}/provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
step() { printf '\n=== %s ===\n' "$*"; }
retry() { local max="$1"; shift; local n=1; until "$@"; do ((n>=max)) && return 1; sleep $((n*3)); ((n++)); done; }

SELKIES_USER="$(printf '%s' "$SELKIES_USER_B64" | base64 -d)"
SELKIES_PASSWORD="$(printf '%s' "$SELKIES_PASS_B64" | base64 -d)"
TIMEZONE="$(printf '%s' "$TIMEZONE_B64" | base64 -d)"
CF_TUNNEL_TOKEN="$(printf '%s' "$CF_TOKEN_B64" | base64 -d)"
DESKTOP_USER="webtop"
HOME_DIR="/home/${DESKTOP_USER}"

step "Base packages"
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" >/etc/timezone
retry 3 apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg jq ssl-cert dbus-x11 \
  xvfb x11-xserver-utils x11-utils openbox obconf \
  pcmanfm qterminal fonts-dejavu-core fonts-liberation \
  pulseaudio pulseaudio-utils alsa-utils

step "Desktop account"
if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DESKTOP_USER"
fi
install -d -m 0755 -o "$DESKTOP_USER" -g "$DESKTOP_USER" \
  "$HOME_DIR/.config/openbox" "$HOME_DIR/Desktop" "$HOME_DIR/Downloads"

step "Firefox native Mozilla DEB"
install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc
FPR="$(gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
EXPECTED="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
[[ "$FPR" == "$EXPECTED" ]] || { echo "Mozilla signing-key fingerprint mismatch: ${FPR:-none}" >&2; exit 1; }
echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' >/etc/apt/sources.list.d/mozilla.list
cat >/etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
retry 3 apt-get update
apt-get install -y --no-install-recommends firefox

step "Selkies native Ubuntu package"
SELKIES_VERSION="$(curl -fsSL https://api.github.com/repos/selkies-project/selkies/releases/latest | jq -r '.tag_name')"
[[ -n "$SELKIES_VERSION" && "$SELKIES_VERSION" != null ]] || { echo "Could not resolve Selkies release." >&2; exit 1; }
. /etc/os-release
DISTRO="ubuntu${VERSION_ID}"
ARCH="$(dpkg --print-architecture)"
PKG="selkies-${SELKIES_VERSION}-${DISTRO}-${ARCH}.deb"
cd /tmp
retry 3 curl -fL -o "$PKG" "https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/${PKG}"
apt-get install -y "./${PKG}"
rm -f "$PKG"
command -v selkies-session >/dev/null || { echo "selkies-session was not installed." >&2; exit 1; }

step "Openbox session"
cat >"$HOME_DIR/.config/openbox/autostart" <<'EOF'
xset s off -dpms
xsetroot -solid '#1d2021'
(sleep 2; firefox --new-window about:blank) &
EOF
cat >"$HOME_DIR/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Jumpbox">
    <item label="Firefox"><action name="Execute"><command>firefox</command></action></item>
    <item label="Terminal"><action name="Execute"><command>qterminal</command></action></item>
    <item label="File Manager"><action name="Execute"><command>pcmanfm</command></action></item>
    <separator />
    <item label="Restart Firefox"><action name="Execute"><command>sh -c 'pkill -f firefox || true; sleep 2; firefox'</command></action></item>
    <item label="Restart Openbox"><action name="Restart" /></item>
  </menu>
</openbox_menu>
EOF
if [[ -f /etc/xdg/openbox/rc.xml ]]; then cp /etc/xdg/openbox/rc.xml "$HOME_DIR/.config/openbox/rc.xml"; fi
chown -R "$DESKTOP_USER:$DESKTOP_USER" "$HOME_DIR/.config" "$HOME_DIR/Desktop" "$HOME_DIR/Downloads"

step "Selkies service"
install -d -m 0750 /etc/selkies
cat >/etc/selkies/jumpbox.env <<EOF
SELKIES_BASIC_AUTH_USER=${SELKIES_USER}
SELKIES_BASIC_AUTH_PASSWORD=${SELKIES_PASSWORD}
SELKIES_ENABLE_BASIC_AUTH=true
SELKIES_ENABLE_HTTPS=true
SELKIES_PUBLIC=true
SELKIES_PORT=${SELKIES_PORT}
SELKIES_USE_CPU=true
SELKIES_AUTO_GPU=false
SELKIES_AUDIO_ENABLED=true
SELKIES_AUDIO_ON_START=true
SELKIES_AUDIO_DEVICE_NAME=output.monitor
SELKIES_ENABLE_CLIPBOARD=true
SELKIES_CLIPBOARD_SEAMLESS=true
SELKIES_FILE_TRANSFERS=upload,download
SELKIES_FILE_MANAGER_PATH=${HOME_DIR}/Downloads
SELKIES_UI_TITLE=Browser Jumpbox
SELKIES_ENABLE_RESIZE=true
SELKIES_MODE=websockets
SELKIES_MICROPHONE_ENABLED=false
SELKIES_WEBCAM_ENABLED=false
SELKIES_GAMEPAD_ENABLED=false
EOF
chmod 0600 /etc/selkies/jumpbox.env
cat >/etc/systemd/system/selkies-jumpbox.service <<EOF
[Unit]
Description=Selkies Openbox Browser Jumpbox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DESKTOP_USER}
Group=${DESKTOP_USER}
WorkingDirectory=${HOME_DIR}
Environment=HOME=${HOME_DIR}
Environment=USER=${DESKTOP_USER}
Environment=DISPLAY=:0
EnvironmentFile=/etc/selkies/jumpbox.env
ExecStart=/usr/bin/selkies-session --session=openbox --public --port=${SELKIES_PORT} --enable-https=true --use-cpu=true --auto-gpu=false
Restart=on-failure
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now selkies-jumpbox.service

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
  step "Cloudflare Tunnel"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' >/etc/apt/sources.list.d/cloudflared.list
  retry 3 apt-get update
  apt-get install -y --no-install-recommends cloudflared
  install -d -m 0750 /etc/cloudflared
  printf 'CF_TUNNEL_TOKEN=%s\n' "$CF_TUNNEL_TOKEN" >/etc/cloudflared/tunnel.env
  chmod 0600 /etc/cloudflared/tunnel.env
  cat >/etc/systemd/system/cloudflared-jumpbox.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel for Selkies Jumpbox
After=network-online.target selkies-jumpbox.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared-jumpbox.service
fi

step "Health checks"
for _ in $(seq 1 30); do systemctl is-active --quiet selkies-jumpbox.service && break; sleep 2; done
systemctl is-active --quiet selkies-jumpbox.service
CODE="$(curl -sk -u "${SELKIES_USER}:${SELKIES_PASSWORD}" -o /dev/null -w '%{http_code}' "https://127.0.0.1:${SELKIES_PORT}/" || true)"
[[ "$CODE" =~ ^(200|301|302)$ ]] || { echo "Selkies HTTPS health check returned HTTP ${CODE:-none}." >&2; journalctl -u selkies-jumpbox -n 80 --no-pager >&2; exit 1; }
if [[ -n "$CF_TUNNEL_TOKEN" ]]; then systemctl is-active --quiet cloudflared-jumpbox.service; fi

apt-get clean
rm -rf /var/lib/apt/lists/*
printf 'SELKIES_VERSION=%s\nHTTP_CODE=%s\n' "$SELKIES_VERSION" "$CODE" >/root/jumpbox-install-result
PROVISION
chmod 0700 "${HOST_TMP}/provision.sh"
pct push "$CTID" "${HOST_TMP}/provision.sh" /root/provision.sh --perms 0700

log "Provisioning Openbox, Firefox, Selkies, audio, and optional Cloudflare Tunnel."
pct exec "$CTID" -- env \
  SELKIES_USER_B64="$SELKIES_USER_B64" \
  SELKIES_PASS_B64="$SELKIES_PASS_B64" \
  TIMEZONE_B64="$TIMEZONE_B64" \
  CF_TOKEN_B64="$CF_TOKEN_B64" \
  SELKIES_PORT="$SELKIES_PORT" \
  bash /root/provision.sh
pct exec "$CTID" -- rm -f /root/provision.sh

RESULT="$(pct exec "$CTID" -- cat /root/jumpbox-install-result 2>/dev/null || true)"
SELKIES_INSTALLED="$(awk -F= '/^SELKIES_VERSION=/{print $2}' <<<"$RESULT")"

cat <<DONE

=========================================================
Browser Jumpbox Ready
=========================================================
Local URL:       https://${CT_IP}:${SELKIES_PORT}/
Login user:      ${SELKIES_USER}
Selkies:         ${SELKIES_INSTALLED:-installed}
Firefox:         auto-starts with every desktop session
Audio:           enabled, output device output.monitor
Cloudflare:      $([[ -n "$CF_TUNNEL_TOKEN" ]] && echo enabled || echo disabled)

Administration:
  Enter LXC:     pct enter ${CTID}
  Selkies log:   pct exec ${CTID} -- journalctl -u selkies-jumpbox -f
  Restart:       pct exec ${CTID} -- systemctl restart selkies-jumpbox
  Tunnel log:    pct exec ${CTID} -- journalctl -u cloudflared-jumpbox -f

The local HTTPS endpoint uses a self-signed certificate by default.
For Cloudflare, configure the tunnel's public hostname to the HTTPS origin
https://127.0.0.1:${SELKIES_PORT} and disable origin TLS verification, or replace
the Selkies certificate with one trusted by cloudflared.
=========================================================
DONE
