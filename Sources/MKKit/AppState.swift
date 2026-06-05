import SwiftUI
import Combine
import Foundation

// Single source of truth for "where are we in the app lifecycle". Shared
// between zoo-tv (tvOS) and zoo-tv-ios (iOS) — same lifecycle in both,
// since the auth + profile model is identical.
//
// Phases:
//   .needsPairing       — no JWT in keychain, show PairView
//   .needsProfilePick   — paired but the user hasn't picked a profile yet
//                         (or explicitly asked to switch); show picker
//   .ready              — JWT present + profileId resolved, show root
//   .signedOut          — explicit user sign-out, identical to .needsPairing
//                         but kept distinct for future copy variation
//
// `.profileId` here is the EFFECTIVE profile (selected by the user). It may
// differ from the JWT-paired profile in the keychain — the JWT-paired one
// is the auth principal, the selected one drives PlaybackProgress upserts
// and the resume rail.
//
// AppState is `@MainActor` because it mutates published state. Keychain
// reads/writes are synchronous and cheap, so they happen inline.

/// Notification posted by MKClient (lives in each app for now) when MK
/// rejects the device JWT with HTTP 401 — AppState listens here and drops
/// the keychain payload so every screen recovers at once instead of looping
/// on a 401 banner. The Notification.Name string ("mkDeviceRevoked") is the
/// contract — MKClient in each app defines the same name independently and
/// they match through NotificationCenter's string-keyed bus. When MKClient
/// migrates to MKKit in a follow-up Change, the app-side duplicate goes.
public extension Notification.Name {
    static let mkDeviceRevoked = Notification.Name("mkDeviceRevoked")
}

@MainActor
public final class AppState: ObservableObject {
    public enum Phase {
        case needsPairing
        case needsProfilePick(deviceId: String)
        case ready(profileId: String, deviceId: String)
        case signedOut
    }

    @Published public var phase: Phase

    private var cancellables = Set<AnyCancellable>()

    public init() {
        self.phase = Self.resolveInitialPhase()
        // A revoked device JWT (HTTP 401 on an authenticated call) is
        // broadcast by MKClient. Clear the keychain and return to pairing
        // so every screen / tab recovers at once instead of looping on a
        // 401 banner.
        NotificationCenter.default.publisher(for: .mkDeviceRevoked)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleRevocation() }
            .store(in: &cancellables)
    }

    private static func resolveInitialPhase() -> Phase {
        guard let jwt = Keychain.read(.deviceJwt),
              let did = Keychain.read(.deviceId),
              !jwt.isEmpty
        else {
            return .needsPairing
        }
        // If the user has already picked a profile (via the on-launch
        // picker or the Profile tab "Switch profile" button), use that.
        // Otherwise fall back to the profile baked into the JWT at pair
        // time — single-profile households never see the picker.
        if let selected = Keychain.read(.selectedProfileId), !selected.isEmpty {
            return .ready(profileId: selected, deviceId: did)
        } else if let pid = Keychain.read(.profileId), !pid.isEmpty {
            // No explicit selection yet. We'll let the router decide
            // whether to surface the picker (multi-profile household) or
            // just go straight to ready (single-profile). For now, ready
            // is the right default — the picker will assert itself only
            // if RootView's startup probe finds >1 profile.
            return .ready(profileId: pid, deviceId: did)
        } else {
            return .needsPairing
        }
    }

    public func didPair(jwt: String, profileId: String, deviceId: String) {
        Keychain.write(.deviceJwt, jwt)
        Keychain.write(.profileId, profileId)
        Keychain.write(.deviceId, deviceId)
        Keychain.delete(.selectedProfileId) // force fresh pick next launch
        // Land on ready with the JWT's profileId; RootView's probe will
        // upgrade to .needsProfilePick if there's more than one Profile.
        self.phase = .ready(profileId: profileId, deviceId: deviceId)
    }

    public func selectProfile(_ profileId: String) {
        Keychain.write(.selectedProfileId, profileId)
        guard let did = Keychain.read(.deviceId) else { return }
        self.phase = .ready(profileId: profileId, deviceId: did)
    }

    /// Called when the user taps "Switch profile" from the Profile tab. We
    /// drop only the on-disk selection (NOT the JWT or the paired profile)
    /// so the user gets the picker back without re-pairing.
    public func requestProfileSwitch() {
        Keychain.delete(.selectedProfileId)
        guard let did = Keychain.read(.deviceId) else { return }
        self.phase = .needsProfilePick(deviceId: did)
    }

    public func signOut() {
        Keychain.clearAll()
        self.phase = .signedOut
    }

    /// Token was rejected by MK (HTTP 401). Drop the keychain payload and
    /// return to the pair flow.
    public func handleRevocation() {
        Keychain.clearAll()
        self.phase = .needsPairing
    }
}
