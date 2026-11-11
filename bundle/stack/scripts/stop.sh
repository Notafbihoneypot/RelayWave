#!/usr/bin/env bash
set -euo pipefail
for c in opencast-edge opencast-app opencast-blossom opencast-relay; do
  podman stop "$c" >/dev/null 2>&1 || true
done
