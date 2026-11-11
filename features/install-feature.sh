#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root *inside* the Debian RelayWave test VM.
# Preserves /opt/opencast-test/data and the existing VM; installs only the
# feed-control ownership checker and dashboard UI. Does not copy episodes.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Run as root inside the VM" >&2; exit 1; fi
ROOT="${RELAYWAVE_APP_DIR:-/opt/opencast-test/app}"
if [[ ! -f "$ROOT/server.mjs" || ! -f "$ROOT/public/app.js" ]]; then
  echo "Existing RelayWave app not found at $ROOT" >&2
  exit 1
fi

# Everything downloaded below is checked against a SHA-256 digest recorded in
# this file before it is used. The digests are the trust anchor; REF only says
# where to look. tools/build-installer.sh rewrites the SHA_ lines.
REF="${RELAYWAVE_REF:-main}"
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || { echo "Invalid RELAYWAVE_REF" >&2; exit 1; }
SHA_FEED_CLAIMS_MJS=30361e370c2d47b03fcd3496e1cfc2c98a9dd512a26cfb0b0e3abe77e3390f04
SHA_FEED_UI_JS=d242779fa7ede5c98eefae4cfed083daaa86ca92e3c98e43cf50a6daa27a6387
SHA_SERVER_MJS=2e9aa9c961d19bdb8ba14392de322fdfdbee3c3337b84c5c24078743bd742bc6
SHA_APP_JS=ca8c74e6869c13e3a6041355e4392c290483d1d8d198ef45be0042be51e11094
SHA_APP_CSS=36a81380160a781957dccd3e00ea97af8f312d4942a9fe4596a432ee362e052b
SHA_QUALIFY_IMAGES_SH=afd0e76b2cf3a8143fd65adf3afc152145072d3ca41c3e04a5ccc32797732345
SHA_REPAIR_RUNTIME_V2_SH=8a9bbb0564d267bbd6f968755f36dab0bd46da2fe86875eaf677300de14b328c
rw_fetch() { # rw_fetch <path in repo> <sha256> <destination>
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/$REF/$1" -o "$3.download"
  echo "$2  $3.download" | sha256sum --check --status || {
    rm -f "$3.download"
    echo "Checksum mismatch for $1 at ref '$REF'; refusing to use it." >&2
    exit 1
  }
  mv "$3.download" "$3"
}

mkdir -p "$ROOT/public"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
if [[ -n "${RELAYWAVE_FEATURE_DIR:-}" ]]; then
  # Local checkout (tests, or an operator working from a clone).
  APP_SRC="${RELAYWAVE_BUNDLE_APP_DIR:-$RELAYWAVE_FEATURE_DIR/../bundle/app}"
  cp "$RELAYWAVE_FEATURE_DIR/feed-claims.mjs" "$RELAYWAVE_FEATURE_DIR/feed-ui.js" "$STAGE/"
  cp "$APP_SRC/server.mjs" "$APP_SRC/public/app.js" "$APP_SRC/public/app.css" "$STAGE/"
else
  rw_fetch features/feed-claims.mjs "$SHA_FEED_CLAIMS_MJS" "$STAGE/feed-claims.mjs"
  rw_fetch features/feed-ui.js "$SHA_FEED_UI_JS" "$STAGE/feed-ui.js"
  rw_fetch bundle/app/server.mjs "$SHA_SERVER_MJS" "$STAGE/server.mjs"
  rw_fetch bundle/app/public/app.js "$SHA_APP_JS" "$STAGE/app.js"
  rw_fetch bundle/app/public/app.css "$SHA_APP_CSS" "$STAGE/app.css"
fi
# Bring the base app up to the reviewed revision (security fixes), keeping one
# copy of what was there. The integration hooks below are then re-applied.
for pair in "server.mjs:$ROOT/server.mjs" "app.js:$ROOT/public/app.js" "app.css:$ROOT/public/app.css"; do
  src="$STAGE/${pair%%:*}"; dst="${pair#*:}"
  [[ -f "$ROOT/before-update/${pair%%:*}" ]] || { mkdir -p "$ROOT/before-update"; cp -p "$dst" "$ROOT/before-update/${pair%%:*}"; }
  install -m 0644 "$src" "$dst"
