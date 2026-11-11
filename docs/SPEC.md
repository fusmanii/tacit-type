# Tacit Type — Spec v1

Nov 7, 2026 · @faisal

Tacit Type is a Mac menu-bar app that triggers a docked iPhone to stream TrueDepth face data and audio, then turns it into typed text: first spoken or whispered speech, then silently mouthed commands. This spec covers build steps 1–3 and is written to be handed to Claude Code.

## Scope

v1 ships three things, in order: a synced face + audio recorder, a spoken/whisper dictation mode, and a silent command classifier. Everything runs locally; no cloud calls.

| Step | Delivers | Done when |
| --- | --- | --- |
| 1. Recorder | iPhone streams ARKit face frames + mic audio to the Mac; Mac saves timestamped sessions | A 60 s session saves with < 1% dropped frames and audio/face drift < 20 ms |
| 2. Spoken / whisper mode | Hotkey → iPhone mic audio → WhisperKit on Mac → text typed into the focused app | Whispered sentence appears in the focused app < 1.5 s after release |
| 3. Silent commands | Mouth a command (no sound) → Mac recognises it from face frames → runs an action | ≥ 95% top-1 on 20 user commands, < 2% false triggers per minute of normal talking |

**Platforms:** macOS 15+ (Apple silicon only), iOS 18+ on an iPhone with TrueDepth (Face ID). Swift 6, SwiftUI, Xcode 16+.

**Out of scope for v1:** open-vocabulary silent dictation (Tier 2), Continuity Camera / webcam path, multi-user models, Windows, App Store distribution (ship as Developer ID notarised build + TestFlight for iOS), cloud sync, AirPods gestures (stub the trigger interface so it can be added later).

## Architecture

&#91;embedded content: System architecture · iPhone sensor, encrypted link, Mac pipelines\]

The iPhone app streams face frames and audio only between `start` and `stop`. Recording, dictation and command recognition all run on the Mac; model training runs offline in `ml/` and ships back as a Core ML file.

## Project layout and wire protocol

One repo, one Xcode workspace, one shared Swift package so both apps compile the exact same message definitions. Both apps ship under one name, **Tacit Type**. In code the targets are `TacitType-macOS` and `TacitType-iOS`; this spec calls them "the Mac app" and "the iPhone app".

