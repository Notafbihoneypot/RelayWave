#!/usr/bin/env bash
set -Eeuo pipefail
# RelayWave runtime repair v2: only the named test containers and start.sh.
# Use /opt/opencast-test for an existing VM, or extracted bundle path for install.
ROOT="${1:-/opt/opencast-test}"
if [[ -f "$ROOT/scripts/start.sh" ]]; then
  START="$ROOT/scripts/start.sh"
elif [[ -f "$ROOT/stack/scripts/start.sh" ]]; then
  START="$ROOT/stack/scripts/start.sh"
else
  echo "RelayWave start.sh not found at $ROOT" >&2
  exit 1
fi
export RELAYWAVE_START="$START"
python3 - <<'PY'
from pathlib import Path
import os
path=Path(os.environ["RELAYWAVE_START"])
original=path.read_text()
lines=original.splitlines(keepends=True)
image="ghcr.io/mattn/nostr-relay:latest"
matches=[
    i for i,line in enumerate(lines[:-1])
    if line.strip()==image+" \\" and lines[i+1].strip().startswith("-addr ")
]
if len(matches)!=1:
    raise SystemExit(
      f"Expected exactly one relay launch command, found {len(matches)} "
      f"among {original.count(image)} image references. No changes written."
    )
i=matches[0]
entrypoint="--entrypoint /go/bin/nostr-relay"
if i==0 or entrypoint not in lines[i-1]:
    indent=lines[i][:len(lines[i])-len(lines[i].lstrip())]
    lines.insert(i,indent+entrypoint+" \\\n")
    print("Fixed relay executable: /go/bin/nostr-relay")
else:
    print("Relay executable already fixed")
source="".join(lines)
marker="# RelayWave safe restart cleanup v2"
if marker not in source:
    needle="set -euo pipefail\n"
    if source.count(needle)!=1:
        raise SystemExit("Could not identify safe startup location. No changes written.")
    block="""# RelayWave safe restart cleanup v2
# Remove only test containers. Do NOT remove volumes or data directories.
for rw_container in opencast-edge opencast-relay opencast-blossom opencast-app; do
  if podman container exists "$rw_container"; then
    podman rm -f "$rw_container" >/dev/null || {
      echo "Could not clean up old RelayWave container $rw_container" >&2
      exit 1
    }
  fi
done
"""
    source=source.replace(needle,needle+block,1)
    print("Enabled explicit cleanup of stale RelayWave containers")
if source!=original:
    path.write_text(source)
print("RelayWave runtime repair v2 applied to",path)
PY
bash -n "$START"
echo "RelayWave startup syntax check passed"
