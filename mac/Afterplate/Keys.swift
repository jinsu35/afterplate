import Foundation
import Security

/// API keys the person brings, kept in the macOS Keychain (service
/// "Afterplate"), set from Settings (⌘,). The older `defaults write` keys
/// and environment variables still work when the Keychain has none.
enum Keys {
    enum Vendor: String { case openAI = "openai", xai = "xai", anthropic = "anthropic", google = "google" }

    private static var service: String { AppData.apart("Afterplate") }

    /// What the Keychain gave, once per launch. Every read used to go to the
    /// Keychain, and some screens check for a key every second: when an item
    /// was made by another build of the app (a different signature), macOS
    /// asked for the login password on every one of those reads, and the
    /// prompt held the main thread, so the photo scan stood still. `nil`
    /// inside means "looked, none there".
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [Vendor: String?] = [:]

    static func get(_ vendor: Vendor) -> String? {
        lock.lock()
        if let cached = known[vendor] { lock.unlock(); return cached }
        lock.unlock()
        let key = read(vendor)
        lock.lock(); known[vendor] = .some(key); lock.unlock()
        return key
    }

    private static func read(_ vendor: Vendor) -> String? {
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
        lock.lock(); known[vendor] = .some(trimmed.isEmpty ? nil : trimmed); lock.unlock()
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
