#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi
NEW_IP=${1:-}
if [[ -z "$NEW_IP" ]]; then
  echo "Usage: $0 192.168.1.80" >&2
  exit 1
fi
if ! [[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected an IPv4 address." >&2
  exit 1
fi
python3 - "$NEW_IP" <<'PY'
from pathlib import Path
import sys
ip=sys.argv[1]
p=Path('/etc/opencast-test.env')
lines=[]
for line in p.read_text().splitlines():
    if line.startswith('LAN_IP='): line=f'LAN_IP={ip}'
    elif line.startswith('PUBLIC_BASE_URL='): line=f'PUBLIC_BASE_URL=http://{ip}:8080'
    elif line.startswith('DEFAULT_BLOSSOM='): line=f'DEFAULT_BLOSSOM=http://{ip}:8081'
    elif line.startswith('DEFAULT_RELAYS='): line=f'DEFAULT_RELAYS=ws://{ip}:7447'
    lines.append(line)
p.write_text('\n'.join(lines)+'\n')
PY
systemctl restart opencast-test.service
echo "OpenCast LAN IP updated to $NEW_IP"
