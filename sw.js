const V='libro-cantos-v16';
const CORE=['./','./index.html','./manifest.json','./icon-192.png','./icon-512.png','./apple-touch-icon.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET') return;
  const u=new URL(e.request.url); if(u.origin!==location.origin&&u.hostname!=='cdn.jsdelivr.net') return;
  const u=new URL(e.request.url); if(u.origin!==location.origin&&u.hostname!=='cdn.jsdelivr.net') return;
  e.respondWith(caches.match(e.request,{ignoreSearch:true}).then(hit=>{
    const net=fetch(e.request).then(r=>{ if(r&&(r.ok||r.type==='opaque')){ const cp=r.clone(); caches.open(V).then(c=>c.put(e.request,cp)); } return r; }).catch(()=>hit||(e.request.mode==='navigate'?caches.match('./index.html'):undefined));
    return hit||net;
  }));
});
