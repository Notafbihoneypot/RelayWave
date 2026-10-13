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

mkdir -p "$ROOT/public"
if [[ -n "${RELAYWAVE_FEATURE_DIR:-}" ]]; then
  install -m 0644 "$RELAYWAVE_FEATURE_DIR/feed-claims.mjs" "$ROOT/feed-claims.mjs"
  install -m 0644 "$RELAYWAVE_FEATURE_DIR/feed-ui.js" "$ROOT/public/feed-ui.js"
else
  ORIGIN="https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/features"
  curl --fail --silent --show-error --location --retry 3 "$ORIGIN/feed-claims.mjs" -o "$ROOT/feed-claims.mjs.tmp"
  curl --fail --silent --show-error --location --retry 3 "$ORIGIN/feed-ui.js" -o "$ROOT/public/feed-ui.js.tmp"
  mv "$ROOT/feed-claims.mjs.tmp" "$ROOT/feed-claims.mjs"
  mv "$ROOT/public/feed-ui.js.tmp" "$ROOT/public/feed-ui.js"
fi
chmod 0644 "$ROOT/feed-claims.mjs" "$ROOT/public/feed-ui.js"

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
patch(server,"const path=url.pathname;\n",
      "\n  if(await handleFeedClaims(req,res,path))return;",
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
          <input type="url" id="claimFeedUrl" value="https://feeds.yellowball.fm/7IvrdL" placeholder="https://your-host.example/rss.xml" autocomplete="off">
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
systemctl restart opencast-test.service
systemctl is-active --quiet opencast-test.service
echo "RelayWave feed-claim feature installed. Existing application data preserved."
source /etc/opencast-test.env
echo "Dashboard: http://$LAN_IP:8080"
