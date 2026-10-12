#!/usr/bin/env bash
set -u

# Read-only RelayWave diagnostic helper. Run as root on the PVE host.
# Never collects VM passwords, cloud-init user-data or private keys.
if [[ "${EUID:-$(id -u)}" != 0 ]]; then echo "Run as root on PVE1."; exit 1; fi
if ! command -v qm >/dev/null 2>&1; then echo "Proxmox qm tool not found."; exit 1; fi

echo "===== Host ====="
hostname
pveversion 2>&1 | head -n 2
echo
echo "===== Possible RelayWave VMs ====="
qm list 2>&1 | head -n 30
echo
VMID="${1:-}"
if [[ -z "$VMID" ]]; then
  mapfile -t FOUND < <(qm list 2>/dev/null | awk 'NR>1 && ($2=="podcast-test" || $2=="relaywave") {print $1}')
  if [[ ${#FOUND[@]} == 1 ]]; then VMID="${FOUND[0]}"; fi
fi
if [[ -z "$VMID" ]]; then
  echo "No unique 'podcast-test' or 'relaywave' VM detected."
  echo "If the installer stopped before VM creation, please share its last error lines."
  echo "If it created a VM with a custom name, run: bash diagnose.sh <VMID>"
  exit 0
fi
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then echo "Invalid VMID."; exit 1; fi

echo "===== VM $VMID ====="
qm status "$VMID" 2>&1 || exit 1
# Exclude credentials, cloud-init text, and private data.
qm config "$VMID" 2>/dev/null | grep -E '^(name|boot|ide2|scsi0|net0|ipconfig0|agent|memory|cores|cicustom):' | sed -E 's@^(cicustom:).*@\1 [configured, content hidden]@'
echo
echo "===== QEMU guest-agent ====="
if ! qm guest cmd "$VMID" ping >/dev/null 2>&1; then
  echo "Guest agent unavailable. VM may still be booting, have no network, or Cloud-Init did not install qemu-guest-agent."
  echo "Open the Proxmox VM console and run:"
  echo "  sudo cloud-init status --long"
  echo "  sudo tail -n 70 /var/log/cloud-init-output.log"
  echo "  sudo tail -n 70 /var/log/opencast-bootstrap.log"
  exit 0
fi

echo "===== Guest bootstrap/cloud-init/service diagnostics ====="
CMD='echo "[Cloud-Init]"; cloud-init status --long 2>&1 || true; echo "[Bootstrap tail]"; if [ -f /var/log/opencast-bootstrap.log ]; then tail -n 80 /var/log/opencast-bootstrap.log; else echo "No bootstrap log yet"; fi; echo "[Podman]"; command -v podman && podman --version || true; echo "[Service]"; systemctl --no-pager --full status opencast-test.service 2>&1 | tail -n 45 || true; echo "[Containers]"; podman ps -a --format "{{.Names}} {{.Status}}" 2>&1 | head -n 30 || true; echo "[App check]"; if [ -f /etc/opencast-test.env ]; then . /etc/opencast-test.env; curl -sS --max-time 3 -o /dev/null -w "HTTP %{http_code}\\n" "http://$LAN_IP:8080/api/config" || true; else echo "Guest install has not written env file"; fi'
qm guest exec "$VMID" --timeout 40 -- /bin/bash -lc "$CMD" 2>&1 | head -c 25000

echo
echo "===== End ====="
echo "Review output for private network information before sharing."
