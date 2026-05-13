# Design Decisions

Every design decision in this application involved trade-offs. This document outlines the decision behind the most significant choices, providing clarity for future readers seeking to understand the structure and implementation of GuideDog.

## Reason for Capacitator

GuideDog Vision wraps a WKWebView inside a native Swift app using Capacitor 8.3. The detection engine, speech, haptics, and all sensor processing run in Swift. The UI runs in HTML and JavaScript.

The alternative was a fully native SwiftUI app. Capacitor was chosen for three reasons.

First, iterating on the UI in HTML and CSS is much faster than waiting for Xcode rebuilds. The onboarding screens, alert boxes, status indicators, and gesture handlers all live in `index.html`. Layouts, colors, and copy could change without ever recompiling.

Second, the same web layer could move to Android inside a Capacitor Android project later. The detection layer would need to be rewritten in Kotlin, but the UI transfers as is.

Third, web tech has a lower barrier for anyone who wants to contribute.

The tradeoff is the JS bridge. Every value crossing between Swift and JavaScript has to serialize. For UI display this latency is fine. The detection, speech, and haptic paths never cross the bridge, so the safety critical stuff stays fast.

## Why YOLOv8n on iOS, not COCO-SSD

The web version uses COCO-SSD (TensorFlow.js). The iOS app uses YOLOv8n compiled to CoreML.

YOLOv8n runs on the Apple Neural Engine through `VNCoreMLRequest`. The ANE is purpose built for inference and runs much faster than the CPU or GPU on the same model. COCO-SSD through TensorFlow.js can't reach the ANE from JavaScript, which would leave most of the chip's capability unused.

YOLOv8n is also more accurate than COCO-SSD at comparable model size. The "nano" variant fits in 6.2 MB and still gets better detection performance.

Running it through Vision also means Apple handles the image preprocessing, orientation correction, and result parsing. Less custom code, fewer places for bugs.

## Why 0.75 default confidence, with class specific overrides

YOLOv8n filters detections to a minimum confidence of 0.75 by default. A few classes have higher thresholds: refrigerator at 0.88, tv at 0.90, chair at 0.90, bed at 0.85, dining table at 0.85.

Early testing started at 0.5 and the false positive rate was rough. Shadows got called objects. Posters got called people. Reflective surfaces produced phantom detections. Every false positive triggered a spoken announcement. A blind user who keeps hearing "Person ahead" and finding nothing will stop trusting the app, which defeats the whole point.

Raising the global threshold to 0.75 fixed most of it, but a handful of classes kept generating false positives at any reasonable threshold. Refrigerators got confused with white walls and large appliances. TVs lit up on every dark rectangular shape. Chairs are extremely overfit in COCO and triggered constantly. Beds and dining tables hallucinated indoors. Those classes specifically got the bar raised further.

The cost of being conservative is missing some real detections at long range, where objects are small and indistinct. That's acceptable because the LiDAR depth band system still warns the user about "something ahead" even when the object detector isn't confident enough to name what it is.

## Why YOLO "person" detections get validated by Apple's human detector

The single most embarrassing false positive in early testing was the app announcing "Person ahead" when the camera was pointing at a poster, a mannequin, or a photo. YOLO was confident, but it was wrong.

The fix: every YOLO "person" detection now runs through Apple's `VNDetectHumanRectanglesRequest`. Both detectors have to agree that there's a human in the same region of the frame before the app announces a person. If YOLO says yes and Apple says no, the detection is dropped.

This double check costs a few milliseconds and only runs for the person class, but it almost completely eliminates the phantom person announcements that hurt user trust the most.

## Why 3 consecutive frame ghost filter

Even at 0.75 confidence, the occasional ghost detection still happens for a single frame. Usually it's a momentary camera shake, a lighting change, or a partial occlusion that resolves on the next frame.

The streak filter requires an object to be detected in at least 3 consecutive YOLO cycles before it gets announced. YOLO runs every 10 frames (about 3 fps), so 3 cycles is roughly a second. Ghost detections almost never survive that long. Real objects almost always do.

The cost is a small announcement delay for new objects (about a second). For stationary obstacles that doesn't matter. For fast moving threats (cars approaching, cyclists) the approach speed path bypasses the streak filter entirely.

## Why one announcement per cycle

When multiple objects show up at the same time, the engine picks exactly one to announce. It does not queue several.

The problem with queuing is staleness. AVSpeechSynthesizer plays utterances sequentially. If you queue three announcements, the third one is talking about something the user already walked past. A blind user hearing "chair on left" when the chair is behind them is at best confusing and at worst dangerous if it makes them turn or stop.

Announcing just the highest priority, closest object on each cycle keeps every announcement current. If something else matters, the next cycle picks it up.

## Why hysteresis on the distance bands

Hysteresis means the threshold for turning something on is different from the threshold for turning it off. A home thermostat is the classic example. It kicks the heater on when the room drops to 68 but doesn't turn it off until the room hits 70. That two degree gap stops the heater from clicking on and off every few seconds when the temperature hovers around 69. Same idea applies whenever your input is noisy and you don't want the output to flicker.

LiDAR depth readings are noisy in exactly this way. A wall 1.0 meter away might read 0.98 m on one frame and 1.02 m on the next. Without hysteresis, the app would enter the danger band (below 1.0 m), exit it, enter it again, and keep announcing "Stop, something close" on a loop.

So the entry and exit thresholds are different numbers. Enter danger at 1.0 m, exit at 1.1 m. Enter caution at 2.0 m, exit at 2.2 m. The gap absorbs normal LiDAR oscillation. You hear one clean announcement when you approach the obstacle and silence until either you get closer (triggering the next band) or move clearly away.

