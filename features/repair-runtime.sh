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
# The script legitimately mentions the image more than once (e.g. pulling it
# separately). Only change the actual command line ending 'IMAGE -addr ...'.
# This can span shell line continuations and is not affected by pull statements.
import re
launch = re.compile(
    r'(?<![A-Za-z0-9/])' + re.escape(image) +
    r'(?P<gap>(?:\s|\\\s*)+)(?=-addr(?:\s|=|$))'
)
matches = list(launch.finditer(source))
if len(matches) != 1:
    details = [
        f"line {source.count(chr(10), 0, m.start())+1}"
        for m in re.finditer(re.escape(image), source)
    ]
    raise SystemExit(
        f"Expected one runnable relay image immediately before -addr; "
        f"found {len(matches)} (image references: {', '.join(details)}). "
        "No startup changes were written."
    )
match = matches[0]
if source[max(0, match.start()-48):match.start()].find('--entrypoint=/go/bin/nostr-relay') == -1:
    source = source[:match.start()] + '--entrypoint=/go/bin/nostr-relay ' + source[match.start():]
    print("Added explicit executable to the relay run command")
else:
    print("Relay entrypoint already configured")

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
