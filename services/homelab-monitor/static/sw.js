// Homelab Monitor — app shell only.
const CACHE = "homelab-temp-static-v15";
const FILES = [
  "/", "/index.html", "/style.css", "/app.js",
  "/favicon.svg", "/manifest.webmanifest",
  "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll(FILES))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k =>
          k.startsWith("homelab-temp-static-") && k !== CACHE
        ).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Never cache temperatures or other API data.
  if (url.pathname.startsWith("/api/")) return;
  if (!FILES.includes(url.pathname)) return;

  event.respondWith(
    fetch(request).then(response => {
      if (response.ok) {
        const copy = response.clone();
        event.waitUntil(
          caches.open(CACHE)
            .then(cache => cache.put(request, copy))
        );
      }
      return response;
    }).catch(() =>
      caches.match(request)
        .then(response => response || Response.error())
    )
  );
});
