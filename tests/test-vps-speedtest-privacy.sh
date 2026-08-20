#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/vps-speedtest.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

iperf3() {
  cat <<'JSON'
{
  "start": {"connecting_to": {"host": "private-target.example"}},
  "end": {
    "sum_sent": {
      "bits_per_second": 101000000,
      "retransmits": 2
    },
    "sum_received": {
      "bits_per_second": 100000000
    }
  }
}
JSON
}

ping() {
  cat <<'PING'
PING private-target.example (192.0.2.10): 56 data bytes
10 packets transmitted, 10 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 10.000/12.000/15.000/1.000 ms
PING
}

export -f iperf3 ping

bash "$SCRIPT" compare private-target.example --port 5201 -P 4 -t 1 >"$TEST_TMP/output"

grep -Fq 'client -> VPS upload: 100.00 Mbps, streams=1, retransmits=2' "$TEST_TMP/output"
grep -Fq 'VPS -> client download: 100.00 Mbps, streams=4, retransmits=2' "$TEST_TMP/output"
grep -Fq 'round-trip min/avg/max/stddev = 10.000/12.000/15.000/1.000 ms' "$TEST_TMP/output"

if grep -Fq 'private-target.example' "$TEST_TMP/output" || grep -Fq '192.0.2.10' "$TEST_TMP/output"; then
  printf 'privacy-safe speed test leaked the endpoint\n' >&2
  sed -n '1,160p' "$TEST_TMP/output" >&2
  exit 1
fi

printf 'vps-speedtest privacy tests passed\n'
