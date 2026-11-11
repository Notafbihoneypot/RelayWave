// Run with: node --test features/feed-claims.test.mjs
// No network access and no dependencies: a local TLS server stands in for the
// podcast host, and DNS is injected.
import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fetchPublicFeed, getVerificationTexts, normalizeFeedUrl, createFeedClaimsHandler } from './feed-claims.mjs';

const NS = 'https://podcastindex.org/namespace/1.0';
const feed = (channel) => `<?xml version="1.0"?><rss xmlns:podcast="${NS}"><channel>${channel}</channel></rss>`;

test('normalizeFeedUrl rejects non-public targets', () => {
  for (const bad of ['http://example.com/f', 'https://127.0.0.1/f', 'https://[::1]/f', 'https://localhost/f',
    'https://example.com:8443/f', 'https://user:pw@example.com/f', 'https://x.internal/f', 'https://0x7f.1/f']) {
    assert.throws(() => normalizeFeedUrl(bad), /HTTPS/, bad);
  }
  assert.equal(normalizeFeedUrl(' https://Example.com/feed.xml '), 'https://example.com/feed.xml');
});

test('fetchPublicFeed refuses private, loopback and mixed DNS answers', async () => {
  for (const address of ['127.0.0.1', '10.0.0.5', '192.168.1.32', '169.254.169.254', '100.64.0.1']) {
    await assert.rejects(
      fetchPublicFeed('https://feed.example.com/f', { resolve: async () => [{ address: '93.184.216.34' }, { address }] }),
      /public IPv4/, address);
  }
});

test('only channel-level podcast:txt purpose=verify is accepted', () => {
  assert.deepEqual(getVerificationTexts(feed('<podcast:txt purpose="verify">abc</podcast:txt>')), ['abc']);
  assert.deepEqual(getVerificationTexts(feed('<item><podcast:txt purpose="verify">abc</podcast:txt></item>')), []);
  assert.deepEqual(getVerificationTexts(feed('<podcast:txt>abc</podcast:txt>')), []);
  assert.deepEqual(getVerificationTexts(feed('<description><![CDATA[<podcast:txt purpose="verify">abc</podcast:txt>]]></description>')), []);
  assert.deepEqual(getVerificationTexts(feed('<!-- <podcast:txt purpose="verify">abc</podcast:txt> -->')), []);
  assert.deepEqual(getVerificationTexts('<rss xmlns:podcast="https://evil.example/ns"><channel><podcast:txt purpose="verify">abc</podcast:txt></channel></rss>'), []);
  assert.throws(() => getVerificationTexts('<!DOCTYPE rss [<!ENTITY x "y">]><rss/>'), /unsafe/);
});

function tlsFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'rw-feed-'));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'), '-subj', '/CN=feed.example.com',
    '-addext', 'subjectAltName=DNS:feed.example.com'], { stdio: 'ignore' });
  return { key: readFileSync(join(dir, 'k.pem')), cert: readFileSync(join(dir, 'c.pem')) };
}

test('pinned lookup works with the installed Node and TLS still checks the host name', async (t) => {
  let tls;
  try { tls = tlsFixture(); } catch { return t.skip('openssl not available'); }
  const body = feed('<podcast:txt purpose="verify">rw-v-test</podcast:txt>');
  const server = https.createServer(tls, (_req, res) => res.end(body));
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => server.close());
  const { port } = server.address();
  // Real https/net stack, production lookup; only the port and the final
  // address are redirected to the local fixture. If the production lookup
  // answered in the wrong shape for this Node version, the connect would fail.
  const seen = [];
  const request = (url, options, cb) => {
    const target = new URL(url); target.port = String(port);
    return https.request(target, { ...options, ca: tls.cert,
      lookup: (host, opts, done) => options.lookup(host, opts, (err, address, family) => {
        seen.push(address);
        done(err, Array.isArray(address) ? [{ address: '127.0.0.1', family: 4 }] : '127.0.0.1', family);
      }) }, cb);
  };
  const xml = await fetchPublicFeed('https://feed.example.com/f', { resolve: async () => [{ address: '93.184.216.34' }], request });
  assert.equal(seen.length, 1);
  assert.equal(JSON.stringify(seen[0]).includes('93.184.216.34'), true, 'connection used the pre-checked address');
  assert.deepEqual(getVerificationTexts(xml), ['rw-v-test']);
});

function harness() {
  const db = {}; let clock = 1_000_000; let feedXml = feed('');
  const sent = [];
  const handler = createFeedClaimsHandler({
    db, queueSave: async () => {}, authenticate: async (req) => req.owner,
    readBody: async (req) => Buffer.from(JSON.stringify(req.body || {})),
    json: (_res, status, data) => sent.push({ status, data }),
    fetchFeed: async () => feedXml, now: () => clock,
  });
  const call = async (owner, op, feedUrl) => {
    const req = { owner, method: op === 'list' ? 'GET' : 'POST', body: { feedUrl } };
    try { await handler(req, {}, '/api/feed-claims/' + op); return sent.pop(); }
    catch (e) { return { status: e.status, data: { error: e.message } }; }
  };
  return { db, call, tick: (ms) => { clock += ms; }, setFeed: (x) => { feedXml = x; } };
}

test('claim flow: wrong code, valid code, already claimed, expired', async () => {
  const h = harness(); const url = 'https://feed.example.com/f';
  const a = await h.call('alice', 'start', url);
  assert.equal(a.status, 200);
  h.tick(13_000);
  assert.equal((await h.call('alice', 'verify', url)).status, 422);
  h.setFeed(feed(`<podcast:txt purpose="verify">${a.data.code}</podcast:txt>`));
  h.tick(13_000);
  assert.equal((await h.call('mallory', 'verify', url)).status, 409, 'a published code is useless to another key');
  assert.equal((await h.call('alice', 'verify', url)).status, 200);
  assert.equal((await h.call('mallory', 'start', url)).status, 409);
  assert.deepEqual((await h.call('alice', 'list')).data.verified.map(v => v.feedUrl), [url]);

  const url2 = 'https://feed.example.com/other';
  assert.equal((await h.call('alice', 'start', url2)).status, 200);
  h.tick(31 * 60_000);
  assert.equal((await h.call('alice', 'verify', url2)).status, 409);
  assert.deepEqual(Object.keys(h.db.feedChallenges), [], 'expired challenges are purged');
});

test('a claim completed by someone else during the fetch is not overwritten', async () => {
  const h = harness(); const url = 'https://feed.example.com/f';
  const a = await h.call('alice', 'start', url);
  h.setFeed(feed(`<podcast:txt purpose="verify">${a.data.code}</podcast:txt>`));
  h.tick(13_000);
  const original = h.db.verifiedFeeds;
  // Simulate the other account winning while alice's fetch is in flight.
  let armed = true;
  h.db.verifiedFeeds = new Proxy(original, { get(target, key) {
    const v = target[key];
    if (armed && key === url) { armed = false; queueMicrotask(() => { target[url] = { owner: 'bob', verifiedAt: 1, method: 'podcast:txt' }; }); }
    return v;
  } });
  const r = await h.call('alice', 'verify', url);
  assert.equal(r.status, 409);
  assert.equal(original[url].owner, 'bob');
});
