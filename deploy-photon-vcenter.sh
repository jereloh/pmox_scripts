#!/usr/bin/env bash
# ==============================================================================
# VMware vCenter Photon OS OVA Deployer + Optional Selkies Setup
# (deploy-photon-vcenter.sh v1.0)
# ==============================================================================
#
# Usage:
#   # Interactive (macOS / Linux workstation with govc & jq):
#   bash deploy-photon-vcenter.sh
#
#   # Unattended (deploy existing Content Library item + ASSUME_YES=1):
#   VC_HOST=vc.lab.local VC_USER=administrator@vsphere.local VC_PASS='...' \
#   LIB_ITEM=/photon-templates/photon-5.0 STATIC_CIDR=172.16.0.50/24 \
#   STATIC_GW=172.16.0.1 ROOT_PASS='...' ASSUME_YES=1 \
#     bash deploy-photon-vcenter.sh
#
#   # Unattended (let vCenter pull OVA directly into Content Library + deploy):
#   VC_HOST=vc.lab.local VC_USER=administrator@vsphere.local VC_PASS='...' \
#   TARGET_LIB=photon-templates OVA_URL=https://.../photon-5.0.ova \
#   STATIC_CIDR=172.16.0.50/24 STATIC_GW=172.16.0.1 ROOT_PASS='...' ASSUME_YES=1 \
#     bash deploy-photon-vcenter.sh
#
# Prerequisites:
#   - govc (vSphere CLI)
#   - jq   (JSON processor)
#   (Zero OVA download on the jumpbox: vCenter pulls & clones via Content Library.)
#
# What it does:
#   1. Prompts for vCenter login and verifies API connectivity.
#   2. Discovers Datacenter, Cluster/Resource Pool, Datastore, Network, and Folder.
#   3. Lets you select an existing Photon OS OVA/OVF item from vCenter Content
#      Library, OR tells vCenter to pull an OVA URL directly into an existing or
#      newly created Content Library (govc library.import -pull).
#   4. Deploys from Content Library (powered off, thin-provisioned), sets
#      vCPU/RAM, and attaches an extra disk (default: 300 GB) in the VM folder.
#   5. Injects cloud-init guestinfo to configure hostname, timezone, root password,
#      root SSH / authorized_keys, static IP (disabling 99-dhcp-en.network), and
#      formats/mounts the extra disk (default: /var/lib/docker).
#   6. Powers on the VM, verifies guest readiness, scrubs guestinfo.userdata, and
#      optionally installs setup-selkies-photon.sh inside the new VM.
# ==============================================================================
set -Eeuo pipefail

VERSION="1.0"
SCRIPT_NAME="deploy-photon-vcenter"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
else
  C_RST=""; C_R=""; C_G=""; C_Y=""; C_B=""
fi
log()  { printf '%s[+]%s %s\n' "$C_B" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'USAGEEOF'
Usage:
  deploy-photon-vcenter.sh            Interactive vCenter Photon OS OVA deployment
  deploy-photon-vcenter.sh --help     Show this help message

Environment overrides (optional, useful with ASSUME_YES=1):
  VC_HOST, VC_USER, VC_PASS, VC_SKIP_TLS (y/n)
  VC_DC, VC_POOL, VC_DS, VC_NET, VC_FOLDER
  LIB_ITEM          Existing Content Library item (/LibraryName/ItemName)
  TARGET_LIB        Target Content Library name/path when pulling an OVA URL
  OVA_URL           Direct-pull OVA URL for vCenter (govc library.import -pull)
  LIB_ITEM_NAME     Content Library item name when pulling from OVA_URL
  VM_NAME, VM_HOSTNAME, VM_CPUS (4), VM_MEM_GB (8)
  EXTRA_DISK_GB (300), EXTRA_DISK_MOUNT (/var/lib/docker), EXTRA_DISK_THICK (0|1)
  USE_STATIC (y/n), STATIC_CIDR, STATIC_GW, DNS_SERVERS (172.16.0.6), DNS_DOMAIN
  TIMEZONE (Asia/Singapore), ROOT_PASS, ENABLE_ROOT_SSH (y/n), SSH_PUBKEY_PATH
  INSTALL_SELKIES (y/n), LAB_DNS, UI_SCALE (1.0), API_PORT (8090), MAX_SESSIONS (3)
USAGEEOF
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

VM_CREATED=0
VM_PATH=""
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
on_err() {
  local rc=$? line=$1
  trap - ERR
  warn "Failed at line ${line} (exit ${rc})."
  if [[ "$VM_CREATED" == "1" && -n "$VM_PATH" && "${ASSUME_YES:-0}" != "1" ]]; then
    local ans=""
    read -r -p "Deployment failed. Destroy VM ${VM_PATH}? [y/N]: " ans || true
    if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
      govc vm.destroy "$VM_PATH" >/dev/null 2>&1 && ok "Destroyed ${VM_PATH}." || warn "Could not destroy ${VM_PATH}."
    fi
  fi
  cleanup
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT

command -v govc >/dev/null 2>&1 || die "'govc' is required (macOS: brew install govc)."
command -v jq   >/dev/null 2>&1 || die "'jq' is required (macOS: brew install jq)."

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __cur="" __in=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then return 0; fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    [[ -n "$__default" ]] || die "$__var required with ASSUME_YES=1."
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __in
    __in="${__in:-$__default}"
  else
    while [[ -z "$__in" ]]; do
      read -r -p "$__prompt: " __in
    done
  fi
  printf -v "$__var" '%s' "$__in"
}

ask_optional() {
  local __var="$1" __prompt="$2" __default="${3:-}" __cur="" __in=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then return 0; fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __in
    __in="${__in:-$__default}"
  else
    read -r -p "$__prompt: " __in
  fi
  printf -v "$__var" '%s' "$__in"
}

ask_yn() {
  local __var="$1" __prompt="$2" __default="${3:-y}" __cur="" __in=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then
    case "$__cur" in
      [Yy]|[Yy][Ee][Ss]|1|true|TRUE) printf -v "$__var" '%s' "y" ;;
      [Nn]|[Nn][Oo]|0|false|FALSE) printf -v "$__var" '%s' "n" ;;
      *) die "Invalid boolean value for ${__var}: ${__cur}" ;;
    esac
    return 0
  fi
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  local suffix="[Y/n]"
  [[ "$__default" == "n" ]] && suffix="[y/N]"
  while :; do
    read -r -p "${__prompt} ${suffix}: " __in
    __in="${__in:-$__default}"
    case "$__in" in
      [Yy]|[Yy][Ee][Ss]) printf -v "$__var" '%s' "y"; return 0 ;;
      [Nn]|[Nn][Oo])     printf -v "$__var" '%s' "n"; return 0 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

