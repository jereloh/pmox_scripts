#!/usr/bin/env bash
# ==============================================================================
# Ephemeral Selkies VDI Host + REST API (setup-selkies-docker-host.sh v1.0)
# ==============================================================================
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/setup-selkies-docker-host.sh)"
#
# OVERVIEW
# --------
# Provisions ONE shared Debian 12 LXC on Proxmox VE acting as a Docker-based VDI
# host for ephemeral Selkies Firefox (default) or Chromium + Terminal sessions
# on demand—with zero shared host storage, optional per-user Cloudflare Tunnel
# sidecars, and a zero-dependency Python stdlib REST API on port 8090.
#
# ARCHITECTURE
# ------------
#
#   [ Automation / Remote Client ] ──▶ REST API (:8090, Bearer Token) ──┐
#                                                                       ▼
#   [ Employee Browsers ]                                        [ vdi-api.py ]
#     ├── Local LAN  ──▶ https://<host-ip>:10000..10020 ──┐             │
#     └── Remote CF  ──▶ Cloudflare Edge ──▶ cf-<user> ───┤             ▼
#                                                         ▼       [ vdi-ctl ]
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │           Proxmox VE Host — Single Shared LXC (Default CTID 305)        │
#   │           Sizing: 4 vCPU | 6 GB RAM | 25 GB Disk | Single Debian 12 OS  │
#   │                                                                         │
#   │  [ Docker Engine (/etc/docker/daemon.json: "icc": false) ]              │
#   │                                                                         │
#   │   ┌───────────────────────────────┐   ┌───────────────────────────────┐ │
#   │   │ User Pod Namespace: alice     │   │ User Pod Namespace: bob       │ │
#   │   │ • selkies-alice (:3001)       │   │ • selkies-bob (:3001)         │ │
#   │   │   (Firefox or Chromium + Sh)  │   │   (Firefox or Chromium + Sh)  │ │
#   │   │ • cf-alice (Optional Tunnel)  │   │ • cf-bob (Optional Tunnel)    │ │
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
# REST API ENDPOINTS (Port 8090)
# ------------------------------
#   GET    /health           -> Health check (no auth)
#   GET    /sessions         -> List active sessions
#   POST   /sessions         -> Start session: {"user":"alice","browser":"chrome","cf_token":"..."}
#   DELETE /sessions/<user>  -> Stop and wipe session
# ==============================================================================
set -Eeuo pipefail

VERSION="1.0"
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

CT_CREATED=0
CTID=""
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

echo "=== ${SCRIPT_NAME} v${VERSION} — Shared Docker Host + REST API for Ephemeral Selkies ==="

ask CTID     "Host Container ID" "305"
pct status "$CTID" >/dev/null 2>&1 && die "CTID ${CTID} already exists."
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
ENVEOF

cat > "${HOST_TMP}/setup-inside-lxc.sh" <<'INSIDE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

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

# 3. Stage Dockerfiles for both Firefox (default) and Chromium (on-demand)
mkdir -p /opt/vcf-firefox/certs /opt/vcf-firefox/bin \
         /opt/vcf-chromium/certs /opt/vcf-chromium/bin

cat > /opt/vcf-firefox/Dockerfile <<DOCKEREOF
FROM lscr.io/linuxserver/firefox:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq unzip openssh-client iputils-ping dnsutils ca-certificates tmux nano less \
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
      { "name": "Home", "url": "https://home.lab.sg" },
    ]
  }
}
POLEOF

RUN mkdir -p /usr/lib/firefox/defaults/pref && \
    printf 'pref("general.config.obscure_value", 0);\npref("general.config.filename", "vcf.cfg");\n' \
      > /usr/lib/firefox/defaults/pref/local-settings.js && \
    cat << 'CFGEOF' > /usr/lib/firefox/vcf.cfg
