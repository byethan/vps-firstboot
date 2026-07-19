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

preview() {
  local name="$1"
  shift
  bash "$SCRIPT" --network-only "$@" --dry-run >"$TEST_TMP/$name"
}

bash -n "$SCRIPT"

preview general --role general --region asia --bandwidth 1000
assert_contains "$TEST_TMP/general" "tcp sysctl:       minimal / system buffers"
assert_contains "$TEST_TMP/general" "net.ipv4.tcp_congestion_control = bbr"

preview transit --role transit --region asia --bandwidth 625
assert_contains "$TEST_TMP/transit" "tcp sysctl:       smart / 12MiB"
assert_contains "$TEST_TMP/transit" "net.ipv4.tcp_limit_output_bytes = 4194304"
assert_contains "$TEST_TMP/transit" "net.ipv4.tcp_mtu_probing = 1"

preview transit-minimal --role transit --region asia --bandwidth 625 --no-smart-tune
assert_contains "$TEST_TMP/transit-minimal" "tcp sysctl:       minimal / system buffers"
assert_contains "$TEST_TMP/transit-minimal" "net.ipv4.tcp_limit_output_bytes = 4194304"
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

preview bdp --role exit --region asia --bandwidth 1000 --bdp-bandwidth 1000 --bdp-rtt 80
assert_contains "$TEST_TMP/bdp" "tcp sysctl:       bdp / 10000000 bytes"
assert_contains "$TEST_TMP/bdp" "net.core.rmem_max = 10000000"

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
