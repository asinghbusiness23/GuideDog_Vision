# Web Architecture

## Technical Complexities

Running real time computer vision in a web browser, on a phone, on iOS Safari, with two ML models loaded at once, runs into hard memory and timing constraints. Most of the architecture exists to work around them.

Dual loops handle the speed gap. A fast loop (50 ms, 20 fps) does the cheap stuff (pixel wall check, UI, speech). A slow loop (200 ms, 5 fps) does the expensive stuff (object detection, depth model, cloud AI). Walking speed math: at 1.4 m/s, a person covers 7 cm in 50 ms but 28 cm in 200 ms. The user needs 50 ms response for walls, but ML inference can't run that fast.

Single owner UI writes. The fast loop is the only path that touches the DOM. The slow loop only writes to the shared state object. An earlier version had both loops calling `updateUI` and the alert box flickered between states within a single animation frame.

Camera loads before any model. The pixel variance wall check needs video frames from the first cycle. If COCO-SSD loaded first, the user would be unprotected during the 3 to 5 second model download.

Single file deployment. All HTML, CSS, and JavaScript live in one `index.html` file. No build tools, no bundler, no framework. One file, one request, no dependency resolution.

COCO-SSD loads through a `<script>` tag, not as an ES module. MediaPipe's ES module crashed iOS Safari during WebAssembly init. Script tag avoids it.

Transformers.js v2, not v3. v3 uses ONNX Runtime Web which combined with TensorFlow.js exceeds the per tab memory budget on 4 GB iPhones. v2 has a lighter engine that fits.

## Single file structure

The entire website is in one `index.html`. Supporting files are `manifest.json` (PWA metadata) and `sw.js` (service worker for offline caching). The service worker cache version is currently `guidedog-v48`.

A single file loads in one request and has no dependency resolution problems. For a project this size that's unusual, but it eliminates an entire class of deployment failures.

## External scripts

TensorFlow.js (`@tensorflow/tfjs@4.22.0`) and COCO-SSD (`@tensorflow-models/coco-ssd@2.2.3`) load through `<script>` tags with SRI integrity hashes. These provide the object detection runtime.

Transformers.js v2 (`@xenova/transformers@2.17.2`) loads as an ES module via `<script type="module">`. It provides the Depth-Anything runtime. The module dispatches a `tx-ready` custom event when ready, or `tx-failed` if it can't load. A fallback CDN (`esm.sh`) is attempted if `jsdelivr` fails.

MediaPipe Audio Classifier loads on demand when the user enters Hear mode. It runs YAMNet through an AudioWorklet to classify environmental sounds locally.

## Dual loops

### protectionLoop (200 ms, 5 fps)

Heavy computation:

- Runs COCO-SSD object detection
- Updates depth calibration from detected objects
- Fires async depth model scans (every 400 ms)
- Fires async cloud AI scans (every 5 seconds)
- Writes state data: `state.localDetections`, `state._mainThreat`, `state.currentObstacle`, `state.depthHazard`, `state.aiHazard`

This loop never touches the UI directly. It only writes to the shared state.

### fastHazardLoop (50 ms, 20 fps)

All output:

- Runs the fast wall check (pixel variance, under 5 ms)
- Reads cached depth values from `state.depthHistory`
- Reads active hazards from `state.depthHazard` and `state.aiHazard`
- Reads COCO-SSD results from `state._mainThreat` and `state.currentObstacle`
- Calls `updateUI` for alert box colors, text, and badge state
- Calls `speakAlert`, `playAlertSound`, `vibrateAlert`

This loop is the sole owner of all UI updates and all speech output. No other code path modifies the UI during normal operation.

### Reason for the split

COCO-SSD inference is 100 to 200 ms per call. Running it every 50 ms would back up the inference queue, drop frames, drain battery, and crash lower end devices. At the same time, the UI needs to feel responsive at 20 fps. A wall in the camera feed should trigger a visible and audible alert within 50 ms.

The pixel variance wall check fits inside 5 ms, so it can ride the 50 ms cycle. The expensive models stay on the 200 ms cycle. Both happen, and both stay sane.

## State object

The `state` object is the central data store. Both loops read and write to it. Key fields:

- `state.video` - the HTML video element
- `state.model` - the loaded COCO-SSD model instance
- `state.isRunning` - whether the protection loops are active
- `state.isPaused` - whether the user has paused alerts
- `state.localDetections` - current COCO-SSD detections
- `state.aiResult` - latest cloud AI response text
- `state.aiHazard` - parsed hazard from cloud AI with expiry
- `state.depthHazard` - parsed hazard from the depth model with expiry
- `state.depthPipeline` - the loaded Transformers.js depth pipeline
- `state.depthHistory` - rolling window of depth readings (center, left, right)
- `state.depthCalibration` - mapping between raw depth values and meters
- `state.currentStatus` - current threat level (safe, warning, danger)
- `state.currentObstacle` - the most dangerous detected obstacle
- `state._mainThreat` - threat level from the protection loop for the fast loop to read

## Startup flow

1. **Camera starts first.** Video must be running before any detection can occur. The fast wall check needs pixels from the first frame.

2. **COCO-SSD loads.** The protection loop depends on it, so this load is awaited.

3. **Loading screen hides.** Once camera and COCO-SSD are ready.

4. **Depth model loads in background.** `initDepthModel()` is fired without `await`. It first checks for WebXR LiDAR (only works in AR mode on supported devices) and falls back to downloading the Transformers.js Depth-Anything weights. The download can take several seconds and happens while the user is on the privacy and help screens.

5. **Privacy screen.** Shown every launch. First tap unlocks audio and speaks the welcome. Second tap dismisses it and shows the features screen.

6. **Features screen.** Describes gestures and voice commands. Tapping start calls `hideHelp()`, which sets `state.isRunning = true` and starts both loops.

## Visibility handling

When the browser tab goes to background (`document.hidden === true`), the app stops running. Any active WebXR session ends. When the tab returns, the loops restart automatically if model and camera are already initialized. This prevents unnecessary battery drain and avoids errors from trying to run ML inference on a backgrounded tab.

## Service worker

The service worker (`sw.js`) registers on load and provides app shell caching. The cache version is `guidedog-v48`. Cloud AI still needs the network, but the interface itself loads offline.
