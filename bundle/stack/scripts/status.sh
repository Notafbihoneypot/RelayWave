#!/usr/bin/env bash
set -u
source /etc/opencast-test.env 2>/dev/null || true
CHECK_IP="${LAN_IP:-127.0.0.1}"

echo "== Containers =="
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo

echo "== Service checks =="
if curl -fsS --max-time 3 "http://$CHECK_IP:8080/api/config" >/tmp/opencast-config.json 2>/dev/null; then
  echo "OpenCast: OK"
  jq -c '{publicBaseUrl,testMode,defaultBlossom,defaultRelays}' /tmp/opencast-config.json 2>/dev/null || cat /tmp/opencast-config.json
else
  echo "OpenCast: FAIL"
fi
# For Blossom and Nostr we only require an HTTP response; their root endpoints
# are allowed to return 404/other protocol-specific status codes.
if curl -sSI --max-time 3 -o /dev/null "http://$CHECK_IP:8081/" 2>/dev/null; then
  echo "Blossom edge: reachable"
else
  echo "Blossom edge: FAIL"
fi
if curl -sS --max-time 3 -o /dev/null -H 'Accept: application/nostr+json' "http://$CHECK_IP:7447/" 2>/dev/null; then
  echo "Nostr relay: reachable"
else
  echo "Nostr relay: check container logs"
fi
