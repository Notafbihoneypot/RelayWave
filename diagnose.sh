#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only diagnostics for the existing RelayWave Proxmox test VM.
# Does not reinstall Podman, modify the VM, or read secrets.
VMID="${1:-103}"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run on PVE1 as root" >&2; exit 1; fi
command -v qm >/dev/null || { echo "Proxmox qm not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Python 3 is needed to decode guest-agent results" >&2; exit 1; }
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo "Expected numeric VMID" >&2; exit 1; }
echo "===== PVE host ====="
hostname
pveversion | head -n 1
echo
echo "===== RelayWave VM ====="
qm status "$VMID"
qm config "$VMID" | grep -E '^(name|agent|memory|cores|scsi0|net0):' || true
if ! qm guest cmd "$VMID" ping >/dev/null 2>&1; then
  echo "Guest agent not responding. Check the Proxmox VM console."
  exit 1
fi

CMD='
echo "===== Systemd service ====="
systemctl is-active opencast-test.service || true
systemctl status opencast-test.service --no-pager -l 2>&1 | tail -n 55 || true
echo
echo "===== Latest service journal (new error should appear here) ====="
journalctl -u opencast-test.service --no-pager --output=short-iso -n 120 2>&1 | tail -n 120 || true
echo
echo "===== Podman networks and images ====="
podman --version || true
command -v nft && nft --version || echo "nftables CLI missing"
podman network ls 2>&1 | head -n 20 || true
podman images --format "{{.Repository}}:{{.Tag}}  {{.Size}}" 2>&1 | head -n 20 || true
echo
echo "===== Podman containers ====="
podman ps -a --format "{{.Names}}  {{.Status}}" 2>&1 | head -n 35 || true
for c in opencast-app opencast-blossom opencast-relay opencast-edge; do
  if podman container exists "$c" 2>/dev/null; then
    echo "--- $c recent logs ---"
    podman logs --tail 15 "$c" 2>&1 || true
  fi
done
echo
echo "===== Deployment files ====="
for f in /opt/opencast-test/app/server.mjs /opt/opencast-test/app/feed-claims.mjs /opt/opencast-test/app/public/feed-ui.js /opt/opencast-test/scripts/start.sh; do
  if test -f "$f"; then echo "PRESENT $f"; else echo "MISSING $f"; fi
done
echo
echo "===== Disk capacity ====="
df -h / | tail -n 1
'
RESULT="$(qm guest exec "$VMID" --timeout 90 -- /bin/bash -lc "$CMD")" || {
  echo "Unable to run diagnostics inside VM $VMID" >&2; exit 1;
}
printf '%s\n' "$RESULT" | python3 -c '
import json,sys
try: obj=json.load(sys.stdin)
except ValueError:
    print("Guest-agent returned invalid JSON",file=sys.stderr)
    sys.exit(1)
for key in ("out-data","err-data"):
    value=obj.get(key,"")
    if value:
        print(value,end="" if value.endswith("\n") else "\n")
if obj.get("out-truncated") or obj.get("err-truncated"):
    print("Warning: some guest output was truncated.")
print("Diagnostic exit code:", obj.get("exitcode","unknown"))
'
echo "Review the output before sharing. Do not include private keys, tokens, or passwords."
