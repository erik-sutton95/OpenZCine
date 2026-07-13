#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/capture-ios-rvi.sh <label> <ios-device-id> [camera-ip]

Examples:
  tools/capture-ios-rvi.sh pairing-flow <ios-device-id>
  tools/capture-ios-rvi.sh connect-flow <ios-device-id> 172.20.10.2

Captures local/private-network traffic from an iOS device through Apple's
Remote Virtual Interface (rvi0). Press Ctrl-C after reproducing the flow.

Output:
  captures/YYYYMMDD-HHMMSS-<label>.pcap
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

label="${1:-}"
device_id="${2:-}"
camera_ip="${3:-}"

if [[ -z "$label" || -z "$device_id" ]]; then
  usage >&2
  exit 64
fi

mkdir -p captures

if ! ifconfig rvi0 >/dev/null 2>&1; then
  rvictl -s "$device_id"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
outfile="captures/${timestamp}-${label}.pcap"

if [[ -n "$camera_ip" ]]; then
  filter="host ${camera_ip} or multicast"
else
  filter="net 10.0.0.0/8 or net 172.16.0.0/12 or net 192.168.0.0/16 or multicast"
fi

cat <<EOF
Capturing iOS traffic on rvi0.
Label:  ${label}
Output: ${outfile}
Filter: ${filter}

Reproduce the scan/pair/connect flow now, then press Ctrl-C to stop.
EOF

sudo tcpdump -i rvi0 -s 0 -U -w "$outfile" "$filter"
