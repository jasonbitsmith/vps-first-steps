#!/usr/bin/env bash
#
# vps-init.sh — Generic VPS bootstrap & hardening for Ubuntu/Debian
#
# Usage:
#   sudo ./vps-init.sh [options]
#   sudo bash vps-init.sh --check
#
# Run with --help for all options.

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---------------------------------------------------------------------------
# Defaults (override via CLI flags)
# ---------------------------------------------------------------------------
NEW_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_URL=""
SSH_PORT=""
TIMEZONE=""
SWAP_SIZE="2G"
DISABLE_PASSWORD_AUTH="false"
DISABLE_ROOT_LOGIN="false"
INSTALL_BASIC_TOOLS="true"
ENABLE_AUTO_UPDATES="true"
STATUS_ONLY="false"
CHECK_ONLY="false"
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
  --ssh-key "KEY"          Public key string to authorize for the new user
  --ssh-key-url URL        Fetch the public key from a URL (e.g. https://github.com/<user>.keys)
  --ssh-port PORT          Existing SSH port (auto-detected; changing ports is not supported)
  --timezone TZ            Set system timezone (e.g. Asia/Shanghai). Default: leave unchanged
  --swap SIZE              Swap file size, e.g. 2G, 512M (default: 2G). Skipped if swap already exists
  --no-swap                Skip swap setup entirely
  --disable-password-auth  Disable SSH password authentication (key-only login)
  --keep-root-login        Preserve existing root-login policy (default)
  --disable-root-login     Disable root login after testing the new account
  --status                Read-only report of current services and swap
  --check                 Read-only prerequisite check; make no changes
  --no-firewall            Skip UFW firewall setup
  --no-fail2ban            Skip fail2ban installation
  --no-auto-updates        Skip unattended-upgrades setup
  --no-basic-tools         Skip installing curl/git/vim/htop/etc.
  -y, --yes                Non-interactive: assume "yes" to all prompts
  -h, --help                Show this help and exit

Example (beginner defaults, preserve existing SSH login):
  sudo bash vps-init.sh --check
  sudo bash vps-init.sh

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
  # Do not remove existing packages automatically.
}

step_install_basic_tools() {
  apt-get install -y sudo openssh-server ca-certificates curl
  [[ "$SKIP_FIREWALL" == true ]] || apt-get install -y ufw
  [[ "$SKIP_FAIL2BAN" == true ]] || apt-get install -y fail2ban
  [[ "$ENABLE_AUTO_UPDATES" == false ]] || apt-get install -y unattended-upgrades
  [[ "${INSTALL_BASIC_TOOLS}" == "true" ]] || return 0
  log "Installing basic tools (curl, git, vim, htop, ufw, fail2ban, unattended-upgrades)..."
  apt-get install -y curl wget git vim htop unzip ca-certificates
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
  [[ -d "$home_dir" && "$home_dir" != / ]] || die "Invalid home directory for $NEW_USER"
  local ssh_dir="${home_dir}/.ssh"
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"

  local key="$SSH_PUBKEY"

  if [[ -n "${key}" ]]; then
    touch "${ssh_dir}/authorized_keys"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      grep -qxF "$line" "${ssh_dir}/authorized_keys" || printf '%s\n' "$line" >> "${ssh_dir}/authorized_keys"
    done <<< "$key"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${NEW_USER}:$(id -gn "$NEW_USER")" "${ssh_dir}"
    usermod -aG sudo "$NEW_USER"
    local sudo_file
    sudo_file="$(mktemp)"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$sudo_file"
    visudo -cf "$sudo_file" || { rm -f "$sudo_file"; die "Invalid sudo configuration"; }
    install -m 0440 "$sudo_file" "/etc/sudoers.d/90-vps-init-$NEW_USER"
    rm -f "$sudo_file"
    log "Authorized key installed for '${NEW_USER}'."
  else
    warn "No SSH key provided (--ssh-key / --ssh-key-url). '${NEW_USER}' has no authorized_keys yet."
  fi
}