```
tacittype/
  TacitType.xcworkspace
  Packages/TacitKit/           # Swift package, used by both apps
    Sources/TacitKit/
      Protocol/                # Message enums, binary codecs, NWProtocolFramer
      Model/                   # FaceFrame, AudioChunk, SessionManifest
      Features/                # Feature extraction (Mac + Python parity tests)
      Constants.swift          # lipVertexIndices, sample rates, protocol version
    Tests/TacitKitTests/
  Apps/TacitType-iOS/          # iOS companion app
  Apps/TacitType-macOS/        # macOS menu-bar app
  ml/                          # Python: dataset loader, training, Core ML export
    pyproject.toml
    silentml/{data,features,model,train,export}.py
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
| 0x01 | `hello` | both | JSON: deviceId, deviceName, deviceModel, appVersion, protocolVersion, capabilities |
| 0x02 | `start` | Mac → iPhone | JSON: sessionId (UUID), mode (`record` / `dictate` / `command`), streams (`face`, `audio`), promptText? |
| 0x03 | `stop` | Mac → iPhone | JSON: sessionId |
| 0x04 | `status` | iPhone → Mac | JSON: state, trackingState, faceDetected, thermalState, batteryLevel, isCharging |
| 0x05 | `clockPing` / 0x06 `clockPong` | both | JSON: t0, t1, t2 (seconds) for offset estimation |
| 0x07 | `pairRequest` | Mac → iPhone | JSON: publicKey (X25519, base64). Pairing listener only |
| 0x08 | `pairAccept` | iPhone → Mac | JSON: publicKey (X25519, base64) |
| 0x09 | `forget` | both | JSON: {}. Sender has deleted its key; receiver deletes its key too |
| 0x10 | `faceBatch` | iPhone → Mac | Binary: N face frames, layout below |
| 0x11 | `audioChunk` | iPhone → Mac | Binary: Float64 ptsOfFirstSample + Int16 PCM, 16 kHz mono |
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

**Clock sync:** on connect and every 10 s, run 5 `clockPing`/`clockPong` rounds; keep the round with the lowest RTT; offset = ((t1 − t0) + (t2 − t3)) / 2, where t3 is the Mac's receive time. Used only for latency metrics and logs. Face and audio already share the iPhone clock, so alignment between them never depends on this.

**Bandwidth budget:** face ≈ 63 KB/s + audio 32 KB/s ≈ 0.8 Mbit/s. No compression needed.

## iOS companion app (Tacit Type for iPhone)

The iPhone app is a thin sensor: it stays open on a MagSafe stand, keeps the camera off until the Mac sends `start`, then streams face frames and audio until `stop`. All processing happens on the Mac.

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
- Target: first face frame < 400 ms after `start` arrives. Log it in every session.
- Thermal: if `ProcessInfo.thermalState >= .serious`, report it in `status` (the Mac warns the user). Don't change the frame rate silently.

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
| `SessionStore` | Writes and reads the on-disk session format (Step 1) |
| `DictationPipeline` | Audio → WhisperKit → cleanup → `TextInserter` (Step 2) |
| `CommandPipeline` | Face frames → features → Core ML encoder → nearest prototype → `ActionRunner` (Step 3) |
| `TextInserter` | Puts text into the focused app |
| `ActionRunner` | Runs a command's action |
| `HUDController` | Small non-activating `NSPanel` near the menu bar showing listening / processing / result / error |

### Triggers (v1)

Push-to-talk: hold to capture, release to process. Use the `KeyboardShortcuts` Swift package (sindresorhus) for user-configurable global hotkeys with key-down and key-up callbacks.

| Mode | Default hotkey | On key down | On key up |
| --- | --- | --- | --- |
| Dictate (spoken/whisper) | hold ⌃⌥Space | send `start` with streams `[audio, face]` | keep 300 ms tail, then `stop`, run `DictationPipeline` |
| Command (silent) | hold ⌃⌥C | send `start` with streams `[face, audio]` | keep 200 ms tail, then `stop`, run `CommandPipeline` |
| Record (training) | from Recorder window | `start` with `promptText` | `stop` on button or prompt timer |

Always request both streams, even when a mode only needs one. Every real use then doubles as training data, if the user has turned on "Save sessions for training" (off by default).

If the user taps instead of holding (< 250 ms), ignore it. If the iPhone isn't connected, the HUD shows "iPhone not connected" and nothing is sent.

### Text insertion

1. Preferred: find the focused element with `AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute)` and set `kAXSelectedTextAttribute` to the text. This replaces the selection, or inserts at the caret.
2. Fallback when step 1 fails or the app ignores it (many Electron apps): snapshot `NSPasteboard.general` (all items and types), write the text, post ⌘V with `CGEvent`, wait 150 ms, restore the pasteboard.
3. Per-app override list in Settings: force paste for bundle IDs where AX insertion misbehaves.

On first run, prompt for Accessibility with `AXIsProcessTrustedWithOptions` and poll until it's granted.

### Menu and windows

- **Menu:** connection status (device name, green/grey dot), mode hotkeys, "Open Recorder…", "Commands…", "Settings…", "Quit".
- **Settings:** Devices (pair, forget), Hotkeys, Dictation (model size, cleanup on/off), Commands, Data (save sessions toggle, data folder, delete all), Diagnostics (latency stats, last 50 log lines).
- **Recorder** and **Commands** windows are specified in Steps 1 and 3.

### Logging and metrics

Use `os.Logger` with subsystem `com.tacittype` and categories `net`, `session`, `dictation`, `command`. For every session record: trigger → first face frame, trigger → first audio, key up → text inserted, dropped frame count. Show rolling p50/p95 in Diagnostics.

## Step 1 — Recorder

Step 1 makes the data engine: a Recorder window that walks the user through prompted takes and saves each one as a self-describing session folder that both Swift and Python can read.

### Session folder

```
~/Library/Application Support/TacitType/sessions/2026-11-07/<sessionId>/
  manifest.json   # metadata, below
  face.bin        # 16-byte header + FaceFrame records, same layout as the wire
  audio.wav       # 16 kHz mono PCM Int16
  transcript.json # optional, written by Step 2 / labeling job
