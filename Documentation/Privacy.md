# Privacy Policy

**GuideDog Vision**


## What gets collected

Nothing. GuideDog Vision does not collect, store, or share any personal data.

## Camera

The app uses your camera to watch for obstacles. All object detection and depth analysis runs on your device. Camera frames are not saved or transmitted during normal use.

When you trigger a scan (double tap, voice command, or the automatic guide scan on the website), one camera frame may be sent to a cloud AI service for a scene description. The image is processed and immediately discarded. Neither service retains the image.

## Microphone

The app uses your microphone for voice commands. Audio is processed on your device through Apple's SFSpeechRecognizer (iOS) or the Web Speech API (website). On the website, the microphone also feeds a local sound classifier that listens for things like doorbells, alarms, and dog barks. No audio is recorded, stored, or transmitted.

## LiDAR

LiDAR depth data is processed entirely on your device. It is never sent anywhere.

## Cloud AI

When a scan fires, a camera frame may be sent to:

- Anthropic (Claude Haiku 4.5) for a text scene description
- OpenAI (GPT-4.1-mini) for a text scene description

Both run through a Cloudflare Worker proxy. The image goes up, a text response comes back, and the image is dropped. Neither provider keeps the image.

The website runs this scan automatically every 5 seconds while guide mode is active, so the cloud AI works as a sighted companion. The same processing and discarding rules apply.

## On device models

These run entirely on your device with no network transmission:

- YOLOv8n (object detection)
- BlindGuideNav (custom 55 class navigation model)
- DeepLabV3 (scene segmentation)
- Depth-Anything (depth estimation, both website and the iOS non LiDAR fallback)
- COCO-SSD (website object detection)
- MediaPipe Audio Classifier (website sound detection)
- ARKit LiDAR and mesh classification

## No account

No sign up. No login. No account.

## No personal data

The app does not collect names, email addresses, location, device identifiers, or anything else that identifies you.

## Third party software

- **Capacitor** (iOS app framework): no user data collection
- **TensorFlow.js** (website ML runtime): runs locally
- **Transformers.js** (website ML runtime): downloads model weights from the HuggingFace CDN, no user data sent
- **MediaPipe** (website audio classifier): runs locally

## Contact

Questions about this policy: https://github.com/Omega-6/GuideDog-Vision
