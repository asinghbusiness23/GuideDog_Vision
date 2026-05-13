# Web Overview

## The Problem

Roughly 2.2 billion people worldwide live with some form of vision impairment, including 43.3 million who are completely blind and 295.1 million with moderate to severe visual impairment. The most well-known mobility aid is the guide dog, but only about 2 percent of blind people actually have one due to 4 major reasons: cost, training time, low graduation rates, and waiting lists. Each guide dog costs $40,000 to $60,000 per dog, and requires extra money and responsibility to keep health. Additionally, a long training time of two years paired with the low graduation rates of roughly one in three dogs graduating create a low supply of guide dogs. As a result, the waiting lists are generally 1-3 years, and these cap the supply far below what is needed.

The app exists because every phone in someone's pocket already has cameras, a Neural Engine, and accelerometers. None of that hardware was being used to help blind people navigate. This project tries to change that.

This app is not a guide dog and never will be. A dog makes its own safety calls, and a dog is a companion. What software can do is watch the scene, identify obstacles, and announce them. Read the [README](../../README.md) for the full problem writeup with citations.
## What it is

The website is a Progressive Web App that helps blind and low vision people navigate using a phone's camera and microphone. Open the URL, grant camera permission, tap to start, and the system begins scanning.

The homepage gives the user two big options: "See" (the obstacle detection guide) and "Hear" (sound detection and live captions). Tapping anywhere on the homepage starts guide mode automatically, which matters because the page is built to be used by someone who cannot see the buttons. The Hear button has its own touch handler that stops the tap from falling through to guide mode.

When the page loads, a welcome message plays: "Welcome to GuideDog. Press anywhere on the page for obstacle detection, or the second button for sounds and captions." It's cancelled the moment the user picks a mode.

## Why a website exists alongside the app

The iPhone app uses LiDAR, which lives on iPhone Pro models. Most phones don't have LiDAR. Many users can't or won't install an app from the App Store. The website is the universal fallback. Anything with a camera and a browser can run it.

## How it works without LiDAR

Without LiDAR, the website can't measure absolute distances directly. It compensates with four overlapping layers:

COCO-SSD runs object detection locally through TensorFlow.js. It identifies 19 navigation relevant objects from the COCO dataset and estimates distance through known size triangulation.

Depth-Anything runs in the browser through Transformers.js v2. The output is a relative depth map (0 to 255). The website auto calibrates this against COCO-SSD detections that have known real world heights, so the relative depth turns into approximate meters.

The fast wall check is the pixel variance technique. A flat surface close to the camera fills the frame with uniform color and very few edges. Compute variance and edge density on a 64 by 48 crop every 50 ms and you can detect a wall with no ML at all. This runs faster than any model could.

The cloud AI guide sends a camera frame to a Cloudflare Worker every 5 seconds. It acts as the sighted companion, describing the scene and pointing out things the local models miss (stairs, wet floors, narrow passages, doors). This is the big differentiator from the iPhone app, which uses cloud AI only on demand because it has LiDAR.

## Sound detection (Hear mode)

Hear mode is a separate experience from guide mode. It listens to the microphone, classifies environmental sounds, and shows live captions of speech.

Sound classification uses MediaPipe Audio Classifier with the YAMNet model, running through an AudioWorklet on the device. The taxonomy is bucketed into categories that matter for awareness: doorbell, alarm, siren, music, knock, dog bark, baby crying, and so on.

Captions use the Web Speech API SpeechRecognition in continuous mode. Speech around the user gets transcribed on screen in real time.

## Browser compatibility

Tested on iOS Safari, Android Chrome, and desktop browsers. HTTPS is required for camera access because browsers block `getUserMedia` on insecure origins. The service worker (currently `guidedog-v48`) caches the app shell so the interface loads without a connection, though cloud AI needs the network.

## Mobile first

The interface is designed for one handed phone use while walking. Big touch targets, gestures, and speech output. Desktop browsers technically work but nobody is going to walk down the street holding a laptop.

## PWA features

The site registers a service worker (`sw.js`) and includes a web app manifest (`manifest.json`), so users can "Add to Home Screen" on iOS or Android. The viewport is locked (`maximum-scale=1`) and `touch-action: manipulation` prevents the double tap zoom delay. Text selection is disabled so gesture taps don't accidentally select things.

## Privacy

All object detection, depth estimation, sound classification, and speech recognition runs on the user's device. Frames sent to the cloud AI for scene descriptions are processed and immediately discarded. No images stored. No account required. No personal data collected. The privacy screen is shown every launch and speaks the same information aloud through the welcome message.