done
install -m 0644 "$STAGE/feed-claims.mjs" "$ROOT/feed-claims.mjs"
install -m 0644 "$STAGE/feed-ui.js" "$ROOT/public/feed-ui.js"

# Patch stable integration hooks once. Re-running this installer is idempotent.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])

def patch(path,needle,content,guard):
    text=path.read_text()
    if guard in text: return
    if text.count(needle)!=1:
        raise SystemExit(f"Expected exactly one integration hook in {path}: {needle[:55]}")
    path.write_text(text.replace(needle,content+needle,1))

server=root/'server.mjs'
patch(server,"import http from 'node:http';",
      "import { createFeedClaimsHandler } from './feed-claims.mjs';\n",
      "import { createFeedClaimsHandler }")
patch(server,"const server=http.createServer(",
      "const handleFeedClaims=createFeedClaimsHandler({db,queueSave,authenticate,readBody,json});\n",
      "const handleFeedClaims=createFeedClaimsHandler")
patch(server,"  if(req.method==='GET'&&path==='/api/config')",
      "  if(await handleFeedClaims(req,res,path))return;\n",
      "if(await handleFeedClaims(req,res,path))return;")

containerfile=root/'Containerfile'
patch(containerfile,"COPY public ./public",
      "COPY feed-claims.mjs ./feed-claims.mjs\n",
      "COPY feed-claims.mjs ./feed-claims.mjs")

frontend=root/'public'/'app.js'
patch(frontend,"async function authenticatedRequest(",
"""window.relaywaveSendFeedClaim=(operation,feedUrl)=>{
  if(!['start','verify'].includes(operation))throw new Error('Invalid verification operation');
  return authenticatedRequest('POST','/api/feed-claims/'+operation,{feedUrl},{after:operation==='start'?'feedStart':'feedVerify'});
};
window.relaywaveListFeedClaims=()=>authenticatedRequest('GET','/api/feed-claims/list',null,{after:'feedList'});
""",
      "window.relaywaveSendFeedClaim=")
anchor="    if(c.after==='seedAnalytics'){state.analyticsRanges=data.ranges||{};renderAnalytics();setResult('insightsResult','Synthetic privacy-safe demo data added.');}\n"
patch(frontend,anchor,
      """    if(['feedStart','feedVerify','feedList'].includes(c.after))window.dispatchEvent(new CustomEvent('relaywave-feed-result',{detail:{after:c.after,data}}));
""",
      "window.dispatchEvent(new CustomEvent('relaywave-feed-result'")

html=root/'public'/'index.html'
patch(html, '      <button class="nav" data-view="podcast">Podcast</button>',
      '      <button class="nav" data-view="import">Import podcast</button>\n',
      'data-view="import"')
panel="""    <section class="view" id="view-import">
      <div class="panel form-panel">
        <div class="section-head"><div><p class="eyebrow">EMAIL-FREE OWNERSHIP</p><h2>Verify your existing podcast</h2></div><span class="pill">Private · read only</span></div>
        <p class="muted">Use your Nostr identity to prove you control the original RSS feed. This does not download episodes, modify your old host, redirect listeners or publish anything.</p>
        <label>Existing RSS feed URL
          <input type="url" id="claimFeedUrl" placeholder="https://your-host.example/rss.xml" autocomplete="off">
        </label>
        <div class="button-row"><button class="button primary" id="claimStartBtn">1. Generate a verification code</button></div>
        <label>One-time code (30-minute expiry)<input id="claimCode" readonly placeholder="Generate a code first"></label>
        <div class="button-row"><button class="button secondary" id="claimCopyBtn">Copy code</button></div>
        <p class="muted">In your existing podcast host, add this as a <strong>channel-level Podcast TXT verification field</strong>. Paste just the code into the field, not the XML markup. Save the feed.</p>
        <label>What the source RSS should contain<textarea id="claimXml" rows="2" readonly placeholder="The XML snippet appears after generating a code"></textarea></label>
        <p class="muted">If your host doesn't expose Podcast TXT, this test version cannot verify that feed yet. Don't paste a private key or password into the feed.</p>
        <div class="button-row"><button class="button primary" id="claimVerifyBtn" disabled>2. Verify ownership</button><button class="button ghost" id="claimListBtn">My verified podcasts</button></div>
        <div class="result" id="claimResult">Connect a Nostr signer (or use the LAN-only test identity) to begin.</div>
        <div class="result" id="claimList"></div>
        <div class="callout">Verification proves current administrative control of the RSS feed, not copyright ownership. Private media import and cutover are separate, not yet enabled.</div>
      </div>
    </section>

"""
patch(html,'    <section class="view" id="view-article">',
      panel,'id="view-import"')
