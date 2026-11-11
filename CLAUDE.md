# Tacit Type

The spec is docs/SPEC.md. Work one milestone at a time in the order it lists. M0 is the skeleton that exists now.

## Commands

- `make generate` regenerates TacitType.xcodeproj from project.yml. Never edit the .xcodeproj by hand.
- `make test-swift` runs TacitKit tests. `make test-python` runs the ml tests.
- `make build` builds both apps without signing.

## Rules

- Wire and disk formats live only in Packages/TacitKit. Both apps import it.
- Anything shared with Python has a mirror in ml/silentml and a parity test. Today that is the blendshape order, the face record dtype and the version constants.
- `Constants.lipVertexIndices` and the blendshape order are frozen once Step 1 data exists. Any change bumps `featureSchemaVersion`.
- Swift 6 strict concurrency, macOS 15 and iOS 18 minimums, Apple silicon only.
