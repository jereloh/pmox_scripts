#!/usr/bin/env bash
#
# Proxmox host script: browser-accessible Firefox + shell in an Ubuntu 24.04 LXC.
#
#   KasmVNC  (https://<ip>:8444)  -> Openbox desktop + Firefox
#   ttyd     (https://<ip>:7681)  -> real terminal in a browser tab, tmux-backed
#
# Fully non-interactive install: no `vncserver` setup wizard afterwards.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/pmox_scripts/main/kasm-ff.sh)"
#
# Unattended: set any of the variables in the CONFIG block as environment
# variables and add ASSUME_YES=1, e.g.
#   CTID=305 STORAGE=local-lvm CT_PASSWORD=... KASM_PASSWORD=... ASSUME_YES=1 ./kasm-ff.sh
#
set -Eeuo pipefail

VERSION="2.0"
SCRIPT_NAME="kasm-ff"

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
else
  C_RST=""; C_R=""; C_G=""; C_Y=""; C_B=""
fi
log()  { printf '%s[+]%s %s\n' "$C_B" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

# ------------------------------------------------------- failure handling ----
CT_CREATED=0
CTID=""
HOST_TMP="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"

cleanup() {
  rm -rf "$HOST_TMP"
}

on_err() {
  local rc=$? line=$1
  warn "Failed at line ${line} (exit ${rc})."
  if [[ "$CT_CREATED" == "1" && -n "$CTID" ]]; then
    warn "Container ${CTID} was created but provisioning did not finish."
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
      warn "Leaving ${CTID} in place for inspection: pct enter ${CTID}"
    else
      read -r -p "Destroy container ${CTID} and roll back? [y/N]: " ans
      if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
        pct stop "$CTID" >/dev/null 2>&1 || true
        pct destroy "$CTID" --purge >/dev/null 2>&1 && ok "Destroyed ${CTID}." \
          || warn "Could not destroy ${CTID}; remove it manually."
      else
        warn "Leaving ${CTID} in place. Inspect with: pct enter ${CTID}"
      fi
    fi
  fi
  cleanup
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT

# -------------------------------------------------------------- preflight ----
[[ $EUID -eq 0 ]] || die "Run this as root on the Proxmox host."
command -v pct >/dev/null    || die "'pct' not found. This must run on a Proxmox VE host."
command -v pvesm >/dev/null  || die "'pvesm' not found. This must run on a Proxmox VE host."

for dep in curl jq; do
  if ! command -v "$dep" >/dev/null; then
    log "Installing missing host dependency: $dep"
    apt-get update -qq && apt-get install -y -qq "$dep"
  fi
done

PVE_VER="$(pveversion | sed -n 's|^pve-manager/\([0-9.]*\)/.*|\1|p')"
PVE_MAJOR="${PVE_VER%%.*}"
PVE_MINOR="$(printf '%s' "$PVE_VER" | cut -d. -f2)"
log "Proxmox VE ${PVE_VER:-unknown} detected."

# ----------------------------------------------------------------- config ----
ask() { # ask VAR "Prompt" "default"
  local __var="$1" __prompt="$2" __default="${3:-}" __cur="${!1:-}" __in
  if [[ -n "$__cur" ]]; then return 0; fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    [[ -n "$__default" ]] || die "$__var must be set when ASSUME_YES=1."
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __in; __in="${__in:-$__default}"
  else
    while [[ -z "${__in:-}" ]]; do read -r -p "$__prompt: " __in; done
  fi
  printf -v "$__var" '%s' "$__in"
}

ask_optional() { # ask_optional VAR "Prompt"  -- empty answer is valid
  local __var="$1" __prompt="$2" __in
  if [[ -n "${!1+x}" ]]; then return 0; fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then printf -v "$__var" '%s' ""; return 0; fi
  read -r -p "$__prompt (blank to skip): " __in
  printf -v "$__var" '%s' "${__in:-}"
}

ask_secret() { # ask_secret VAR "Prompt" minlen
  local __var="$1" __prompt="$2" __min="${3:-8}" __a __b
  if [[ -n "${!1:-}" ]]; then
    local __existing="${!1}"
    (( ${#__existing} >= __min )) || die "$__var is shorter than ${__min} characters."
    return 0
  fi
  [[ "${ASSUME_YES:-0}" != "1" ]] || die "$__var must be set when ASSUME_YES=1."
  while :; do
    read -r -s -p "$__prompt: " __a; echo
    read -r -s -p "Confirm: " __b; echo
    [[ "$__a" == "$__b" ]]           || { warn "Passwords do not match."; continue; }
    (( ${#__a} >= __min ))           || { warn "Minimum ${__min} characters."; continue; }
    break
  done
  printf -v "$__var" '%s' "$__a"
}

echo
echo "=== ${SCRIPT_NAME} v${VERSION} — Firefox + shell over HTTPS in an LXC ==="
echo

ask CTID     "Container ID (e.g. 305)"
[[ "$CTID" =~ ^[0-9]+$ ]] && (( CTID >= 100 )) || die "CTID must be a number >= 100."
if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID ${CTID} already exists. Pick another, or: pct destroy ${CTID}"
fi

ask CTNAME "Container hostname" "kasm-firefox"
[[ "$CTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "Hostname must be alphanumeric/hyphen only."

if [[ -z "${STORAGE:-}" ]]; then
  echo
  echo "Storage pools that can hold a container rootfs:"
  pvesm status -content rootdir | awk 'NR>1 {printf "  - %-20s %s\n", $1, $2}'
  echo
fi
ask STORAGE "Storage pool for the rootfs"
pvesm status -content rootdir | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" \
  || die "Storage '$STORAGE' does not exist or cannot hold a rootfs."

# Template storage (usually 'local')
TPL_STORAGE="${TPL_STORAGE:-$(pvesm status -content vztmpl | awk 'NR>1 {print $1; exit}')}"
[[ -n "$TPL_STORAGE" ]] || die "No storage available for container templates (content type vztmpl)."

ask DISK_SIZE "Disk size in GB" "12"
ask MEMORY    "Memory in MB"    "3072"
ask CORES     "CPU cores"       "2"
[[ "$DISK_SIZE" =~ ^[0-9]+$ && "$MEMORY" =~ ^[0-9]+$ && "$CORES" =~ ^[0-9]+$ ]] \
  || die "Disk/memory/cores must be numeric."
(( DISK_SIZE >= 8 )) || warn "Under 8 GB is tight once Firefox caches build up."

ask UNPRIVILEGED "Unprivileged container? [y/n]" "y"
[[ "$UNPRIVILEGED" =~ ^[Yy]$ ]] && UNPRIV_FLAG="1" || UNPRIV_FLAG="0"

ask USE_DHCP "Use DHCP? [y/n]" "y"
if [[ "$USE_DHCP" =~ ^[Nn]$ ]]; then
  ask STATIC_IP "Static IP with prefix (e.g. 192.168.1.50/24)"
  ask STATIC_GW "Gateway"
  [[ "$STATIC_IP" == */* ]] || die "Static IP must include a prefix, e.g. /24."
  NET_CONFIG="name=eth0,bridge=${BRIDGE:-vmbr0},ip=${STATIC_IP},gw=${STATIC_GW}"
else
  NET_CONFIG="name=eth0,bridge=${BRIDGE:-vmbr0},ip=dhcp"
fi

ask_optional CUSTOM_DNS "Custom DNS server"
CUSTOM_DNS="$(printf '%s' "$CUSTOM_DNS" | tr -d '[:space:]')"
DNS_FLAG=(); [[ -n "$CUSTOM_DNS" ]] && DNS_FLAG=(--nameserver "$CUSTOM_DNS")

ask TIMEZONE "Timezone" "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)"

echo
echo "--- Credentials ---"
ask_secret CT_PASSWORD   "Root password for the container" 8
ask_secret KASM_PASSWORD "Web password for Firefox + terminal (user: ${KASM_USER:-kasm})" 8
KASM_USER="${KASM_USER:-kasm}"

echo
echo "--- Hardware acceleration ---"
ask WANT_GPU "Pass through an iGPU (/dev/dri) to this container? [y/n]" "n"
HAS_GPU=0; [[ "$WANT_GPU" =~ ^[Yy]$ ]] && HAS_GPU=1

if (( HAS_GPU )); then
  if [[ ! -e /dev/dri/renderD128 ]]; then
    log "No /dev/dri/renderD128 on the host; trying to load i915..."
    modprobe i915 2>/dev/null || true
    sleep 2
  fi
  if [[ ! -e /dev/dri/renderD128 ]]; then
    warn "Still no /dev/dri/renderD128 on the host. Continuing with software rendering."
    HAS_GPU=0
  else
    ok "Host render node found."
  fi
fi

echo
echo "--- Optional extras ---"
ask_optional CF_TOKEN "Cloudflare Tunnel token"
CF_TOKEN="$(printf '%s' "$CF_TOKEN" | tr -d '[:space:]')"

ask_optional ALLOW_CIDR "Restrict web ports to this CIDR with ufw (e.g. 192.168.1.0/24)"
ALLOW_CIDR="$(printf '%s' "$ALLOW_CIDR" | tr -d '[:space:]')"

ask APPARMOR_UNCONFINED "Run the container AppArmor-unconfined? [y/n]" "n"

ask AUTOSTART_FIREFOX "Launch Firefox automatically on session start? [y/n]" "y"
ask UI_SCALE "Desktop UI scale (1.0 = native, 1.25 helps on phones)" "1.25"

KASM_PORT="${KASM_PORT:-8444}"
TTYD_PORT="${TTYD_PORT:-7681}"

echo
echo "--------------------------------------------------"
printf '  CT %s (%s) on %s, %sGB disk, %sMB RAM, %s cores\n' \
  "$CTID" "$CTNAME" "$STORAGE" "$DISK_SIZE" "$MEMORY" "$CORES"
printf '  Unprivileged: %s   GPU: %s   Firewall: %s\n' \
  "$([[ $UNPRIV_FLAG == 1 ]] && echo yes || echo no)" \
  "$([[ $HAS_GPU == 1 ]] && echo yes || echo no)" \
  "${ALLOW_CIDR:-none}"
echo "--------------------------------------------------"
if [[ "${ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Proceed? [Y/n]: " go; [[ "${go:-y}" =~ ^[Yy]$ ]] || die "Aborted."
fi

# --------------------------------------------------------------- template ----
log "Refreshing appliance template index..."
pveam update >/dev/null 2>&1 || warn "pveam update failed; using the cached index."

TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || die "No ubuntu-24.04-standard template found in the index."

TPL_VOLID="${TPL_STORAGE}:vztmpl/${TEMPLATE##*/}"
if pveam list "$TPL_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TPL_VOLID"; then
  ok "Template already present: ${TEMPLATE##*/}"
else
  log "Downloading ${TEMPLATE##*/} to ${TPL_STORAGE}..."
  pveam download "$TPL_STORAGE" "$TEMPLATE"
fi

# ----------------------------------------------------------------- create ----
log "Creating container ${CTID}..."
pct create "$CTID" "$TPL_VOLID" \
  --ostype ubuntu \
  --arch amd64 \
  --hostname "$CTNAME" \
  --net0 "$NET_CONFIG" \
  "${DNS_FLAG[@]}" \
  --storage "$STORAGE" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --password "$CT_PASSWORD" \
  --memory "$MEMORY" \
  --swap "$(( MEMORY / 2 ))" \
  --cores "$CORES" \
  --features nesting=1 \
  --onboot 1 \
  --tags "firefox,kasmvnc,${SCRIPT_NAME}" \
  --unprivileged "$UNPRIV_FLAG" \
  --start 0
CT_CREATED=1
ok "Container created."

CONF="/etc/pve/lxc/${CTID}.conf"
if [[ "$APPARMOR_UNCONFINED" =~ ^[Yy]$ ]]; then
  warn "Setting lxc.apparmor.profile: unconfined (weakens container isolation)."
  echo "lxc.apparmor.profile: unconfined" >> "$CONF"
fi

log "Starting container..."
pct start "$CTID"

# Wait for the container to actually have working DNS + routing.
log "Waiting for container networking..."
NET_OK=0
for i in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    NET_OK=1; break
  fi
  sleep 2
done
(( NET_OK )) || die "Container has no working DNS after 120s. Check bridge/DNS settings."
CT_IP_EARLY="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
ok "Networking up (${CT_IP_EARLY:-unknown})."

# -------------------------------------------------------------- GPU wires ----
if (( HAS_GPU )); then
  log "Configuring GPU passthrough..."
  RENDER_GID="$(pct exec "$CTID" -- getent group render 2>/dev/null | cut -d: -f3 || true)"
  VIDEO_GID="$(pct exec "$CTID" -- getent group video 2>/dev/null | cut -d: -f3 || true)"
  RENDER_GID="${RENDER_GID:-104}"; VIDEO_GID="${VIDEO_GID:-44}"

  USE_DEV_ENTRIES=0
  if (( PVE_MAJOR > 8 )) || { (( PVE_MAJOR == 8 )) && (( ${PVE_MINOR:-0} >= 2 )); }; then
    USE_DEV_ENTRIES=1
  fi

  pct stop "$CTID"
  if (( USE_DEV_ENTRIES )) \
     && pct set "$CTID" -dev0 "/dev/dri/renderD128,gid=${RENDER_GID}" >/dev/null 2>&1; then
    ok "Mapped /dev/dri/renderD128 (gid ${RENDER_GID}) via dev0."
    [[ -e /dev/dri/card0 ]] && pct set "$CTID" -dev1 "/dev/dri/card0,gid=${VIDEO_GID}" >/dev/null 2>&1 || true
  else
    warn "dev0 passthrough unavailable; falling back to raw lxc.* entries."
    cat >> "$CONF" <<'GPUEOF'
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
GPUEOF
  fi
  pct start "$CTID"
  for i in $(seq 1 30); do
    pct exec "$CTID" -- getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
    sleep 2
  done
fi

# --------------------------------------------------- build provision files ----
log "Staging configuration..."

# Secrets and settings travel in one root-only env file, never on a command line.
cat > "${HOST_TMP}/provision.env" <<ENVEOF
KASM_USER='${KASM_USER}'
KASM_PASSWORD='${KASM_PASSWORD//\'/\'\\\'\'}'
KASM_PORT='${KASM_PORT}'
TTYD_PORT='${TTYD_PORT}'
HAS_GPU='${HAS_GPU}'
TIMEZONE='${TIMEZONE}'
UI_SCALE='${UI_SCALE}'
AUTOSTART_FIREFOX='${AUTOSTART_FIREFOX}'
ALLOW_CIDR='${ALLOW_CIDR}'
CF_TOKEN='${CF_TOKEN}'
KASMVNC_FALLBACK_VERSION='${KASMVNC_FALLBACK_VERSION:-1.3.4}'
ENVEOF

cat > "${HOST_TMP}/provision.sh" <<'PROVEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[x] provision.sh failed at line $LINENO" >&2' ERR

# shellcheck disable=SC1091
source /root/provision.env

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -y)

step() { printf '\n=== %s ===\n' "$*"; }

retry() { # retry N cmd...
  local n="$1"; shift
  local i=1
  until "$@"; do
    (( i >= n )) && return 1
    echo "  retry $i/$n: $*" >&2
    sleep $(( i * 3 )); (( i++ ))
  done
}

step "Base system"
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
retry 3 apt-get update
apt-get "${APT_OPTS[@]}" upgrade
apt-get "${APT_OPTS[@]}" install \
  ca-certificates curl wget gnupg jq sudo locales tzdata \
  openbox tint2 xterm dbus-x11 x11-xserver-utils xdotool xclip \
  fonts-dejavu-core fonts-liberation fonts-noto-color-emoji \
  pulseaudio pulseaudio-utils \
  ssl-cert tmux nano less htop git iproute2 bzip2 unzip file

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8

step "Desktop user"
if ! id -u "$KASM_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$KASM_USER"
fi
usermod -aG sudo,ssl-cert,audio "$KASM_USER"
echo "$KASM_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${KASM_USER}"
chmod 440 "/etc/sudoers.d/90-${KASM_USER}"
printf '%s:%s\n' "$KASM_USER" "$KASM_PASSWORD" | chpasswd
HOMEDIR="$(getent passwd "$KASM_USER" | cut -d: -f6)"

step "Firefox from Mozilla's APT repo"
install -d -m 0755 /etc/apt/keyrings
retry 3 wget -qO /tmp/mozilla.key https://packages.mozilla.org/apt/repo-signing-key.gpg
FPR="$(gpg --show-keys --with-colons /tmp/mozilla.key 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
EXPECTED_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
if [[ "$FPR" != "$EXPECTED_FPR" ]]; then
  echo "[x] Mozilla signing key fingerprint mismatch (got ${FPR:-none})." >&2
  exit 1
fi
install -m 0644 /tmp/mozilla.key /etc/apt/keyrings/packages.mozilla.org.asc
rm -f /tmp/mozilla.key
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
  > /etc/apt/preferences.d/mozilla
retry 3 apt-get update
apt-get "${APT_OPTS[@]}" install firefox

step "GPU drivers"
if [[ -e /dev/dri/renderD128 ]]; then
  apt-get "${APT_OPTS[@]}" install \
    mesa-va-drivers mesa-vulkan-drivers intel-media-va-driver-non-free vainfo || \
    echo "[!] Some VA-API packages were unavailable; continuing."
  usermod -aG video,render "$KASM_USER" || true
  echo "[+] Render node present inside the container."
else
  echo "[i] No render node inside the container; software rendering."
fi

step "KasmVNC"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DEB_URL=""
if REL_JSON="$(curl -fsSL --max-time 20 https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null)"; then
  DEB_URL="$(jq -r --arg cn "$CODENAME" \
    '.assets[]?.browser_download_url
     | select(test("kasmvncserver_" + $cn + "_.*_amd64\\.deb$"))' <<<"$REL_JSON" | head -1)"
fi
if [[ -z "$DEB_URL" || "$DEB_URL" == "null" ]]; then
  echo "[!] GitHub API gave no asset (rate limit?); falling back to v${KASMVNC_FALLBACK_VERSION}."
  DEB_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_FALLBACK_VERSION}/kasmvncserver_${CODENAME}_${KASMVNC_FALLBACK_VERSION}_amd64.deb"
fi
echo "[i] $DEB_URL"
retry 3 wget -q -O /tmp/kasmvnc.deb "$DEB_URL"
file /tmp/kasmvnc.deb | grep -q 'Debian binary package' || { echo "[x] Downloaded file is not a .deb" >&2; exit 1; }
apt-get "${APT_OPTS[@]}" install /tmp/kasmvnc.deb
rm -f /tmp/kasmvnc.deb
adduser "$KASM_USER" ssl-cert >/dev/null

step "KasmVNC configuration"
install -d -m 0755 /etc/kasmvnc
{
  cat <<'YAMLEOF'
desktop:
  resolution:
    width: 1280
    height: 720
  allow_resize: true
  pixel_depth: 24
YAMLEOF
  if [[ "$HAS_GPU" == "1" ]]; then
    cat <<'YAMLEOF'
  gpu:
    hw3d: true
    drinode: /dev/dri/renderD128
YAMLEOF
  fi
  cat <<YAMLEOF

network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: ${KASM_PORT}
  ssl:
    require_ssl: true

user_session:
  session_type: shared
  idle_timeout: never

encoding:
  max_frame_rate: 30
  scrolling:
    detect_vertical_scrolling: true
    detect_horizontal_scrolling: true

server:
  auto_shutdown:
    no_user_session_timeout: never
    active_user_session_timeout: never
    inactive_user_session_timeout: never

command_line:
  prompt: false
YAMLEOF
} > /etc/kasmvnc/kasmvnc.yaml

# Non-interactive KasmVNC user creation. This is what removes the setup wizard;
# combined with `command_line.prompt: false` the server never asks for anything.
install -d -m 0700 -o "$KASM_USER" -g "$KASM_USER" "${HOMEDIR}/.vnc"
PWTOOL="$(command -v kasmvncpasswd || command -v vncpasswd)"
PWFILE="${HOMEDIR}/.kasmpasswd"
rm -f "$PWFILE"

set_kasm_password() {
  # 1) plain pipe (works on current releases)
  sudo -u "$KASM_USER" env PW="$KASM_PASSWORD" bash -c \
    'printf "%s\n%s\n" "$PW" "$PW" | '"$PWTOOL"' -u '"$KASM_USER"' -ow '"$PWFILE" \
    >/dev/null 2>&1 || true
  grep -q "^${KASM_USER}:" "$PWFILE" 2>/dev/null && return 0

  # 2) same thing behind a pty, for builds that insist on a terminal
  sudo -u "$KASM_USER" env PW="$KASM_PASSWORD" bash -c \
    'printf "%s\n%s\n" "$PW" "$PW" | script -qec "'"$PWTOOL"' -u '"$KASM_USER"' -ow '"$PWFILE"'" /dev/null' \
    >/dev/null 2>&1 || true
  grep -q "^${KASM_USER}:" "$PWFILE" 2>/dev/null
}

if ! set_kasm_password; then
  echo "[x] Could not create the KasmVNC user non-interactively." >&2
  echo "    Fix manually:  pct enter <ctid> && sudo -u ${KASM_USER} ${PWTOOL} -u ${KASM_USER} -ow" >&2
  exit 1
fi
chmod 600 "$PWFILE"
chown "$KASM_USER:$KASM_USER" "$PWFILE"
echo "[✓] KasmVNC user '${KASM_USER}' created."

step "Session, window manager and taskbar"
cat > "${HOMEDIR}/.vnc/xstartup" <<XEOF
#!/usr/bin/env bash
# XDG_RUNTIME_DIR is provided by the systemd unit (RuntimeDirectory=kasmvnc);
# fall back to a private /tmp dir when started by hand.
if [[ -z "\${XDG_RUNTIME_DIR:-}" || ! -d "\${XDG_RUNTIME_DIR}" ]]; then
  export XDG_RUNTIME_DIR="/tmp/runtime-\$(id -un)"
  mkdir -p "\$XDG_RUNTIME_DIR" && chmod 700 "\$XDG_RUNTIME_DIR"
fi
export LANG=en_US.UTF-8
export GDK_SCALE=1
export GDK_DPI_SCALE=${UI_SCALE}
export QT_SCALE_FACTOR=${UI_SCALE}
XEOF
if [[ "$HAS_GPU" == "1" ]]; then
  cat >> "${HOMEDIR}/.vnc/xstartup" <<'XEOF'
export MOZ_X11_EGL=1
export MOZ_ACCELERATED=1
export LIBVA_DRIVER_NAME=iHD
XEOF
fi
cat >> "${HOMEDIR}/.vnc/xstartup" <<XEOF
xrdb -merge <<< "Xft.dpi: \$(awk "BEGIN{printf \"%d\", 96 * ${UI_SCALE}}")"
xsetroot -solid '#1d2021'
xset s off -dpms
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
exec dbus-run-session -- openbox-session
XEOF

install -d -m 0755 "${HOMEDIR}/.config/openbox"
cat > "${HOMEDIR}/.config/openbox/menu.xml" <<'MENUEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Workspace">
    <item label="Firefox">
      <action name="Execute"><command>firefox</command></action>
    </item>
    <item label="Terminal">
      <action name="Execute"><command>xterm -fa Monospace -fs 12</command></action>
    </item>
    <separator />
    <item label="Restart Firefox">
      <action name="Execute"><command>sh -c 'pkill -f firefox; sleep 2; firefox'</command></action>
    </item>
    <item label="Restart window manager">
      <action name="Restart" />
    </item>
  </menu>
</openbox_menu>
MENUEOF

cat > "${HOMEDIR}/.config/openbox/autostart" <<AUTOEOF
tint2 &
AUTOEOF
if [[ "$AUTOSTART_FIREFOX" =~ ^[Yy]$ ]]; then
  echo '(sleep 2; firefox) &' >> "${HOMEDIR}/.config/openbox/autostart"
fi

# Openbox: big title bars and thick borders are far easier to hit on a phone.
cat > "${HOMEDIR}/.config/openbox/rc.xml" <<'RCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <theme>
    <name>Clearlooks</name>
    <titleLayout>NLIMC</titleLayout>
    <font place="ActiveWindow"><name>sans</name><size>11</size><weight>bold</weight></font>
    <font place="InactiveWindow"><name>sans</name><size>11</size></font>
  </theme>
  <desktops><number>1</number><names><name>Main</name></names></desktops>
  <applications>
    <application class="*"><maximized>yes</maximized></application>
  </applications>
</openbox_config>
RCEOF

install -d -m 0755 "${HOMEDIR}/.config/tint2"
cat > "${HOMEDIR}/.config/tint2/tint2rc" <<'TINTEOF'
panel_items = TSC
panel_size = 100% 46
panel_position = bottom center horizontal
panel_background_id = 1
taskbar_mode = single_desktop
task_maximum_size = 260 40
task_font = sans 11
task_font_color = #ffffff 100
launcher_icon_size = 32
time1_format = %H:%M
time1_font = sans 11
clock_font_color = #ffffff 100
clock_padding = 10 0
rounded = 0
background_color = #1d2021 100
border_width = 0
TINTEOF

chown -R "$KASM_USER:$KASM_USER" "${HOMEDIR}/.vnc" "${HOMEDIR}/.config"
chmod +x "${HOMEDIR}/.vnc/xstartup"

step "Firefox policies and profile defaults"
install -d -m 0755 /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<'POLEOF'
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisableProfileImport": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NoDefaultBookmarks": true,
    "PromptForDownloadLocation": false,
    "Homepage": { "URL": "about:blank", "StartPage": "homepage" },
    "FirefoxHome": { "Search": true, "TopSites": true, "Highlights": false, "Pocket": false, "Snippets": false }
  }
}
POLEOF

install -d -m 0755 /usr/lib/firefox/defaults/pref
cat > /usr/lib/firefox/defaults/pref/local-settings.js <<'PREFEOF'
pref("general.config.obscure_value", 0);
pref("general.config.filename", "kasm.cfg");
PREFEOF
cat > /usr/lib/firefox/kasm.cfg <<PREFEOF
// Firefox global overrides for a small remote display
pref("browser.aboutConfig.showWarning", false);
pref("layout.css.devPixelsPerPx", "${UI_SCALE}");
pref("browser.sessionstore.resume_from_crash", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.tabs.warnOnClose", false);
pref("general.smoothScroll", true);
pref("mousewheel.default.delta_multiplier_y", 200);
pref("gfx.webrender.all", true);
PREFEOF

step "ttyd (browser terminal)"
if ! apt-get "${APT_OPTS[@]}" install ttyd 2>/dev/null; then
  echo "[i] ttyd not in the archive; fetching the static build."
  TTYD_URL="$(curl -fsSL --max-time 20 https://api.github.com/repos/tsl0922/ttyd/releases/latest 2>/dev/null \
    | jq -r '.assets[]?.browser_download_url | select(endswith("ttyd.x86_64"))' | head -1)"
  [[ -n "$TTYD_URL" && "$TTYD_URL" != "null" ]] \
    || TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64"
  retry 3 wget -q -O /usr/local/bin/ttyd "$TTYD_URL"
  chmod 0755 /usr/local/bin/ttyd
fi
TTYD_BIN="$(command -v ttyd)"

step "systemd services"
cat > /etc/systemd/system/kasmvnc.service <<UNITEOF
[Unit]
Description=KasmVNC desktop for ${KASM_USER}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${KASM_USER}
Group=${KASM_USER}
WorkingDirectory=${HOMEDIR}
Environment=HOME=${HOMEDIR}
Environment=SHELL=/bin/bash
Environment=LANG=en_US.UTF-8
Environment=XDG_RUNTIME_DIR=/run/kasmvnc
RuntimeDirectory=kasmvnc
RuntimeDirectoryMode=0700
PIDFile=${HOMEDIR}/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStartPre=-/bin/rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
ExecStart=/usr/bin/vncserver :1 -depth 24
ExecStop=-/usr/bin/vncserver -kill :1
Restart=always
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /etc/systemd/system/ttyd.service <<UNITEOF
[Unit]
Description=ttyd browser terminal for ${KASM_USER}
After=network-online.target
Wants=network-online.target

[Service]
User=${KASM_USER}
Group=${KASM_USER}
WorkingDirectory=${HOMEDIR}
Environment=HOME=${HOMEDIR}
Environment=TERM=xterm-256color
EnvironmentFile=/etc/ttyd.env
ExecStart=${TTYD_BIN} --port ${TTYD_PORT} --writable \\
  --credential \${TTYD_CRED} \\
  --ssl --ssl-cert /etc/ssl/certs/ssl-cert-snakeoil.pem \\
  --ssl-key /etc/ssl/private/ssl-cert-snakeoil.key \\
  -t fontSize=16 -t 'theme={"background":"#1d2021"}' \\
  tmux new -A -s main
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

printf 'TTYD_CRED=%s:%s\n' "$KASM_USER" "$KASM_PASSWORD" > /etc/ttyd.env
chmod 640 /etc/ttyd.env
chgrp "$KASM_USER" /etc/ttyd.env

cat > "${HOMEDIR}/.tmux.conf" <<'TMUXEOF'
set -g mouse on
set -g history-limit 20000
set -g default-terminal "screen-256color"
set -g status-style bg=colour236,fg=colour250
TMUXEOF
chown "$KASM_USER:$KASM_USER" "${HOMEDIR}/.tmux.conf"

systemctl daemon-reload
systemctl enable --now kasmvnc.service
systemctl enable --now ttyd.service

step "Optional extras"
if [[ -n "$ALLOW_CIDR" ]]; then
  apt-get "${APT_OPTS[@]}" install ufw
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow from "$ALLOW_CIDR" to any port "$KASM_PORT" proto tcp >/dev/null
  ufw allow from "$ALLOW_CIDR" to any port "$TTYD_PORT" proto tcp >/dev/null
  ufw allow from "$ALLOW_CIDR" to any port 22 proto tcp >/dev/null
  ufw --force enable >/dev/null
  echo "[+] ufw active, web ports limited to ${ALLOW_CIDR}."
fi

if [[ -n "$CF_TOKEN" ]]; then
  retry 3 wget -q -O /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  apt-get "${APT_OPTS[@]}" install /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
  cloudflared service install "$CF_TOKEN" >/dev/null
  echo "[+] cloudflared installed and registered."
fi

apt-get "${APT_OPTS[@]}" install unattended-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
apt-get clean

step "Health check"
sleep 6
FAILED=0
for svc in kasmvnc ttyd; do
  if systemctl is-active --quiet "$svc"; then
    echo "[✓] ${svc}.service active"
  else
    echo "[x] ${svc}.service is NOT active" >&2
    journalctl -u "$svc" -n 20 --no-pager >&2 || true
    FAILED=1
  fi
done
CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${KASM_PORT}/" || echo 000)"
echo "[i] KasmVNC HTTP status: ${CODE} (401 = up and asking for login)"
[[ "$CODE" == "401" || "$CODE" == "200" ]] || FAILED=1
exit "$FAILED"
PROVEOF

# ----------------------------------------------------------------- deploy ----
log "Pushing provisioning files..."
pct push "$CTID" "${HOST_TMP}/provision.env" /root/provision.env --perms 600
pct push "$CTID" "${HOST_TMP}/provision.sh"  /root/provision.sh  --perms 700

log "Provisioning inside the container (this takes several minutes)..."
PROV_RC=0
pct exec "$CTID" -- /root/provision.sh || PROV_RC=$?
pct exec "$CTID" -- rm -f /root/provision.env /root/provision.sh || true
shred -u "${HOST_TMP}/provision.env" 2>/dev/null || rm -f "${HOST_TMP}/provision.env"

CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
CT_IP="${CT_IP:-<container-ip>}"

echo
echo "========================================================"
if (( PROV_RC == 0 )); then
  ok "Provisioning complete."
else
  warn "Provisioning finished with errors (exit ${PROV_RC})."
  warn "Inspect with: pct exec ${CTID} -- journalctl -u kasmvnc -n 50 --no-pager"
  if [[ ! "$APPARMOR_UNCONFINED" =~ ^[Yy]$ ]]; then
    warn "If KasmVNC will not start, try adding to ${CONF}:"
    warn "    lxc.apparmor.profile: unconfined"
    warn "then: pct restart ${CTID}"
  fi
fi
echo "--------------------------------------------------------"
printf '  Desktop + Firefox : https://%s:%s\n' "$CT_IP" "$KASM_PORT"
printf '  Terminal          : https://%s:%s\n' "$CT_IP" "$TTYD_PORT"
printf '  Login             : %s / (the web password you set)\n' "$KASM_USER"
echo
printf '  GPU passthrough   : %s\n' "$([[ $HAS_GPU == 1 ]] && echo enabled || echo 'off (software rendering)')"
printf '  Cloudflare tunnel : %s\n' "$([[ -n $CF_TOKEN ]] && echo registered || echo 'not configured')"
printf '  Firewall          : %s\n' "${ALLOW_CIDR:-open to the LAN}"
echo "--------------------------------------------------------"
cat <<TIPS
  Both services use the self-signed snakeoil certificate, so the first
  visit shows a browser warning. Put them behind the Cloudflare tunnel
  or a reverse proxy for a real certificate.

  Right-click the desktop background for the Firefox / terminal menu.
  On a phone, use the terminal URL instead of the desktop for shell work.

  Useful:
    pct enter $CTID
    systemctl restart kasmvnc
    journalctl -u kasmvnc -f
TIPS
echo "========================================================"
