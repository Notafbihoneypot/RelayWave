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
# Both files are fetched from one pinned commit AND checked against SHA-256
# digests recorded here. The digests are the trust anchor: a moved branch, a
# rewritten commit or a tampered download fails closed before anything is
# installed. When the theme changes, update REF and both digests together.
GUEST_COMMAND="$(cat <<'GUEST'
set -Eeuo pipefail
umask 022
REF=0c64450f02e7109d6336d861a54763e19c9ab98f
HTML_SHA256=44a21af3e60d3d8637a30d1332d918ef7da8dfe43bcaddf34e4e6d9bfd3a57b2
CSS_SHA256=caeaa50449e14b203576a03df3be44fede62bb128825f6bed3203302712172ac
BASE="https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/$REF/themes/retro-2000"
APP_PUBLIC=/opt/opencast-test/app/public
[[ -d "$APP_PUBLIC" && -f "$APP_PUBLIC/index.html" ]] || {
  echo "Existing RelayWave app public directory missing." >&2
  exit 1
}
# Read only LAN_IP; do not execute the whole env file as root.
LAN_IP="$(sed -n 's/^LAN_IP=//p' /etc/opencast-test.env | head -n 1)"
[[ "$LAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "LAN_IP missing from /etc/opencast-test.env." >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch() {
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 "$BASE/$1" -o "$tmp/$1"
  echo "$2  $tmp/$1" | sha256sum --check --status || {
    echo "Checksum mismatch for $1; nothing was installed." >&2
    exit 1
  }
}
fetch retro.html "$HTML_SHA256"
fetch retro.css "$CSS_SHA256"
for f in retro.html retro.css; do
  if [[ -f "$APP_PUBLIC/$f" ]]; then
    cp -p "$APP_PUBLIC/$f" "$APP_PUBLIC/$f.previous"
  fi
done
# Stylesheet first, so the page is never served without it.
install -m 0644 "$tmp/retro.css" "$APP_PUBLIC/retro.css"
install -m 0644 "$tmp/retro.html" "$APP_PUBLIC/retro.html"
echo "Persistent preview stored: $APP_PUBLIC/retro.html and retro.css"
if podman container exists opencast-app; then
  if [[ "$(podman inspect --format '{{.State.Running}}' opencast-app)" == true ]]; then
    podman cp "$APP_PUBLIC/retro.css" opencast-app:/app/public/retro.css
    podman cp "$APP_PUBLIC/retro.html" opencast-app:/app/public/retro.html
    echo "Updated running app container without restarting it."
  else
    echo "RelayWave container not running. Preview will load after normal stack startup."
  fi
else
  echo "RelayWave container not created. Preview will load after normal stack startup."
fi
URL="http://$LAN_IP:8080/retro.html"
# Confirm the app serves exactly the reviewed bytes, not just any HTTP 200.
served() { curl --fail --silent --show-error --max-time 8 "http://$LAN_IP:8080/$1" | sha256sum | cut -d' ' -f1; }
if [[ "$(served retro.html)" == "$HTML_SHA256" && "$(served retro.css)" == "$CSS_SHA256" ]]; then
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
