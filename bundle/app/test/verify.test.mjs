import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
process.env.NODE_ENV='test';
const { verifyEvent, schnorrVerify, signEvent } = await import('../server.mjs');

test('passes BIP-340 vector 0', () => {
  const pub='F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9';
  const msg='0000000000000000000000000000000000000000000000000000000000000000';
  const sig='E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0';
  assert.equal(schnorrVerify(sig,msg,pub), true);
});

test('rejects BIP-340 invalid vector 6', () => {
  const pub='DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659';
  const msg='243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89';
  const sig='FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A14602975563CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2';
  assert.equal(schnorrVerify(sig,msg,pub), false);
});

test('signEvent produces a verifiable Nostr event', () => {
  const secret=Buffer.from('11'.repeat(32),'hex');
  const signed=signEvent({kind:1,created_at:1700000000,tags:[['t','test']],content:'hello'},secret);
  assert.equal(verifyEvent(signed),true);
  assert.equal(signed.pubkey.length,64);
  assert.equal(signed.sig.length,128);
});

test('verifyEvent rejects tampering', () => {
  const secret=Buffer.from('22'.repeat(32),'hex');
  const signed=signEvent({kind:1,created_at:1700000000,tags:[],content:'hello'},secret);
  signed.content='tampered';
  const expected=createHash('sha256').update(JSON.stringify([0,signed.pubkey,signed.created_at,signed.kind,signed.tags,signed.content])).digest('hex');
  assert.notEqual(signed.id, expected);
  assert.equal(verifyEvent(signed), false);
});

test('privacy analytics classifies clients coarsely and rejects bot traffic', async () => {
  const { classifyClient, isLikelyBot } = await import('../server.mjs');
  assert.equal(classifyClient('AntennaPod/3.5.0 Android/17 Pixel-Whatever'), 'AntennaPod');
  assert.equal(classifyClient('XMRPod/2.0 Android'), 'XMRPod');
  assert.equal(isLikelyBot('Googlebot/2.1'), true);
  assert.equal(isLikelyBot('AntennaPod/3.5.0'), false);
});

test('privacy analytics suppresses small country/app/referrer cells', async () => {
  const { aggregateAnonymous, analyticsSnapshot } = await import('../server.mjs');
  const pubkey='ab'.repeat(32);
  for(let i=0;i<4;i++) aggregateAnonymous(pubkey,{itemId:'ep-small',itemType:'episode',title:'Small',country:'US',client:'XMRPod',referrer:'Nostr'});
  for(let i=0;i<5;i++) aggregateAnonymous(pubkey,{itemId:'ep-visible',itemType:'episode',title:'Visible',country:'DE',client:'AntennaPod',referrer:'Search'});
  const out=analyticsSnapshot(pubkey,'1d');
  assert.equal(out.countries.US, undefined);
  assert.equal(out.countries.DE, 5);
  assert.equal(out.countries.Other, 4);
  assert.equal(out.clients.XMRPod, undefined);
  assert.equal(out.clients.AntennaPod, 5);
  assert.equal(out.clients.Other, 4);
  assert.equal(out.referrers.Nostr, undefined);
  assert.equal(out.referrers.Search, 5);
  assert.equal(out.referrers.Other, 4);
  assert.equal(out.privacy.rawIpRetentionDays, 0);
  assert.equal(out.privacy.cityTracking, false);
  const serialized=JSON.stringify(out);
  assert.equal(serialized.includes('user-agent'), false);
  assert.equal(serialized.includes('ipAddress'), false);
});

test('country values are limited to coarse ISO-like codes', async () => {
  const { safeCountry } = await import('../server.mjs');
  assert.equal(safeCountry('us'),'US');
  assert.equal(safeCountry('Detroit, MI'),'ZZ');
  assert.equal(safeCountry('T1'),'ZZ');
  assert.equal(safeCountry(''),'ZZ');
});

test('service worker caches only the static app shell', async () => {
  const { readFile } = await import('node:fs/promises');
  const sw = await readFile(new URL('../public/sw.js', import.meta.url), 'utf8');
  assert.match(sw, /CACHEABLE\.has\(u\.pathname\)/);
  assert.doesNotMatch(sw, /c\.put\(e\.request.*api/i);
  assert.doesNotMatch(sw, /\/api\/analytics/);
});
