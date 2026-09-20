#!/usr/bin/env bash
# easy-openldap.sh
#
# Proxmox VE helper-style installer:
#   1. Run this script on the Proxmox VE host.
#   2. It creates a fresh Debian LXC.
#   3. It installs native OpenLDAP + phpLDAPadmin inside the LXC.
#   4. It enables memberOf and validates correct LDAP search-scope behavior.
#
# Interactive questions:
#   - LDAP domain (for example: lab.local)
#   - LDAP administrator password
#
# Everything else is auto-detected, with optional environment overrides.
#
# Example:
#   curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/easy-openldap.sh | bash
#
# Optional overrides:
#   CTID=123
#   CT_HOSTNAME=openldap
#   CT_CORES=1
#   CT_MEMORY=512
#   CT_SWAP=256
#   CT_DISK_GB=8
#   CT_BRIDGE=vmbr0
#   CT_STORAGE=local-lvm
#   TEMPLATE_STORAGE=local
#   DEBIAN_RELEASE=12
#
# Notes:
#   - Intended for a fresh OpenLDAP deployment.
#   - Uses DHCP for the container network.
#   - Uses an unprivileged LXC.
#   - Does not save the LDAP administrator password to disk.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="easy-openldap.sh"
HOST_LOG="/var/log/easy-openldap.log"

CT_HOSTNAME="${CT_HOSTNAME:-openldap}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_SWAP="${CT_SWAP:-256}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-12}"

exec > >(tee -a "$HOST_LOG") 2>&1
trap 'rc=$?; echo; echo "[ERROR] ${SCRIPT_NAME} failed at line ${LINENO} (exit ${rc})." >&2; echo "Host log: ${HOST_LOG}" >&2; exit ${rc}' ERR

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this script as root on the Proxmox VE host."
}

check_pve_host() {
  command -v pct >/dev/null 2>&1 || die "'pct' not found. Run this on a Proxmox VE host."
  command -v pvesm >/dev/null 2>&1 || die "'pvesm' not found. Run this on a Proxmox VE host."
  command -v pveam >/dev/null 2>&1 || die "'pveam' not found. Run this on a Proxmox VE host."
  command -v pvesh >/dev/null 2>&1 || die "'pvesh' not found. Run this on a Proxmox VE host."
  ok "Proxmox VE host detected."
}