step_harden_ssh() {
  [[ "$DISABLE_ROOT_LOGIN" == true || "$DISABLE_PASSWORD_AUTH" == true ]] || return 0
  local main=/etc/ssh/sshd_config backup
  backup="$(mktemp /etc/ssh/sshd_config.vps-init-backup.XXXXXX)"
  cp -p "$main" "$backup"
  # OpenSSH uses the first value encountered, including cloud-init drop-ins.
  {
    [[ "$DISABLE_ROOT_LOGIN" == false ]] || echo 'PermitRootLogin no'
    if [[ "$DISABLE_PASSWORD_AUTH" == true ]]; then
      echo 'PasswordAuthentication no'
      echo 'KbdInteractiveAuthentication no'
    fi
    cat "$backup"
  } > "$main"
  if ! sshd -t || ! systemctl reload ssh; then
    cp -p "$backup" "$main"
    systemctl reload ssh || true
    die "SSH change failed; original configuration restored from $backup"
  fi
  log "SSH configuration validated and reloaded. Backup: $backup"
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
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/vps-init.local <<EOF
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
  [[ ! -e /swapfile ]] || die "/swapfile exists but is not active; inspect it before proceeding."
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

report_status() {
  local output
  printf '\n=== 当前状态（只读检查） ===\n'
  printf '\n[防火墙 UFW]\n'
  if command -v ufw >/dev/null; then
    LC_ALL=C ufw status verbose || warn "无法读取防火墙状态"
  else
    warn "UFW 未安装"
  fi
  printf '\n[fail2ban 服务]\n'
  if command -v systemctl >/dev/null; then
    systemctl is-active fail2ban || warn "fail2ban 未运行或无法查询"
  else
    warn "systemctl 不可用"
  fi
  printf '\n[SSH 防护规则]\n'
  if command -v fail2ban-client >/dev/null; then
    # Avoid printing banned IP addresses in a report people may share.
    if output="$(fail2ban-client status sshd 2>&1)"; then
      printf '%s\n' "$output" | sed '/Banned IP list:/d'
    else
      warn "无法读取 sshd 防护规则；请检查 fail2ban"
    fi
  else
    warn "fail2ban-client 未安装"
  fi
  printf '\n[实际 swap：不是配置的目标大小]\n'
  if command -v swapon >/dev/null; then
    if output="$(swapon --show --noheadings --output NAME,TYPE,SIZE,USED 2>/dev/null)"; then
      if [[ -n "$output" ]]; then
        printf 'NAME TYPE SIZE USED\n%s\n' "$output"
      else
        printf '没有启用的 swap\n'
      fi
    else
      warn "无法读取 swap 状态"
    fi
  else
    warn "swapon 不可用"
  fi
  printf '\n此报告不验证外部 SSH 登录、重启后状态或原有业务。\n'
}

print_summary() {
  report_status
  cat <<EOF

$(printf '\033[1;36m=========================================================\033[0m')
 VPS initialization complete. / VPS 基础初始化完成。

 - SSH port:        ${SSH_PORT}
 - Root login:       $( [[ "${DISABLE_ROOT_LOGIN}" == "true" ]] && echo disabled || echo unchanged )
 - Password auth:    $( [[ "${DISABLE_PASSWORD_AUTH}" == "true" ]] && echo disabled || echo unchanged )
 - New user:         ${NEW_USER:-none created}

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
    --user|--ssh-key|--ssh-key-url|--ssh-port|--timezone|--swap)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $1" ;;
  esac
  case "$1" in
    --user) NEW_USER="$2"; shift 2 ;;
    --ssh-key) SSH_PUBKEY="$2"; shift 2 ;;
    --ssh-key-url) SSH_PUBKEY_URL="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --swap) SWAP_SIZE="$2"; shift 2 ;;
    --no-swap) SKIP_SWAP="true"; shift ;;
    --disable-password-auth) DISABLE_PASSWORD_AUTH="true"; shift ;;
    --status) STATUS_ONLY="true"; shift ;;
    --check) CHECK_ONLY="true"; shift ;;
    --disable-root-login) DISABLE_ROOT_LOGIN="true"; shift ;;
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

# Status is independent of installation options and never runs setup steps.
if [[ "$STATUS_ONLY" == true ]]; then
  require_root
  report_status
  exit 0
