#!/usr/bin/env bash
# ==============================================================================
# Ephemeral Selkies VDI Host + REST API (setup-selkies-docker-host.sh v1.4)
# ==============================================================================
#
# Usage:
#   # Fresh install:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/setup-selkies-docker-host.sh)"
#
#   # Update an existing host (preserves /etc/vdi-ctl.conf & running sessions):
#   bash setup-selkies-docker-host.sh --update [CTID] [--rebuild] [--pull]
#
# OVERVIEW
# --------
# Provisions ONE shared Debian 12 LXC on Proxmox VE acting as a Docker-based VDI
# host for ephemeral Selkies Firefox (default) or Chromium + Terminal sessions
# on demand—with zero shared host storage, optional per-user Cloudflare Tunnel
# sidecars (add/swap/remove live), Day-2 password & TTL management (in days,
# default 0 = never expire, with systemd auto-reaper), and a zero-dependency
# Python stdlib REST API on port 8090.
#
# ARCHITECTURE
# ------------
#
#   [ Automation / Remote Client ] ──▶ REST API (:8090, Bearer Token) ──┐
#                                                                       ▼
#   [ Employee Browsers ]                                        [ vdi-api.py ]
#     ├── Local LAN  ──▶ https://<host-ip>:10000..10020 ──┐             │
#     └── Remote CF  ──▶ Cloudflare Edge ──▶ cf-<user> ───┤             ▼
#                                                         ▼       [ vdi-ctl ] ◀── vdi-reaper.timer (5m)
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │           Proxmox VE Host — Single Shared LXC (Default CTID 305)        │
#   │           Sizing: 4 vCPU | 6 GB RAM | 25 GB Disk | Single Debian 12 OS  │
#   │           State : /var/lib/vdi/sessions/<user>.env (TTL / expiry)       │
#   │                                                                         │
#   │  [ Docker Engine (/etc/docker/daemon.json: "icc": false) ]              │
#   │                                                                         │
#   │   ┌───────────────────────────────┐   ┌───────────────────────────────┐ │
#   │   │ User Pod Namespace: alice     │   │ User Pod Namespace: bob       │ │
#   │   │ • selkies-alice (:3001)       │   │ • selkies-bob (:3001)         │ │
#   │   │   (Firefox or Chromium + Sh)  │   │   (Firefox or Chromium + Sh)  │ │
#   │   │ • cf-alice (Live CF Sidecar)  │   │ • cf-bob (Live CF Sidecar)    │ │
#   │   │ • 2 vCPU / 1.8 GB / 512M tmpfs│   │ • 2 vCPU / 1.8 GB / 512M tmpfs│ │
#   │   └──────────────┬────────────────┘   └──────────────┬────────────────┘ │
#   │                  │                                   │                  │
#   │                  └─────────────────┬─────────────────┘                  │
#   │                                    │ OverlayFS (Read-Only Base Images)  │
#   │                                    ▼                                    │
#   │   ┌──────────────────────────────────────────────────────────────────┐  │
#   │   │ Shared Images: vcf-firefox:latest (default) | vcf-chromium:latest│  │
#   │   │ • Enterprise Policies (DoH disabled, managed VCF 9.1.1 bookmarks)│  │
#   │   │ • Terminal CLI Tools (curl, jq, ssh, dig, tmux)                  │  │
#   │   └─────────────────────────────────┬────────────────────────────────┘  │
#   └─────────────────────────────────────┼───────────────────────────────────┘
#                                         │ Outbound NAT (--dns 172.16.0.6)
#                                         ▼
#                  ┌─────────────────────────────────────────────┐
#                  │         Internal Lab Network (VCF)          │
#                  │  vCenter, SDDC Manager, NSX, VCFA, PAIS     │
#                  └─────────────────────────────────────────────┘
#
# CLI COMMANDS (vdi-ctl)
# ----------------------
#   vdi-ctl start <user> [--chrome] [-cf <token>] [--days <N>]  (default: 0 = never expire)
#   vdi-ctl stop <user>
#   vdi-ctl list
#   vdi-ctl passwd <user> [new_password]
#   vdi-ctl cf {add|set|remove} <user> [token]
#   vdi-ctl ttl <user> <days>                                   (0 = never expire)
#   vdi-ctl reap
#   vdi-ctl rebuild [--pull]
#   vdi-ctl api-key
#   vdi-ctl rotate-api-key
#   vdi-ctl help
#
# REST API ENDPOINTS (Port 8090)
# ------------------------------
#   GET    /health           -> Health check (no auth)
#   GET    /info  (/, /help) -> API & CLI command reference (no auth)
#   GET    /sessions         -> List active sessions (includes cf_active, ttl_days, expires_at)
#   POST   /sessions                -> Start session: {"user":"alice","browser":"chrome","cf_token":"...","days":0}
#   POST   /sessions/<user>/password -> Change password (requires {"password":"..."})
#   PATCH  /sessions/<user>         -> Day-2 update:  {"password":"...","cf_token":"...","days":2}
#   DELETE /sessions/<user>         -> Stop and wipe session
# ==============================================================================
set -Eeuo pipefail

VERSION="1.4"
SCRIPT_NAME="selkies-docker-host"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
else
  C_RST=""; C_R=""; C_G=""; C_Y=""; C_B=""
fi
log()  { printf '%s[+]%s %s\n' "$C_B" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

MODE="install"
REBUILD_IMAGES=0
PULL_IMAGES=0
UPDATE_CTID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      MODE="update"
      if [[ -n "${2:-}" && "${2:-}" =~ ^[0-9]+$ ]]; then
        UPDATE_CTID="$2"; shift 2
      else
        shift
      fi
      ;;
    --rebuild)
      REBUILD_IMAGES=1; shift
      ;;
    --pull)
      REBUILD_IMAGES=1; PULL_IMAGES=1; shift
      ;;
    -h|--help)
      cat <<'USAGEEOF'
