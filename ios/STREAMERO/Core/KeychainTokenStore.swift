import Foundation
import Security
import StreameroCore

/// Tokens live in the Keychain (this device only, available after first unlock so background
/// playback can refresh stream URLs while the phone is locked). Never in UserDefaults or logs.
final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account = "session"

    init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> AuthTokens? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder.streamero.decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder.streamero.encode(tokens) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
