#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE="${1:-}"

PORT="${IPERF_PORT:-5201}"
PARALLEL="${IPERF_PARALLEL:-4}"
DURATION="${IPERF_DURATION:-30}"
SITE_PING_COUNT="${SITE_PING_COUNT:-4}"
SITE_PING_TIMEOUT="${SITE_PING_TIMEOUT:-3}"
SHOW_SENSITIVE="${SHOW_SENSITIVE:-no}"
SERVER_HOST=""
SITE_TARGETS=()
DEFAULT_SITE_TARGETS=(
  "Google|www.google.com"
  "YouTube|www.youtube.com"
  "GitHub|github.com"
  "Apple|www.apple.com"
  "Microsoft|www.microsoft.com"
  "Cloudflare|www.cloudflare.com"
  "OpenAI|chatgpt.com"
  "Telegram|telegram.org"
  "Netflix|www.netflix.com"
  "TikTok|www.tiktok.com"
  "X|x.com"
  "AWS|aws.amazon.com"
  "Steam|store.steampowered.com"
  "NodeSeek|www.nodeseek.com"
)

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
  bash vps-speedtest.sh single <vps-ip-or-domain> [--port 5201] [-t 30]
  bash vps-speedtest.sh client <vps-ip-or-domain> [--port 5201] [-P 4] [-t 30]
  bash vps-speedtest.sh compare <vps-ip-or-domain> [--port 5201] [-P 4] [-t 30]
  bash vps-speedtest.sh sites [--count 4] [--timeout 3] [host...]

Modes:
  server    Run an iperf3 server on the VPS.
  single    Run privacy-safe upload/download tests with exactly one TCP stream.
  client    Run upload/download tests with the configured stream count.
  compare   Compare one TCP stream with the configured multi-stream count.
  sites     Test latency from the current machine to major websites.

Examples:
  # On the VPS:
  bash vps-speedtest.sh server --port 5201

  # At home:
  bash vps-speedtest.sh single vps.example.net --port 5201 -t 30
  bash vps-speedtest.sh compare vps.example.net --port 5201 -P 4 -t 30

  # On a landing VPS:
  bash vps-speedtest.sh sites
  bash vps-speedtest.sh sites --count 6 github.com chatgpt.com

Privacy:
  --show-sensitive prints full iperf/ping/route diagnostics, including endpoints.

Environment variables:
  IPERF_PORT, IPERF_PARALLEL, IPERF_DURATION, SITE_PING_COUNT, SITE_PING_TIMEOUT,
  SHOW_SENSITIVE
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
      --show-sensitive)
        SHOW_SENSITIVE="yes"
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