fi

# Validate before changing the machine.
[[ -z "$NEW_USER" || "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Invalid username"
[[ "$NEW_USER" != root ]] || die "Choose a non-root username"
[[ "$SWAP_SIZE" =~ ^[1-9][0-9]*[MG]$ ]] || die "Swap size must be like 512M or 2G"
[[ -z "$SSH_PORT" || "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || die "Invalid SSH port"
[[ -z "$SSH_PORT" ]] || ((10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535)) || die "Invalid SSH port"
if [[ -n "$SSH_PUBKEY" || -n "$SSH_PUBKEY_URL" || "$DISABLE_ROOT_LOGIN" == true || "$DISABLE_PASSWORD_AUTH" == true ]]; then
  [[ -n "$NEW_USER" ]] || die "SSH keys and login restrictions require --user"
fi
if [[ -n "$NEW_USER" ]]; then
  [[ -n "$SSH_PUBKEY" || -n "$SSH_PUBKEY_URL" ]] || die "A new user requires your SSH PUBLIC key"
fi
[[ -z "$SSH_PUBKEY" || -z "$SSH_PUBKEY_URL" ]] || die "Choose one public-key source"
[[ -z "$SSH_PUBKEY_URL" || "$SSH_PUBKEY_URL" == https://* ]] || die "Public-key URL must use HTTPS"
require_root
detect_os
command -v sshd >/dev/null || die "OpenSSH server is required"
sshd -t || die "Existing SSH configuration is invalid"
ports="$(sshd -T | awk '$1 == "port" {print $2}')"
[[ "$ports" =~ ^[0-9]+$ ]] || die "Multiple SSH ports detected; configure the firewall manually"
[[ -z "$SSH_PORT" || "$SSH_PORT" == "$ports" ]] || die "Port changes are not supported. Current configured port: $ports"
SSH_PORT="$ports"
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ connected_port <<< "$SSH_CONNECTION"
  [[ "$connected_port" == "$SSH_PORT" ]] || die "Active SSH port differs from config; check socket activation before proceeding"
fi
[[ -z "$TIMEZONE" || ( "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ) ]] || die "Unknown timezone"
if [[ -n "$SSH_PUBKEY_URL" ]]; then
  command -v curl >/dev/null || die "Install curl first, or supply --ssh-key"
  SSH_PUBKEY="$(curl --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -fsSL "$SSH_PUBKEY_URL")"
fi
if [[ -n "$NEW_USER" ]]; then
  [[ -n "$SSH_PUBKEY" ]] || die "Public-key source returned no keys"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin >/dev/null || die "Invalid SSH public key"
  done <<< "$SSH_PUBKEY"
fi
log "Checks passed. SSH port: $SSH_PORT; existing login policy is preserved unless explicitly changed."
[[ "$CHECK_ONLY" == false ]] || exit 0
warn "Use a fresh VPS. UFW blocks incoming services other than SSH unless already allowed."
[[ -z "$NEW_USER" ]] || warn "$NEW_USER will receive passwordless sudo (administrator access)."
confirm "即将更新系统、安装工具，并按选项配置防火墙和 swap。是否继续？" || die "Aborted."
if [[ "$DISABLE_ROOT_LOGIN" == true || "$DISABLE_PASSWORD_AUTH" == true ]]; then
  [[ "$NON_INTERACTIVE" == false ]] || die "Login restrictions require an interactive second-session check"
fi
step_update_system
step_install_basic_tools
step_set_timezone
step_create_user
step_setup_firewall
step_setup_fail2ban
step_setup_swap
step_enable_auto_updates
if [[ "$DISABLE_ROOT_LOGIN" == true || "$DISABLE_PASSWORD_AUTH" == true ]]; then
  warn "Keep this connection open. In a SECOND terminal, log in as $NEW_USER on port $SSH_PORT and run sudo -n true."
  read -r -p 'Type VERIFIED only after both succeed: ' verified
  [[ "$verified" == VERIFIED ]] || die "Login policy unchanged; verification not completed"
fi
step_harden_ssh
print_summary
