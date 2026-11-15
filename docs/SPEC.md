# Tacit Type — Spec v1

Nov 7, 2026 · @faisal

Tacit Type is a Mac menu-bar app that triggers a docked iPhone to stream TrueDepth face data and audio, then turns it into typed text: first spoken or whispered speech, then silently mouthed sentences read from mouth video. This spec covers build steps 1–3 and is written to be handed to Claude Code.

## Scope

v1 ships three things, in order: a synced face + audio recorder, a spoken/whisper dictation mode, and silent dictation from mouth video. The app runs entirely locally; only model fine-tuning may use a rented GPU.

| Step | Delivers | Done when |
| --- | --- | --- |
| 1. Recorder | iPhone streams ARKit face frames, mouth video and mic audio to the Mac; Mac saves timestamped sessions | A 60 s session saves with < 1% dropped frames and face/audio/video drift < 20 ms |
| 2. Spoken / whisper mode | Hotkey → iPhone mic audio → WhisperKit on Mac → text typed into the focused app | Whispered sentence appears in the focused app < 1.5 s after release |
| 3. Silent dictation | Hold a hotkey, mouth a sentence with no sound → fine-tuned lip-reading model reads the mouth video → LLM cleanup → text typed | Fine-tuned model beats the pretrained baseline on held-out silent sittings; ≥ 7 of 10 everyday test phrases correct in meaning |

**Platforms:** macOS 15+ (Apple silicon only), iOS 18+ on an iPhone with TrueDepth (Face ID). Swift 6, SwiftUI, Xcode 16+.

**Out of scope for v1:** a silent command classifier (dropped), models that use Face ID data (recorded now for v2), working in the dark, multi-user models, the Continuity Camera / webcam path, Windows, App Store distribution (Developer ID build + TestFlight; the Python sidecar makes v1 developer-only), cloud sync, AirPods gestures (stub the trigger interface so they can be added later).

## Architecture

&#91;embedded content: System architecture · iPhone sensor, encrypted link, Mac pipelines\]

The iPhone app streams face frames, mouth video and audio only between `start` and `stop`. Recording, dictation and lip-reading all run on the Mac; model training runs offline in `ml/` and the Mac app runs the result in a local Python sidecar.

## Project layout and wire protocol

One repo, one Xcode workspace, one shared Swift package so both apps compile the exact same message definitions. Both apps ship under one name, **Tacit Type**. In code the targets are `TacitType-macOS` and `TacitType-iOS`; this spec calls them "the Mac app" and "the iPhone app".

```
tacittype/
  TacitType.xcworkspace
  Packages/TacitKit/           # Swift package, used by both apps
    Sources/TacitKit/
      Protocol/                # Message enums, binary codecs, NWProtocolFramer
      Model/                   # FaceFrame, MouthFrame, AudioChunk, SessionManifest
      Features/                # MouthActivity and other shared feature code
      Constants.swift          # lipVertexIndices, cropLandmarkIndices, rates, protocol version
    Tests/TacitKitTests/
  Apps/TacitType-iOS/          # iOS companion app
  Apps/TacitType-macOS/        # macOS menu-bar app
  ml/                          # Python: loader, fine-tuning, sidecar server
    pyproject.toml
    prompts/                   # Harvard + everyday sentence lists
    third_party/usr2/          # pinned submodule: USR 2.0 (primary model)
    third_party/auto_avsr/     # pinned submodule: Auto-AVSR (fallback)
    silentml/{data,preprocess,models,finetune,evaluate,serve}.py
  docs/                        # this spec, exported as SPEC.md
```

### Framing

One TCP stream (over TLS-PSK, see Pairing) carries all messages. A custom `NWProtocolFramer` adds an 8-byte header to each message:

| Bytes | Field | Notes |
| --- | --- | --- |
| 0 | `type` (UInt8) | Message type, table below |
| 1 | `version` (UInt8) | Protocol version, start at 1; reject mismatches with an `error` message |
| 2–3 | reserved | 0 |
| 4–7 | `length` (UInt32, little-endian) | Payload bytes |

Control messages carry JSON payloads (`Codable`). Data messages carry packed little-endian binary so 60 fps stays cheap.

### Message types

| Type | Name | Direction | Payload |
| --- | --- | --- | --- |
| 0x01 | `hello` | both | JSON: deviceId, deviceName, deviceModel, appVersion, osVersion?, protocolVersion, capabilities |
| 0x02 | `start` | Mac → iPhone | JSON: sessionId (UUID), mode (`record` / `dictate` / `silent`), streams (`face`, `audio`, `mouth`), promptText? |
| 0x03 | `stop` | Mac → iPhone | JSON: sessionId |
| 0x04 | `status` | iPhone → Mac | JSON: state, trackingState, faceDetected, thermalState, batteryLevel, isCharging |
| 0x05 | `clockPing` / 0x06 `clockPong` | both | JSON: t0, t1, t2 (seconds) for offset estimation |
| 0x07 | `pairRequest` | Mac → iPhone | JSON: publicKey (X25519, base64). Pairing listener only |
| 0x08 | `pairAccept` | iPhone → Mac | JSON: publicKey (X25519, base64) |
| 0x09 | `forget` | both | JSON: {}. Sender has deleted its key; receiver deletes its key too |
| 0x10 | `faceBatch` | iPhone → Mac | Binary: N face frames, layout below |
| 0x11 | `audioChunk` | iPhone → Mac | Binary: Float64 ptsOfFirstSample + Int16 PCM, 16 kHz mono |
| 0x12 | `mouthBatch` | iPhone → Mac | Binary: N mouth crops + landmarks, layout below (Step 3) |
| 0x7F | `error` | both | JSON: code, message |

### FaceFrame binary layout (one frame, 1,052 bytes with 64 lip vertices)

| Field | Type | Count | Notes |
| --- | --- | --- | --- |
| timestamp | Float64 | 1 | `ARFrame.timestamp` (host-clock seconds, same clock as audio PTS) |
| trackingFlags | UInt32 | 1 | bit0 isTracked, bit1 trackingState == normal |
| blendShapes | Float32 | 52 | Fixed order = `ARFaceAnchor.BlendShapeLocation` sorted alphabetically by rawValue; order lives in `Constants.blendShapeOrder` |
| headTransform | Float32 | 16 | `faceAnchor.transform`, column-major |
| lipVertices | Float32 | 64 × 3 | `faceAnchor.geometry.vertices[i]` for i in `Constants.lipVertexIndices`, face-local coordinates (already head-pose free) |

