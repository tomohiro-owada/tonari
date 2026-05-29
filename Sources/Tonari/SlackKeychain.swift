import Foundation
import Security

/// Stores Slack credentials (token + d cookie) in Tonari's own Keychain entries
/// under service "app.tonari". One Keychain access prompt the first time, then
/// macOS caches the authorization for this app's bundle id.
struct SlackKeychain {
    static let service = "app.tonari"
    static let tokenAccount = "slack-token"
    static let cookieAccount = "slack-cookie-d"

    enum KCError: LocalizedError {
        case osStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .osStatus(let s): return "Keychain error: \(s)"
            }
        }
    }

    static func save(creds: SlackCredentials) throws {
        try saveItem(account: tokenAccount, value: creds.token)
        try saveItem(account: cookieAccount, value: creds.cookieD)
    }

    static func load() -> SlackCredentials? {
        guard let t = loadItem(account: tokenAccount),
              let c = loadItem(account: cookieAccount) else { return nil }
        return SlackCredentials(token: t, cookieD: c)
    }

    static func clear() {
        deleteItem(account: tokenAccount)
        deleteItem(account: cookieAccount)
    }

    // MARK: - Internal

    private static func saveItem(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KCError.osStatus(errSecParam)
        }
        deleteItem(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { throw KCError.osStatus(status) }
    }

    private static func loadItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteItem(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
