import Foundation
import Security
import os

/// The primitive the credential store writes through.
///
/// Exists so unit tests can run against memory instead of securityd: the store's tests pin the
/// account-key scheme and lookup order, not Apple's keychain — and the real keychain is exactly
/// what made them flake, going unavailable for whole windows in parallel simulator clones and
/// failing every test in the class at once regardless of what keys they used.
protocol CameraWiFiKeychainBacking: Sendable {
    func read(service: String, account: String) -> Data?
    func write(service: String, account: String, data: Data)
    func delete(service: String, account: String)
}

/// The production backing: the same `SecItem` calls, dictionaries and accessibility attribute the
/// store has always used, so existing saved passwords keep resolving byte-identically.
struct SecItemKeychainBacking: CameraWiFiKeychainBacking {
    func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func write(service: String, account: String, data: Data) {
        delete(service: service, account: account)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain-backed storage for camera Wi‑Fi passwords, keyed by SSID or SSID prefix.
enum CameraWiFiCredentialStore {
    private static let service = "OpenZCine.CameraWiFi"
    private static let prefixAccountMarker = "prefix:"

    /// Locked rather than a bare static: the store is reached from more than one isolation
    /// domain, and the swap-in point (tests) must never race a production read.
    private static let backing = OSAllocatedUnfairLock<any CameraWiFiKeychainBacking>(
        initialState: SecItemKeychainBacking())

    /// Test seam. Production never calls this; the default backing is the keychain.
    static func setBacking(_ newBacking: any CameraWiFiKeychainBacking) {
        backing.withLock { $0 = newBacking }
    }

    static func password(forSSID ssid: String) -> String? {
        readPassword(account: normalizedSSID(ssid))
    }

    /// Returns a password saved for a Nikon AP prefix before an exact SSID is known.
    static func password(forPrefix prefix: String) -> String? {
        readPassword(account: prefixAccount(prefix))
    }

    /// Resolves a stored password for an exact SSID, then falls back to a prefix entry.
    static func password(forSSID ssid: String?, prefix: String?) -> String? {
        if let ssid, let stored = password(forSSID: ssid) {
            return stored
        }
        if let prefix, let stored = password(forPrefix: prefix) {
            return stored
        }
        return nil
    }

    static func savePassword(_ password: String, forSSID ssid: String) {
        writePassword(password, account: normalizedSSID(ssid))
    }

    static func savePassword(_ password: String, forPrefix prefix: String) {
        writePassword(password, account: prefixAccount(prefix))
    }

    static func deletePassword(forSSID ssid: String) {
        deletePassword(account: normalizedSSID(ssid))
    }

    static func deletePassword(forPrefix prefix: String) {
        deletePassword(account: prefixAccount(prefix))
    }

    private static func prefixAccount(_ prefix: String) -> String {
        prefixAccountMarker + normalizedSSID(prefix)
    }

    private static func readPassword(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        guard let data = backing.withLock({ $0.read(service: service, account: account) }),
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            return nil
        }
        return password
    }

    private static func writePassword(_ password: String, account: String) {
        guard !account.isEmpty, let data = password.data(using: .utf8) else { return }
        backing.withLock { $0.write(service: service, account: account, data: data) }
    }

    private static func deletePassword(account: String) {
        guard !account.isEmpty else { return }
        backing.withLock { $0.delete(service: service, account: account) }
    }

    private static func normalizedSSID(_ ssid: String) -> String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