Usage:
  setup-selkies-docker-host.sh                                  Fresh install (interactive)
  setup-selkies-docker-host.sh --update [CTID]                  Update vdi-ctl, vdi-api, and systemd units (no image rebuild)
  setup-selkies-docker-host.sh --update [CTID] --rebuild        Also rebuild vcf-* images from pinned base tags
  setup-selkies-docker-host.sh --update [CTID] --pull           Also pull newest upstream base images and rebuild
USAGEEOF
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

CT_CREATED=0
CTID="${UPDATE_CTID}"
HOST_TMP="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"
cleanup() { rm -rf "$HOST_TMP"; }
on_err() {
  local rc=$? line=$1
  warn "Failed at line ${line} (exit ${rc})."
  if [[ "$CT_CREATED" == "1" && -n "$CTID" && "${ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "Destroy container ${CTID} and roll back? [y/N]: " ans
    if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge >/dev/null 2>&1 && ok "Destroyed ${CTID}."
    fi
  fi
  cleanup; exit "$rc"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pct >/dev/null || die "'pct' not found."

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __cur="${!1:-}" __in
  if [[ -n "$__cur" ]]; then return 0; fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    [[ -n "$__default" ]] || die "$__var required with ASSUME_YES=1."
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __in; __in="${__in:-$__default}"
  else
    while [[ -z "${__in:-}" ]]; do read -r -p "$__prompt: " __in; done
  fi
  printf -v "$__var" '%s' "$__in"
}

ask_secret() {
  local __var="$1" __prompt="$2" __min="${3:-8}" __a __b
  if [[ -n "${!1:-}" ]]; then return 0; fi
  [[ "${ASSUME_YES:-0}" != "1" ]] || die "$__var required with ASSUME_YES=1."
  while :; do
    read -r -s -p "$__prompt: " __a; echo
    read -r -s -p "Confirm: " __b; echo
    [[ "$__a" == "$__b" && ${#__a} -ge $__min ]] && break
    warn "Mismatch or shorter than ${__min} chars."
  done
  printf -v "$__var" '%s' "$__a"
}

echo "=== ${SCRIPT_NAME} v${VERSION} (${MODE}) — Shared Docker Host + REST API for Ephemeral Selkies ==="

ask CTID "Host Container ID" "305"

if [[ "$MODE" == "update" ]]; then
  pct status "$CTID" >/dev/null 2>&1 || die "CTID ${CTID} does not exist."
  if ! pct status "$CTID" | grep -q "running"; then
    log "Starting LXC ${CTID}..."
    pct start "$CTID"
    sleep 3
  fi
else
  pct status "$CTID" >/dev/null 2>&1 && die "CTID ${CTID} already exists. Use --update ${CTID} to upgrade an existing host."
  ask CTNAME   "Host Container hostname" "selkies-vdi-host"

  if [[ -z "${STORAGE:-}" ]]; then
    pvesm status -content rootdir | awk 'NR>1 {printf "  - %-20s %s\n", $1, $2}'
  fi
  ask STORAGE   "Storage pool for rootfs"
  TPL_STORAGE="${TPL_STORAGE:-$(pvesm status -content vztmpl | awk 'NR>1 {print $1; exit}')}"

  ask DISK_SIZE "Disk size in GB (holds shared Docker images)" "25"
  ask MEMORY    "Memory in MB (6144 MB fits 3 concurrent users)" "6144"
  ask CORES     "CPU cores" "4"

  ask USE_DHCP  "Use DHCP? [y/n]" "y"
  if [[ "$USE_DHCP" =~ ^[Nn]$ ]]; then
    ask STATIC_IP "Static IP with prefix (e.g. 172.16.0.50/24)"
    ask STATIC_GW "Gateway"
    NET_CONFIG="name=eth0,bridge=${BRIDGE:-vmbr0},ip=${STATIC_IP},gw=${STATIC_GW}"
  else
    NET_CONFIG="name=eth0,bridge=${BRIDGE:-vmbr0},ip=dhcp"
  fi

  ask CUSTOM_DNS "DNS server for containers (default lab DNS)" "172.16.0.6"
  DNS_FLAG=(); [[ -n "$CUSTOM_DNS" && "$CUSTOM_DNS" != "none" ]] && DNS_FLAG=(--nameserver "$CUSTOM_DNS")
  ask TIMEZONE   "Timezone" "$(cat /etc/timezone 2>/dev/null || echo Asia/Singapore)"
  ask UI_SCALE   "Browser HiDPI scale (1.0 = native, 1.25 = scaled)" "1.0"
  ask API_PORT   "REST API port" "8090"
  ask_secret CT_PASSWORD "Root password for the Docker host LXC" 8

  log "Applying host sysctl tuning..."
  cat > /etc/sysctl.d/99-selkies.conf <<'SYSEOF'
vm.max_map_count = 262144
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
SYSEOF
  sysctl --system >/dev/null

  pveam update >/dev/null 2>&1 || true
  TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard' | sort -V | tail -1)"
  TPL_VOLID="${TPL_STORAGE}:vztmpl/${TEMPLATE##*/}"
  pveam list "$TPL_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TPL_VOLID" || pveam download "$TPL_STORAGE" "$TEMPLATE"

  STOR_TYPE="$(pvesm status -storage "$STORAGE" | awk 'NR==2 {print $2}')"
  FEATURES="nesting=1,keyctl=1"
  [[ "$STOR_TYPE" == "zfspool" ]] && FEATURES="nesting=1,keyctl=1,fuse=1"

  log "Creating Docker Host LXC ${CTID} (${STOR_TYPE}, features=${FEATURES})..."
  pct create "$CTID" "$TPL_VOLID" \
    --ostype debian \
    --arch amd64 \
    --hostname "$CTNAME" \
    --net0 "$NET_CONFIG" \
    "${DNS_FLAG[@]}" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --password "$CT_PASSWORD" \
    --memory "$MEMORY" \
    --swap 1024 \
    --cores "$CORES" \
    --features "$FEATURES" \
    --onboot 1 \
    --tags "docker,selkies,vdi-host" \
    --unprivileged 1 \
    --start 0
  CT_CREATED=1

  pct start "$CTID"
  log "Waiting for LXC networking..."
  for i in $(seq 1 30); do
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
  done

  API_KEY="$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-32)"

  cat > "${HOST_TMP}/vdi.env" <<ENVEOF
LAB_DNS='${CUSTOM_DNS}'
TIMEZONE='${TIMEZONE}'
UI_SCALE='${UI_SCALE}'
VDI_API_PORT='${API_PORT}'
VDI_API_KEY='${API_KEY}'
MAX_SESSIONS='3'
DEFAULT_DAYS='0'
FIREFOX_BASE='lscr.io/linuxserver/firefox:latest'
CHROMIUM_BASE='lscr.io/linuxserver/chromium:latest'
CLOUDFLARED_IMAGE='cloudflare/cloudflared:latest'
ENVEOF
fi

cat > "${HOST_TMP}/setup-inside-lxc.sh" <<'INSIDE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

MODE="${MODE:-install}"
REBUILD_IMAGES="${REBUILD_IMAGES:-0}"
PULL_IMAGES="${PULL_IMAGES:-0}"

if [[ "$MODE" == "install" ]]; then
  # shellcheck disable=SC1091
  source /root/vdi.env
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates jq iproute2 python3

  # 1. Install Docker Engine
  curl -fsSL https://get.docker.com | sh

  # 2. Harden Docker daemon: isolate containers from each other (icc=false)
  cat > /etc/docker/daemon.json <<'JSONEOF'
{
  "icc": false,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "2"
  }
}
JSONEOF
  systemctl restart docker
else
  # Update mode: back up existing scripts and preserve /etc/vdi-ctl.conf
  BACKUP_DIR="/var/backups/vdi/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [[ -f /usr/local/bin/vdi-ctl ]] && cp /usr/local/bin/vdi-ctl "$BACKUP_DIR/"
  [[ -f /usr/local/bin/vdi-api.py ]] && cp /usr/local/bin/vdi-api.py "$BACKUP_DIR/"

  touch /etc/vdi-ctl.conf
  chmod 600 /etc/vdi-ctl.conf
  ensure_conf() {
    grep -q "^${1}=" /etc/vdi-ctl.conf || echo "${1}='${2}'" >> /etc/vdi-ctl.conf
  }
  ensure_conf UI_SCALE "1.0"
  ensure_conf VDI_API_PORT "8090"
  ensure_conf MAX_SESSIONS "3"
  ensure_conf DEFAULT_DAYS "0"
  ensure_conf FIREFOX_BASE "lscr.io/linuxserver/firefox:latest"
  ensure_conf CHROMIUM_BASE "lscr.io/linuxserver/chromium:latest"
  ensure_conf CLOUDFLARED_IMAGE "cloudflare/cloudflared:latest"
  # shellcheck disable=SC1091
  source /etc/vdi-ctl.conf
fi

# 3. Stage Dockerfiles for both Firefox (default) and Chromium (on-demand)
mkdir -p /opt/vcf-firefox/certs /opt/vcf-firefox/bin \
         /opt/vcf-chromium/certs /opt/vcf-chromium/bin

cat > /opt/vcf-firefox/Dockerfile <<DOCKEREOF
ARG BASE_IMAGE=lscr.io/linuxserver/firefox:latest
FROM \${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq unzip openssh-client iputils-ping dnsutils ca-certificates tmux nano less apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/lib/firefox/distribution && \
    cat << 'POLEOF' > /usr/lib/firefox/distribution/policies.json
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisableProfileImport": true,
    "DontCheckDefaultBrowser": true,
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NoDefaultBookmarks": true,
    "DisplayBookmarksToolbar": "always",
    "PromptForDownloadLocation": false,
    "Homepage": { "URL": "about:blank", "StartPage": "homepage" },
    "ManagedBookmarks": [
      { "toplevel_name": "Lab Resources" },
      { "name": "Home", "url": "https://home.lab.sg" }
    ]
  }
}
POLEOF

RUN mkdir -p /usr/lib/firefox/defaults/pref && \
    printf 'pref("general.config.obscure_value", 0);\npref("general.config.filename", "vcf.cfg");\n' \
      > /usr/lib/firefox/defaults/pref/local-settings.js && \
    cat << 'CFGEOF' > /usr/lib/firefox/vcf.cfg
pref("browser.aboutConfig.showWarning", false);
pref("layout.css.devPixelsPerPx", "${UI_SCALE:-1.0}");
pref("browser.sessionstore.resume_from_crash", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.tabs.warnOnClose", false);
pref("network.trr.mode", 5);
pref("network.dns.disablePrefetch", true);
CFGEOF
DOCKEREOF

cat > /opt/vcf-chromium/Dockerfile <<'DOCKEREOF'
ARG BASE_IMAGE=lscr.io/linuxserver/chromium:latest
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq unzip openssh-client iputils-ping dnsutils ca-certificates tmux nano less apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/chromium/policies/managed && \
    cat << 'POLEOF' > /etc/chromium/policies/managed/vcf-lab.json
{
  "BookmarkBarEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "DnsOverHttpsMode": "off",
  "ManagedBookmarks": [
    { "toplevel_name": "Lab Resources" },
    { "name": "Home", "url": "https://home.lab.sg" }
  ]
}
POLEOF
DOCKEREOF

if [[ "$MODE" == "install" || "$REBUILD_IMAGES" == "1" ]]; then
  PULL_ARG=()
  [[ "$PULL_IMAGES" == "1" ]] && PULL_ARG=(--pull)
  docker build "${PULL_ARG[@]}" --build-arg "BASE_IMAGE=${FIREFOX_BASE:-lscr.io/linuxserver/firefox:latest}" \
    -t vcf-firefox:latest /opt/vcf-firefox
  if [[ "$MODE" == "update" ]] && docker image inspect vcf-chromium:latest >/dev/null 2>&1; then
    docker build "${PULL_ARG[@]}" --build-arg "BASE_IMAGE=${CHROMIUM_BASE:-lscr.io/linuxserver/chromium:latest}" \
      -t vcf-chromium:latest /opt/vcf-chromium
  fi
  if [[ "$PULL_IMAGES" == "1" ]]; then
    docker pull "${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}" >/dev/null
  fi
  docker image prune -f >/dev/null 2>&1 || true
fi

# 4. Install vdi-ctl session manager CLI
cat > /usr/local/bin/vdi-ctl <<'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -f /etc/vdi-ctl.conf ]] && source /etc/vdi-ctl.conf

PORT_START=10000
PORT_END=10020
MAX_SESSIONS="${MAX_SESSIONS:-3}"
DEFAULT_DAYS="${DEFAULT_DAYS:-0}"
LAB_DNS="${LAB_DNS:-172.16.0.6}"
TIMEZONE="${TIMEZONE:-Asia/Singapore}"
FIREFOX_BASE="${FIREFOX_BASE:-lscr.io/linuxserver/firefox:latest}"
CHROMIUM_BASE="${CHROMIUM_BASE:-lscr.io/linuxserver/chromium:latest}"
CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
STATE_DIR="/var/lib/vdi/sessions"
mkdir -p "$STATE_DIR"

gen_secret() {
  local len="${1:-16}"
  dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-"$len"
}

is_running() {
  docker ps --filter "name=^/${1}$" --format '{{.Names}}' | grep -qx "$1"
}

require_running() {
  local user="$1"
  is_running "selkies-${user}" || { echo "Error: No active session for '${user}'." >&2; exit 1; }
}

validate_days() {
  local days="$1"
  [[ "$days" =~ ^[0-9]+$ ]] || { echo "Error: days must be a non-negative integer (0 = never expire)." >&2; exit 1; }
}

write_state() {
  local user="$1" days="$2" now created_at expires=0
  now=$(date +%s)
  created_at="$now"
  if [[ -f "${STATE_DIR}/${user}.env" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_DIR}/${user}.env" || true
    created_at="${CREATED_AT:-$now}"
  fi
  if [[ "$days" -gt 0 ]]; then
    expires=$((now + days * 86400))
  fi
  cat > "${STATE_DIR}/${user}.env" <<EOF
CREATED_AT=${created_at}
TTL_DAYS=${days}
EXPIRES_AT=${expires}
EOF
  chmod 600 "${STATE_DIR}/${user}.env"
}

format_expiry() {
  local expires="${1:-0}"
  if [[ -z "$expires" || "$expires" -eq 0 ]]; then
    echo "never"
  else
    date -d "@${expires}" '+%Y-%m-%d %H:%M'
  fi
}

start_cf_sidecar() {
  local user="$1" cf_token="$2"
  docker rm -f "cf-${user}" >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped \
    --name "cf-${user}" \
    --network "container:selkies-${user}" \
    --memory=128m \
    --cpus=0.5 \
    --label "app=vcf-selkies-cf" \
    --label "vdi.user=${user}" \
    "$CLOUDFLARED_IMAGE" \
    tunnel --no-autoupdate run --token "$cf_token" >/dev/null
}

find_free_port() {
  local used_ports
  used_ports=$(docker ps --filter "label=app=vcf-selkies" --format '{{.Label "vdi.port"}}')
  for port in $(seq "$PORT_START" "$PORT_END"); do
    if ! grep -qx "$port" <<< "$used_ports" && ! ss -tln | grep -q ":${port} "; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

ensure_image() {
  local browser="$1"
  if [[ "$browser" == "chrome" ]]; then
    if ! docker image inspect vcf-chromium:latest >/dev/null 2>&1; then
      echo "[+] First-time Chromium request: building vcf-chromium:latest..."
      docker build --build-arg "BASE_IMAGE=${CHROMIUM_BASE}" -t vcf-chromium:latest /opt/vcf-chromium >/dev/null
    fi
    echo "vcf-chromium:latest"
  else
    echo "vcf-firefox:latest"
  fi
}

cmd_start() {
  local user="" browser="firefox" cf_token="" days="$DEFAULT_DAYS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chrome|--chromium) browser="chrome"; shift ;;
      --firefox|-ff)       browser="firefox"; shift ;;
      -cf|--cf)
        cf_token="${2:?Error: -cf requires a Cloudflare Tunnel token}"
        shift 2
        ;;
      --days|-d)
        days="${2:?Error: --days requires an integer (0 = never expire)}"
        shift 2
        ;;
      -*)
        echo "Unknown option: $1" >&2; exit 1
        ;;
      *)
        if [[ -z "$user" ]]; then
          user="$1"; shift
        else
          echo "Unexpected argument: $1" >&2; exit 1
        fi
        ;;
    esac
  done

  [[ -n "$user" ]] || { echo "Usage: vdi-ctl start <username> [--chrome] [-cf <token>] [--days <N>]" >&2; exit 1; }
  validate_days "$days"
  local cname="selkies-${user}"

  if is_running "$cname"; then
    local existing_port
    existing_port=$(docker inspect -f '{{index .Config.Labels "vdi.port"}}' "$cname")
    echo "Session already active for '${user}' on port ${existing_port}." >&2
    exit 1
  fi

  local active_count
  active_count=$(docker ps --filter "label=app=vcf-selkies" -q | wc -l)
  if [ "$active_count" -ge "$MAX_SESSIONS" ]; then
    echo "Error: Max concurrent sessions ($MAX_SESSIONS) reached." >&2
    exit 1
  fi

  local image port pass host_ip dns_args=()
  image=$(ensure_image "$browser")
  port=$(find_free_port) || { echo "Error: No free ports available." >&2; exit 1; }
  pass=$(gen_secret 16)
  host_ip=$(hostname -I | awk '{print $1}')
  [[ -n "$LAB_DNS" && "$LAB_DNS" != "none" ]] && dns_args=(--dns "$LAB_DNS")

  docker rm -f "cf-${user}" "$cname" >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped \
    --name "$cname" \
    --hostname "vcf-${browser}-${user}" \
    --shm-size=1gb \
    --memory=3072m \
    --cpus=2 \
    "${dns_args[@]}" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e TZ="$TIMEZONE" \
    -e CUSTOM_USER="$user" \
    -e PASSWORD="$pass" \
    -e SELKIES_DESKTOP=true \
    -e NO_GAMEPAD=true \
    -e NO_WEBCAM=true \
    -e NO_AUDIO=true \
    -p "${port}:3001" \
    --label "app=vcf-selkies" \
    --label "vdi.user=${user}" \
    --label "vdi.browser=${browser}" \
    --label "vdi.port=${port}" \
    "$image" >/dev/null

  if [[ -n "$cf_token" ]]; then
    start_cf_sidecar "$user" "$cf_token"
  fi

  rm -f "${STATE_DIR}/${user}.env"
  write_state "$user" "$days"
  # shellcheck disable=SC1090
  source "${STATE_DIR}/${user}.env"

  echo "=========================================="
  echo " User     : ${user} (${browser})"
  echo " LAN URL  : https://${host_ip}:${port}"
  if [[ -n "$cf_token" ]]; then
    echo " CF Tunnel: Attached (cf-${user} -> https://localhost:3001)"
  fi
  echo " TTL Days : ${days} ($(format_expiry "$EXPIRES_AT"))"
  echo " Login    : ${user}"
  echo " Password : ${pass}"
  echo "=========================================="
}

cmd_stop() {
  local user="${1:?Usage: vdi-ctl stop <username>}"
  docker rm -f "cf-${user}" >/dev/null 2>&1 || true
  docker rm -f "selkies-${user}" >/dev/null
  rm -f "${STATE_DIR}/${user}.env"
  echo "Stopped and wiped ephemeral session for '${user}'."
}

cmd_list() {
  local rows
  rows=$(docker ps --filter "label=app=vcf-selkies" \
    --format '{{.Label "vdi.user"}}|{{.Label "vdi.browser"}}|{{.Names}}|{{.Label "vdi.port"}}|{{.Status}}')
  printf "%-14s %-9s %-20s %-6s %-9s %-5s %-17s %s\n" \
    "USER" "BROWSER" "CONTAINER" "PORT" "CF" "DAYS" "EXPIRES" "STATUS"
  [[ -z "$rows" ]] && return 0
  while IFS='|' read -r user browser cname port status; do
    local cf_state="none" TTL_DAYS=0 EXPIRES_AT=0
    is_running "cf-${user}" && cf_state="attached"
    if [[ -f "${STATE_DIR}/${user}.env" ]]; then
      # shellcheck disable=SC1090
      source "${STATE_DIR}/${user}.env" || true
    fi
    printf "%-14s %-9s %-20s %-6s %-9s %-5s %-17s %s\n" \
      "$user" "$browser" "$cname" "$port" "$cf_state" "${TTL_DAYS:-0}" "$(format_expiry "${EXPIRES_AT:-0}")" "$status"
  done <<< "$rows"
}

cmd_passwd() {
  local user="${1:?Usage: vdi-ctl passwd <username> [new_password]}"
  local new_pass="${2:-$(gen_secret 16)}"
  require_running "$user"
  docker exec -e VDI_USER="$user" -e VDI_PASS="$new_pass" "selkies-${user}" bash -c '
    set -e
    htfile="/config/.htpasswd"
    [[ -f /etc/nginx/.htpasswd && ! -f /config/.htpasswd ]] && htfile="/etc/nginx/.htpasswd"
    hash_line=$(htpasswd -nb "$VDI_USER" "$VDI_PASS")
    printf "%s\n" "$hash_line" > "$htfile"
    chmod 644 "$htfile"
    mkdir -p /custom-cont-init.d
    cat > /custom-cont-init.d/99-vdi-passwd <<HOOK
#!/usr/bin/env bash
printf "%s\n" '\''${hash_line}'\'' > "${htfile}"
chmod 644 "${htfile}"
HOOK
    chmod +x /custom-cont-init.d/99-vdi-passwd
    nginx -s reload >/dev/null 2>&1 || true
  '
  echo "=========================================="
  echo " User     : ${user}"
  echo " Password : ${new_pass}"
  echo "=========================================="
}

cmd_cf() {
  local action="${1:?Usage: vdi-ctl cf {add|set|remove} <username> [token]}"
  local user="${2:?Usage: vdi-ctl cf {add|set|remove} <username> [token]}"
  local token="${3:-}"
  require_running "$user"
  case "$action" in
    add)
      [[ -n "$token" ]] || { echo "Usage: vdi-ctl cf add <username> <token>" >&2; exit 1; }
      if is_running "cf-${user}"; then
        echo "Error: CF tunnel already attached for '${user}'. Use 'vdi-ctl cf set' to replace it." >&2
        exit 1
      fi
      start_cf_sidecar "$user" "$token"
      echo "CF Tunnel: Attached (cf-${user} -> https://localhost:3001)"
      ;;
    set)
      [[ -n "$token" ]] || { echo "Usage: vdi-ctl cf set <username> <token>" >&2; exit 1; }
      start_cf_sidecar "$user" "$token"
      echo "CF Tunnel: Attached (cf-${user} -> https://localhost:3001)"
      ;;
    remove|rm)
      docker rm -f "cf-${user}" >/dev/null 2>&1 || true
      echo "CF Tunnel: Removed for '${user}' (LAN access remains active)."
      ;;
    *)
      echo "Usage: vdi-ctl cf {add|set|remove} <username> [token]" >&2; exit 1
      ;;
  esac
}

