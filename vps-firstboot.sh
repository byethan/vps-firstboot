#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SSH_USER="${SSH_USER:-${NEW_USER:-root}}"
SSH_PORT="${SSH_PORT:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-}"
COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-yes}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ENABLE_BBR_FQ="${ENABLE_BBR_FQ:-yes}"
ENABLE_VPS_SYSCTL="${ENABLE_VPS_SYSCTL:-yes}"
TCP_TUNE_ARGS_SEEN="no"
TCP_TUNE_ONLY="${TCP_TUNE_ONLY:-no}"
TUNE_BANDWIDTH="${TUNE_BANDWIDTH:-${BANDWIDTH:-500}}"
TUNE_REGION="${TUNE_REGION:-${REGION:-asia}}"
DRY_RUN="${DRY_RUN:-no}"
TC_IFACE="${TC_IFACE:-}"
TC_RATE="${TC_RATE:-}"
TC_MTU="${TC_MTU:-}"
TC_BURST="${TC_BURST:-256k}"
ASSUME_YES="${ASSUME_YES:-no}"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-firstboot.sh --port <ssh-port> --public-key 'ssh-ed25519 AAAA...'
  sudo bash vps-firstboot.sh --bandwidth 1000 --region asia

Options:
  --user NAME           Existing SSH user to install the key for. Default: root
  --port PORT           SSH port to use. Required for SSH hardening
  --public-key KEY      SSH public key text to install for the user
  --key-file PATH       File containing one SSH public key on the server
  --no-copy-root-keys   Do not copy /root/.ssh/authorized_keys as fallback
  --enable-fail2ban     Install and configure fail2ban for the SSH port
  --no-fail2ban         Do not install and configure fail2ban
  --enable-bbr-fq       Enable Linux TCP BBR with fq qdisc. Default: yes
  --no-bbr-fq           Do not configure Linux TCP BBR with fq qdisc
  --enable-vps-sysctl   Apply TCP/sysctl tuning profile. Default: yes
  --no-vps-sysctl       Do not apply the TCP/sysctl tuning profile
  --network-only        Only apply network optimization; skip SSH hardening
  --tcp-tune-only       Alias of --network-only
  --bandwidth MBPS      TCP tuning profile bandwidth. Examples: 500, 1000. Default: 500
  --region REGION       TCP tuning profile region: asia or overseas. Default: asia
  --dry-run             Preview TCP tuning files without applying changes
  --tc-iface IFACE      Configure optional egress shaping on this interface
  --tc-rate RATE        Egress shaping rate, for example 97mbit
  --tc-mtu MTU          Optional MTU to set before shaping, for example 1492
  --tc-burst BURST      Optional HTB burst size. Default: 256k
  -y, --yes             Non-interactive mode
  -h, --help            Show this help

Environment variables with the same names also work:
  SSH_USER, SSH_PORT, PUBLIC_KEY, PUBLIC_KEY_FILE, COPY_ROOT_KEYS, ENABLE_FAIL2BAN,
  ENABLE_BBR_FQ, ENABLE_VPS_SYSCTL, TCP_TUNE_ONLY, TUNE_BANDWIDTH, BANDWIDTH,
  TUNE_REGION, REGION, DRY_RUN, TC_IFACE, TC_RATE, TC_MTU, TC_BURST, ASSUME_YES

What this script does:
  1. install SSH public keys for an existing SSH user, root by default
  2. move SSH to the port you specify
  3. disable SSH password login
  4. keep root login key-only
  5. enable Linux TCP BBR with fq qdisc by default
  6. apply a region/bandwidth TCP tuning profile by default
  7. optionally install fail2ban and protect the SSH port
  8. optionally configure tc egress shaping when iface and rate are supplied
  9. create a systemd service to restore fq on the default route interface

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

