import Foundation
import Security

/// API keys the person brings, kept in the macOS Keychain (service
/// "Afterplate"), set from Settings (⌘,). The older `defaults write` keys
/// and environment variables still work when the Keychain has none.
enum Keys {
    enum Vendor: String { case openAI = "openai", xai = "xai", anthropic = "anthropic", google = "google" }

    private static var service: String { AppData.apart("Afterplate") }

    static func get(_ vendor: Vendor) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Empty removes it.
    static func set(_ key: String, for vendor: Vendor) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
