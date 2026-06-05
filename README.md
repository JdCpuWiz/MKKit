# MKKit

Shared Swift package for code consumed by both [zoo-tv](https://github.com/JdCpuWiz/zoo-tv) (tvOS) and [zoo-tv-ios](https://github.com/JdCpuWiz/zoo-tv-ios) (iOS).

## In MKKit

**Phase 1 (v0.1.0, 2026-06-04)**:
- `Keychain` — wrapper around iOS/tvOS Keychain Services for the device JWT + profile state. Bootstrap once per app with `Keychain.configure(service:keyPrefix:)`.
- `AppState` — `ObservableObject` driving the app lifecycle phases (`.needsPairing`, `.needsProfilePick`, `.ready`, `.signedOut`).
- `Notification.Name.mkDeviceRevoked` — broadcast contract for token-revocation auto-recovery.

**Phase 2 (v0.2.0, 2026-06-04)**:
- `MKClient` — Hono / media-kennel networking + auth client. Single base URL (`https://media-kennel.deckerzoo.com` — Traefik FQDN, resolves to LAN at home and works off-LAN). Adopts the iOS-flavored implementation: fractional-ISO8601 date decoder, optional `profileId` query parameter on all library routes, `/api/external/library/...` stream paths.
- `MKError` — typed errors from MKClient.

## Future

- **Theme color tokens + `AppBackground`** — Change #115. Platform-divergent button styles stay in each app.

## Usage

Add as an SPM dependency:

```swift
// project.yml (xcodegen)
packages:
  MKKit:
    url: https://github.com/JdCpuWiz/MKKit
    from: 0.1.0

targets:
  YourApp:
    dependencies:
      - package: MKKit
```

Then in `@main App.init`:

```swift
import MKKit

@main
struct ZooTVApp: App {
    init() {
        Keychain.configure(service: "com.zoo-tv.app", keyPrefix: "zoo-tv")
    }
}
```

Per-app config strings keep keychain account scopes distinct so side-by-side installs on the same iPad don't cross-stomp credentials.

## Platforms

- iOS 17+
- tvOS 17+
