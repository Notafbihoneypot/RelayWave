#!/usr/bin/env bash
set -Eeuo pipefail

# Adds the retro-2000 skin to an existing RelayWave app as an opt-in theme.
# Run as root *inside* the test VM, from a checkout of this repository:
#   bash themes/retro-2000/install-theme.sh                  # dashboard toggle
#   bash themes/retro-2000/install-theme.sh --public-pages   # also /p/ pages
#   bash themes/retro-2000/install-theme.sh --remove         # full rollback
#
# UI assets only: copies static files into public/ and adds two tags to
# index.html. It does not touch server.mjs, the database, Blossom, the relay
# or any signing code, and it does not restart anything. Installs from the
# local checkout; it downloads nothing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${RELAYWAVE_APP_DIR:-/opt/opencast-test/app}"
PUBLIC="$ROOT/public"
MODE=install; PUBLIC_PAGES=0
for arg in "$@"; do
  case "$arg" in
    --public-pages) PUBLIC_PAGES=1 ;;
    --remove) MODE=remove ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ -f "$PUBLIC/index.html" && -f "$PUBLIC/site.css" ]] || { echo "RelayWave public directory not found at $PUBLIC" >&2; exit 1; }

patch_index() { python3 - "$PUBLIC/index.html" "$1" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); mode=sys.argv[2]
text=path.read_text()
tags='  <link rel="stylesheet" href="/retro-app.css">\n  <script src="/theme.js"></script>\n'
if mode=='remove':
    path.write_text(text.replace(tags,''))
elif tags not in text:
    needle='  <link rel="stylesheet" href="/app.css">\n'
    if text.count(needle)!=1:
        raise SystemExit(f"Expected exactly one app.css link in {path}; nothing changed.")
    path.write_text(text.replace(needle,needle+tags,1))
PY
}
in_container() {
  command -v podman >/dev/null 2>&1 && podman container exists opencast-app 2>/dev/null &&
    [[ "$(podman inspect --format '{{.State.Running}}' opencast-app)" == true ]]
}
sync_file() { # copy one public file into the running container, or delete it there
  in_container || return 0
  if [[ -f "$PUBLIC/$1" ]]; then podman cp "$PUBLIC/$1" "opencast-app:/app/public/$1"
  else podman exec opencast-app rm -f "/app/public/$1"; fi
}

if [[ "$MODE" == remove ]]; then
  patch_index remove
  rm -f "$PUBLIC/retro-app.css" "$PUBLIC/theme.js"
  if [[ -f "$PUBLIC/site.css.classic" ]]; then mv "$PUBLIC/site.css.classic" "$PUBLIC/site.css"; fi
  for f in index.html site.css retro-app.css theme.js; do sync_file "$f"; done
  echo "Retro theme removed; classic interface restored."
  exit 0
fi

install -m 0644 "$HERE/retro-app.css" "$PUBLIC/retro-app.css"
install -m 0644 "$HERE/theme.js" "$PUBLIC/theme.js"
node --check "$PUBLIC/theme.js" 2>/dev/null || true
patch_index install
if ((PUBLIC_PAGES)); then
  [[ -f "$PUBLIC/site.css.classic" ]] || cp -p "$PUBLIC/site.css" "$PUBLIC/site.css.classic"
  install -m 0644 "$HERE/site-retro.css" "$PUBLIC/site.css"
fi
for f in retro-app.css theme.js index.html site.css; do sync_file "$f"; done
echo "Retro theme installed. Classic remains the default."
echo "Open the dashboard with ?theme=retro, or use the 'Retro theme' button; ?theme=classic switches back."
((PUBLIC_PAGES)) && echo "Public pages now use the retro stylesheet (classic saved as site.css.classic)."
exit 0
