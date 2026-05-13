# App Overview

## The Problem

Roughly 2.2 billion people worldwide live with some form of vision impairment, including 43.3 million who are completely blind and 295.1 million with moderate to severe visual impairment. The most well-known mobility aid is the guide dog, but only about 2 percent of blind people actually have one due to 4 major reasons: cost, training time, low graduation rates, and waiting lists. Each guide dog costs $40,000 to $60,000 per dog, and requires extra money and responsibility to keep health. Additionally, a long training time of two years paired with the low graduation rates of roughly one in three dogs graduating create a low supply of guide dogs. As a result, the waiting lists are generally 1-3 years, and these cap the supply far below what is needed.

The app exists because every phone in someone's pocket already has cameras, a Neural Engine, and accelerometers. None of that hardware was being used to help blind people navigate. This project tries to change that.

This app is not a guide dog and never will be. A dog makes its own safety calls, and a dog is a companion. What software can do is watch the scene, identify obstacles, and announce them. Read the [README](../../README.md) for the full problem writeup with citations.

## What the app does

GuideDog Vision turns an iPhone into a navigation assistant. The phone runs continuously while you walk. It announces obstacles, walls, doors, vehicles, and other hazards through speech, haptics, and spatial audio beeps. The user does not have to do anything to receive these alerts. The point is proactive protection. If you want more detail about what's around you, gestures and voice commands trigger a cloud AI scene description.

## Who it's for

Primary users are blind and low vision people. The interface is designed for eyes free operation. Everything important reaches you through speech and haptics. The visual UI is there for sighted helpers and for debugging.

Secondary users are orientation and mobility instructors who might use the camera preview during training.

## What devices work

Any iPhone running iOS 15 or later with ARKit world tracking support. The experience depends on the hardware.

**LiDAR equipped iPhones (recommended).** iPhone 12 Pro and later Pro models have a LiDAR scanner. These give you the full experience: centimeter accurate depth at 30 fps, ARKit mesh classification for walls and doors, and the most reliable distance information.

**Non Pro iPhones.** The app still runs. Object detection, segmentation, and cloud AI all work normally. For depth, the app falls back to Depth-Anything, a neural depth estimator converted to CoreML for this project. It's less precise than LiDAR but gives useful distance warnings. On these phones, speech drops the "feet" suffix from announcements ("Person right" instead of "Person, 6 feet") because the distances are estimates rather than direct measurements.

## What you get

### On device detection

LiDAR splits the depth map into left, center, and right zones and reports smoothed distances. Progressive bands trigger speech, haptics, and audio alerts as you get closer to something.

YOLOv8n runs through Apple's Vision framework on the Neural Engine. It recognizes 80 COCO classes (people, cars, chairs, etc.) at about 3 fps. People detections are cross checked against Apple's VNDetectHumanRectanglesRequest, so YOLO calling something a "person" only sticks if Apple's human detector also sees a human in the same place. This kills almost all of the phantom "person" announcements from photos, posters, and mannequins.

ARKit mesh classification reconstructs a 3D mesh of the room and labels surfaces as walls, doors, windows, seats, or tables. The mesh check ranges out to 6 meters and filters to a forward facing 60 degree cone, so walls behind you don't get announced.

DeepLabV3 catches large objects YOLO missed by segmenting the whole frame into 21 PASCAL VOC classes.

BlindGuideNav is the custom 55 class model trained for this project on navigation specific features (curbs, crosswalks, stairs, doors, railings, wet floors, etc.). It runs alongside YOLO and their detections merge before the announcement system picks what to speak.

### Wall inference for featureless surfaces

The hardest failure mode encountered was a blank white wall with no edges. ARKit's mesh classifier needs visual features to anchor, so it sometimes loses tracking with `.limited(.insufficientFeatures)` when the camera is pointed at a flat painted wall. The fix: when the left, center, and right depth zones all read similar distances and no object detection has fired in the center recently, the app says "Wall ahead" instead of the generic "Heads up" or "Something ahead." This backstops the mesh classifier exactly when it would otherwise fail. Depth processing now keeps running during `.limited(.insufficientFeatures)` so the inference can fire.

The wall announcer also has three distance tiers: "Wall ahead" under 3 meters, "Wall, X feet" under 2 meters, "Wall nearby" under 1 meter.

### Cloud AI

When you trigger a scan, the app sends a compressed camera frame to a Cloudflare Worker that races Claude Haiku 4.5 against GPT-4.1-mini. Whichever responds first gets spoken aloud. The prompt is safety focused with a 15 word maximum, prioritizing stairs and immediate hazards.

### Interaction

Voice commands are activated by holding the screen. Recognized commands include "what's around," "is it safe," "left," "right," "scan," "stop," "resume," and "help." Known commands fire from partial recognition for minimal latency.

Haptics pulse faster as you get closer. Caution pulses every 0.5 seconds. Danger pulses every 0.1 seconds.

Spatial audio plays a short beep panned to the side an obstacle is on. Beeps fire only at danger level. The spatial channel pauses when speech is playing so you can hear each clearly.

### Distance bands with hysteresis

The progressive band system fires once when you enter each band. Enter danger at 1.0 meter, exit at 1.1. Enter caution at 2.0, exit at 2.2. The hysteresis stops LiDAR jitter from flipping the band back and forth at the boundary. More detail in [Distance](Distance.md).

### Depth-Anything fallback

On iPhones without LiDAR, the app loads a Depth-Anything CoreML model converted from the HuggingFace export. It runs in about 9 ms on iPhone 13 and produces a relative depth map. The model is preloaded on app launch so the engine starts instantly when the user taps START. The same progressive band system uses these estimates, just labeled as approximate so speech drops the foot count.

### Startup speech

When you tap START, the app says "Loading. One moment." right away. Once the first real depth callback arrives, it says "GuideDog active." This is so blind users know whether the engine is initializing or actually running.
