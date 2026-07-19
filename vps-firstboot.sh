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
ENABLE_VPS_SYSCTL="${ENABLE_VPS_SYSCTL:-no}"
ENABLE_BDP_TUNE="${ENABLE_BDP_TUNE:-no}"
BDP_BANDWIDTH_MBPS="${BDP_BANDWIDTH_MBPS:-}"
BDP_RTT_MS="${BDP_RTT_MS:-}"
BDP_EXTRA_MIB="${BDP_EXTRA_MIB:-0}"
BDP_BUFFER_BYTES=""
ENABLE_LOCALE_FIX="${ENABLE_LOCALE_FIX:-yes}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-en_US.UTF-8}"
ENABLE_PREFER_IPV4="${ENABLE_PREFER_IPV4:-yes}"
ENABLE_BBRV3_KERNEL="${ENABLE_BBRV3_KERNEL:-yes}"
ENABLE_BPFTUNE="${ENABLE_BPFTUNE:-no}"
BPFTUNE_REPO="${BPFTUNE_REPO:-https://github.com/byethan/bpftune.git}"
BPFTUNE_REF="${BPFTUNE_REF:-main}"
BPFTUNE_SRC_DIR="${BPFTUNE_SRC_DIR:-/usr/local/src/bpftune}"
TCP_TUNE_ARGS_SEEN="no"
TCP_TUNE_ONLY="${TCP_TUNE_ONLY:-no}"
TUNE_BANDWIDTH="${TUNE_BANDWIDTH:-${BANDWIDTH:-auto}}"
TUNE_REGION="${TUNE_REGION:-${REGION:-auto}}"
TUNE_ROLE="${TUNE_ROLE:-${ROLE:-general}}"
SMART_TCP_TUNE="${SMART_TCP_TUNE:-auto}"
TUNE_BANDWIDTH_SOURCE="configured"
TUNE_REGION_SOURCE="configured"
TUNE_COUNTRY_CODE=""
TUNE_DEFAULT_IFACE=""
SMART_BUFFER_MB=""
SMART_BUFFER_BYTES=""
SMART_MEMORY_CAP_MB=""
DRY_RUN="${DRY_RUN:-no}"
TC_IFACE="${TC_IFACE:-}"
TC_RATE="${TC_RATE:-}"
TC_MTU="${TC_MTU:-}"
TC_BURST="${TC_BURST:-256k}"
ASSUME_YES="${ASSUME_YES:-no}"
BBRV3_ACTION="setup"
BBRV3_REPO="${BBRV3_REPO:-byJoey/Actions-bbr-v3}"
BBRV3_VERSION="${BBRV3_VERSION:-}"
BBRV3_FLAVOR="${BBRV3_FLAVOR:-standard}"
BBRV3_LOCK_VERSION="${BBRV3_LOCK_VERSION:-yes}"
BBRV3_LOCK_FILE="${BBRV3_LOCK_FILE:-/etc/vps-firstboot/bbrv3-version.lock}"
BBRV3_INSTALL_DIR="${BBRV3_INSTALL_DIR:-/var/cache/vps-firstboot/bbrv3}"
BBRV3_BACKUP_ROOT="${BBRV3_BACKUP_ROOT:-/root/vps-firstboot-backups}"
BBRV3_SELECTED_TAG=""
BBRV3_NEEDS_REBOOT="no"
BBRV3_BACKUP_DONE="no"
NETWORK_BACKUP_DONE="no"
NETWORK_BACKUP_DIR=""
NETWORK_TUNE_APPLIED="no"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-firstboot.sh --port <ssh-port> --public-key 'ssh-ed25519 AAAA...'
  sudo bash vps-firstboot.sh --bandwidth auto --region auto
  sudo bash vps-firstboot.sh install -y
  sudo bash vps-firstboot.sh check
  sudo bash vps-firstboot.sh rollback -y
  sudo bash vps-firstboot.sh network-rollback -y

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
  --enable-vps-sysctl   Deprecated compatibility flag; aggressive TCP/sysctl tuning is not written
  --no-vps-sysctl       Keep only the minimal BBR/fq sysctl baseline. Default: yes
  --enable-bdp-tune     Write BDP-based tcp_rmem/tcp_wmem max values
  --no-bdp-tune         Disable BDP-based TCP buffer values
  --bdp-bandwidth MBPS  Bottleneck bandwidth for BDP calculation, for example 600
  --bdp-rtt MS          RTT for BDP calculation, for example 170
  --bdp-extra-mib MIB   Optional headroom added to calculated BDP. Default: 0
  --enable-locale-fix   Configure system UTF-8 locale and SSH locale handling. Default: yes
  --no-locale-fix       Do not configure locale settings
  --system-locale NAME  Locale to generate and set. Default: en_US.UTF-8
  --prefer-ipv4         Prefer IPv4 when hostnames have both A and AAAA records. Default: yes
  --no-prefer-ipv4      Do not configure /etc/gai.conf IPv4 preference
  --enable-bbrv3-kernel Install standard BBRv3 kernel during normal setup. Default: yes
  --no-bbrv3-kernel     Skip BBRv3 kernel install during normal setup
  --enable-bpftune      Build, install, and enable bpftune BPF auto-tuning daemon
  --no-bpftune          Do not install or enable bpftune. Default: no
  --bpftune-repo URL    bpftune git repository. Default: https://github.com/byethan/bpftune.git
  --bpftune-ref REF     bpftune git branch/tag/ref. Default: main
  --bpftune-src DIR     bpftune source checkout directory. Default: /usr/local/src/bpftune
  --network-only        Only apply network optimization; skip SSH hardening
  --tcp-tune-only       Alias of --network-only
  --role ROLE           VPS role: general, transit, exit, or web. Default: general
  --enable-smart-tune   Apply memory-capped region/bandwidth TCP buffers
  --no-smart-tune       Keep minimal buffers. Default for general/web roles
  --bandwidth MBPS      TCP tuning profile bandwidth. Examples: auto, 500, 1000. Default: auto
  --region REGION       TCP tuning profile region: auto, asia, or overseas. "oversea" is accepted as overseas. Default: auto
  --dry-run             Preview TCP tuning files without applying changes
  --tc-iface IFACE      Configure optional egress shaping on this interface
  --tc-rate RATE        Egress shaping rate, for example 97mbit
  --tc-mtu MTU          Optional MTU to set before shaping, for example 1492
  --tc-burst BURST      Optional HTB burst size. Default: 256k
  --bbrv3-version TAG   BBRv3 release tag to install. Default: locked tag, then latest
  --bbrv3-repo OWNER/REPO
                        BBRv3 release repository. Default: byJoey/Actions-bbr-v3
  --bbrv3-standard      Install standard BBRv3 kernel. Default: yes
  --bbrv3-max           Install BBRv3 Max kernel. Not recommended for production
  --lock-bbrv3-version  Lock selected BBRv3 release tag for future installs. Default: yes
  --no-lock-bbrv3-version
                        Do not write/update the BBRv3 version lock
  -y, --yes             Non-interactive mode
  -h, --help            Show this help

Environment variables with the same names also work:
  SSH_USER, SSH_PORT, PUBLIC_KEY, PUBLIC_KEY_FILE, COPY_ROOT_KEYS, ENABLE_FAIL2BAN,
  ENABLE_BBR_FQ, ENABLE_VPS_SYSCTL, ENABLE_LOCALE_FIX, SYSTEM_LOCALE,
  ENABLE_PREFER_IPV4, ENABLE_BBRV3_KERNEL,
  ENABLE_BDP_TUNE, BDP_BANDWIDTH_MBPS, BDP_RTT_MS, BDP_EXTRA_MIB,
  ENABLE_BPFTUNE, BPFTUNE_REPO, BPFTUNE_REF, BPFTUNE_SRC_DIR, TCP_TUNE_ONLY,
  TUNE_BANDWIDTH, BANDWIDTH, TUNE_REGION, REGION, TUNE_ROLE, ROLE, SMART_TCP_TUNE,
  DRY_RUN, TC_IFACE, TC_RATE,
  TC_MTU, TC_BURST, ASSUME_YES, BBRV3_REPO, BBRV3_VERSION, BBRV3_FLAVOR,
  BBRV3_LOCK_VERSION, BBRV3_LOCK_FILE, BBRV3_INSTALL_DIR, BBRV3_BACKUP_ROOT