ask_login_secret() {
  local __var="$1" __prompt="$2" __cur="" __val=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then return 0; fi
  [[ "${ASSUME_YES:-0}" != "1" ]] || die "$__var required with ASSUME_YES=1."
  while [[ -z "$__val" ]]; do
    read -r -s -p "$__prompt: " __val
    printf '\n' >&2
  done
  printf -v "$__var" '%s' "$__val"
}

ask_new_secret() {
  local __var="$1" __prompt="$2" __min="${3:-8}" __cur="" __a="" __b=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then
    [[ ${#__cur} -ge $__min ]] || die "$__var must be at least ${__min} characters."
    return 0
  fi
  [[ "${ASSUME_YES:-0}" != "1" ]] || die "$__var required with ASSUME_YES=1."
  while :; do
    read -r -s -p "$__prompt: " __a; printf '\n' >&2
    read -r -s -p "Confirm: " __b; printf '\n' >&2
    if [[ "$__a" == "$__b" && ${#__a} -ge $__min ]]; then
      break
    fi
    warn "Password mismatch or shorter than ${__min} characters."
  done
  printf -v "$__var" '%s' "$__a"
}

pick_from_list() {
  local __var="$1" __prompt="$2"
  shift 2
  local __items=("$@")
  local __count=${#__items[@]}
  [[ $__count -gt 0 ]] || die "No choices available for: ${__prompt}"

  local __cur=""
  eval "__cur=\"\${${__var}:-}\""
  if [[ -n "$__cur" ]]; then
    return 0
  fi

  if [[ $__count -eq 1 ]]; then
    log "${__prompt}: ${__items[0]}"
    printf -v "$__var" '%s' "${__items[0]}"
    return 0
  fi

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    printf -v "$__var" '%s' "${__items[0]}"
    return 0
  fi

  printf '\nAvailable %s:\n' "$__prompt"
  local i=1 item
  for item in "${__items[@]}"; do
    printf '  %2d) %s\n' "$i" "$item"
    i=$((i + 1))
  done

  local __choice=""
  while :; do
    read -r -p "Select ${__prompt} [1-${__count} or exact path] [1]: " __choice
    __choice="${__choice:-1}"
    if [[ "$__choice" =~ ^[0-9]+$ ]] && [[ "$__choice" -ge 1 && "$__choice" -le "$__count" ]]; then
      printf -v "$__var" '%s' "${__items[$((__choice - 1))]}"
      return 0
    fi
    for item in "${__items[@]}"; do
      if [[ "$__choice" == "$item" ]]; then
        printf -v "$__var" '%s' "$item"
        return 0
      fi
    done
    warn "Invalid selection: $__choice"
  done
}

b64_encode() {
  base64 | tr -d '\r\n'
}

sh_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. o
  for o in $ip; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

valid_cidr() {
  local cidr="$1"
  [[ "$cidr" == */* ]] || return 1
  local ip="${cidr%/*}" prefix="${cidr#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ && "$prefix" -ge 1 && "$prefix" -le 32 ]] || return 1
  return 0
}

expand_tilde() {
  local p="$1"
  case "$p" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${p#~/}" ;;
    *)     printf '%s' "$p" ;;
  esac
}

echo "=== ${SCRIPT_NAME} v${VERSION} — Deploy VMware Photon OS OVA to vCenter ==="
echo

# ------------------------------------------------------------------------------
# 1. vCenter Login & Connectivity Check
# ------------------------------------------------------------------------------
ask VC_HOST "vCenter FQDN or IP"
VC_HOST="${VC_HOST#https://}"
VC_HOST="${VC_HOST#http://}"
VC_HOST="${VC_HOST%/sdk}"
VC_HOST="${VC_HOST%/}"

ask VC_USER "vCenter username" "administrator@vsphere.local"
ask_login_secret VC_PASS "vCenter password"
ask_yn VC_SKIP_TLS "Skip vCenter TLS certificate verification?" "y"

export GOVC_URL="https://${VC_HOST}/sdk"
export GOVC_USERNAME="$VC_USER"
export GOVC_PASSWORD="$VC_PASS"
export GOVC_PERSIST_SESSION=false
if [[ "$VC_SKIP_TLS" == "y" ]]; then
  export GOVC_INSECURE=1
else
  export GOVC_INSECURE=0
fi

log "Connecting to vCenter (${VC_HOST})..."
ABOUT_JSON="$(govc about -json)" || die "Failed to authenticate or connect to vCenter ${VC_HOST}."
VC_FULLNAME="$(printf '%s' "$ABOUT_JSON" | jq -r '.about.fullName // "VMware vCenter"')"
ok "Connected: ${VC_FULLNAME}"

# ------------------------------------------------------------------------------
# 2. Discover vCenter Inventory Targets
# ------------------------------------------------------------------------------
DC_LIST=()
while IFS= read -r line; do [[ -n "$line" ]] && DC_LIST+=("$line"); done < <(govc find / -type d | sort)
pick_from_list VC_DC "Datacenter" "${DC_LIST[@]}"
export GOVC_DATACENTER="$VC_DC"

POOL_LIST=()
while IFS= read -r line; do [[ -n "$line" ]] && POOL_LIST+=("$line"); done < <(govc find "$VC_DC" -type p | sort)
pick_from_list VC_POOL "Cluster / Resource Pool" "${POOL_LIST[@]}"

DS_LIST=()
while IFS= read -r line; do [[ -n "$line" ]] && DS_LIST+=("$line"); done < <(govc find "$VC_DC" -type s | sort)
pick_from_list VC_DS "Datastore" "${DS_LIST[@]}"

NET_LIST=()
while IFS= read -r line; do [[ -n "$line" ]] && NET_LIST+=("$line"); done < <(govc find "$VC_DC" -type n -type g -type o | sort -u)
pick_from_list VC_NET "Network / Port Group" "${NET_LIST[@]}"

FOLDER_LIST=("${VC_DC}/vm")
while IFS= read -r line; do
  [[ -n "$line" && "$line" != "${VC_DC}/vm" ]] && FOLDER_LIST+=("$line")
done < <(govc find "${VC_DC}/vm" -type f 2>/dev/null | sort || true)
pick_from_list VC_FOLDER "VM Folder" "${FOLDER_LIST[@]}"

# ------------------------------------------------------------------------------
# 3. Photon OS OVA Selection (Content Library Only — Zero Jumpbox Download)
# ------------------------------------------------------------------------------
DEFAULT_PHOTON_OVA_URL="https://packages.broadcom.com/photon/5.0/GA/ova/photon-hw15-5.0-dde71ec57.x86_64.ova"
NEED_PULL=0
CREATE_LIB=0
NEW_LIB_NAME=""
TARGET_LIB="${TARGET_LIB:-}"
OVA_URL="${OVA_URL:-}"
LIB_ITEM_NAME="${LIB_ITEM_NAME:-}"
LIB_ITEM="${LIB_ITEM:-}"

if [[ -n "$LIB_ITEM" ]]; then
  LIB_ITEM="/${LIB_ITEM#/}"
  govc library.info "$LIB_ITEM" >/dev/null 2>&1 || die "Content Library item not found: ${LIB_ITEM}"
  ok "Using Content Library item: ${LIB_ITEM}"
elif [[ -n "$OVA_URL" ]]; then
  NEED_PULL=1
else
  LIB_ITEMS=()
  while IFS= read -r line; do [[ -n "$line" ]] && LIB_ITEMS+=("$line"); done < <(govc library.ls '/*/*' 2>/dev/null | sort || true)
  if [[ ${#LIB_ITEMS[@]} -eq 0 ]]; then
    log "No existing Content Library items found on vCenter; will pull a Photon OS OVA directly into a Content Library."
    NEED_PULL=1
  elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
    LIB_ITEM="${LIB_ITEMS[0]}"
    ok "Using Content Library item: ${LIB_ITEM}"
  else
    item_count=${#LIB_ITEMS[@]}
    pull_idx=$((item_count + 1))
    printf '\nAvailable Content Library items on vCenter:\n'
    i=1
    for item in "${LIB_ITEMS[@]}"; do
      printf '  %2d) %s\n' "$i" "$item"
      i=$((i + 1))
    done
    printf '  %2d) [Download new Photon OS OVA into a Content Library (vCenter direct pull)]\n' "$pull_idx"

    while :; do
      read -r -p "Select Content Library item [1-${pull_idx} or exact /Library/Item] [1]: " choice
      choice="${choice:-1}"
      if [[ "$choice" == "$pull_idx" ]]; then
        NEED_PULL=1
        break
      elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "$item_count" ]]; then
        LIB_ITEM="${LIB_ITEMS[$((choice - 1))]}"
        ok "Using Content Library item: ${LIB_ITEM}"
        break
      else
        cand="/${choice#/}"
        if govc library.info "$cand" >/dev/null 2>&1; then
          LIB_ITEM="$cand"
          ok "Using Content Library item: ${LIB_ITEM}"
          break
        fi
        warn "Invalid selection or item not found: ${choice}"
      fi
    done
  fi
fi

if [[ "$NEED_PULL" == "1" ]]; then
  LIBRARIES=()
  while IFS= read -r line; do [[ -n "$line" ]] && LIBRARIES+=("$line"); done < <(govc library.ls 2>/dev/null | sort || true)

  if [[ -n "$TARGET_LIB" ]]; then
    TARGET_LIB="/${TARGET_LIB#/}"
    if ! govc library.info "$TARGET_LIB" >/dev/null 2>&1; then
      CREATE_LIB=1
      NEW_LIB_NAME="${TARGET_LIB#/}"
    fi
  elif [[ ${#LIBRARIES[@]} -eq 0 ]]; then
    log "No Content Libraries found on vCenter."
    ask NEW_LIB_NAME "New Content Library name (created on ${VC_DS})" "photon-templates"
    NEW_LIB_NAME="${NEW_LIB_NAME#/}"
    CREATE_LIB=1
    TARGET_LIB="/${NEW_LIB_NAME}"
  elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
    TARGET_LIB="${LIBRARIES[0]}"
  else
    lib_count=${#LIBRARIES[@]}
    new_lib_idx=$((lib_count + 1))
    printf '\nAvailable Content Libraries on vCenter:\n'
    i=1
    for lib in "${LIBRARIES[@]}"; do
      printf '  %2d) %s\n' "$i" "$lib"
      i=$((i + 1))
    done
    printf '  %2d) [Create a new local Content Library on datastore %s]\n' "$new_lib_idx" "$VC_DS"

    while :; do
      read -r -p "Select target Content Library [1-${new_lib_idx}] [1]: " lib_choice
      lib_choice="${lib_choice:-1}"
      if [[ "$lib_choice" == "$new_lib_idx" ]]; then
        ask NEW_LIB_NAME "New Content Library name (created on ${VC_DS})" "photon-templates"
        NEW_LIB_NAME="${NEW_LIB_NAME#/}"
        TARGET_LIB="/${NEW_LIB_NAME}"
        if govc library.info "$TARGET_LIB" >/dev/null 2>&1; then
          warn "Content Library '${TARGET_LIB}' already exists; using existing library."
          CREATE_LIB=0
        else
          CREATE_LIB=1
        fi
        break
      elif [[ "$lib_choice" =~ ^[0-9]+$ ]] && [[ "$lib_choice" -ge 1 && "$lib_choice" -le "$lib_count" ]]; then
        TARGET_LIB="${LIBRARIES[$((lib_choice - 1))]}"
        CREATE_LIB=0
        break
      else
        cand="/${lib_choice#/}"
        if govc library.info "$cand" >/dev/null 2>&1; then
          TARGET_LIB="$cand"
          CREATE_LIB=0
          break
        fi
        warn "Invalid selection: ${lib_choice}"
      fi
    done
  fi

  ask OVA_URL "Photon OS OVA URL (vCenter will pull directly)" "$DEFAULT_PHOTON_OVA_URL"
  [[ "$OVA_URL" =~ ^https?:// ]] || die "OVA URL must start with http:// or https://: ${OVA_URL}"

  DEFAULT_ITEM_NAME="$(basename "${OVA_URL%%\?*}" | sed -E 's/\.(ova|ovf)$//')"
  [[ -n "$DEFAULT_ITEM_NAME" ]] || DEFAULT_ITEM_NAME="photon-5.0"

  while :; do
    ask LIB_ITEM_NAME "Content Library item name" "$DEFAULT_ITEM_NAME"
    LIB_ITEM="${TARGET_LIB%/}/${LIB_ITEM_NAME}"
    if [[ "$CREATE_LIB" == "0" ]] && govc library.info "$LIB_ITEM" >/dev/null 2>&1; then
      warn "Item '${LIB_ITEM}' already exists in Content Library."
      REUSE_EXISTING=""
      ask_yn REUSE_EXISTING "Use existing item '${LIB_ITEM}' instead of re-downloading?" "y"
      if [[ "$REUSE_EXISTING" == "y" ]]; then
        NEED_PULL=0
        ok "Using existing Content Library item: ${LIB_ITEM}"
        break
      fi
      LIB_ITEM_NAME=""
    else
      break
    fi
  done
fi

# ------------------------------------------------------------------------------
# 4. VM Sizing, 300 GB Extra Disk, Network & Credentials
# ------------------------------------------------------------------------------
echo
ask VM_NAME "New VM name" "selkies-photon"
EXISTING_VM="$(govc find "$VC_FOLDER" -maxdepth 1 -type m -name "$VM_NAME" 2>/dev/null || true)"
[[ -z "$EXISTING_VM" ]] || die "VM '${VM_NAME}' already exists in folder '${VC_FOLDER}'."

ask VM_HOSTNAME "Guest OS hostname" "$VM_NAME"
ask VM_CPUS     "vCPU count" "4"
[[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || die "Invalid vCPU count: ${VM_CPUS}"

ask VM_MEM_GB "Memory in GB" "8"
[[ "$VM_MEM_GB" =~ ^[1-9][0-9]*$ ]] || die "Invalid memory size in GB: ${VM_MEM_GB}"
VM_MEM_MB=$((VM_MEM_GB * 1024))

ask EXTRA_DISK_GB "Extra data disk size in GB (0 to skip)" "300"
[[ "$EXTRA_DISK_GB" =~ ^[0-9]+$ ]] || die "Invalid disk size in GB: ${EXTRA_DISK_GB}"

EXTRA_DISK_MOUNT="none"
EXTRA_DISK_THICK="${EXTRA_DISK_THICK:-0}"
if [[ "$EXTRA_DISK_GB" -gt 0 ]]; then
  ask EXTRA_DISK_MOUNT "Mount point for ${EXTRA_DISK_GB} GB disk ('none' to leave unformatted)" "/var/lib/docker"
  if [[ "$EXTRA_DISK_MOUNT" != "none" && "$EXTRA_DISK_MOUNT" != /* ]]; then
    die "Mount point must be an absolute path or 'none': ${EXTRA_DISK_MOUNT}"
  fi
fi

echo
ask_yn USE_STATIC "Configure Static IP?" "y"
STATIC_CIDR="${STATIC_CIDR:-}"
STATIC_GW="${STATIC_GW:-}"
DNS_DOMAIN="${DNS_DOMAIN:-}"
if [[ "$USE_STATIC" == "y" ]]; then
  while :; do
    ask STATIC_CIDR "Static IP with CIDR prefix (e.g. 172.16.0.50/24)"
    valid_cidr "$STATIC_CIDR" && break
    warn "Invalid CIDR notation: ${STATIC_CIDR} (expected a.b.c.d/prefix)"
    STATIC_CIDR=""
  done
  while :; do
    ask STATIC_GW "Gateway IP (e.g. 172.16.0.1)"
    valid_ipv4 "$STATIC_GW" && break
    warn "Invalid IPv4 address: ${STATIC_GW}"
    STATIC_GW=""
  done
  ask DNS_SERVERS "DNS server(s), space or comma separated" "172.16.0.6"
  ask_optional DNS_DOMAIN "DNS search domain (optional)"
else
  ask DNS_SERVERS "DNS server(s) for containers (if installing Selkies)" "172.16.0.6"
fi

ask TIMEZONE "Guest timezone" "Asia/Singapore"
echo
warn "Note: Photon OS enforces PAM password rules; use a strong mixed-case + digit/symbol root password."
ask_new_secret ROOT_PASS "New root password for Photon OS VM" 8
ask_yn ENABLE_ROOT_SSH "Allow root SSH password login?" "y"

DEFAULT_SSH_PUBKEY=""
if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
  DEFAULT_SSH_PUBKEY="${HOME}/.ssh/id_ed25519.pub"
elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
  DEFAULT_SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
fi
ask_optional SSH_PUBKEY_PATH "SSH public key path (optional, Enter to skip)" "$DEFAULT_SSH_PUBKEY"
SSH_PUBKEY=""
if [[ -n "$SSH_PUBKEY_PATH" ]]; then
  SSH_PUBKEY_PATH="$(expand_tilde "$SSH_PUBKEY_PATH")"
  [[ -f "$SSH_PUBKEY_PATH" ]] || die "SSH public key file not found: ${SSH_PUBKEY_PATH}"
  SSH_PUBKEY="$(tr -d '\r\n' < "$SSH_PUBKEY_PATH")"
fi

echo
ask_yn INSTALL_SELKIES "Auto-run setup-selkies-photon.sh after VM boots?" "y"
LAB_DNS=""
UI_SCALE=""
API_PORT=""
MAX_SESSIONS=""
if [[ "$INSTALL_SELKIES" == "y" ]]; then
  DEFAULT_LAB_DNS="$(printf '%s' "$DNS_SERVERS" | tr ',' ' ' | awk '{print $1}')"
  DEFAULT_LAB_DNS="${DEFAULT_LAB_DNS:-172.16.0.6}"
  ask LAB_DNS      "Container DNS server (LAB_DNS)" "$DEFAULT_LAB_DNS"
  ask UI_SCALE     "Browser HiDPI scale (1.0 = native, 1.25 = scaled)" "1.0"
  ask API_PORT     "Selkies REST API port" "8090"
  ask MAX_SESSIONS "Max concurrent browser sessions" "3"
  [[ "$API_PORT" =~ ^[0-9]+$ && "$API_PORT" -ge 1 && "$API_PORT" -le 65535 ]] \
    || die "Invalid API_PORT: ${API_PORT}"
  [[ "$MAX_SESSIONS" =~ ^[1-9][0-9]*$ ]] \
    || die "Invalid MAX_SESSIONS: ${MAX_SESSIONS}"
fi

# ------------------------------------------------------------------------------
# 5. Deployment Summary & Confirmation
# ------------------------------------------------------------------------------
echo
echo "==================== Deployment Summary ===================="
echo "  vCenter        : ${VC_HOST} (${VC_USER})"
echo "  Datacenter     : ${VC_DC}"
echo "  Cluster / Pool : ${VC_POOL}"
echo "  Datastore      : ${VC_DS}"
echo "  Network        : ${VC_NET}"
echo "  Folder         : ${VC_FOLDER}"
if [[ "$NEED_PULL" == "1" ]]; then
  if [[ "$CREATE_LIB" == "1" ]]; then
    echo "  Content Library: ${TARGET_LIB} (new, on ${VC_DS})"
  else
    echo "  Content Library: ${TARGET_LIB}"
  fi
  echo "  OVA Direct Pull: ${OVA_URL}"
  echo "  Library Item   : ${LIB_ITEM}"
else
  echo "  Library Item   : ${LIB_ITEM} (existing on vCenter)"
fi
echo "  VM Name        : ${VM_NAME} (hostname: ${VM_HOSTNAME})"
echo "  Compute        : ${VM_CPUS} vCPU | ${VM_MEM_GB} GB RAM"
if [[ "$EXTRA_DISK_GB" -gt 0 ]]; then
  echo "  Extra Disk     : ${EXTRA_DISK_GB} GB -> ${EXTRA_DISK_MOUNT}"
else
  echo "  Extra Disk     : none"
fi
if [[ "$USE_STATIC" == "y" ]]; then
  echo "  Network Config : Static ${STATIC_CIDR} (GW: ${STATIC_GW}, DNS: ${DNS_SERVERS})"
else
  echo "  Network Config : DHCP"
fi
echo "  Root SSH Login : ${ENABLE_ROOT_SSH} (SSH key: ${SSH_PUBKEY_PATH:-none})"
echo "  Auto-Install   : Selkies VDI = ${INSTALL_SELKIES}"
echo "============================================================"
echo

if [[ "${ASSUME_YES:-0}" != "1" ]]; then
  PROCEED=""
  ask_yn PROCEED "Proceed with deployment?" "y"
  [[ "$PROCEED" == "y" ]] || { log "Cancelled."; exit 0; }
fi

# ------------------------------------------------------------------------------
# 6. Pull OVA via vCenter (if needed) & Deploy from Content Library (Powered Off)
# ------------------------------------------------------------------------------
if [[ "$CREATE_LIB" == "1" ]]; then
  log "Creating local Content Library '${NEW_LIB_NAME}' on datastore '${VC_DS}'..."
  govc library.create -dc "$VC_DC" -ds "$VC_DS" "$NEW_LIB_NAME"
  ok "Created Content Library: /${NEW_LIB_NAME}"
fi

if [[ "$NEED_PULL" == "1" ]]; then
  log "Instructing vCenter to pull OVA directly into '${LIB_ITEM}' (zero jumpbox download)..."
  govc library.import -pull -n "$LIB_ITEM_NAME" "${TARGET_LIB#/}" "$OVA_URL"
  ok "vCenter imported OVA into Content Library: ${LIB_ITEM}"
fi

log "Generating OVF import spec from '${LIB_ITEM}'..."
OVF_FILE="$(govc library.ls "${LIB_ITEM%/}/" | grep -E '\.ovf$' | head -n1 || true)"
[[ -n "$OVF_FILE" ]] || die "No .ovf descriptor found inside Content Library item '${LIB_ITEM}'."
govc library.export "$OVF_FILE" "${TMP_DIR}/template.ovf"
govc import.spec "${TMP_DIR}/template.ovf" > "${TMP_DIR}/spec.json"

jq --arg name "$VM_NAME" --arg net "$VC_NET" '
  .Name = $name
  | .DiskProvisioning = "thin"
  | .PowerOn = false
  | if (.NetworkMapping | type) == "array" then
      .NetworkMapping |= map(.Network = $net)
    else . end
' "${TMP_DIR}/spec.json" > "${TMP_DIR}/options.json"

log "Deploying Photon OS VM '${VM_NAME}' from Content Library '${LIB_ITEM}'..."
govc library.deploy \
  -dc "$VC_DC" -ds "$VC_DS" -pool "$VC_POOL" -folder "$VC_FOLDER" \
  -options "${TMP_DIR}/options.json" \
  "$LIB_ITEM" "$VM_NAME"

VM_PATH="${VC_FOLDER%/}/${VM_NAME}"
VM_CREATED=1
ok "VM deployed from Content Library: ${VM_PATH}"

# ------------------------------------------------------------------------------
# 7. Resize Compute & Attach Extra 300 GB Disk
# ------------------------------------------------------------------------------
log "Configuring ${VM_CPUS} vCPU and ${VM_MEM_GB} GB RAM..."
govc vm.change -vm "$VM_PATH" -c "$VM_CPUS" -m "$VM_MEM_MB"

if [[ "$EXTRA_DISK_GB" -gt 0 ]]; then
  VMX_PATH="$(govc vm.info -json "$VM_PATH" | jq -r '.virtualMachines[0].config.files.vmPathName // ""')"
  VM_HOME_DIR="$(printf '%s' "$VMX_PATH" | sed -E 's|^\[[^]]+\][[:space:]]*||; s|/[^/]+$||')"
  if [[ -n "$VM_HOME_DIR" ]]; then
    DISK_NAME="${VM_HOME_DIR}/${VM_NAME}-data.vmdk"
  else
    DISK_NAME="${VM_NAME}/${VM_NAME}-data.vmdk"
  fi
  DISK_EXTRA_ARGS=()
  if [[ "$EXTRA_DISK_THICK" == "1" ]]; then
    DISK_EXTRA_ARGS=(-thick)
  fi
  log "Creating and attaching ${EXTRA_DISK_GB} GB disk (${DISK_NAME})..."
  govc vm.disk.create \
    -vm "$VM_PATH" -ds "$VC_DS" -name "$DISK_NAME" -size "${EXTRA_DISK_GB}G" \
    ${DISK_EXTRA_ARGS[@]+"${DISK_EXTRA_ARGS[@]}"}
  ok "Attached ${EXTRA_DISK_GB} GB disk."
fi

# ------------------------------------------------------------------------------
# 8. Build Cloud-Init GuestInfo Payload (Firstboot Script)
# ------------------------------------------------------------------------------
log "Injecting cloud-init guestinfo configuration..."
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf 'VM_HOSTNAME=%s\n'      "$(sh_quote "$VM_HOSTNAME")"
  printf 'TIMEZONE=%s\n'         "$(sh_quote "$TIMEZONE")"
  printf 'ROOT_PASS=%s\n'        "$(sh_quote "$ROOT_PASS")"
  printf 'ENABLE_ROOT_SSH=%s\n'  "$(sh_quote "$ENABLE_ROOT_SSH")"
  printf 'SSH_PUBKEY=%s\n'       "$(sh_quote "$SSH_PUBKEY")"
  printf 'USE_STATIC=%s\n'       "$(sh_quote "$USE_STATIC")"
  printf 'STATIC_CIDR=%s\n'      "$(sh_quote "$STATIC_CIDR")"
  printf 'STATIC_GW=%s\n'        "$(sh_quote "$STATIC_GW")"
  printf 'DNS_SERVERS=%s\n'      "$(sh_quote "$DNS_SERVERS")"
  printf 'DNS_DOMAIN=%s\n'       "$(sh_quote "$DNS_DOMAIN")"
  printf 'EXTRA_DISK_GB=%s\n'    "$(sh_quote "$EXTRA_DISK_GB")"
  printf 'EXTRA_DISK_MOUNT=%s\n' "$(sh_quote "$EXTRA_DISK_MOUNT")"
} > "${TMP_DIR}/firstboot.sh"

cat >> "${TMP_DIR}/firstboot.sh" <<'FIRSTBOOT_BODY'
exec > /var/log/photon-firstboot.log 2>&1

echo "[firstboot] Setting hostname and timezone..."
hostnamectl set-hostname "$VM_HOSTNAME"
timedatectl set-timezone "$TIMEZONE" || true

echo "[firstboot] Configuring root password and SSH..."
printf 'root:%s\n' "$ROOT_PASS" | chpasswd
chage -M -1 -d "$(date +%Y-%m-%d)" root || true

if [[ -n "$SSH_PUBKEY" ]]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  grep -qxF "$SSH_PUBKEY" /root/.ssh/authorized_keys || printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

if [[ "$ENABLE_ROOT_SSH" == "y" ]]; then
  if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  else
    printf '\nPermitRootLogin yes\n' >> /etc/ssh/sshd_config
  fi
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    printf 'PermitRootLogin yes\n' > /etc/ssh/sshd_config.d/99-allow-root.conf
  fi
  systemctl reload-or-restart sshd || systemctl restart sshd || true
fi

if [[ "$USE_STATIC" == "y" ]]; then
  echo "[firstboot] Configuring static IP ${STATIC_CIDR} (gw ${STATIC_GW})..."
  mkdir -p /etc/systemd/network
  for f in /etc/systemd/network/99-dhcp-en.network /etc/systemd/network/50-dhcp-en.network; do
    if [[ -f "$f" ]]; then
      mv "$f" "${f}.bak"
    fi
  done
  {
    printf '[Match]\nName=e*\n\n[Network]\nAddress=%s\nGateway=%s\n' "$STATIC_CIDR" "$STATIC_GW"
    for dns in $(printf '%s' "$DNS_SERVERS" | tr ',' ' '); do
      [[ -n "$dns" ]] && printf 'DNS=%s\n' "$dns"
    done
    if [[ -n "$DNS_DOMAIN" ]]; then
      printf 'Domains=%s\n' "$DNS_DOMAIN"
    fi
  } > /etc/systemd/network/10-static-en.network
  chmod 644 /etc/systemd/network/10-static-en.network
  systemctl restart systemd-networkd
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl restart systemd-resolved
  fi
fi

if [[ "$EXTRA_DISK_GB" -gt 0 && "$EXTRA_DISK_MOUNT" != "none" ]]; then
  echo "[firstboot] Detecting extra disk for ${EXTRA_DISK_MOUNT}..."
  DATA_DISK=""
  for _ in $(seq 1 15); do
    ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    ROOT_PK=""
    [[ -n "$ROOT_SRC" ]] && ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
    while read -r dev type _; do
      [[ "$type" == "disk" ]] || continue
      [[ -n "$ROOT_PK" && "$dev" == "$ROOT_PK" ]] && continue
      [[ -n "$ROOT_SRC" && "/dev/${dev}" == "$ROOT_SRC" ]] && continue
      if lsblk -n "/dev/${dev}" 2>/dev/null | awk 'NR>1 {found=1} END {exit !found}'; then
        continue
      fi
      if blkid "/dev/${dev}" >/dev/null 2>&1; then
        continue
      fi
      DATA_DISK="/dev/${dev}"
      break
    done < <(lsblk -ndo NAME,TYPE,SIZE 2>/dev/null)
    [[ -n "$DATA_DISK" ]] && break
    sleep 2
  done
  if [[ -n "$DATA_DISK" ]]; then
    mkfs.ext4 -F -L photon-data "$DATA_DISK"
    DATA_UUID="$(blkid -s UUID -o value "$DATA_DISK")"
    mkdir -p "$EXTRA_DISK_MOUNT"
    if ! grep -q "UUID=${DATA_UUID}" /etc/fstab; then
      printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$DATA_UUID" "$EXTRA_DISK_MOUNT" >> /etc/fstab
    fi
    mount "$EXTRA_DISK_MOUNT"
    mountpoint -q "$EXTRA_DISK_MOUNT" || { echo "[firstboot] Failed to mount ${EXTRA_DISK_MOUNT}" >&2; exit 1; }
    echo "[firstboot] Mounted ${DATA_DISK} (UUID=${DATA_UUID}) at ${EXTRA_DISK_MOUNT}."
  else
    echo "[firstboot] Warning: No unformatted extra disk detected; skipping mount." >&2
  fi
fi

mkdir -p /var/lib
date -u '+%Y-%m-%dT%H:%M:%SZ' > /var/lib/photon-deploy.done
rm -f /usr/local/sbin/photon-firstboot.sh
echo "[firstboot] Complete."
FIRSTBOOT_BODY

FIRSTBOOT_B64="$(b64_encode < "${TMP_DIR}/firstboot.sh")"
cat > "${TMP_DIR}/user-data.yaml" <<UDEOF
#cloud-config
write_files:
  - path: /usr/local/sbin/photon-firstboot.sh
    permissions: '0700'
    owner: root:root
    encoding: b64
    content: ${FIRSTBOOT_B64}
runcmd:
  - /usr/local/sbin/photon-firstboot.sh
UDEOF

cat > "${TMP_DIR}/meta-data.yaml" <<MDEOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_HOSTNAME}
MDEOF

USERDATA_B64="$(b64_encode < "${TMP_DIR}/user-data.yaml")"
METADATA_B64="$(b64_encode < "${TMP_DIR}/meta-data.yaml")"

govc vm.change -vm "$VM_PATH" \
  -e "guestinfo.metadata=${METADATA_B64}" \
  -e "guestinfo.metadata.encoding=base64" \
  -e "guestinfo.userdata=${USERDATA_B64}" \
  -e "guestinfo.userdata.encoding=base64"

# ------------------------------------------------------------------------------
# 9. Power On, Verify Firstboot, Scrub Secret & Optional Selkies Install
# ------------------------------------------------------------------------------
log "Powering on ${VM_PATH}..."
govc vm.power -on "$VM_PATH"

log "Waiting for VMware Tools IP (up to 3 minutes)..."
REPORTED_IP="$(govc vm.ip -a -v4 -wait 3m "$VM_PATH" 2>/dev/null || true)"
[[ -n "$REPORTED_IP" ]] && log "VMware Tools reported IP: ${REPORTED_IP}"

log "Waiting for guest firstboot configuration to complete..."
READY=0
for _ in $(seq 1 36); do
  if GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.run -vm "$VM_PATH" /bin/test -f /var/lib/photon-deploy.done >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [[ "$READY" == "1" ]]; then
  ok "Guest customization verified (/var/lib/photon-deploy.done present)."
  govc vm.change -vm "$VM_PATH" -e "guestinfo.userdata=" >/dev/null 2>&1 || true
  REPORTED_IP="$(govc vm.ip -a -v4 -wait 30s "$VM_PATH" 2>/dev/null || echo "${REPORTED_IP:-unknown}")"

  if [[ "$EXTRA_DISK_GB" -gt 0 && "$EXTRA_DISK_MOUNT" != "none" ]]; then
    log "Verifying ${EXTRA_DISK_MOUNT} mount inside guest:"
    GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.run -vm "$VM_PATH" /bin/df -h "$EXTRA_DISK_MOUNT" || true
  fi

  if [[ "$INSTALL_SELKIES" == "y" ]]; then
    SELKIES_LOCAL="${SCRIPT_DIR}/setup-selkies-photon.sh"
    SELKIES_URL="https://raw.githubusercontent.com/jereloh/pmox_scripts/main/setup-selkies-photon.sh"
    if [[ -f "$SELKIES_LOCAL" ]]; then
      log "Uploading setup-selkies-photon.sh to ${VM_NAME}..."
      GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.upload -vm "$VM_PATH" -f -perm 0700 "$SELKIES_LOCAL" /root/setup-selkies-photon.sh
    else
      log "Downloading setup-selkies-photon.sh directly inside ${VM_NAME} (zero jumpbox download)..."
      GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.run -vm "$VM_PATH" /bin/bash -c \
        "curl -fsSL '${SELKIES_URL}' -o /root/setup-selkies-photon.sh && chmod 700 /root/setup-selkies-photon.sh"
    fi

    log "Running setup-selkies-photon.sh inside ${VM_NAME}..."
    GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.run -vm "$VM_PATH" \
      -e "ASSUME_YES=1" \
      -e "CUSTOM_DNS=${LAB_DNS}" \
      -e "TIMEZONE=${TIMEZONE}" \
      -e "UI_SCALE=${UI_SCALE}" \
      -e "API_PORT=${API_PORT}" \
      -e "MAX_SESSIONS=${MAX_SESSIONS}" \
      /bin/bash /root/setup-selkies-photon.sh
    GOVC_GUEST_LOGIN="root:${ROOT_PASS}" govc guest.run -vm "$VM_PATH" /bin/rm -f /root/setup-selkies-photon.sh >/dev/null 2>&1 || true
    ok "Selkies VDI host installed on ${VM_NAME}."
  fi
else
  warn "Timed out waiting for /var/lib/photon-deploy.done via VMware Tools."
  warn "Inspect the VM console and check: cloud-init status --long && cat /var/log/photon-firstboot.log"
  warn "Note: guestinfo.userdata was not cleared; clear it manually once verified."
fi

DISPLAY_IP="${REPORTED_IP:-${STATIC_CIDR%/*}}"
echo
echo "========================================================"
ok "Photon OS deployment finished: ${VM_PATH}"
echo "--------------------------------------------------------"
echo "  VM Path    : ${VM_PATH}"
echo "  Hostname   : ${VM_HOSTNAME}"
echo "  IP Address : ${DISPLAY_IP:-pending}"
echo "  Compute    : ${VM_CPUS} vCPU | ${VM_MEM_GB} GB RAM"
if [[ "$EXTRA_DISK_GB" -gt 0 ]]; then
  echo "  Extra Disk : ${EXTRA_DISK_GB} GB (${EXTRA_DISK_MOUNT})"
fi
echo "  SSH Access : ssh root@${DISPLAY_IP:-<vm-ip>}"
if [[ "$INSTALL_SELKIES" == "y" && "$READY" == "1" ]]; then
  echo "  Selkies API: http://${DISPLAY_IP:-<vm-ip>}:${API_PORT}"
fi
echo "========================================================"
