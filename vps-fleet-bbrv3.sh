#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
RAW_FIRSTBOOT_URL="${RAW_FIRSTBOOT_URL:-https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh}"
DEFAULT_PORT="${SSH_PORT:-22928}"
BATCH_SIZE="${BATCH_SIZE:-2}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

usage() {
  cat <<'USAGE'
Usage:
  bash vps-fleet-bbrv3.sh <hosts-file> audit
  bash vps-fleet-bbrv3.sh <hosts-file> install
  bash vps-fleet-bbrv3.sh <hosts-file> rolling-reboot [--batch-size 2]
  bash vps-fleet-bbrv3.sh <hosts-file> verify

Hosts file formats:
  user@host
  user@host port
  name user@host port

Examples:
  hk1 root@1.2.3.4 22928
  jp1 root@2001:db8::10 22928
  root@example.com

Environment:
  RAW_FIRSTBOOT_URL   URL of vps-firstboot.sh
  SSH_PORT            Default SSH port. Default: 22928
  BATCH_SIZE          rolling-reboot batch size. Default: 2
USAGE
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

parse_host_line() {
  local line="$1"
  local first second third
  read -r first second third _rest <<<"$line"

  [[ -n "${first:-}" ]] || return 1
  [[ "$first" == \#* ]] && return 1

  if [[ "$first" == *@* ]]; then
    HOST_NAME="$first"
    SSH_TARGET="$first"
    SSH_PORT_VALUE="${second:-$DEFAULT_PORT}"
  else
    HOST_NAME="$first"
    SSH_TARGET="${second:-}"
    SSH_PORT_VALUE="${third:-$DEFAULT_PORT}"
  fi

  [[ -n "$SSH_TARGET" ]] || return 1
  [[ "$SSH_PORT_VALUE" =~ ^[0-9]+$ ]] || die "invalid SSH port for $HOST_NAME: $SSH_PORT_VALUE"
  return 0
}

remote_ssh() {
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT_VALUE" "$SSH_TARGET" "$@"
}

remote_firstboot() {
  local action="$1"
  remote_ssh "curl -fsSL '$RAW_FIRSTBOOT_URL' -o /root/vps-firstboot.sh || wget -O /root/vps-firstboot.sh '$RAW_FIRSTBOOT_URL'; bash /root/vps-firstboot.sh $action -y"
}

for_each_host() {
  local hosts_file="$1"
  local fn="$2"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_host_line "$line" || continue
    "$fn"
  done <"$hosts_file"
}

do_audit_host() {
  log "audit $HOST_NAME ($SSH_TARGET:$SSH_PORT_VALUE)"
  remote_ssh 'uname -a; cat /etc/os-release | sed -n "1,6p"; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true; modinfo tcp_bbr 2>/dev/null | grep "^version:" || true'
}

do_install_host() {
  log "install BBRv3 on $HOST_NAME ($SSH_TARGET:$SSH_PORT_VALUE)"
  remote_firstboot install
}

do_verify_host() {
  log "verify $HOST_NAME ($SSH_TARGET:$SSH_PORT_VALUE)"
  remote_firstboot check
}

wait_ssh_down() {
  local tries=12
  while (( tries > 0 )); do
    if ! remote_ssh true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    tries=$((tries - 1))
  done
}

wait_ssh_up() {
  local tries=72
  while (( tries > 0 )); do
    if remote_ssh true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    tries=$((tries - 1))
  done
  return 1
}

rolling_reboot() {
  local hosts_file="$1"
  local -a batch_lines=()
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_host_line "$line" || continue
    batch_lines+=("$line")
    if (( ${#batch_lines[@]} >= BATCH_SIZE )); then
      reboot_batch "${batch_lines[@]}"
      batch_lines=()
    fi
  done <"$hosts_file"

  if (( ${#batch_lines[@]} > 0 )); then
    reboot_batch "${batch_lines[@]}"
  fi
}

reboot_batch() {
  local -a lines=("$@")
  local line
  local failed=0

  log "rebooting batch of ${#lines[@]}"
  for line in "${lines[@]}"; do
    parse_host_line "$line" || continue
    log "reboot $HOST_NAME"
    remote_ssh 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true
  done

  for line in "${lines[@]}"; do
    parse_host_line "$line" || continue
    log "waiting for $HOST_NAME to leave SSH"
    wait_ssh_down || true
  done

  for line in "${lines[@]}"; do
    parse_host_line "$line" || continue
    log "waiting for $HOST_NAME to return"
    if wait_ssh_up; then
      do_verify_host
    else
      log "ERROR: $HOST_NAME did not return over SSH"
      failed=1
    fi
  done

  (( failed == 0 )) || die "rolling reboot stopped because a host failed verification"
}

main() {
  local hosts_file="${1:-}"
  local action="${2:-}"
  shift 2 || true

  [[ -n "$hosts_file" && -n "$action" ]] || { usage; exit 1; }
  [[ -r "$hosts_file" ]] || die "cannot read hosts file: $hosts_file"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --batch-size)
        [[ $# -ge 2 ]] || die "--batch-size requires a value"
        BATCH_SIZE="$2"
        shift 2
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

  [[ "$BATCH_SIZE" =~ ^[0-9]+$ && "$BATCH_SIZE" -ge 1 ]] || die "batch size must be >= 1"

  case "$action" in
    audit)
      for_each_host "$hosts_file" do_audit_host
      ;;
    install)
      for_each_host "$hosts_file" do_install_host
      ;;
    rolling-reboot)
      rolling_reboot "$hosts_file"
      ;;
    verify)
      for_each_host "$hosts_file" do_verify_host
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
