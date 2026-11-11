#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuilds everything that is derived from other files in this repository:
#   1. the app bundle embedded in install.sh (from bundle/)
#   2. every SHA_<NAME>=<digest> line in the scripts that download other files
#   3. install.sh.sha256 and the digest quoted in README.md
#
# Run it after changing anything under bundle/ or features/, or any script
# listed below, then commit the result. `--check` changes nothing and exits
# non-zero if a rebuild would change a file (use it in review or CI).
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if ((CHECK)); then
  git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$WORK"
  cd "$WORK"
fi

sha() { sha256sum "$1" | cut -d' ' -f1; }
pin() { # pin <script> <VAR> <file whose digest goes in VAR>
  local digest; digest="$(sha "$3")"
  grep -Eq "^[[:space:]]*$2=[0-9a-f]{64}\$" "$1" || { echo "No $2 line in $1" >&2; exit 1; }
  sed -E -i "s|^([[:space:]]*)$2=[0-9a-f]{64}\$|\1$2=$digest|" "$1"
}

# 1. Embedded bundle. Fixed order, owner and timestamps so the same sources
#    always produce the same bytes (and therefore the same install.sh digest).
tar --sort=name --mtime='2026-01-01 00:00:00Z' --owner=0 --group=0 --numeric-owner --mode='a+rX,u+w,go-w,ug-s' \
    --exclude='bundle/app/data/db.json*' --transform='s|^bundle|OpenCast-Proxmox-Test|' \
    -cf - bundle | gzip -n -9 | base64 -w 76 > "$WORK/.payload.b64"
python3 -I - install.sh "$WORK/.payload.b64" <<'PY'
import sys
path,payload=sys.argv[1],sys.argv[2]
text=open(path).read()
start='__PAYLOAD_START__\n'; end='__PAYLOAD_END__\n'
a=text.rindex(start)+len(start); b=text.rindex(end)
if a>b: raise SystemExit('payload markers not found in install.sh')
open(path,'w').write(text[:a]+open(payload).read()+text[b:])
PY
rm -f "$WORK/.payload.b64"

# 2. Digests, leaves first: a script's own digest is only taken after the
#    digests inside it are final.
pin features/install-feature.sh SHA_FEED_CLAIMS_MJS      features/feed-claims.mjs
pin features/install-feature.sh SHA_FEED_UI_JS           features/feed-ui.js
pin features/install-feature.sh SHA_SERVER_MJS           bundle/app/server.mjs
pin features/install-feature.sh SHA_APP_JS               bundle/app/public/app.js
pin features/install-feature.sh SHA_APP_CSS              bundle/app/public/app.css
for script in features/install-feature.sh repair-vm.sh repair-vm-v2.sh install.sh; do
  pin "$script" SHA_QUALIFY_IMAGES_SH    features/qualify-images.sh
  pin "$script" SHA_REPAIR_RUNTIME_V2_SH features/repair-runtime-v2.sh
done
pin update-vm.sh SHA_INSTALL_FEATURE_SH features/install-feature.sh
pin install.sh   SHA_INSTALL_FEATURE_SH features/install-feature.sh
pin themes/retro-2000/deploy-to-vm.sh HTML_SHA256 themes/retro-2000/retro.html
pin themes/retro-2000/deploy-to-vm.sh CSS_SHA256  themes/retro-2000/retro.css

# 3. Published digest of the installer itself.
OLD="$(cut -d' ' -f1 install.sh.sha256)"
NEW="$(sha install.sh)"
printf '%s  install.sh\n' "$NEW" > install.sh.sha256
[[ "$OLD" == "$NEW" ]] || sed -i "s/$OLD/$NEW/g" README.md
grep -q "$NEW" README.md || { echo "README.md does not quote the installer digest" >&2; exit 1; }

if ((CHECK)); then
  cd - >/dev/null
  if git ls-files -z | xargs -0 -I{} cmp -s "{}" "$WORK/{}"; then echo "Derived files are up to date."; else
    echo "Derived files are stale; run tools/build-installer.sh and commit." >&2; exit 1; fi
else
  echo "install.sh digest: $NEW"
fi
