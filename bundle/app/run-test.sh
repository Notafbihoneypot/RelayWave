#!/bin/sh
set -eu
HOST_IP=${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}
PUBLIC_URL=${PUBLIC_BASE_URL:-http://${HOST_IP:-localhost}:8787}
echo "Starting OpenCast test build"
echo "Android/LAN URL: $PUBLIC_URL"
echo "TEST_MODE is ON. Do not expose this test signer to the public internet."
TEST_MODE=1 PUBLIC_BASE_URL="$PUBLIC_URL" node server.mjs
