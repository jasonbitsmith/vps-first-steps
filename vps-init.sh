#!/usr/bin/env bash
#
# vps-init.sh — Generic VPS bootstrap & hardening for Ubuntu/Debian
#
# Usage:
#   sudo ./vps-init.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/vps-init.sh | sudo bash -s -- [options]
#
# Run with --help for all options.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via CLI flags)
# ---------------------------------------------------------------------------
NEW_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_URL=""
SSH_PORT="22"
TIMEZONE=""
SWAP_SIZE="2G"
DISABLE_PASSWORD_AUTH="false"
DISABLE_ROOT_LOGIN="true"
INSTALL_BASIC_TOOLS="true"
ENABLE_AUTO_UPDATES="true"
NON_INTERACTIVE="false"
SKIP_FIREWALL="false"
SKIP_FAIL2BAN="false"
SKIP_SWAP="false"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
vps-init.sh — Generic VPS bootstrap & hardening (Ubuntu/Debian)

Options:
  --user NAME              Create a sudo user NAME (skips creation if it already exists)
  --ssh-key "KEY"          Public key string to authorize for the new user (and root, until root login is disabled)
  --ssh-key-url URL        Fetch the public key from a URL (e.g. https://github.com/<user>.keys)
  --ssh-port PORT          SSH port to configure (default: 22)
  --timezone TZ            Set system timezone (e.g. Asia/Shanghai). Default: leave unchanged
  --swap SIZE              Swap file size, e.g. 2G, 512M (default: 2G). Skipped if swap already exists
  --no-swap                Skip swap setup entirely
  --disable-password-auth  Disable SSH password authentication (key-only login)
  --keep-root-login        Do NOT disable SSH root login (default is to disable it)
  --no-firewall            Skip UFW firewall setup
  --no-fail2ban            Skip fail2ban installation
  --no-auto-updates        Skip unattended-upgrades setup
  --no-basic-tools         Skip installing curl/git/vim/htop/etc.
  -y, --yes                Non-interactive: assume "yes" to all prompts
  -h, --help                Show this help and exit

Example:
  sudo ./vps-init.sh --user deploy --ssh-key-url https://github.com/octocat.keys \
      --timezone Asia/Shanghai --disable-password-auth -y

IMPORTANT: Before closing your current session, open a NEW terminal and verify
you can log in with the new user / key / port. Do not disconnect first.
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (use sudo)."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) : ;;
    *) die "Unsupported OS: ${ID:-unknown}. This script supports Ubuntu/Debian only." ;;
  esac
  log "Detected OS: ${PRETTY_NAME:-$ID}"
}

