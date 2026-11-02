#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
# ---------------------------------------------------------------------------
# 可配置项
# 每一项都能用同名环境变量设置，大多数也有对应的命令行参数（见 --help）。
# 命令行参数优先于环境变量。写着 yes/no 的项只接受这两个值。
# ---------------------------------------------------------------------------

# 运行哪一部分：all=安全初始化+网络调优，security=只做安全初始化，network=只调网络。
RUN_PART="${RUN_PART:-all}"

# ----- SSH 登录 -----
# 安装公钥的用户，必须已经存在，脚本不会新建用户。
SSH_USER="${SSH_USER:-${NEW_USER:-root}}"
# 新 SSH 端口，1024-65535。运行 all 或 security 时必填，旧端口会立即关闭。
SSH_PORT="${SSH_PORT:-}"
# 公钥的三种传法只能选一种：公钥正文、服务器上的公钥文件、从标准输入读一行（yes/no）。
PUBLIC_KEY="${PUBLIC_KEY:-}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-}"
PUBLIC_KEY_STDIN="${PUBLIC_KEY_STDIN:-no}"
# 没提供公钥时，是否把 root 的 authorized_keys 复制给 SSH_USER。yes/no。
COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-yes}"
# 是否安装 fail2ban 保护 SSH 端口。yes/no。
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"

# ----- 系统 -----
# 是否升级系统并开启自动安全更新，只支持 apt 系统。yes/no。
ENABLE_SYSTEM_UPDATE="${ENABLE_SYSTEM_UPDATE:-yes}"
# 是否配置系统 locale，以及使用哪个 locale。yes/no；locale 名如 en_US.UTF-8。
ENABLE_LOCALE_FIX="${ENABLE_LOCALE_FIX:-yes}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-en_US.UTF-8}"
# 域名同时有 IPv4 和 IPv6 地址时，是否优先用 IPv4。不会禁用 IPv6。yes/no。
ENABLE_PREFER_IPV4="${ENABLE_PREFER_IPV4:-yes}"

# ----- BBR 和 TCP 调优 -----
# 是否启用发行版内核自带的 BBR + fq。yes/no。
ENABLE_BBR_FQ="${ENABLE_BBR_FQ:-yes}"
# 机器用途：
#   general  只开 BBR + fq，保留系统缓冲区
#   web      建站，加大监听队列并开启 MTU 探测
#   transit  线路鸡/中转，智能缓冲区、MTU 探测、关闭空闲后的慢启动
#   exit     落地机，在 transit 基础上扩大临时端口范围并预留 SSH 端口
TUNE_ROLE="${TUNE_ROLE:-${ROLE:-general}}"
# 调优目标：
#   auto           默认；用了 --target-mbps 或 --rtt-ms 就是 single-stream，否则是 balanced
#   latency        低延迟优先，不放大缓冲区
#   balanced       日常通用，缓冲区由 role 决定
#   single-stream  单线程速度优先，缓冲区 = 带宽 x 延迟 x 2
#   throughput     吞吐优先，缓冲区 = 带宽 x 延迟 x 3，占用内存更多
#   custom         用 MANUAL_BUFFER_MIB 手动指定缓冲区
TUNE_OBJECTIVE="${TUNE_OBJECTIVE:-${OBJECTIVE:-auto}}"
# 是否按带宽和延迟计算缓冲区（BDP）。yes/no；设了带宽或延迟会自动打开。
ENABLE_BDP_TUNE="${ENABLE_BDP_TUNE:-no}"
# 想达到的单线程速度，1-100000 Mbps。填真实瓶颈，不是网卡标称的 10G。
BDP_BANDWIDTH_MBPS="${BDP_BANDWIDTH_MBPS:-}"
# 客户端到这台 VPS 的延迟，1-10000 ms。
BDP_RTT_MS="${BDP_RTT_MS:-}"
# 缓冲区倍数，1-4。single-stream 默认 2，throughput 默认 3。
BDP_FACTOR="${BDP_FACTOR:-2}"
# 在计算结果上额外增加的缓冲区，0-64 MiB。
BDP_EXTRA_MIB="${BDP_EXTRA_MIB:-0}"
# 手动指定 TCP 最大缓冲区，1-512 MiB，优先级最高。
MANUAL_BUFFER_MIB="${MANUAL_BUFFER_MIB:-}"
# 是否允许缓冲区超过按内存算出的安全上限。yes/no。
ALLOW_UNSAFE_BUFFER="${ALLOW_UNSAFE_BUFFER:-no}"
# 是否按地区、带宽和内存自动选缓冲区。auto/yes/no；auto 时 transit 和 exit 才开启。
SMART_TCP_TUNE="${SMART_TCP_TUNE:-auto}"
# 智能缓冲区用的套餐带宽：auto 或 1-100000 Mbps。auto 读网卡速度，虚拟网卡常常不准。
TUNE_BANDWIDTH="${TUNE_BANDWIDTH:-${BANDWIDTH:-auto}}"
# 智能缓冲区用的地区：auto、asia 或 overseas。auto 会访问公网服务查询国家。
TUNE_REGION="${TUNE_REGION:-${REGION:-auto}}"

# ----- 可选：tc 限速整形 -----
# 网卡名和出口速率要一起设置，速率如 97mbit；不设就不启用。
TC_IFACE="${TC_IFACE:-}"
TC_RATE="${TC_RATE:-}"
# 可选的 MTU，576-9000；整形的突发大小，如 256k。
TC_MTU="${TC_MTU:-}"
TC_BURST="${TC_BURST:-256k}"

# ----- 可选：bpftune 自动调优 -----
# 是否编译并启用 bpftune。yes/no。需要 systemd 和内核 BTF，小内存机器不建议开。
ENABLE_BPFTUNE="${ENABLE_BPFTUNE:-no}"
# bpftune 的仓库地址、分支或标签、源码目录。
BPFTUNE_REPO="${BPFTUNE_REPO:-https://github.com/byethan/bpftune.git}"
BPFTUNE_REF="${BPFTUNE_REF:-main}"
BPFTUNE_SRC_DIR="${BPFTUNE_SRC_DIR:-/usr/local/src/bpftune}"

# ----- 运行方式 -----
# 只预览不修改。yes/no。
DRY_RUN="${DRY_RUN:-no}"
# 不询问确认。yes/no。
ASSUME_YES="${ASSUME_YES:-no}"
# 输出里显示国家码、网卡名等诊断信息。yes/no。
SHOW_SENSITIVE="${SHOW_SENSITIVE:-no}"
# 网络配置备份目录，必须是绝对路径。
BACKUP_ROOT="${BACKUP_ROOT:-/root/vps-firstboot-backups}"

# ---------------------------------------------------------------------------
# 脚本内部状态，不用修改
# ---------------------------------------------------------------------------
ACTION="setup"
BDP_FACTOR_EXPLICIT="no"
BDP_BUFFER_BYTES=""
MANUAL_BUFFER_BYTES=""
TCP_TUNE_ARGS_SEEN="no"
TUNE_BANDWIDTH_SOURCE="configured"
TUNE_REGION_SOURCE="configured"
TUNE_COUNTRY_CODE=""
TUNE_DEFAULT_IFACE=""
SMART_BUFFER_MB=""
SMART_BUFFER_BYTES=""
SMART_MEMORY_CAP_MB=""
TCP_RMEM_MIN=4096
TCP_RMEM_DEFAULT=131072
TCP_WMEM_MIN=4096
TCP_WMEM_DEFAULT=16384
SYSTEM_UPDATE_RESULT="not-run"
SELF_PATH="/usr/local/sbin/vps-firstboot"
SSHD_INCLUDE_FILE="/etc/ssh/sshd_config.d/00-login-hardening.conf"
SSHD_LEGACY_INCLUDE_FILE="/etc/ssh/sshd_config.d/99-login-hardening.conf"
NETWORK_BACKUP_DONE="no"
NETWORK_BACKUP_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-firstboot.sh security --port <ssh-port> --key-file /root/admin-key.pub
  sudo bash vps-firstboot.sh network --role transit --objective single-stream --target-mbps 625 --rtt-ms 80
  sudo bash vps-firstboot.sh all --port <ssh-port> --key-file /root/admin-key.pub
  sudo bash vps-firstboot.sh --port <ssh-port> --key-file /root/admin-key.pub
  sudo bash vps-firstboot.sh --bandwidth auto --region auto
  sudo bash vps-firstboot.sh check
  sudo bash vps-firstboot.sh network-rollback -y

