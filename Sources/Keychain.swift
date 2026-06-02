import Foundation
import Security

/// The OAuth credentials Claude Code stores in the login Keychain under the
/// generic-password service "Claude Code-credentials". The JSON is wrapped in a
/// top-level `claudeAiOauth` object.
struct OAuthCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double            // epoch milliseconds
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?
}

private struct CredentialsWrapper: Codable {
    var claudeAiOauth: OAuthCredentials
}

enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case unexpectedData
    case osStatus(OSStatus)

    var description: String {
        switch self {
        case .notFound:
            return "Not logged in. Open Claude Code and sign in on this Mac."
        case .unexpectedData:
            return "Keychain item had an unexpected format."
        case .osStatus(let s):
            let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        }
    }
}

/// Reads/writes the shared Claude Code credentials. We match on the service name
/// only (never a hardcoded account) so this works as-is on any Mac and any user.
enum Keychain {
    static let service = "Claude Code-credentials"

    static func readCredentials() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data else { throw KeychainError.unexpectedData }

        do {
            return try JSONDecoder().decode(CredentialsWrapper.self, from: data).claudeAiOauth
        } catch {
            throw KeychainError.unexpectedData
        }
    }

    /// Writes refreshed credentials back to the same item, preserving the JSON
    /// shape Claude Code expects so the two clients stay in sync.
    static func writeCredentials(_ creds: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(CredentialsWrapper(claudeAiOauth: creds))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }
}
