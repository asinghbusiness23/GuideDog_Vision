# Sound Detection

## Overview

The Sound & Captions mode includes an on-device audio classifier that listens to ambient sound through the microphone and announces relevant events to the user via a visual banner, speech, and haptic vibration. The classifier runs the YAMNet model in TFLite format using the MediaPipe Audio Tasks library. Everything runs locally on the device — no audio is sent to any server.

Sound detection is opt-in. The user taps the SOUND button in the assist bar or says "sound detection" while in GuideDog mode to enable it. The same toggle disables it.

---

## What Makes This Non-Trivial

- **Bucket aggregation over raw class scores.** YAMNet returns scores for \~521 AudioSet classes. Many conceptually identical sounds split confidence across multiple classes ("Siren" 0.18, "Police car siren" 0.14, "Ambulance siren" 0.12). Summing scores per user-facing bucket means the siren bucket receives 0.44 and fires, rather than each subclass being individually rejected at the threshold. This is the difference between detecting a siren and missing it.  
- **Ambient noise floor calibration.** Before classifying anything, the system spends \~1.5 seconds measuring the room's background noise. Classification is gated on the signal being at least 3 dB above the calibrated floor, which prevents CPU burn and false positives in silent environments. The floor is set to the median of collected frames, not the mean, making it robust to a single loud burst during calibration.  
- **Separate classify gate and ambient gate.** The classify gate (3 dB above floor) governs whether to run the full YAMNet model. A separate ambient gate (12 dB above floor) governs the fallback "Loud sound nearby" announcement when MediaPipe fails to load. These two thresholds serve different purposes and are tuned independently.  
- **AudioWorklet over ScriptProcessor.** The worklet runs audio capture off the main thread. ScriptProcessor (deprecated but universally supported) is used as a fallback. The worklet prevents audio buffering from delaying the UI thread.  
- **Disabled browser audio DSP.** The `getUserMedia` call explicitly disables `echoCancellation`, `noiseSuppression`, and `autoGainControl`. These browser-level audio processing pipelines are tuned for voice calls and aggressively suppress steady sounds (sirens, traffic, alarms) that GuideDog specifically needs to detect.  
- **Per-label announcement cooldown.** Each distinct sound label has its own cooldown timestamp in `state.lastSoundSpeak`. A siren heard twice in 6 seconds is announced once. This prevents the user from being flooded with repeated alerts for continuous sounds.

---

## MediaPipe Module Loading

The MediaPipe Audio Tasks library is loaded in a `<script type="module">` block at page load. Two CDN sources are tried in sequence:

1. `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-audio@0.10.35`  
2. `https://esm.sh/@mediapipe/tasks-audio@0.10.35`

On success, the module is stored as `window.__mpAudio` and `window.__mpAudioBase`, and a `mp-audio-ready` custom event is dispatched. On failure, `mp-audio-failed` is dispatched and the system falls back to ambient-only mode.

---

## Model Loading

`loadAudioClassifier()` is called the first time the user enables sound detection. It:

1. Waits for `window.__mpAudio` (the MediaPipe module) using an event listener with an 8-second safety timeout  
2. Resolves `FilesetResolver.forAudioTasks(wasmBase)` using the CDN's `/wasm` path  
3. Creates an `AudioClassifier` with:  
   - Model: `yamnet.tflite` from `storage.googleapis.com/mediapipe-models/`  
   - `maxResults: 25` (wider tail for bucket-summing to work across subclasses)  
   - `scoreThreshold: 0.02` (low per-class floor; real threshold is on the bucket sum)

The result is stored in `_mpClassifier`. The function returns `null` if loading fails, which triggers ambient-only mode for the session.

---

## Audio Capture Pipeline

### Mic Access

`toggleSoundDetection()` calls `navigator.mediaDevices.getUserMedia` with audio constraints that disable all browser DSP:

{

  echoCancellation: false,

  noiseSuppression: false,

  autoGainControl: false,

  channelCount: 1

}

The resulting `MediaStream` is stored in `state.yamnetMicStream`.

### Capture Node Setup (`startAudioCapture`)

