# Web Speech and Audio

## Technical Complexities

iOS Safari is the most restrictive environment for browser audio. Several workarounds came out of testing and are now baked in.

Audio unlock primer utterance. iOS Safari blocks `speechSynthesis.speak()` until a user gesture occurs. The fix: call `speak()` with an empty string, volume 0, rate 10 (max) on the very first touch. The user hears nothing but the engine unlocks for all later calls.

Document level touch listeners. The unlock listeners attach to `document`, not to specific UI elements, because privacy and help overlays sit at higher z indexes and intercept touches before they reach anything underneath. Document level catches every touch on every overlay.

Never call `cancel()` before `speak()`. On iOS Safari, calling `speechSynthesis.cancel()` immediately before `speak()` can silently drop the new utterance. The `doSpeak` wrapper never cancels. Only the priority 3 danger path cancels, and even then it waits 50 ms before speaking the replacement.

Exponential gain envelope on beeps. Each tone ramps from target volume down to 0.01 over the duration. An abrupt cutoff produces an audible click on most speakers. The exponential ramp produces a clean fade.

`onended` audio node disconnect. Every oscillator, gain, and panner gets disconnected after the beep finishes to prevent memory leaks from accumulated audio nodes.

Three independent encoding dimensions for urgency. Frequency (500, 800, 1200 Hz), beep count (1, 2, 3), and volume (0.3, 0.5, 0.7). All three reinforce the same severity signal so the user picks up urgency even if one dimension is masked by background noise.

Stereo panning for spatial cues. Left obstacles pan to -0.8, right obstacles pan to +0.8, ahead plays at 0. Directional information without speaking the word "left" or "right."

## Overview

Three audio channels: synthesized speech (Web Speech API), tonal beeps (Web Audio API), and haptic vibration (Vibration API). Speech conveys detailed information. Beeps provide direction and urgency. Vibration confirms tactically even when the phone is muted.

---

## Speech synthesis

### doSpeak

The lowest level speech wrapper. Creates a `SpeechSynthesisUtterance`, sets rate (default 1.1x) and volume (1.0), and calls `speechSynthesis.speak()`.

`doSpeak` never calls `speechSynthesis.cancel()` before speaking. Intentional workaround for an iOS Safari bug: calling `cancel()` right before `speak()` can silently drop the new utterance. By never canceling, utterances queue naturally and play in order.

`onend` and `onerror` handlers reset `_currentSpeechPriority` to 0, indicating no priority locked speech is active.

### speak

Used for user initiated speech (button taps, voice command responses). Accepts a `force` flag. When `force` is true, it calls `speechSynthesis.cancel()` before speaking. This is acceptable because user initiated speech should interrupt any current alert.

When `force` is false, the function checks `CONFIG.VOICE_COOLDOWN` (1.5 s) to prevent repeats. If the user is currently using voice recognition (`state.isListening`), speech recognition is stopped before speaking, since the mic and speaker can't both be active on most devices.

### speakAlert

Used for automated alerts from the detection system. Three priority tiers with zero cooldowns:

**Priority 3 (Danger):**
- Calls `speechSynthesis.cancel()` to interrupt
- Waits 50 ms (via `setTimeout`) to let the cancel take effect
- Speaks at 1.3x rate for urgency
- Only automated path that cancels current speech

**Priority 2 (Warning):**
- Queues naturally via `doSpeak` at 1.1x rate
- Doesn't cancel
- Plays after current utterance finishes

**Priority 1 (Info):**
- Same behavior as priority 2

All three priorities have zero cooldowns. The cooldown map is `{ 3: 0, 2: 0, 1: 0 }`. Earlier versions used 2 to 3 second cooldowns but those caused alerts to feel delayed. Users reported missing important warnings because the cooldown timer hadn't expired. Setting all cooldowns to zero ensures every alert is delivered immediately. Duplicate alerts are prevented by temporal smoothing in the detection system, not by the speech system.

