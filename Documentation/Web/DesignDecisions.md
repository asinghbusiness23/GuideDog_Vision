# Web Design Decisions

Every design decision in this application involved trade-offs. This document outlines the decision behind the most significant choices, providing clarity for future readers seeking to understand the structure and implementation of GuideDog. Most of these came out of specific bugs or user complaints during testing. Each section names the decision, what it replaces, and the reason it won out.

---

## Why COCO-SSD instead of MediaPipe for object detection

An earlier prototype used MediaPipe's object detection because it had a cleaner API. On iOS Safari, the ES module import crashed the browser tab during WebAssembly init. Not during inference. Just loading the library was enough to kill the page.

COCO-SSD loads through a traditional `<script>` tag and exposes a `cocoSsd` global. No ES modules, no WebAssembly imports happening at module scope. It works on every browser tested, including iOS Safari.

The cost is that COCO-SSD only detects 80 COCO classes. For this use case the 19 navigation relevant classes cover the most common obstacles, so it's fine.

---

## Why Transformers.js v2 instead of v3

Transformers.js v3 uses ONNX Runtime Web for inference. Loading it alongside TensorFlow.js means both runtimes initialize at the same time. On iOS Safari that combination exceeded the per tab memory limit and the browser killed the tab silently during model init.

This was consistent on iPhones with 4 GB of RAM and intermittent on iPhones with 6 GB. Desktop and Android Chrome handled both runtimes fine because they get more memory per tab.

Transformers.js v2 (`@xenova/transformers@2.17.2`) uses a lighter inference engine. Both it and TensorFlow.js can coexist inside iOS Safari's budget. The v2 engine is slower than v3, but the depth model only runs every 400 ms so the speed difference doesn't matter.

The tradeoff: v2 isn't actively maintained. Future models may only ship on v3. If iOS Safari raises the memory limit, this decision is worth revisiting.

---

## Why cloud AI every 5 seconds

The website has no LiDAR. COCO-SSD recognizes 19 classes but doesn't know what stairs or wet floors look like. The depth model gives relative depth without saying what anything is. The cloud AI fills these gaps as a sighted companion.

Five seconds came out of three constraints.

Token cost. Each request hits both Anthropic and OpenAI. At 1 request per 5 seconds, a 30 minute walk is about 360 API calls. Every 2 seconds would triple that. Every 10 seconds would let a fast walker miss obstacles.

Walking speed. People walk at about 1.4 m/s, covering 7 meters in 5 seconds. Indoor hallway obstacles are usually spaced farther apart than that, and for dense environments the local detection (COCO-SSD, depth, wall check) is continuous between AI scans.

Response latency. Cloud AI responses take 1 to 3 seconds. A 5 second cycle ensures the previous response has come back before the next request fires. The `state.aiScanInProgress` flag prevents overlapping requests.

---

## Why "guide" prompt on web, "app" prompt on iOS

Same Cloudflare Worker, two different system prompts selected by the `mode` parameter.

The iOS app already has LiDAR for space and YOLO for objects. It knows where things are. It uses the AI as a backstop for the things its sensors can't see (stairs, signage, wet floors, etc.). The "app" prompt is terse and safety focused.

The website has none of that. It needs the AI to do the descriptive work of a sighted companion: "hallway ahead, door on your left, floor slopes down." The "guide" prompt instructs the AI to talk that way and call out which direction is clear for walking.

Keeping it in one Worker with a parameter means one deploy ships the latest prompts to both clients.

---

## Why zero cooldowns on speakAlert

Earlier versions had 2 to 3 second cooldowns per alert key. The intent was to stop the same alert from repeating too quickly.

In practice, users started missing important warnings. A wall would appear, the app would say "Wall ahead," and the cooldown would block any further wall alerts for 2 to 3 seconds. If the user kept walking, the next warning didn't fire until the cooldown expired.

The worst case was escalating threats. If the system said "Slow" at warning level and the situation jumped to danger inside the cooldown window, the danger alert got silently dropped. The user heard "Slow" but never "Stop."

Zero cooldowns fix this. Duplicate alerts are prevented upstream by temporal smoothing in the detection layer, not by the speech layer. The fast hazard loop only speaks when the threat state actually changes (`threat !== _lastFastThreat`), so the same danger doesn't repeat anyway.

---

## Why fastHazardLoop owns all UI updates

The fast loop (50 ms cycle) is the only piece of code that writes to the DOM. The slow loop (200 ms cycle) only writes to the shared state object.

In earlier versions both loops called `updateUI`. The slow loop set the alert box green ("Path Clear") and 20 ms later the fast loop set it red ("Wall detected"). The badge and box colors flickered. Some frames had the badge showing SAFE while the box was red, because the slow loop updated the badge and the fast loop updated the box in the same animation frame.

