#!/usr/bin/env bash
set -euo pipefail

# Manage which Nostr identities may upload media to this node's Blossom server.
# Uploads are closed by default: an identity that is not on this list is
# refused by Blossom itself ("Pubkey not authorized by any storage rule").
#
#   uploaders.sh list
#   uploaders.sh add <npub1... | 64-char hex>
#   uploaders.sh remove <npub1... | 64-char hex>
#   uploaders.sh add-test-identity     # the dashboard's "Test identity" (TEST_MODE only)
#   uploaders.sh sync                  # re-render blossom.yml from the list
#
# The list is config/uploaders.txt, one hex public key per line. Reading and
# downloading media is unaffected; only uploading is restricted.
ROOT="${RELAYWAVE_ROOT:-/opt/opencast-test}"
LIST="$ROOT/config/uploaders.txt"
CONF="$ROOT/config/blossom.yml"
[[ -f "$CONF" ]] || { echo "Blossom config not found at $CONF" >&2; exit 1; }
touch "$LIST"

to_hex() { python3 - "$1" <<'PY'
import re, sys
value = sys.argv[1].strip().lower()
if re.fullmatch(r'[0-9a-f]{64}', value):
    print(value); raise SystemExit
CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
def polymod(values):
    gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; chk = 1
    for v in values:
        top = chk >> 25; chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if (top >> i) & 1 else 0
    return chk
if not value.startswith('npub1') or any(c not in CHARSET for c in value[5:]):
    raise SystemExit('Expected an npub1... key or 64 hex characters.')
data = [CHARSET.index(c) for c in value[5:]]
hrp = [ord(c) >> 5 for c in 'npub'] + [0] + [ord(c) & 31 for c in 'npub']
if polymod(hrp + data) != 1:
    raise SystemExit('That npub has a bad checksum; check for a typo.')
acc = bits = 0; out = bytearray()
for v in data[:-6]:
    acc = (acc << 5) | v; bits += 5
    while bits >= 8:
        bits -= 8; out.append((acc >> bits) & 0xff)
if len(out) != 32 or (acc & ((1 << bits) - 1)):
    raise SystemExit('That npub does not decode to a 32-byte key.')
print(out.hex())
PY
}

sync_config() { python3 - "$LIST" "$CONF" <<'PY'
import re, sys
from pathlib import Path
keys = sorted({l.strip() for l in Path(sys.argv[1]).read_text().splitlines() if re.fullmatch(r'[0-9a-f]{64}', l.strip())})
conf = Path(sys.argv[2]); text = conf.read_text()
begin = '    # BEGIN RELAYWAVE UPLOADERS (managed by scripts/uploaders.sh; do not edit)\n'
end = '    # END RELAYWAVE UPLOADERS\n'
if text.count(begin) != 1 or text.count(end) != 1:
    raise SystemExit(f'Upload rule markers not found in {conf}; nothing changed.')
if keys:
    pub = '      pubkeys:\n' + ''.join(f'        - "{k}"\n' for k in keys)
else:
    pub = '      pubkeys: []\n'
# Stored scope: audio, artwork, transcripts and chapter files. The long
# expiration is deliberate: Blossom prunes blobs unaccessed for this long.
block = ''.join(f'    - type: "{mime}"\n      expiration: 100 years\n{pub}'
                for mime in ('audio/*', 'image/*', 'text/vtt', 'application/json'))
a = text.index(begin) + len(begin); b = text.index(end)
new = text[:a] + block + text[b:]
if new != text:
    conf.write_text(new)
print(f'{len(keys)} uploader(s) allowed.')
PY
}

reload_blossom() {
  if command -v podman >/dev/null 2>&1 && podman container exists opencast-blossom 2>/dev/null; then
    podman restart opencast-blossom >/dev/null && echo "Blossom restarted with the new list."
  fi
}

case "${1:-}" in
  list)
    grep -E '^[0-9a-f]{64}$' "$LIST" || echo "(no uploaders allowed)"
    ;;
  add|remove)
    KEY="$(to_hex "${2:?Give an npub or hex public key}")"
    grep -vx "$KEY" "$LIST" > "$LIST.tmp" || true
    [[ "$1" == add ]] && echo "$KEY" >> "$LIST.tmp"
    mv "$LIST.tmp" "$LIST"
    sync_config; reload_blossom
    ;;
  add-test-identity)
    LAN_IP="$(sed -n 's/^LAN_IP=//p' /etc/opencast-test.env | head -n 1)"
    KEY="$(curl --fail --silent --show-error --max-time 8 "http://$LAN_IP:8080/api/config" |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("demoPubkey",""))')"
    [[ "$KEY" =~ ^[0-9a-f]{64}$ ]] || { echo "The app is not in test mode or is not answering." >&2; exit 1; }
    echo "Allowing the test identity $KEY."
    echo "Anyone who can reach the dashboard can sign as it, so this opens uploads to your LAN."
    exec "$0" add "$KEY"
    ;;
  sync)
    sync_config
    ;;
  *)
    sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2
    ;;
esac
