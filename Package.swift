// swift-tools-version: 5.9
import PackageDescription

// Shared Swift package for code that the zoo-tv (tvOS) and zoo-tv-ios apps
// both consume. Lifted out of each app to eliminate the copy-paste drift
// that was already showing up by 2026-06 (MKClient had diverged 119 lines).
//
// Phase 1 (initial release, 2026-06-04): Keychain + AppState only — small,
// near-identical files where the only divergence was config strings. Both
// migrated cleanly with a `Keychain.configure(...)` bootstrap call in each
// app so the keychain account scopes stay distinct per app bundle.
//
// Follow-up phases (separate Changes): MKClient (resolve the 119-line drift
// between the two copies first), Theme color tokens + AppBackground (leave
// FocusGlowButton / TouchScaleButton in each app since they're platform-
// idiomatic, not shared logic).

let package = Package(
    name: "MKKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "MKKit", targets: ["MKKit"]),
    ],
    targets: [
        .target(
            name: "MKKit",
            path: "Sources/MKKit",
        ),
    ],
)