What this script does:
  1. install SSH public keys for an existing SSH user, root by default
  2. move SSH to the port you specify
  3. disable SSH password login
  4. keep root login key-only
  5. enable Linux TCP BBR with fq qdisc by default
  6. tune conservatively by VPS role; general stays at only BBR + fq by default
  7. optionally write memory-capped smart buffers or explicit BDP-based buffers
  8. configure a UTF-8 system locale and avoid invalid SSH LC_* imports
  9. prefer IPv4 for dual-stack hostname resolution without disabling IPv6
  10. install standard BBRv3 kernel by default, without automatic reboot
  11. optionally build and enable bpftune for BPF-driven Linux auto-tuning
  12. optionally install fail2ban and protect the SSH port
  13. optionally configure tc egress shaping when iface and rate are supplied
  14. create a systemd service to restore fq on the default route interface

Management subcommands:
  install   Install the standard BBRv3 kernel from GitHub Releases, enable BBR + fq,
            clean legacy aggressive sysctl snippets, and do not reboot automatically.
  check     Print OS, kernel, BBR module, qdisc, congestion control, lock, and reboot state.
  rollback  Restore latest sysctl backup and remove non-running BBRv3 kernel packages when safe.
  network-rollback
            Restore the latest managed network configuration backup without removing kernels.

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

normalize_region() {
  case "$TUNE_REGION" in
    oversea)
      TUNE_REGION="overseas"
      ;;
  esac
}

normalize_role() {
  case "$TUNE_ROLE" in
    line|relay)
      TUNE_ROLE="transit"
      ;;
    landing|proxy)
      TUNE_ROLE="exit"
      ;;
    site|website)
      TUNE_ROLE="web"
      ;;
  esac
}

default_route_iface() {
  ip route show default 2>/dev/null | awk 'NR == 1 {print $5; exit}'
}

fetch_url_quiet() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 2 --max-time 4 "$url" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=4 "$url" 2>/dev/null || true
  fi
}

detect_country_code() {
  local body
  local code

  body="$(fetch_url_quiet https://ifconfig.co/country-iso | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)"
  if [[ "$body" =~ ^[A-Z]{2}$ ]]; then
    printf '%s\n' "$body"
    return 0
  fi

  body="$(fetch_url_quiet https://ipinfo.io/country | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]' || true)"
  if [[ "$body" =~ ^[A-Z]{2}$ ]]; then
    printf '%s\n' "$body"
    return 0
  fi

  body="$(fetch_url_quiet https://www.cloudflare.com/cdn-cgi/trace || true)"
  code="$(printf '%s\n' "$body" | awk -F= '/^loc=/ {print toupper($2); exit}')"
  if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
    printf '%s\n' "$code"
    return 0
  fi

  return 1
}

country_to_region() {
  local country="$1"
  case "$country" in
    AF|AM|AZ|BD|BN|BT|CC|CN|CX|GE|HK|ID|IN|IO|JP|KG|KH|KP|KR|KZ|LA|LK|MM|MN|MO|MV|MY|NP|PH|PK|SG|TH|TJ|TL|TM|TW|UZ|VN|AU|FJ|FM|GU|KI|MH|MP|NC|NF|NR|NU|NZ|PF|PG|PN|PW|SB|TK|TO|TV|VU|WF|WS)
      printf '%s\n' asia
      ;;
    *)
      printf '%s\n' overseas
      ;;
  esac
}

detect_bandwidth_mbps() {
  local iface="$1"
  local speed_file
  local speed

  if [[ -n "$iface" ]]; then
    speed_file="/sys/class/net/$iface/speed"
    if [[ -r "$speed_file" ]]; then
      speed="$(cat "$speed_file" 2>/dev/null || true)"
      if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed >= 1 && speed <= 100000 )); then
        printf '%s\n' "$speed"
        return 0
      fi
    fi
  fi

  return 1
}

resolve_auto_profile() {
  local detected_bandwidth

  if [[ "$TUNE_REGION" == "auto" ]]; then
    TUNE_COUNTRY_CODE="$(detect_country_code || true)"
    if [[ -n "$TUNE_COUNTRY_CODE" ]]; then
      TUNE_REGION="$(country_to_region "$TUNE_COUNTRY_CODE")"
      TUNE_REGION_SOURCE="auto-country:$TUNE_COUNTRY_CODE"
    else
      TUNE_REGION="asia"
      TUNE_REGION_SOURCE="fallback"
      log "warning: could not detect VPS country; using region=asia"
    fi
  fi

  if [[ "$TUNE_BANDWIDTH" == "auto" ]]; then
    TUNE_DEFAULT_IFACE="$(default_route_iface || true)"
    detected_bandwidth="$(detect_bandwidth_mbps "$TUNE_DEFAULT_IFACE" || true)"
    if [[ -n "$detected_bandwidth" ]]; then
      TUNE_BANDWIDTH="$detected_bandwidth"
      TUNE_BANDWIDTH_SOURCE="auto-iface:${TUNE_DEFAULT_IFACE:-unknown}"
    elif [[ "$TUNE_REGION" == "overseas" ]]; then
      TUNE_BANDWIDTH=1000
      TUNE_BANDWIDTH_SOURCE="fallback"
      log "warning: could not detect NIC speed; using bandwidth=1000 for overseas"
    else
      TUNE_BANDWIDTH=500
      TUNE_BANDWIDTH_SOURCE="fallback"
      log "warning: could not detect NIC speed; using bandwidth=500 for asia"
    fi
  fi
}

resolve_smart_tcp_tune() {
  if [[ "$SMART_TCP_TUNE" == "auto" ]]; then
    case "$TUNE_ROLE" in
      transit|exit)
        SMART_TCP_TUNE="yes"
        ;;
      *)
        SMART_TCP_TUNE="no"
        ;;
    esac
  fi
}

get_tcp_buffer_cap_mb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"

  if ! [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    printf '64\n'
  elif (( mem_kb < 524288 )); then
    printf '16\n'
  elif (( mem_kb < 1048576 )); then
    printf '32\n'
  else
    printf '64\n'
  fi

}

calculate_smart_buffer_mb() {
  local buffer_mb
  local cap_mb="$1"

  if [[ "$TUNE_REGION" == "overseas" ]]; then
    if (( TUNE_BANDWIDTH < 500 )); then
      buffer_mb=16
    elif (( TUNE_BANDWIDTH < 1000 )); then
      buffer_mb=48
    else
      buffer_mb=64
    fi
  else
    if (( TUNE_BANDWIDTH < 500 )); then
      buffer_mb=8
    elif (( TUNE_BANDWIDTH < 1000 )); then
      buffer_mb=12
    elif (( TUNE_BANDWIDTH < 2000 )); then
      buffer_mb=16
    elif (( TUNE_BANDWIDTH < 5000 )); then
      buffer_mb=24
    elif (( TUNE_BANDWIDTH < 10000 )); then
      buffer_mb=28
    else
      buffer_mb=32
    fi
  fi

  if (( buffer_mb > cap_mb )); then
    buffer_mb="$cap_mb"
  fi
  printf '%s\n' "$buffer_mb"
}

resolve_tcp_buffer_plan() {
  if [[ "$SMART_TCP_TUNE" != "yes" || "$ENABLE_BDP_TUNE" == "yes" ]]; then
    return 0
  fi

  SMART_MEMORY_CAP_MB="$(get_tcp_buffer_cap_mb)"
  SMART_BUFFER_MB="$(calculate_smart_buffer_mb "$SMART_MEMORY_CAP_MB")"
  SMART_BUFFER_BYTES=$(( SMART_BUFFER_MB * 1024 * 1024 ))
}

tcp_tune_plan_value() {
  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf 'bdp / %s bytes\n' "$BDP_BUFFER_BYTES"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    printf 'smart / %sMiB / memory-cap %sMiB\n' "$SMART_BUFFER_MB" "$SMART_MEMORY_CAP_MB"
  elif [[ "$TUNE_ROLE" == "web" ]]; then
    printf 'web-conservative / system buffers\n'
  else
    printf 'minimal / system buffers\n'
  fi
}

locale_plan_value() {
  if [[ "$ENABLE_LOCALE_FIX" == "yes" ]]; then
    printf 'yes / %s\n' "$SYSTEM_LOCALE"
  else
    printf 'no\n'
  fi
}