cmd_ttl() {
  local user="${1:?Usage: vdi-ctl ttl <username> <days>}"
  local days="${2:?Usage: vdi-ctl ttl <username> <days>}"
  require_running "$user"
  validate_days "$days"
  write_state "$user" "$days"
  # shellcheck disable=SC1090
  source "${STATE_DIR}/${user}.env"
  echo "TTL updated for '${user}': ${days} day(s) (expires: $(format_expiry "$EXPIRES_AT"))."
}

cmd_reap() {
  local now user f
  now=$(date +%s)
  shopt -s nullglob
  for f in "${STATE_DIR}"/*.env; do
    user=$(basename "$f" .env)
    if ! is_running "selkies-${user}"; then
      rm -f "$f"
      continue
    fi
    TTL_DAYS=0 EXPIRES_AT=0
    # shellcheck disable=SC1090
    source "$f" || true
    if [[ "${EXPIRES_AT:-0}" -gt 0 && "$now" -ge "$EXPIRES_AT" ]]; then
      echo "Reaping expired session '${user}' (TTL ${TTL_DAYS}d)..."
      cmd_stop "$user"
    fi
  done
  shopt -u nullglob
}

cmd_api_key() {
  echo "${VDI_API_KEY:?Error: VDI_API_KEY not set in /etc/vdi-ctl.conf}"
}

cmd_rotate_api_key() {
  local new_key
  new_key=$(gen_secret 32)
  sed -i "s|^VDI_API_KEY=.*|VDI_API_KEY='${new_key}'|" /etc/vdi-ctl.conf
  systemctl restart vdi-api
  echo "Rotated VDI_API_KEY: ${new_key}"
}

cmd_rebuild() {
  local pull_arg=() pull_flag=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pull) pull_flag=1; pull_arg=(--pull); shift ;;
      *) echo "Usage: vdi-ctl rebuild [--pull]" >&2; exit 1 ;;
    esac
  done
  echo "[+] Rebuilding vcf-firefox:latest (base: ${FIREFOX_BASE})..."
  docker build "${pull_arg[@]}" --build-arg "BASE_IMAGE=${FIREFOX_BASE}" -t vcf-firefox:latest /opt/vcf-firefox
  if docker image inspect vcf-chromium:latest >/dev/null 2>&1; then
    echo "[+] Rebuilding vcf-chromium:latest (base: ${CHROMIUM_BASE})..."
    docker build "${pull_arg[@]}" --build-arg "BASE_IMAGE=${CHROMIUM_BASE}" -t vcf-chromium:latest /opt/vcf-chromium
  fi
  if [[ "$pull_flag" == "1" ]]; then
    echo "[+] Pulling ${CLOUDFLARED_IMAGE}..."
    docker pull "$CLOUDFLARED_IMAGE" >/dev/null
  fi
  docker image prune -f >/dev/null 2>&1 || true
  echo "[✓] Image rebuild complete (running sessions untouched; new sessions will use updated images)."
}

cmd_help() {
  cat <<'HELPEOF'
vdi-ctl — Selkies Ephemeral VDI Session Manager

Session Lifecycle:
  vdi-ctl start <user> [--chrome] [-cf <token>] [--days <N>]
      Start a Firefox (default) or Chromium session.
      --days <N> : Auto-expire after N days (default: 0 = never expire)
      -cf <tok>  : Attach a Cloudflare Tunnel sidecar on start
  vdi-ctl stop <user>
      Stop and wipe session + CF sidecar for <user>
  vdi-ctl list
      List active sessions (browser, port, CF status, TTL days, expiry)

Day-2 Operations:
  vdi-ctl passwd <user> [new_password]
      Change session password live (auto-generates if omitted)
  vdi-ctl cf add <user> <token>
      Attach a Cloudflare Tunnel sidecar to a running session
  vdi-ctl cf set <user> <token>
      Add or replace the Cloudflare Tunnel token live (zero downtime)
  vdi-ctl cf remove <user>
      Remove Cloudflare Tunnel sidecar (LAN access remains active)
  vdi-ctl ttl <user> <days>
      Update session expiry to <days> from now (0 = never expire)
  vdi-ctl reap
      Stop any expired sessions (runs every 5m via vdi-reaper.timer)
  vdi-ctl rebuild [--pull]
      Rebuild vcf-firefox (and vcf-chromium if present) from pinned base tags
      in /etc/vdi-ctl.conf. Pass --pull to fetch newest upstream images.

Host Updates (run on Proxmox host):
  setup-selkies-docker-host.sh --update [CTID] [--rebuild | --pull]
      --update           : Update vdi-ctl, vdi-api, and systemd units (no image rebuild)
      --update --rebuild : Also rebuild vcf-* images from pinned base tags
      --update --pull    : Also pull newest upstream images and rebuild

API Key & Help:
  vdi-ctl api-key
      Print the current REST API Bearer token
  vdi-ctl rotate-api-key
      Generate a new REST API Bearer token and restart vdi-api
  vdi-ctl help
      Show this help message
HELPEOF
}

case "${1:-}" in
  start)          shift; cmd_start "$@" ;;
  stop)           cmd_stop "${2:-}" ;;
  list)           cmd_list ;;
  passwd)         cmd_passwd "${2:-}" "${3:-}" ;;
  cf)             shift; cmd_cf "$@" ;;
  ttl)            cmd_ttl "${2:-}" "${3:-}" ;;
  reap)           cmd_reap ;;
  rebuild)        shift; cmd_rebuild "$@" ;;
  api-key)        cmd_api_key ;;
  rotate-api-key) cmd_rotate_api_key ;;
  help|-h|--help) cmd_help ;;
  *)              cmd_help >&2; exit 1 ;;
esac
CTLEOF
chmod +x /usr/local/bin/vdi-ctl
if [[ "$MODE" == "install" ]]; then
  mv /root/vdi.env /etc/vdi-ctl.conf
  chmod 600 /etc/vdi-ctl.conf
fi

# 5. Install lightweight Python stdlib REST API daemon
cat > /usr/local/bin/vdi-api.py <<'APIEOF'
#!/usr/bin/env python3
import hmac, json, os, re, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = os.environ.get("VDI_API_KEY", "")
STATE_DIR = "/var/lib/vdi/sessions"
USER_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
TOKEN_RE = re.compile(r"^[a-zA-Z0-9._=-]{10,512}$")

def read_session_state(user):
    path = os.path.join(STATE_DIR, f"{user}.env")
    state = {"ttl_days": 0, "expires_at": 0}
    if not os.path.isfile(path):
        return state
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                if k == "TTL_DAYS":
                    state["ttl_days"] = int(v or 0)
                elif k == "EXPIRES_AT":
                    state["expires_at"] = int(v or 0)
    return state

class VDIHandler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {API_KEY}"
        return bool(API_KEY) and hmac.compare_digest(auth, expected)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        if self.path in ("/", "/info", "/help"):
            return self._send(200, {
                "service": "selkies-vdi-api",
                "auth": "Authorization: Bearer <VDI_API_KEY> (retrieve via 'vdi-ctl api-key')",
                "defaults": {
                    "browser": "firefox",
                    "days": int(os.environ.get("DEFAULT_DAYS", "0")),
                    "max_sessions": int(os.environ.get("MAX_SESSIONS", "3")),
                },
                "endpoints": {
                    "GET /health": "Health check (no auth)",
                    "GET /info": "This API & CLI reference (no auth; aliases: /, /help)",
                    "GET /sessions": "List active sessions (cf_active, ttl_days, expires_at)",
                    "POST /sessions": {
                        "description": "Start a new ephemeral session",
                        "body": {"user": "alice", "browser": "firefox|chrome", "cf_token": "optional", "days": 0},
                    },
                    "POST /sessions/<user>/password": {
                        "description": "Change password on a running session (only when password is provided)",
                        "body": {"password": "required (min 8 chars)"},
                    },
                    "PATCH /sessions/<user>": {
                        "description": "Day-2 updates on a running session (any subset of fields)",
                        "body": {"password": "optional (empty = auto-gen)", "cf_token": "token or null to remove", "days": "int >= 0 (0 = never expire)"},
                    },
                    "DELETE /sessions/<user>": "Stop and wipe a session",
                },
                "cli": "Run 'vdi-ctl help' on the Proxmox host or inside the LXC for CLI commands (includes rebuild [--pull] and --update [--rebuild|--pull])",
            })
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/sessions":
            res = subprocess.run(
                ["docker", "ps", "--filter", "label=app=vcf-selkies", "--format", "{{json .}}"],
                capture_output=True, text=True
            )
            cf_res = subprocess.run(
                ["docker", "ps", "--filter", "label=app=vcf-selkies-cf", "--format", "{{.Label \"vdi.user\"}}"],
                capture_output=True, text=True
            )
            cf_users = set(cf_res.stdout.strip().splitlines())
            sessions = []
            for line in res.stdout.strip().splitlines():
                item = json.loads(line)
                labels = dict(kv.split("=", 1) for kv in item.get("Labels", "").split(",") if "=" in kv)
                user = labels.get("vdi.user", "")
                st = read_session_state(user)
                sessions.append({
                    "user": user,
                    "browser": labels.get("vdi.browser"),
                    "port": labels.get("vdi.port"),
                    "container": item.get("Names"),
                    "status": item.get("Status"),
                    "cf_active": user in cf_users,
                    "ttl_days": st["ttl_days"],
                    "expires_at": st["expires_at"],
                })
            return self._send(200, {"sessions": sessions})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})

        if self.path.startswith("/sessions/") and self.path.endswith("/password"):
            user = self.path[len("/sessions/"):-len("/password")]
            if not USER_RE.match(user):
                return self._send(400, {"error": "invalid user"})
            try:
                data = self._read_json()
            except json.JSONDecodeError:
                return self._send(400, {"error": "invalid json"})
            pw = data.get("password")
            if not isinstance(pw, str) or len(pw) < 8:
                return self._send(400, {"error": "password is required (min 8 characters)"})
            res = subprocess.run(["/usr/local/bin/vdi-ctl", "passwd", user, pw], capture_output=True, text=True)
            if res.returncode != 0:
                return self._send(404, {"error": res.stderr.strip() or "password update failed"})
            return self._send(200, {"status": "updated", "user": user, "password": pw})

        if self.path != "/sessions":
            return self._send(404, {"error": "not found"})

        try:
            data = self._read_json()
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})

        user = data.get("user", "")
        browser = data.get("browser", "firefox")
        cf_token = data.get("cf_token", "")
        days = data.get("days", None)

        if not USER_RE.match(user):
            return self._send(400, {"error": "invalid user (alphanumeric, 1-32 chars)"})
        if browser not in ("firefox", "chrome"):
            return self._send(400, {"error": "browser must be firefox or chrome"})
        if cf_token and not TOKEN_RE.match(cf_token):
            return self._send(400, {"error": "invalid cf_token format"})
        if days is not None and (not isinstance(days, int) or isinstance(days, bool) or days < 0):
            return self._send(400, {"error": "days must be a non-negative integer"})

        cmd = ["/usr/local/bin/vdi-ctl", "start", user]
        if browser == "chrome":
            cmd.append("--chrome")
        if cf_token:
            cmd.extend(["-cf", cf_token])
        if days is not None:
            cmd.extend(["--days", str(days)])

        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            return self._send(409, {"error": res.stderr.strip() or res.stdout.strip()})

        parsed = {"raw": res.stdout.strip()}
        for line in res.stdout.splitlines():
            if ":" in line:
                k, v = [x.strip() for x in line.split(":", 1)]
                if k in ("User", "LAN URL", "CF Tunnel", "TTL Days", "Login", "Password"):
                    parsed[k.lower().replace(" ", "_")] = v
        return self._send(201, parsed)

    def do_PATCH(self):
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if not self.path.startswith("/sessions/"):
            return self._send(404, {"error": "not found"})
        user = self.path.split("/sessions/", 1)[1]
        if not USER_RE.match(user):
            return self._send(400, {"error": "invalid user"})

        try:
            data = self._read_json()
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})

        result = {"status": "updated", "user": user}

        if "days" in data:
            days = data["days"]
            if not isinstance(days, int) or isinstance(days, bool) or days < 0:
                return self._send(400, {"error": "days must be a non-negative integer"})
            res = subprocess.run(["/usr/local/bin/vdi-ctl", "ttl", user, str(days)], capture_output=True, text=True)
            if res.returncode != 0:
                return self._send(404, {"error": res.stderr.strip() or "update failed"})
            result["ttl_days"] = days

        if "cf_token" in data:
            cf_token = data["cf_token"]
            if cf_token:
                if not isinstance(cf_token, str) or not TOKEN_RE.match(cf_token):
                    return self._send(400, {"error": "invalid cf_token format"})
                res = subprocess.run(["/usr/local/bin/vdi-ctl", "cf", "set", user, cf_token], capture_output=True, text=True)
                result["cf_active"] = True
            else:
                res = subprocess.run(["/usr/local/bin/vdi-ctl", "cf", "remove", user], capture_output=True, text=True)
                result["cf_active"] = False
            if res.returncode != 0:
                return self._send(404, {"error": res.stderr.strip() or "cf update failed"})

        if "password" in data:
            pw = data["password"]
            cmd = ["/usr/local/bin/vdi-ctl", "passwd", user]
            if isinstance(pw, str) and pw:
                if len(pw) < 8:
                    return self._send(400, {"error": "password must be at least 8 characters"})
                cmd.append(pw)
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                return self._send(404, {"error": res.stderr.strip() or "password update failed"})
            for line in res.stdout.splitlines():
                if line.strip().startswith("Password"):
                    result["password"] = line.split(":", 1)[1].strip()

        return self._send(200, result)

    def do_DELETE(self):
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if not self.path.startswith("/sessions/"):
            return self._send(404, {"error": "not found"})
        user = self.path.split("/sessions/", 1)[1]
        if not USER_RE.match(user):
            return self._send(400, {"error": "invalid user"})

        res = subprocess.run(["/usr/local/bin/vdi-ctl", "stop", user], capture_output=True, text=True)
        if res.returncode != 0:
            return self._send(404, {"error": res.stderr.strip() or "session not found"})
        return self._send(200, {"status": "stopped", "user": user})

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    port = int(os.environ.get("VDI_API_PORT", "8090"))
    ThreadingHTTPServer(("0.0.0.0", port), VDIHandler).serve_forever()
APIEOF
chmod +x /usr/local/bin/vdi-api.py

cat > /etc/systemd/system/vdi-api.service <<'UNITEOF'
[Unit]
Description=Lightweight Selkies VDI REST API
After=docker.service
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/vdi-ctl.conf
ExecStart=/usr/bin/python3 /usr/local/bin/vdi-api.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /etc/systemd/system/vdi-reaper.service <<'REAPEREOF'
[Unit]
Description=Reap expired Selkies VDI sessions
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vdi-ctl reap
REAPEREOF

cat > /etc/systemd/system/vdi-reaper.timer <<'TIMEREOF'
[Unit]
Description=Run Selkies VDI session reaper every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now vdi-api vdi-reaper.timer
if [[ "$MODE" == "update" ]]; then
  systemctl restart vdi-api
fi
INSIDE_EOF

pct push "$CTID" "${HOST_TMP}/setup-inside-lxc.sh" /root/setup-inside-lxc.sh --perms 700
if [[ "$MODE" == "install" ]]; then
  pct push "$CTID" "${HOST_TMP}/vdi.env" /root/vdi.env --perms 600
  log "Installing Docker, REST API, and building shared vcf-firefox image inside LXC ${CTID}..."
else
  log "Updating LXC ${CTID} (rebuild=${REBUILD_IMAGES}, pull=${PULL_IMAGES}; running sessions untouched)..."
fi
pct exec "$CTID" -- env MODE="$MODE" REBUILD_IMAGES="$REBUILD_IMAGES" PULL_IMAGES="$PULL_IMAGES" /root/setup-inside-lxc.sh
pct exec "$CTID" -- rm -f /root/setup-inside-lxc.sh

cat > /usr/local/bin/vdi-ctl <<WRAPEOF
#!/usr/bin/env bash
exec pct exec ${CTID} -- /usr/local/bin/vdi-ctl "\$@"
WRAPEOF
chmod +x /usr/local/bin/vdi-ctl

HOST_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
API_PORT="$(pct exec "$CTID" -- bash -c "source /etc/vdi-ctl.conf && echo \${VDI_API_PORT:-8090}")"
echo
echo "========================================================"
if [[ "$MODE" == "update" ]]; then
  ok "Updated Selkies Docker Host + REST API on LXC ${CTID} (v${VERSION})"
  echo "--------------------------------------------------------"
  echo "  REST Endpoint : http://${HOST_IP}:${API_PORT}"
  echo "  Bearer Token  : (preserved — run 'vdi-ctl api-key' to view)"
  echo "  CLI Help      : vdi-ctl help"
else
  ok "Shared Selkies Docker Host + REST API ready on LXC ${CTID}"
  echo "--------------------------------------------------------"
  echo "  REST Endpoint : http://${HOST_IP}:${API_PORT}"
  echo "  Bearer Token  : ${API_KEY}"
  echo "  Start (REST)  : curl -X POST http://${HOST_IP}:${API_PORT}/sessions -H 'Authorization: Bearer ${API_KEY}' -d '{\"user\":\"alice\"}'"
  echo "  CLI Shortcut  : vdi-ctl {start <user> [--chrome] [-cf <token>] [--days <N>] | stop <user> | list | passwd <user> [pass] | cf {add|set|remove} <user> [token] | ttl <user> <days> | rebuild [--pull] | api-key | rotate-api-key | help}"
fi
echo "========================================================"