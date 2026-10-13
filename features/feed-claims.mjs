// RelayWave read-only RSS ownership proof, using existing NIP-98 authentication.
import { lookup } from 'node:dns/promises';
import https from 'node:https';
import { isIP } from 'node:net';
import { createHash, randomBytes } from 'node:crypto';

const MAX_BYTES = 6 * 1024 * 1024;
const LIFE_MS = 30 * 60_000;
const COOLDOWN_MS = 12_000;
const XML_NS = 'https://podcastindex.org/namespace/1.0';
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = (message, status = 400) => Object.assign(new Error(message), { status });

export function normalizeFeedUrl(value) {
  if (typeof value !== 'string' || value.length > 1500) throw fail('Provide a valid HTTPS RSS feed URL');
  let url;
  try { url = new URL(value.trim()); } catch { throw fail('Provide a valid HTTPS RSS feed URL'); }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== 'https:' || url.port && url.port !== '443' || url.username || url.password || url.hash ||
      !host || isIP(host.replace(/^\[|\]$/g,'')) ||
      /(?:^|\.)(?:localhost|local|internal|test|invalid|onion)$/.test(host)) {
    throw fail('Only public HTTPS RSS feeds on port 443 are supported');
  }
  return url.href;
}

function isPublicIPv4(addr) {
  if (isIP(addr) !== 4) return false;
  const [a,b,c] = addr.split('.').map(Number);
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 ||
    a === 192 && (b === 168 || b === 0 || b === 88 && c === 99) ||
    a === 100 && b >= 64 && b <= 127 ||
    a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) ||
    a === 203 && b === 0 && c === 113 ||
    a === 192 && b === 0 && (c === 0 || c === 2));
}

export async function fetchPublicFeed(value, { resolve = lookup, request = https.request } = {}) {
  const url = new URL(normalizeFeedUrl(value));
  const ips = await resolve(url.hostname, { family: 4, all: true });
  if (!Array.isArray(ips) || ips.length === 0 || ips.some(ip => !isPublicIPv4(ip.address))) {
    throw fail('Feed DNS must resolve to public IPv4 addresses only', 422);
  }
  // Pin the verified IP: no DNS rebinding between the IP check and connection.
  // TLS still validates the original host name. Do not follow redirects.
  return await new Promise((resolveResult,rejectResult) => {
    let done = false;
    const finish = (err,body) => {
      if (done) return;
      done = true;
      err ? rejectResult(err) : resolveResult(body);
    };
    const req = request(url,{
      method:'GET',
      lookup:(_hostname,_options,callback) => callback(null,ips[0].address,4),
      timeout:9000,
      maxHeaderSize:16384,
      headers:{
        'Accept':'application/rss+xml, application/xml, text/xml;q=0.9',
        'Accept-Encoding':'identity',
        'User-Agent':'RelayWave-OwnershipCheck/0.1'
      }
    },res=>{
      if(res.statusCode !== 200) {
        res.resume();
        finish(fail('RSS host responded with HTTP '+res.statusCode,422));
        return;
      }
      if(Number(res.headers['content-length'] || 0) > MAX_BYTES) {
        res.destroy();
        finish(fail('RSS feed exceeds the 6 MiB verification limit',413));
        return;
      }
      let bytes=0;
      const chunks=[];
      res.on('data',chunk=>{
        bytes += chunk.length;
        if(bytes>MAX_BYTES) {
          res.destroy();
          finish(fail('RSS feed exceeds the 6 MiB verification limit',413));
          return;
        }
        chunks.push(chunk);
      });
      res.on('end',()=>finish(null,Buffer.concat(chunks).toString('utf8')));
      res.on('error',()=>finish(fail('Could not read RSS feed',422)));
    });
    req.on('timeout',()=>req.destroy(new Error('timeout')));
    req.on('error',()=>finish(fail('Could not fetch RSS feed securely',422)));
    req.end();
  });
}

