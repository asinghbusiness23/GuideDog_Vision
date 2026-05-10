const CACHE = 'guidedog-v9';      // bumped — colorblind toggle, SVG cam icon, no potted plant
const CDN_CACHE = 'guidedog-cdn-v1';

const APP_SHELL = ['/GuideDog/', '/GuideDog/index.html', '/GuideDog/manifest.json'];

const CDN_SCRIPTS = [
    'https://cdn.jsdelivr.net/npm/@tensorflow/tfjs@4.22.0/dist/tf.min.js',
    'https://cdn.jsdelivr.net/npm/@tensorflow-models/coco-ssd@2.2.3/dist/coco-ssd.min.js'
];

self.addEventListener('install', e => {
    e.waitUntil(
        // App shell MUST succeed; CDN pre-cache is best-effort (large files can time out)
        caches.open(CACHE)
            .then(c => c.addAll(APP_SHELL))
            .then(() => {
                // Don't block install on CDN fetch — cache opportunistically
                caches.open(CDN_CACHE).then(c =>
                    Promise.allSettled(CDN_SCRIPTS.map(url =>
                        fetch(url).then(r => r.ok ? c.put(url, r) : null).catch(() => null)
                    ))
                );
            })
            .then(() => self.skipWaiting())   // activate immediately, don't wait for tabs to close
    );
});

self.addEventListener('activate', e => {
    e.waitUntil(
        caches.keys()
            .then(keys => Promise.all(
                keys.filter(k => k !== CACHE && k !== CDN_CACHE).map(k => caches.delete(k))
            ))
            .then(() => self.clients.claim())
    );
});

self.addEventListener('fetch', e => {
    const url = e.request.url;

    // Never intercept cloud AI or model download requests
    if (url.includes('workers.dev') || url.includes('huggingface.co') || url.includes('esm.sh')) return;

    // CDN scripts: cache-first, network fallback
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

    // App shell: cache-first, network fallback
    e.respondWith(
        caches.match(e.request).then(r => r || fetch(e.request))
    );
});