Options:
  security              Part 1: SSH hardening, keys, locale, and optional fail2ban only
  network               Part 2: BBR, TCP buffers, qdisc, shaping, and network checks only
  all                   Run both parts. Default; preserves the legacy one-command behavior
  --user NAME           Existing SSH user to install the key for. Default: root
  --port PORT           SSH port to use. Required for SSH hardening
  --public-key KEY      SSH public key text to install for the user
  --key-file PATH       File containing one SSH public key on the server
  --public-key-stdin     Read one SSH public key from standard input; avoids argv/history exposure
  --show-sensitive      Show full diagnostic identifiers. Default logs are privacy-safe
  --no-copy-root-keys   Do not copy /root/.ssh/authorized_keys as fallback
  --enable-fail2ban     Install and configure fail2ban for the SSH port
  --no-fail2ban         Do not install and configure fail2ban
  --no-system-update    Skip apt upgrades and automatic security updates
  --enable-bbr-fq       Enable Linux TCP BBR with fq qdisc. Default: yes
  --no-bbr-fq           Do not configure Linux TCP BBR with fq qdisc
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
  --enable-bpftune      Build, install, and enable bpftune BPF auto-tuning daemon
  --no-bpftune          Do not install or enable bpftune. Default: no
  --bpftune-repo URL    bpftune git repository. Default: https://github.com/byethan/bpftune.git
  --bpftune-ref REF     bpftune git branch/tag/ref. Default: main
  --bpftune-src DIR     bpftune source checkout directory. Default: /usr/local/src/bpftune
  --network-only        Only apply network optimization; skip SSH hardening
  --tcp-tune-only       Alias of --network-only
  --security-only       Only apply VPS security/base initialization
  --role ROLE           VPS role: general, transit, exit, or web. Default: general
  --objective GOAL      Network goal: latency, balanced, single-stream, throughput, or custom
  --target-mbps MBPS    Single-stream target/bottleneck bandwidth; enables BDP tuning
  --rtt-ms MS           Measured client-to-VPS RTT; enables BDP tuning
  --bdp-factor N        Buffer multiplier applied to BDP, from 1 to 4. Default: 2
  --buffer-mib MIB      Exact TCP maximum buffer; selects objective=custom
  --allow-unsafe-buffer Allow manual/BDP buffer above the RAM-derived safety cap
  --enable-smart-tune   Apply memory-capped region/bandwidth TCP buffers
  --no-smart-tune       Keep minimal buffers. Default for general/web roles
  --bandwidth MBPS      TCP tuning profile bandwidth. Examples: auto, 500, 1000. Default: auto
  --region REGION       TCP tuning profile region: auto, asia, or overseas. "oversea" is accepted as overseas. Default: auto
  --dry-run             Preview TCP tuning files without applying changes
  --tc-iface IFACE      Configure optional egress shaping on this interface
  --tc-rate RATE        Egress shaping rate, for example 97mbit
  --tc-mtu MTU          Optional MTU to set before shaping, for example 1492
  --tc-burst BURST      Optional HTB burst size. Default: 256k
  -y, --yes             Non-interactive mode
  -h, --help            Show this help

Environment variables with the same names also work:
  SSH_USER, SSH_PORT, PUBLIC_KEY, PUBLIC_KEY_FILE, PUBLIC_KEY_STDIN, SHOW_SENSITIVE,
  COPY_ROOT_KEYS, ENABLE_FAIL2BAN,
  ENABLE_SYSTEM_UPDATE, ENABLE_BBR_FQ, ENABLE_LOCALE_FIX, SYSTEM_LOCALE,
  ENABLE_PREFER_IPV4,
  RUN_PART, TUNE_OBJECTIVE, OBJECTIVE,
  ENABLE_BDP_TUNE, BDP_BANDWIDTH_MBPS, BDP_RTT_MS, BDP_EXTRA_MIB, BDP_FACTOR,
  MANUAL_BUFFER_MIB, ALLOW_UNSAFE_BUFFER,
  ENABLE_BPFTUNE, BPFTUNE_REPO, BPFTUNE_REF, BPFTUNE_SRC_DIR,
  TUNE_BANDWIDTH, BANDWIDTH, TUNE_REGION, REGION, TUNE_ROLE, ROLE, SMART_TCP_TUNE,
  DRY_RUN, TC_IFACE, TC_RATE,
  TC_MTU, TC_BURST, ASSUME_YES, BACKUP_ROOT

What this script does:
  1. install SSH public keys for an existing SSH user, root by default
  2. move SSH to the port you specify; the old port closes right away
  3. disable SSH password login
  4. keep root login key-only
  5. install system updates and enable automatic security updates on apt systems
  6. enable TCP BBR with fq qdisc from the distribution kernel
  7. tune conservatively by VPS role; general stays at only BBR + fq by default
  8. optionally write memory-capped smart buffers or explicit BDP-based buffers
  9. configure a UTF-8 system locale and avoid invalid SSH LC_* imports
  10. prefer IPv4 for dual-stack hostname resolution without disabling IPv6
  11. optionally build and enable bpftune for BPF-driven Linux auto-tuning
  12. optionally install fail2ban and protect the SSH port
  13. optionally configure tc egress shaping when iface and rate are supplied
  14. create a systemd service to restore fq on the default route interface

Management subcommands:
  check     Print OS, kernel source, BBR version, qdisc, SSH ports, and reboot state.
  network-rollback
            Restore the latest managed network configuration backup.

Important:
  Allow the new port in your provider's firewall first. The old SSH port closes
  right away, so a blocked new port means reinstalling the machine.
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

security_part_enabled() {
  [[ "$RUN_PART" == "all" || "$RUN_PART" == "security" ]]
}

network_part_enabled() {
  [[ "$RUN_PART" == "all" || "$RUN_PART" == "network" ]]
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

resolve_tune_objective() {
  if [[ "$TUNE_OBJECTIVE" == "auto" ]]; then
    TUNE_OBJECTIVE="balanced"
  fi

  case "$TUNE_OBJECTIVE" in
    latency)
      if [[ "$SMART_TCP_TUNE" == "auto" ]]; then
        SMART_TCP_TUNE="no"
      fi
      ;;
    balanced)
      ;;
    single-stream)
      ENABLE_BDP_TUNE="yes"
      SMART_TCP_TUNE="no"
      if [[ -z "$BDP_BANDWIDTH_MBPS" && "$TUNE_BANDWIDTH" != "auto" ]]; then
        BDP_BANDWIDTH_MBPS="$TUNE_BANDWIDTH"
      fi
      ;;
    throughput)
      ENABLE_BDP_TUNE="yes"
      SMART_TCP_TUNE="no"
      if [[ "$BDP_FACTOR_EXPLICIT" != "yes" ]]; then
        BDP_FACTOR=3
      fi
      if [[ -z "$BDP_BANDWIDTH_MBPS" && "$TUNE_BANDWIDTH" != "auto" ]]; then
        BDP_BANDWIDTH_MBPS="$TUNE_BANDWIDTH"
      fi
      ;;
    custom)
      SMART_TCP_TUNE="no"
      if [[ -n "$MANUAL_BUFFER_MIB" ]]; then
        ENABLE_BDP_TUNE="no"
      fi
      ;;
  esac
}

resolve_tcp_tuple_defaults() {
  local tuple
  local first
  local second
  local third

  tuple="$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)"
  read -r first second third <<<"$tuple"
  if [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9]+$ ]]; then
    TCP_RMEM_MIN="$first"
    TCP_RMEM_DEFAULT="$second"
  fi

  tuple="$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)"
  read -r first second third <<<"$tuple"
  if [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9]+$ ]]; then
    TCP_WMEM_MIN="$first"
    TCP_WMEM_DEFAULT="$second"
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
  if [[ -n "$MANUAL_BUFFER_MIB" || "$SMART_TCP_TUNE" != "yes" || "$ENABLE_BDP_TUNE" == "yes" ]]; then
    return 0
  fi

  SMART_MEMORY_CAP_MB="$(get_tcp_buffer_cap_mb)"
  SMART_BUFFER_MB="$(calculate_smart_buffer_mb "$SMART_MEMORY_CAP_MB")"
  SMART_BUFFER_BYTES=$(( SMART_BUFFER_MB * 1024 * 1024 ))
}