Each alert uses a `key` parameter (such as `"fast_danger"` or `"stairs"`) tracked in `state.lastAlerts`. The cooldown is checked against this key, but since cooldowns are zero the check always passes. The key mechanism stays in the code in case per alert cooldowns need to come back.

---

## iOS Safari audio unlock

iOS Safari blocks both `speechSynthesis.speak()` and `AudioContext` playback until a user gesture occurs. The app handles this with a multi step unlock.

### Document level listeners

Two event listeners attach at the document level:

```
document.addEventListener('touchstart', unlockAudio, { once: true, passive: true });
document.addEventListener('click', unlockAudio, { once: true });
```

These fire on the very first touch or click anywhere on the page. `{ once: true }` removes them after firing.

### unlockAudio

Does two things:

1. Resumes the AudioContext. If it's `suspended` (which it always is on iOS until a gesture), `resume()` is called.

2. Speaks a primer utterance. On the first call only (tracked by `state.audioUnlocked`), creates a `SpeechSynthesisUtterance` with an empty string, volume 0, rate 10 (max). This silent utterance unlocks the speech engine on iOS. Without it, later `speechSynthesis.speak()` calls would be silently ignored.

The primer is intentionally silent and fast so the user hears nothing. It exists solely to satisfy iOS Safari's requirement that speech synthesis be initiated from a user gesture.

### Why document level

Earlier versions attached the unlock listeners to the `alertArea` element. That failed when overlays (privacy, help) were shown on top, because touches on the overlay didn't reach the `alertArea`. Attaching to `document` ensures any touch anywhere triggers the unlock regardless of which overlay is visible.

---

## Web Audio API: beeps

### Initialization

`initAudio` creates a new `AudioContext` (or `webkitAudioContext` on older Safari). If the Web Audio API is unavailable, the AI badge changes to "Audio Unavailable" and the system continues without tonal alerts. Speech and vibration still work.

### playBeep

Generates a sine wave tone:

- **Frequency:** in Hz (e.g., 500, 800, 1200)
- **Duration:** in seconds (e.g., 0.1, 0.15, 0.2)
- **Pan:** stereo panning from -1 (full left) to 1 (full right), default 0
- **Volume:** gain 0 to 1, default 0.5

The audio graph:

```
Oscillator (sine wave) -> Gain (envelope) -> StereoPanner -> Destination
```

The gain envelope starts at the specified volume and ramps exponentially to 0.01 over the duration. Natural fade out instead of an abrupt cutoff (which would click).

All audio nodes (oscillator, gain, panner) are disconnected in the `onended` handler to prevent memory leaks.

### playAlertSound

Translates urgency into distinct beep patterns:

**Danger:** Three rapid 1200 Hz beeps at 0.7 volume, spaced 150 ms apart. High frequency and rapid repetition convey urgency.

**Warning:** Two 800 Hz beeps at 0.5 volume, spaced 200 ms apart. Lower frequency and wider spacing convey caution without panic.

**Info:** One 500 Hz beep at 0.3 volume. A single low frequency tone at reduced volume conveys awareness.

The `position` parameter controls stereo panning. Left obstacles pan to -0.8. Right obstacles pan to 0.8. Ahead plays in the center. Spatial audio helps the user locate direction without verbal description.

---

## Vibration API

### vibrate

Wraps `navigator.vibrate()` with a cooldown check. Vibrations are rate limited to one every 400 ms (`CONFIG.VIBRATE_COOLDOWN`) to prevent continuous buzzing that would desensitize the user.

Uses optional chaining (`navigator.vibrate?.()`) and a try/catch, since the Vibration API isn't available everywhere (notably iOS Safari).

### vibrateAlert

Patterns by urgency:

**Danger:** `[200, 100, 200, 100, 200]`. Three long buzzes with short pauses. Total 800 ms.

**Warning:** `[150, 100, 150]`. Two medium buzzes with a short pause. Total 400 ms.

**Info:** `[100]`. One short buzz. Total 100 ms.

Longer patterns for higher urgency provide a stronger tactile signal. Users learn to associate the pattern with severity without needing the audio.
