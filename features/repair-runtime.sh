#!/usr/bin/env bash
set -Eeuo pipefail
# Targeted repair of the RelayWave test stack. Must run as root inside VM.
# Does not delete images, network volumes, application state, or any other VM.
ROOT="${1:-/opt/opencast-test}"
if [[ -f "$ROOT/scripts/start.sh" ]]; then
  START="$ROOT/scripts/start.sh"
elif [[ -f "$ROOT/stack/scripts/start.sh" ]]; then
  START="$ROOT/stack/scripts/start.sh"
else
  echo "RelayWave startup script not found in $ROOT" >&2
  exit 1
fi

export RELAYWAVE_START="$START"
python3 - <<'PY'
from pathlib import Path
import os
path = Path(os.environ["RELAYWAVE_START"])
source = path.read_text()
marker = "# RelayWave restart cleanup for named test containers"
image = "ghcr.io/mattn/nostr-relay:latest"
if image not in source:
    raise SystemExit("Relay image not found in start.sh; refusing an unsafe patch")
if source.count(image) != 1:
    raise SystemExit("Relay image occurs multiple times; inspect start.sh before patching")
if "--entrypoint=/go/bin/nostr-relay" not in source:
    # This upstream image has CMD, not ENTRYPOINT. Appending -addr
    # after the image makes Podman try to exec '-addr' as a binary.
    source = source.replace(image, "--entrypoint=/go/bin/nostr-relay " + image)
    print("Added explicit executable for mattn/nostr-relay container")

if marker not in source:
    # Only remove the named containers owned by this test stack. Bind-mounted
    # application data and named volumes are unaffected (never pass -v).
    cleanup = """%s
if command -v podman >/dev/null 2>&1; then
  podman rm -f --ignore opencast-app opencast-blossom opencast-relay opencast-edge >/dev/null 2>&1 || true
fi
""" % marker
    if source.startswith("#!"):
        newline = source.index("\n")
        source = source[:newline+1] + cleanup + source[newline+1:]
    else:
        source = cleanup + source
    print("Added idempotent RelayWave-only container cleanup")
path.write_text(source)
PY
bash -n "$START"
echo "RelayWave runtime startup syntax OK: $START"
