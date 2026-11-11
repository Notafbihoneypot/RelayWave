#!/usr/bin/env bash
set -euo pipefail
source /etc/opencast-test.env
ROOT=/opt/opencast-test
NET=opencast-test-net

mkdir -p "$ROOT/data/app" "$ROOT/data/blossom" "$ROOT/data/relay" "$ROOT/data/cache"
chown 101:101 "$ROOT/data/cache" 2>/dev/null || chmod 0777 "$ROOT/data/cache"

if ! podman network inspect "$NET" >/dev/null 2>&1; then
  podman network create "$NET" >/dev/null
fi

# Build local images. The OpenCast image has no runtime npm dependency install.
podman build -q -t localhost/opencast-test:local -f "$ROOT/app/Containerfile" "$ROOT/app"
podman build -q -t localhost/opencast-blossom:local "$ROOT/vendor/blossom-server"
if ! podman image exists ghcr.io/mattn/nostr-relay:latest; then
  podman pull -q ghcr.io/mattn/nostr-relay:latest >/dev/null
fi
if ! podman image exists docker.io/library/nginx:stable-alpine; then
  podman pull -q docker.io/library/nginx:stable-alpine >/dev/null
fi

for c in opencast-edge opencast-app opencast-blossom opencast-relay; do
  podman rm -f "$c" >/dev/null 2>&1 || true
done

podman run -d \
  --name opencast-app \
  --network "$NET" \
  --restart=unless-stopped \
  --log-driver=journald \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -e PORT=8787 \
  -e "PUBLIC_BASE_URL=$PUBLIC_BASE_URL" \
  -e "DEFAULT_BLOSSOM=$DEFAULT_BLOSSOM" \
  -e "DEFAULT_RELAYS=$DEFAULT_RELAYS" \
  -e "TEST_MODE=$TEST_MODE" \
  -e "DEMO_SECRET=${DEMO_SECRET:-}" \
  -e "ANALYTICS_TRUST_PROXY=${ANALYTICS_TRUST_PROXY:-0}" \
  -e "ANALYTICS_K=${ANALYTICS_K:-5}" \
  -v "$ROOT/data/app:/app/data:Z" \
  localhost/opencast-test:local >/dev/null

podman run -d \
  --name opencast-blossom \
  --network "$NET" \
  --restart=unless-stopped \
  --log-driver=journald \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -e BLOSSOM_REQUIRE_CONFIG=1 \
  -v "$ROOT/config/blossom.yml:/app/config.yml:ro,Z" \
  -v "$ROOT/data/blossom:/app/data:Z" \
  localhost/opencast-blossom:local /app/config.yml >/dev/null

podman run -d \
  --name opencast-relay \
  --network "$NET" \
  --restart=unless-stopped \
  --log-driver=journald \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -p "$LAN_IP:7447:7447" \
  -v "$ROOT/data/relay:/data:Z" \
  ghcr.io/mattn/nostr-relay:latest \
  -addr 0.0.0.0:7447 \
  -database /data/nostr-relay.sqlite \
  -service-url "ws://$LAN_IP:7447" >/dev/null

podman run -d \
  --name opencast-edge \
  --network "$NET" \
  --restart=unless-stopped \
  --log-driver=journald \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --user 101:101 \
  --entrypoint nginx \
  -p "$LAN_IP:8080:8080" \
  -p "$LAN_IP:8081:8081" \
  -v "$ROOT/config/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
  -v "$ROOT/data/cache:/var/cache/nginx:Z" \
  docker.io/library/nginx:stable-alpine -g 'daemon off;' >/dev/null

sleep 2
