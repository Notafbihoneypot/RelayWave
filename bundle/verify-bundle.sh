#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "$ROOT"/proxmox/create-vm.sh "$ROOT"/install-in-vm.sh "$ROOT"/stack/scripts/*.sh; do
  bash -n "$f"
done
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  (cd "$ROOT/app" && npm test)
else
  echo "Node/npm not installed here; skipped OpenCast unit tests."
fi
echo "Bundle checks passed."
