// Plainly's service worker: makes the installed app open and work offline. It only caches the app itself and the
// fictional samples; reports and vitals never pass through it (they stay in the page and IndexedDB).
const VERSION = "__VERSION__";
const PRECACHE = __FILES__;
const CACHE = `plainly-${VERSION}`;

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k.startsWith("plainly-") && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const fonts = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (url.origin !== self.location.origin && !fonts) return; // Firebase and AI calls go straight to the network

  // Pages: network first so updates show, the cached app when offline.
  if (req.mode === "navigate") {
    e.respondWith(fetch(req).then((r) => { caches.open(CACHE).then((c) => c.put("/", r.clone())); return r; }).catch(() => caches.match("/", { ignoreVary: true })));
    return;
  }
  // Everything else (hashed assets, icons, samples, fonts): cache first, filled on first use. ignoreVary because
  // module scripts send an Origin header and servers answer "Vary: Origin", which would otherwise never match offline.
  e.respondWith(caches.match(req, { ignoreVary: true }).then((hit) => hit || fetch(req).then((r) => {
    if (r.ok || r.type === "opaque") { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
    return r;
  })));
});
