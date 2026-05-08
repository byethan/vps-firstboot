#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SSH_USER="${SSH_USER:-${NEW_USER:-root}}"
SSH_PORT="${SSH_PORT:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-}"
COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-yes}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ASSUME_YES="${ASSUME_YES:-no}"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-firstboot.sh --port <ssh-port> --public-key 'ssh-ed25519 AAAA...'

Options:
  --user NAME           Existing SSH user to install the key for. Default: root
  --port PORT           SSH port to use. Required
  --public-key KEY      SSH public key text to install for the user
  --key-file PATH       File containing one SSH public key on the server
  --no-copy-root-keys   Do not copy /root/.ssh/authorized_keys as fallback
  --enable-fail2ban     Install and configure fail2ban for the SSH port
  --no-fail2ban         Do not install and configure fail2ban
  -y, --yes             Non-interactive mode
  -h, --help            Show this help

Environment variables with the same names also work:
  SSH_USER, SSH_PORT, PUBLIC_KEY, PUBLIC_KEY_FILE, COPY_ROOT_KEYS, ENABLE_FAIL2BAN, ASSUME_YES

What this script does:
  1. install SSH public keys for an existing SSH user, root by default
  2. move SSH to the port you specify
  3. disable SSH password login
  4. keep root login key-only
  5. optionally install fail2ban and protect the SSH port

Important:
  Keep the current SSH session open. Open a second terminal and test:
    ssh -p <PORT> <USER>@<SERVER_IP>
USAGE
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "yes" ]]; then
    return 0
  fi

  read -r -p "$prompt [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 ]] || die "--user requires a value"
        SSH_USER="${2:-}"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a value"
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --public-key)
        [[ $# -ge 2 ]] || die "--public-key requires a value"
        PUBLIC_KEY="${2:-}"
        shift 2
        ;;
      --key-file)
        [[ $# -ge 2 ]] || die "--key-file requires a value"
        PUBLIC_KEY_FILE="${2:-}"
        shift 2
        ;;
      --no-copy-root-keys)
        COPY_ROOT_KEYS="no"
        shift
        ;;
      --enable-fail2ban)
        ENABLE_FAIL2BAN="yes"
        shift
        ;;
      --no-fail2ban)
        ENABLE_FAIL2BAN="no"
        shift
        ;;
      -y|--yes)
        ASSUME_YES="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo bash $SCRIPT_NAME"
  [[ -n "$SSH_USER" ]] || die "--user cannot be empty"
  [[ -n "$SSH_PORT" ]] || die "--port is required"
  [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid Linux user name: $SSH_USER"
  id "$SSH_USER" >/dev/null 2>&1 || die "user $SSH_USER does not exist; create it before running this script"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be a number"
  (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || die "use a port from 1024 to 65535"

  if [[ -n "$PUBLIC_KEY_FILE" ]]; then
    [[ -r "$PUBLIC_KEY_FILE" ]] || die "cannot read key file: $PUBLIC_KEY_FILE"
    PUBLIC_KEY="$(sed -n '1p' "$PUBLIC_KEY_FILE")"
  fi

  if [[ -n "$PUBLIC_KEY" ]]; then
    [[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]+ ]] || die "public key does not look like an SSH public key"
  fi
}