A `MediaStreamAudioSourceNode` is created from the mic stream. A silent gain node (`gain = 0`) is connected to `AudioContext.destination` so the graph is actually pulled by the browser without routing mic audio to the speakers.

**Window size:** `Math.round(0.975 × sampleRate)` samples. YAMNet was trained on 0.975-second windows at 16 kHz, giving 15,600 samples. On a 44.1 kHz AudioContext the window is \~43,000 samples. The model internally resamples if needed.

### AudioWorklet Path

If `AudioWorkletNode` is available (Chrome, Safari 14.5+, Firefox 76+):

1. A worklet processor (`gd-capture`) is created as a Blob URL and registered  
2. The processor accumulates mono PCM into a `Float32Array` of `windowSamples` length  
3. When the buffer fills, it is transferred (zero-copy, via `Transferable`) to the main thread via `port.postMessage`  
4. The main thread calls `onAudioWindow(samples, sampleRate)`

### ScriptProcessor Fallback

If AudioWorklet is unavailable, a deprecated `ScriptProcessorNode` (buffer size 4096\) is used. The ring buffer and window filling logic is equivalent, but runs on the main thread. A warning is logged.

### Teardown (`stopAudioCapture`)

All nodes are disconnected, event handlers are cleared, and `_ambientFloorDb` is reset to `null` so calibration restarts fresh if sound detection is re-enabled.

---

## Ambient Noise Calibration

Before classifying any window, the system calibrates the ambient noise floor:

1. On the first window received, `_ambientCalibrationDoneAt` is set to `Date.now() + 1500ms`  
2. Each window's RMS level (in dBFS) is pushed to `_ambientCalibrationFrames`  
3. When `Date.now()` passes the deadline, the frames are sorted and the **median** is taken as `_ambientFloorDb`

Using the median (not the mean) makes the calibration robust to a single loud event (a door slam, a word spoken) during the calibration window.

### dBFS Computation

rmsDb \= 20 × log10(max(sqrt(mean(samples²)), 1e-7))

The `1e-7` floor prevents `-Infinity` on a perfectly silent frame.

---

## Classification

### Gate Check

After calibration, each window is gated before classification:

if (rmsDb \< \_ambientFloorDb \+ CONFIG.AUDIO\_CLASSIFY\_GATE\_DB) skip

`CONFIG.AUDIO_CLASSIFY_GATE_DB = 3` dB. Windows within 3 dB of the ambient floor are silently skipped. This saves CPU and battery in quiet environments where no meaningful sound is present.

### Classify Call

const results \= \_mpClassifier.classify(samples, sampleRate);

MediaPipe returns an array of `AudioClassifierResult` objects. Each contains `classifications[0].categories`, sorted by score descending.

A `_classifyBusy` flag prevents overlapping calls. If the previous `classify()` call has not returned, the current window is dropped.

---

## Sound Taxonomy: Buckets and Labels

### SOUND\_BUCKETS

A two-level taxonomy maps user-facing labels to urgency levels. There are 37 buckets grouped into three urgency tiers:

**Danger buckets** (spoken immediately, interrupt current speech): `siren`, `fire_alarm`, `car_horn`, `truck_horn`, `train_horn`, `gunshot`, `explosion`

**Warning buckets** (spoken, queued): `alarm`, `car_alarm`, `reversing`, `shouting`, `dog_warning`, `vehicle`, `traffic`, `train`, `bicycle_bell`, `thunder`

**Info buckets** (banner only, spoken with cooldown): `speech`, `conversation`, `music`, `crowd`, `applause`, `laughter`, `baby_cry`, `crying`, `knock`, `doorbell`, `door`, `phone`, `rain`, `alarm_clock`, `dog_info`, `cat`

### SOUND\_LABELS

`SOUND_LABELS` maps verbatim YAMNet category names to bucket keys. There are over 200 entries covering all major subclasses. Examples:

| YAMNet category name | Bucket |
| :---- | :---- |
| `Siren` | `siren` |
| `Police car (siren)` | `siren` |
| `Ambulance (siren)` | `siren` |
| `Fire alarm` | `fire_alarm` |
| `Smoke detector, smoke alarm` | `fire_alarm` |
| `Vehicle horn, car horn, honking` | `car_horn` |
| `Bark` | `dog_warning` |
| `Speech` | `speech` |
| `Pop music` | `music` |
| `Drum kit` | `music` |
| (200+ more) | … |

