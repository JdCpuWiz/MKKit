import Foundation
import Security

// Wrapper around the iOS/tvOS Keychain Services API. Stores the long-lived
// device JWT, the JWT-paired profileId, the deviceId, and the user-selected
// profileId. All four are written under a single bootstrapped service so
// that a sign-out / re-pair from the Profile tab is a single delete-by-
// account loop (clearAll).
//
// kSecClassGenericPassword is the right class — there's nothing certificate-y
// about a JWT. kSecAttrAccessibleAfterFirstUnlock means the token is
// readable after the device unlocks once post-boot, which on tvOS effectively
// means "always after boot completes" and on iOS keeps us pollable while
// screen-locked (the audio background mode keeps us running there during
// playback). That's the right default for a background-pollable client.
//
// IMPORTANT — call `Keychain.configure(service:keyPrefix:)` once from the
// app's @main init BEFORE any read/write. The placeholder defaults will
// silently keep credentials in a sentinel "_unconfigured" namespace until
// configure() runs, so a missed bootstrap = mysterious "I keep landing on
// the pair screen" symptoms. Both apps assert-on-launch in DEBUG to catch
// this in dev.

public enum KeychainKey: String, Sendable {
    case deviceJwt
    case profileId
    case deviceId
    /// User-selected profile id from the on-launch profile picker. May
    /// differ from `.profileId` (the JWT-paired profile) when the user
    /// switches via the Profile tab. Nil/missing means "use .profileId".
    case selectedProfileId
}

public enum Keychain {
    // Bootstrapped via configure(). Placeholders mean configure was never
    // called — read/write will land in a sentinel namespace that flushes
    // on app delete (no data loss risk, but no persistence either).
    private static var service: String = "_unconfigured"
    private static var keyPrefix: String = "_unconfigured"

    /// Bootstrap before any read/write. Call once from the app's @main
    /// init. `service` is the kSecAttrService value — typically the app's
    /// bundle identifier (e.g. "com.zoo-tv.app", "com.zoo-tv-ios.app").
    /// `keyPrefix` namespaces the kSecAttrAccount values so a side-by-side
    /// install on the same iPad doesn't cross-stomp (e.g. "zoo-tv" vs
    /// "zoo-tv-ios").
    public static func configure(service: String, keyPrefix: String) {
        Self.service = service
        Self.keyPrefix = keyPrefix
    }

    private static func account(for key: KeychainKey) -> String {
        "\(keyPrefix).\(key.rawValue)"
    }

    public static func write(_ key: KeychainKey, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account(for: key),
        ]
        // Replace existing entry (delete then add). kSecAttrSynchronizable
        // defaults to false on both iOS and tvOS so credentials don't
        // travel through iCloud Keychain by accident.
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public static func read(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account(for: key),
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account(for: key),
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func clearAll() {
        delete(.deviceJwt)
        delete(.profileId)
        delete(.deviceId)
        delete(.selectedProfileId)
    }
}
