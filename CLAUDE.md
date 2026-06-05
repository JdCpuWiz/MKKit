# CLAUDE.md — MKKit

Shared Swift package consumed by `zoo-tv` (tvOS) and `zoo-tv-ios` (iOS). Pure SPM — no Xcode project, no Pods, no project.yml.

## Scope

**In** (Phase 1, 2026-06-04, Change #5):
- `Keychain` — bootstrapped at app start via `Keychain.configure(service:keyPrefix:)`. Returns to a `_unconfigured` sentinel namespace if configure isn't called — silent in prod, debug-asserts in DEBUG.
- `AppState` — `@MainActor` `ObservableObject` driving `.needsPairing` / `.needsProfilePick` / `.ready` / `.signedOut` phases. Owns the `.mkDeviceRevoked` Notification listener.
- `Notification.Name.mkDeviceRevoked` — string-keyed broadcast contract.

**In** (Phase 2, 2026-06-04, Change #114):
- `MKClient` — Hono / media-kennel networking + auth client. Base URL hard-pinned to `https://media-kennel.deckerzoo.com` (the public Traefik FQDN — resolves to LAN at home, works off-LAN elsewhere). Merged the 119-line iOS/tvOS drift by adopting the iOS version's fractional-ISO8601 date decoder + `profileId` optional parameters + `/api/external/library/...` stream paths (bug #32 fix) for both platforms. All public types have `Sendable` conformance for Swift 6 strict concurrency.
- `MKError` — typed errors from MKClient (`badResponse`, `decodingFailed`, `noToken`, `offline`).

**In** (Phase 3, 2026-06-04, Change #115):
- `Color(hex:)` extension — hex literal initializer (`Color(hex: 0xFF9900)`).
- `Theme` — color tokens (`bg`, `surface`, `card`, `accent`, `danger`, `success`, `info`, `text`, `muted`, `dim`).
- `AppBackground` — the brand-image + dark-gradient backdrop both apps use as the outermost layer of every screen. Fail-softs to flat-bg + vignette when the `zootv-background` asset isn't in the consuming app yet (e.g., iOS hasn't shipped the asset).

**Out** (intentional, will stay out):
- `FocusGlowButton` (tvOS only) and `TouchScaleButton` (iOS only). Same intent ("highlight on interaction") but the underlying SwiftUI APIs (`@FocusState` vs `@GestureState`) and design semantics (focus traversal vs touch) are platform-specific. Forcing them into a shared abstraction would either over-engineer or under-serve one platform.

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
