#!/usr/bin/env bash
set -Eeuo pipefail
# Fix Podman unqualified FROM references in RelayWave's test stack.
# Usage: bash qualify-images.sh /opt/opencast-test
# Also supports the extracted install payload directory before copying to /opt.
ROOT="${1:-/opt/opencast-test}"
[[ -d "$ROOT/app" ]] || { echo "Application source missing at $ROOT/app" >&2; exit 1; }
if [[ -f "$ROOT/scripts/start.sh" ]]; then
  START="$ROOT/scripts/start.sh"
elif [[ -f "$ROOT/stack/scripts/start.sh" ]]; then
  START="$ROOT/stack/scripts/start.sh"
else
  echo "RelayWave start.sh missing at $ROOT" >&2
  exit 1
fi
export RW_ROOT="$ROOT" RW_START="$START"
python3 - <<'PY'
from pathlib import Path
import os
root=Path(os.environ["RW_ROOT"])
start=Path(os.environ["RW_START"])
app=root/"app"/"Containerfile"
if not app.is_file():
    raise SystemExit(f"Missing {app}")
a=app.read_text()
b=a.replace("FROM node:22-alpine","FROM docker.io/library/node:22-alpine")
if a!=b:
    app.write_text(b)
    print(f"Qualified app base image: {app}")
blossom=root/"vendor"/"blossom-server"/"Dockerfile"
if blossom.is_file():
    a=blossom.read_text()
    b=a.replace("FROM denoland/deno:debian","FROM docker.io/denoland/deno:debian")
    if a!=b:
        blossom.write_text(b)
        print(f"Qualified Blossom base image: {blossom}")

# Persist the fix through subsequent service restarts, even if vendor source
# was not cloned at the time this script was run.
a=start.read_text()
marker="# RelayWave: qualify Blossom's upstream Deno image for Podman"
if marker not in a:
    needle='podman build -q -t localhost/opencast-blossom:local "$ROOT/vendor/blossom-server"'
    if a.count(needle)!=1:
        raise SystemExit(f"Expected one Blossom build command in {start}")
    prefix=(
        marker + "\n"
        'if grep -q "^FROM denoland/deno:debian$" "$ROOT/vendor/blossom-server/Dockerfile"; then\n'
        "  sed -i 's@^FROM denoland/deno:debian$@FROM docker.io/denoland/deno:debian@' \"$ROOT/vendor/blossom-server/Dockerfile\"\n"
        "fi\n"
    )
    start.write_text(a.replace(needle,prefix+needle,1))
    print(f"Patched persistent Podman startup: {start}")
# The installer binds HTTP ports to LAN_IP, not localhost.
# Report accurate status instead of false FAIL on all healthy containers.
status_script = (root/"scripts"/"status.sh") if (root/"scripts"/"status.sh").is_file() else (root/"stack"/"scripts"/"status.sh")
if status_script.is_file():
    a=status_script.read_text()
    b=a.replace("http://127.0.0.1:", "http://\u0024{LAN_IP:-127.0.0.1}:")
    if a!=b:
        status_script.write_text(b)
        print(f"Fixed LAN-bound health checks: {status_script}")
print("Podman base image references are qualified.")
PY
