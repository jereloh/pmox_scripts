#!/usr/bin/env bash
# easy-openldap.sh
#
# Proxmox VE helper-style installer for:
#   - Debian LXC
#   - Native OpenLDAP (slapd)
#   - phpLDAPadmin
#   - memberOf overlay
#
# Inspired by the interaction pattern used by the Proxmox VE Community Scripts:
#   - Default vs Advanced settings
#   - whiptail TUI
#   - CTID / hostname / resources / storage / network configuration
#   - confirmation screen before creation
#
# Run on the Proxmox VE HOST:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jereloh/pmox_scripts/main/easy-openldap.sh)"
#
# Default settings:
#   OS:           Debian 13
#   Hostname:     openldap
#   CPU:          1 core
#   RAM:          512 MB
#   Swap:         256 MB
#   Disk:         8 GB
#   Network:      DHCP
#   Bridge:       vmbr0
#   Unprivileged: yes
#
# The LDAP domain and administrator password are always requested.
#
# IMPORTANT:
# - Intended for a new container.
# - LDAP administrator password is not saved by this script.
# - phpLDAPadmin is intended for a trusted management network.

set -Eeuo pipefail
IFS=$'\n\t'

APP="OpenLDAP"
SCRIPT_NAME="easy-openldap.sh"
HOST_LOG="/var/log/easy-openldap.log"
BACKTITLE="Easy OpenLDAP - Proxmox VE"

exec > >(tee -a "$HOST_LOG") 2>&1
trap 'rc=$?; echo; echo "[ERROR] ${SCRIPT_NAME} failed at line ${LINENO} (exit ${rc})." >&2; echo "Log: ${HOST_LOG}" >&2; exit ${rc}' ERR

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

cleanup() {
  [[ -n "${GUEST_SCRIPT:-}" && -f "${GUEST_SCRIPT:-}" ]] && rm -f "$GUEST_SCRIPT" || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------

need_root() {
  [[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox VE host."
}

check_pve() {
  command -v pct >/dev/null 2>&1 || die "'pct' not found. This must run on a Proxmox VE host."
  command -v pveam >/dev/null 2>&1 || die "'pveam' not found."
  command -v pvesm >/dev/null 2>&1 || die "'pvesm' not found."
  command -v pvesh >/dev/null 2>&1 || die "'pvesh' not found."

  case "$(uname -m)" in
    x86_64)
      HOST_ARCH="amd64"
      ;;
    aarch64|arm64)
      HOST_ARCH="arm64"
      ;;
    *)
      die "Unsupported Proxmox host architecture: $(uname -m)"
      ;;
  esac

  ok "Detected Proxmox host architecture: ${HOST_ARCH}"
}

ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail..."
    apt-get update -qq
    apt-get install -y whiptail >/dev/null
  fi
}

next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null
}

ctid_in_use() {
  pct status "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# TUI helpers
# ---------------------------------------------------------------------------

ui_msg() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 70
}

ui_input() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --inputbox "$prompt" 10 68 "$default" \
    3>&1 1>&2 2>&3
}

ui_password() {
  local title="$1"
  local prompt="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --passwordbox "$prompt" 10 68 \
    3>&1 1>&2 2>&3
}

ui_yesno() {
  local title="$1"
  local prompt="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --yesno "$prompt" 12 70
}

ui_menu() {
  local title="$1"
  local prompt="$2"
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "$prompt" 18 74 10 "$@" \
    3>&1 1>&2 2>&3
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

validate_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$ ]]
}

validate_uint() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 ))
}

validate_domain() {
  local d="$1" part
  [[ "$d" == *.* ]] || return 1
  IFS='.' read -r -a _parts <<< "$d"
  for part in "${_parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
  done
}