domain_to_base_dn() {
  local domain="$1" part out=""
  IFS='.' read -r -a parts <<< "$domain"
  ((${#parts[@]} >= 2)) || return 1

  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
    [[ -n "$out" ]] && out+=","
    out+="dc=${part}"
  done
  printf '%s' "$out"
}

prompt_domain() {
  local tty=/dev/tty
  [[ -r "$tty" && -w "$tty" ]] || die "Interactive TTY unavailable."

  echo
  while true; do
    read -r -p "Enter LDAP domain (example: lab.local): " LDAP_DOMAIN < "$tty"
    LDAP_DOMAIN="${LDAP_DOMAIN//[[:space:]]/}"
    [[ -n "$LDAP_DOMAIN" ]] || {
      echo "LDAP domain cannot be empty." > "$tty"
      continue
    }

    if BASE_DN="$(domain_to_base_dn "$LDAP_DOMAIN")"; then
      break
    fi
    echo "Invalid domain. Example: lab.local" > "$tty"
  done

  FIRST_DC="${LDAP_DOMAIN%%.*}"
  LDAP_ADMIN_DN="cn=admin,${BASE_DN}"
  PEOPLE_DN="ou=people,${BASE_DN}"
  GROUPS_DN="ou=groups,${BASE_DN}"
}

prompt_password() {
  local tty=/dev/tty
  local p1 p2

  echo
  echo "LDAP Base DN:"
  echo "  ${BASE_DN}"
  echo
  echo "OpenLDAP administrator DN:"
  echo "  ${LDAP_ADMIN_DN}"
  echo

  while true; do
    read -r -s -p "Enter LDAP administrator password: " p1 < "$tty"
    echo > "$tty"

    [[ ${#p1} -ge 8 ]] || {
      echo "Password must be at least 8 characters." > "$tty"
      continue
    }

    read -r -s -p "Confirm LDAP administrator password: " p2 < "$tty"
    echo > "$tty"

    [[ "$p1" == "$p2" ]] || {
      echo "Passwords do not match. Try again." > "$tty"
      continue
    }

    LDAP_ADMIN_PASSWORD="$p1"
    unset p1 p2
    break
  done
}

next_vmid() {
  if [[ -n "${CTID:-}" ]]; then
    pct status "$CTID" >/dev/null 2>&1 && die "CTID ${CTID} already exists."
    return
  fi

  CTID="$(pvesh get /cluster/nextid 2>/dev/null)"
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Unable to determine next available CTID."
}

storage_supports() {
  local storage="$1" content="$2"
  pvesm status --content "$content" 2>/dev/null |
    awk 'NR>1 {print $1}' |
    grep -Fxq "$storage"
}

detect_template_storage() {
  if [[ -n "${TEMPLATE_STORAGE:-}" ]]; then
    storage_supports "$TEMPLATE_STORAGE" vztmpl ||
      die "TEMPLATE_STORAGE '${TEMPLATE_STORAGE}' does not support container templates."
    return
  fi

  TEMPLATE_STORAGE="$(
    pvesm status --content vztmpl 2>/dev/null |
      awk 'NR>1 && $3=="active" {print $1; exit}'
  )"
  [[ -n "$TEMPLATE_STORAGE" ]] || die "No active Proxmox storage supporting 'vztmpl' was found."
}

detect_rootfs_storage() {
  if [[ -n "${CT_STORAGE:-}" ]]; then
    storage_supports "$CT_STORAGE" rootdir ||
      die "CT_STORAGE '${CT_STORAGE}' does not support container root filesystems."
    return
  fi

  CT_STORAGE="$(
    pvesm status --content rootdir 2>/dev/null |
      awk 'NR>1 && $3=="active" {print $1; exit}'
  )"
  [[ -n "$CT_STORAGE" ]] || die "No active Proxmox storage supporting 'rootdir' was found."
}

check_bridge() {
  ip link show "$CT_BRIDGE" >/dev/null 2>&1 ||
    die "Network bridge '${CT_BRIDGE}' does not exist. Set CT_BRIDGE if your bridge has another name."
}

find_debian_template() {
  info "Refreshing Proxmox template index..."
  pveam update >/dev/null

  TEMPLATE_NAME="$(
    pveam available --section system 2>/dev/null |
      awk -v rel="$DEBIAN_RELEASE" '$2 ~ ("debian-" rel "-standard") {print $2}' |
      sort -V |
      tail -1
  )"

  [[ -n "$TEMPLATE_NAME" ]] ||
    die "Could not find a Debian ${DEBIAN_RELEASE} standard LXC template in pveam."

  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_REF"; then
    info "Downloading ${TEMPLATE_NAME} to ${TEMPLATE_STORAGE}..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
  else
    ok "Template already present: ${TEMPLATE_NAME}"
  fi
}

show_plan() {
  echo
  echo "============================================================"
  echo " OpenLDAP LXC deployment plan"
  echo "============================================================"
  echo " CTID:              ${CTID}"
  echo " Hostname:          ${CT_HOSTNAME}"
  echo " Debian:            ${DEBIAN_RELEASE}"
  echo " Cores:             ${CT_CORES}"
  echo " Memory:            ${CT_MEMORY} MB"
  echo " Swap:              ${CT_SWAP} MB"
  echo " Disk:              ${CT_DISK_GB} GB"
  echo " Rootfs storage:    ${CT_STORAGE}"
  echo " Template storage:  ${TEMPLATE_STORAGE}"
  echo " Bridge:            ${CT_BRIDGE}"
  echo " Network:           DHCP"
  echo
  echo " LDAP domain:       ${LDAP_DOMAIN}"
  echo " Base DN:           ${BASE_DN}"
  echo " Admin DN:          ${LDAP_ADMIN_DN}"
  echo " Users OU:          ${PEOPLE_DN}"
  echo " Groups OU:         ${GROUPS_DN}"
  echo "============================================================"
  echo

  local answer
  read -r -p "Create this LXC and install OpenLDAP? [Y/n]: " answer < /dev/tty
  answer="${answer:-Y}"
  [[ "$answer" =~ ^[Yy]$ ]] || exit 0
}

create_lxc() {
  info "Creating Debian LXC ${CTID}..."

  pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp,type=veth" \
    --unprivileged 1 \
    --features nesting=0 \
    --onboot 1 \
    --start 0

  ok "LXC ${CTID} created."
}

start_lxc() {
  info "Starting LXC ${CTID}..."
  pct start "$CTID"

  local i
  for i in {1..60}; do
    if pct exec "$CTID" -- systemctl is-system-running --wait >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  pct exec "$CTID" -- true >/dev/null 2>&1 ||
    die "Container started but pct exec is not responding."

  ok "LXC ${CTID} is running."
}

build_guest_installer() {
  GUEST_SCRIPT="$(mktemp)"
  chmod 0600 "$GUEST_SCRIPT"

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

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

info "Updating Debian packages..."
apt-get update
apt-get -y upgrade

info "Installing OpenLDAP and phpLDAPadmin..."
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
  slapd ldap-utils apache2 libapache2-mod-php phpldapadmin \
  openssl ssl-cert ca-certificates

systemctl enable --now slapd apache2

DB_DN="$(
  ldapsearch -LLL -Y EXTERNAL -H ldapi:/// \
    -b cn=config "(olcSuffix=${BASE_DN})" dn 2>/dev/null |
    awk '/^dn: /{sub(/^dn: /,""); print; exit}'
)"
[[ -n "$DB_DN" ]] || die "Could not locate LDAP database for ${BASE_DN}."

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
  local dn="$1"
  ldapsearch -LLL -x \
    -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$dn" -s base '(objectClass=*)' dn 2>/dev/null |
    grep -q '^dn:'
}

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


install_vcf_phpldapadmin_templates() {
  info "Installing VCF-friendly phpLDAPadmin templates..."

  local tdir="/etc/phpldapadmin/templates/creation"
  [[ -d "$tdir" ]] || die "phpLDAPadmin creation-template directory not found: $tdir"

  cat > "${tdir}/vcfUser.xml" <<'EOF_XML'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE template SYSTEM "template.dtd">
<template>
  <description>Simple LDAP authentication user for VCF</description>
  <icon>ldap-user.png</icon>
  <invalid>0</invalid>
  <rdn>uid</rdn>
  <noleaf>1</noleaf>
  <title>VCF: User</title>
  <visible>1</visible>

  <objectClasses>
    <objectClass id="inetOrgPerson"></objectClass>
  </objectClasses>

  <attributes>
    <attribute id="uid">
      <display>Username / Login</display>
      <icon>ldap-uid.png</icon>
      <order>1</order>
      <page>1</page>
    </attribute>

    <attribute id="givenName">
      <display>First name</display>
      <icon>ldap-uid.png</icon>
      <onchange>=autoFill(cn;%givenName% %sn%)</onchange>
      <order>2</order>
      <page>1</page>
    </attribute>

    <attribute id="sn">
      <display>Last name</display>
      <icon>ldap-uid.png</icon>
      <onchange>=autoFill(cn;%givenName% %sn%)</onchange>
      <order>3</order>
      <page>1</page>
    </attribute>

    <attribute id="cn">
      <display>Full name</display>
      <icon>ldap-uid.png</icon>
      <order>4</order>
      <page>1</page>
    </attribute>

    <attribute id="mail">
      <display>Email</display>
      <icon>mail.png</icon>
      <order>5</order>
      <page>1</page>
    </attribute>

    <attribute id="userPassword">
      <display>Password</display>
      <icon>lock.png</icon>
      <order>6</order>
      <page>1</page>
      <helper>
        <default>ssha</default>
        <id>enc</id>
        <value>ssha</value>
      </helper>
      <post>=php.PasswordEncrypt(%enc%;%userPassword%)</post>
      <verify>1</verify>
    </attribute>

    <attribute id="description">
      <display>Description</display>
      <order>7</order>
      <page>1</page>
    </attribute>
  </attributes>
</template>
EOF_XML

  cat > "${tdir}/vcfGroup.xml" <<'EOF_XML'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE template SYSTEM "template.dtd">
<template>
  <description>VCF-compatible groupOfNames group</description>
  <icon>ldap-group.png</icon>
  <invalid>0</invalid>
  <rdn>cn</rdn>
  <noleaf>1</noleaf>
  <title>VCF: Group</title>
  <visible>1</visible>

  <objectClasses>
    <objectClass id="groupOfNames"></objectClass>
  </objectClasses>

  <attributes>
    <attribute id="cn">
      <display>Group name</display>
      <icon>ldap-group.png</icon>
      <order>1</order>
      <page>1</page>
    </attribute>

    <attribute id="member">
      <display>Initial member DN</display>
      <order>2</order>
      <page>1</page>
    </attribute>

    <attribute id="description">
      <display>Description</display>
      <order>3</order>
      <page>1</page>
    </attribute>
  </attributes>
</template>
EOF_XML

  chmod 0644 "${tdir}/vcfUser.xml" "${tdir}/vcfGroup.xml"

  php -r '
    foreach (array(
      "/etc/phpldapadmin/templates/creation/vcfUser.xml",
      "/etc/phpldapadmin/templates/creation/vcfGroup.xml"
    ) as $f) {
      libxml_use_internal_errors(true);
      if (simplexml_load_file($f) === false) {
        fwrite(STDERR, "Invalid XML: $f\n");
        foreach (libxml_get_errors() as $e) fwrite(STDERR, trim($e->message)."\n");
        exit(1);
      }
    }
  '

  systemctl restart apache2
  ok "Installed phpLDAPadmin templates: VCF: User and VCF: Group."
}

info "Configuring phpLDAPadmin..."
CFG=/etc/phpldapadmin/config.php
[[ -f "$CFG" ]] || die "phpLDAPadmin config not found."

cp -a "$CFG" "${CFG}.pre-easy-openldap" 2>/dev/null || true

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
  ln -sf /etc/phpldapadmin/apache.conf /etc/apache2/conf-available/phpldapadmin.conf
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

install_vcf_phpldapadmin_templates

info "Validating LDAP base-scope behavior..."
COUNT="$(
  ldapsearch -LLL -x \
    -H ldap://127.0.0.1 \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASSWORD" \
    -b "$BASE_DN" -s base '(objectClass=*)' dn 2>/dev/null |
    grep -c '^dn:' || true
)"
[[ "$COUNT" == "1" ]] || die "Base-scope test returned ${COUNT} entries; expected exactly 1."