```

- `face.bin` header: magic `SFCE` (4 bytes), UInt16 featureSchemaVersion, UInt16 lipVertexCount, UInt32 frameCount, UInt32 reserved. Records follow back to back, so Python reads them with `numpy.fromfile` and a structured dtype.
- `audio.wav` starts at the PTS of the first audio sample. If chunks arrive with a gap (PTS jump > 1 ms), fill the gap with zeros so sample index ↔ time stays linear, and count it in `audioGapsFilled`.

### manifest.json fields

| Field | Example | Notes |
| --- | --- | --- |
| sessionId, createdAt | UUID, ISO 8601 |  |
| mode | `record` / `dictate` / `command` | Which pipeline triggered it |
| speechStyle | `aloud` / `whisper` / `silent` / `negative` | Set by the Recorder; `dictate` defaults to `aloud`, `command` to `silent` |
| promptId, promptText | `harvard-03-07`, "The birch canoe…" | null outside the Recorder |
| commandId | `send` | Only for command takes |
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
| Sync check | "pa pa pa pa pa" aloud | 1 per Recorder launch | Measures face/audio offset |
| Aloud sentences | Harvard sentences (720, public domain), shuffled | 50 per sitting | Future Tier 2 + labels via Whisper |
| Silent sentences | Same sentences, mouthed | 50 per sitting | Silent↔aloud domain shift |
| Commands | User's command list (Step 3) | 10 silent + 3 aloud each | Command model |
| Negatives | "Talk normally about anything", "chew", "smile", "yawn", "stay still" | 10 s each | Rejection class |

Flow per take: show the prompt large, then a 3-2-1 countdown → capture → the user presses Space to stop (or it stops on the prompt's time limit) → quality checks run → a review strip plays back. Keys: **Space** start/stop, **R** redo, **→** accept and next, **Delete** discard.

The review strip draws the audio waveform with `jawOpen` and `mouthClose` curves on the same time axis, so sync is visible at a glance.

### Quality checks

- `trackedRatio ≥ 0.95` and `measuredFps ≥ 55`, else flag `poor_tracking`.
- Aloud and whisper: speech detected by a simple energy VAD, else `no_speech`.
- Silent: audio RMS above −40 dBFS for more than 300 ms → flag `audible_in_silent` and ask "We heard you; redo silently?"
- Duration between 0.4 s and 2× the prompt's expected length.
- Sync check: cross-correlate the audio energy envelope with `jawOpen` (both resampled to 100 Hz). Report the lag; pass if |lag| < 20 ms. Store the lag in every later manifest of that sitting as `measuredAvOffsetMs`.

Flagged takes are saved with `quality.ok = false` and excluded by the Python loader by default.

### Python loader (ml/silentml/data.py)

`load_session(path) -> Session(face: np.ndarray[T, F], face_ts: np.ndarray[T], audio: np.ndarray[S], audio_t0: float, manifest: dict)` plus `iter_sessions(root, style=None, ok_only=True)`. A unit test in Swift writes a synthetic session and a pytest reads it back and checks every field, so the two sides can't drift.

## Step 2 — Spoken and whisper mode

Step 2 proves the whole loop before any ML training: hold the hotkey, speak or whisper, release, and the text lands in the focused app within 1.5 s. It also auto-labels the aloud sessions from Step 1.

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
   - Mouth active but energy VAD fires on < 20% of the open frames → you were mouthing silently; skip Whisper; HUD shows "No sound — use Command mode?".
   - Otherwise send the gated audio to WhisperKit.
7. **Fallback:** if the face is tracked in < 80% of the clip's frames (phone knocked, you looked away), bypass the gate, use the energy VAD alone, and log `gate_bypassed`.

Log per session: seconds of audio gated out, whether the gate was bypassed, gate time. Budget: < 10 ms per clip.

### Models

| Setting | WhisperKit model | Approx. size | Use |
| --- | --- | --- | --- |
| Fast (default) | `openai_whisper-small.en` | \~250 MB | Short dictation, any Apple silicon Mac |
| Accurate | `openai_whisper-large-v3-v20240930_turbo` | \~600 MB+ | Better on whispers and names; M2 or newer recommended |

Download on first use to `Application Support/TacitType/models` with a progress bar. Call `prewarmModels()` at launch and keep the pipeline in memory. Verify the exact model ids against WhisperKit's model repo at implementation time.

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

### Auto-labelling job (feeds Step 3 and Tier 2)

A "Label sessions" button in Settings → Data runs WhisperKit with `wordTimestamps: true` over every `aloud` / `whisper` session lacking `transcript.json`. It writes `{ text, words: [{ w, start, end, p }], model, createdAt }`, with times relative to `firstAudioTs`. If `promptText` exists, also store the word error rate between the transcript and the prompt. Takes with WER > 0.3 get flagged so bad reads don't pollute training.

## Step 3 — Silent command model

Step 3 recognises a silently mouthed command from face frames alone. A small encoder turns a take into a 128-d embedding; the command is the nearest enrolled prototype, or "none" if nothing is close enough. New commands need 5 takes and no retraining.

### Input features (identical in Swift and Python)

Implement once in Swift (`TacitKit/Features/FeatureExtractor.swift`) and once in Python (`silentml/features.py`), with a parity test on a fixture session: max abs difference < 1e-4.

1. **Resample** to a uniform 60 Hz grid by linear interpolation on `timestamp`. Untracked gaps ≤ 100 ms are interpolated; longer gaps are zero-filled and masked.
2. **Blendshapes (29):** `jawOpen, jawForward, jawLeft, jawRight, mouthClose, mouthFunnel, mouthPucker, mouthLeft, mouthRight, mouthSmileLeft, mouthSmileRight, mouthFrownLeft, mouthFrownRight, mouthDimpleLeft, mouthDimpleRight, mouthStretchLeft, mouthStretchRight, mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper, mouthPressLeft, mouthPressRight, mouthLowerDownLeft, mouthLowerDownRight, mouthUpperUpLeft, mouthUpperUpRight, cheekPuff, tongueOut`.
3. **Lip shape (192):** the 64 lip vertices, minus the user's neutral lip shape, divided by the neutral mouth width (corner-to-corner distance). Vertices are already in face-local space, so head pose is removed.
4. **Velocity (221):** first difference of 2 + 3, times 60 (per-second units).
5. **Normalise:** z-score each of the 442 dims with mean/std from the user's training data; store them in `normalizer.json` next to the model.
6. **Crop:** mouth-activity score (MouthActivity, shared with Step 2's gate) = L2 norm of blendshape velocity, smoothed with a 100 ms moving average. Keep from the first to the last frame above threshold, plus 100 ms padding each side. Pad or centre-crop to **T = 120** frames (2 s), with a mask.

Model input: `features [1, 120, 442]` Float32 and `mask [1, 120]`.

**Neutral face:** the mean of the "stay still" negative takes, saved as `neutral.json` per user. Re-capture it from the Commands window ("Recalibrate neutral", 3 s).

### Encoder

| Layer | Shape out | Notes |
| --- | --- | --- |
| Linear 442 → 128 + LayerNorm | \[B, 120, 128\] |  |
| 4 × residual temporal block | \[B, 120, 128\] | Depthwise conv k = 5, dilation 1/2/4/8 → pointwise 128 → GELU → LayerNorm, dropout 0.1 |
| Masked attention pooling | \[B, 128\] | Learned query, softmax over valid frames |
| Linear 128 → 128, L2-normalise | \[B, 128\] | The embedding |

About 0.3 M parameters. PyTorch 2.x in `silentml/model.py`.

### Training (offline, in ml/)

**Stage A — word pretraining (uses Step 1 sentence data).** Cut aloud and silent sentence takes into word segments using the Whisper word timestamps from Step 2 (silent takes: align by prompt order with DTW against the aloud take of the same prompt). Train with supervised contrastive loss (temperature 0.1): segments of the same word are positives. This turns a few hours of sentences into thousands of labelled examples.

**Stage B — command fine-tune.** Fine-tune on command takes (silent + aloud) with the same loss, plus negatives as their own "none" class. Weight silent takes 2×. Optimiser AdamW, lr 1e-3 (Stage A) / 3e-4 (Stage B), batch 64, early stop on validation accuracy.

**Augmentation:** time-stretch 0.8–1.2×, shift ±100 ms, Gaussian noise σ = 0.05 (in z-space), random blendshape channel dropout p = 0.1, lip-vertex rotation ±3° about the face's forward axis.

**Split:** hold out whole sittings (never takes from the same sitting in train and validation).

**CLI:** `python -m silentml.train --data <sessions dir> --stage a|b --out runs/<name>`, then `python -m silentml.export runs/<name>` → `CommandEncoder.mlpackage` (coremltools, ML Program, FP16, fixed input shapes) + `normalizer.json`. Export fails unless Core ML vs PyTorch embeddings have cosine > 0.999 on 50 validation takes.

v1 training runs from the CLI by the developer. On-device training (for example with MLX Swift) is out of scope.

### Inference and rejection

- **Prototypes:** for each command, mean embedding of its enrolled silent takes (min 5, recommended 10), re-normalised. The "none" prototypes are 5 k-means centroids of the negative takes.
- **Decision:** cosine similarity to every prototype. Accept the top command only if (a) it is not a "none" centroid, (b) score ≥ τ (default 0.75, tuned per user), and (c) top − second ≥ 0.05. Otherwise the HUD shows "Not sure" with the top-2 guesses and runs nothing.
- **Tuning τ:** on held-out takes, choose the lowest τ that keeps false accepts on negatives ≤ 2%. Save it in `commands.json`.
- **Latency:** key up → action ≤ 300 ms after the tail (features + Core ML on CPU/Neural Engine should take < 20 ms).

### Commands window

- Table of commands: phrase, action, takes enrolled, last score, a "Try it" button that shows live score bars for the top 3.
- "Add command": type the phrase, pick an action, then mouth it 5–10 times (uses the Recorder flow).
- **Confusable warning:** if two prototypes have cosine > 0.85, warn ("'next' and 'yes' look alike — pick a different phrase?").
- **Action types:** keystroke (for example ⌘↩), type text, open app or URL, run a Shortcut by name (`/usr/bin/shortcuts run "<name>"`), AppleScript, built-in (start dictation, mute mic).
- Stored in `Application Support/TacitType/commands.json`: `[{ id, phrase, action, prototype: [128], takeIds, createdAt }]` + `tau` + `modelVersion`.

**Starter set (20)**, chosen for distinct mouth shapes: send, undo, copy, paste, next, back, scroll up, scroll down, new tab, close tab, play, pause, mute, volume up, volume down, screenshot, yes, no, dictate, lock.

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

- [ ] `start` → first face frame < 400 ms (p95 over 20 tries)
- [ ] 60 s session: measured fps ≥ 58, dropped frames < 1%, no audio gaps
- [ ] Camera indicator is off whenever the iPhone app isn't capturing
- [ ] Lip vertex indices chosen, reviewed on screen, hardcoded

**M3 — Recorder** (Step 1)

- [ ] Session folders written as specced; Python loader reads them; Swift↔Python fixture test passes
- [ ] Sync check reports |lag| < 20 ms on 5 consecutive runs
- [ ] Recorder runs all five blocks with keyboard-only flow and quality flags

**M4 — Dictation** (Step 2)

- [ ] Hold hotkey, whisper a sentence, release: text appears in TextEdit, Notes, Slack, VS Code and Chrome
- [ ] Key up → inserted p50 < 1.1 s, p95 < 1.5 s (small.en, M1 or newer)
- [ ] Pasteboard contents are restored after paste fallback
- [ ] Label job writes `transcript.json` for all aloud and whisper takes
- [ ] Mouth gate: holding the hotkey with your mouth closed while someone talks next to you inserts nothing, 10 of 10 tries
- [ ] Mouth gate doesn't hurt accuracy: on 20 recorded test takes (aloud + whisper), word error rate with the gate is no more than 1 point worse than without it

**M5 — Silent commands** (Step 3)

- [ ] Feature parity test Swift↔Python passes
- [ ] Stage A + B trained on ≥ 1 h of the developer's sentences and 20 commands × 13 takes
- [ ] Held-out top-1 ≥ 95%, false accepts on negatives ≤ 2%
- [ ] Key up → action ≤ 300 ms after the tail
- [ ] Adding a new command with 5 takes works without retraining

**M6 — Demo-ready**

- [ ] Onboarding: permissions, pairing, Shortcuts automation, neutral calibration, 5-minute starter enrolment
- [ ] Lights-off demo: 10 silent commands in a row in a dark room, all correct

## Risks and open questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Silent mouthing differs from aloud speech | Stage A pretraining transfers poorly | Silent takes in every block, 2× weight in Stage B; measure silent-only accuracy separately |
| The iPhone app must be in the foreground | Feels less seamless than Continuity Camera | Dock mode + Shortcuts automation on charger; clear "Open Tacit Type" HUD message |
| ARKit face-mesh topology change in a future iOS | Lip indices silently wrong | Check `ARFaceGeometry.vertexCount == 1220` at launch; refuse to capture and log if not |
| Command confusables (similar mouth shapes) | Wrong action runs | Margin rule, confusable warning at enrolment, "Not sure" instead of guessing |
| AX insertion fails in some apps | Text doesn't appear | Paste fallback + per-app override list |
| Thermal throttling during long sessions | Frame drops | Report in `status`; push-to-talk keeps sessions short |
| Privacy: camera + mic stream | Trust | Camera only on during capture, TLS, all local, sessions saved only when the user opts in |

**Open questions**

- Name is **Tacit Type** for both apps. Before any public demo, secure the domain, the App Store name and the X/GitHub handle.
- Should Command mode also accept a whispered command and route it through Whisper when the face model is "Not sure"?
- Minimum iPhone model to support: confirm 60 fps face tracking on the oldest TrueDepth device you own.
- Exact WhisperKit model ids and sizes: verify against its model repo when M4 starts.
