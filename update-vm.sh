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
# The in-guest installer is verified against this digest before it runs, and
# it verifies everything it downloads in turn. RELAYWAVE_REF selects a branch
# or commit for testing; the digests still have to match.
REF="${RELAYWAVE_REF:-main}"
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || { echo "Invalid RELAYWAVE_REF" >&2; exit 1; }
SHA_INSTALL_FEATURE_SH=4ab0e443d5427e46f0ade9632b45030cd7d2ed855dfbfcfa8d6008245007fea3
COMMAND="set -Eeuo pipefail
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 'https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/$REF/features/install-feature.sh' -o /root/relaywave-feed-feature.sh.download
echo '$SHA_INSTALL_FEATURE_SH  /root/relaywave-feed-feature.sh.download' | sha256sum --check --status || { rm -f /root/relaywave-feed-feature.sh.download; echo 'Checksum mismatch for install-feature.sh; nothing was run.' >&2; exit 1; }
mv /root/relaywave-feed-feature.sh.download /root/relaywave-feed-feature.sh
RELAYWAVE_REF='$REF' bash /root/relaywave-feed-feature.sh"
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
echo "Update complete. Open the dashboard URL printed above and select Import podcast."