patch(html,'</body>',
      '<script defer src="/feed-ui.js"></script>\n',
      'src="/feed-ui.js"')
PY

node --check "$ROOT/server.mjs"
node --check "$ROOT/feed-claims.mjs"
node --check "$ROOT/public/app.js"
node --check "$ROOT/public/feed-ui.js"

if [[ "${RELAYWAVE_SKIP_RESTART:-0}" = 1 ]]; then
  echo "Feature files patched and syntax-checked. Restart skipped for local test."
  exit 0
fi

# Debian 13 may omit the nftables executable even with Podman/netavark installed.
if ! command -v nft >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables
fi
# Podman defaults on Debian have no unqualified Docker Hub image search;
# make both app and Blossom base images explicit, including on future restarts.
rw_fetch features/qualify-images.sh "$SHA_QUALIFY_IMAGES_SH" /root/relaywave-qualify-images.sh
bash /root/relaywave-qualify-images.sh /opt/opencast-test
rw_fetch features/repair-runtime-v2.sh "$SHA_REPAIR_RUNTIME_V2_SH" /root/relaywave-repair-runtime-v2.sh
bash /root/relaywave-repair-runtime-v2.sh /opt/opencast-test

# Stack hardening for VMs installed before the security review. Idempotent.
python3 - <<'PY'
from pathlib import Path
import re, secrets
env=Path('/etc/opencast-test.env')
text=env.read_text()
if not re.search(r'^DEMO_SECRET=[0-9a-f]{64}$',text,re.M):
    text=re.sub(r'^DEMO_SECRET=.*\n','',text,flags=re.M)
    env.write_text(text.rstrip('\n')+'\nDEMO_SECRET='+secrets.token_hex(32)+'\n')
    print('Generated a per-install test signer key (the old one was derivable from the source).')
env.chmod(0o600)
start=Path('/opt/opencast-test/scripts/start.sh')
s=start.read_text()
if 'DEMO_SECRET' not in s:
    needle='  -e "TEST_MODE=$TEST_MODE" \\\n'
    if s.count(needle)!=1: raise SystemExit('Could not find the TEST_MODE line in start.sh; nothing changed.')
    start.write_text(s.replace(needle,needle+'  -e "DEMO_SECRET=${DEMO_SECRET:-}" \\\n',1))
for path,old,new in (('/opt/opencast-test/config/blossom.yml','  maxSize: 2147483648\n  workers: 1','  maxSize: 536870912\n  workers: 1'),
                     ('/opt/opencast-test/config/nginx.conf','client_max_body_size 2048m;','client_max_body_size 512m;'),
                     ('/opt/opencast-test/config/nginx.conf','client_max_body_size 32m;','client_max_body_size 2m;')):
    p=Path(path)
    if p.is_file():
        c=p.read_text()
        if old in c: p.write_text(c.replace(old,new,1)); print('Tightened',path)
PY
bash -n /opt/opencast-test/scripts/start.sh
if ! dpkg-query -W -f='${Status}' aardvark-dns 2>/dev/null | grep -qx 'install ok installed'; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends aardvark-dns
fi
systemctl restart opencast-test.service
systemctl is-active --quiet opencast-test.service
echo "RelayWave feed-claim feature installed. Existing application data preserved."
echo "Dashboard: http://$(sed -n 's/^LAN_IP=//p' /etc/opencast-test.env | head -n 1):8080"
