#!/usr/bin/env bash
set -Eeuo pipefail
# Apply RelayWave's RSS ownership verification feature to existing test VM.
# Run on PVE1 as root. Never creates or destroys VMs.
VMID="${1:-103}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root on PVE1" >&2; exit 1; }
command -v qm >/dev/null || { echo "qm is missing: run on PVE" >&2; exit 1; }
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo "VMID must be numeric" >&2; exit 1; }
NAME="$(qm config "$VMID" | sed -n 's/^name: //p')"
[[ "$NAME" == "podcast-test" ]] || { echo "Refusing to touch VM $VMID named '$NAME' (expected podcast-test)" >&2; exit 1; }
qm status "$VMID" | grep -q '^status: running$' || { echo "VM $VMID is not running" >&2; exit 1; }
qm guest cmd "$VMID" ping >/dev/null || { echo "Guest agent is unavailable in VM $VMID" >&2; exit 1; }
echo "Updating RelayWave inside VM $VMID. Its data volumes will not be deleted."
COMMAND='set -Eeuo pipefail; curl -fsSL --retry 3 https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/features/install-feature.sh -o /root/relaywave-feed-feature.sh; bash /root/relaywave-feed-feature.sh'
RESULT="$(qm guest exec "$VMID" --timeout 900 -- /bin/bash -lc "$COMMAND")"
printf '%s\n' "$RESULT" | python3 -c '
import json,sys
try:
    response=json.load(sys.stdin)
except ValueError:
    print("Unrecognized guest-agent response",file=sys.stderr)
    sys.exit(1)
for name in ("out-data","err-data"):
    value=response.get(name,"")
    if value: print(value,end="" if value.endswith("\n") else "\n")
code=response.get("exitcode",1)
print("Guest installer exit code:", code)
sys.exit(0 if code == 0 else 1)
'
echo "Update complete. Open http://192.168.1.32:8080 and select Import podcast."
