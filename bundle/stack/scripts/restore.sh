#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi
BACKUP=${1:-}
if [[ -z "$BACKUP" || ! -f "$BACKUP" ]]; then
  echo "Usage: $0 /path/to/opencast-test-YYYYMMDDTHHMMSSZ.tar.age" >&2
  exit 1
fi
ROOT=/opt/opencast-test
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Decrypting backup..."
age -d -o "$TMP/backup.tar.gz" "$BACKUP"
mkdir -p "$TMP/payload"
tar -C "$TMP/payload" -xzf "$TMP/backup.tar.gz"

systemctl stop opencast-test.service || true
rm -rf "$ROOT/data" "$ROOT/config"
cp -a "$TMP/payload/data" "$ROOT/data"
cp -a "$TMP/payload/config" "$ROOT/config"
if [[ -f "$TMP/payload/opencast-test.env" ]]; then
  install -m 0600 "$TMP/payload/opencast-test.env" /etc/opencast-test.env
fi
systemctl start opencast-test.service

echo "Restore complete."
"$ROOT/scripts/status.sh" || true