info "Validating entryUUID and memberOf..."
TEST_USER="uid=vcf-install-test,${PEOPLE_DN}"
TEST_GROUP="cn=vcf-install-test,${GROUPS_DN}"
TEST_HASH="$(slappasswd -s "$(openssl rand -hex 18)")"

ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_GROUP" >/dev/null 2>&1 || true
ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_USER" >/dev/null 2>&1 || true

ldapadd -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
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

ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_GROUP" >/dev/null
ldapdelete -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" "$TEST_USER" >/dev/null

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

Suggested VCF-oriented mappings:
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

ok "Guest configuration completed successfully."
GUEST
}

push_and_run_guest_installer() {
  info "Copying installer into LXC..."
  pct push "$CTID" "$GUEST_SCRIPT" /root/easy-openldap-guest.sh --perms 0700

  info "Installing OpenLDAP inside LXC. This may take several minutes..."

  # Send the password via stdin so it is not written into the guest script.
  # The wrapper exports the non-secret configuration and reads one secret line.
  printf '%s\n' "$LDAP_ADMIN_PASSWORD" | pct exec "$CTID" -- bash -c "
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
  rm -f "$GUEST_SCRIPT"
  unset LDAP_ADMIN_PASSWORD
  ok "OpenLDAP installation completed inside LXC."
}