`faceBatch` = UInt16 frameCount + frames. The iPhone sends one batch every 100 ms (about 6 frames), or immediately on `stop`.

### Mouth video (added for Step 3)

`0x12 mouthBatch` (iPhone → Mac), binary: UInt16 frameCount, then per frame: Float64 timestamp (same host clock as face and audio), UInt8 landmarkCount, landmarkCount × (Float32 x, Float32 y) in crop pixels, UInt32 jpegLength, JPEG bytes (192×192 grayscale). Sent every 200 ms (about 5 frames), or immediately on `stop`. Only sent when `start.streams` includes `mouth`.

## Pairing, discovery and transport

The Mac and iPhone find each other with Bonjour and talk over a direct, encrypted TCP connection that works with or without shared Wi-Fi.

**Discovery**

- iPhone advertises with `NWListener` on service type `_tacittype._tcp`, TXT record: `id` (stable device UUID in Keychain), `name`, `v` (protocol version).
- It runs two listeners. The main one holds one PSK per paired Mac and is rebuilt when that set changes. The pairing one (instance name suffixed "(Pairing)", TXT `pair=1`) exists only while a code is on screen and accepts nothing but `hello` + `pairRequest`, so a code can never open a normal session.
- Mac browses with `NWBrowser` for the same type. Both set `parameters.includePeerToPeer = true` so AWDL is used when there is no common network.
- Add `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_tacittype._tcp]` to both Info.plists.

**First-time pairing**

1. The iPhone shows a 6-digit code whenever it has no paired Mac, or after "Pair Another Mac" (touch and hold the dock screen).
2. User picks the iPhone in the Mac's "Pair New iPhone…" window and types the code.
3. Both sides derive a 32-byte pre-shared key: `HKDF-SHA256(code, salt = iphoneId, info = "tacittype-pair-v1")`, then open a TLS-PSK connection with identity `tt1-pair`. The Mac's id is not in the salt because the iPhone has to configure the key before any Mac connects.
4. Inside that connection the Mac sends `hello` + `pairRequest` with an ephemeral X25519 key, and the iPhone answers `pairAccept` with its own. Both derive the long-term key as `HKDF-SHA256(X25519 shared secret, salt = iphoneId || macId, info = "tacittype-ltk-v1")` and store it in Keychain keyed by the peer's id. The code is never used again. Because the key comes from X25519, someone who records the pairing handshake and brute-forces the code offline still can't recover it.
5. 10 failed handshakes on one code make the iPhone show a fresh one. A single wrong code can cost several, since Network.framework tries AWDL, IPv6 and IPv4 at once.

**Every later connection:** TLS-PSK with PSK = long-term key and identity `tt1:<macId>`, client session resumption off. Unknown peers are rejected. "Forget device" deletes the key on both sides and sends `forget` if connected.

