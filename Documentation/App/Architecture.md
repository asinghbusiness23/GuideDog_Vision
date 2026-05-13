# Architecture

## Technical Complexities

GuideDog Vision is a Capacitor app doing real time computer vision. Most apps in this category are pure SwiftUI or UIKit. Going through a JavaScript bridge would normally add latency to safety critical paths, so several decisions exist to keep the bridge out of the hot path.

JavaScript only renders the display surface. Sensor processing, model inference, audio output, and haptics all live in Swift. The JS layer receives status updates and renders them. It never decides anything safety related.

The `start()` method is synchronous on purpose. An earlier async version had a race where `isRunning` flipped to true before the ARSession actually started, so detection layers ran against empty frame data and failed silently.

Six detection layers each run at a different cadence (every 4, 10, 15, 20, 60 frames) chosen to match how fast their information goes stale.

Depth and mesh processing run on a dedicated serial `DispatchQueue` at `.userInitiated` quality of service, so they never block AR frame delivery on the main thread.

`isDetecting` and `isSegmenting` boolean guards stop CoreML requests from piling up on the Apple Neural Engine. Without them the queued requests stall the pipeline and freeze the camera.

SpeechController, HapticController, and SpatialAudioController are initialized at staggered offsets (immediate, 0.1 s, 1.0 s) to avoid an AVFoundation conflict that would otherwise leave the speech synthesizer with no audio output.

## Overview

The app is built on Capacitor 8.3, which wraps a WKWebView inside a native Swift app. The UI is HTML, CSS, and JavaScript. Detection, speech, and sensor logic are Swift with full access to Apple frameworks.

Dependencies are managed through Swift Package Manager. No CocoaPods, no Carthage. Capacitor itself is integrated via SPM.

## Bridge

### CAPBridgeViewController subclass

`ViewController.swift` subclasses `CAPBridgeViewController`. This is the standard Capacitor pattern. The ViewController owns the NavigationEngine and VoiceCommandController and manages the Swift to JavaScript bridge.

### JavaScript to Swift

The ViewController registers five `WKScriptMessageHandler` names during `viewDidLoad`:

| Message | Purpose |
|---|---|
| `speak` | Speak text through native AVSpeechSynthesizer. A whitespace only string cancels current speech. |
| `scanRequest` | Trigger a manual AI scene scan. |
| `cameraToggle` | Turn the camera preview on or off (boolean). |
| `voiceCommand` | Start or stop the speech recognizer. |
| `engineStart` | Signal that the user dismissed the privacy and help screens. Starts the NavigationEngine. |

### Swift to JavaScript

The ViewController calls `evaluateJavaScript` on the WKWebView with function calls on the `window` object:

| Function | Purpose |
|---|---|
| `__onLiDARDepth` | Center, left, right depth values (meters) after each depth cycle. |
| `__onNativeReady` | Sent once after engine start. Boolean indicating whether the device has LiDAR. |
| `__onDetection` | Object label and direction when YOLO confirms a detection. |
| `__onNativeFrame` | Base64 JPEG camera frame for the preview overlay (only when CAM is on). |

This bridge design keeps the web layer as a display surface. Sensor processing, inference, and audio output happen in Swift. JavaScript handles UI rendering, gesture detection, and onboarding screens.

## NavigationEngine

`NavigationEngine` is the core class. It manages the ARSession, all detection models, speech, haptics, and spatial audio. It conforms to `ARSessionDelegate` and `VoiceCommandDelegate`.

### Startup

The engine is created when the user taps through the privacy and help screens. The ViewController sends `engineStart`, which requests camera, microphone, and speech permissions (if not already granted), then calls `startEngine()`.

`start()` is synchronous (see Design Decisions). The start sequence:

1. Disable the idle timer so the screen stays awake.
2. Configure `AVAudioSession` for `playAndRecord` with `spokenAudio` mode.
3. Create the SpeechController and say "Loading. One moment."
4. After a 0.1 second delay, create the HapticController.
5. After a 1.0 second delay, create the SpatialAudioController. This delay is intentional: AVAudioEngine conflicts with AVSpeechSynthesizer if both initialize simultaneously.
6. Configure and run the ARSession with world tracking, scene depth (if LiDAR is available), and mesh classification with classification.
7. When the first real depth callback arrives, say "GuideDog active."

### Frame dispatch

The `session(_:didUpdate:)` delegate fires at the AR frame rate (typically 30 fps). A frame counter tracks which frame we're on. Each detection layer runs at its own interval:

| Layer | Interval | Effective rate | Thread |
|---|---|---|---|
| LiDAR depth | every 4 frames | ~7.5 fps | detectionQueue (background) |
| YOLOv8n | every 10 frames | ~3 fps | global async |
| BlindGuideNav | every 20 frames | ~1.5 fps | global async |
| ARKit mesh | every 15 frames | ~2 fps | detectionQueue (background) |
| DeepLabV3 | every 60 frames | ~0.5 fps | global async |
| Camera preview frame | every 3 frames | ~10 fps | main thread |

The intervals balance computational cost against how fast each signal becomes stale. LiDAR runs most often because distance changes fastest (a person at 1.4 m/s covers 18 cm between cycles). Object detectors run slower because their results take longer to compute and object identity doesn't change frame to frame the way distance does. Mesh classification runs slower still because architectural surfaces only change when you enter a new area. Segmentation runs slowest because its job is to catch large objects the others missed, which is a low frequency event by design.

### Background processing

Depth and mesh classification run on a serial `DispatchQueue` named `com.blindguide.detection` at `.userInitiated` quality of service. This keeps them off the main thread so they never block AR frame delivery.

YOLOv8n and DeepLabV3 use `isDetecting` and `isSegmenting` flags to prevent concurrent CoreML requests piling up on the Apple Neural Engine. Without these guards the ANE backs up and stalls the camera pipeline.

### Audio session

`AVAudioSession` is configured with:
- Category `.playAndRecord` (speech output plus mic input for voice commands)
- Mode `.spokenAudio` (optimized for speech)
- Options `.allowBluetoothA2DP`, `.allowBluetooth`, `.mixWithOthers`, `.duckOthers`

If no Bluetooth audio device is connected, the output is forced to the speaker with `overrideOutputAudioPort(.speaker)`. Without that, `.playAndRecord` defaults to the earpiece, which is too quiet for navigation.

## File structure

| File | What's in it |
|---|---|
| `ViewController.swift` | CAPBridgeViewController subclass. Bridge handlers. Owns engine and voice controller. |
| `NavigationEngine.swift` | ARSession, frame dispatch, depth processing, detection orchestration, distance bands, voice command handling. |
| `ObjectDetector.swift` | YOLOv8n CoreML loading and Vision inference. |
| `MeshClassifier.swift` | ARMeshAnchor classification (wall, door, window, seat, table). 6 m range. `closestWall` accessor for nearest wall regardless of direction. |
| `SceneSegmenter.swift` | DeepLabV3 semantic segmentation with PASCAL VOC classes. |
| `AISceneDescriber.swift` | Cloud AI race between Claude and GPT via the Cloudflare Worker. |
| `AudioFeedback.swift` | SpeechController (priority speech), SpatialAudioController (directional beeps), RiskSolver (hysteresis). |
| `HapticFeedback.swift` | HapticController (UIImpactFeedbackGenerator pulse timers). |
| `VoiceCommands.swift` | VoiceCommandController (SFSpeechRecognizer, command parsing). |
| `index.html` | Web UI inside the WKWebView: onboarding, alert box, gestures, camera preview. |
