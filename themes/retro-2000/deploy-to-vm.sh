#!/usr/bin/env bash
set -Eeuo pipefail

# Run on PVE1 as root, targeting the existing podcast-test VM.
# Adds a separate /retro.html preview. Does not change the current dashboard.
VMID="${1:-103}"
if [[ ${EUID:-$(id -u)} -ne 0 ]] || ! command -v qm >/dev/null 2>&1; then
  echo "Run this as root on the Proxmox VE host (PVE1)." >&2
  exit 1
fi
[[ "$VMID" =~ ^[0-9]+$ ]] || { echo "VMID must be numeric." >&2; exit 1; }
NAME="$(qm config "$VMID" | sed -n 's/^name: //p')"
[[ "$NAME" == "podcast-test" ]] || { echo "Refusing VM $VMID named '$NAME' (expected podcast-test)." >&2; exit 1; }
qm status "$VMID" | grep -qx 'status: running' || { echo "VM is not running." >&2; exit 1; }
qm guest cmd "$VMID" ping >/dev/null || { echo "VM guest-agent is unavailable." >&2; exit 1; }

echo "Installing RelayWave retro homepage preview in VM $VMID..."
# Pinned to the reviewed retro HTML commit, not mutable branch content.
GUEST_COMMAND="$(cat <<'GUEST'
set -Eeuo pipefail
APP_PUBLIC=/opt/opencast-test/app/public
[[ -d "$APP_PUBLIC" && -f "$APP_PUBLIC/index.html" ]] || {
  echo "Existing RelayWave app public directory missing." >&2
  exit 1
}
source /etc/opencast-test.env
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  'https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/c2ebc0487081f9a6dd06b389185cfb625605ca02/themes/retro-2000/retro.html' \
  -o "$tmp"
grep -q 'RETRO THEME PREVIEW' "$tmp" || {
  echo "Downloaded HTML did not pass the content check." >&2
  exit 1
}
if [[ -f "$APP_PUBLIC/retro.html" ]]; then
  cp -p "$APP_PUBLIC/retro.html" "$APP_PUBLIC/retro.html.previous"
fi
install -m 0644 "$tmp" "$APP_PUBLIC/retro.html"
echo "Persistent preview stored: $APP_PUBLIC/retro.html"
if podman container exists opencast-app; then
  if [[ "$(podman inspect --format '{{.State.Running}}' opencast-app)" == true ]]; then
    podman cp "$APP_PUBLIC/retro.html" opencast-app:/app/public/retro.html
    echo "Updated running app container without restarting it."
  else
    echo "RelayWave container not running. Preview will load after normal stack startup."
  fi
else
  echo "RelayWave container not created. Preview will load after normal stack startup."
fi
URL="http://$LAN_IP:8080/retro.html"
if curl --fail --silent --show-error --max-time 8 "$URL" -o /dev/null; then
  echo "SUCCESS: $URL"
  echo "Original dashboard remains: http://$LAN_IP:8080/"
else
  echo "Preview was saved, but the app URL is not serving it yet."
  echo "If RelayWave is stopped, repair/start the existing app; do not recreate the VM."
  exit 1
fi
GUEST
)"
RESULT="$(qm guest exec "$VMID" --timeout 120 -- /bin/bash -lc "$GUEST_COMMAND")"
printf '%s\n' "$RESULT" | python3 -c '
import json,sys
response=json.load(sys.stdin)
for name in ("out-data","err-data"):
    value=response.get(name,"")
    if value: print(value,end="" if value.endswith("\n") else "\n")
code=response.get("exitcode")
print("Preview install exit code:",code)
sys.exit(0 if code==0 else 1)
'