**TLS version (measured, Nov 2026):** Network.framework only negotiates PSK with TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256`. TLS 1.3 PSK handshakes fail, and the ECDHE-PSK suites are silently replaced by the plain PSK suite. Forward secrecy for pairing comes from step 4. Over a Bonjour endpoint a refused key leaves the connection in `preparing` instead of failing, so the Mac treats a handshake timeout as "wrong code" while pairing and three timeouts in a row as "rejected" when reconnecting.

**Reconnect:** Mac auto-connects to the last paired iPhone whenever it appears in the browser. On drop, retry with backoff 0.5 s → 1 → 2 → 5 s (cap). `NWConnection.pathUpdateHandler` drives UI state.

**Clock sync:** on connect and every 10 s, run 5 `clockPing`/`clockPong` rounds; keep the round with the lowest RTT; offset = ((t1 − t0) + (t2 − t3)) / 2, where t3 is the Mac's receive time. Used only for latency metrics and logs. Face, audio and mouth video already share the iPhone clock, so alignment between them never depends on this.

**Bandwidth budget:** face ≈ 63 KB/s + audio 32 KB/s ≈ 0.8 Mbit/s. Mouth video adds ≈ 250 KB/s (25 fps × \~10 KB JPEG), ≈ 2.8 Mbit/s in total; only the mouth video is compressed.

## iOS companion app (Tacit Type for iPhone)

The iPhone app is a thin sensor: it stays open on a MagSafe stand, keeps the camera off until the Mac sends `start`, then streams face frames, mouth video and audio until `stop`. All processing happens on the Mac.

### States

| State | Camera / mic | Screen | Enters on | Leaves on |
| --- | --- | --- | --- | --- |
| `unpaired` | off | Pairing code + instructions | first launch, forget device | pairing completes |
| `idle` | off | Dock screen (black, small status dot) | paired + Mac connected or waiting | `start` |
| `capturing` | ARKit running | Dock screen, dot turns green | `start` | `stop`, disconnect, 120 s safety timeout |
| `error` | off | Message + retry | permission denied, no TrueDepth, ARKit failure | user action |

Leaving `capturing` always pauses the `ARSession`, so the green camera indicator is never on outside a session.

### Dock mode

- When `UIDevice.batteryState` is `.charging` or `.full`: set `isIdleTimerDisabled = true`, show a black dock screen, and lower `UIScreen.main.brightness` to 0.1 (restore it on exit).
- On battery: idle timer behaves normally; show a banner telling the user to dock the phone.
- Expose an App Intent `OpenDockModeIntent` (`openAppWhenRun = true`). Onboarding walks the user through one Shortcuts personal automation: **When charger is connected → Open Tacit Type**, set to run immediately.
- iOS suspends the listener and ARKit in the background, so the iPhone app must be in the foreground to work. If the Mac can't find it, the Mac shows "Open Tacit Type on your iPhone". (Remote wake via push is out of scope for v1.)

### Capture pipeline

- `ARFaceTrackingConfiguration`: `maximumNumberOfTrackedFaces = 1`, `providesAudioData = true`, `isLightEstimationEnabled = false`, `videoFormat` = the highest-fps format in `supportedVideoFormats` (expect 60).
- `session.delegateQueue` = a dedicated serial queue, never main.
- `session(_:didUpdate frame:)`: take the first `ARFaceAnchor` in `frame.anchors`, pack a `FaceFrame` with `frame.timestamp`, append to the current batch, flush every 100 ms. If no face: send a frame with `trackingFlags = 0` and zeros, so gaps are explicit.
- `session(_:didOutputAudioSampleBuffer:)`: convert with a cached `AVAudioConverter` to 16 kHz mono Int16; send an `audioChunk` per buffer with the PTS of its first sample (`CMSampleBufferGetPresentationTimeStamp`, seconds). Both timestamps are on the same host clock.
- Target: first face frame < 450 ms after `start` arrives. Log it in every session. The TrueDepth camera alone takes about 420 ms to power on from off (measured Nov 2026), and no ARKit run option or video format shortens it.
- Thermal: if `ProcessInfo.thermalState >= .serious`, report it in `status` (the Mac warns the user). Don't change the frame rate silently.

### Mouth video crop

The iPhone sends a loose, lightly normalised crop plus landmarks; the exact alignment the lip-reading model needs runs on the Mac in Python (Step 3). Preprocessing can then change without re-recording.

1. **Frame rate:** keep the ARKit frame nearest each 40 ms tick, giving 25 fps, the rate both models were trained on (see Model preprocessing in Step 3).
2. **Landmarks:** project 12 face-mesh vertices (4 eye corners, nose bridge, nose tip, nose base, 2 mouth corners, upper and lower lip centres, chin) into `frame.capturedImage` with `ARCamera.projectPoint`. These cover the 68-point positions both models align with (iBUG 28, 30, 33, 36, 39, 42, 45, 48, 54 and the mouth centre). Landmarks may fall outside the crop, so keep them as unclamped floats. Hardcode their indices in `Constants.cropLandmarkIndices`, picked with the same debug screen as the lip vertices. `CropLandmarkSelector` proposes them from ARKit's neutral mesh (eye and mouth holes, the face midline, and nose depth), and the picker's "Copy Crop Landmarks" button shows and copies that result. They were hardcoded on Nov 15, 2026. Changing them after mouth data exists bumps `mouthFileVersion`.
3. **Crop:** a square centred on the mouth, side = 3 × mouth width, rotated so the eye line is level. Take it from the image's luma (Y) plane, so it's already grayscale. Resize to 192×192 with vImage.
4. **Encode:** JPEG quality 85 (\~8–12 KB) on the capture queue, then send in `mouthBatch` with the landmarks mapped into crop pixels.
5. **Light:** compute mean luma per crop and report it in `status`; the Mac warns when it's too dark.

Cropping and encoding must not drop face frames: measure capture-queue time and keep it under 8 ms per frame.

### Lip vertex selection (one-off dev task)

`ARFaceGeometry` has the same 1,220-vertex topology on every device. Build a debug screen `LipVertexPickerView` that, on a neutral face: (1) takes vertices inside a mouth bounding box in face-local space, (2) keeps those within \~6 mm of the lip contour, (3) farthest-point-samples 64 of them. Render them as dots over the face mesh for visual review. Hardcode the result in `Constants.lipVertexIndices` and never change it after Step 1 data exists. Any change bumps a `featureSchemaVersion`.

### Permissions and plist

`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices`. Check for TrueDepth with `ARFaceTrackingConfiguration.isSupported` and show `error` otherwise.

## Mac app (Tacit Type for Mac)

The Mac app is a menu-bar-only app (`LSUIElement = YES`, SwiftUI `MenuBarExtra`) that owns the connection, decides when to capture, runs all inference, and types the result. Distributed as a Developer ID-signed, notarised build with hardened runtime and no App Sandbox, because it needs Accessibility and synthetic key events.

### Components

| Component | Responsibility |
| --- | --- |
| `DeviceManager` | `NWBrowser`, pairing flow, Keychain keys, connection lifecycle, reconnect, exposes `@Observable` state |
| `TriggerCenter` | Turns inputs into `began` / `ended` events per mode. v1 source: `HotkeyTrigger`. Protocol `TriggerSource` so `AirPodsNodTrigger` can be added later |
| `SessionManager` | Sends `start`/`stop`, receives batches, keeps per-session ring buffers, hands a finished `CaptureSession` to the active pipeline, optionally persists it |
| `SessionStore` | Writes and reads the on-disk session format (Step 1), including `mouth.mp4` via `AVAssetWriter` |
| `DictationPipeline` | Audio → WhisperKit → cleanup → `TextInserter` (Step 2) |
| `SilentDictationPipeline` | Mouth video → Python sidecar (lip-reading model) → LLM cleanup → `TextInserter` (Step 3) |
| `ModelSidecar` | Starts, health-checks and restarts the Python model server; reports its status in Settings |
| `TextInserter` | Puts text into the focused app |
| `HUDController` | Small non-activating `NSPanel` near the menu bar showing listening / processing / result / error |

### Triggers (v1)

Both modes are toggles: press once to capture, press again to process. Use the `KeyboardShortcuts` Swift package (sindresorhus) for user-configurable global hotkeys with key-down and key-up callbacks.

| Mode | Default hotkey | On key down | On key up |
| --- | --- | --- | --- |
| Dictate (spoken/whisper) | press ⌃⌥Space once | send `start` with streams `[audio, face, mouth]` | nothing. Press again to keep a 300 ms tail, then `stop`, run `DictationPipeline` |
| Silent dictate | press ⌃⌥S once | send `start` with streams `[mouth, face, audio]` | nothing. Press again to keep a 300 ms tail, then `stop`, run `SilentDictationPipeline` |
| Record (training) | from Recorder window | `start` with `promptText` | `stop` on button or prompt timer |

Always request all three streams, even when a mode only needs one. Every real use then doubles as training data, if the user has turned on "Save sessions for training" (off by default).

If the second press comes within 250 ms of the first, cancel and type nothing. If the iPhone isn't connected, the HUD shows "iPhone not connected" and nothing is sent.

### Text insertion

1. Preferred: find the focused element with `AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute)` and set `kAXSelectedTextAttribute` to the text. This replaces the selection, or inserts at the caret.
2. Fallback when step 1 fails or the app ignores it (many Electron apps): snapshot `NSPasteboard.general` (all items and types), write the text, post ⌘V with `CGEvent`, wait 150 ms, restore the pasteboard.
3. Per-app override list in Settings: force paste for bundle IDs where AX insertion misbehaves.

On first run, prompt for Accessibility with `AXIsProcessTrustedWithOptions` and poll until it's granted.

### Menu and windows

- **Menu:** connection status (device name, green/grey dot), mode hotkeys, "Open Recorder…", "Settings…", "Quit".
- **Settings:** Devices (pair, forget), Hotkeys, Dictation (model size, cleanup on/off), Silent dictation (sidecar status, checkpoint path, LLM cleanup on/off), Data (save sessions toggle, data folder, delete all), Diagnostics (latency stats, last 50 log lines).
- **Recorder** window is specified in Step 1.

### Logging and metrics

Use `os.Logger` with subsystem `com.tacittype` and categories `net`, `session`, `dictation`, `silent`. For every session record: trigger → first face frame, trigger → first audio, key up → text inserted, dropped frame count. Show rolling p50/p95 in Diagnostics.

## Step 1 — Recorder

Step 1 makes the data engine: a Recorder window that walks the user through prompted takes and saves each one as a self-describing session folder that both Swift and Python can read.

### Session folder

```
~/Library/Application Support/TacitType/sessions/2026-11-07/<sessionId>/
  manifest.json   # metadata, below
  face.bin        # 16-byte header + FaceFrame records, same layout as the wire
  audio.wav       # 16 kHz mono PCM Int16
  mouth.mp4       # 192x192 grayscale mouth crops, H.264, 25 fps (Step 3)
  mouth.bin       # per-frame timestamp + crop landmarks (Step 3)
  transcript.json # optional, written by Step 2 / labeling job
