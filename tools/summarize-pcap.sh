#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/summarize-pcap.sh <capture.pcap> [camera-ip]

Prints a compact packet timeline and a PTP-IP hex preview using tcpdump.
Install tshark/Wireshark later if deeper protocol dissection is needed.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

pcap="${1:-}"
camera_ip="${2:-}"

if [[ -z "$pcap" ]]; then
  usage >&2
  exit 64
fi

if [[ ! -f "$pcap" ]]; then
  echo "Capture not found: $pcap" >&2
  exit 66
fi

if [[ -n "$camera_ip" ]]; then
  timeline_filter="host ${camera_ip} or tcp port 15740"
else
  timeline_filter="tcp port 15740 or udp or icmp"
fi

echo "== Timeline =="
tcpdump -nn -tttt -r "$pcap" "$timeline_filter"

echo
echo "== PTP-IP hex preview =="
tcpdump -nn -tttt -XX -r "$pcap" "tcp port 15740"