function readAttributes(source) {
  const values={};
  for(const m of source.matchAll(/([^\s=/>]+)\s*=\s*(["'])(.*?)\2/gs)) values[m[1]]=m[3];
  return values;
}

export function getVerificationTexts(xml) {
  if(typeof xml!=='string' || xml.length>MAX_BYTES || /<!\s*(?:DOCTYPE|ENTITY)/i.test(xml)) {
    throw fail('Invalid or unsafe XML',422);
  }
  const result=[],stack=[];
  const addText=value=>{if(stack.length)stack.at(-1).text += value;};
  for(let pos=0;pos<xml.length;) {
    const start=xml.indexOf('<',pos);
    if(start<0){addText(xml.slice(pos));break;}
    if(start>pos)addText(xml.slice(pos,start));
    if(xml.startsWith('<!--',start)) {
      const end=xml.indexOf('-->',start+4);
      if(end<0)throw fail('Malformed XML comment',422);
      pos=end+3; continue;
    }
    if(xml.startsWith('<![CDATA[',start)) {
      const end=xml.indexOf(']]>',start+9);
      if(end<0)throw fail('Malformed XML CDATA',422);
      addText(xml.slice(start+9,end));
      pos=end+3;continue;
    }
    if(xml.startsWith('<?',start)) {
      const end=xml.indexOf('?>',start+2);
      if(end<0)throw fail('Malformed XML instruction',422);
      pos=end+2;continue;
    }
    if(xml.startsWith('<!',start))throw fail('Unsupported XML declaration',422);
    let end=start+1,quote='';
    for(;end<xml.length;end++) {
      const ch=xml[end];
      if(quote){if(ch===quote)quote='';}
      else if(ch==='"'||ch==="'")quote=ch;
      else if(ch==='>')break;
    }
    if(end>=xml.length)throw fail('Malformed RSS XML',422);
    let tag=xml.slice(start+1,end).trim();
    pos=end+1;
    const close=tag.startsWith('/');
    if(close)tag=tag.slice(1).trim();
    const selfClose=tag.endsWith('/');
    if(selfClose)tag=tag.slice(0,-1).trim();
    const match=/^([A-Za-z_][A-Za-z0-9_.:-]*)(?:\s+([\s\S]*))?$/.exec(tag);
    if(!match)throw fail('Malformed XML tag',422);
    const name=match[1];
    if(close) {
      const top=stack.pop();
      if(!top || top.name!==name)throw fail('Unbalanced RSS tags',422);
      if(top.isVerify && top.text.trim())result.push(top.text.trim());
      continue;
    }
    const attrs=readAttributes(match[2]||'');
    const ns={...(stack.at(-1)?.ns||{})};
    for(const [key,value] of Object.entries(attrs)){
      if(key==='xmlns')ns['']=value;
      if(key.startsWith('xmlns:'))ns[key.slice(6)]=value;
    }
    const [prefix,local]=name.includes(':')?name.split(':',2):['',name];
    const directChannel=stack.length===2 && stack[0].name.toLowerCase()==='rss' && stack[1].name.toLowerCase()==='channel';
    const node={
      name,ns,text:'',
      isVerify:directChannel && local==='txt' && ns[prefix]===XML_NS && attrs.purpose==='verify'
    };
    if(!selfClose)stack.push(node);
  }
  if(stack.length)throw fail('Incomplete RSS feed',422);
  return result;
}

export function createFeedClaimsHandler({db,queueSave,authenticate,readBody,json,fetchFeed=fetchPublicFeed,now=()=>Date.now()}) {
  db.feedChallenges ||= {};
  db.verifiedFeeds ||= {};
  const headers={'cache-control':'no-store'};
  return async (req,res,path)=>{
    if(!['/api/feed-claims/start','/api/feed-claims/verify','/api/feed-claims/list'].includes(path))return false;
    if(!((path==='/api/feed-claims/list' && req.method==='GET') ||
      (req.method==='POST' && path!=='/api/feed-claims/list'))) {
      json(res,405,{error:'Method not allowed'},headers);return true;
    }
    const raw=req.method==='POST'?await readBody(req,4096):Buffer.alloc(0);
    const owner=await authenticate(req,raw);
    if(path==='/api/feed-claims/list') {
      const verified=Object.entries(db.verifiedFeeds)
        .filter(([,v])=>v.owner===owner)
        .map(([feedUrl,v])=>({feedUrl,verifiedAt:v.verifiedAt}));
      json(res,200,{verified},headers);return true;
    }
    let body;
    try{body=JSON.parse(raw.toString('utf8')||'{}');}catch{throw fail('Invalid JSON body');}
    const feedUrl=normalizeFeedUrl(body.feedUrl);
    if(db.verifiedFeeds[feedUrl] && db.verifiedFeeds[feedUrl].owner!==owner){
      throw fail('Already claimed by another account; manual review required',409);
    }
    const key=owner+':'+hash(feedUrl);
    const current=now();
    if(path==='/api/feed-claims/start'){
      const active=Object.entries(db.feedChallenges)
        .filter(([k,v])=>k.startsWith(owner+':') && v.expiresAt>current);
      if(active.length>=5 && !db.feedChallenges[key])throw fail('Too many open verification challenges',429);
      if(db.feedChallenges[key] && current-db.feedChallenges[key].createdAt<COOLDOWN_MS){
        throw fail('Please wait before generating another challenge',429);
      }
      const code='rw-v-'+randomBytes(18).toString('hex');
      db.feedChallenges[key]={
        owner,feedUrl,digest:hash(code),createdAt:current,expiresAt:current+LIFE_MS,
        attempts:0,lastAttemptAt:0
      };
      await queueSave();
      json(res,200,{feedUrl,code,expiresAt:current+LIFE_MS,method:'podcast:txt purpose="verify"'},headers);
      return true;
    }
    const challenge=db.feedChallenges[key];
    if(!challenge || current>=challenge.expiresAt)throw fail('Challenge missing or expired. Generate a new code.',409);
    if(challenge.attempts>=8)throw fail('Too many failed attempts. Generate a new code.',429);
    if(current-challenge.lastAttemptAt<COOLDOWN_MS)throw fail('Wait a moment before retrying',429);
    challenge.lastAttemptAt=current;
    challenge.attempts++;
    await queueSave();
    const xml=await fetchFeed(feedUrl);
    if(!getVerificationTexts(xml).some(value=>hash(value)===challenge.digest)){
      json(res,422,{error:'Verification code not found in the channel-level podcast:txt purpose="verify" field. Wait for your host to update RSS, then retry.'},headers);
      return true;
    }
    if(now()>=challenge.expiresAt)throw fail('Challenge expired while fetching the RSS feed',409);
    db.verifiedFeeds[feedUrl]={owner,verifiedAt:now(),method:'podcast:txt'};
    delete db.feedChallenges[key];
    await queueSave();
    json(res,200,{verified:true,feedUrl,verifiedAt:db.verifiedFeeds[feedUrl].verifiedAt,next:'Private import preview can follow; no media was copied'},headers);
    return true;
  };
}
