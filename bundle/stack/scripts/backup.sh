#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/opencast-test
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=${1:-"$PWD/opencast-test-$STAMP.tar.age"}
TMP=$(mktemp -d)
STOPPED=0
cleanup() {
  if [[ $STOPPED -eq 1 ]]; then
    podman start opencast-app opencast-blossom opencast-relay >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "Stopping stateful test containers for a consistent snapshot..."
podman stop opencast-app opencast-blossom opencast-relay >/dev/null 2>&1 || true
STOPPED=1

mkdir -p "$TMP/payload"
cp -a "$ROOT/data" "$TMP/payload/data"
cp -a "$ROOT/config" "$TMP/payload/config"
cp -a /etc/opencast-test.env "$TMP/payload/opencast-test.env"
tar -C "$TMP/payload" -czf "$TMP/opencast-test-$STAMP.tar.gz" .

podman start opencast-app opencast-blossom opencast-relay >/dev/null 2>&1 || true
STOPPED=0

echo "Encrypting with an age passphrase. Keep the passphrase outside this VM."
age -p -o "$OUT" "$TMP/opencast-test-$STAMP.tar.gz"
echo "Encrypted backup: $OUT"
