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

    /// Writes refreshed token fields back into Claude Code's shared item without
    /// disturbing anything else. We re-read the live JSON and patch only the three
    /// fields a refresh rotates — so every other key Claude Code stores (scopes,
    /// subscriptionType, and any field this struct doesn't model or that Anthropic
    /// adds later) survives untouched. Encoding our narrow struct instead would
    /// silently drop those keys on every refresh and corrupt Claude Code's item.
    static func writeCredentials(_ creds: OAuthCredentials) throws {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        guard readStatus != errSecItemNotFound else { throw KeychainError.notFound }
        guard readStatus == errSecSuccess else { throw KeychainError.osStatus(readStatus) }
        guard let data = item as? Data,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { throw KeychainError.unexpectedData }

        // Patch only the fields a token refresh changes; leave the rest verbatim.
        oauth["accessToken"] = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"] = creds.expiresAt
        root["claudeAiOauth"] = oauth

        let updated = try JSONSerialization.data(withJSONObject: root)
        let writeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: updated]
        let status = SecItemUpdate(writeQuery as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }
}
