const CACHE = 'guidedog-v44';       // bumped — blind-hint moved above buttons
const CDN_CACHE = 'guidedog-cdn-v3'; // bumped — added YAMNet CDN URL

const CDN_SCRIPTS = [
    'https://cdn.jsdelivr.net/npm/@tensorflow/tfjs@4.22.0/dist/tf.min.js',
    'https://cdn.jsdelivr.net/npm/@tensorflow-models/coco-ssd@2.2.3/dist/coco-ssd.min.js',
    // Tesseract (lazy-loaded for OCR / bill reading) — pre-cache so it's ready
    'https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js',
];

// These origins serve large model files / ES modules and should NEVER be cached
// by the service worker — they have their own CDN caching and change frequently.
const PASSTHROUGH_ORIGINS = [
    'workers.dev',          // cloud AI proxy
    'huggingface.co',       // Depth-Anything model weights
    'esm.sh',               // @xenova/transformers ES module CDN
    'kaggle.com',           // YAMNet model (tf.loadGraphModel fromTFHub)
    'tensorflow.org',       // TF Hub redirects
    'raw.githubusercontent.com', // YAMNet class map CSV
];

self.addEventListener('install', e => {
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

    // Never intercept passthrough origins
    if (PASSTHROUGH_ORIGINS.some(o => url.includes(o))) return;

    // CDN scripts: cache-first (versioned URLs — safe to cache long-term)
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

    // Everything else (index.html, manifest, sw.js): straight to network — always fresh
});