#!/usr/bin/env bash
set -Eeuo pipefail

# In-place recovery for the initial RelayWave Debian 13 test VM on Proxmox.
# Installs missing nftables, fixes explicit Podman image references and restarts the stack.
# Does not install anything on the Proxmox host or recreate the VM.
VMID="${1:-103}"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root on PVE1." >&2
  exit 1
fi
if ! command -v qm >/dev/null 2>&1; then
  echo "This script must run on a Proxmox VE host." >&2
  exit 1
fi
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
  echo "VMID must be numeric." >&2
  exit 1
fi
if ! qm status "$VMID" 2>/dev/null | grep -q '^status: running$'; then
  echo "VM $VMID is not running (or does not exist)." >&2
  exit 1
fi
NAME="$(qm config "$VMID" | sed -n 's/^name: //p')"
if [[ "$NAME" != "podcast-test" ]]; then
  echo "Refusing to modify VM $VMID: expected podcast-test, got '$NAME'." >&2
  exit 1
fi
if ! qm guest cmd "$VMID" ping >/dev/null 2>&1; then
  echo "QEMU guest agent on VM $VMID is not responding." >&2
  exit 1
fi

echo "Repairing RelayWave test VM $VMID ($NAME) in place..."
GUEST_COMMAND='
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v nft >/dev/null 2>&1; then
  echo "Installing missing nftables package..."
  apt-get update
  apt-get install -y --no-install-recommends nftables
fi
echo "nft executable: $(command -v nft)"
echo "Fixing short-name container image references..."
curl -fsSL --retry 3 https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/features/qualify-images.sh -o /root/relaywave-qualify-images.sh
bash /root/relaywave-qualify-images.sh /opt/opencast-test
echo "Installing the Podman DNS helper if missing..."
if ! dpkg-query -W -f='${Status}' aardvark-dns 2>/dev/null | grep -qx 'install ok installed'; then
  apt-get update
  apt-get install -y --no-install-recommends aardvark-dns
fi
echo "Fixing the Nostr relay executable and stale test container names..."
curl -fsSL --retry 3 https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/features/repair-runtime.sh -o /root/relaywave-repair-runtime.sh
bash /root/relaywave-repair-runtime.sh /opt/opencast-test
echo "Restarting application stack..."
if ! systemctl restart opencast-test.service; then
  echo "Service failed; recent service errors:"
  journalctl -u opencast-test.service --no-pager -n 65 || true
  exit 1
fi
sleep 3
systemctl is-active opencast-test.service
/opt/opencast-test/scripts/status.sh
source /etc/opencast-test.env
if curl -fsS --max-time 8 "http://$LAN_IP:8080/api/config" >/dev/null; then
  echo "SUCCESS: dashboard http://$LAN_IP:8080"
  echo "Blossom: http://$LAN_IP:8081"
  echo "Relay: ws://$LAN_IP:7447"
else
  echo "Dashboard is not yet responding. Inspect podman containers and logs."
  podman ps -a --format "{{.Names}} {{.Status}}" || true
  exit 1
fi
'

if ! RESPONSE="$(qm guest exec "$VMID" --timeout 900 -- /bin/bash -lc "$GUEST_COMMAND" 2>&1)"; then
  echo "Failed to run the repair inside the guest:" >&2
  printf '%s\n' "$RESPONSE" >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$RESPONSE" | python3 -c '
import json,sys
try:
    r=json.load(sys.stdin)
except ValueError:
    print("Unexpected guest-agent response; paste original JSON for diagnosis", file=sys.stderr)
    sys.exit(1)
for key in ("out-data", "err-data"):
    value=r.get(key)
    if value: print(value, end="" if value.endswith("\n") else "\n")
code=r.get("exitcode")
print("Guest command exit code:", code)
sys.exit(0 if code == 0 else 1)
'
else
  printf '%s\n' "$RESPONSE"
  echo "Check the JSON exitcode (0 means repair completed)."
fi