pref("browser.aboutConfig.showWarning", false);
pref("layout.css.devPixelsPerPx", "${UI_SCALE}");
pref("browser.sessionstore.resume_from_crash", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.tabs.warnOnClose", false);
pref("network.trr.mode", 5);
pref("network.dns.disablePrefetch", true);
CFGEOF
DOCKEREOF

cat > /opt/vcf-chromium/Dockerfile <<'DOCKEREOF'
FROM lscr.io/linuxserver/chromium:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq unzip openssh-client iputils-ping dnsutils ca-certificates tmux nano less \
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
    { "name": "Home", "url": "https://home.lab.sg" },
  ]
}
POLEOF
DOCKEREOF

docker build -t vcf-firefox:latest /opt/vcf-firefox

# 4. Install vdi-ctl session manager CLI
cat > /usr/local/bin/vdi-ctl <<'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -f /etc/vdi-ctl.conf ]] && source /etc/vdi-ctl.conf

PORT_START=10000
PORT_END=10020
MAX_SESSIONS=3
LAB_DNS="${LAB_DNS:-172.16.0.6}"
TIMEZONE="${TIMEZONE:-Asia/Singapore}"

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
      docker build -t vcf-chromium:latest /opt/vcf-chromium >/dev/null
    fi
    echo "vcf-chromium:latest"
  else
    echo "vcf-firefox:latest"
  fi
}

cmd_start() {
  local user="" browser="firefox" cf_token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chrome|--chromium) browser="chrome"; shift ;;
      --firefox|-ff)       browser="firefox"; shift ;;
      -cf|--cf)
        cf_token="${2:?Error: -cf requires a Cloudflare Tunnel token}"
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

  [[ -n "$user" ]] || { echo "Usage: vdi-ctl start <username> [--chrome] [-cf <token>]" >&2; exit 1; }
  local cname="selkies-${user}"
  local cf_cname="cf-${user}"

  if docker ps --filter "name=^/${cname}$" --format '{{.Names}}' | grep -qx "$cname"; then
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
  pass=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)
  host_ip=$(hostname -I | awk '{print $1}')
  [[ -n "$LAB_DNS" && "$LAB_DNS" != "none" ]] && dns_args=(--dns "$LAB_DNS")

  docker run -d --rm \
    --name "$cname" \
    --hostname "vcf-${browser}-${user}" \
    --shm-size=1gb \
    --memory=1800m \
    --cpus=2 \
    --tmpfs /config/Downloads:rw,noexec,nosuid,size=512m \
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
    docker run -d --rm \
      --name "$cf_cname" \
      --network "container:${cname}" \
      --memory=128m \
      --cpus=0.5 \
      --label "app=vcf-selkies-cf" \
      --label "vdi.user=${user}" \
      cloudflare/cloudflared:latest \
      tunnel --no-autoupdate run --token "$cf_token" >/dev/null
  fi

  echo "=========================================="
  echo " User     : ${user} (${browser})"
  echo " LAN URL  : https://${host_ip}:${port}"
  if [[ -n "$cf_token" ]]; then
    echo " CF Tunnel: Attached (${cf_cname} -> https://localhost:3001)"
  fi
  echo " Login    : ${user}"
  echo " Password : ${pass}"
  echo "=========================================="
}

cmd_stop() {
  local user="${1:?Usage: vdi-ctl stop <username>}"
  docker stop "cf-${user}" >/dev/null 2>&1 || true
  docker stop "selkies-${user}" >/dev/null
  echo "Stopped and wiped ephemeral session for '${user}'."
}

cmd_list() {
  docker ps --filter "label=app=vcf-selkies" \
    --format "table {{.Label \"vdi.user\"}}\t{{.Label \"vdi.browser\"}}\t{{.Names}}\t{{.Label \"vdi.port\"}}\t{{.Status}}"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop)  cmd_stop "${2:-}" ;;
  list)  cmd_list ;;
  *)     echo "Usage: vdi-ctl {start <user> [--chrome] [-cf <token>] | stop <user> | list}" >&2; exit 1 ;;