```

- `face.bin` header: magic `SFCE` (4 bytes), UInt16 featureSchemaVersion, UInt16 lipVertexCount, UInt32 frameCount, UInt32 reserved. Records follow back to back, so Python reads them with `numpy.fromfile` and a structured dtype.
- `audio.wav` starts at the PTS of the first audio sample. If chunks arrive with a gap (PTS jump > 1 ms), fill the gap with zeros so sample index ↔ time stays linear, and count it in `audioGapsFilled`.
- `transcript.json`: `{ text, words: [{ w, start, end, p }], model, createdAt, wer? }`. Word times are seconds from `firstAudioTs`. `words` is empty when live dictation wrote it. `wer` is against `promptText` and only set for Recorder takes.
- `mouth.mp4`: written by the Mac with `AVAssetWriter` (H.264, high quality, constant 25 fps). The exact capture time of each frame lives in `mouth.bin`: magic `SMTH`, UInt16 version, UInt16 landmarkCount, UInt32 frameCount, then per frame Float64 timestamp + landmarks. The manifest adds `mouthFrameCount`, `mouthFps` and `meanLuma`.

### manifest.json fields

| Field | Example | Notes |
| --- | --- | --- |
| sessionId, createdAt | UUID, ISO 8601 |  |
| mode | `record` / `dictate` / `silent` | Which pipeline triggered it |
| speechStyle | `aloud` / `whisper` / `silent` / `negative` | Set by the Recorder; `dictate` defaults to `aloud`, `silent` to `silent` |
| promptId, promptText | `harvard-03-07`, "The birch canoe…" | null outside the Recorder |
| sittingId | UUID | One per Recorder sitting, so training can hold out whole sittings. Absent outside the Recorder |
| device | `iPhone16,1`, iOS 18.2 |  |
| appVersions, protocolVersion, featureSchemaVersion |  | Reject mixing schema versions in training |
| firstFaceTs, firstAudioTs | 81234.512, 81234.498 | iPhone host-clock seconds |
| frameCount, measuredFps, trackedRatio | 612, 59.8, 0.99 |  |
| droppedFrames, audioGapsFilled | 0, 0 | Dropped = expected frames − received, from timestamps |
| quality | `{ "ok": true, "flags": [] }` | From the checks below |

### Recorder window

A SwiftUI window that runs blocks of prompts. Each block has a speech style and a prompt list.

| Block | Prompts | Takes | Purpose |
| --- | --- | --- | --- |
| Sync check | "pa pa pa pa pa" aloud | 1 per Recorder launch | Measures face/audio/video offset |
| Aloud sentences | Harvard + everyday prompts (`ml/prompts/`), shuffled | 50 per sitting | Step 3 fine-tuning |
| Whisper sentences | 10 of the aloud block's prompts, whispered | 10 per sitting | M4 dictation and mouth-gate checks |
| Silent sentences | The same prompts, mouthed | 50 per sitting | Step 3 fine-tuning (the real task) |
| Test set | 100 everyday prompts, silent | Once, in its own sitting | Held-out score; never trained on |
| Neutral | "Stay still" | 3 × 10 s per sitting | Neutral face + `MouthActivity` threshold |

Flow per take: show the prompt large, then a 3-2-1 countdown → capture → the user presses Space to stop (or it stops on the prompt's time limit) → quality checks run → a review strip plays back. Keys: **Space** start/stop, **R** redo, **→** accept and next, **Delete** discard.

The review strip draws the audio waveform with `jawOpen` and `mouthClose` curves on the same time axis, so sync is visible at a glance.

### Quality checks

- `trackedRatio ≥ 0.95` and `measuredFps ≥ 55`, else flag `poor_tracking`.
- Aloud and whisper: speech detected by a simple energy VAD, else `no_speech`.
- Silent: audio RMS above −40 dBFS for more than 300 ms → flag `audible_in_silent` and ask "We heard you; redo silently?"
- Duration between 0.4 s and 2× the prompt's expected length.
- Sync check: cross-correlate the audio energy envelope with `jawOpen` (both resampled to 100 Hz). Report the lag; pass if |lag| < 20 ms. Store the lag in every later manifest of that sitting as `measuredAvOffsetMs`.

**Video checks:** mean crop luma below 60 (of 255) → flag `low_light`; fewer than 98% of expected mouth frames → `mouth_dropped`. The review strip also plays the mouth crops in sync with the audio.

Flagged takes are saved with `quality.ok = false` and excluded by the Python loader by default.

Flag names: `poor_tracking`, `no_speech`, `audible_in_silent`, `too_short`, `too_long`, `sync_offset`, `sync_failed`, `incomplete`, `low_light`, `mouth_dropped`, `transcript_mismatch` (set by the label job in Step 2). The checks live in `TacitKit/Features/TakeQuality.swift` and `SyncCheck.swift`.

Recorder details settled in M3:

- The Mac sends `start` as the last count of the 3-2-1 begins, so the camera is already running when the user starts. Each take therefore opens with about 0.3 s of lead-in. The duration check measures from the end of the countdown.
- The silent sentence block repeats the aloud block's 50 sentences in a new order. Sentences with no accepted aloud take come first, so sittings work through the whole prompt corpus.
- Keys beyond the four above: **S** skips a prompt, and **Space** on the review strip replays the take.

Recorder details settled in M3b:

- Prompt lists live in `ml/prompts/` and are copied into the Mac app bundle. `harvard.txt` is there. `everyday.txt` (about 1,300 lines, reviewed by hand) and `test.txt` (100 lines) still need writing. Until `everyday.txt` exists the sentence blocks draw from Harvard only, and "New Test Set Sitting" has nothing to show until `test.txt` exists. Lines starting with `#` are comments. Prompt ids are the file name plus a 4-digit line number, for example `everyday-0012`.
- Neutral takes are saved with `speechStyle` `negative`, so `iter_sessions(style="negative")` returns them with any other no-speech takes.
- The sync check runs twice on the same take, once against `jawOpen` and once against mouth-crop openness (how dark the middle of the crop is). Both lags are shown, and either failing asks for a redo.