parse_client_args() {
  [[ $# -ge 1 ]] || die "client mode requires <vps-ip-or-domain>"
  SERVER_HOST="$1"
  [[ "$SERVER_HOST" =~ ^[A-Za-z0-9._:%-]+$ ]] || die "target contains unsupported characters"
  shift
  parse_common_args "$@"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "port must be from 1 to 65535"
  [[ "$PARALLEL" =~ ^[0-9]+$ ]] && (( PARALLEL >= 1 && PARALLEL <= 64 )) || die "parallel streams must be from 1 to 64"
  [[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 1 && DURATION <= 3600 )) || die "duration must be from 1 to 3600 seconds"
  [[ "$SHOW_SENSITIVE" =~ ^(yes|no)$ ]] || die "SHOW_SENSITIVE must be yes or no"
}

parse_sites_args() {
  SITE_TARGETS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --count|-c)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        SITE_PING_COUNT="$2"
        shift 2
        ;;
      --timeout|-W)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        SITE_PING_TIMEOUT="$2"
        shift 2
        ;;
      --show-sensitive)
        SHOW_SENSITIVE="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          SITE_TARGETS+=("$1|$1")
          shift
        done
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        SITE_TARGETS+=("$1|$1")
        shift
        ;;
    esac
  done

  [[ "$SITE_PING_COUNT" =~ ^[0-9]+$ ]] || die "--count must be a positive integer"
  [[ "$SITE_PING_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer"
  (( SITE_PING_COUNT >= 1 && SITE_PING_COUNT <= 20 )) || die "--count must be from 1 to 20"
  (( SITE_PING_TIMEOUT >= 1 && SITE_PING_TIMEOUT <= 30 )) || die "--timeout must be from 1 to 30 seconds"
  [[ "$SHOW_SENSITIVE" =~ ^(yes|no)$ ]] || die "SHOW_SENSITIVE must be yes or no"

  if [[ ${#SITE_TARGETS[@]} -eq 0 ]]; then
    SITE_TARGETS=("${DEFAULT_SITE_TARGETS[@]}")
  fi
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
  local ping_output
  log "latency check: ping $([[ "$SHOW_SENSITIVE" == "yes" ]] && printf '%s' "$SERVER_HOST" || printf '[target hidden]')"
  if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
    ping -c 10 "$SERVER_HOST" || true
  else
    ping_output="$(LC_ALL=C ping -c 10 "$SERVER_HOST" 2>&1 || true)"
    printf '%s\n' "$ping_output" | sed -n '/packet loss/p;/min\/avg/p;/round-trip/p'
  fi

  if have_cmd mtr && [[ "$SHOW_SENSITIVE" == "yes" ]]; then
    log "route check: mtr ${SERVER_HOST}"
    mtr -rwzc 50 "$SERVER_HOST" || true
  elif have_cmd mtr; then
    log "route details hidden; rerun with --show-sensitive if mtr diagnostics are needed"
  else
    log "mtr not found; skipping route loss/jitter check"
  fi
}

iperf_json_number() {
  local json="$1"
  local section="$2"
  local key="$3"
  printf '%s\n' "$json" | awk -v section="\"$section\"" -v key="\"$key\"" '
    index($0, section) { active=1; next }
    active && index($0, key) {
      line=$0
      sub(/^.*:[[:space:]]*/, "", line)
      sub(/[,[:space:]].*$/, "", line)
      print line
      exit
    }
  '
}

run_iperf_direction() {
  local direction="$1"
  local streams="$2"
  local label
  local output
  local rc
  local bps
  local retransmits

  if [[ "$direction" == "download" ]]; then
    label="VPS -> client download"
  else
    label="client -> VPS upload"
  fi

  log "testing $label: $streams stream(s), ${DURATION}s, target $([[ "$SHOW_SENSITIVE" == "yes" ]] && printf '%s:%s' "$SERVER_HOST" "$PORT" || printf '[hidden]')"
  if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
    if [[ "$direction" == "download" ]]; then
      iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$streams" -t "$DURATION" -R
    else
      iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$streams" -t "$DURATION"
    fi
    return
  fi

  set +e
  if [[ "$direction" == "download" ]]; then
    output="$(iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$streams" -t "$DURATION" -R --json 2>/dev/null)"
  else
    output="$(iperf3 -c "$SERVER_HOST" -p "$PORT" -P "$streams" -t "$DURATION" --json 2>/dev/null)"
  fi
  rc=$?
  set -e
  if (( rc != 0 )); then
    log "ERROR: iperf3 test failed; rerun with --show-sensitive for endpoint/error details"
    return "$rc"
  fi

  bps="$(iperf_json_number "$output" sum_received bits_per_second)"
  retransmits="$(iperf_json_number "$output" sum_sent retransmits)"
  [[ "$bps" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "iperf3 returned no usable throughput summary"
  [[ "$retransmits" =~ ^[0-9]+$ ]] || retransmits="n/a"
  awk -v label="$label" -v streams="$streams" -v bps="$bps" -v retrans="$retransmits" \
    'BEGIN {printf "%s: %.2f Mbps, streams=%s, retransmits=%s\n", label, bps/1000000, streams, retrans}'
}

run_client_profile() {
  local streams="$1"
  run_iperf_direction upload "$streams"
  printf '\n'
  run_iperf_direction download "$streams"
}

run_client() {
  shift
  parse_client_args "$@"
  install_iperf3

  run_client_profile "$PARALLEL"
  printf '\n'
  run_latency_checks
}

run_single() {
  shift
  parse_client_args "$@"
  install_iperf3
  run_client_profile 1
  printf '\n'
  run_latency_checks
}

run_compare() {
  shift
  parse_client_args "$@"
  install_iperf3
  log "single-stream baseline"
  run_client_profile 1
  printf '\n'
  log "multi-stream comparison"
  run_client_profile "$PARALLEL"
  printf '\n'
  run_latency_checks
}

ping_site() {
  local label="$1"
  local host="$2"
  local output
  local rc
  local loss
  local avg
  local stats
  local deadline
  local -a ping_cmd
  local display_host

  if [[ "$SHOW_SENSITIVE" == "yes" ]]; then
    display_host="$host"
  else
    display_host="[hidden]"
  fi

  deadline=$(( SITE_PING_COUNT * SITE_PING_TIMEOUT + 3 ))

  set +e
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ping_cmd=(ping -c "$SITE_PING_COUNT" -W "$((SITE_PING_TIMEOUT * 1000))" "$host")
  else
    ping_cmd=(ping -c "$SITE_PING_COUNT" -W "$SITE_PING_TIMEOUT" "$host")
  fi

  if have_cmd timeout; then
    output="$(LC_ALL=C timeout "$deadline" "${ping_cmd[@]}" 2>&1 | sed -n '1,120p')"
  elif have_cmd gtimeout; then
    output="$(LC_ALL=C gtimeout "$deadline" "${ping_cmd[@]}" 2>&1 | sed -n '1,120p')"
  elif have_cmd perl; then
    output="$(LC_ALL=C perl -e '
      my $deadline = shift @ARGV;
      my $pid;
      $SIG{ALRM} = sub {
        kill "TERM", $pid if $pid;
        exit 124;
      };
      alarm $deadline;
      $pid = open(my $fh, "-|", @ARGV);
      exit 127 unless $pid;
      my $lines = 0;
      while (my $line = <$fh>) {
        print $line if $lines < 120;
        $lines++;
      }
      close($fh);
      exit(($? >> 8) || 0);
    ' "$deadline" "${ping_cmd[@]}" 2>&1)"
  else
    output="$(LC_ALL=C "${ping_cmd[@]}" 2>&1 | sed -n '1,120p')"
  fi
  rc=$?
  set -e

  loss="$(printf '%s\n' "$output" | sed -n 's/.* \([0-9.]*%\) packet loss.*/\1/p' | tail -n 1)"
  stats="$(printf '%s\n' "$output" | sed -n 's/.*= \([^ ]*\) ms.*/\1/p' | tail -n 1)"
  avg="$(printf '%s\n' "$stats" | cut -d/ -f2)"

  if [[ -z "$loss" ]]; then
    loss="n/a"
  fi

  if [[ "$rc" -eq 0 && -n "$avg" ]]; then
    printf '%-12s %-32s %10s %10s\n' "$label" "$display_host" "${avg}ms" "$loss"
  else
    printf '%-12s %-32s %10s %10s\n' "$label" "$display_host" "failed" "$loss"
  fi
}

run_sites() {
  local item
  local label
  local host

  shift
  parse_sites_args "$@"

  log "testing major-site latency: ${SITE_PING_COUNT} pings, ${SITE_PING_TIMEOUT}s timeout"
  printf '%-12s %-32s %10s %10s\n' "site" "host" "avg" "loss"
  printf '%-12s %-32s %10s %10s\n' "----" "----" "---" "----"

  for item in "${SITE_TARGETS[@]}"; do
    label="${item%%|*}"
    host="${item#*|}"
    ping_site "$label" "$host"
  done
}

case "$MODE" in
  server)
    run_server "$@"
    ;;
  single)
    run_single "$@"
    ;;
  client)
    run_client "$@"
    ;;
  compare)
    run_compare "$@"
    ;;
  sites)
    run_sites "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
