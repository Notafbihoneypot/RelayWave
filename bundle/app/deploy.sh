#!/bin/sh
set -eu
IMAGE="opencast-nostr-publisher"
NAME="opencast-publisher"
VOLUME="opencast-publisher-data"

printf "Public URL [http://localhost:8787]: "
read -r PUBLIC_URL || true
PUBLIC_URL=${PUBLIC_URL:-http://localhost:8787}
printf "Enable disposable TEST signer? [y/N]: "
read -r TEST_REPLY || true
case "${TEST_REPLY:-n}" in y|Y|yes|YES) TEST_MODE=1 ;; *) TEST_MODE=0 ;; esac
printf "Blossom server [https://blossom.primal.net]: "
read -r BLOSSOM || true
BLOSSOM=${BLOSSOM:-https://blossom.primal.net}
printf "Relay list (comma separated) [wss://relay.damus.io,wss://nos.lol,wss://relay.nostr.band]: "
read -r RELAYS || true
RELAYS=${RELAYS:-wss://relay.damus.io,wss://nos.lol,wss://relay.nostr.band}

podman build -t "$IMAGE" -f Containerfile .
podman volume inspect "$VOLUME" >/dev/null 2>&1 || podman volume create "$VOLUME" >/dev/null
podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d \
  --name "$NAME" \
  --restart=unless-stopped \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -p 8787:8787 \
  -e PORT=8787 \
  -e "PUBLIC_BASE_URL=$PUBLIC_URL" \
  -e "DEFAULT_BLOSSOM=$BLOSSOM" \
  -e "DEFAULT_RELAYS=$RELAYS" \
  -e "TEST_MODE=$TEST_MODE" \
  -v "$VOLUME:/app/data:Z" \
  "$IMAGE" >/dev/null

echo "Started $NAME"
echo "Open: $PUBLIC_URL"
[ "$TEST_MODE" = "1" ] && echo "WARNING: disposable test signer enabled. Keep this deployment private/LAN-only."
