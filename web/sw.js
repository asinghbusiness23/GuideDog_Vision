const CACHE = 'guidedog-v30';     // bumped — streaming cloud AI client
const CDN_CACHE = 'guidedog-cdn-v2';

const CDN_SCRIPTS = [
    'https://cdn.jsdelivr.net/npm/@tensorflow/tfjs@4.22.0/dist/tf.min.js',
    'https://cdn.jsdelivr.net/npm/@tensorflow-models/coco-ssd@2.2.3/dist/coco-ssd.min.js'
];

self.addEventListener('install', e => {
    // Don't cache app shell — always fetch fresh from network
    // Only pre-cache CDN scripts (large, rarely change)
    e.waitUntil(
        caches.open(CDN_CACHE).then(c =>
            Promise.allSettled(CDN_SCRIPTS.map(url =>
                fetch(url).then(r => r.ok ? c.put(url, r) : null).catch(() => null)
            ))
        ).then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', e => {
    e.waitUntil(
        caches.keys()
            .then(keys => Promise.all(
                keys.filter(k => k !== CACHE && k !== CDN_CACHE).map(k => caches.delete(k))
            ))
            // Do NOT call clients.claim() — avoids reload race condition on iOS Safari
    );
});

self.addEventListener('fetch', e => {
    const url = e.request.url;

    // Never intercept cloud AI, model downloads, or module imports
    if (url.includes('workers.dev') || url.includes('huggingface.co') || url.includes('esm.sh')) return;

    // CDN scripts: cache-first (they're versioned, safe to cache)
    if (url.includes('cdn.jsdelivr.net')) {
        e.respondWith(
            caches.open(CDN_CACHE).then(c =>
                c.match(e.request).then(r => r || fetch(e.request).then(res => {
                    if (res.ok) c.put(e.request, res.clone());
                    return res;
                }))
            )
        );
        return;
    }

    // Everything else: go straight to network (no caching index.html)
});
