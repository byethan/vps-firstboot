#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/vps-firstboot.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || {
    printf 'missing expected text: %s\n' "$expected" >&2
    sed -n '1,120p' "$file" >&2
    exit 1
  }
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    printf 'unexpected text found: %s\n' "$unexpected" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  fi
}

preview() {
  local name="$1"
  shift
  bash "$SCRIPT" --network-only "$@" --dry-run >"$TEST_TMP/$name"
}

bash -n "$SCRIPT"
bash -n "$REPO_DIR/vps-security.sh"
bash -n "$REPO_DIR/vps-network-tune.sh"
bash -n "$REPO_DIR/vps-speedtest.sh"
bash -n "$REPO_DIR/vps-fleet-bbrv3.sh"

assert_contains "$SCRIPT" 'release asset $name has no usable GitHub SHA-256 digest'
assert_contains "$SCRIPT" 'BBRV3_STATE_ROOT"/*/packages.tsv'
assert_not_contains "$SCRIPT" "awk '/bbr|joey|7\\./"
assert_not_contains "$SCRIPT" '    /etc/sysctl.d \'

preview general --role general --region asia --bandwidth 1000
assert_contains "$TEST_TMP/general" "tcp sysctl:       minimal / system buffers"
assert_contains "$TEST_TMP/general" "net.ipv4.tcp_congestion_control = bbr"

preview transit --role transit --region asia --bandwidth 625
assert_contains "$TEST_TMP/transit" "tcp sysctl:       smart / 12MiB"
assert_contains "$TEST_TMP/transit" "net.ipv4.tcp_mtu_probing = 1"
assert_not_contains "$TEST_TMP/transit" "net.ipv4.tcp_limit_output_bytes"

preview transit-minimal --role transit --region asia --bandwidth 625 --no-smart-tune
assert_contains "$TEST_TMP/transit-minimal" "tcp sysctl:       minimal / system buffers"
assert_not_contains "$TEST_TMP/transit-minimal" "net.ipv4.tcp_limit_output_bytes"
if grep -Fq -- "net.core.rmem_max" "$TEST_TMP/transit-minimal"; then
  printf 'transit --no-smart-tune unexpectedly wrote buffer limits\n' >&2
  exit 1
fi

preview exit --role exit --region overseas --bandwidth 1000
assert_contains "$TEST_TMP/exit" "tcp sysctl:       smart / 64MiB"
assert_contains "$TEST_TMP/exit" "net.ipv4.ip_local_port_range = 10240 65535"

preview web --role web --region asia --bandwidth 10000
assert_contains "$TEST_TMP/web" "tcp sysctl:       web-conservative / system buffers"
assert_contains "$TEST_TMP/web" "net.core.somaxconn = 8192"
assert_contains "$TEST_TMP/web" "net.ipv4.tcp_max_syn_backlog = 8192"
assert_not_contains "$TEST_TMP/web" "net.ipv4.tcp_slow_start_after_idle"

preview bdp --role exit --region asia --bandwidth 1000 --bdp-bandwidth 1000 --bdp-rtt 80
assert_contains "$TEST_TMP/bdp" "tcp sysctl:       bdp-2x / 20000000 bytes"
assert_contains "$TEST_TMP/bdp" "net.core.rmem_max = 20000000"

preview single --role transit --objective single-stream --target-mbps 625 --rtt-ms 80 --region asia
assert_contains "$TEST_TMP/single" "objective:        single-stream"
assert_contains "$TEST_TMP/single" "tcp sysctl:       bdp-2x / 12500000 bytes"
assert_contains "$TEST_TMP/single" "smart tune:       no"

preview throughput --role transit --objective throughput --target-mbps 1000 --rtt-ms 80 --region asia
assert_contains "$TEST_TMP/throughput" "tcp sysctl:       bdp-3x / 30000000 bytes"

preview custom --role general --buffer-mib 32
assert_contains "$TEST_TMP/custom" "tcp sysctl:       custom / 32MiB / 33554432 bytes"
assert_contains "$TEST_TMP/custom" "net.core.rmem_max = 33554432"

if bash "$SCRIPT" network --role general --buffer-mib 128 --dry-run >"$TEST_TMP/unsafe-buffer" 2>&1; then
  printf 'unsafe manual buffer unexpectedly succeeded without an override\n' >&2
  exit 1
fi
assert_contains "$TEST_TMP/unsafe-buffer" "RAM-derived safety cap"

bash "$SCRIPT" network --role general --buffer-mib 128 --allow-unsafe-buffer --dry-run >"$TEST_TMP/unsafe-allowed"
assert_contains "$TEST_TMP/unsafe-allowed" "custom / 128MiB"

TEST_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTONLYREDACTED unique-private-comment'
printf '%s\n' "$TEST_PUBLIC_KEY" | bash "$SCRIPT" security --port 22222 --public-key-stdin --dry-run >"$TEST_TMP/security"
assert_contains "$TEST_TMP/security" "Part 1 / VPS security"
assert_contains "$TEST_TMP/security" "provided (content hidden)"
assert_not_contains "$TEST_TMP/security" "unique-private-comment"
assert_not_contains "$TEST_TMP/security" "/etc/sysctl.d/90-vps-bbr-fq.conf"

if bash "$SCRIPT" security --dry-run >"$TEST_TMP/security-no-port" 2>&1; then
  printf 'explicit security mode unexpectedly succeeded without an SSH port\n' >&2
  exit 1
fi
assert_contains "$TEST_TMP/security-no-port" "--port is required"

preview fq-layout --role general
assert_contains "$TEST_TMP/fq-layout" "pfifo|pfifo_fast|bfifo|fq_codel"
assert_contains "$TEST_TMP/fq-layout" "*) continue ;;"

if bash "$SCRIPT" --network-only --role invalid --region asia --bandwidth 1000 --dry-run >"$TEST_TMP/invalid" 2>&1; then
  printf 'invalid role unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$TEST_TMP/invalid" "--role must be general, transit, exit, or web"

if bash "$SCRIPT" network-rollback -y >"$TEST_TMP/network-rollback" 2>&1; then
  printf 'network rollback unexpectedly succeeded without a server backup\n' >&2
  exit 1
fi
if grep -Fq -- "--port is required" "$TEST_TMP/network-rollback"; then
  printf 'network rollback was incorrectly routed through setup validation\n' >&2
  exit 1
fi

printf 'vps-firstboot dry-run tests passed\n'
