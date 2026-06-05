# CLAUDE.md — MKKit

Shared Swift package consumed by `zoo-tv` (tvOS) and `zoo-tv-ios` (iOS). Pure SPM — no Xcode project, no Pods, no project.yml.

## Scope

**In** (Phase 1, 2026-06-04, Change #5):
- `Keychain` — bootstrapped at app start via `Keychain.configure(service:keyPrefix:)`. Returns to a `_unconfigured` sentinel namespace if configure isn't called — silent in prod, debug-asserts in DEBUG.
- `AppState` — `@MainActor` `ObservableObject` driving `.needsPairing` / `.needsProfilePick` / `.ready` / `.signedOut` phases. Owns the `.mkDeviceRevoked` Notification listener.
- `Notification.Name.mkDeviceRevoked` — string-keyed broadcast contract. Each app's MKClient still defines + posts an identical name; when MKClient migrates here in Phase 2, the duplicate goes.

**Out** (follow-up Changes):
- MKClient — needs a 119-line drift merge first. Lift iOS-flavored version (it's the newer, busier copy) and gate any tvOS-only branches with `#if os(tvOS)`.
- Theme — colors + `AppBackground` are shareable; `FocusGlowButton` (tvOS) and `TouchScaleButton` (iOS) stay in their respective apps as platform-idiomatic UI.

## Versioning

Tagged releases on `main`. Apps pin via `from: 0.1.0` in their `project.yml` packages section. Bump:
- patch (`0.1.0 → 0.1.1`) — bugfix, no API change
- minor (`0.1.0 → 0.2.0`) — additive API change (new public type / method)
- major (`0.x.y → 1.0.0`) — breaking API change

Both consuming apps must rebuild + ship after any MKKit version bump.

## Build / test

```bash
swift build              # builds the package
swift test               # runs tests (none yet, but the harness is ready)
```

CI / GitHub Actions not wired yet — for now, local `swift build` is the only gate.

## Drift policy

When a consuming app needs a one-line tweak to shared code, **add it in MKKit and rev a patch tag**. Resist the urge to shadow with a same-named struct in the app — the whole point of this package is to kill the copy-paste drift that bit us across MKClient and Theme by 2026-06.