### Python loader (ml/silentml/data.py)

`load_session(path) -> Session(face: np.ndarray[T, F], face_ts: np.ndarray[T], audio: np.ndarray[S], audio_t0: float, manifest: dict, tracked: np.ndarray[T], path: Path, mouth: np.ndarray[N, 192, 192] | None, mouth_ts: np.ndarray[N] | None, mouth_landmarks: np.ndarray[N, 12, 2] | None, transcript: dict | None)` plus `iter_sessions(root, style=None, ok_only=True)`. A unit test in Swift writes a synthetic session and a pytest reads it back and checks every field, so the two sides can't drift. `mouth.mp4` is decoded with PyAV, taking the Y plane and expanding video range back to 0 … 255 exactly as Swift does.

## Step 2 — Spoken and whisper mode

Step 2 proves the whole loop before any ML training: press the hotkey, speak or whisper, press it again, and the text lands in the focused app within 1.5 s. It also auto-labels the aloud sessions from Step 1.

### Pipeline

1. Key up → `SessionManager` returns the session's audio (16 kHz Int16) after the 300 ms tail.
2. **Pre-process:** convert to Float32, remove DC offset, peak-normalise to −3 dBFS (whispers are quiet), run an energy VAD, then apply the mouth-activity gate (below). If there's no speech, show "Didn't catch that" in the HUD and stop.
3. **Transcribe** with WhisperKit (Swift package `argmaxinc/WhisperKit`), Core ML on the Neural Engine, `DecodingOptions`: language `en`, `temperature 0` with fallback, `withoutTimestamps: true`, `suppressBlank: true`, `promptTokens` built from the user's custom vocabulary (Settings → Dictation → Words), `noSpeechThreshold 0.6`.
4. **Hallucination guard:** drop the result if it is one of a short blocklist ("Thank you.", "Thanks for watching!", "you", ".") and the clip is < 1.5 s or quiet.
5. **Cleanup:** trim, collapse whitespace, apply the user's replacements list (for example "new line" → `\n`). Optional LLM polish: if Apple's `FoundationModels` framework is available (macOS 26+) and the toggle is on, ask the on-device model to fix punctuation only, with a 400 ms timeout; on timeout use the raw text.
6. **Insert** via `TextInserter`; HUD shows the text for 1.5 s.

### Mouth-activity gate

Whisper only hears audio from moments when your mouth is moving. This stops it inventing text from silence or room noise, and ignores people talking near you while your mouth is still.

1. **Score:** compute the mouth-activity score from the session's face frames: L2 norm of the frame-to-frame velocity of the 29 mouth/jaw blendshapes (raw values, not z-scored), smoothed with a 100 ms moving average, at 60 Hz. Implement it once in `TacitKit/Features/MouthActivity.swift`; Step 3's crop uses the same function.
2. **Threshold:** θ = mean + 4 × std of the score over the user's "stay still" takes from the Recorder. Until those exist, use a default constant and tune it during M4.
3. **Hysteresis:** the gate opens when the score stays above θ for ≥ 80 ms and closes when it stays below 0.6 θ for ≥ 300 ms, so short pauses between words don't cut speech. Merge open regions less than 400 ms apart.
4. **Padding:** extend each open region 150 ms earlier (lips move before sound starts) and 250 ms later (trailing consonants).
5. **Apply to audio:** trim the clip to the first and last open region, and zero any closed gap longer than 600 ms inside it. Don't cut and splice, so audio timestamps stay valid for the labelling job.
6. **Decide:**
   - No open region at all → skip Whisper; HUD shows "Didn't catch that".
   - Mouth active but energy VAD fires on < 20% of the open frames → you were mouthing silently; skip Whisper; HUD shows "No sound — use Silent dictate?".
   - Otherwise send the gated audio to WhisperKit.
7. **Fallback:** if the face is tracked in < 80% of the clip's frames (phone knocked, you looked away), bypass the gate, use the energy VAD alone, and log `gate_bypassed`.

Log per session: seconds of audio gated out, whether the gate was bypassed, gate time. Budget: < 10 ms per clip.

### Models

| Setting | WhisperKit model | Approx. size | Use |
| --- | --- | --- | --- |
| Fast (default) | `openai_whisper-small.en` | \~250 MB | Short dictation, any Apple silicon Mac |
| Accurate | `openai_whisper-large-v3-v20240930_turbo` | \~600 MB+ | Better on whispers and names; M2 or newer recommended |

Download on first use to `Application Support/TacitType/models` with a progress bar. Call `prewarmModels()` at launch and keep the pipeline in memory. Both model ids were checked against `argmaxinc/whisperkit-coreml` on Nov 15, 2026, with WhisperKit 1.1.1.

### Latency budget (key up → text inserted)

