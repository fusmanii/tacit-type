# Tacit Type

Tacit Type is a macOS menu bar app that uses a docked iPhone as a face, mouth and audio sensor. The iPhone app has the same name. Together they type text into the focused Mac app. Everything runs locally.

Tacit Type has two dictation modes.

| Mode | Default hotkey | What it does |
| --- | --- | --- |
| Dictate | ⌃⌥Space | Types what you say aloud or whisper. WhisperKit reads the iPhone microphone audio. |
| Silent dictate | ⌃⌥S | Types any sentence that you mouth with no sound. A lip-reading model reads the mouth video from the iPhone. |

Press the hotkey one time to start. Press it again to stop. The text then appears in the focused app.

Silent dictation is free-form lip reading. It is not a fixed set of commands. The Auto-AVSR model reads whole sentences from the mouth video and returns its 5 best guesses. On macOS 26 or newer, the on-device Apple language model picks the most likely sentence from those guesses. If the app hears your voice in silent mode, Whisper types the text.

Silent dictation uses the pretrained model today. On the first test sitting, it got about 62% of silent words wrong. The next work is to record personal data and fine-tune the model on it. The full design and the scores are in [docs/SPEC.md](docs/SPEC.md).

## Layout

```
Packages/TacitKit/      Shared Swift package with the wire protocol, models and features
Apps/TacitType-macOS/   Menu bar app, Recorder and dictation pipelines
Apps/TacitType-iOS/     iPhone app
ml/                     Python package silentml: session loader, lip-reading models, scoring and the sidecar
ml/third_party/         The two lip-reading model repos, as pinned git submodules
project.yml             XcodeGen spec for TacitType.xcodeproj
```

## Requirements

- A Mac with Apple silicon and macOS 15 or newer. The LLM cleanup needs macOS 26 or newer.
- An iPhone with Face ID and iOS 18 or newer.
- Xcode 16 or newer and XcodeGen.
- Python 3.14 for the lip-reading environment. Python 3.15 does not work yet, because some packages have no prebuilt wheels for it.

```bash
brew install xcodegen python@3.14
```

## Getting started

1. Open the workspace in Xcode.

```bash
make open
```

2. Build the Python environment and fetch the model submodules.

```bash
make ml-env
```

3. Download the lip-reading checkpoints.

```bash
make ml-models
```

4. Build and launch the Mac app, signed with your team.

```bash
make run-signed
```

5. Connect your iPhone. Unlock it. Then build and install the iPhone app.

```bash
make run-ios
```

The Mac app starts the lip-reading sidecar (`python -m silentml.serve`) from `ml/.venv`. If `ml/.venv` does not have `torch`, silent dictation is not available. To repair it, delete `ml/.venv` and run `make ml-env` again.

`make run` builds the Mac app with ad hoc signing, so no Apple team is necessary. But macOS then removes the Accessibility permission after each build. `make run-signed` and `make run-ios` read your team from `Config/Signing.local.xcconfig`.

The Xcode project is generated from `project.yml` and is not checked in. Run `make generate` after you add files or change targets.

## Tests

```bash
make test
```

`make test` runs the TacitKit Swift tests and the Python tests. `make build` builds both apps without code signing. CI runs the same steps.

## Signing

Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`. Then set your team in it. Tacit Type is a Developer ID build with hardened runtime and no App Sandbox, because it needs Accessibility and synthetic key events.
