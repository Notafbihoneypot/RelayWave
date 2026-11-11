// Regression tests for the security review fixes. Dependency-free; the server
// listens on an ephemeral loopback port and writes to a temporary directory.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

process.env.NODE_ENV = 'test';
process.env.TEST_MODE = '1';
process.env.DEMO_SECRET = '';
process.env.PUBLIC_BASE_URL = '';
process.env.DATA_DIR = mkdtempSync(join(tmpdir(), 'rw-sec-'));
const { server, signEvent, verifyEvent } = await import('../server.mjs');

await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => server.close());

const secret = Buffer.from('33'.repeat(32), 'hex');
const sha = (s) => createHash('sha256').update(s).digest('hex');
const now = () => Math.floor(Date.now() / 1000);
function auth(method, path, body) {
  const tags = [['u', base + path], ['method', method]];
  if (body != null) tags.push(['payload', sha(body)]);
  // a random tag keeps two requests in the same second from sharing an event id
  tags.push(['nonce', Math.random().toString(36).slice(2)]);
  const ev = signEvent({ kind: 27235, created_at: now(), tags, content: '' }, secret);
  return 'Nostr ' + Buffer.from(JSON.stringify(ev)).toString('base64');
}
async function call(method, path, payload, header) {
  const body = payload == null ? undefined : JSON.stringify(payload);
  const res = await fetch(base + path, { method, body, headers: { authorization: header ?? auth(method, path, body) } });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}
const article = (slug, content = 'hello') => ({ event: signEvent({ kind: 30023, created_at: now(), tags: [['d', slug], ['title', 'T']], content }, secret) });

test('events with malformed tags are rejected', () => {
  const good = signEvent({ kind: 1, created_at: 1, tags: [['t', 'x']], content: '' }, secret);
  assert.equal(verifyEvent(good), true);
  for (const tags of [[null], [['title', { a: 1 }]], [[]], ['x']]) {
    assert.equal(verifyEvent({ ...good, tags }), false);
  }
});

test('the demo key is not derivable from the source', async () => {
  const { demoPubkey } = await (await fetch(base + '/api/config')).json();
  const old = signEvent({ kind: 1, created_at: 1, tags: [], content: '' },
    createHash('sha256').update('nostr-publisher-test-mode-do-not-use-for-real-funds').digest()).pubkey;
  assert.match(demoPubkey, /^[0-9a-f]{64}$/);
  assert.notEqual(demoPubkey, old);
});

test('the test signer refuses cross-site requests', async () => {
  const body = JSON.stringify({ unsigned: { kind: 1, created_at: 1, tags: [], content: '' } });
  const post = (headers) => fetch(base + '/api/test/sign', { method: 'POST', body, headers }).then(r => r.status);
  assert.equal(await post({ origin: 'https://evil.example' }), 403);
  assert.equal(await post({ 'sec-fetch-site': 'cross-site' }), 403);
  assert.equal(await post({ origin: base }), 200);
  assert.equal(await post({}), 200);
});

test('a signed request cannot be replayed', async () => {
  const body = JSON.stringify({ title: 'Show' });
  const header = auth('PUT', '/api/publication', body);
  const send = () => fetch(base + '/api/publication', { method: 'PUT', body, headers: { authorization: header } }).then(r => r.status);
  assert.equal(await send(), 200);
  assert.equal(await send(), 401);
});

test('article limits and reserved identifiers', async () => {
  assert.equal((await call('POST', '/api/articles', article('first'))).status, 200);
  for (const slug of ['__proto__', 'constructor']) {
    assert.equal((await call('POST', '/api/articles', article(slug))).status, 400, slug);
  }
  assert.equal((await call('POST', '/api/articles', article('big', 'x'.repeat(200001)))).status, 413);
  const pk = article('x').event.pubkey;
  assert.equal((await fetch(`${base}/p/${pk}/article/first`)).status, 200);
  assert.equal((await fetch(`${base}/p/${pk}/article/constructor`)).status, 404);
  assert.equal((await fetch(`${base}/p/${pk}/article/toString`)).status, 404);
});

test('the tip page shows the address card', async () => {
  const xmr = '4' + 'A'.repeat(94);
  assert.equal((await call('PUT', '/api/publication', { title: 'Show', xmrAddress: xmr })).status, 200);
  const pk = article('x').event.pubkey;
  const html = await (await fetch(`${base}/p/${pk}/tip`)).text();
  assert.match(html, /<h2>Direct Monero tip<\/h2>/);
  assert.equal(html.includes(`<code>${xmr}</code>`), true);
});

test('static files cannot escape the public directory', async () => {
  for (const p of ['/..%2fserver.mjs', '/%2e%2e/server.mjs', '/../server.mjs', '/..\\server.mjs']) {
    const res = await fetch(base + p);
    assert.notEqual(res.status, 200, p);
  }
});
