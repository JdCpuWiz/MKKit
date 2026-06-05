import SwiftUI

// Shared visual layer for the zoo-tv apps. Lifted out of each app in
// Change #115 (MKKit Phase 3) since the color tokens + AppBackground were
// byte-identical across tvOS and iOS save for a couple comment lines.
//
// What's NOT in here: FocusGlowButton (tvOS only — wraps Apple's focus
// engine with our orange-glow style) and TouchScaleButton (iOS only —
// wraps press-state with our scale-down style). They have the same intent
// ("highlight on interaction") but the underlying SwiftUI APIs and the
// design semantics are platform-specific. Forcing them into a shared
// abstraction would either over-engineer or under-serve one platform.
// Each app keeps its own button style at ZooTV/UI/FocusGlowButton.swift
// and ZooTVIOS/UI/TouchScaleButton.swift respectively.

public extension Color {
    /// Hex literal initializer — `Color(hex: 0xFF9900)`.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

public enum Theme {
    public static let bg       = Color(hex: 0x0A0A0A)
    public static let surface  = Color(hex: 0x111111)
    public static let card     = Color(hex: 0x1E1E1E)
    public static let accent   = Color(hex: 0xFF9900)
    public static let danger   = Color(hex: 0xB91C1C)
    public static let success  = Color(hex: 0x15803D)
    public static let info     = Color(hex: 0x1D4ED8)
    public static let text     = Color.white
    public static let muted    = Color.white.opacity(0.6)
    public static let dim      = Color.white.opacity(0.4)
}

/// App-wide background. Layers the brand artwork at low opacity over the
/// flat dark Theme.bg, with a top-to-bottom darken gradient so foreground
/// posters + text stay legible. Use as the OUTERMOST view in every screen
/// (sits behind everything else):
///
///   ZStack {
///       AppBackground()
///       // your content
///   }
///
/// The `zootv-background` asset lives in each consuming app's Assets.xcassets
/// — SwiftUI's `Image(_:)` fail-softs to an empty view when the asset is
/// missing, so an app that hasn't shipped the asset yet just sees
/// `Theme.bg` + the vignette without crashing or warning at runtime.
/// Drop a 1920×1080 (or smaller for iOS) brand image into
/// `Assets.xcassets/zootv-background.imageset/` to enable the watermark.
public struct AppBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            Theme.bg
            Image("zootv-background")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.55)
            // Light vignette only — keeps the brand image visible while
            // making sure focused cards / text still pop. Tuned looser
            // than streaming-app standard (which targets photo fanart) since
            // the background is a flat brand image, not a busy still.
            LinearGradient(
                colors: [Color.black.opacity(0.15), Color.black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom,
            )
        }
        .ignoresSafeArea()
    }
}