Putting all UI writes in one loop kills the race. The badge, box, icon, text, and detail all get set in one `updateUI` call. No other code path can interleave and create a mismatch. The slow loop writes its results to `state._mainThreat` and `state.currentObstacle`, and the fast loop reads those on its next cycle. The 50 ms delay is imperceptible but it makes the display always consistent.

---

## Why camera loads before the model

The startup sequence loads the camera first, then COCO-SSD.

The fast wall check needs video pixels from the very first frame. It runs every 50 ms and needs `state.video.videoWidth > 0`. If the model loaded first, the camera would have no pixels for the 3 to 5 seconds it takes to download and init COCO-SSD. During that gap, the user could walk into a wall with no warning.

Loading the camera first means the wall check works as soon as the protection loops start. COCO-SSD finishes loading within 1 to 3 seconds. The depth model loads in the background and may take longer, but the wall check and COCO-SSD cover the gap.

---

## Why the privacy screen shows every launch

It's not a privacy theater thing. The target users are blind. They can't read the screen. The privacy screen's job is audio. The first tap triggers a spoken welcome that explains what the app does, how it uses the camera, and that nothing is stored. The second tap confirms the user heard it and wants to proceed.

If the screen only showed on first run, returning users would never hear the orientation again. They'd land directly in scanning mode with no audio cue. A user who hasn't opened the app in weeks might forget the gestures.

The privacy screen also serves as the iOS audio unlock point. The first tap is guaranteed to be a user gesture, which is what iOS Safari needs to enable speech synthesis. Without this screen the app would need another guaranteed gesture moment, and there isn't a clean one.

There's now a silent mode reminder banner on the privacy screen too, because that was the single most common support question: "Why isn't it talking?" The answer was usually "Your phone is on silent."

---

## Why two loops instead of one

A single 50 ms loop running COCO-SSD would be a disaster. The model takes 100 to 200 ms per frame on a phone browser. Trying to run it every 50 ms would back up an inference queue, drop frames, drain battery, and crash lower end devices.

A single 200 ms loop would update the UI at 5 fps. The wall check (pixel variance) completes in under 5 ms. If the wall check only ran every 200 ms, the user could walk 28 cm (about 11 inches) between checks. At 50 ms that drops to 7 cm. Way better response to sudden obstacles.

Dual loops handle both extremes. The slow loop does the expensive work (COCO-SSD, depth model, cloud AI). The fast loop does the cheap work (wall check, UI updates, speech). The user gets 20 fps responsiveness to walls and flat surfaces while ML inference runs at a sustainable 5 fps.

---

## Why the homepage taps anywhere to start

Older versions had pill buttons across the homepage. A sighted user could see and tap them. A blind user landed on a screen they couldn't see, didn't know where the buttons were, and had to fumble to find one.

The current homepage has two big mode cards: "See" (blue glow, primary) and "Hear" (neutral, secondary). The whole page also has a tap anywhere handler that starts guide mode. The Hear button calls `stopPropagation` so its tap doesn't fall through. Blind users just tap. Sighted users see the buttons. Everyone gets what they need.

The hero copy is "Eyes and ears, when you need them." with a blue accent on the phrase "when you need them." The font is system humanist sans (`-apple-system`, `SF Pro Text`, `system-ui`) instead of the older monospace used at the start. It reads conversationally instead of code adjacent.

The web welcome message plays on page load (where the browser allows): "Welcome to GuideDog. Press anywhere on the page for obstacle detection, or the second button for sounds and captions." It cancels the moment the user picks a mode.

---

## Why iOS audio needs a primer utterance

iOS Safari blocks `speechSynthesis.speak()` until a user gesture happens. If the app tries to speak before any touch or click, the utterance is silently dropped. No error. Just no audio.

On the first user gesture, the code calls `speak()` with an empty string, volume 0, and rate 10 (max). The user hears nothing because there's nothing to hear, but the engine is unlocked. After that primer, all subsequent `speak()` calls work regardless of whether they're inside a gesture handler or in an async callback.

The primer listeners attach to `document`, not to specific UI elements. An earlier version attached them to the alert area, but overlays (privacy screen, help screen) intercepted touches before they reached anything below. Document level listeners catch every touch on every overlay.

The privacy notice on the website also has a first tap speaks behaviour: the very first tap on the page speaks the welcome message and unlocks audio, the next tap moves you forward. The help screen has a similar tap anywhere to start pattern, with the back button and the colorblind toggle exempted so those keep working as buttons.
