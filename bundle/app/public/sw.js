const CACHE='opencast-test-v3';
const ASSETS=['/','/app.css','/app.js','/manifest.webmanifest','/icons/icon.svg'];
const CACHEABLE=new Set(ASSETS);
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET')return;
  const u=new URL(e.request.url);
  if(u.origin!==self.location.origin||!CACHEABLE.has(u.pathname))return;
  e.respondWith(fetch(e.request).then(r=>{
    if(r.ok&&r.type==='basic'){const clone=r.clone();caches.open(CACHE).then(c=>c.put(e.request,clone));}
    return r;
  }).catch(()=>caches.match(e.request)));
});
