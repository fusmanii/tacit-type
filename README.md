# Tacit Type

Tacit Type is a macOS menu bar app that turns a docked iPhone into a face and audio sensor. The iPhone app ships under the same name. Together they type whispered speech and run silently mouthed commands. Everything runs locally.

The full design lives in [docs/SPEC.md](docs/SPEC.md).

## Layout

```
Packages/TacitKit/  Shared Swift package with the wire protocol, models and features
Apps/TacitType-macOS/   Menu bar app
Apps/TacitType-iOS/     iPhone app
ml/                 Python dataset loader, training and Core ML export
project.yml         XcodeGen spec for TacitType.xcodeproj
```

## Getting started

You need Xcode 16 or newer, XcodeGen and Python 3.11 or newer.

```bash
brew install xcodegen
```

```bash
make open
```

To build and launch the Mac app without opening Xcode, run `make run`. It uses ad-hoc signing, so no Apple team is needed.

The Xcode project is generated from `project.yml` and is not checked in. Run `make generate` after you add files or change targets.

## Tests

```bash
make ml-env
```

```bash
make test
```

`make test` runs the TacitKit Swift tests and the Python tests. `make build` builds both apps without code signing. CI runs the same steps.

## Signing

Set your team in Xcode under Signing & Capabilities for both targets. Tacit Type ships as a Developer ID build with hardened runtime and no App Sandbox, because it needs Accessibility and synthetic key events.