get_container_ip() {
  local ip=""
  local i

  for i in {1..60}; do
    ip="$(
      pct exec "$CTID" -- sh -c \
        "ip -4 -o addr show dev eth0 scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" \
        2>/dev/null || true
    )"
    [[ -n "$ip" ]] && break
    sleep 2
  done

  CT_IP="${ip:-<check DHCP lease>}"
}

final_message() {
  get_container_ip

  echo
  echo "================================================================"
  echo " OpenLDAP LXC deployment complete"
  echo "================================================================"
  echo
  echo " LXC:"
  echo "   CTID:      ${CTID}"
  echo "   Hostname:  ${CT_HOSTNAME}"
  echo "   IP:        ${CT_IP}"
  echo
  echo " Web administration UI:"
  echo "   https://${CT_IP}/phpldapadmin"
  echo
  echo " Login DN:"
  echo "   ${LDAP_ADMIN_DN}"
  echo
  echo " Use the LDAP administrator password you entered at the start."
  echo
  echo " LDAP:"
  echo "   Base DN:   ${BASE_DN}"
  echo "   Users:     ${PEOPLE_DN}"
  echo "   Groups:    ${GROUPS_DN}"
  echo
  echo " The LDAP administrator password was NOT written to disk."
  echo
  echo " Container reference:"
  echo "   pct enter ${CTID}"
  echo "   /root/OPENLDAP-README.txt"
  echo
  echo " Host log:"
  echo "   ${HOST_LOG}"
  echo "================================================================"
}

main() {
  need_root
  check_pve_host
  prompt_domain
  prompt_password
  next_vmid
  detect_template_storage
  detect_rootfs_storage
  check_bridge
  find_debian_template
  show_plan
  create_lxc
  start_lxc
  build_guest_installer
  push_and_run_guest_installer
  final_message
}

main "$@"