## Why beeps are danger only

An earlier version played spatial audio beeps at both caution and danger levels. In testing, the caution beeps fired nonstop. Indoor rooms basically always have a wall within 2 meters somewhere. Hallways guarantee it on at least one side. The result was constant beeping with no way to escape it, which made the feature actively harmful.

Restricting beeps to danger (under 1.0 m) means they only fire when you're genuinely about to walk into something. In a normal room, the center of a hallway gives you silence. When you get too close to a wall or object, the beep sounds with directional panning so you know which side the threat is on.

Caution feedback still comes through other channels: haptic pulses every 0.5 seconds and the spoken "Heads up." Those don't have the same constant noise problem.

## Why size triangulation instead of per pixel LiDAR sampling

The obvious way to measure the distance to a detected object would be to sample the LiDAR depth map at the object's bounding box. The engine does have a `sampleDepthAt(box:)` method that does this. The primary path uses size triangulation through the pinhole camera model instead.

The reason is coordinate space alignment. The camera image and the LiDAR depth map don't share the same pixel grid. They have different resolutions and slightly different fields of view. ARKit can project between the two but the projection involves interpolation that drifts at the edges of the frame.

Testing revealed that sampling the depth map at an object's bounding box would sometimes return the distance to the wall behind the object, not the object itself, because the depth pixel didn't quite land on the object surface.

Size triangulation avoids the issue entirely. It uses only the camera image (bounding box height) and the camera intrinsics (focal length from `ARFrame.camera.intrinsics`). Both live in the same coordinate space. The estimate is less precise than a perfect depth sample but it never returns a distance to the wrong surface.

The zone based LiDAR distance (left, center, right thirds of the depth map) is still used as a cross check. When both methods agree within a meter, the engine averages them. When they disagree, size triangulation wins because it's measuring the specific object instead of an average over a zone.

## Why start() is synchronous

An earlier version of `NavigationEngine.start()` was `async`. The problem: `isRunning` got set to `true` before the `await` on the ARSession config returned. The detection layers checked `isRunning`, saw true, started running, and got nothing because the ARSession hadn't actually started delivering frames. The whole system looked like it was working but produced no output.

Making `start()` synchronous fixed it. `isRunning = true` happens, then the ARSession is configured and run on the main thread immediately. The detection layers can't run before they get their first `session(_:didUpdate:)` callback, so there's no race. The heavy controller initialization (haptics, spatial audio) is deferred with `asyncAfter` to avoid blocking the main thread, but the ARSession itself starts inline.

## Why cloud AI fires on scene change, not on a timer

An earlier approach scanned the scene every 30 seconds on a timer. Two problems.

First, wasted tokens. If you're standing still or walking down a long featureless hallway, the scene doesn't change. Scanning every 30 seconds gives you the same description repeatedly and burns API quota.

Second, missed transitions. If you walk briskly through a doorway into a new room, the timer might not fire for another 25 seconds, by which point the new environment is old news.

Scene change triggering solves both. The engine monitors the ARKit mesh classification for the center zone. When the dominant classification flips (wall to door, for example), the cloud scan fires immediately. If nothing changes, nothing fires. The 20 second minimum interval between automatic scans stops rapid fire requests when mesh classification oscillates around a boundary.

## Why SpatialAudioController is delayed 1 second

The SpatialAudioController gets created 1 second after `start()` runs, not immediately.

AVAudioEngine and AVSpeechSynthesizer don't get along during initialization. If both try to set up at the same time, the synthesizer can lose its audio output entirely. It reports `isSpeaking == true`, delegate callbacks fire, but no sound comes out. For a blind user, silent speech is catastrophic.

The root cause appears to be AVAudioEngine reconfiguring the audio session during init, and AVSpeechSynthesizer losing its audio route if it tries to speak during that reconfiguration. The fix is to delay AVAudioEngine creation until after the synthesizer has spoken its first utterance and locked in a route. After that, AVAudioEngine init doesn't disrupt it.

A one second delay is reliable across every device and iOS version tested. It's not a beautiful fix but the underlying AVFoundation behavior isn't well documented.

## Why wall inference exists at all

The hardest scene to detect is a blank painted wall in good lighting. ARKit's mesh classifier needs visual features to track. A flat white wall has very few features, so ARKit drops into `.limited(.insufficientFeatures)` and stops returning useful mesh data. Without depth, the object detectors don't see anything either, because there's nothing in the frame to detect.

The wall inference fixes this. When the left, center, and right depth zones all read similar distances (the depth map is uniform) and no recent object detection in the center, the engine concludes there must be a wall and announces it with one of three messages by distance: "Wall ahead" under 3 m, "Wall, X feet" under 2 m, "Wall nearby" under 1 m. Depth processing now keeps running during `.limited(.insufficientFeatures)`, so the inference can still fire even when ARKit's tracking degrades.

This is the single biggest improvement to indoor failure modes. It backstops ARKit's mesh classifier exactly when it would otherwise fall over.

## Why the speech drops "feet" on non Pro phones

When the app runs on a non LiDAR iPhone, depth comes from the Depth-Anything fallback. Those values are estimates, not direct sensor readings. Announcing "Person, 6 feet" implies a precision the system doesn't actually have.

On non Pro phones, the speech drops the foot suffix and just says "Person right." The direction is reliable (it comes from the bounding box position in the image), but the distance is approximate so the announcement reflects that. On LiDAR phones, the foot count stays in because the measurement is real.