tcp_tune_plan_value() {
  if [[ -n "$MANUAL_BUFFER_MIB" ]]; then
    printf 'custom / %sMiB / %s bytes\n' "$MANUAL_BUFFER_MIB" "$MANUAL_BUFFER_BYTES"
  elif [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf 'bdp-%sx / %s bytes\n' "$BDP_FACTOR" "$BDP_BUFFER_BYTES"
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
  if network_part_enabled && [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf 'yes / %sMbps / %sms / factor %sx / %s bytes\n' "$BDP_BANDWIDTH_MBPS" "$BDP_RTT_MS" "$BDP_FACTOR" "$BDP_BUFFER_BYTES"
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
      security)
        RUN_PART="security"
        shift
        ;;
      network)
        RUN_PART="network"
        shift
        ;;
      all|setup)
        RUN_PART="all"
        shift
        ;;
    esac
  fi

  if [[ $# -gt 0 ]]; then
    case "$1" in
      check|network-rollback)
        ACTION="$1"
        shift
        ;;
      install|rollback)
        die "the third-party BBRv3 kernel was removed; this script uses BBR from the distribution kernel"
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
        log "privacy warning: --public-key can be visible in shell history/process listings; prefer --key-file or --public-key-stdin"
        shift 2
        ;;
      --key-file)
        [[ $# -ge 2 ]] || die "--key-file requires a value"
        PUBLIC_KEY_FILE="${2:-}"
        shift 2
        ;;
      --public-key-stdin)
        PUBLIC_KEY_STDIN="yes"
        shift
        ;;
      --show-sensitive)
        SHOW_SENSITIVE="yes"
        shift
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
      --no-system-update)
        ENABLE_SYSTEM_UPDATE="no"
        shift
        ;;
      --no-bbrv3-kernel|--enable-vps-sysctl|--no-vps-sysctl)
        log "notice: $1 no longer has any effect"
        shift
        ;;
      --enable-bbrv3-kernel|--bbrv3-version|--bbrv3-repo|--bbrv3-standard|--bbrv3-max|--lock-bbrv3-version|--no-lock-bbrv3-version)
        die "$1 was removed; this script uses BBR from the distribution kernel"
        ;;
      --enable-bbr-fq)
        ENABLE_BBR_FQ="yes"
        shift
        ;;
      --no-bbr-fq)
        ENABLE_BBR_FQ="no"
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
        RUN_PART="network"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
        ;;
      --security-only)
        RUN_PART="security"
        shift
        ;;
      --role)
        [[ $# -ge 2 ]] || die "--role requires a value"
        TUNE_ROLE="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --objective)
        [[ $# -ge 2 ]] || die "--objective requires a value"
        TUNE_OBJECTIVE="${2:-}"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --target-mbps)
        [[ $# -ge 2 ]] || die "--target-mbps requires a value"
        BDP_BANDWIDTH_MBPS="${2:-}"
        TUNE_BANDWIDTH="${2:-}"
        ENABLE_BDP_TUNE="yes"
        [[ "$TUNE_OBJECTIVE" == "auto" ]] && TUNE_OBJECTIVE="single-stream"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --rtt-ms)
        [[ $# -ge 2 ]] || die "--rtt-ms requires a value"
        BDP_RTT_MS="${2:-}"
        ENABLE_BDP_TUNE="yes"
        [[ "$TUNE_OBJECTIVE" == "auto" ]] && TUNE_OBJECTIVE="single-stream"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --bdp-factor)
        [[ $# -ge 2 ]] || die "--bdp-factor requires a value"
        BDP_FACTOR="${2:-}"
        BDP_FACTOR_EXPLICIT="yes"
        ENABLE_BDP_TUNE="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --buffer-mib)
        [[ $# -ge 2 ]] || die "--buffer-mib requires a value"
        MANUAL_BUFFER_MIB="${2:-}"
        TUNE_OBJECTIVE="custom"
        ENABLE_BDP_TUNE="no"
        TCP_TUNE_ARGS_SEEN="yes"
        shift 2
        ;;
      --allow-unsafe-buffer)
        ALLOW_UNSAFE_BUFFER="yes"
        TCP_TUNE_ARGS_SEEN="yes"
        shift
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
  BDP_BUFFER_BYTES=$(( bdp_bytes * BDP_FACTOR + extra_bytes ))
}

validate_inputs() {
  if [[ "$RUN_PART" == "all" && -z "$SSH_PORT" && "$TCP_TUNE_ARGS_SEEN" == "yes" ]]; then
    RUN_PART="network"
  fi

  if [[ -n "$BDP_BANDWIDTH_MBPS" || -n "$BDP_RTT_MS" ]]; then
    ENABLE_BDP_TUNE="yes"
  fi

  normalize_region
  normalize_role
  [[ "$RUN_PART" =~ ^(all|security|network)$ ]] || die "RUN_PART must be all, security, or network"
  [[ "$TUNE_ROLE" =~ ^(general|transit|exit|web)$ ]] || die "--role must be general, transit, exit, or web"
  [[ "$TUNE_OBJECTIVE" =~ ^(auto|latency|balanced|single-stream|throughput|custom)$ ]] || die "--objective must be latency, balanced, single-stream, throughput, or custom"

  resolve_tune_objective
  resolve_smart_tcp_tune

  # Country detection contacts a public endpoint. Do it only when the chosen
  # smart-buffer plan actually needs region and interface-speed information.
  if network_part_enabled && [[ "$SMART_TCP_TUNE" == "yes" && "$ENABLE_BDP_TUNE" != "yes" && -z "$MANUAL_BUFFER_MIB" ]]; then
    resolve_auto_profile
  fi

  [[ "$PUBLIC_KEY_STDIN" =~ ^(yes|no)$ ]] || die "PUBLIC_KEY_STDIN must be yes or no"
  [[ "$SHOW_SENSITIVE" =~ ^(yes|no)$ ]] || die "SHOW_SENSITIVE must be yes or no"
  [[ "$COPY_ROOT_KEYS" =~ ^(yes|no)$ ]] || die "COPY_ROOT_KEYS must be yes or no"
  [[ "$ENABLE_FAIL2BAN" =~ ^(yes|no)$ ]] || die "ENABLE_FAIL2BAN must be yes or no"
  [[ "$ENABLE_SYSTEM_UPDATE" =~ ^(yes|no)$ ]] || die "ENABLE_SYSTEM_UPDATE must be yes or no"
  [[ "$ENABLE_BBR_FQ" =~ ^(yes|no)$ ]] || die "ENABLE_BBR_FQ must be yes or no"
  [[ "$ENABLE_BDP_TUNE" =~ ^(yes|no)$ ]] || die "ENABLE_BDP_TUNE must be yes or no"
  [[ "$SMART_TCP_TUNE" =~ ^(yes|no)$ ]] || die "SMART_TCP_TUNE must be auto, yes, or no"
  [[ "$ENABLE_LOCALE_FIX" =~ ^(yes|no)$ ]] || die "ENABLE_LOCALE_FIX must be yes or no"
  [[ "$ENABLE_PREFER_IPV4" =~ ^(yes|no)$ ]] || die "ENABLE_PREFER_IPV4 must be yes or no"
  [[ "$ENABLE_BPFTUNE" =~ ^(yes|no)$ ]] || die "ENABLE_BPFTUNE must be yes or no"
  [[ "$DRY_RUN" =~ ^(yes|no)$ ]] || die "DRY_RUN must be yes or no"
  [[ "$ASSUME_YES" =~ ^(yes|no)$ ]] || die "ASSUME_YES must be yes or no"
  [[ "$ALLOW_UNSAFE_BUFFER" =~ ^(yes|no)$ ]] || die "ALLOW_UNSAFE_BUFFER must be yes or no"
  [[ "$SYSTEM_LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "--system-locale contains unsupported characters"
  [[ "$BDP_FACTOR" =~ ^[0-9]+$ ]] || die "--bdp-factor must be an integer from 1 to 4"
  (( BDP_FACTOR >= 1 && BDP_FACTOR <= 4 )) || die "--bdp-factor must be from 1 to 4"

  if [[ "$SMART_TCP_TUNE" == "yes" && "$ENABLE_BDP_TUNE" != "yes" && -z "$MANUAL_BUFFER_MIB" ]]; then
    [[ "$TUNE_REGION" =~ ^(asia|overseas)$ ]] || die "--region must be asia or overseas when smart tuning is enabled"
    [[ "$TUNE_BANDWIDTH" =~ ^[0-9]+$ ]] || die "--bandwidth must be a number in Mbps when smart tuning is enabled"
    (( TUNE_BANDWIDTH >= 1 && TUNE_BANDWIDTH <= 100000 )) || die "--bandwidth must be from 1 to 100000 Mbps"
  else
    [[ "$TUNE_REGION" =~ ^(auto|asia|overseas)$ ]] || die "--region must be auto, asia, or overseas"
    [[ "$TUNE_BANDWIDTH" == "auto" || "$TUNE_BANDWIDTH" =~ ^[0-9]+$ ]] || die "--bandwidth must be auto or a number in Mbps"
    if [[ "$TUNE_BANDWIDTH" =~ ^[0-9]+$ ]]; then
      (( TUNE_BANDWIDTH >= 1 && TUNE_BANDWIDTH <= 100000 )) || die "--bandwidth must be from 1 to 100000 Mbps"
    fi
  fi

  SMART_MEMORY_CAP_MB="$(get_tcp_buffer_cap_mb)"
  if [[ -n "$MANUAL_BUFFER_MIB" ]]; then
    [[ "$MANUAL_BUFFER_MIB" =~ ^[0-9]+$ ]] || die "--buffer-mib must be an integer"
    (( MANUAL_BUFFER_MIB >= 1 && MANUAL_BUFFER_MIB <= 512 )) || die "--buffer-mib must be from 1 to 512 MiB"
    MANUAL_BUFFER_BYTES=$(( MANUAL_BUFFER_MIB * 1024 * 1024 ))
    if (( MANUAL_BUFFER_MIB > SMART_MEMORY_CAP_MB )) && [[ "$ALLOW_UNSAFE_BUFFER" != "yes" ]]; then
      die "--buffer-mib exceeds the ${SMART_MEMORY_CAP_MB}MiB RAM-derived safety cap; reduce it or explicitly use --allow-unsafe-buffer"
    fi
  elif [[ "$TUNE_OBJECTIVE" == "custom" ]]; then
    die "--objective custom requires --buffer-mib"
  fi

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
    if (( BDP_BUFFER_BYTES > SMART_MEMORY_CAP_MB * 1024 * 1024 )) && [[ "$ALLOW_UNSAFE_BUFFER" != "yes" ]]; then
      die "calculated BDP buffer exceeds the ${SMART_MEMORY_CAP_MB}MiB RAM-derived safety cap; lower target/RTT/factor or explicitly use --allow-unsafe-buffer"
    fi
  fi
  resolve_tcp_buffer_plan
  resolve_tcp_tuple_defaults
  [[ -n "$BPFTUNE_REPO" && "$BPFTUNE_REPO" != *[[:space:]]* ]] || die "--bpftune-repo must be a non-empty URL/path without whitespace"
  [[ "$BPFTUNE_REF" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "--bpftune-ref contains unsupported characters"
  [[ "$BPFTUNE_SRC_DIR" == /* ]] || die "--bpftune-src must be an absolute path"

  if [[ "$DRY_RUN" != "yes" ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo bash $SCRIPT_NAME"
  fi

  if security_part_enabled; then
    [[ -n "$SSH_USER" ]] || die "--user cannot be empty"
    [[ -n "$SSH_PORT" ]] || die "--port is required"
    [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid Linux user name: $SSH_USER"
    id "$SSH_USER" >/dev/null 2>&1 || die "user $SSH_USER does not exist; create it before running this script"
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be a number"
    (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || die "use a port from 1024 to 65535"
  elif [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
    die "--enable-fail2ban requires SSH hardening and --port"
  fi

  if security_part_enabled; then
    if [[ "$PUBLIC_KEY_STDIN" == "yes" && ( -n "$PUBLIC_KEY" || -n "$PUBLIC_KEY_FILE" ) ]]; then
      die "use only one public-key input: --public-key-stdin, --key-file, or --public-key"
    fi

    if [[ -n "$PUBLIC_KEY" && -n "$PUBLIC_KEY_FILE" ]]; then
      die "use only one public-key input: --key-file or --public-key"
    fi

    if [[ "$PUBLIC_KEY_STDIN" == "yes" ]]; then
      IFS= read -r PUBLIC_KEY || die "failed to read a public key from standard input"
      [[ -n "$PUBLIC_KEY" ]] || die "standard input did not contain a public key"
    elif [[ -n "$PUBLIC_KEY_FILE" ]]; then
      [[ -r "$PUBLIC_KEY_FILE" ]] || die "cannot read key file: $PUBLIC_KEY_FILE"
      PUBLIC_KEY="$(sed -n '1p' "$PUBLIC_KEY_FILE")"
    fi

    if [[ -n "$PUBLIC_KEY" ]]; then
      [[ "$PUBLIC_KEY" != *$'\n'* && "$PUBLIC_KEY" != *$'\r'* ]] || die "public key must be exactly one line"
      [[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || die "public key does not look like an SSH public key"
    fi
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

  if [[ -n "$PUBLIC_KEY" ]] && command -v ssh-keygen >/dev/null 2>&1; then
    if ! printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1; then
      die "the supplied public key is not valid; nothing was changed"
    fi
  fi

  install -d -m 0700 -o "$SSH_USER" -g "$user_group" "$user_home/.ssh"

  if [[ -n "$PUBLIC_KEY" ]]; then
    touch "$auth_keys"
    if ! grep -Fxq "$PUBLIC_KEY" "$auth_keys"; then
      # A last line without a newline would otherwise merge with the new key.
      if [[ -n "$(tail -c 1 "$auth_keys")" ]]; then
        printf '\n' >>"$auth_keys"
      fi
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

  return 1
}

sshd_binary() {
  command -v sshd 2>/dev/null || printf '/usr/sbin/sshd\n'
}

sshd_effective_ports() {
  "$(sshd_binary)" -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
}

port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v port="$port" '{n = split($4, part, ":"); if (part[n] == port) found = 1} END {exit !found}'
}

wait_for_ssh_port() {
  local port="$1"
  local attempt

  command -v ss >/dev/null 2>&1 || return 0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    port_is_listening "$port" && return 0
    sleep 1
  done
  return 1
}

check_ssh_port_available() {
  local listeners

  command -v ss >/dev/null 2>&1 || return 0
  listeners="$(ss -ltnpH "sport = :$SSH_PORT" 2>/dev/null || true)"
  [[ -n "$listeners" ]] || return 0
  [[ "$listeners" == *'"sshd"'* || "$listeners" == *'"systemd"'* ]] && return 0
  die "TCP port $SSH_PORT is already used by another service; choose a different --port"
}

allow_ssh_port_in_firewall() {
  local handled="no"
  local status
  local nft_rules
  local iptables_rules
  local drop_pattern='hook input[^;]*;[[:space:]]*policy drop'

  if command -v ufw >/dev/null 2>&1; then
    status="$(ufw status 2>/dev/null || true)"
    if [[ "$status" == *"Status: active"* ]]; then
      handled="yes"
      if ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1; then
        log "opened TCP $SSH_PORT in ufw"
      else
        log "warning: failed to open TCP $SSH_PORT in ufw"
      fi
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    handled="yes"
    if firewall-cmd --permanent --add-port="$SSH_PORT/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
      log "opened TCP $SSH_PORT in firewalld"
    else
      log "warning: failed to open TCP $SSH_PORT in firewalld"
    fi
  fi

  [[ "$handled" == "no" ]] || return 0
  nft_rules="$(nft list ruleset 2>/dev/null || true)"
  iptables_rules="$(iptables -S INPUT 2>/dev/null || true)"
  if [[ "$nft_rules" =~ $drop_pattern || "$iptables_rules" == *"-P INPUT DROP"* ]]; then
    log "warning: the local firewall drops incoming traffic by default; TCP $SSH_PORT may be blocked"
  fi
}

backup_sshd_files() {
  local stamp="$1"
  local file

  for file in /etc/ssh/sshd_config "$SSHD_INCLUDE_FILE" "$SSHD_LEGACY_INCLUDE_FILE"; do
    if [[ -e "$file" ]]; then
      cp -p "$file" "$file.bak.$stamp"
    fi
  done
}

restore_sshd_files() {
  local stamp="$1"
  local file

  for file in /etc/ssh/sshd_config "$SSHD_INCLUDE_FILE" "$SSHD_LEGACY_INCLUDE_FILE"; do
    if [[ -e "$file.bak.$stamp" ]]; then
      cp -p "$file.bak.$stamp" "$file"
    else
      rm -f "$file"
    fi
  done
}

configure_sshd() {
  local sshd_bin
  local stamp

  stamp="$(date +%Y%m%d%H%M%S)"
  sshd_bin="$(sshd_binary)"
  backup_sshd_files "$stamp"

  remove_managed_sshd_block /etc/ssh/sshd_config
  comment_global_sshd_directives /etc/ssh/sshd_config
  if sshd_supports_include "$sshd_bin"; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    rm -f "$SSHD_LEGACY_INCLUDE_FILE"
    print_sshd_hardening_config >"$SSHD_INCLUDE_FILE"
    ensure_sshd_dropin_include /etc/ssh/sshd_config
  else
    log "warning: this sshd does not support Include; writing SSH hardening inline"
    rm -f "$SSHD_INCLUDE_FILE" "$SSHD_LEGACY_INCLUDE_FILE"
    remove_sshd_dropin_include /etc/ssh/sshd_config
    prepend_inline_sshd_hardening /etc/ssh/sshd_config
  fi

  if ! "$sshd_bin" -t; then
    restore_sshd_files "$stamp"
    die "sshd rejected the new configuration; the previous SSH configuration was restored"
  fi

  allow_ssh_port_in_firewall

  # Socket activation takes its port from the socket unit and leaves
  # ssh.service disabled, so sshd would not come back after a reboot.
  if command -v systemctl >/dev/null 2>&1 && systemctl cat ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1 || log "warning: failed to enable ssh.service"
  fi

  if ! { restart_sshd_service && wait_for_ssh_port "$SSH_PORT"; }; then
    restore_sshd_files "$stamp"
    restart_sshd_service || true
    die "SSH did not come back on port $SSH_PORT; the previous SSH configuration was restored"
  fi
  log "SSH now listens on port $SSH_PORT; the old port is closed"
}

tcp_buffer_max_bytes() {
  if [[ -n "$MANUAL_BUFFER_MIB" ]]; then
    printf '%s\n' "$MANUAL_BUFFER_BYTES"
  elif [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf '%s\n' "$BDP_BUFFER_BYTES"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    printf '%s\n' "$SMART_BUFFER_BYTES"
  fi
}

# The exit role widens the ephemeral range over common SSH ports. Reserve them
# so an outgoing connection cannot hold the SSH port when sshd restarts.
ssh_reserved_ports() {
  local ports="$SSH_PORT"
  local reserved
  local port

  [[ -n "$ports" ]] || ports="$(sshd_effective_ports)"
  reserved="$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)"
  for port in $ports; do
    (( port >= 10240 )) || continue
    [[ ",$reserved," == *",$port,"* ]] || reserved="${reserved:+$reserved,}$port"
  done
  printf '%s\n' "$reserved"
}

print_tcp_tune_settings() {
  local max_bytes
  local reserved

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  fi

  max_bytes="$(tcp_buffer_max_bytes)"
  if [[ -n "$max_bytes" ]]; then
    printf 'net.core.rmem_max = %s\n' "$max_bytes"
    printf 'net.core.wmem_max = %s\n' "$max_bytes"
    printf 'net.ipv4.tcp_rmem = %s %s %s\n' "$TCP_RMEM_MIN" "$TCP_RMEM_DEFAULT" "$max_bytes"
    printf 'net.ipv4.tcp_wmem = %s %s %s\n' "$TCP_WMEM_MIN" "$TCP_WMEM_DEFAULT" "$max_bytes"
  fi

  if [[ "$TUNE_ROLE" =~ ^(transit|exit)$ || "$TUNE_OBJECTIVE" =~ ^(single-stream|throughput)$ ]]; then
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
  fi

  case "$TUNE_ROLE" in
    transit|exit)
      printf 'net.ipv4.tcp_mtu_probing = 1\n'
      ;;
    web)
      printf 'net.core.somaxconn = 8192\n'
      printf 'net.ipv4.tcp_max_syn_backlog = 8192\n'
      printf 'net.ipv4.tcp_mtu_probing = 1\n'
      ;;
  esac

  if [[ "$TUNE_ROLE" == "exit" ]]; then
    printf 'net.ipv4.ip_local_port_range = 10240 65535\n'
    reserved="$(ssh_reserved_ports)"
    if [[ -n "$reserved" ]]; then
      printf 'net.ipv4.ip_local_reserved_ports = %s\n' "$reserved"
    fi
  fi
}

print_tcp_tune_sysctl() {
  printf '# Generated by %s\n' "$SCRIPT_NAME"
  if [[ -n "$MANUAL_BUFFER_MIB" ]]; then
    printf '# Custom TCP buffer tuning: objective=%s, max=%s MiB\n' "$TUNE_OBJECTIVE" "$MANUAL_BUFFER_MIB"
  elif [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
    printf '# BDP TCP buffer tuning: objective=%s, %s Mbps, %s ms RTT, factor=%sx, +%s MiB headroom\n' "$TUNE_OBJECTIVE" "$BDP_BANDWIDTH_MBPS" "$BDP_RTT_MS" "$BDP_FACTOR" "$BDP_EXTRA_MIB"
  elif [[ "$SMART_TCP_TUNE" == "yes" ]]; then
    printf '# Smart TCP tuning: role=%s, region=%s, bandwidth=%sMbps, memory-cap=%sMiB\n' "$TUNE_ROLE" "$TUNE_REGION" "$TUNE_BANDWIDTH" "$SMART_MEMORY_CAP_MB"
  else
    printf '# Conservative TCP profile: role=%s; keep system-managed buffers\n' "$TUNE_ROLE"
  fi
  print_tcp_tune_settings
}

print_fq_restore_default() {
  cat <<'FQ_DEFAULT'
# Space-separated interface names. Leave empty to use default route interfaces.
VPS_FQ_IFACES=
FQ_DEFAULT
}

print_fq_restore_script() {
  cat <<'FQ_SCRIPT'
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
    pfifo|pfifo_fast|bfifo|fq_codel) ;;
    *) continue ;;
  esac
  tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
done
FQ_SCRIPT
}

print_fq_restore_unit() {
  cat <<'FQ_SERVICE'
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
}

print_fq_restore_files() {
  printf '/etc/default/vps-fq-restore:\n'
  print_fq_restore_default
  printf '\n/usr/local/sbin/vps-fq-restore:\n'
  print_fq_restore_script
  printf '\n/etc/systemd/system/vps-fq-restore.service:\n'
  print_fq_restore_unit
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

network_record_created_path() {
  local path="$1"
  if [[ "$NETWORK_BACKUP_DONE" == "yes" && -n "$NETWORK_BACKUP_DIR" ]]; then
    printf '%s\n' "$path" >>"$NETWORK_BACKUP_DIR/created-paths.txt"
  fi
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
    network_record_created_path "$disabled"
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

managed_network_paths() {
  printf '%s\n' \
    /etc/sysctl.d/90-vps-bbr-fq.conf \
    /etc/sysctl.d/99-vps-tcp-tune.conf \
    /etc/sysctl.d/99-joeyblog.conf \
    /etc/sysctl.d/98-vps-baseline.conf \
    /etc/sysctl.d/99-bbr-fq.conf \
    /etc/modules-load.d/bbr.conf \
    /etc/gai.conf \
    /etc/default/vps-fq-restore \
    /usr/local/sbin/vps-fq-restore \
    /etc/systemd/system/vps-fq-restore.service \
    /etc/default/vps-tc-shape \
    /usr/local/sbin/vps-tc-shape \
    /etc/systemd/system/vps-tc-shape.service
}

network_backup_config() {
  local backup_dir
  local path
  local relative
  local manifest
  local enabled_state
  local active_state

  if [[ "$NETWORK_BACKUP_DONE" == "yes" ]]; then
    return 0
  fi
  [[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != "/" ]] || die "BACKUP_ROOT must be a non-root absolute path"

  backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d%H%M%S)-$$-network"
  manifest="$backup_dir/manifest.tsv"
  install -d -m 0700 "$backup_dir/files"
  : >"$manifest"

  while IFS= read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
      relative="${path#/}"
      install -d -m 0700 "$backup_dir/files/$(dirname "$relative")"
      cp -a "$path" "$backup_dir/files/$relative"
      printf 'present\t%s\n' "$path" >>"$manifest"
    else
      printf 'absent\t%s\n' "$path" >>"$manifest"
    fi
  done < <(managed_network_paths)

  : >"$backup_dir/services.tsv"
  if command -v systemctl >/dev/null 2>&1; then
    for path in vps-fq-restore.service vps-tc-shape.service; do
      enabled_state="$(systemctl is-enabled "$path" 2>/dev/null | sed -n '1p' || true)"
      active_state="$(systemctl is-active "$path" 2>/dev/null | sed -n '1p' || true)"
      printf '%s\t%s\t%s\n' "$path" "${enabled_state:-disabled}" "${active_state:-inactive}" >>"$backup_dir/services.tsv"
    done
  fi

  if [[ -n "$TC_IFACE" ]] && ip link show dev "$TC_IFACE" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$TC_IFACE" "$(ip -o link show dev "$TC_IFACE" | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}')" >"$backup_dir/tc-mtu.tsv"
  fi

  printf '%s\n' "$backup_dir" >/etc/vps-firstboot-last-network-backup
  NETWORK_BACKUP_DONE="yes"
  NETWORK_BACKUP_DIR="$backup_dir"
  log "backed up network config to $backup_dir"
}

network_backup_path_allowed() {
  [[ $'\n'"$(managed_network_paths)"$'\n' == *$'\n'"$1"$'\n'* ]]
}

network_created_path_allowed() {
  [[ "$1" =~ ^/etc/sysctl\.d/(99-vps-tcp-tune|99-joeyblog|98-vps-baseline|99-bbr-fq)\.conf\.disabled(\.([0-9]{14}|backup))?$ ]]
}

latest_network_backup() {
  local pointed
  [[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != "/" ]] || die "BACKUP_ROOT must be a non-root absolute path"
  pointed="$(sed -n '1p' /etc/vps-firstboot-last-network-backup 2>/dev/null || true)"
  if [[ "$pointed" == "${BACKUP_ROOT}/"*-network && -f "$pointed/manifest.tsv" ]]; then
    printf '%s\n' "$pointed"
    return 0
  fi
  ls -dt "${BACKUP_ROOT}"/*-network 2>/dev/null | head -n 1 || true
}

network_rollback() {
  local backup_dir
  local status
  local path
  local source
  local iface
  local mtu
  local unit
  local enabled_state
  local active_state
  local created_path

  [[ "$(id -u)" -eq 0 ]] || die "run as root for network rollback"
  backup_dir="$(latest_network_backup)"
  [[ -n "$backup_dir" && -f "$backup_dir/manifest.tsv" ]] || die "no network backup was found"

  cat <<PLAN

Network rollback plan:
  backup: $backup_dir
  restore only vps-firstboot-managed sysctl, IPv4 preference, fq restore, and tc shaping files
  later edits to those managed paths will be replaced by the saved versions
  kernels and SSH configuration will not be changed

PLAN
  confirm "Proceed with network rollback?" || die "aborted"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now vps-tc-shape.service vps-fq-restore.service >/dev/null 2>&1 || true
  fi

  if [[ -f "$backup_dir/created-paths.txt" ]]; then
    while IFS= read -r created_path; do
      [[ -n "$created_path" ]] || continue
      network_created_path_allowed "$created_path" || die "backup contains unsupported created path: $created_path"
      if [[ -d "$created_path" && ! -L "$created_path" ]]; then
        die "refusing to remove unexpected directory during rollback: $created_path"
      fi
      rm -f "$created_path"
    done <"$backup_dir/created-paths.txt"
  fi

  while IFS=$'\t' read -r status path; do
    [[ -n "$status" && -n "$path" ]] || continue
    network_backup_path_allowed "$path" || die "backup contains unsupported path: $path"
    source="$backup_dir/files/${path#/}"
    case "$status" in
      present)
        [[ -e "$source" || -L "$source" ]] || die "backup is incomplete: $source"
        if [[ -d "$path" && ! -L "$path" ]]; then
          die "refusing to replace unexpected directory during rollback: $path"
        fi
        rm -f "$path"
        install -d -m 0755 "$(dirname "$path")"
        cp -a "$source" "$path"
        ;;
      absent)
        if [[ -d "$path" && ! -L "$path" ]]; then
          die "refusing to remove unexpected directory during rollback: $path"
        fi
        rm -f "$path"
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
    if [[ -f "$backup_dir/services.tsv" ]]; then
      while IFS=$'\t' read -r unit enabled_state active_state; do
        [[ "$unit" =~ ^vps-(fq-restore|tc-shape)\.service$ ]] || continue
        if [[ "$enabled_state" == "enabled" ]]; then
          systemctl enable "$unit" >/dev/null 2>&1 || true
        else
          systemctl disable "$unit" >/dev/null 2>&1 || true
        fi
        if [[ "$active_state" == "active" ]]; then
          systemctl start "$unit" >/dev/null 2>&1 || true
        else
          systemctl stop "$unit" >/dev/null 2>&1 || true
        fi
      done <"$backup_dir/services.tsv"
    fi
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
  print_fq_restore_default >"$default_file"
  print_fq_restore_script >"$script_file"
  chmod 0755 "$script_file"
  print_fq_restore_unit >"$service_file"

  "$script_file"
  systemctl daemon-reload || log "warning: failed to reload systemd after writing vps-fq-restore.service"
  systemctl enable vps-fq-restore.service >/dev/null 2>&1 || log "warning: failed to enable vps-fq-restore.service"
}

configure_tcp_tune() {
  local available
  local line
  local key
  local value
  local sysctl_file="/etc/sysctl.d/90-vps-bbr-fq.conf"

  if [[ "$ENABLE_BBR_FQ" != "yes" && "$ENABLE_BDP_TUNE" != "yes" && "$SMART_TCP_TUNE" != "yes" && -z "$MANUAL_BUFFER_MIB" && "$TUNE_ROLE" == "general" ]]; then
    disable_legacy_tcp_tune_conf
    warn_sysctl_network_overrides
    return 0
  fi

  if [[ "$ENABLE_BBR_FQ" == "yes" ]]; then
    if [[ -x "$(command -v modprobe || true)" ]]; then
      modprobe tcp_bbr 2>/dev/null || true
    fi
    install -d -m 0755 /etc/modules-load.d
    printf 'tcp_bbr\n' >/etc/modules-load.d/bbr.conf
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  install -d -m 0755 /etc/sysctl.d
  disable_legacy_tcp_tune_conf
  rm -f /etc/sysctl.d/98-vps-baseline.conf /etc/sysctl.d/99-bbr-fq.conf
  : >"$sysctl_file"

  while IFS= read -r line; do
    key="${line%% = *}"
    value="${line#* = }"
    if [[ "$key" == "net.ipv4.tcp_congestion_control" && " $available " != *" bbr "* ]]; then
      log "warning: tcp_bbr is not available on this kernel; tcp_congestion_control was left unchanged"
      continue
    fi
    apply_sysctl_setting "$sysctl_file" "$key" "$value"
  done < <(print_tcp_tune_settings)

  if [[ ! -s "$sysctl_file" ]]; then
    rm -f "$sysctl_file"
  fi

  warn_sysctl_network_overrides
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

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@" </dev/null
}

# apt-get update takes the lists lock without waiting, and apt-daily can hold it.
apt_update() {
  local attempt

  for attempt in 1 2 3 4 5 6; do
    apt_get update && return 0
    log "apt-get update failed (attempt $attempt of 6)"
    sleep 20
  done
  return 1
}

# dpkg has no lock timeout of its own, and apt-daily can hold the lock at any time.
dpkg_configure_pending() {
  local attempt
  local output

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    if output="$(LC_ALL=C DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a 2>&1 </dev/null)"; then
      if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
      fi
      return 0
    fi
    if [[ "$output" != *"locked by another process"* ]]; then
      break
    fi
    if (( attempt == 1 )); then
      log "waiting for another package manager to finish"
    fi
    sleep 10
  done
  printf '%s\n' "$output" >&2
  return 1
}

wait_for_boot_tasks() {
  command -v cloud-init >/dev/null 2>&1 || return 0
  log "waiting for cloud-init to finish"
  timeout 600 cloud-init status --wait >/dev/null 2>&1 || log "warning: cloud-init reported a problem or timed out; continuing"
}

os_release_value() {
  awk -F= -v key="$1" '$1 == key {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true
}

ensure_debian_security_source() {
  local codename
  local policy

  [[ "$(os_release_value ID)" == "debian" ]] || return 0
  codename="$(os_release_value VERSION_CODENAME)"
  case "$codename" in
    bookworm|trixie) ;;
    *) return 0 ;;
  esac

  policy="$(apt-cache policy 2>/dev/null || true)"
  [[ "$policy" != *"n=${codename}-security"* ]] || return 0

  log "adding the missing ${codename}-security source"
  cat >/etc/apt/sources.list.d/debian-security.sources <<SOURCES
Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${codename}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
  apt_update
}

# Without the metapackage, apt never pulls in new Debian kernels.
ensure_debian_kernel_metapackage() {
  local arch
  local meta
  local status

  [[ "$(os_release_value ID)" == "debian" ]] || return 0
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq; then
    return 0
  fi

  arch="$(dpkg --print-architecture)"
  case "$(uname -r)" in
    *-cloud-*) meta="linux-image-cloud-$arch" ;;
    *) meta="linux-image-$arch" ;;
  esac

  status="$(dpkg-query -W -f='${db:Status-Status}' "$meta" 2>/dev/null || true)"
  [[ "$status" != "installed" ]] || return 0
  log "installing the kernel metapackage $meta"
  apt_get install "$meta"
}

enable_automatic_security_updates() {
  apt_get install unattended-upgrades || return 1
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTO_UPGRADES
}

apply_system_update() {
  dpkg_configure_pending || return 1
  apt_update || return 1
  ensure_debian_security_source || return 1
  apt_get -f install || return 1
  apt_get full-upgrade || return 1
  ensure_debian_kernel_metapackage || return 1
  enable_automatic_security_updates
}

system_update() {
  if [[ "$ENABLE_SYSTEM_UPDATE" != "yes" ]]; then
    SYSTEM_UPDATE_RESULT="disabled"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    SYSTEM_UPDATE_RESULT="unsupported"
    log "warning: system update supports apt only; skipping"
    return 0
  fi

  log "installing system updates"
  if apply_system_update; then
    SYSTEM_UPDATE_RESULT="ok"
  else
    SYSTEM_UPDATE_RESULT="failed"
    log "warning: system update failed; continuing with the remaining setup"
  fi
}

install_fail2ban() {
  local fail2ban_backend="auto"

  if [[ "$ENABLE_FAIL2BAN" != "yes" ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt_update || return 1
    apt_get install fail2ban || return 1
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
    if ! command -v locale-gen >/dev/null 2>&1; then
      if ! { apt_update && apt_get install locales; }; then
        log "warning: failed to install locales; skipping locale configuration"
        return 0
      fi
    fi

    if [[ -f /etc/locale.gen ]] && ! grep -Eq "^[[:space:]]*${SYSTEM_LOCALE}[[:space:]]+UTF-8" /etc/locale.gen; then
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

install_bpftune_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt_update
    apt_get install git make gcc pkg-config clang llvm bpftool libbpf-dev libcap-dev libnl-3-dev libnl-route-3-dev python3-docutils
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
  if security_part_enabled; then
    cat <<SECURITY_DRYRUN

Dry run: Part 1 / VPS security and base initialization. No files or services will be changed.

Security profile:
  ssh user:         $SSH_USER
  ssh port:         $SSH_PORT
  public key:       $([[ -n "$PUBLIC_KEY" ]] && printf 'provided (content hidden)' || printf 'root authorized_keys fallback')
  password login:   disabled
  root login:       key-only
  locale fix:       $(locale_plan_value)
  fail2ban:         $ENABLE_FAIL2BAN
  system update:    $ENABLE_SYSTEM_UPDATE

Would validate and write the SSH hardening drop-in:
SECURITY_DRYRUN
    print_sshd_hardening_config
  fi

  if ! network_part_enabled; then
    return 0
  fi

  cat <<DRYRUN

Dry run: Part 2 / BBR, TCP and single-stream tuning. No files, sysctls, qdiscs, or kernels will be changed.

Profile:
  role:             $TUNE_ROLE
  objective:        $TUNE_OBJECTIVE
  region:           $TUNE_REGION
  region source:    $TUNE_REGION_SOURCE
  bandwidth:        $TUNE_BANDWIDTH$([[ "$TUNE_BANDWIDTH" == "auto" ]] || printf 'Mbps')
  bandwidth source: $TUNE_BANDWIDTH_SOURCE
  bbr + fq:         $ENABLE_BBR_FQ
  tcp sysctl:       $(tcp_tune_plan_value)
  smart tune:       $SMART_TCP_TUNE
  bdp tune:         $(bdp_plan_value)
  ipv4 preference:  $(ipv4_preference_plan_value)
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
  printf '\nPlan (execution domain: %s):\n' "$RUN_PART"
  if security_part_enabled; then
    cat <<SECURITY_PLAN
  Part 1 security:   enabled
  ssh user/port:     $SSH_USER / $SSH_PORT
  public key:        $([[ -n "$PUBLIC_KEY" ]] && printf 'provided (content hidden)' || printf 'root authorized_keys fallback')
  locale fix:        $(locale_plan_value)
  fail2ban:          $ENABLE_FAIL2BAN
  system update:     $ENABLE_SYSTEM_UPDATE
SECURITY_PLAN
  else
    printf '  Part 1 security:   skipped\n'
  fi

  if network_part_enabled; then
    cat <<NETWORK_PLAN
  Part 2 network:    enabled
  bbr + fq:          $ENABLE_BBR_FQ
  role/objective:    $TUNE_ROLE / $TUNE_OBJECTIVE
  tcp sysctl:        $(tcp_tune_plan_value)
  smart tune:        $SMART_TCP_TUNE
  bdp tune:          $(bdp_plan_value)
  ipv4 preference:   $(ipv4_preference_plan_value)
  bpftune:           $ENABLE_BPFTUNE
  tcp profile:       $TUNE_REGION / $TUNE_BANDWIDTH$([[ "$TUNE_BANDWIDTH" == "auto" ]] || printf 'Mbps')
  profile source:    $TUNE_REGION_SOURCE / $TUNE_BANDWIDTH_SOURCE
  tc shaping:        ${TC_IFACE:-disabled}${TC_RATE:+ @ $TC_RATE}
NETWORK_PLAN
  else
    printf '  Part 2 network:    skipped\n'
  fi

  if security_part_enabled; then
    printf '\nThis will disable SSH password login and close the old SSH port.\n\n'
  else
    printf '\n'
  fi
}

kernel_source() {
  local maintainer

  maintainer="$(dpkg-query -W -f='${Maintainer}' "linux-image-$(uname -r)" 2>/dev/null || true)"
  case "$maintainer" in
    "") printf 'unknown\n' ;;
    *debian-kernel@lists.debian.org*|*kernel-team@lists.ubuntu.com*) printf 'official\n' ;;
    *) printf 'third-party\n' ;;
  esac
}

third_party_kernels() {
  { dpkg-query -W -f='${db:Status-Status} ${binary:Package} ${Maintainer}\n' 'linux-image-*' 2>/dev/null || true; } |
    awk '$1 == "installed" && !/debian-kernel@lists\.debian\.org|kernel-team@lists\.ubuntu\.com/ {print $2}' |
    xargs
}

newest_installed_kernel() {
  local kernel

  for kernel in /boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    printf '%s\n' "${kernel##*/vmlinuz-}"
  done | sort -V | tail -n 1
}

reboot_required() {
  local newest

  [[ ! -e /var/run/reboot-required ]] || return 0
  newest="$(newest_installed_kernel)"
  [[ -n "$newest" && "$newest" != "$(uname -r)" ]]
}

tcp_bbr_version() {
  if [[ -r /sys/module/tcp_bbr/version ]]; then
    cat /sys/module/tcp_bbr/version
  elif [[ -d /sys/module/tcp_bbr ]]; then
    printf '1\n'
  else
    printf 'not-loaded\n'
  fi
}

default_route_qdiscs() {
  local iface="$1"
  tc qdisc show dev "$iface" 2>/dev/null | awk '{print $2}' | sort -u | xargs
}

print_kernel_status() {
  local third_party

  third_party="$(third_party_kernels)"
  printf 'kernel: %s\n' "$(uname -r)"
  printf 'kernel_source: %s\n' "$(kernel_source)"
  printf 'third_party_kernels: %s\n' "${third_party:-none}"
  printf 'reboot_required: %s\n' "$(reboot_required && echo yes || echo no)"
  printf 'tcp_bbr_version: %s\n' "$(tcp_bbr_version)"
}

status_check() {
  local iface

  printf '\nStatus:\n'
  printf 'os: %s\n' "$(os_release_value PRETTY_NAME)"
  print_kernel_status
  printf 'tcp_available_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf 'default_qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  for iface in $(ip route show default 2>/dev/null | awk '{print $5}' | sort -u); do
    printf 'qdiscs_on_%s: %s\n' "$iface" "$(default_route_qdiscs "$iface")"
  done
  printf 'ssh_ports: %s\n' "$(sshd_effective_ports | xargs)"
  printf 'automatic_updates: %s\n' "$([[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && echo yes || echo no)"
}

show_verification_status() {
  local bbr_available
  local default_ifaces
  local sshd_t
  local iface_index=0
  local iface
  sshd_t=""
  if security_part_enabled; then
    sshd_t="$("$(sshd_binary)" -T 2>/dev/null || true)"
  fi
  bbr_available="unknown"
  default_ifaces=""
  if network_part_enabled; then
    bbr_available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ " $bbr_available " == *" bbr "* ]]; then
      bbr_available="yes"
    else
      bbr_available="no"
    fi
    default_ifaces="$(ip route show default 2>/dev/null | awk '{print $5}' | sort -u | tr '\n' ' ' || true)"
  fi

  printf '\nVerification:\n'
  print_kernel_status
  if security_part_enabled; then
    printf 'system_update: %s\n' "$SYSTEM_UPDATE_RESULT"
    printf 'ssh_listen_target: %s\n' "$(port_is_listening "$SSH_PORT" && echo yes || echo no)"
    printf 'ssh_ports: %s\n' "$(sshd_effective_ports | xargs)"
    printf 'pubkeyauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^pubkeyauthentication / {print $2; exit}')"
    printf 'passwordauthentication: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^passwordauthentication / {print $2; exit}')"
    printf 'permitrootlogin: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^permitrootlogin / {print $2; exit}')"
    printf 'allowusers: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^allowusers / {$1=""; sub(/^ /, ""); print; exit}')"
    printf 'usedns: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^usedns / {print $2; exit}')"
    printf 'acceptenv: %s\n' "$(printf '%s\n' "$sshd_t" | awk '/^acceptenv / {$1=""; sub(/^ /, ""); print; exit}')"
    printf 'system_locale: %s\n' "$(awk -F= '/^LANG=/ {gsub(/"/, "", $2); print $2; found=1} END{if(!found) print "unknown"}' /etc/default/locale 2>/dev/null || echo unknown)"
    printf 'locale_check_skip: %s\n' "$([[ -e /var/lib/cloud/instance/locale-check.skip ]] && echo yes || echo no)"
  fi

  if network_part_enabled; then
    printf 'tcp_profile: %s/%s%s\n' "$TUNE_REGION" "$TUNE_BANDWIDTH" "$([[ "$TUNE_BANDWIDTH" == "auto" ]] || printf 'Mbps')"
    printf 'tcp_role: %s\n' "$TUNE_ROLE"
    printf 'tcp_objective: %s\n' "$TUNE_OBJECTIVE"
    printf 'tcp_tune_mode: %s\n' "$(tcp_tune_plan_value)"
    printf 'tcp_profile_source: %s/%s\n' "$TUNE_REGION_SOURCE" "$TUNE_BANDWIDTH_SOURCE"
    if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
      printf 'tcp_profile_country: %s\n' "${TUNE_COUNTRY_CODE:-unknown}"
      printf 'tcp_profile_iface: %s\n' "${TUNE_DEFAULT_IFACE:-unknown}"
    else
      printf 'tcp_profile_country: %s\n' "$([[ -n "$TUNE_COUNTRY_CODE" ]] && printf 'detected (hidden)' || printf 'not-detected')"
      printf 'tcp_profile_iface: %s\n' "$([[ -n "$TUNE_DEFAULT_IFACE" ]] && printf 'detected (hidden)' || printf 'not-detected')"
    fi
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
      iface_index=$(( iface_index + 1 ))
      if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
        printf 'qdiscs_on_%s: %s\n' "$iface" "$(default_route_qdiscs "$iface")"
      else
        printf 'qdiscs_on_default_%s: %s\n' "$iface_index" "$(default_route_qdiscs "$iface")"
      fi
    done

    if [[ -n "$TC_IFACE" && -n "$TC_RATE" ]]; then
      if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
        printf 'tc_shape: %s @ %s\n' "$TC_IFACE" "$TC_RATE"
      else
        printf 'tc_shape: configured @ %s (interface hidden)\n' "$TC_RATE"
      fi
      printf 'tc_qdisc_root: %s\n' "$(tc qdisc show dev "$TC_IFACE" 2>/dev/null | awk 'NR==1 {print; found=1} END{if(!found) print "unknown"}')"
    fi
  fi

  if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      printf 'fail2ban_service: %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo not-installed)"
    else
      printf 'fail2ban_service: %s\n' "unknown"
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
      printf 'fail2ban_jail_sshd: %s\n' "$(fail2ban-client status sshd 2>/dev/null | awk -F':[[:space:]]*' '/Status for the jail/ {print $2; found=1} END{if(!found) print "missing"}')"
      printf 'fail2ban_banned: %s\n' "$(fail2ban-client status sshd 2>/dev/null | awk -F':[[:space:]]*' '/Currently banned/ {print $2; found=1} END{if(!found) print "unknown"}')"
    else
      printf 'fail2ban_jail_sshd: %s\n' "not-installed"
      printf 'fail2ban_banned: %s\n' "unknown"
    fi
  fi
}

install_self() {
  local source

  source="$(readlink -f "$0" 2>/dev/null || true)"
  if [[ ! -f "$source" ]]; then
    log "warning: this run came from a pipe, so the vps-firstboot command was not installed"
    return 0
  fi
  [[ ! "$source" -ef "$SELF_PATH" ]] || return 0
  install -d -m 0755 "$(dirname "$SELF_PATH")"
  install -m 0755 "$source" "$SELF_PATH"
}

final_message() {
  local third_party

  printf '\nDone. The current verification status is shown above.\n'

  if security_part_enabled; then
    cat <<SSH_DONE

SSH now listens only on port $SSH_PORT. Log in from a second terminal to check:
  ssh -p $SSH_PORT $SSH_USER@SERVER_IP

If that fails, allow TCP $SSH_PORT in your provider's firewall or security group.
SSH_DONE
  fi

  if [[ "$SYSTEM_UPDATE_RESULT" == "failed" ]]; then
    printf '\nSystem update failed, so security updates are still missing. Fix apt, then rerun:\n  vps-firstboot security --port %s --yes\n' "$SSH_PORT"
  fi

  third_party="$(third_party_kernels)"
  if [[ -n "$third_party" ]]; then
    cat <<THIRD_PARTY

Third-party kernels are installed: $third_party
GRUB boots the highest version, so Debian's kernel security updates may never
take effect. Remove them with apt-get purge, then run update-grub.
THIRD_PARTY
  fi

  if reboot_required; then
    printf '\nA newer kernel or library was installed. Reboot when ready:\n  reboot\n'
  fi

  if [[ -n "$NETWORK_BACKUP_DIR" ]]; then
    cat <<ROLLBACK_DONE

Network rollback point:
  $NETWORK_BACKUP_DIR

To restore it without changing the kernel or SSH configuration:
  vps-firstboot network-rollback -y
ROLLBACK_DONE
  fi

  if network_part_enabled && [[ "$ENABLE_BDP_TUNE" == "yes" ]]; then
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

  case "$ACTION" in
    check)
      status_check
      exit 0
      ;;
    network-rollback)
      network_rollback
      exit 0
      ;;
  esac

  validate_inputs

  if [[ "$DRY_RUN" == "yes" ]]; then
    print_tcp_tune_dry_run
    exit 0
  fi

  print_plan
  case "$RUN_PART" in
    all) confirm "Proceed with Part 1 security initialization and Part 2 network tuning?" || die "aborted" ;;
    security) confirm "Proceed with Part 1 security initialization?" || die "aborted" ;;
    network) confirm "Proceed with Part 2 BBR/TCP/network tuning?" || die "aborted" ;;
  esac

  install_self

  if security_part_enabled; then
    wait_for_boot_tasks
    check_ssh_port_available
    install_authorized_keys
    configure_sshd
    system_update
    configure_locale
    if ! install_fail2ban; then
      log "warning: fail2ban setup failed; continuing with the remaining setup"
    fi
  fi

  if network_part_enabled; then
    network_backup_config
    configure_ipv4_preference
    configure_tcp_tune
    configure_tc_shaping
    install_bpftune
  fi
  show_verification_status
  final_message
}

main "$@"