bdp_plan_value() {
  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf 'yes / %sMbps / %sms / %s bytes\n' "$BDP_BANDWIDTH_MBPS" "$BDP_RTT_MS" "$BDP_BUFFER_BYTES"
  else
    printf 'no\n'
  fi
}

ipv4_preference_plan_value() {
  if [[ "$ENABLE_PREFER_IPV4" == "yes" ]]; then
    printf 'yes / /etc/gai.conf\n'
  else
    printf 'no\n'
  fi
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|check|rollback|network-rollback)
        BBRV3_ACTION="$1"
        shift
        ;;
    esac
  fi

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
      --enable-bdp-tune)
        ENABLE_BDP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --no-bdp-tune)
        ENABLE_BDP_TUNE="no"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --bdp-bandwidth)
        [[ $# -ge 2 ]] || die "--bdp-bandwidth requires a value"
        BDP_BANDWIDTH_MBPS="${2:-}"
        ENABLE_BDP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --bdp-rtt)
        [[ $# -ge 2 ]] || die "--bdp-rtt requires a value"
        BDP_RTT_MS="${2:-}"
        ENABLE_BDP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --bdp-extra-mib)
        [[ $# -ge 2 ]] || die "--bdp-extra-mib requires a value"
        BDP_EXTRA_MIB="${2:-}"
        ENABLE_BDP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --enable-locale-fix)
        ENABLE_LOCALE_FIX="yes"
        shift
        ;;
      --no-locale-fix)
        ENABLE_LOCALE_FIX="no"
        shift
        ;;
      --system-locale)
        [[ $# -ge 2 ]] || die "--system-locale requires a value"
        SYSTEM_LOCALE="${2:-}"
        shift 2
        ;;
      --prefer-ipv4)
        ENABLE_PREFER_IPV4="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --no-prefer-ipv4)
        ENABLE_PREFER_IPV4="no"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --enable-bbrv3-kernel)
        ENABLE_BBRV3_KERNEL="yes"
        shift
        ;;
      --no-bbrv3-kernel)
        ENABLE_BBRV3_KERNEL="no"
        shift
        ;;
      --enable-bpftune)
        ENABLE_BPFTUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --no-bpftune)
        ENABLE_BPFTUNE="no"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --bpftune-repo)
        [[ $# -ge 2 ]] || die "--bpftune-repo requires a value"
        BPFTUNE_REPO="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --bpftune-ref)
        [[ $# -ge 2 ]] || die "--bpftune-ref requires a value"
        BPFTUNE_REF="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --bpftune-src)
        [[ $# -ge 2 ]] || die "--bpftune-src requires a value"
        BPFTUNE_SRC_DIR="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --network-only|--tcp-tune-only)
        TCP_TUNE_ONLY="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --role)
        [[ $# -ge 2 ]] || die "--role requires a value"
        TUNE_ROLE="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --enable-smart-tune)
        SMART_TCP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --no-smart-tune)
        SMART_TCP_TUNE="no"
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
      --bbrv3-version)
        [[ $# -ge 2 ]] || die "--bbrv3-version requires a value"
        BBRV3_VERSION="${2:-}"
        shift 2
        ;;
      --bbrv3-repo)
        [[ $# -ge 2 ]] || die "--bbrv3-repo requires a value"
        BBRV3_REPO="${2:-}"
        shift 2
        ;;
      --bbrv3-standard)
        BBRV3_FLAVOR="standard"
        shift
        ;;
      --bbrv3-max)
        BBRV3_FLAVOR="max"
        shift
        ;;
      --lock-bbrv3-version)
        BBRV3_LOCK_VERSION="yes"
        shift
        ;;
      --no-lock-bbrv3-version)
        BBRV3_LOCK_VERSION="no"
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

compute_bdp_buffer_bytes() {
  local bdp_bytes
  local extra_bytes

  bdp_bytes=$(( BDP_BANDWIDTH_MBPS * 1000000 * BDP_RTT_MS / 8000 ))
  extra_bytes=$(( BDP_EXTRA_MIB * 1024 * 1024 ))
  BDP_BUFFER_BYTES=$(( bdp_bytes + extra_bytes ))
}

validate_inputs() {
  if [[ -z "$SSH_PORT" && "$TCP_TUNE_ARGS_SEEN" == "yes" ]]; then
    TCP_TUNE_ONLY="yes"
  fi

  if [[ -n "$BDP_BANDWIDTH_MBPS" || -n "$BDP_RTT_MS" ]]; then
    ENABLE_BDP_TUNE="yes"
  fi

  normalize_region
  normalize_role
  resolve_auto_profile
  resolve_smart_tcp_tune

  [[ "$COPY_ROOT_KEYS" =~ ^(yes|no)$ ]] || die "COPY_ROOT_KEYS must be yes or no"
  [[ "$ENABLE_FAIL2BAN" =~ ^(yes|no)$ ]] || die "ENABLE_FAIL2BAN must be yes or no"
  [[ "$ENABLE_BBR_FQ" =~ ^(yes|no)$ ]] || die "ENABLE_BBR_FQ must be yes or no"
  [[ "$ENABLE_VPS_SYSCTL" =~ ^(yes|no)$ ]] || die "ENABLE_VPS_SYSCTL must be yes or no"
  [[ "$ENABLE_BDP_TUNE" =~ ^(yes|no)$ ]] || die "ENABLE_BDP_TUNE must be yes or no"
  [[ "$SMART_TCP_TUNE" =~ ^(yes|no)$ ]] || die "SMART_TCP_TUNE must be auto, yes, or no"
  [[ "$ENABLE_LOCALE_FIX" =~ ^(yes|no)$ ]] || die "ENABLE_LOCALE_FIX must be yes or no"
  [[ "$ENABLE_PREFER_IPV4" =~ ^(yes|no)$ ]] || die "ENABLE_PREFER_IPV4 must be yes or no"
  [[ "$ENABLE_BBRV3_KERNEL" =~ ^(yes|no)$ ]] || die "ENABLE_BBRV3_KERNEL must be yes or no"
  [[ "$ENABLE_BPFTUNE" =~ ^(yes|no)$ ]] || die "ENABLE_BPFTUNE must be yes or no"
  [[ "$TCP_TUNE_ONLY" =~ ^(yes|no)$ ]] || die "TCP_TUNE_ONLY must be yes or no"
  [[ "$DRY_RUN" =~ ^(yes|no)$ ]] || die "DRY_RUN must be yes or no"
  [[ "$ASSUME_YES" =~ ^(yes|no)$ ]] || die "ASSUME_YES must be yes or no"
  [[ "$SYSTEM_LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "--system-locale contains unsupported characters"
  [[ "$TUNE_REGION" =~ ^(asia|overseas)$ ]] || die "--region must be asia or overseas"
  [[ "$TUNE_ROLE" =~ ^(general|transit|exit|web)$ ]] || die "--role must be general, transit, exit, or web"
  [[ "$TUNE_BANDWIDTH" =~ ^[0-9]+$ ]] || die "--bandwidth must be a number in Mbps"
  (( TUNE_BANDWIDTH >= 1 && TUNE_BANDWIDTH <= 100000 )) || die "--bandwidth must be from 1 to 100000 Mbps"
  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    [[ -n "$BDP_BANDWIDTH_MBPS" ]] || die "--bdp-bandwidth is required when BDP tuning is enabled"
    [[ -n "$BDP_RTT_MS" ]] || die "--bdp-rtt is required when BDP tuning is enabled"
    [[ "$BDP_BANDWIDTH_MBPS" =~ ^[0-9]+$ ]] || die "--bdp-bandwidth must be a number in Mbps"
    [[ "$BDP_RTT_MS" =~ ^[0-9]+$ ]] || die "--bdp-rtt must be a number in milliseconds"
    [[ "$BDP_EXTRA_MIB" =~ ^[0-9]+$ ]] || die "--bdp-extra-mib must be a non-negative integer"
    (( BDP_BANDWIDTH_MBPS >= 1 && BDP_BANDWIDTH_MBPS <= 100000 )) || die "--bdp-bandwidth must be from 1 to 100000 Mbps"
    (( BDP_RTT_MS >= 1 && BDP_RTT_MS <= 10000 )) || die "--bdp-rtt must be from 1 to 10000 ms"
    (( BDP_EXTRA_MIB <= 64 )) || die "--bdp-extra-mib must be from 0 to 64 MiB"
    compute_bdp_buffer_bytes
    (( BDP_BUFFER_BYTES >= 1048576 )) || die "calculated BDP buffer is below 1 MiB; check --bdp-bandwidth and --bdp-rtt"
    (( BDP_BUFFER_BYTES <= 536870912 )) || die "calculated BDP buffer exceeds 512 MiB; check --bdp-bandwidth and --bdp-rtt"
  fi
  resolve_tcp_buffer_plan
  [[ -n "$BPFTUNE_REPO" && "$BPFTUNE_REPO" != *[[:space:]]* ]] || die "--bpftune-repo must be a non-empty URL/path without whitespace"
  [[ "$BPFTUNE_REF" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "--bpftune-ref contains unsupported characters"
  [[ "$BPFTUNE_SRC_DIR" == /* ]] || die "--bpftune-src must be an absolute path"

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
      split("Port PubkeyAuthentication PasswordAuthentication KbdInteractiveAuthentication ChallengeResponseAuthentication PermitRootLogin PermitEmptyPasswords AllowUsers UseDNS AcceptEnv", keys)
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

print_sshd_hardening_config() {
  cat <<SSHD
Port $SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin without-password
PermitEmptyPasswords no
AllowUsers $SSH_USER
UseDNS no
AcceptEnv LANG
SSHD
}

sshd_supports_include() {
  local sshd_bin="$1"
  local tmp_file
  local err_file
  local rc

  tmp_file="$(mktemp)"
  err_file="$(mktemp)"
  printf '%s\n' 'Include /tmp/vps-firstboot-nonexistent-*.conf' >"$tmp_file"

  set +e
  "$sshd_bin" -t -f "$tmp_file" >/dev/null 2>"$err_file"
  rc=$?
  set -e

  if grep -qi 'Bad configuration option: Include' "$err_file"; then
    rm -f "$tmp_file" "$err_file"
    return 1
  fi

  rm -f "$tmp_file" "$err_file"
  return "$rc"
}

remove_managed_sshd_block() {
  local config_file="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  awk '
    /^[[:space:]]*#[[:space:]]*BEGIN managed by vps-firstboot$/ { skip = 1; next }
    /^[[:space:]]*#[[:space:]]*END managed by vps-firstboot$/ { skip = 0; next }
    !skip { print }
  ' "$config_file" >"$tmp_file"
  cat "$tmp_file" >"$config_file"
  rm -f "$tmp_file"
}

remove_sshd_dropin_include() {
  local config_file="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  awk '
    /^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf[[:space:]]*$/ { next }
    { print }
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

prepend_inline_sshd_hardening() {
  local config_file="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  {
    printf '%s\n' '# BEGIN managed by vps-firstboot'
    print_sshd_hardening_config
    printf '%s\n' '# END managed by vps-firstboot'
    cat "$config_file"
  } >"$tmp_file"
  cat "$tmp_file" >"$config_file"
  rm -f "$tmp_file"
}

restart_sshd_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files sshd.service >/dev/null 2>&1 || systemctl list-units --all sshd.service >/dev/null 2>&1; then
      if systemctl restart sshd.service; then
        return 0
      fi
    fi

    if systemctl list-unit-files ssh.service >/dev/null 2>&1 || systemctl list-units --all ssh.service >/dev/null 2>&1; then
      if systemctl restart ssh.service; then
        return 0
      fi
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service sshd restart; then
      return 0
    fi

    if service ssh restart; then
      return 0
    fi
  fi

  if [[ -x /etc/init.d/sshd ]]; then
    if /etc/init.d/sshd restart; then
      return 0
    fi
  fi

  if [[ -x /etc/init.d/ssh ]]; then
    if /etc/init.d/ssh restart; then
      return 0
    fi
  fi

  die "failed to restart SSH service; try manually: systemctl restart sshd.service"
}

configure_sshd() {
  local include_file="/etc/ssh/sshd_config.d/00-login-hardening.conf"
  local legacy_include_file="/etc/ssh/sshd_config.d/99-login-hardening.conf"
  local sshd_bin

  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
  sshd_bin="$(command -v sshd || true)"
  sshd_bin="${sshd_bin:-/usr/sbin/sshd}"

  remove_managed_sshd_block /etc/ssh/sshd_config
  comment_global_sshd_directives /etc/ssh/sshd_config
  if sshd_supports_include "$sshd_bin"; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    rm -f "$legacy_include_file"
    print_sshd_hardening_config >"$include_file"
    ensure_sshd_dropin_include /etc/ssh/sshd_config
  else
    log "warning: this sshd does not support Include; writing SSH hardening inline"
    rm -f "$include_file" "$legacy_include_file"
    remove_sshd_dropin_include /etc/ssh/sshd_config
    prepend_inline_sshd_hardening /etc/ssh/sshd_config
  fi

  "$sshd_bin" -t

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^ssh\.socket'; then
      systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    fi
  fi

  restart_sshd_service
}

print_tcp_tune_sysctl() {
  printf '# Generated by %s\n' "$SCRIPT_NAME"
  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf '# BDP TCP buffer tuning: %s Mbps, %s ms RTT, +%s MiB headroom\n' "$BDP_BANDWIDTH_MBPS" "$BDP_RTT_MS" "$BDP_EXTRA_MIB"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    printf '# Smart TCP tuning: role=%s, region=%s, bandwidth=%sMbps, memory-cap=%sMiB\n' "$TUNE_ROLE" "$TUNE_REGION" "$TUNE_BANDWIDTH" "$SMART_MEMORY_CAP_MB"
  else
    printf '# Conservative TCP profile: role=%s; keep system-managed buffers\n' "$TUNE_ROLE"
  fi

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  fi

  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf 'net.core.rmem_max = %s\n' "$BDP_BUFFER_BYTES"
    printf 'net.core.wmem_max = %s\n' "$BDP_BUFFER_BYTES"
    printf 'net.ipv4.tcp_rmem = 4096 87380 %s\n' "$BDP_BUFFER_BYTES"
    printf 'net.ipv4.tcp_wmem = 4096 16384 %s\n' "$BDP_BUFFER_BYTES"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    printf 'net.core.rmem_max = %s\n' "$SMART_BUFFER_BYTES"
    printf 'net.core.wmem_max = %s\n' "$SMART_BUFFER_BYTES"
    printf 'net.ipv4.tcp_rmem = 4096 87380 %s\n' "$SMART_BUFFER_BYTES"
    printf 'net.ipv4.tcp_wmem = 4096 65536 %s\n' "$SMART_BUFFER_BYTES"
  fi

  case "$TUNE_ROLE" in
    transit|exit)
      printf 'net.ipv4.tcp_limit_output_bytes = 4194304\n'
      printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
      printf 'net.ipv4.tcp_mtu_probing = 1\n'
      ;;
    web)
      printf 'net.core.somaxconn = 8192\n'
      printf 'net.ipv4.tcp_max_syn_backlog = 8192\n'
      printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
      printf 'net.ipv4.tcp_mtu_probing = 1\n'
      ;;
  esac

  if [[ "$TUNE_ROLE" == "exit" ]]; then
    printf 'net.ipv4.ip_local_port_range = 10240 65535\n'
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

disable_legacy_tcp_tune_conf() {
  local file
  local disabled
  local stamp

  stamp="$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'backup')"
  for file in \
    /etc/sysctl.d/99-vps-tcp-tune.conf \
    /etc/sysctl.d/99-joeyblog.conf \
    /etc/sysctl.d/98-vps-baseline.conf \
    /etc/sysctl.d/99-bbr-fq.conf; do
    [[ -e "$file" ]] || continue
    disabled="${file}.disabled"
    if [[ -e "$disabled" ]]; then
      disabled="${file}.disabled.${stamp}"
    fi
    mv "$file" "$disabled"
    log "disabled legacy aggressive TCP tuning: $file -> $disabled"
  done
}

warn_sysctl_network_overrides() {
  local file
  local pattern
  pattern='default_qdisc|tcp_congestion_control|rmem_max|wmem_max|tcp_rmem|tcp_wmem|netdev_max_backlog|somaxconn|tcp_fastopen|tcp_mtu_probing|slow_start_after_idle|tcp_limit_output_bytes|tcp_max_syn_backlog|ip_local_port_range'

  for file in /etc/sysctl.conf /etc/sysctl.d/99-sysctl.conf; do
    [[ -f "$file" ]] || continue
    if grep -Eq "$pattern" "$file"; then
      log "warning: $file still contains TCP/network sysctl values; review manually before deleting anything"
      grep -nE "$pattern" "$file" | sed "s#^#[$SCRIPT_NAME]   #"
    fi
  done
}

network_backup_config() {
  local backup_dir
  local path
  local relative
  local manifest

  if [[ "$NETWORK_BACKUP_DONE" == "yes" ]]; then
    return 0
  fi

  backup_dir="${BBRV3_BACKUP_ROOT}/$(date +%Y%m%d%H%M%S)-$$-network"
  manifest="$backup_dir/manifest.tsv"
  install -d -m 0700 "$backup_dir/files"
  : >"$manifest"

  for path in \
    /etc/sysctl.conf \
    /etc/sysctl.d \
    /etc/gai.conf \
    /etc/default/vps-fq-restore \
    /usr/local/sbin/vps-fq-restore \
    /etc/systemd/system/vps-fq-restore.service \
    /etc/default/vps-tc-shape \
    /usr/local/sbin/vps-tc-shape \
    /etc/systemd/system/vps-tc-shape.service; do
    if [[ -e "$path" || -L "$path" ]]; then
      relative="${path#/}"
      install -d -m 0700 "$backup_dir/files/$(dirname "$relative")"
      cp -a "$path" "$backup_dir/files/$relative"
      printf 'present\t%s\n' "$path" >>"$manifest"
    else
      printf 'absent\t%s\n' "$path" >>"$manifest"
    fi
  done

  if [[ -n "$TC_IFACE" ]] && ip link show dev "$TC_IFACE" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$TC_IFACE" "$(ip -o link show dev "$TC_IFACE" | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}')" >"$backup_dir/tc-mtu.tsv"
  fi

  printf '%s\n' "$backup_dir" >/etc/vps-firstboot-last-network-backup
  NETWORK_BACKUP_DONE="yes"
  NETWORK_BACKUP_DIR="$backup_dir"
  log "backed up network config to $backup_dir"
}

network_backup_path_allowed() {
  case "$1" in
    /etc/sysctl.conf|/etc/sysctl.d|/etc/gai.conf|\
    /etc/default/vps-fq-restore|/usr/local/sbin/vps-fq-restore|/etc/systemd/system/vps-fq-restore.service|\
    /etc/default/vps-tc-shape|/usr/local/sbin/vps-tc-shape|/etc/systemd/system/vps-tc-shape.service)
      return 0
      ;;
  esac
  return 1
}

latest_network_backup() {
  local pointed
  pointed="$(sed -n '1p' /etc/vps-firstboot-last-network-backup 2>/dev/null || true)"
  if [[ "$pointed" == "${BBRV3_BACKUP_ROOT}/"*-network && -f "$pointed/manifest.tsv" ]]; then
    printf '%s\n' "$pointed"
    return 0
  fi
  ls -dt "${BBRV3_BACKUP_ROOT}"/*-network 2>/dev/null | head -n 1 || true
}

network_rollback() {
  local backup_dir
  local status
  local path
  local source
  local iface
  local mtu

  [[ "$(id -u)" -eq 0 ]] || die "run as root for network rollback"
  backup_dir="$(latest_network_backup)"
  [[ -n "$backup_dir" && -f "$backup_dir/manifest.tsv" ]] || die "no network backup was found"

  cat <<PLAN

Network rollback plan:
  backup: $backup_dir
  restore sysctl, IPv4 preference, fq restore, and tc shaping files
  later edits to those managed paths will be replaced by the saved versions
  kernels and SSH configuration will not be changed

PLAN
  confirm "Proceed with network rollback?" || die "aborted"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now vps-tc-shape.service vps-fq-restore.service >/dev/null 2>&1 || true
  fi

  while IFS=$'\t' read -r status path; do
    [[ -n "$status" && -n "$path" ]] || continue
    network_backup_path_allowed "$path" || die "backup contains unsupported path: $path"
    source="$backup_dir/files/${path#/}"
    case "$status" in
      present)
        [[ -e "$source" || -L "$source" ]] || die "backup is incomplete: $source"
        rm -rf "$path"
        install -d -m 0755 "$(dirname "$path")"
        cp -a "$source" "$path"
        ;;
      absent)
        rm -rf "$path"
        ;;
      *)
        die "backup has invalid manifest status: $status"
        ;;
    esac
  done <"$backup_dir/manifest.tsv"

  if [[ -f "$backup_dir/tc-mtu.tsv" ]]; then
    IFS=$'\t' read -r iface mtu <"$backup_dir/tc-mtu.tsv" || true
    if [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [[ "$mtu" =~ ^[0-9]+$ ]] && ip link show dev "$iface" >/dev/null 2>&1; then
      tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
      ip link set dev "$iface" mtu "$mtu" || log "warning: failed to restore MTU $mtu on $iface"
    fi
  fi

  sysctl --system >/dev/null 2>&1 || log "warning: some restored sysctl settings could not be applied immediately"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    [[ -f /etc/systemd/system/vps-fq-restore.service ]] && systemctl enable --now vps-fq-restore.service >/dev/null 2>&1 || true
    [[ -f /etc/systemd/system/vps-tc-shape.service ]] && systemctl enable --now vps-tc-shape.service >/dev/null 2>&1 || true
  fi

  log "restored network config from $backup_dir"
  log "reboot if you need every runtime queue/sysctl state reconstructed from the restored files"
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
  local sysctl_file="/etc/sysctl.d/90-vps-bbr-fq.conf"

  if [[ "$ENABLE_BBR_FQ" != "yes" && "$ENABLE_VPS_SYSCTL" != "yes" && "$ENABLE_BDP_TUNE" != "yes" && "$SMART_TCP_TUNE" != "yes" && "$TUNE_ROLE" == "general" ]]; then
    disable_legacy_tcp_tune_conf
    warn_sysctl_network_overrides
    NETWORK_TUNE_APPLIED="yes"
    return 0
  fi

  if [[ "$ENABLE_BBR_FQ" == "yes" && -x "$(command -v modprobe || true)" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  install -d -m 0755 /etc/sysctl.d
  disable_legacy_tcp_tune_conf
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

  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    apply_sysctl_setting "$sysctl_file" net.core.rmem_max "$BDP_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.core.wmem_max "$BDP_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_rmem "4096 87380 $BDP_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_wmem "4096 16384 $BDP_BUFFER_BYTES"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    apply_sysctl_setting "$sysctl_file" net.core.rmem_max "$SMART_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.core.wmem_max "$SMART_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_rmem "4096 87380 $SMART_BUFFER_BYTES"
    apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_wmem "4096 65536 $SMART_BUFFER_BYTES"
  fi

  case "$TUNE_ROLE" in
    transit|exit)
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_limit_output_bytes 4194304
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_slow_start_after_idle 0
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_mtu_probing 1
      ;;
    web)
      apply_sysctl_setting "$sysctl_file" net.core.somaxconn 8192
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_max_syn_backlog 8192
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_slow_start_after_idle 0
      apply_sysctl_setting "$sysctl_file" net.ipv4.tcp_mtu_probing 1
      ;;
  esac

  if [[ "$TUNE_ROLE" == "exit" ]]; then
    apply_sysctl_setting "$sysctl_file" net.ipv4.ip_local_port_range "10240 65535"
  fi

  if [[ "$ENABLE_VPS_SYSCTL" == "yes" ]]; then
    log "notice: --enable-vps-sysctl is deprecated; aggressive TCP buffer/backlog tuning is no longer written"
  fi

  if [[ ! -s "$sysctl_file" ]]; then
    rm -f "$sysctl_file"
  fi

  warn_sysctl_network_overrides
  install_fq_restore_service
  NETWORK_TUNE_APPLIED="yes"
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

configure_locale() {
  local locale_file="/etc/default/locale"

  if [[ "$ENABLE_LOCALE_FIX" != "yes" ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v locale-gen >/dev/null 2>&1; then
      apt-get update
      apt-get install -y locales
    fi

    if [[ -f /etc/locale.gen ]] && ! grep -Eq "^[[:space:]]*$SYSTEM_LOCALE[[:space:]]+UTF-8" /etc/locale.gen; then
      printf '%s UTF-8\n' "$SYSTEM_LOCALE" >>/etc/locale.gen
    fi

    locale-gen >/dev/null 2>&1 || log "warning: failed to generate locale $SYSTEM_LOCALE"

    if command -v update-locale >/dev/null 2>&1; then
      update-locale LANG="$SYSTEM_LOCALE" LC_CTYPE="$SYSTEM_LOCALE" || log "warning: failed to update system locale"
    else
      install -d -m 0755 /etc/default
      printf 'LANG=%s\nLC_CTYPE=%s\n' "$SYSTEM_LOCALE" "$SYSTEM_LOCALE" >"$locale_file"
    fi
  elif command -v localectl >/dev/null 2>&1; then
    localectl set-locale LANG="$SYSTEM_LOCALE" LC_CTYPE="$SYSTEM_LOCALE" || log "warning: failed to set locale with localectl"
  else
    log "warning: locale configuration skipped because no supported locale tool was found"
  fi

  if [[ -d /var/lib/cloud/instance ]]; then
    touch /var/lib/cloud/instance/locale-check.skip 2>/dev/null || true
  fi
}

print_ipv4_preference_gai_conf() {
  cat <<'GAI_CONF'
# BEGIN managed by vps-firstboot: prefer-ipv4
# Keep a complete precedence table; any active precedence line overrides glibc defaults.
precedence ::1/128 50
precedence ::/0 40
precedence 2002::/16 30
precedence ::/96 20
precedence ::ffff:0:0/96 100
# END managed by vps-firstboot: prefer-ipv4
GAI_CONF
}

strip_managed_ipv4_preference_block() {
  local file="$1"
  local output_file="$2"
  local begin="# BEGIN managed by vps-firstboot: prefer-ipv4"
  local end="# END managed by vps-firstboot: prefer-ipv4"

  if [[ -f "$file" ]]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$file" >"$output_file"
  else
    : >"$output_file"
  fi
}

configure_ipv4_preference() {
  local file="/etc/gai.conf"
  local tmp_file

  tmp_file="$(mktemp)"
  strip_managed_ipv4_preference_block "$file" "$tmp_file"

  if [[ "$ENABLE_PREFER_IPV4" == "yes" ]]; then
    {
      cat "$tmp_file"
      if [[ -s "$tmp_file" ]]; then
        printf '\n'
      fi
      print_ipv4_preference_gai_conf
    } >"$file"
    log "configured IPv4 preference for dual-stack hostnames in $file"
  elif [[ -f "$file" ]] && grep -Fq '# BEGIN managed by vps-firstboot: prefer-ipv4' "$file"; then
    cat "$tmp_file" >"$file"
    log "removed vps-firstboot IPv4 preference block from $file"
  fi

  rm -f "$tmp_file"
}

bbrv3_arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' x86_64
      ;;
    aarch64|arm64)
      printf '%s\n' arm64
      ;;
    *)
      return 1
      ;;
  esac
}

bbrv3_os_supported() {
  local id=""
  local version_id=""
  local major=""

  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  id="${ID:-}"
  version_id="${VERSION_ID:-}"
  major="${version_id%%.*}"

  case "$id:$major" in
    debian:12|debian:13|ubuntu:24|ubuntu:25|ubuntu:26)
      return 0
      ;;
  esac

  case "${VERSION_CODENAME:-}" in
    bookworm|trixie|forky|sid|noble|oracular|plucky|questing)
      return 0
      ;;
  esac

  return 1
}

bbrv3_ensure_deps() {
  command -v apt-get >/dev/null 2>&1 || die "BBRv3 kernel install requires Debian/Ubuntu with apt-get"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq dpkg coreutils sed grep
}

bbrv3_gh_api() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
      -H "Accept: application/vnd.github+json" \
      "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

bbrv3_locked_tag() {
  local tag=""
  if [[ -r "$BBRV3_LOCK_FILE" ]]; then
    tag="$(sed -n '1p' "$BBRV3_LOCK_FILE")"
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
    return 0
  fi
  return 1
}

bbrv3_select_tag() {
  local arch="$1"
  local releases_json
  local tag_pattern
  local locked

  if [[ -n "$BBRV3_VERSION" && "$BBRV3_VERSION" != "latest" ]]; then
    printf '%s\n' "$BBRV3_VERSION"
    return 0
  fi

  if [[ -z "$BBRV3_VERSION" ]]; then
    locked="$(bbrv3_locked_tag || true)"
    if [[ -n "$locked" ]]; then
      printf '%s\n' "$locked"
      return 0
    fi
  fi

  releases_json="$(bbrv3_gh_api "https://api.github.com/repos/${BBRV3_REPO}/releases?per_page=50")"
  if [[ "$BBRV3_FLAVOR" == "max" ]]; then
    tag_pattern="^${arch}-[0-9].*-max$"
  else
    tag_pattern="^${arch}-[0-9].*[^x]$"
  fi

  printf '%s\n' "$releases_json" |
    jq -r --arg pattern "$tag_pattern" '[.[] | select(.tag_name | test($pattern))][0].tag_name // empty'
}

bbrv3_release_json() {
  local tag="$1"
  bbrv3_gh_api "https://api.github.com/repos/${BBRV3_REPO}/releases/tags/${tag}"
}

bbrv3_download_assets() {
  local release_json="$1"
  local dest_dir="$2"
  local urls
  local url
  local name

  install -d -m 0755 "$dest_dir"
  urls="$(printf '%s\n' "$release_json" | jq -r '.assets[].browser_download_url | select(test("\\.deb$")) | select(test("linux-(image|headers)")) | select(test("dbg|debug") | not)')"
  [[ -n "$urls" ]] || die "no linux image/header .deb assets found in BBRv3 release $BBRV3_SELECTED_TAG"

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    name="$(basename "$url")"
    log "downloading $name"
    curl -fL "$url" -o "$dest_dir/$name"
  done <<EOF
$urls
EOF
}

bbrv3_backup_sysctl() {
  local backup_dir
  if [[ "$BBRV3_BACKUP_DONE" == "yes" ]]; then
    return 0
  fi
  backup_dir="${BBRV3_BACKUP_ROOT}/$(date +%Y%m%d%H%M%S)-$$-bbrv3"
  install -d -m 0700 "$backup_dir"
  cp -a /etc/sysctl.conf "$backup_dir"/ 2>/dev/null || true
  cp -a /etc/sysctl.d "$backup_dir"/sysctl.d 2>/dev/null || true
  printf '%s\n' "$backup_dir" >/etc/vps-firstboot-last-sysctl-backup 2>/dev/null || true
  BBRV3_BACKUP_DONE="yes"
  log "backed up sysctl config to $backup_dir"
}

bbrv3_disable_aggressive_sysctl_files() {
  disable_legacy_tcp_tune_conf
}

bbrv3_apply_fq_sysctl() {
  if [[ "$NETWORK_TUNE_APPLIED" == "yes" ]]; then
    log "keeping the TCP role/profile already applied during setup"
    return 0
  fi
  ENABLE_BBR_FQ="yes"
  ENABLE_BDP_TUNE="no"
  SMART_TCP_TUNE="no"
  TUNE_ROLE="general"
  ENABLE_VPS_SYSCTL="no"
  configure_tcp_tune
}

bbrv3_install() {
  local arch
  local release_json
  local work_dir
  local current_kernel

  [[ "$(id -u)" -eq 0 ]] || die "run as root for BBRv3 install"
  bbrv3_os_supported || die "BBRv3 install supports Debian 12/13 or Ubuntu 24.04+ only"
  arch="$(bbrv3_arch_tag)" || die "BBRv3 install supports x86_64 and aarch64 only"
  [[ "$BBRV3_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--bbrv3-repo must be OWNER/REPO"
  [[ "$BBRV3_FLAVOR" =~ ^(standard|max)$ ]] || die "BBRV3_FLAVOR must be standard or max"

  bbrv3_ensure_deps
  install -d -m 0755 "$(dirname "$BBRV3_LOCK_FILE")" "$BBRV3_INSTALL_DIR"

  BBRV3_SELECTED_TAG="$(bbrv3_select_tag "$arch")"
  [[ -n "$BBRV3_SELECTED_TAG" ]] || die "could not select a BBRv3 release tag"
  if [[ "$BBRV3_FLAVOR" == "standard" && "$BBRV3_SELECTED_TAG" == *-max ]]; then
    die "selected tag is a max kernel but standard flavor was requested: $BBRV3_SELECTED_TAG"
  fi

  current_kernel="$(uname -r)"
  work_dir="${BBRV3_INSTALL_DIR}/${BBRV3_SELECTED_TAG}"
  release_json="$(bbrv3_release_json "$BBRV3_SELECTED_TAG")"

  cat <<PLAN

BBRv3 install plan:
  repo:           $BBRV3_REPO
  tag:            $BBRV3_SELECTED_TAG
  flavor:         $BBRV3_FLAVOR
  arch:           $arch
  current kernel: $current_kernel
  reboot:         no automatic reboot
  rollback:       old kernel packages are kept as boot fallback

PLAN
  confirm "Proceed with BBRv3 kernel install?" || die "aborted"

  bbrv3_backup_sysctl
  bbrv3_disable_aggressive_sysctl_files
  bbrv3_download_assets "$release_json" "$work_dir"

  log "installing BBRv3 kernel packages"
  dpkg -i "$work_dir"/*.deb || apt-get -f install -y
  update-initramfs -u -k all >/dev/null 2>&1 || true
  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || log "warning: update-grub failed"
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || log "warning: grub-mkconfig failed"
  fi

  bbrv3_apply_fq_sysctl

  if [[ "$BBRV3_LOCK_VERSION" == "yes" ]]; then
    printf '%s\n' "$BBRV3_SELECTED_TAG" >"$BBRV3_LOCK_FILE"
    log "locked BBRv3 release tag: $BBRV3_LOCK_FILE -> $BBRV3_SELECTED_TAG"
  fi

  BBRV3_NEEDS_REBOOT="yes"
  bbrv3_check
  cat <<DONE

BBRv3 kernel packages installed.
No reboot was performed. Reboot during your maintenance window:
  reboot

After reboot, verify:
  bash /root/vps-firstboot.sh check

DONE
}

bbrv3_module_version() {
  modinfo tcp_bbr 2>/dev/null | awk -F': *' '/^version:/ {print $2; exit}'
}

bbrv3_installed_packages() {
  { dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null || true; } |
    awk '/bbr|joey|7\./ {print}'
}

bbrv3_check() {
  printf '\nBBRv3 status:\n'
  printf 'os: %s\n' "$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; found=1} END{if(!found) print "unknown"}' /etc/os-release 2>/dev/null || echo unknown)"
  printf 'kernel: %s\n' "$(uname -r)"
  printf 'tcp_bbr_version: %s\n' "$(bbrv3_module_version || echo unknown)"
  printf 'tcp_available_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf 'default_qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf 'bbrv3_lock: %s\n' "$(bbrv3_locked_tag || echo none)"
  printf 'reboot_required: %s\n' "$([[ -e /var/run/reboot-required ]] && echo yes || echo "${BBRV3_NEEDS_REBOOT:-unknown}")"
  printf 'legacy_99_vps_tcp_tune: %s\n' "$([[ -e /etc/sysctl.d/99-vps-tcp-tune.conf ]] && echo present || echo absent)"
  printf 'legacy_99_joeyblog: %s\n' "$([[ -e /etc/sysctl.d/99-joeyblog.conf ]] && echo present || echo absent)"
  printf 'installed_bbrv3_kernel_packages:\n'
  bbrv3_installed_packages | sed 's/^/  /' || true
}

bbrv3_restore_latest_sysctl_backup() {
  local latest
  latest="$(ls -dt "${BBRV3_BACKUP_ROOT}"/*-bbrv3 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" ]] || return 0

  if [[ -f "$latest/sysctl.conf" ]]; then
    cp -a "$latest/sysctl.conf" /etc/sysctl.conf
  fi
  if [[ -d "$latest/sysctl.d" ]]; then
    rm -rf /etc/sysctl.d
    cp -a "$latest/sysctl.d" /etc/sysctl.d
  fi
  sysctl --system >/dev/null 2>&1 || true
  log "restored latest sysctl backup from $latest"
}

bbrv3_rollback() {
  local running
  local pkg

  [[ "$(id -u)" -eq 0 ]] || die "run as root for BBRv3 rollback"
  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query is required for rollback"

  cat <<PLAN

BBRv3 rollback plan:
  restore latest sysctl backup if available
  remove vps-firstboot BBR/fq sysctl file
  remove non-running BBRv3-looking linux image/header packages
  never remove the currently running kernel

PLAN
  confirm "Proceed with BBRv3 rollback?" || die "aborted"

  bbrv3_restore_latest_sysctl_backup
  rm -f /etc/sysctl.d/90-vps-bbr-fq.conf

  running="$(uname -r)"
  while read -r pkg _version; do
    [[ -n "$pkg" ]] || continue
    if [[ "$pkg" == *"$running"* ]]; then
      log "keeping currently running kernel package: $pkg"
      continue
    fi
    log "removing package: $pkg"
    apt-get remove -y "$pkg" || true
  done <<EOF
$(bbrv3_installed_packages)
EOF

  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  fi
  bbrv3_check
}

run_bbrv3_action() {
  case "$BBRV3_ACTION" in
    install)
      bbrv3_install
      ;;
    check)
      bbrv3_check
      ;;
    rollback)
      bbrv3_rollback
      ;;
    network-rollback)
      network_rollback
      ;;
  esac
}

install_bpftune_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git make gcc pkg-config clang llvm bpftool libbpf-dev libcap-dev libnl-3-dev libnl-route-3-dev python3-docutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git make gcc pkgconf-pkg-config clang llvm bpftool libbpf-devel libcap-devel libnl3-devel python3-docutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git make gcc pkgconfig clang llvm bpftool libbpf-devel libcap-devel libnl3-devel python3-docutils
  else
    die "cannot install bpftune build dependencies automatically on this system; unsupported package manager"
  fi
}

bpftune_libdir() {
  if [[ -f /etc/debian_version ]]; then
    printf '%s\n' lib
  else
    printf '%s\n' lib64
  fi
}

install_bpftune() {
  local jobs
  local libdir
  local src_parent

  if [[ "$ENABLE_BPFTUNE" != "yes" ]]; then
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 || die "bpftune service management requires systemd/systemctl"
  [[ -e /sys/kernel/btf/vmlinux || -e "/boot/vmlinux-$(uname -r)" ]] || die "bpftune requires kernel BTF; /sys/kernel/btf/vmlinux is missing"

  install_bpftune_build_deps

  src_parent="$(dirname "$BPFTUNE_SRC_DIR")"
  install -d -m 0755 "$src_parent"

  if [[ -d "$BPFTUNE_SRC_DIR/.git" ]]; then
    git -C "$BPFTUNE_SRC_DIR" fetch --depth 1 origin "$BPFTUNE_REF"
  elif [[ -e "$BPFTUNE_SRC_DIR" ]]; then
    die "bpftune source path exists but is not a git checkout: $BPFTUNE_SRC_DIR"
  else
    git clone --depth 1 "$BPFTUNE_REPO" "$BPFTUNE_SRC_DIR"
    git -C "$BPFTUNE_SRC_DIR" fetch --depth 1 origin "$BPFTUNE_REF"
  fi

  git -C "$BPFTUNE_SRC_DIR" checkout --detach FETCH_HEAD

  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
  [[ "$jobs" =~ ^[0-9]+$ ]] || jobs=2
  libdir="$(bpftune_libdir)"

  make -C "$BPFTUNE_SRC_DIR" -j "$jobs" libdir="$libdir" srcdir docdir
  make -C "$BPFTUNE_SRC_DIR" libdir="$libdir" install

  bpftune -S
  systemctl daemon-reload || log "warning: failed to reload systemd after installing bpftune"
  systemctl enable --now bpftune.service
}

print_tcp_tune_dry_run() {
  cat <<DRYRUN

Dry run: TCP tuning preview only. No files will be written and no sysctl/tc changes will be applied.

Profile:
  role:             $TUNE_ROLE
  region:           $TUNE_REGION
  region source:    $TUNE_REGION_SOURCE
  bandwidth:        ${TUNE_BANDWIDTH}Mbps
  bandwidth source: $TUNE_BANDWIDTH_SOURCE
  bbr + fq:         $ENABLE_BBR_FQ
  tcp sysctl:       $(tcp_tune_plan_value)
  smart tune:       $SMART_TCP_TUNE
  bdp tune:         $(bdp_plan_value)
  locale fix:       $(locale_plan_value)
  ipv4 preference:  $(ipv4_preference_plan_value)
  bbrv3 kernel:     $ENABLE_BBRV3_KERNEL / $BBRV3_FLAVOR / ${BBRV3_VERSION:-locked-or-latest}
  bpftune:          $ENABLE_BPFTUNE
  tc shaping:       ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}

Would disable legacy /etc/sysctl.d/99-vps-tcp-tune.conf if present.
Would create a timestamped network backup before applying changes.
Would write /etc/sysctl.d/90-vps-bbr-fq.conf:
DRYRUN
  print_tcp_tune_sysctl

  if [[ "$ENABLE_PREFER_IPV4" == "yes" ]]; then
    printf '\nWould update /etc/gai.conf:\n'
    print_ipv4_preference_gai_conf
  fi

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    printf '\nWould write fq restore files:\n'
    print_fq_restore_files
  fi

  if [[ "$ENABLE_BBRV3_KERNEL" == "yes" ]]; then
    cat <<BBRV3_PREVIEW

Would install standard BBRv3 kernel packages from GitHub Releases:
  repo: $BBRV3_REPO
  version: ${BBRV3_VERSION:-locked tag if present, otherwise latest standard release}
  lock version: $BBRV3_LOCK_VERSION
  automatic reboot: no
BBRV3_PREVIEW
  fi

  if [[ -n "$TC_IFACE" && -n "$TC_RATE" ]]; then
    cat <<TC_PREVIEW

Would write tc shaping files:
  /etc/default/vps-tc-shape
  /usr/local/sbin/vps-tc-shape
  /etc/systemd/system/vps-tc-shape.service
TC_PREVIEW
  fi

  if [[ "$ENABLE_BPFTUNE" == "yes" ]]; then
    cat <<BPFTUNE_PREVIEW

Would build/install bpftune:
  repo: $BPFTUNE_REPO
  ref:  $BPFTUNE_REF
  src:  $BPFTUNE_SRC_DIR
  service: bpftune.service
BPFTUNE_PREVIEW
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
  tcp role:         $TUNE_ROLE
  tcp sysctl:       $(tcp_tune_plan_value)
  smart tune:       $SMART_TCP_TUNE
  bdp tune:         $(bdp_plan_value)
  locale fix:       $(locale_plan_value)
  ipv4 preference:  $(ipv4_preference_plan_value)
  bbrv3 kernel:     $ENABLE_BBRV3_KERNEL / $BBRV3_FLAVOR / ${BBRV3_VERSION:-locked-or-latest}
  bpftune:          $ENABLE_BPFTUNE
  tcp profile:      $TUNE_REGION / ${TUNE_BANDWIDTH}Mbps
  profile source:   $TUNE_REGION_SOURCE / $TUNE_BANDWIDTH_SOURCE
  fail2ban:        $ENABLE_FAIL2BAN
  tc shaping:       ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}

This will disable SSH password login. Root login remains key-only if the user is root.

PLAN
  else
    cat <<PLAN

Plan:
  ssh hardening:    no
  bbr + fq:         $ENABLE_BBR_FQ
  tcp role:         $TUNE_ROLE
  tcp sysctl:       $(tcp_tune_plan_value)
  smart tune:       $SMART_TCP_TUNE
  bdp tune:         $(bdp_plan_value)
  locale fix:       $(locale_plan_value)
  ipv4 preference:  $(ipv4_preference_plan_value)
  bbrv3 kernel:     $ENABLE_BBRV3_KERNEL / $BBRV3_FLAVOR / ${BBRV3_VERSION:-locked-or-latest}
  bpftune:          $ENABLE_BPFTUNE
  tcp profile:      $TUNE_REGION / ${TUNE_BANDWIDTH}Mbps
  profile source:   $TUNE_REGION_SOURCE / $TUNE_BANDWIDTH_SOURCE
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
    printf 'usedns: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^usedns / {print $2; exit}')"
    printf 'acceptenv: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^acceptenv / {$1=""; sub(/^ /, ""); print; exit}')"
  fi
  printf 'system_locale: %s\n' "$(awk -F= '/^LANG=/ {gsub(/"/, "", $2); print $2; found=1} END{if(!found) print "unknown"}' /etc/default/locale 2>/dev/null || echo unknown)"
  printf 'locale_check_skip: %s\n' "$([[ -e /var/lib/cloud/instance/locale-check.skip ]] && echo yes || echo no)"
  printf 'tcp_profile: %s/%sMbps\n' "$TUNE_REGION" "$TUNE_BANDWIDTH"
  printf 'tcp_role: %s\n' "$TUNE_ROLE"
  printf 'tcp_tune_mode: %s\n' "$(tcp_tune_plan_value)"
  printf 'tcp_profile_source: %s/%s\n' "$TUNE_REGION_SOURCE" "$TUNE_BANDWIDTH_SOURCE"
  printf 'tcp_profile_country: %s\n' "${TUNE_COUNTRY_CODE:-unknown}"
  printf 'tcp_profile_iface: %s\n' "${TUNE_DEFAULT_IFACE:-unknown}"
  printf 'bdp_tune: %s\n' "$(bdp_plan_value)"
  printf 'ipv4_preference: %s\n' "$(grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf 2>/dev/null && echo yes || echo no)"
  printf 'bbr_available: %s\n' "$bbr_available"
  printf 'default_qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf 'rmem_max: %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  printf 'wmem_max: %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  printf 'tcp_rmem: %s\n' "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo unknown)"
  printf 'tcp_wmem: %s\n' "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo unknown)"
  printf 'tcp_limit_output_bytes: %s\n' "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo unknown)"
  printf 'tcp_slow_start_after_idle: %s\n' "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo unknown)"
  printf 'tcp_mtu_probing: %s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
  printf 'somaxconn: %s\n' "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
  printf 'tcp_max_syn_backlog: %s\n' "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo unknown)"
  printf 'network_backup: %s\n' "${NETWORK_BACKUP_DIR:-none-this-run}"
  printf 'legacy_tcp_tune_conf: %s\n' "$([[ -e /etc/sysctl.d/99-vps-tcp-tune.conf ]] && echo present || echo disabled)"
  printf 'fq_restore_service: %s\n' "$(systemctl is-enabled vps-fq-restore.service 2>/dev/null || echo unavailable)"

  if [[ "$ENABLE_BPFTUNE" == "yes" || -x "$(command -v bpftune || true)" ]]; then
    printf 'bpftune_binary: %s\n' "$(command -v bpftune 2>/dev/null || echo not-installed)"
    if command -v systemctl >/dev/null 2>&1; then
      printf 'bpftune_service: %s/%s\n' "$(systemctl is-enabled bpftune.service 2>/dev/null || echo unavailable)" "$(systemctl is-active bpftune.service 2>/dev/null || echo inactive)"
    else
      printf 'bpftune_service: %s\n' "unavailable"
    fi
  fi

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

  if [[ -n "$NETWORK_BACKUP_DIR" ]]; then
    cat <<ROLLBACK_DONE

Network rollback point:
  $NETWORK_BACKUP_DIR

To restore it without changing the kernel or SSH configuration:
  bash /root/vps-firstboot.sh network-rollback -y
ROLLBACK_DONE
  fi

  if [[ "$BBRV3_NEEDS_REBOOT" == "yes" ]]; then
    cat <<BBRV3_DONE

BBRv3 kernel packages are installed, but this script did not reboot automatically.
Reboot during your maintenance window:
  reboot

After reboot, verify:
  bash /root/vps-firstboot.sh check
BBRV3_DONE
  fi

  if [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    cat <<BDP_DONE

BDP tuning is applied. From your bottleneck client network, verify with:
  # on the VPS, during testing only:
  iperf3 -s

  # from your client network:
  iperf3 -c SERVER_IP -R -t 30

If retransmits are high, rerun with a smaller --bdp-extra-mib or lower --bdp-bandwidth.
If retransmits are 0 or very low, you can test a slightly larger --bdp-extra-mib.
BDP_DONE
  fi
}

main() {
  parse_args "$@"

  if [[ "$BBRV3_ACTION" != "setup" ]]; then
    run_bbrv3_action
    exit 0
  fi

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

  network_backup_config
  if [[ "$ENABLE_BBRV3_KERNEL" == "yes" ]]; then
    bbrv3_backup_sysctl
  fi

  configure_locale
  configure_ipv4_preference
  configure_tcp_tune
  configure_tc_shaping
  install_bpftune
  install_fail2ban
  if [[ "$ENABLE_BBRV3_KERNEL" == "yes" ]]; then
    bbrv3_install
  fi
  show_verification_status
  final_message
}

main "$@"
