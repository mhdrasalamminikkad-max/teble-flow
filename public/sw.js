/* TABLEFLOW: offline fallback only. Never cache authenticated HTML, API responses,
   orders, session data, or third-party pages. No offline order queue. */
const CACHE='tableflow-public-v1';
const FILES=['/offline.html','/icons/icon-192.png','/icons/icon-512.png'];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(FILES)))});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('tableflow-public-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',event=>{const request=event.request,url=new URL(request.url);if(request.method!=='GET'||url.origin!==self.location.origin)return;if(request.mode==='navigate'){event.respondWith(fetch(request).catch(async()=>await caches.match('/offline.html')||new Response('You are offline. Reconnect and try again.',{status:503,headers:{'Content-Type':'text/plain'}})));return}if(FILES.includes(url.pathname)&&!url.search){event.respondWith(caches.match(request).then(cached=>cached||fetch(request)))}});