Music receives the broadest coverage: all AudioSet genre labels, all instrument classes, and all vocal-music subclasses roll up to the `music` bucket. This means a partial confidence split across "Pop music" 0.15, "Drum kit" 0.10, and "Electric guitar" 0.08 combines to 0.33, which exceeds the `CONFIG.AUDIO_SCORE_THRESHOLD = 0.25` threshold.

---

## Bucket Aggregation and Winner Selection

`handleMediaPipeResults()` processes each classify result:

1. **Sum scores per bucket.** For each category returned, look up its bucket key in `SOUND_LABELS`. Accumulate scores: `bucketSum[bucket] += c.score`.  
2. **Track the top individual class per bucket** for debug logging.  
3. **Reject below threshold.** Any bucket whose summed score is below `CONFIG.AUDIO_SCORE_THRESHOLD = 0.25` is discarded.  
4. **Pick the winner.** Among buckets above threshold, prefer higher urgency. Within the same urgency tier, prefer higher summed score.  
5. **Dispatch.** Call `handleSoundLabel(meta.label, meta.urgency)` with the winner's human-readable label and urgency tier.

---

## Ambient-Only Fallback

If MediaPipe fails to load, `runAmbientGate()` is used instead of `classifyWindow()`. It fires `handleSoundLabel("Loud sound nearby", "warning")` whenever the RMS level exceeds `_ambientFloorDb + CONFIG.AUDIO_AMBIENT_GATE_DB` (12 dB). This fallback never claims a specific category — it only announces that something loud is happening.

---

## Sound Event Dispatch (`handleSoundLabel`)

For each detected sound:

1. **Show the sound banner** (`showSoundBanner`) — a blue pill at the bottom of the screen above the caption box, visible for `CONFIG.SOUND_BANNER_DURATION = 6000ms`  
2. **Check per-label cooldown.** If `state.lastSoundSpeak[label]` was set less than `CONFIG.SOUND_SPEAK_COOLDOWN = 6000ms` ago, skip announcement (but still show the banner)  
3. **Announce** for warning and danger levels:  
   - Update `state.lastSoundSpeak[label]`  
   - Call `speakAlert("sound_" + label, spoken, priority)` — priority 3 for danger, 2 for warning  
   - Call `vibrateAlert(urgency)`  
4. **Info-level sounds** update the cooldown timestamp and show the banner but do not speak (they are informational, not safety-critical)

In Assist mode, `doSpeak()` is suppressed for deaf users (the `state.appMode === 'assist'` guard in `doSpeak` exits early). Banner display and vibration still work normally.

---

## Debug Instrumentation

Enable the debug panel with `?debug=1` in the URL, `#debug` in the hash, or `localStorage.gd_debug = '1'`.

The debug panel shows:

- MediaPipe module load status  
- Model load status and time  
- Capture backend (AudioWorklet or ScriptProcessor)  
- Sample rate and window size  
- Window count, gated count, classified count  
- Announced vs suppressed counts  
- First classify latency (ms)  
- Current RMS (dBFS) and ambient floor (dBFS), with dB-above-floor  
- Rolling log of the last 14 events (dropped windows, classify results, announced labels)

The debug panel is rendered via `requestAnimationFrame` to avoid blocking the audio thread.

---

## Configuration Parameters

| Parameter | Value | Purpose |
| :---- | :---- | :---- |
| `AUDIO_WINDOW_SECONDS` | 0.975 | YAMNet expected window length |
| `AUDIO_SCORE_THRESHOLD` | 0.25 | Min bucket score to announce |
| `AUDIO_CALIBRATION_MS` | 1500 | Ambient calibration duration |
| `AUDIO_AMBIENT_GATE_DB` | 12 | dB above floor to trigger ambient fallback |
| `AUDIO_CLASSIFY_GATE_DB` | 3 | dB above floor to skip classification |
| `SOUND_BANNER_DURATION` | 6000 | ms banner stays visible |
| `SOUND_SPEAK_COOLDOWN` | 6000 | ms between re-announcing the same label |