confirm() {
  local prompt="$1"
  [[ "${NON_INTERACTIVE}" == "true" ]] && return 0
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step_update_system() {
  log "Updating package index and upgrading installed packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get autoremove -y
}

step_install_basic_tools() {
  [[ "${INSTALL_BASIC_TOOLS}" == "true" ]] || return 0
  log "Installing basic tools (curl, git, vim, htop, ufw, fail2ban, unattended-upgrades)..."
  apt-get install -y curl wget git vim htop unzip ufw fail2ban unattended-upgrades ca-certificates
}

step_set_timezone() {
  [[ -n "${TIMEZONE}" ]] || return 0
  log "Setting timezone to ${TIMEZONE}..."
  timedatectl set-timezone "${TIMEZONE}"
}

step_create_user() {
  [[ -n "${NEW_USER}" ]] || { warn "No --user specified, skipping user creation."; return 0; }

  if id "${NEW_USER}" &>/dev/null; then
    log "User '${NEW_USER}' already exists, skipping creation."
  else
    log "Creating user '${NEW_USER}' with sudo privileges..."
    adduser --disabled-password --gecos "" "${NEW_USER}"
    usermod -aG sudo "${NEW_USER}"
  fi

  local home_dir
  home_dir="$(getent passwd "${NEW_USER}" | cut -d: -f6)"
  local ssh_dir="${home_dir}/.ssh"
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"

  local key=""
  if [[ -n "${SSH_PUBKEY_URL}" ]]; then
    log "Fetching public key from ${SSH_PUBKEY_URL}..."
    key="$(curl -fsSL "${SSH_PUBKEY_URL}")"
  elif [[ -n "${SSH_PUBKEY}" ]]; then
    key="${SSH_PUBKEY}"
  fi

  if [[ -n "${key}" ]]; then
    touch "${ssh_dir}/authorized_keys"
    if ! grep -qF "${key}" "${ssh_dir}/authorized_keys" 2>/dev/null; then
      printf '%s\n' "${key}" >> "${ssh_dir}/authorized_keys"
    fi
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${NEW_USER}:${NEW_USER}" "${ssh_dir}"
    log "Authorized key installed for '${NEW_USER}'."
  else
    warn "No SSH key provided (--ssh-key / --ssh-key-url). '${NEW_USER}' has no authorized_keys yet."
  fi
}

step_harden_ssh() {
  log "Configuring SSH daemon..."
  local sshd_config="/etc/ssh/sshd_config"
  local drop_in_dir="/etc/ssh/sshd_config.d"
  local drop_in="${drop_in_dir}/99-vps-init.conf"
  mkdir -p "${drop_in_dir}"

  cp "${sshd_config}" "${sshd_config}.bak.$(date +%s)" 2>/dev/null || true

  {
    echo "# Managed by vps-init.sh — do not edit sshd_config directly for these settings"
    echo "Port ${SSH_PORT}"
    if [[ "${DISABLE_ROOT_LOGIN}" == "true" ]]; then
      echo "PermitRootLogin no"
    fi
    if [[ "${DISABLE_PASSWORD_AUTH}" == "true" ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
  } > "${drop_in}"

  if sshd -t; then
    log "sshd config validated. Restarting ssh service..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
  else
    die "sshd config validation failed — reverting. Check ${drop_in}"
  fi
}

step_setup_firewall() {
  [[ "${SKIP_FIREWALL}" == "true" ]] && { warn "Skipping firewall setup (--no-firewall)."; return 0; }
  log "Configuring UFW firewall (allow ${SSH_PORT}/tcp, deny incoming by default)..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"
  ufw --force enable
  ufw status verbose
}

step_setup_fail2ban() {
  [[ "${SKIP_FAIL2BAN}" == "true" ]] && { warn "Skipping fail2ban setup (--no-fail2ban)."; return 0; }
  log "Configuring fail2ban for sshd..."
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd
maxretry = 5
bantime  = 1h
findtime = 10m
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

step_setup_swap() {
  [[ "${SKIP_SWAP}" == "true" ]] && { warn "Skipping swap setup (--no-swap)."; return 0; }
  if swapon --show | grep -q .; then
    log "Swap already active, skipping."
    return 0
  fi
  log "Creating ${SWAP_SIZE} swap file at /swapfile..."
  fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$(numfmt --from=iec "${SWAP_SIZE}" | awk '{print int($1/1048576)}')"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
}

step_enable_auto_updates() {
  [[ "${ENABLE_AUTO_UPDATES}" == "true" ]] || return 0
  log "Enabling unattended security updates..."
  dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

print_summary() {
  cat <<EOF

$(printf '\033[1;36m=========================================================\033[0m')
 VPS initialization complete.

 - SSH port:        ${SSH_PORT}
 - Root login:       $( [[ "${DISABLE_ROOT_LOGIN}" == "true" ]] && echo disabled || echo enabled )
 - Password auth:    $( [[ "${DISABLE_PASSWORD_AUTH}" == "true" ]] && echo disabled || echo enabled )
 - New user:         ${NEW_USER:-none created}
 - Firewall (ufw):   $( [[ "${SKIP_FIREWALL}" == "true" ]] && echo skipped || echo enabled )
 - fail2ban:         $( [[ "${SKIP_FAIL2BAN}" == "true" ]] && echo skipped || echo enabled )
 - Swap:             $( [[ "${SKIP_SWAP}" == "true" ]] && echo skipped || echo "${SWAP_SIZE}" )

 IMPORTANT: Open a NEW terminal window now and confirm you can log in:
   ssh -p ${SSH_PORT} ${NEW_USER:-<user>}@<server-ip>

 Do NOT close this session until that login is confirmed working,
 especially if password auth or root login was disabled.
$(printf '\033[1;36m=========================================================\033[0m')
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) NEW_USER="$2"; shift 2 ;;
    --ssh-key) SSH_PUBKEY="$2"; shift 2 ;;
    --ssh-key-url) SSH_PUBKEY_URL="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --swap) SWAP_SIZE="$2"; shift 2 ;;
    --no-swap) SKIP_SWAP="true"; shift ;;
    --disable-password-auth) DISABLE_PASSWORD_AUTH="true"; shift ;;
    --keep-root-login) DISABLE_ROOT_LOGIN="false"; shift ;;
    --no-firewall) SKIP_FIREWALL="true"; shift ;;
    --no-fail2ban) SKIP_FAIL2BAN="true"; shift ;;
    --no-auto-updates) ENABLE_AUTO_UPDATES="false"; shift ;;
    --no-basic-tools) INSTALL_BASIC_TOOLS="false"; shift ;;
    -y|--yes) NON_INTERACTIVE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

# Safety: refuse to disable both root login and password auth if no key material given
if [[ "${DISABLE_PASSWORD_AUTH}" == "true" && -z "${SSH_PUBKEY}" && -z "${SSH_PUBKEY_URL}" ]]; then
  die "--disable-password-auth requires --ssh-key or --ssh-key-url so you don't lock yourself out."
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root
detect_os

confirm "This will update the system and apply security hardening. Continue?" || die "Aborted."

step_update_system
step_install_basic_tools
step_set_timezone
step_create_user
step_harden_ssh
step_setup_firewall
step_setup_fail2ban
step_setup_swap
step_enable_auto_updates
print_summary
