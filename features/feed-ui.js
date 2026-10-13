// Optional RelayWave RSS ownership step. Uses the parent app's NIP-98 signer.
document.addEventListener('DOMContentLoaded', () => {
  const $ = id => document.getElementById(id);
  const url = $('claimFeedUrl'), code = $('claimCode'), xml = $('claimXml');
  const start = $('claimStartBtn'), verify = $('claimVerifyBtn');
  const status = $('claimResult'), list = $('claimList');
  if (!url || !code || !xml || !start || !verify || !status) return;

  const show = (message, good = true) => {
    status.textContent = message;
    status.className = 'result ' + (good ? 'ok' : 'error');
  };
  function setBusy(busy) {
    start.disabled = busy;
    verify.disabled = busy || !code.value;
    $('claimListBtn').disabled = busy;
  }
  async function send(type) {
    const feedUrl = url.value.trim();
    if (!feedUrl.startsWith('https://')) {
      show('Enter the original HTTPS RSS feed URL.', false);
      return;
    }
    setBusy(true);
    show('Waiting for your Nostr signing approval…');
    try {
      await window.relaywaveSendFeedClaim(type, feedUrl);
      // With NIP-55 on Android the page redirects to a signer first.
    } catch (error) {
      show(error.message || 'Signer or verification failed', false);
    } finally {
      setBusy(false);
    }
  }
  start.addEventListener('click', () => send('start'));
  verify.addEventListener('click', () => send('verify'));
  url.addEventListener('input', () => {
    code.value = '';
    xml.value = '';
    verify.disabled = true;
    show('Editing the source feed does not change or redirect it.');
  });
  $('claimCopyBtn').addEventListener('click', async () => {
    if (!code.value) return;
    try {
      await navigator.clipboard.writeText(code.value);
      show('Code copied. Add it to your original podcast host.');
    } catch {
      code.focus();
      code.select();
      show('Select and copy the code above.');
    }
  });
  $('claimListBtn').addEventListener('click', async () => {
    setBusy(true);
    try {
      await window.relaywaveListFeedClaims();
    } catch (error) {
      show(error.message || 'Could not read verified feeds', false);
    } finally { setBusy(false); }
  });
  window.addEventListener('relaywave-feed-result', event => {
    const { after, data } = event.detail || {};
    if (after === 'feedStart') {
      code.value = data.code || '';
      xml.value = '<podcast:txt purpose="verify">' + code.value + '</podcast:txt>';
      verify.disabled = !code.value;
      show('One-time code created. Add it to the original feed, save, then click Verify. Expires in 30 minutes.');
    } else if (after === 'feedVerify') {
      code.value = ''; xml.value = ''; verify.disabled = true;
      show('Ownership verified! Your podcast has NOT been imported, redirected, or published. The next step will be a private import preview.');
    } else if (after === 'feedList') {
      list.replaceChildren();
      for (const entry of data.verified || []) {
        const div = document.createElement('p');
        div.textContent = 'Verified: ' + entry.feedUrl;
        list.appendChild(div);
      }
      if (!list.children.length) list.textContent = 'No verified feeds yet.';
      show('Verified podcast list refreshed.');
    }
  });
});
