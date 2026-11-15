# Tacit Type

The spec is docs/SPEC.md. Work one milestone at a time in the order it lists. M0 to M3 are built. M3b (mouth video) and M4 (dictation) are written and their tests pass, but their acceptance checks still need a real iPhone. M5 is next.

Step 3 is silent dictation from mouth video. The old command classifier design is gone.

## Commands

- `make generate` regenerates TacitType.xcodeproj from project.yml. Never edit the .xcodeproj by hand.
- `make test-swift` runs TacitKit tests. `make test-python` runs the ml tests.
- `make build` builds both apps without signing.
- `make run-signed` builds and opens the Mac app signed with your team, so the Accessibility grant survives rebuilds.

## Rules

- Wire and disk formats live only in Packages/TacitKit. Both apps import it.
- Anything shared with Python has a mirror in ml/silentml and a parity test. Today that is the blendshape order, the face record dtype, the crop landmark order, the mouth.bin layout, the version constants, the transcript.json fields and the session folder format.
- `Constants.lipVertexIndices` and the blendshape order are frozen once Step 1 data exists. Any change bumps `featureSchemaVersion`.
- The session fixture in ml/tests/fixtures is written by the Swift tests. After a format change run `TACIT_WRITE_FIXTURE=1 make test-swift`, then update ml/tests/test_data.py.
- Swift 6 strict concurrency, macOS 15 and iOS 18 minimums, Apple silicon only.
