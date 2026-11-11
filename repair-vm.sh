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
GUEST_COMMAND="$(cat <<'GUEST_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v nft >/dev/null 2>&1; then
  echo "Installing missing nftables package..."
  apt-get update
  apt-get install -y --no-install-recommends nftables
fi
echo "nft executable: $(command -v nft)"
echo "Fixing short-name container image references..."
REF=__RW_REF__
SHA_QUALIFY_IMAGES_SH=afd0e76b2cf3a8143fd65adf3afc152145072d3ca41c3e04a5ccc32797732345
SHA_REPAIR_RUNTIME_V2_SH=8a9bbb0564d267bbd6f968755f36dab0bd46da2fe86875eaf677300de14b328c
rw_fetch() { # rw_fetch <path in repo> <sha256> <destination>
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/$REF/$1" -o "$3.download"
  echo "$2  $3.download" | sha256sum --check --status || {
    rm -f "$3.download"
    echo "Checksum mismatch for $1 at ref '$REF'; refusing to use it." >&2
    exit 1
  }
  mv "$3.download" "$3"
}
rw_fetch features/qualify-images.sh "$SHA_QUALIFY_IMAGES_SH" /root/relaywave-qualify-images.sh
bash /root/relaywave-qualify-images.sh /opt/opencast-test
echo "Installing the Podman DNS helper if missing..."
if ! dpkg-query -W -f='${Status}' aardvark-dns 2>/dev/null | grep -qx 'install ok installed'; then
  apt-get update
  apt-get install -y --no-install-recommends aardvark-dns
fi
echo "Fixing the Nostr relay executable and stale test container names..."
rw_fetch features/repair-runtime-v2.sh "$SHA_REPAIR_RUNTIME_V2_SH" /root/relaywave-repair-runtime-v2.sh
bash /root/relaywave-repair-runtime-v2.sh /opt/opencast-test
echo "Restarting application stack..."
if ! systemctl restart opencast-test.service; then
  echo "Service failed; recent service errors:"
  journalctl -u opencast-test.service --no-pager -n 65 || true
  exit 1
fi
sleep 3
systemctl is-active opencast-test.service
/opt/opencast-test/scripts/status.sh
LAN_IP="$(sed -n 's/^LAN_IP=//p' /etc/opencast-test.env | head -n 1)"
if curl -fsS --max-time 8 "http://$LAN_IP:8080/api/config" >/dev/null; then
  echo "SUCCESS: dashboard http://$LAN_IP:8080"
  echo "Blossom: http://$LAN_IP:8081"
  echo "Relay: ws://$LAN_IP:7447"
else
  echo "Dashboard is not yet responding. Inspect podman containers and logs."
  podman ps -a --format "{{.Names}} {{.Status}}" || true
  exit 1
fi
GUEST_SCRIPT
)"
# Downloads inside the guest are verified against the digests above.
REF="${RELAYWAVE_REF:-main}"
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || { echo "Invalid RELAYWAVE_REF" >&2; exit 1; }
GUEST_COMMAND="${GUEST_COMMAND//__RW_REF__/$REF}"

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
