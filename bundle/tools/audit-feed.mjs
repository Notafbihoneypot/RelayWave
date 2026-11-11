#!/usr/bin/env node
import { writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const argv = process.argv.slice(2);
const url = argv.find(a => !a.startsWith('--'));
const copyMedia = argv.includes('--copy-media');
const outArg = argv.find(a => a.startsWith('--out='));
const outDir = resolve(outArg ? outArg.slice(6) : './feed-audit');
if (!url) {
  console.error('Usage: node tools/audit-feed.mjs <rss-url> [--copy-media] [--out=DIR]');
  process.exit(2);
}

const UA = 'RelayWave-OpenCast-Migration-Audit/0.1 (+local shadow import)';
const text = s => String(s ?? '').replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').trim();
const decodeXml = s => text(s)
  .replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')
  .replace(/&quot;/g,'"').replace(/&apos;/g,"'")
  .replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n)))
  .replace(/&#x([0-9a-f]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16)));
const one = (xml, tag) => {
  const escaped = tag.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const m = xml.match(new RegExp(`<${escaped}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${escaped}>`, 'i'));
  return m ? decodeXml(m[1]) : '';
};
const attr = (s, name) => {
  const m = s.match(new RegExp(`${name}\\s*=\\s*(["'])(.*?)\\1`, 'i'));
  return m ? decodeXml(m[2]) : '';
};
const human = n => {
  if (n == null || Number.isNaN(n)) return 'unknown';
  const u=['B','KB','MB','GB','TB']; let i=0,x=n;
  while(x>=1000&&i<u.length-1){x/=1000;i++;}
  return `${x.toFixed(i<2?1:2)} ${u[i]}`;
};

async function fetchWithTimeout(resource, opts={}, ms=20000) {
  const ac = new AbortController();
  const t=setTimeout(()=>ac.abort(),ms);
  try { return await fetch(resource,{...opts,signal:ac.signal,headers:{'user-agent':UA,...(opts.headers||{})},redirect:'follow'}); }
  finally { clearTimeout(t); }
}

console.log(`Fetching RSS: ${url}`);
const fr = await fetchWithTimeout(url, {}, 30000);
if (!fr.ok) throw new Error(`Feed fetch failed: HTTP ${fr.status}`);
const xml = await fr.text();
await mkdir(outDir,{recursive:true});
await writeFile(resolve(outDir,'source-feed.xml'),xml);

const channel = xml.match(/<channel(?:\s[^>]*)?>([\s\S]*?)<\/channel>/i)?.[1] || xml;
const itemMatches = [...channel.matchAll(/<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi)];
const p2tags = [...new Set([...xml.matchAll(/<podcast:([A-Za-z0-9_-]+)/g)].map(m=>m[1].toLowerCase()))].sort();
const channelTitle = one(channel,'title');
const channelDescription = one(channel,'description');
const channelLink = one(channel,'link');
const imageMatch = channel.match(/<itunes:image\b[^>]*>/i)?.[0] || '';
const channelImage = attr(imageMatch,'href') || one(channel,'url');

const episodes = itemMatches.map((m,i)=>{
  const it=m[1];
  const encTag=it.match(/<enclosure\b[^>]*>/i)?.[0]||'';
  const guid=one(it,'guid');
  const title=one(it,'title');
  const pubDate=one(it,'pubDate');
  const duration=one(it,'itunes:duration');
  return {
    index:i+1,title,guid,pubDate,duration,
    enclosure:{url:attr(encTag,'url'),length:Number(attr(encTag,'length'))||null,type:attr(encTag,'type')},
    hasTranscript:/<podcast:transcript\b/i.test(it),
    hasChapters:/<podcast:chapters\b/i.test(it),
    hasSoundbite:/<podcast:soundbite\b/i.test(it),
    hasFunding:/<podcast:funding\b/i.test(it),
  };
});

const guidSet = new Set();
const duplicateGuids=[];
for(const e of episodes){ if(e.guid){ if(guidSet.has(e.guid)) duplicateGuids.push(e.guid); guidSet.add(e.guid); } }

async function probe(e) {
  const u=e.enclosure.url;
  if(!u) return {...e,probe:{ok:false,error:'missing enclosure URL'}};
  let r;
  try { r=await fetchWithTimeout(u,{method:'HEAD'},20000); }
  catch(err){ return {...e,probe:{ok:false,error:`HEAD ${err.message}`}}; }
  let len=Number(r.headers.get('content-length'))||e.enclosure.length||null;
  let acceptRanges=r.headers.get('accept-ranges')||'';
  let contentType=r.headers.get('content-type')||e.enclosure.type||'';
  if((!r.ok || !len || !acceptRanges) && r.status !== 405){
    // do not download body on a successful HEAD unless needed
  }
  if(!r.ok || !len || r.status===405){
    try {
      const rr=await fetchWithTimeout(u,{headers:{Range:'bytes=0-0'}},20000);
      const cr=rr.headers.get('content-range')||'';
      const mm=cr.match(/\/(\d+)$/);
      if(mm) len=Number(mm[1]);
      if(!contentType) contentType=rr.headers.get('content-type')||'';
      acceptRanges=acceptRanges||rr.headers.get('accept-ranges')|| (rr.status===206?'bytes':'');
      try { await rr.body?.cancel(); } catch {}
      return {...e,probe:{ok:rr.ok || rr.status===206,status:rr.status,length:len,contentType,acceptRanges,finalUrl:rr.url}};
    } catch(err){ return {...e,probe:{ok:false,status:r.status,length:len,contentType,acceptRanges,error:`range probe ${err.message}`}}; }
  }
  return {...e,probe:{ok:r.ok,status:r.status,length:len,contentType,acceptRanges,finalUrl:r.url}};
}

const results=[];
const concurrency=6;
let cursor=0;
async function worker(){
  while(true){
    const i=cursor++; if(i>=episodes.length) return;
    const p=await probe(episodes[i]); results[i]=p;
    const size=p.probe?.length?human(p.probe.length):'unknown';
    console.log(`[${i+1}/${episodes.length}] ${p.probe?.ok?'OK':'WARN'} ${size} ${p.title.slice(0,70)}`);
  }
}
await Promise.all(Array.from({length:Math.min(concurrency,Math.max(1,episodes.length))},worker));

let totalBytes=0, known=0, broken=0, rangeReady=0;
for(const e of results){
  if(e.probe?.length){ totalBytes+=e.probe.length; known++; }
  if(!e.probe?.ok) broken++;
  if(String(e.probe?.acceptRanges).toLowerCase().includes('bytes') || e.probe?.status===206) rangeReady++;
}

const report={
  auditedAt:new Date().toISOString(), sourceFeed:url,
  show:{title:channelTitle,description:channelDescription,link:channelLink,image:channelImage},
  summary:{
    episodeCount:episodes.length,
    enclosureBytesKnown:known,
    estimatedSourceBytes:totalBytes,
    estimatedSourceHuman:human(totalBytes),
    twoBlossomCopiesBytes:totalBytes*2,
    twoBlossomCopiesHuman:human(totalBytes*2),
    twoCopiesPlusBackupBytes:totalBytes*3,
    twoCopiesPlusBackupHuman:human(totalBytes*3),
    missingGuids:episodes.filter(e=>!e.guid).length,
    duplicateGuidCount:duplicateGuids.length,
    brokenEnclosures:broken,
    byteRangeReady:rangeReady,
    transcriptEpisodes:episodes.filter(e=>e.hasTranscript).length,
    chaptersEpisodes:episodes.filter(e=>e.hasChapters).length,
    soundbiteEpisodes:episodes.filter(e=>e.hasSoundbite).length,
    fundingEpisodes:episodes.filter(e=>e.hasFunding).length,
    podcasting20Tags:p2tags,
  },
  duplicateGuids,
  episodes:results,
};
await writeFile(resolve(outDir,'audit.json'),JSON.stringify(report,null,2));
const csv=['index,title,guid,pubDate,enclosure_url,bytes,status,range,type'];
const q=v=>'"'+String(v??'').replaceAll('"','""')+'"';
for(const e of results) csv.push([e.index,e.title,e.guid,e.pubDate,e.enclosure.url,e.probe?.length||'',e.probe?.status||'',e.probe?.acceptRanges||'',e.probe?.contentType||''].map(q).join(','));
await writeFile(resolve(outDir,'episodes.csv'),csv.join('\n'));

if(copyMedia){
  const mediaDir=resolve(outDir,'media'); await mkdir(mediaDir,{recursive:true});
  console.log('\nShadow-copying media. This does NOT modify the source feed or directories.');
  for(let i=0;i<results.length;i++){
    const e=results[i]; if(!e.enclosure.url || !e.probe?.ok) continue;
    const ext=(new URL(e.enclosure.url).pathname.match(/(\.[A-Za-z0-9]{2,5})$/)?.[1]||'.bin');
    const safeGuid=(e.guid||`episode-${i+1}`).replace(/[^A-Za-z0-9._-]+/g,'_').slice(0,120);
    const dest=resolve(mediaDir,`${String(i+1).padStart(4,'0')}-${safeGuid}${ext}`);
    console.log(`[${i+1}/${results.length}] copy ${e.title.slice(0,60)}`);
    const r=await fetchWithTimeout(e.enclosure.url,{},120000);
    if(!r.ok){console.warn(`  skipped HTTP ${r.status}`);continue;}
    const ab=await r.arrayBuffer(); await writeFile(dest,new Uint8Array(ab));
  }
}

console.log('\n=== Migration audit ===');
console.log(`Show: ${channelTitle || '(untitled)'}`);
console.log(`Episodes: ${episodes.length}`);
console.log(`Source media (known enclosures): ${human(totalBytes)} (${known}/${episodes.length} sized)`);
console.log(`2 Blossom copies: ${human(totalBytes*2)}`);
console.log(`2 copies + off-site backup: ${human(totalBytes*3)}`);
console.log(`Missing GUIDs: ${report.summary.missingGuids}`);
console.log(`Duplicate GUIDs: ${report.summary.duplicateGuidCount}`);
console.log(`Broken enclosures: ${broken}`);
console.log(`Byte-range ready: ${rangeReady}/${episodes.length}`);
console.log(`Podcasting 2.0 tags: ${p2tags.join(', ') || 'none detected'}`);
console.log(`Report: ${resolve(outDir,'audit.json')}`);
console.log(`Episode CSV: ${resolve(outDir,'episodes.csv')}`);