esac
CTLEOF
chmod +x /usr/local/bin/vdi-ctl
mv /root/vdi.env /etc/vdi-ctl.conf
chmod 600 /etc/vdi-ctl.conf

# 5. Install lightweight Python stdlib REST API daemon
cat > /usr/local/bin/vdi-api.py <<'APIEOF'
#!/usr/bin/env python3
import hmac, json, os, re, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = os.environ.get("VDI_API_KEY", "")
USER_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
TOKEN_RE = re.compile(r"^[a-zA-Z0-9._=-]{10,512}$")

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

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/sessions":
            res = subprocess.run(
                ["docker", "ps", "--filter", "label=app=vcf-selkies", "--format", "{{json .}}"],
                capture_output=True, text=True
            )
            sessions = []
            for line in res.stdout.strip().splitlines():
                item = json.loads(line)
                labels = dict(kv.split("=", 1) for kv in item.get("Labels", "").split(",") if "=" in kv)
                sessions.append({
                    "user": labels.get("vdi.user"),
                    "browser": labels.get("vdi.browser"),
                    "port": labels.get("vdi.port"),
                    "container": item.get("Names"),
                    "status": item.get("Status"),
                })
            return self._send(200, {"sessions": sessions})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._auth():
            return self._send(401, {"error": "unauthorized"})
        if self.path != "/sessions":
            return self._send(404, {"error": "not found"})

        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})

        user = data.get("user", "")
        browser = data.get("browser", "firefox")
        cf_token = data.get("cf_token", "")

        if not USER_RE.match(user):
            return self._send(400, {"error": "invalid user (alphanumeric, 1-32 chars)"})
        if browser not in ("firefox", "chrome"):
            return self._send(400, {"error": "browser must be firefox or chrome"})
        if cf_token and not TOKEN_RE.match(cf_token):
            return self._send(400, {"error": "invalid cf_token format"})

        cmd = ["/usr/local/bin/vdi-ctl", "start", user]
        if browser == "chrome":
            cmd.append("--chrome")
        if cf_token:
            cmd.extend(["-cf", cf_token])

        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            return self._send(409, {"error": res.stderr.strip() or res.stdout.strip()})

        parsed = {"raw": res.stdout.strip()}
        for line in res.stdout.splitlines():
            if ":" in line:
                k, v = [x.strip() for x in line.split(":", 1)]
                if k in ("User", "LAN URL", "CF Tunnel", "Login", "Password"):
                    parsed[k.lower().replace(" ", "_")] = v
        return self._send(201, parsed)

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

systemctl daemon-reload
systemctl enable --now vdi-api
INSIDE_EOF

pct push "$CTID" "${HOST_TMP}/vdi.env" /root/vdi.env --perms 600
pct push "$CTID" "${HOST_TMP}/setup-inside-lxc.sh" /root/setup-inside-lxc.sh --perms 700
log "Installing Docker, REST API, and building shared vcf-firefox image inside LXC ${CTID}..."
pct exec "$CTID" -- /root/setup-inside-lxc.sh
pct exec "$CTID" -- rm -f /root/setup-inside-lxc.sh

cat > /usr/local/bin/vdi-ctl <<WRAPEOF
#!/usr/bin/env bash
exec pct exec ${CTID} -- /usr/local/bin/vdi-ctl "\$@"
WRAPEOF
chmod +x /usr/local/bin/vdi-ctl

HOST_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
echo
echo "========================================================"
ok "Shared Selkies Docker Host + REST API ready on LXC ${CTID}"
echo "--------------------------------------------------------"
echo "  REST Endpoint : http://${HOST_IP}:${API_PORT}"
echo "  Bearer Token  : ${API_KEY}"
echo "  Start (REST)  : curl -X POST http://${HOST_IP}:${API_PORT}/sessions -H 'Authorization: Bearer ${API_KEY}' -d '{\"user\":\"alice\"}'"
echo "  CLI Shortcut  : vdi-ctl {start <user> [--chrome] [-cf <token>] | stop <user> | list}"
echo "========================================================"