| Stage | Budget |
| --- | --- |
| Tail + `stop` + last batches arrive | 350 ms |
| Pre-process + VAD + mouth gate | 20 ms |
| Whisper transcribe (≤ 10 s clip, small.en) | 700 ms |
| Cleanup (no LLM) | 5 ms |
| Insert | 50 ms |
| **Total** | **≈ 1.1 s (target < 1.5 s)** |

Incremental transcription while the key is held is a v1.1 improvement. Design `DictationPipeline` so it can accept a growing buffer later.

### Whisper vs aloud

Measure: if the mouth gate is open and peak RMS before normalisation is under −30 dBFS, tag the session `speechStyle = whisper`. No separate mode or hotkey: the same hotkey handles both.

### Auto-labelling job (optional quality check for Step 3)

A "Label sessions" button in Settings → Data runs WhisperKit with `wordTimestamps: true` over every `aloud` / `whisper` session lacking `transcript.json`. It writes `{ text, words: [{ w, start, end, p }], model, createdAt }`, with times relative to `firstAudioTs`. If `promptText` exists, also store the word error rate between the transcript and the prompt. Takes with WER > 0.3 get flagged so bad reads don't pollute training.

### Dictation details settled in M4

- WhisperKit is pinned to 1.1.1. KeyboardShortcuts is pinned to 2.4.0, because 3.x needs Swift 6.2 tools and so Xcode 26.
- The model loads at launch only when it is already on disk. Otherwise it downloads on the first dictation, with progress in the HUD, or from Settings → Dictation.
- The default gate threshold θ is 1.0 blendshape units per second. ARKit jitter on a still face scores about 0.2 to 0.4, and speech scores 2 to 8. Once accepted neutral takes exist, θ comes from them and Diagnostics shows which one is in use.
- Audio starts about 420 ms before the TrueDepth camera does. If the mouth is already moving within 100 ms of the first tracked frame, the first open region reaches back to the start of the audio, so a word spoken right at key down is kept.
- The label job normalises the audio the same way dictation does and skips the WER flag on the sync check take. A take more than 0.3 WER from its prompt gets `transcript_mismatch` and `quality.ok = false`.
- When "Save sessions for training" is on, a dictation is saved with mode `dictate`, its tagged speech style, and a `transcript.json` holding Whisper's raw text with no word timings. The label job leaves it alone because it already has a transcript.
- Dictate is a toggle, not push-to-talk. The first press starts capture and the second press stops it, so the latency budget runs from the second press. A second press within 250 ms of the first cancels. If the iPhone hits its 120 s safety timeout first, the next press still transcribes what was captured. Silent dictate works the same way from M5.
- Silent dictate (⌃⌥S) is registered now and shows "Silent dictation arrives in M5" in the HUD.
- The paste fallback marks the pasteboard with `org.nspasteboard.TransientType` so clipboard managers skip the dictated text. It restores the old contents only if nothing else wrote to the pasteboard in those 150 ms.
- AX insertion counts as failed when the focused element's value is readable and did not change. Slack, VS Code, Discord and Notion start on the paste override list.
- The `FoundationModels` punctuation polish is written behind `#if canImport(FoundationModels)`. It only compiles with the macOS 26 SDK and has not run yet. The polished text is used only if its words match Whisper's exactly.
- `make run-signed` signs the Debug build with the team in `Config/Signing.local.xcconfig`. macOS keeps the Accessibility grant across rebuilds only for a stable signature, so use it instead of `make run` when testing dictation.
- Diagnostics shows stop press → inserted p50 and p95 against the M4 budgets, a per-stage breakdown of the last dictation, and a button that runs Whisper with and without the gate on the newest 20 accepted aloud and whisper Recorder takes.

## Step 3 — Silent dictation (video lip-reading)

Step 3 turns silently mouthed sentences into text. It fine-tunes a pretrained open-source lip-reading model (USR 2.0, with Auto-AVSR as the fallback) on mouth video of the user, then cleans its guesses with an on-device LLM. Face ID data is still recorded in every session but the v1 model doesn't use it; it's kept for a v2 low-light model.

### Why video, not Face ID data

Pretrained lip-reading models read mouth video, and training from scratch needs hundreds of hours: Auto-AVSR scores 93% word error rate (WER) when trained on 23 h and 20.3% on 3,291 h. ARKit's 52 values also miss teeth and most tongue positions, which carry speech information; one 2025 study scored 66.4% WER from lip landmarks alone versus 17.3% from video. The trade-off: video needs light, so v1 doesn't work in the dark.

### Pretrained models