install_authorized_keys() {
  local user_home
  user_home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  [[ -n "$user_home" ]] || die "cannot find home directory for $SSH_USER"

  install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "$user_home/.ssh"

  if [[ -n "$PUBLIC_KEY" ]]; then
    printf '%s\n' "$PUBLIC_KEY" >"$user_home/.ssh/authorized_keys"
  elif [[ "$COPY_ROOT_KEYS" == "yes" && -s /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$user_home/.ssh/authorized_keys"
  else
    die "no SSH public key supplied, and /root/.ssh/authorized_keys is empty; refusing to disable password login"
  fi

  chown "$SSH_USER:$SSH_USER" "$user_home/.ssh/authorized_keys"
  chmod 0600 "$user_home/.ssh/authorized_keys"
}

configure_sshd() {
  local include_file="/etc/ssh/sshd_config.d/99-login-hardening.conf"
  local sshd_bin

  install -d -m 0755 /etc/ssh/sshd_config.d
  cat >"$include_file" <<SSHD
Port $SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
AllowUsers $SSH_USER
SSHD

  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >>/etc/ssh/sshd_config
  fi

  sshd_bin="$(command -v sshd || true)"
  sshd_bin="${sshd_bin:-/usr/sbin/sshd}"
  "$sshd_bin" -t

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^ssh\.socket'; then
      systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    fi

    if systemctl list-unit-files | grep -q '^ssh\.service'; then
      systemctl restart ssh
    elif systemctl list-unit-files | grep -q '^sshd\.service'; then
      systemctl restart sshd
    else
      service ssh restart
    fi
  else
    service ssh restart
  fi
}

install_fail2ban() {
  local fail2ban_backend="auto"

  if [[ "$ENABLE_FAIL2BAN" != "yes" ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y fail2ban
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y fail2ban
  elif command -v yum >/dev/null 2>&1; then
    yum install -y fail2ban
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache fail2ban
  else
    die "cannot install fail2ban automatically on this system; unsupported package manager"
  fi

  if command -v systemctl >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1; then
    fail2ban_backend="systemd"
  fi

  install -d -m 0755 /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<FAIL2BAN
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
backend = $fail2ban_backend
FAIL2BAN

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now fail2ban
    systemctl restart fail2ban
  else
    service fail2ban restart
  fi
}

print_plan() {
  cat <<PLAN

Plan:
  ssh user:         $SSH_USER
  ssh port:        $SSH_PORT
  copy root keys:  $COPY_ROOT_KEYS
  fail2ban:        $ENABLE_FAIL2BAN

This will disable SSH password login. Root login remains key-only if the user is root.

PLAN
}

show_verification_status() {
  local sshd_t
  sshd_t="$(sshd -T 2>/dev/null || true)"

  printf '\nVerification:\n'
  printf 'ssh_listen_target: %s\n' "$(ss -ltnp | grep -Eq "[:.]${SSH_PORT}\\b" && echo yes || echo no)"
  printf 'ssh_listen_22: %s\n' "$(ss -ltnp | grep -Eq '[:.]22\\b' && echo yes || echo no)"
  printf 'sshd_port: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^port / {print $2; exit}')"
  printf 'pubkeyauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^pubkeyauthentication / {print $2; exit}')"
  printf 'passwordauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^passwordauthentication / {print $2; exit}')"
  printf 'permitrootlogin: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^permitrootlogin / {print $2; exit}')"
  printf 'allowusers: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^allowusers / {$1=""; sub(/^ /, ""); print; exit}')"

  if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      printf 'fail2ban_service: %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo not-installed)"
    else
      printf 'fail2ban_service: %s\n' "unknown"
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
      printf 'fail2ban_jail_sshd: %s\n' "$(fail2ban-client status sshd 2>/dev/null | awk -F': *' '/Status for the jail/ {print $2; found=1} END{if(!found) print "missing"}')"
      printf 'fail2ban_banned: %s\n' "$(fail2ban-client status sshd 2>/dev/null | awk -F': *' '/Currently banned/ {print $2; found=1} END{if(!found) print "unknown"}')"
    else
      printf 'fail2ban_jail_sshd: %s\n' "not-installed"
      printf 'fail2ban_banned: %s\n' "unknown"
    fi
  fi
}

final_message() {
  cat <<DONE

Done.

The current verification status is shown above.

Do not close this terminal yet. Open a second terminal and test:
  ssh -p $SSH_PORT $SSH_USER@SERVER_IP

DONE
}

main() {
  parse_args "$@"
  validate_inputs
  print_plan
  confirm "Proceed with SSH login hardening?" || die "aborted"

  install_authorized_keys
  configure_sshd
  install_fail2ban
  show_verification_status
  final_message
}

main "$@"
