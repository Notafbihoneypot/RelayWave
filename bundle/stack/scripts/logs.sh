#!/usr/bin/env bash
set -euo pipefail
for c in opencast-app opencast-blossom opencast-relay opencast-edge; do
  echo "===== $c ====="
  podman logs --tail 80 "$c" 2>&1 || true
  echo
done