domain_to_base_dn() {
  local d="$1" part out=""
  IFS='.' read -r -a _parts <<< "$d"
  for part in "${_parts[@]}"; do
    [[ -n "$out" ]] && out+=","
    out+="dc=${part}"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Storage / bridge discovery
# ---------------------------------------------------------------------------

list_template_storages() {
  pvesm status --content vztmpl 2>/dev/null |
    awk 'NR>1 && $3=="active" {print $1}'
}

list_rootfs_storages() {
  pvesm status --content rootdir 2>/dev/null |
    awk 'NR>1 && $3=="active" {print $1}'
}

list_bridges() {
  ip -o link show |
    awk -F': ' '$2 ~ /^vmbr[0-9]+(@|$)/ {sub(/@.*/,"",$2); print $2}' |
    sort -u
}

choose_storage_menu() {
  local type="$1"
  local default="$2"
  local -a items=()
  local s

  if [[ "$type" == "template" ]]; then
    while read -r s; do
      [[ -n "$s" ]] && items+=("$s" "Template storage")
    done < <(list_template_storages)
  else
    while read -r s; do
      [[ -n "$s" ]] && items+=("$s" "Container rootfs storage")
    done < <(list_rootfs_storages)
  fi

  ((${#items[@]} > 0)) || die "No suitable Proxmox storage found."

  if [[ ${#items[@]} -eq 2 ]]; then
    printf '%s' "${items[0]}"
    return
  fi

  ui_menu "STORAGE" "Select ${type} storage" "${items[@]}"
}

choose_bridge_menu() {
  local -a items=()
  local b
  while read -r b; do
    [[ -n "$b" ]] && items+=("$b" "Linux bridge")
  done < <(list_bridges)

  ((${#items[@]} > 0)) || die "No vmbr bridge found."

  if [[ ${#items[@]} -eq 2 ]]; then
    printf '%s' "${items[0]}"
    return
  fi

  ui_menu "NETWORK BRIDGE" "Select bridge" "${items[@]}"
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

default_settings() {
  METHOD="Default"
  CTID="$(next_ctid)"
  CT_HOSTNAME="openldap"
  DEBIAN_RELEASE="13"
  CT_CORES="1"
  CT_MEMORY="512"
  CT_SWAP="256"
  CT_DISK_GB="8"
  CT_UNPRIVILEGED="1"
  CT_NET_MODE="dhcp"
  CT_IPV4="dhcp"
  CT_GATEWAY=""
  CT_VLAN=""
  CT_BRIDGE="$(list_bridges | grep -Fx 'vmbr0' | head -1 || true)"
  [[ -n "$CT_BRIDGE" ]] || CT_BRIDGE="$(list_bridges | head -1)"
  TEMPLATE_STORAGE="$(list_template_storages | head -1)"
  CT_STORAGE="$(list_rootfs_storages | head -1)"

  [[ -n "$CT_BRIDGE" ]] || die "No Proxmox bridge found."
  [[ -n "$TEMPLATE_STORAGE" ]] || die "No template storage found."
  [[ -n "$CT_STORAGE" ]] || die "No rootfs storage found."
}

advanced_settings() {
  METHOD="Advanced"

  local val

  while true; do
    val="$(ui_input "CONTAINER ID" "Set Container ID" "$(next_ctid)")" || exit 0
    [[ -z "$val" ]] && val="$(next_ctid)"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
      ui_msg "INVALID VALUE" "Container ID must be numeric."
      continue
    fi
    if ctid_in_use "$val"; then
      ui_msg "ID IN USE" "CTID ${val} is already in use."
      continue
    fi
    CTID="$val"
    break
  done

  while true; do
    val="$(ui_input "HOSTNAME" "Set container hostname" "openldap")" || exit 0
    if validate_hostname "$val"; then
      CT_HOSTNAME="$val"
      break
    fi
    ui_msg "INVALID HOSTNAME" "Enter a valid hostname, for example: openldap"
  done

  DEBIAN_RELEASE="$(
    ui_menu "DEBIAN VERSION" "Select Debian release" \
      "13" "Debian 13" \
      "12" "Debian 12"
  )" || exit 0

  while true; do
    val="$(ui_input "CPU CORES" "Number of CPU cores" "1")" || exit 0
    if validate_uint "$val"; then CT_CORES="$val"; break; fi
    ui_msg "INVALID VALUE" "CPU cores must be a positive integer."
  done

  while true; do
    val="$(ui_input "MEMORY" "RAM in MB" "512")" || exit 0
    if validate_uint "$val"; then CT_MEMORY="$val"; break; fi
    ui_msg "INVALID VALUE" "Memory must be a positive integer."
  done

  val="$(ui_input "SWAP" "Swap in MB" "256")" || exit 0
  [[ "$val" =~ ^[0-9]+$ ]] || {
    ui_msg "INVALID VALUE" "Swap must be zero or a positive integer."
    advanced_settings
    return
  }
  CT_SWAP="$val"

  while true; do
    val="$(ui_input "DISK SIZE" "Root disk size in GB" "8")" || exit 0
    if validate_uint "$val"; then CT_DISK_GB="$val"; break; fi
    ui_msg "INVALID VALUE" "Disk size must be a positive integer."
  done

  TEMPLATE_STORAGE="$(choose_storage_menu template "")" || exit 0
  CT_STORAGE="$(choose_storage_menu rootfs "")" || exit 0
  CT_BRIDGE="$(choose_bridge_menu)" || exit 0

  CT_NET_MODE="$(
    ui_menu "NETWORK" "Select IPv4 configuration" \
      "dhcp" "DHCP" \
      "static" "Static IPv4"
  )" || exit 0

  CT_IPV4="dhcp"
  CT_GATEWAY=""

  if [[ "$CT_NET_MODE" == "static" ]]; then
    while true; do
      val="$(ui_input "STATIC IPV4" "IPv4 address in CIDR format, e.g. 172.16.0.20/24" "")" || exit 0
      if [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        CT_IPV4="$val"
        break
      fi
      ui_msg "INVALID IPV4" "Enter an IPv4 address with prefix, e.g. 172.16.0.20/24"
    done
    CT_GATEWAY="$(ui_input "GATEWAY" "IPv4 default gateway, e.g. 172.16.0.1" "")" || exit 0
    [[ -n "$CT_GATEWAY" ]] || {
      ui_msg "INVALID GATEWAY" "A gateway is required for static IPv4."
      advanced_settings
      return
    }
  fi

  CT_VLAN="$(ui_input "VLAN" "VLAN tag (leave blank for none)" "")" || exit 0
  if [[ -n "$CT_VLAN" && ! "$CT_VLAN" =~ ^[0-9]+$ ]]; then
    ui_msg "INVALID VLAN" "VLAN must be numeric or blank."
    advanced_settings
    return
  fi

  if ui_yesno "CONTAINER TYPE" "Create an unprivileged LXC?\n\nRecommended: Yes"; then
    CT_UNPRIVILEGED="1"
  else
    CT_UNPRIVILEGED="0"
  fi
}

select_settings_mode() {
  if ui_yesno "SETTINGS" \
    "Use Default Settings?\n\nDefault:\n  Debian 13\n  1 CPU\n  512 MB RAM\n  8 GB disk\n  DHCP\n  Unprivileged LXC"; then
    default_settings
  else
    advanced_settings
  fi
}

# ---------------------------------------------------------------------------
# LDAP application settings
# ---------------------------------------------------------------------------

prompt_ldap_settings() {
  local val p1 p2

  while true; do
    val="$(ui_input "LDAP DOMAIN" \
      "Enter the LDAP naming domain.\n\nExample: lab.local\n\nThis will become dc=lab,dc=local" \
      "")" || exit 0

    val="${val//[[:space:]]/}"

    if validate_domain "$val"; then
      LDAP_DOMAIN="$val"
      break
    fi

    ui_msg "INVALID LDAP DOMAIN" \
      "Enter a DNS-style name containing at least two labels.\n\nExample: lab.local"
  done

  BASE_DN="$(domain_to_base_dn "$LDAP_DOMAIN")"
  FIRST_DC="${LDAP_DOMAIN%%.*}"
  LDAP_ADMIN_DN="cn=admin,${BASE_DN}"
  PEOPLE_DN="ou=people,${BASE_DN}"
  GROUPS_DN="ou=groups,${BASE_DN}"

  while true; do
    p1="$(ui_password "LDAP ADMIN PASSWORD" \
      "Administrator DN:\n${LDAP_ADMIN_DN}\n\nEnter a password (minimum 8 characters):")" || exit 0

    if ((${#p1} < 8)); then
      ui_msg "PASSWORD TOO SHORT" "Use at least 8 characters."
      continue
    fi

    p2="$(ui_password "CONFIRM PASSWORD" "Re-enter the LDAP administrator password:")" || exit 0

    if [[ "$p1" != "$p2" ]]; then
      ui_msg "PASSWORD MISMATCH" "Passwords do not match."
      continue
    fi

    LDAP_ADMIN_PASSWORD="$p1"
    unset p1 p2
    break
  done
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

settings_summary() {
  local network_summary
  if [[ "$CT_NET_MODE" == "dhcp" ]]; then
    network_summary="DHCP"
  else
    network_summary="${CT_IPV4}, GW ${CT_GATEWAY}"
  fi

  cat <<EOF
Method:             ${METHOD}

Container
  CTID:             ${CTID}
  Hostname:         ${CT_HOSTNAME}
  OS:               Debian ${DEBIAN_RELEASE}
  Architecture:     ${HOST_ARCH}
  CPU:              ${CT_CORES} core(s)
  RAM:              ${CT_MEMORY} MB
  Swap:             ${CT_SWAP} MB
  Disk:             ${CT_DISK_GB} GB
  Rootfs storage:   ${CT_STORAGE}
  Template storage: ${TEMPLATE_STORAGE}
  Bridge:           ${CT_BRIDGE}
  Network:          ${network_summary}
  VLAN:             ${CT_VLAN:-none}
  Unprivileged:     $([[ "$CT_UNPRIVILEGED" == 1 ]] && echo yes || echo no)

LDAP
  Domain:           ${LDAP_DOMAIN}
  Base DN:          ${BASE_DN}
  Administrator:    ${LDAP_ADMIN_DN}
  Users OU:         ${PEOPLE_DN}
  Groups OU:        ${GROUPS_DN}
EOF
}

confirm_settings() {
  local summary
  summary="$(settings_summary)"

  if ! whiptail --backtitle "$BACKTITLE" \
    --title "READY TO CREATE" \
    --yesno "${summary}\n\nCreate the LXC and install OpenLDAP?" \
    32 78; then

    if ui_yesno "DO OVER" "Return to settings and start over?"; then
      main_menu
      exit 0
    fi
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Template handling
# ---------------------------------------------------------------------------

find_debian_template() {
  info "Refreshing Proxmox template index..."
  pveam update >/dev/null

  # IMPORTANT: Proxmox may publish both amd64 and arm64 templates.
  # Never select a template for the wrong CPU architecture: doing so
  # creates an LXC that fails at /sbin/init with "Exec format error".
  TEMPLATE_NAME="$(
    pveam available --section system 2>/dev/null |
      awk -v rel="$DEBIAN_RELEASE" -v arch="$HOST_ARCH" '
        $2 ~ ("debian-" rel "-standard") && $2 ~ ("_" arch "\\.tar") {print $2}
      ' |
      sort -V |
      tail -1
  )"

  [[ -n "$TEMPLATE_NAME" ]] ||
    die "Unable to find a Debian ${DEBIAN_RELEASE} ${HOST_ARCH} standard template."

  case "$TEMPLATE_NAME" in
    *_"${HOST_ARCH}".tar.*) ;;
    *) die "Safety check failed: template '${TEMPLATE_NAME}' does not match host architecture '${HOST_ARCH}'." ;;
  esac

  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
  info "Selected template: ${TEMPLATE_NAME}"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null |
       awk 'NR>1 {print $1}' |
       grep -Fxq "$TEMPLATE_REF"; then
    info "Downloading ${TEMPLATE_NAME}..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
  fi
}

# ---------------------------------------------------------------------------
# LXC creation
# ---------------------------------------------------------------------------

create_lxc() {
  info "Creating LXC ${CTID} (${CT_HOSTNAME})..."

  local net="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IPV4},type=veth"
  [[ -n "$CT_GATEWAY" ]] && net+=",gw=${CT_GATEWAY}"
  [[ -n "$CT_VLAN" ]] && net+=",tag=${CT_VLAN}"

  pct create "$CTID" "$TEMPLATE_REF" \
    --arch "$HOST_ARCH" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    --net0 "$net" \
    --unprivileged "$CT_UNPRIVILEGED" \
    --onboot 1 \
    --start 0

  local created_arch
  created_arch="$(pct config "$CTID" | awk '/^arch:/ {print $2}')"
  if [[ "$created_arch" != "$HOST_ARCH" ]]; then
    die "Created LXC architecture is '${created_arch:-unknown}', expected '${HOST_ARCH}'. Refusing to start it."
  fi

  ok "LXC ${CTID} created with architecture ${created_arch}."
}

start_lxc() {
  info "Starting LXC ${CTID}..."
  pct start "$CTID"

  local i
  for i in {1..60}; do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then
      ok "Container is ready."
      return
    fi
    sleep 2
  done

  die "Container did not become ready."
}

# ---------------------------------------------------------------------------
# Guest installer
# ---------------------------------------------------------------------------

build_guest_installer() {
  GUEST_SCRIPT="$(mktemp)"

  cat > "$GUEST_SCRIPT" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

LDAP_DOMAIN="${LDAP_DOMAIN:?}"
BASE_DN="${BASE_DN:?}"
FIRST_DC="${FIRST_DC:?}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:?}"
PEOPLE_DN="${PEOPLE_DN:?}"
GROUPS_DN="${GROUPS_DN:?}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:?}"

info() { echo "[INFO] $*"; }
ok()   { echo "[ OK ] $*"; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

info "Updating Debian..."
apt-get update
apt-get -y upgrade

info "Installing OpenLDAP, Apache and phpLDAPadmin..."

debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_DOMAIN} Directory
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
EOF

apt-get install -y --no-install-recommends \
  slapd ldap-utils \
  apache2 libapache2-mod-php phpldapadmin \
  openssl ssl-cert ca-certificates

systemctl enable --now slapd apache2

DB_DN="$(
  ldapsearch -LLL -Y EXTERNAL -H ldapi:/// \
    -b cn=config "(olcSuffix=${BASE_DN})" dn 2>/dev/null |
    awk '/^dn: /{sub(/^dn: /,""); print; exit}'
)"
[[ -n "$DB_DN" ]] || die "Could not find OpenLDAP database for ${BASE_DN}."

# Load memberof module if required.
if ! ldapsearch -LLL -Y EXTERNAL -H ldapi:/// \
  -b cn=config '(objectClass=olcModuleList)' olcModuleLoad 2>/dev/null |
  grep -Eq '^olcModuleLoad: .*memberof'; then

  MODULE_DN="$(
    ldapsearch -LLL -Y EXTERNAL -H ldapi:/// \
      -b cn=config '(objectClass=olcModuleList)' dn 2>/dev/null |
      awk '/^dn: /{sub(/^dn: /,""); print; exit}'
  )"

  if [[ -n "$MODULE_DN" ]]; then
    ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: ${MODULE_DN}
changetype: modify
add: olcModuleLoad
olcModuleLoad: memberof
EOF
  else
    ldapadd -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/ldap
olcModuleLoad: memberof
EOF
  fi
fi

# Add memberOf overlay.
if ! ldapsearch -LLL -Y EXTERNAL -H ldapi:/// \
  -b "$DB_DN" '(olcOverlay=memberof*)' dn 2>/dev/null |
  grep -q '^dn:'; then

  ldapadd -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: olcOverlay=memberof,${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
EOF
fi

entry_exists() {
  ldapsearch -LLL -x \
    -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$1" -s base '(objectClass=*)' dn 2>/dev/null |
    grep -q '^dn:'
}

# Base entry may already have been created by Debian slapd configuration.
if ! entry_exists "$BASE_DN"; then
  ldapadd -x -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: domain
dc: ${FIRST_DC}
description: ${LDAP_DOMAIN} Directory
EOF
fi

if ! entry_exists "$PEOPLE_DN"; then
  ldapadd -x -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: ${PEOPLE_DN}
objectClass: top
objectClass: organizationalUnit
ou: people
description: User accounts
EOF
fi

if ! entry_exists "$GROUPS_DN"; then
  ldapadd -x -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: ${GROUPS_DN}
objectClass: top
objectClass: organizationalUnit
ou: groups
description: Groups
EOF
fi

# Configure phpLDAPadmin.
CFG="/etc/phpldapadmin/config.php"
[[ -f "$CFG" ]] || die "phpLDAPadmin config not found."

cp -a "$CFG" "${CFG}.pre-easy-openldap"

cat > /etc/phpldapadmin/easy-openldap.php <<EOF
<?php
\$servers->setValue('server','name','OpenLDAP (${LDAP_DOMAIN})');
\$servers->setValue('server','host','127.0.0.1');
\$servers->setValue('server','port',389);
\$servers->setValue('server','base',array('${BASE_DN}'));
\$servers->setValue('login','auth_type','session');
\$servers->setValue('login','bind_id','${LDAP_ADMIN_DN}');
\$servers->setValue('login','attr','dn');
EOF

chmod 0640 /etc/phpldapadmin/easy-openldap.php
chown root:www-data /etc/phpldapadmin/easy-openldap.php

if ! grep -q 'easy-openldap.php' "$CFG"; then
  if grep -q '^?>' "$CFG"; then
    sed -i "/^?>/i require_once '/etc/phpldapadmin/easy-openldap.php';" "$CFG"
  else
    printf "\nrequire_once '/etc/phpldapadmin/easy-openldap.php';\n" >> "$CFG"
  fi
fi

if [[ -e /etc/apache2/conf-available/phpldapadmin.conf ]]; then
  a2enconf phpldapadmin >/dev/null 2>&1 || true
elif [[ -e /etc/phpldapadmin/apache.conf ]]; then
  ln -sf /etc/phpldapadmin/apache.conf \
    /etc/apache2/conf-available/phpldapadmin.conf
  a2enconf phpldapadmin >/dev/null 2>&1 || true
fi

a2enmod ssl rewrite >/dev/null
a2ensite default-ssl >/dev/null

cat > /etc/apache2/conf-available/easy-openldap-https.conf <<'EOF'
RewriteEngine On
RewriteCond %{HTTPS} !=on
RewriteRule ^/phpldapadmin(.*)$ https://%{HTTP_HOST}/phpldapadmin$1 [R=302,L]
EOF

a2enconf easy-openldap-https >/dev/null
apache2ctl configtest >/dev/null
systemctl restart apache2

# Validation 1: base scope must return exactly one object.
COUNT="$(
  ldapsearch -LLL -x \
    -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$BASE_DN" -s base '(objectClass=*)' dn 2>/dev/null |
    grep -c '^dn:' || true
)"

[[ "$COUNT" == "1" ]] ||
  die "Base-scope validation returned ${COUNT} objects; expected 1."

# Validation 2: inetOrgPerson + groupOfNames + memberOf + entryUUID.
TEST_USER="uid=vcf-install-test,${PEOPLE_DN}"
TEST_GROUP="cn=vcf-install-test,${GROUPS_DN}"
TEST_HASH="$(slappasswd -s "$(openssl rand -hex 18)")"

ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASSWORD" "$TEST_GROUP" >/dev/null 2>&1 || true
ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASSWORD" "$TEST_USER" >/dev/null 2>&1 || true

ldapadd -x -H ldap://127.0.0.1 \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: ${TEST_USER}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: vcf-install-test
cn: VCF Install Test
sn: Test
mail: vcf-install-test@${LDAP_DOMAIN}
userPassword: ${TEST_HASH}

dn: ${TEST_GROUP}
objectClass: top
objectClass: groupOfNames
cn: vcf-install-test
member: ${TEST_USER}
EOF

MEMBEROF="$(
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$TEST_USER" -s base '(objectClass=*)' memberOf 2>/dev/null |
    awk '/^memberOf: /{sub(/^memberOf: /,""); print; exit}'
)"

UUID="$(
  ldapsearch -LLL -x -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$TEST_USER" -s base '(objectClass=*)' entryUUID 2>/dev/null |
    awk '/^entryUUID: /{print $2; exit}'
)"

[[ "$MEMBEROF" == "$TEST_GROUP" ]] || die "memberOf validation failed."
[[ -n "$UUID" ]] || die "entryUUID validation failed."

ldapdelete -x -H ldap://127.0.0.1 \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_GROUP" >/dev/null
ldapdelete -x -H ldap://127.0.0.1 \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_USER" >/dev/null

# Backup helper.
cat > /usr/local/sbin/backup-openldap <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
OUT_DIR="${1:-/var/backups/openldap}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"
slapcat -n 0 | gzip -9 > "$OUT_DIR/cn-config-${STAMP}.ldif.gz"
slapcat -n 1 | gzip -9 > "$OUT_DIR/directory-${STAMP}.ldif.gz"
echo "Backup written to: $OUT_DIR"
EOF
chmod 0750 /usr/local/sbin/backup-openldap

cat > /root/OPENLDAP-README.txt <<EOF
OpenLDAP quick reference
========================

Base DN:
  ${BASE_DN}

Administrator DN:
  ${LDAP_ADMIN_DN}

Users:
  ${PEOPLE_DN}

Groups:
  ${GROUPS_DN}

VCF-oriented attributes:
  Users filter:         (objectClass=inetOrgPerson)
  Groups filter:        (objectClass=groupOfNames)
  User search attr:     uid
  Group search attr:    cn
  Object UUID:          entryUUID
  Membership:           memberOf
  Group member:         member

Backup:
  /usr/local/sbin/backup-openldap

The LDAP administrator password is not stored by this installer.
EOF
chmod 0600 /root/OPENLDAP-README.txt

ok "OpenLDAP guest installation complete."
GUEST

  chmod 0700 "$GUEST_SCRIPT"
}

run_guest_installer() {
  pct push "$CTID" "$GUEST_SCRIPT" /root/easy-openldap-guest.sh --perms 0700

  info "Installing OpenLDAP inside LXC ${CTID}..."

  # Password is passed to guest installer through stdin, not written into the script.
  printf '%s\n' "$LDAP_ADMIN_PASSWORD" |
    pct exec "$CTID" -- bash -c "
      set -Eeuo pipefail
      IFS= read -r LDAP_ADMIN_PASSWORD
      export LDAP_ADMIN_PASSWORD
      export LDAP_DOMAIN=$(printf '%q' "$LDAP_DOMAIN")
      export BASE_DN=$(printf '%q' "$BASE_DN")
      export FIRST_DC=$(printf '%q' "$FIRST_DC")
      export LDAP_ADMIN_DN=$(printf '%q' "$LDAP_ADMIN_DN")
      export PEOPLE_DN=$(printf '%q' "$PEOPLE_DN")
      export GROUPS_DN=$(printf '%q' "$GROUPS_DN")
      exec /root/easy-openldap-guest.sh
    "

  pct exec "$CTID" -- rm -f /root/easy-openldap-guest.sh || true
  unset LDAP_ADMIN_PASSWORD
}

get_lxc_ip() {
  local i ip=""
  for i in {1..60}; do
    ip="$(
      pct exec "$CTID" -- sh -c \
        "ip -4 -o addr show dev eth0 scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" \
        2>/dev/null || true
    )"
    [[ -n "$ip" ]] && break
    sleep 2
  done
  printf '%s' "${ip:-<check-container-IP>}"
}

show_completion() {
  local ip
  ip="$(get_lxc_ip)"

  local msg
  msg="OpenLDAP installation completed successfully.

LXC
  CTID:      ${CTID}
  Hostname:  ${CT_HOSTNAME}
  IP:        ${ip}

phpLDAPadmin
  https://${ip}/phpldapadmin

Login DN
  ${LDAP_ADMIN_DN}

LDAP
  Base DN:   ${BASE_DN}
  Users:     ${PEOPLE_DN}
  Groups:    ${GROUPS_DN}

Use the LDAP administrator password entered during setup.

The password was NOT saved to disk.

Container notes:
  /root/OPENLDAP-README.txt"

  ui_msg "INSTALLATION COMPLETE" "$msg"

  echo
  echo "=============================================================="
  echo " OpenLDAP installation complete"
  echo "=============================================================="
  echo " CTID:        ${CTID}"
  echo " Hostname:    ${CT_HOSTNAME}"
  echo " IP:          ${ip}"
  echo
  echo " Web UI:"
  echo "   https://${ip}/phpldapadmin"
  echo
  echo " Login DN:"
  echo "   ${LDAP_ADMIN_DN}"
  echo
  echo " Base DN:"
  echo "   ${BASE_DN}"
  echo
  echo " Host log:"
  echo "   ${HOST_LOG}"
  echo "=============================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main_menu() {
  select_settings_mode
  prompt_ldap_settings
  confirm_settings

  find_debian_template
  create_lxc
  start_lxc
  build_guest_installer
  run_guest_installer
  show_completion
}

main() {
  need_root
  check_pve
  ensure_whiptail

  ui_msg "EASY OPENLDAP" \
    "This helper creates a Debian LXC and installs native OpenLDAP + phpLDAPadmin.

Choose Default or Advanced container settings on the next screen."

  main_menu
}

main "$@"
