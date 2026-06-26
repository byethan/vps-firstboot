#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE="${1:-}"

PORT="${IPERF_PORT:-5201}"
PARALLEL="${IPERF_PARALLEL:-4}"
DURATION="${IPERF_DURATION:-30}"
SERVER_HOST=""

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  bash vps-speedtest.sh server [--port 5201]
  bash vps-speedtest.sh client <vps-ip-or-domain> [--port 5201] [-P 4] [-t 30]

Modes:
  server    Run an iperf3 server on the VPS.
  client    Run home-to-VPS upload/download tests from your local machine.

Examples:
  # On the VPS:
  bash vps-speedtest.sh server --port 5201

  # At home:
  bash vps-speedtest.sh client 1.2.3.4 --port 5201 -P 4 -t 30

Environment variables:
  IPERF_PORT, IPERF_PARALLEL, IPERF_DURATION
USAGE
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    die "need root permission to install packages; rerun as root or install iperf3 manually"
  fi
}

install_iperf3() {
  if have_cmd iperf3; then
    return 0
  fi

  log "iperf3 not found; trying to install it"

  if have_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y iperf3
  elif have_cmd dnf; then
    as_root dnf install -y iperf3
  elif have_cmd yum; then
    as_root yum install -y iperf3
  elif have_cmd apk; then
    as_root apk add iperf3
  elif have_cmd brew; then
    brew install iperf3
  else
    die "could not find a supported package manager; please install iperf3 first"
  fi
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port|-p)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        PORT="$2"
        shift 2
        ;;
      -P|--parallel)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        PARALLEL="$2"
        shift 2
        ;;
      -t|--time|--duration)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        DURATION="$2"
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
}

parse_client_args() {
  [[ $# -ge 1 ]] || die "client mode requires <vps-ip-or-domain>"
  SERVER_HOST="$1"
  shift
  parse_common_args "$@"
}

open_firewall_hint() {
  cat <<EOF

If the client cannot connect, allow TCP port ${PORT} on the VPS firewall/security group.
Common commands:
  ufw allow ${PORT}/tcp
  firewall-cmd --permanent --add-port=${PORT}/tcp && firewall-cmd --reload

Cloud panels also need an inbound TCP rule for port ${PORT}.
EOF
}

run_server() {
  shift
  parse_common_args "$@"
  install_iperf3

  log "starting iperf3 server on TCP port ${PORT}"
  log "keep this SSH window open while testing from home"
  open_firewall_hint
  exec iperf3 -s -p "$PORT"
}

run_latency_checks() {
  log "latency check: ping ${SERVER_HOST}"
  ping -c 10 "$SERVER_HOST" || true

  if have_cmd mtr; then
    log "route check: mtr ${SERVER_HOST}"
    mtr -rwzc 50 "$SERVER_HOST" || true
  else
    log "mtr not found; skipping route loss/jitter check"
  fi
}

run_client() {
  shift
  parse_client_args "$@"
  install_iperf3

  log "testing home -> VPS upload: ${SERVER_HOST}:${PORT}, ${PARALLEL} streams, ${DURATION}s"
  iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$PARALLEL" -t "$DURATION"

  printf '\n'
  log "testing VPS -> home download: ${SERVER_HOST}:${PORT}, ${PARALLEL} streams, ${DURATION}s"
  iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$PARALLEL" -t "$DURATION" -R

  printf '\n'
  run_latency_checks
}

case "$MODE" in
  server)
    run_server "$@"
    ;;
  client)
    run_client "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
