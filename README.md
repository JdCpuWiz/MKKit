# MKKit

Shared Swift package for code consumed by both [zoo-tv](https://github.com/JdCpuWiz/zoo-tv) (tvOS) and [zoo-tv-ios](https://github.com/JdCpuWiz/zoo-tv-ios) (iOS).

## Phase 1 (this release)

- `Keychain` — wrapper around iOS/tvOS Keychain Services for the device JWT + profile state. Bootstrap once per app with `Keychain.configure(service:keyPrefix:)`.
- `AppState` — `ObservableObject` driving the app lifecycle phases (`.needsPairing`, `.needsProfilePick`, `.ready`, `.signedOut`).
- `Notification.Name.mkDeviceRevoked` — broadcast contract between MKClient (still in each app) and AppState for token-revocation auto-recovery.

## Follow-up phases

- **MKClient** — networking + auth client. Currently duplicated with ~119 lines of drift; needs a merge pass before lifting.
- **Theme** — color tokens + `AppBackground`. Platform-divergent button styles (`FocusGlowButton` tvOS / `TouchScaleButton` iOS) stay in each app.

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