- **Primary: [USR 2.0](https://github.com/ahaliassos/usr2)** (ICLR 2026, MIT code). Released visual-speech checkpoints: Huge 17.6% WER, Large 21.5%, Base+ 24.8% (the repo's VSR column; it doesn't name the test set). Start with **Large**; try **Huge** if Phase A shows it's clearly better and its latency fits. Its own preprocessing finds the mouth with MediaPipe face landmarks.
- **Fallback: [Auto-AVSR](https://github.com/mpc001/auto_avsr)** (Apache 2.0 code). Checkpoint `vsr_trlrs2lrs3vox2avsp_base.pth` (visual-only, 250M params, 20.3% WER on LRS3). The most mature repo and docs; use it if USR 2.0 loses Phase A, won't fine-tune cleanly, or is too slow.
- Vendor both as git submodules at `ml/third_party/usr2` and `ml/third_party/auto_avsr`, each pinned to one commit. `silentml` wraps them behind one interface (`load(name)`, `preprocess(session)`, `nbest(clip)`, `finetune(...)`), so the rest of the pipeline doesn't care which model runs.
- Reuse each model's own preprocessing code for mouth alignment and cropping. Don't reimplement it: a crop that differs from what a model was trained on costs accuracy with no visible error. The two models may want different crops, which is why the iPhone sends a loose 192×192 crop and the final crop happens in Python.
- **Licence:** both repos' code is permissive (MIT, Apache 2.0). The weights come from research datasets (LRS2, LRS3, VoxCeleb2, AVSpeech) with their own terms. Fine for personal use and a demo video; review before charging money.

### Model preprocessing (checked Nov 14, 2026)

USR 2.0 reuses Auto-AVSR's mouth cropping code, so both models expect the same input. Numbers come from [USR 2.0 `preprocessing/extract_mouths.py`](https://github.com/ahaliassos/usr2/blob/main/preprocessing/extract_mouths.py), its [`conf/data`](https://github.com/ahaliassos/usr2/tree/main/conf/data) configs, and Auto-AVSR's [`video_process.py`](https://github.com/mpc001/auto_avsr/blob/main/preparation/detectors/retinaface/video_process.py) and [`transforms.py`](https://github.com/mpc001/auto_avsr/blob/main/datamodule/transforms.py).

| Stage | Both models |
| --- | --- |
| Landmarks | 68-point iBUG layout per frame. Missing frames are interpolated, then smoothed over a 12-frame window |
| Alignment | Affine warp to `20words_mean_face.npy` in a 256×256 frame, fitted on points 28, 33, 36, 39, 42, 45, 48, 54 (Auto-AVSR's MediaPipe path uses eye centres, nose tip and mouth centre instead) |
| Crop | 96×96 around the mouth centre (mean of points 48–67) |
| Model input | Centre crop 88×88 at test time, random 88×88 crop in training |
| Pixels | Grayscale, divided by 255, then mean 0.421, std 0.165 |
| Frame rate | 25 fps |

What this means for Tacit Type:

- In the reference face the mouth is 45 px wide, so the 96 px crop spans about 2.1 mouth widths. The iPhone crop puts 64 px across the mouth (3 × mouth width in 192 px). That leaves enough resolution, plus room for the alignment rotation.
- Don't run the models' MediaPipe or RetinaFace detectors on the iPhone crop. The eyes sit about 1.4 mouth widths above the mouth centre, right at the crop's edge, so detection would be unreliable. Instead, `silentml.preprocess` maps the `mouth.bin` landmarks onto the 68-point indices above and passes them in. Auto-AVSR's `AVSRDataLoader.load_data` already accepts precomputed landmarks.
- ARKit mesh points don't sit exactly where the iBUG annotations do. Phase A's side-by-side crop check is how to catch a systematic shift. If one shows up, fit a fixed correction from the 12 ARKit points to the mean face once.
- USR 2.0 decodes with beam 40 and CTC weight 0.1 by default. Phase C's beam of 10–20 trades accuracy for latency, so measure both in Phase A.

| Set | Amount | Your time | Purpose |
| --- | --- | --- | --- |
| Aloud sentences | 1,000 prompts (\~1 h of speech) | \~3 h | Fine-tuning; easier target the model already knows |
| Silent sentences | The same 1,000 prompts, mouthed | \~3 h | Fine-tuning on the real task |
| Test set | 100 everyday prompts, silent, in their own sitting | \~20 min | Never trained on; the honest score |
| Baseline | 50 aloud + 50 silent | \~30 min | Phase A go/no-go |

**Prompt corpus** (`ml/prompts/`): the 720 Harvard sentences plus \~1,300 everyday message-style sentences, 4–15 words each ("running ten minutes late", "sounds good, ship it"). Generate the everyday list once with an LLM, review it by hand, and commit it. Start with 1,000 prompts each way; grow to 2,000 if WER is still dropping.

**Sittings:** 8–10 sittings of 30–40 minutes on different days, light and phone positions. Validation and test always hold out whole sittings.

**Labels:** the prompt text itself, normalised to the model's tokenizer (lowercase, punctuation stripped). No word timings needed. Drop takes the Step 1 quality checks flag; optionally drop aloud takes whose Whisper transcript is > 0.3 WER from the prompt (misreads).

### Phase A — Zero-shot baseline (go/no-go)

1. Record the 50 + 50 baseline takes in one sitting.
2. Run both pretrained models unmodified on them: USR 2.0 Large (and Huge if it fits in memory) and Auto-AVSR.
3. For each, report WER and character error rate (CER) for aloud and silent separately, plus processing time per second of video on the Mac. Save 20 crops next to samples of that model's expected input.
4. Pick the model with the lowest silent WER whose latency fits the 2.5 s target, and record the choice and numbers in `runs/baseline/metrics.json`. Ties go to USR 2.0.

If silent WER is above \~90%, fix preprocessing (crop size, alignment, frame rate, brightness) before recording more data. A broken crop looks like a bad model.

### Phase B — Fine-tune

- Start from the checkpoint; fine-tune the whole model with AdamW, lr 1e-4 with 500-step warm-up (start lower than the chosen repo's default because the dataset is tiny). Freeze the visual front-end for the first 2 epochs.
- Sample silent takes 2× as often as aloud.
- Augmentation: the chosen repo's defaults. Auto-AVSR's are a random 88×88 crop and time masking, with no horizontal flip. Check USR 2.0's training transforms when vendoring it, since its repo only shows the test pipeline.
- Validation: 2 held-out sittings; early stop on **silent** validation WER.
- Compute: one rented GPU with ≥ 40 GB memory (A100/H100 class). Estimated 1–3 h per run and a few dollars; measure on the first run. Training on the Mac is possible but slow and may not fit in memory.
- CLI: `python -m silentml.finetune --data <sessions dir> --init <checkpoint> --out runs/<name>`; every run writes `config.json` and `metrics.json`.

### Phase C — Decoding and LLM cleanup

1. The model's beam search (beam 10–20) returns the top 5 hypotheses with scores.
2. The on-device LLM (Apple `FoundationModels`, macOS 26+) gets the 5 guesses, the name of the focused app, and a note that p/b/m, f/v and t/d/n look identical on the lips. It returns the most likely sentence.
3. 800 ms timeout; on timeout or without macOS 26, use the top hypothesis. No cloud LLM in v1.

### Running it on the Mac (v1)

- **Python sidecar** `python -m silentml.serve`: loads the model once on Apple's GPU (MPS), listens on a Unix socket in `Application Support/TacitType`, and returns the n-best list as JSON for a given session. The Mac app's `ModelSidecar` starts it with `Process`, health-checks it, and restarts it on crash. This makes v1 developer-only (it needs a Python environment); a Core ML or MLX port is v2.
- `SilentDictationPipeline`: trim the clip with `MouthActivity` (Step 2's gate), preprocess, call the sidecar, run LLM cleanup, insert with `TextInserter`.
- If the mouth gate is open and the audio is clearly voiced (energy VAD on > 50% of open frames), the user spoke out loud: route the clip to `DictationPipeline` instead.
- Latency target: release → text ≤ 2.5 s for a 5 s utterance. Measure it in Phase A; optimise later (smaller checkpoint, Core ML, int8).

### Face ID data (kept for v2)

Every session keeps `face.bin`. v1 uses it only for `MouthActivity`. Planned v2: feed the ARKit values to the model as a second input for low light and jaw/lip-rounding cues, and evaluate ARKit's raw depth map (`capturedDepthData`, which arrives at a lower rate than video).

### Metrics

Per run: WER and CER for aloud and silent, per held-out sitting. On the 100-prompt test set, also score "correct in meaning after LLM cleanup" by hand (yes/no). Track every run in `runs/<name>/metrics.json` so the effect of more data is visible.

## Milestones and acceptance criteria

Build in this order; each milestone ends with its checks passing. Hand Claude Code one milestone at a time.

**M0 — Skeleton**

- [ ] Workspace, `TacitKit` package, both app targets build; CI runs `swift test` and `pytest`
- [ ] Message codecs round-trip every message type (unit tests, including a 6-frame `faceBatch`)

**M1 — Connect** (Pairing, discovery and transport)

- [ ] Mac lists the iPhone within 3 s of the iPhone app opening, both on shared Wi-Fi and with the two devices on different networks (peer-to-peer via AWDL)
- [ ] Pairing with a 6-digit code; reconnects automatically after an app relaunch with no code
- [ ] Unpaired Mac is rejected; "Forget device" works on both sides

**M2 — Capture** (iOS app, Step 1 data path)

- [x] `start` → first face frame < 450 ms (p95 over 20 tries)
- [x] 60 s session: measured fps ≥ 58, dropped frames < 1%, no audio gaps
- [x] Camera indicator is off whenever the iPhone app isn't capturing
- [x] Lip vertex indices chosen, reviewed on screen, hardcoded

**M3 — Recorder** (Step 1)

- [ ] Session folders written as specced; Python loader reads them; Swift↔Python fixture test passes
- [ ] Sync check reports |lag| < 20 ms on 5 consecutive runs
- [ ] Recorder runs all five blocks with keyboard-only flow and quality flags

**M3b — Mouth video** (added after M3 for Step 3)

- [ ] iPhone sends 192×192 grayscale mouth crops at 25 fps with landmarks; < 2% dropped; face frames still ≥ 58 fps
- [ ] Sessions include `mouth.mp4` + `mouth.bin`; the Python loader returns mouth frames aligned with face and audio timestamps
- [ ] Sync check shows video within 20 ms of audio (measured from `mouth.bin` timestamps, so it is finer than one 40 ms frame)
- [ ] Recorder plays mouth crops in sync; `low_light` flag fires in a dim room

**M4 — Dictation** (Step 2)

- [ ] Press the hotkey, whisper a sentence, press it again: text appears in TextEdit, Notes, Slack, VS Code and Chrome
- [ ] Stop press → inserted p50 < 1.1 s, p95 < 1.5 s (small.en, M1 or newer)
- [ ] Pasteboard contents are restored after paste fallback
- [ ] Label job writes `transcript.json` for all aloud and whisper takes
- [ ] Mouth gate: dictating with your mouth closed while someone talks next to you inserts nothing, 10 of 10 tries
- [ ] Mouth gate doesn't hurt accuracy: on 20 recorded test takes (aloud + whisper), word error rate with the gate is no more than 1 point worse than without it

**M5 — Silent dictation** (Step 3)

- [ ] Phase A: USR 2.0 and Auto-AVSR WER, CER and latency on 50 aloud + 50 silent takes recorded in `runs/baseline/metrics.json`
- [ ] Mouth crops checked side by side against the model's expected input
- [ ] ≥ 1,000 aloud + 1,000 silent sentence takes across ≥ 8 sittings, plus the 100-prompt test set
- [ ] Fine-tuned model beats the baseline's silent WER on 2 held-out sittings
- [ ] Python sidecar starts with the Mac app and survives a crash/restart
- [ ] Press ⌃⌥S, mouth a sentence, press it again: text appears in the focused app ≤ 2.5 s later
- [ ] Test set: ≥ 7 of 10 everyday phrases correct in meaning after LLM cleanup

**M6 — Demo-ready**

- [ ] Onboarding: permissions, pairing, Shortcuts automation, neutral calibration, sidecar setup check
- [ ] Demo: in normal room light, silently dictate 5 everyday messages into Slack; at least 4 land correct in meaning

## Risks and open questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Silent mouthing differs from aloud speech | The pretrained model (trained on aloud video) does worse on silent takes | Silent takes sampled 2×; silent WER tracked separately; LLM cleanup |
| Preprocessing differs from the pretrained model's | Large accuracy loss with no visible error | Reuse each model's own preprocessing code; side-by-side crop check in M5 |
| Low light | Video model fails | `low_light` flag + HUD warning; Face ID fusion in v2 |
| Too little personal data to move WER | Fine-tuning plateaus | Grow the corpus to 2,000 each way; freeze more layers; LLM cleanup carries short phrases |
| Pretrained weights' licence | v1 can't be sold as-is | Personal and demo use only until the dataset terms are reviewed or a model is retrained |
| Python sidecar | Not shippable to normal users | Fine for v1; Core ML or MLX port in v2 |
| The iPhone app must be in the foreground | Feels less seamless than Continuity Camera | Dock mode + Shortcuts automation on charger; clear "Open Tacit Type" HUD message |
| AX insertion fails in some apps | Text doesn't appear | Paste fallback + per-app override list |
| Thermal throttling (camera + charging + JPEG encoding) | Frame drops | Cooled MagSafe stand; thermal state in `status`; push-to-talk keeps sessions short |
| Privacy: camera + mic stream | Trust | Camera only on during capture, TLS, all local, sessions saved only when the user opts in |

**Open questions**

- Name is **Tacit Type** for both apps. Before any public demo, secure the domain, the App Store name and the X/GitHub handle.
- Licence terms of the pretrained weights, if Tacit Type is ever sold.
- Minimum iPhone model: confirm 60 fps face tracking plus mouth cropping on the oldest TrueDepth device you own.
