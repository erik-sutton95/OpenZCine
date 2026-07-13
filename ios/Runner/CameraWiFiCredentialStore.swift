import Foundation
import Security

/// Keychain-backed storage for camera Wi‑Fi passwords, keyed by SSID or SSID prefix.
enum CameraWiFiCredentialStore {
    private static let service = "OpenZCine.CameraWiFi"
    private static let prefixAccountMarker = "prefix:"

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            return nil
        }
        return password
    }

    private static func writePassword(_ password: String, account: String) {
        guard !account.isEmpty else { return }
        deletePassword(account: account)
        guard let data = password.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func deletePassword(account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func normalizedSSID(_ ssid: String) -> String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