ssh_hardening_enabled() {
  [[ "$TCP_TUNE_ONLY" != "yes" ]]
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
      --enable-bbr-fq)
        ENABLE_BBR_FQ="yes"
        shift
        ;;
      --no-bbr-fq)
        ENABLE_BBR_FQ="no"
        shift
        ;;
      --enable-vps-sysctl)
        ENABLE_VPS_SYSCTL="yes"
        shift
        ;;
      --no-vps-sysctl)
        ENABLE_VPS_SYSCTL="no"
        shift
        ;;
      --network-only|--tcp-tune-only)
        TCP_TUNE_ONLY="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --bandwidth)
        [[ $# -ge 2 ]] || die "--bandwidth requires a value"
        TUNE_BANDWIDTH="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --region)
        [[ $# -ge 2 ]] || die "--region requires a value"
        TUNE_REGION="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --tc-iface)
        [[ $# -ge 2 ]] || die "--tc-iface requires a value"
        TC_IFACE="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --tc-rate)
        [[ $# -ge 2 ]] || die "--tc-rate requires a value"
        TC_RATE="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --tc-mtu)
        [[ $# -ge 2 ]] || die "--tc-mtu requires a value"
        TC_MTU="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --tc-burst)
        [[ $# -ge 2 ]] || die "--tc-burst requires a value"
        TC_BURST="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
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
  if [[ -z "$SSH_PORT" && "$TCP_TUNE_ARGS_SEEN" == "yes" ]]; then
    TCP_TUNE_ONLY="yes"
  fi

  [[ "$COPY_ROOT_KEYS" =~ ^(yes|no)$ ]] || die "COPY_ROOT_KEYS must be yes or no"
  [[ "$ENABLE_FAIL2BAN" =~ ^(yes|no)$ ]] || die "ENABLE_FAIL2BAN must be yes or no"
  [[ "$ENABLE_BBR_FQ" =~ ^(yes|no)$ ]] || die "ENABLE_BBR_FQ must be yes or no"
  [[ "$ENABLE_VPS_SYSCTL" =~ ^(yes|no)$ ]] || die "ENABLE_VPS_SYSCTL must be yes or no"
  [[ "$TCP_TUNE_ONLY" =~ ^(yes|no)$ ]] || die "TCP_TUNE_ONLY must be yes or no"
  [[ "$DRY_RUN" =~ ^(yes|no)$ ]] || die "DRY_RUN must be yes or no"
  [[ "$ASSUME_YES" =~ ^(yes|no)$ ]] || die "ASSUME_YES must be yes or no"
  [[ "$TUNE_REGION" =~ ^(asia|overseas)$ ]] || die "--region must be asia or overseas"
  [[ "$TUNE_BANDWIDTH" =~ ^[0-9]+$ ]] || die "--bandwidth must be a number in Mbps"
  (( TUNE_BANDWIDTH >= 1 && TUNE_BANDWIDTH <= 100000 )) || die "--bandwidth must be from 1 to 100000 Mbps"

  if [[ "$DRY_RUN" != "yes" ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo bash $SCRIPT_NAME"
  fi

  if ssh_hardening_enabled; then
    [[ -n "$SSH_USER" ]] || die "--user cannot be empty"
    [[ -n "$SSH_PORT" ]] || die "--port is required"
    [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid Linux user name: $SSH_USER"
    id "$SSH_USER" >/dev/null 2>&1 || die "user $SSH_USER does not exist; create it before running this script"
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be a number"
    (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || die "use a port from 1024 to 65535"
  elif [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
    die "--enable-fail2ban requires SSH hardening and --port"
  fi

  if [[ -n "$PUBLIC_KEY_FILE" ]]; then
    [[ -r "$PUBLIC_KEY_FILE" ]] || die "cannot read key file: $PUBLIC_KEY_FILE"
    PUBLIC_KEY="$(sed -n '1p' "$PUBLIC_KEY_FILE")"
  fi

  if [[ -n "$PUBLIC_KEY" ]]; then
    [[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]+ ]] || die "public key does not look like an SSH public key"
  fi

  if [[ -n "$TC_IFACE" || -n "$TC_RATE" || -n "$TC_MTU" ]]; then
    [[ -n "$TC_IFACE" ]] || die "--tc-iface is required when tc shaping is enabled"
    [[ -n "$TC_RATE" ]] || die "--tc-rate is required when tc shaping is enabled"
    [[ "$TC_IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid tc interface: $TC_IFACE"
    [[ "$TC_RATE" =~ ^[0-9]+(kbit|mbit|gbit)$ ]] || die "invalid tc rate, use values like 97mbit"
    [[ "$TC_BURST" =~ ^[0-9]+[kKmMgG]?$ ]] || die "invalid tc burst, use values like 256k"
    if [[ -n "$TC_MTU" ]]; then
      [[ "$TC_MTU" =~ ^[0-9]+$ ]] || die "tc MTU must be a number"
      (( TC_MTU >= 576 && TC_MTU <= 9000 )) || die "tc MTU must be from 576 to 9000"
    fi
    if [[ "$DRY_RUN" != "yes" ]]; then
      command -v ip >/dev/null 2>&1 || die "ip command is required for tc shaping"
      command -v tc >/dev/null 2>&1 || die "tc command is required for tc shaping"
      ip link show dev "$TC_IFACE" >/dev/null 2>&1 || die "network interface does not exist: $TC_IFACE"
    fi
  fi
}

install_authorized_keys() {
  local auth_keys
  local source_keys="/root/.ssh/authorized_keys"
  local user_group
  local user_home
  user_home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  [[ -n "$user_home" ]] || die "cannot find home directory for $SSH_USER"
  user_group="$(id -gn "$SSH_USER")"
  auth_keys="$user_home/.ssh/authorized_keys"

  install -d -m 0700 -o "$SSH_USER" -g "$user_group" "$user_home/.ssh"

  if [[ -n "$PUBLIC_KEY" ]]; then
    touch "$auth_keys"
    if ! grep -Fxq "$PUBLIC_KEY" "$auth_keys"; then
      printf '%s\n' "$PUBLIC_KEY" >>"$auth_keys"
    fi
  elif [[ "$COPY_ROOT_KEYS" == "yes" && -s "$source_keys" ]]; then
    if [[ "$(readlink -f "$source_keys")" != "$(readlink -f "$auth_keys" 2>/dev/null || printf '%s' "$auth_keys")" ]]; then
      cp "$source_keys" "$auth_keys"
    fi
  else
    die "no SSH public key supplied, and /root/.ssh/authorized_keys is empty; refusing to disable password login"
  fi

  chown "$SSH_USER:$user_group" "$auth_keys"
  chmod 0600 "$auth_keys"
}

comment_global_sshd_directives() {
  local config_file="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  awk '
    BEGIN {
      split("Port PubkeyAuthentication PasswordAuthentication KbdInteractiveAuthentication ChallengeResponseAuthentication PermitRootLogin PermitEmptyPasswords AllowUsers", keys)
      for (i in keys) managed[tolower(keys[i])] = 1
      in_match = 0
    }
    /^[[:space:]]*Match[[:space:]]/ { in_match = 1 }
    {
      line = $0
      stripped = line
      sub(/^[[:space:]]*/, "", stripped)
      split(stripped, parts, /[[:space:]]+/)
      key = tolower(parts[1])
      if (!in_match && line !~ /^[[:space:]]*#/ && managed[key]) {
        print "# managed by vps-firstboot: " line
      } else {
        print line
      }
    }
  ' "$config_file" >"$tmp_file"
  cat "$tmp_file" >"$config_file"
  rm -f "$tmp_file"
}

ensure_sshd_dropin_include() {
  local config_file="$1"
  local tmp_file

  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$config_file"; then
    return 0
  fi

  tmp_file="$(mktemp)"
  {
    printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
    cat "$config_file"
  } >"$tmp_file"
  cat "$tmp_file" >"$config_file"
  rm -f "$tmp_file"
}

configure_sshd() {
  local include_file="/etc/ssh/sshd_config.d/00-login-hardening.conf"
  local legacy_include_file="/etc/ssh/sshd_config.d/99-login-hardening.conf"
  local sshd_bin

  install -d -m 0755 /etc/ssh/sshd_config.d
  rm -f "$legacy_include_file"
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

  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
  comment_global_sshd_directives /etc/ssh/sshd_config
  ensure_sshd_dropin_include /etc/ssh/sshd_config

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

tune_profile() {
  case "$TUNE_REGION:$TUNE_BANDWIDTH" in
    asia:*)
      if (( TUNE_BANDWIDTH <= 500 )); then
        TUNE_RMEM_MAX=67108864
        TUNE_WMEM_MAX=67108864
        TUNE_BACKLOG=8192
        TUNE_NETDEV_BACKLOG=16384
      else
        TUNE_RMEM_MAX=134217728
        TUNE_WMEM_MAX=134217728
        TUNE_BACKLOG=16384
        TUNE_NETDEV_BACKLOG=32768
      fi
      ;;
    overseas:*)
      if (( TUNE_BANDWIDTH <= 500 )); then
        TUNE_RMEM_MAX=134217728
        TUNE_WMEM_MAX=134217728
        TUNE_BACKLOG=16384
        TUNE_NETDEV_BACKLOG=32768
      else
        TUNE_RMEM_MAX=268435456
        TUNE_WMEM_MAX=268435456
        TUNE_BACKLOG=32768
        TUNE_NETDEV_BACKLOG=65536
      fi
      ;;
  esac

  TUNE_TCP_RMEM="4096 87380 $TUNE_RMEM_MAX"
  TUNE_TCP_WMEM="4096 65536 $TUNE_WMEM_MAX"
  TUNE_KEEPALIVE_TIME=600
  TUNE_KEEPALIVE_INTVL=60
  TUNE_KEEPALIVE_PROBES=5
  TUNE_LOCAL_PORT_RANGE="10240 65535"
}

print_tcp_tune_sysctl() {
  tune_profile
  printf '# Generated by %s\n' "$SCRIPT_NAME"
  printf '# profile: region=%s bandwidth=%sMbps\n' "$TUNE_REGION" "$TUNE_BANDWIDTH"

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  fi

  if [[ "$ENABLE_VPS_SYSCTL" == "yes" ]]; then
    printf 'net.core.rmem_max = %s\n' "$TUNE_RMEM_MAX"
    printf 'net.core.wmem_max = %s\n' "$TUNE_WMEM_MAX"
    printf 'net.ipv4.tcp_rmem = %s\n' "$TUNE_TCP_RMEM"
    printf 'net.ipv4.tcp_wmem = %s\n' "$TUNE_TCP_WMEM"
    printf 'net.ipv4.tcp_mtu_probing = 1\n'
    printf 'net.ipv4.tcp_fastopen = 3\n'
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
    printf 'net.ipv4.tcp_syncookies = 1\n'
    printf 'net.ipv4.tcp_tw_reuse = 1\n'
    printf 'net.ipv4.tcp_keepalive_time = %s\n' "$TUNE_KEEPALIVE_TIME"
    printf 'net.ipv4.tcp_keepalive_intvl = %s\n' "$TUNE_KEEPALIVE_INTVL"
    printf 'net.ipv4.tcp_keepalive_probes = %s\n' "$TUNE_KEEPALIVE_PROBES"
    printf 'net.ipv4.tcp_fin_timeout = 15\n'
    printf 'net.ipv4.tcp_max_syn_backlog = %s\n' "$TUNE_BACKLOG"
    printf 'net.core.somaxconn = %s\n' "$TUNE_BACKLOG"
    printf 'net.core.netdev_max_backlog = %s\n' "$TUNE_NETDEV_BACKLOG"
    printf 'net.ipv4.ip_local_port_range = %s\n' "$TUNE_LOCAL_PORT_RANGE"
  fi
}

print_fq_restore_files() {
  cat <<'FQ_RESTORE_SCRIPT'
/etc/default/vps-fq-restore:
# Space-separated interface names. Leave empty to use default route interfaces.
VPS_FQ_IFACES=

/usr/local/sbin/vps-fq-restore:
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/default/vps-fq-restore ]]; then
  . /etc/default/vps-fq-restore
fi

sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true

if [[ -z "${VPS_FQ_IFACES:-}" ]]; then
  VPS_FQ_IFACES="$(ip route show default 2>/dev/null | awk '{print $5}' | sort -u | tr '\n' ' ')"
fi

for iface in $VPS_FQ_IFACES; do
  [[ "$iface" == "lo" ]] && continue
  ip link show dev "$iface" >/dev/null 2>&1 || continue
  root_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}')"
  case "$root_qdisc" in
    htb|cake) continue ;;
  esac
  tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
done

/etc/systemd/system/vps-fq-restore.service:
[Unit]
Description=Restore fq queue discipline for VPS TCP tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-fq-restore

[Install]
WantedBy=multi-user.target
FQ_RESTORE_SCRIPT
}

apply_sysctl_setting() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  if ! sysctl -n "$key" >/dev/null 2>&1; then
    log "warning: sysctl key $key is unavailable; skipping"
    return 0
  fi

  printf '%s = %s\n' "$key" "$value" >>"$config_file"
  sysctl -w "$key=$value" >/dev/null 2>&1 || log "warning: failed to apply $key=$value"
}

install_fq_restore_service() {
  local default_file="/etc/default/vps-fq-restore"
  local script_file="/usr/local/sbin/vps-fq-restore"
  local service_file="/etc/systemd/system/vps-fq-restore.service"

  if [[ "$ENABLE_BBR_FQ" != "yes" ]]; then
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log "warning: fq restore service not installed because systemctl is unavailable"
    return 0
  fi

  if ! command -v ip >/dev/null 2>&1 || ! command -v tc >/dev/null 2>&1; then
    log "warning: fq restore service requires ip and tc from iproute2"
    return 0
  fi

  install -d -m 0755 /etc/default /usr/local/sbin
  cat >"$default_file" <<'FQ_DEFAULT'
# Space-separated interface names. Leave empty to use default route interfaces.
VPS_FQ_IFACES=
FQ_DEFAULT

  cat >"$script_file" <<'FQ_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/default/vps-fq-restore ]]; then
  . /etc/default/vps-fq-restore
fi

sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true

if [[ -z "${VPS_FQ_IFACES:-}" ]]; then
  VPS_FQ_IFACES="$(ip route show default 2>/dev/null | awk '{print $5}' | sort -u | tr '\n' ' ')"
fi

for iface in $VPS_FQ_IFACES; do
  [[ "$iface" == "lo" ]] && continue
  ip link show dev "$iface" >/dev/null 2>&1 || continue
  root_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2}')"
  case "$root_qdisc" in
    htb|cake) continue ;;
  esac
  tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
done
FQ_SCRIPT
  chmod 0755 "$script_file"

  cat >"$service_file" <<'FQ_SERVICE'
[Unit]
Description=Restore fq queue discipline for VPS TCP tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-fq-restore

[Install]
WantedBy=multi-user.target
FQ_SERVICE

  "$script_file"
  systemctl daemon-reload || log "warning: failed to reload systemd after writing vps-fq-restore.service"
  systemctl enable vps-fq-restore.service >/dev/null 2>&1 || log "warning: failed to enable vps-fq-restore.service"
}

configure_tcp_tune() {
  local available
  local sysctl_file="/etc/sysctl.d/99-vps-tcp-tune.conf"

  if [[ "$ENABLE_BBR_FQ" != "yes" && "$ENABLE_VPS_SYSCTL" != "yes" ]]; then
    return 0
  fi

  tune_profile

  if [[ "$ENABLE_BBR_FQ" == "yes" && -x "$(command -v modprobe || true)" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  install -d -m 0755 /etc/sysctl.d
  rm -f /etc/sysctl.d/98-vps-baseline.conf /etc/sysctl.d/99-bbr-fq.conf
  : >"$sysctl_file"

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    apply_sysctl_setting "$sysctl_file" net.core.default_qdisc fq
    if [[ " $available " == *" bbr "* ]]; then
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_congestion_control bbr
    else
      log "warning: tcp_bbr is not available on this kernel; skipping tcp_congestion_control=bbr"
    fi
  fi

  if [[ "$ENABLE_VPS_SYSCTL" == "yes" ]]; then
    apply_sysctl_setting "$sysctl_file" net.core.rmem_max "$TUNE_RMEM_MAX"
    apply_sysctl_setting "$sysctl_file" net.core.wmem_max "$TUNE_WMEM_MAX"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_rmem "$TUNE_TCP_RMEM"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_wmem "$TUNE_TCP_WMEM"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_mtu_probing 1
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_fastopen 3
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_slow_start_after_idle 0
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_syncookies 1
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_tw_reuse 1
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_keepalive_time "$TUNE_KEEPALIVE_TIME"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_keepalive_intvl "$TUNE_KEEPALIVE_INTVL"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_keepalive_probes "$TUNE_KEEPALIVE_PROBES"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_fin_timeout 15
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_max_syn_backlog "$TUNE_BACKLOG"
    apply_sysctl_setting "$sysctl_file" net.core.somaxconn "$TUNE_BACKLOG"
    apply_sysctl_setting "$sysctl_file" net.core.netdev_max_backlog "$TUNE_NETDEV_BACKLOG"
    apply_sysctl_setting "$sysctl_file" net.ipv4.ip_local_port_range "$TUNE_LOCAL_PORT_RANGE"
  fi

  if [[ ! -s "$sysctl_file" ]]; then
    rm -f "$sysctl_file"
  fi

  install_fq_restore_service
}

configure_tc_shaping() {
  local config_file="/etc/default/vps-tc-shape"
  local script_file="/usr/local/sbin/vps-tc-shape"
  local service_file="/etc/systemd/system/vps-tc-shape.service"

  if [[ -z "$TC_IFACE" && -z "$TC_RATE" ]]; then
    return 0
  fi

  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/default

  cat >"$config_file" <<TC_CONFIG
TC_IFACE=$TC_IFACE
TC_RATE=$TC_RATE
TC_MTU=$TC_MTU
TC_BURST=$TC_BURST
TC_CONFIG

  cat >"$script_file" <<'TC_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

. /etc/default/vps-tc-shape

if [[ -n "${TC_MTU:-}" ]]; then
  ip link set dev "$TC_IFACE" mtu "$TC_MTU"
fi

tc qdisc del dev "$TC_IFACE" root >/dev/null 2>&1 || true
tc qdisc add dev "$TC_IFACE" root handle 1: htb default 10
tc class add dev "$TC_IFACE" parent 1: classid 1:1 htb rate "$TC_RATE" ceil "$TC_RATE" burst "$TC_BURST" cburst "$TC_BURST"
tc class add dev "$TC_IFACE" parent 1:1 classid 1:10 htb rate "$TC_RATE" ceil "$TC_RATE" burst "$TC_BURST" cburst "$TC_BURST"
tc qdisc add dev "$TC_IFACE" parent 1:10 fq_codel limit 1024 flows 1024 target 7ms interval 110ms
TC_SCRIPT
  chmod 0755 "$script_file"

  "$script_file"

  if command -v systemctl >/dev/null 2>&1; then
    cat >"$service_file" <<TC_SERVICE
[Unit]
Description=VPS tc egress shaping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script_file

[Install]
WantedBy=multi-user.target
TC_SERVICE
    systemctl daemon-reload || log "warning: failed to reload systemd after writing vps-tc-shape.service"
    systemctl enable vps-tc-shape.service >/dev/null 2>&1 || log "warning: failed to enable vps-tc-shape.service"
  else
    log "warning: tc shaping applied now but not persisted because systemctl is unavailable"
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

print_tcp_tune_dry_run() {
  cat <<DRYRUN

Dry run: TCP tuning preview only. No files will be written and no sysctl/tc changes will be applied.

Profile:
  region:           $TUNE_REGION
  bandwidth:        ${TUNE_BANDWIDTH}Mbps
  bbr + fq:         $ENABLE_BBR_FQ
  tcp sysctl:       $ENABLE_VPS_SYSCTL
  tc shaping:       ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}

Would write /etc/sysctl.d/99-vps-tcp-tune.conf:
DRYRUN
  print_tcp_tune_sysctl

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    printf '\nWould write fq restore files:\n'
    print_fq_restore_files
  fi

  if [[ -n "$TC_IFACE" && -n "$TC_RATE" ]]; then
    cat <<TC_PREVIEW

Would write tc shaping files:
  /etc/default/vps-tc-shape
  /usr/local/sbin/vps-tc-shape
  /etc/systemd/system/vps-tc-shape.service
TC_PREVIEW
  fi
}

print_plan() {
  if ssh_hardening_enabled; then
    cat <<PLAN

Plan:
  ssh hardening:    yes
  ssh user:         $SSH_USER
  ssh port:        $SSH_PORT
  copy root keys:  $COPY_ROOT_KEYS
  bbr + fq:         $ENABLE_BBR_FQ
  tcp sysctl:       $ENABLE_VPS_SYSCTL
  tcp profile:      $TUNE_REGION / ${TUNE_BANDWIDTH}Mbps
  fail2ban:        $ENABLE_FAIL2BAN
  tc shaping:       ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}

This will disable SSH password login. Root login remains key-only if the user is root.

PLAN
  else
    cat <<PLAN

Plan:
  ssh hardening:    no
  bbr + fq:         $ENABLE_BBR_FQ
  tcp sysctl:       $ENABLE_VPS_SYSCTL
  tcp profile:      $TUNE_REGION / ${TUNE_BANDWIDTH}Mbps
  tc shaping:       ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}

PLAN
  fi
}

show_verification_status() {
  local bbr_available
  local default_ifaces
  local sshd_t
  sshd_t=""
  if ssh_hardening_enabled; then
    sshd_t="$(sshd -T 2>/dev/null || true)"
  fi
  bbr_available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && echo yes || echo no)"
  default_ifaces="$(ip route show default 2>/dev/null | awk '{print $5}' | sort -u | tr '\n' ' ' || true)"

  printf '\nVerification:\n'
  if ssh_hardening_enabled; then
    printf 'ssh_listen_target: %s\n' "$(ss -ltnp | grep -Eq "[:.]${SSH_PORT}\\b" && echo yes || echo no)"
    printf 'ssh_listen_22: %s\n' "$(ss -ltnp | grep -Eq '[:.]22\\b' && echo yes || echo no)"
    printf 'sshd_port: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^port / {print $2; exit}')"
    printf 'pubkeyauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^pubkeyauthentication / {print $2; exit}')"
    printf 'passwordauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^passwordauthentication / {print $2; exit}')"
    printf 'permitrootlogin: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^permitrootlogin / {print $2; exit}')"
    printf 'allowusers: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^allowusers / {$1=""; sub(/^ /, ""); print; exit}')"
  fi
  printf 'bbr_available: %s\n' "$bbr_available"
  printf 'default_qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf 'tcp_rmem: %s\n' "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo unknown)"
  printf 'tcp_wmem: %s\n' "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo unknown)"
  printf 'tcp_mtu_probing: %s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
  printf 'tcp_fastopen: %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
  printf 'tcp_slow_start_after_idle: %s\n' "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo unknown)"
  printf 'tcp_tw_reuse: %s\n' "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo unknown)"
  printf 'tcp_keepalive: %s/%s/%s\n' "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo unknown)" "$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo unknown)" "$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo unknown)"
  printf 'tcp_max_syn_backlog: %s\n' "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo unknown)"
  printf 'ip_local_port_range: %s\n' "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo unknown)"
  printf 'somaxconn: %s\n' "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
  printf 'fq_restore_service: %s\n' "$(systemctl is-enabled vps-fq-restore.service 2>/dev/null || echo unavailable)"

  for iface in $default_ifaces; do
    printf 'tc_qdisc_%s: %s\n' "$iface" "$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print; found=1} END{if(!found) print "unknown"}')"
  done

  if [[ -n "$TC_IFACE" && -n "$TC_RATE" ]]; then
    printf 'tc_shape: %s @ %s\n' "$TC_IFACE" "$TC_RATE"
    printf 'tc_qdisc_root: %s\n' "$(tc qdisc show dev "$TC_IFACE" 2>/dev/null | awk 'NR==1 {print; found=1} END{if(!found) print "unknown"}')"
  fi

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
  if ssh_hardening_enabled; then
    cat <<DONE

Done.

The current verification status is shown above.

Do not close this terminal yet. Open a second terminal and test:
  ssh -p $SSH_PORT $SSH_USER@SERVER_IP

DONE
  else
    cat <<DONE

Done.

The current TCP/network verification status is shown above.

DONE
  fi
}

main() {
  parse_args "$@"
  validate_inputs

  if [[ "$DRY_RUN" == "yes" ]]; then
    print_tcp_tune_dry_run
    exit 0
  fi

  print_plan
  if ssh_hardening_enabled; then
    confirm "Proceed with SSH login hardening and network tuning?" || die "aborted"
  else
    confirm "Proceed with network tuning?" || die "aborted"
  fi

  if ssh_hardening_enabled; then
    install_authorized_keys
    configure_sshd
  fi

  configure_tcp_tune
  configure_tc_shaping
  install_fail2ban
  show_verification_status
  final_message
}

main "$@"
