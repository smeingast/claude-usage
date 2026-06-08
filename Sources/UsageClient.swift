import Foundation

/// One rate-limit window as reported by the usage endpoint.
struct LimitWindow {
    var utilization: Double      // percent, 0…100(+)
    var resetsAt: Date?
}

/// A full snapshot of the account's current limit utilization.
struct UsageSnapshot {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var sevenDayOpus: LimitWindow?
    var sevenDaySonnet: LimitWindow?
    var fetchedAt: Date
}

enum UsageError: Error, CustomStringConvertible {
    case auth                    // 401/403 — token rejected
    case http(Int)
    case transport(String)
    case decode

    var description: String {
        switch self {
        case .auth:           return "Not authorized. Open Claude Code and sign in."
        case .http(let c):    return "Server returned HTTP \(c)."
        case .transport(let m): return "Network error: \(m)"
        case .decode:         return "Could not parse usage response."
        }
    }
}

/// Talks to the Claude usage endpoint, transparently refreshing the OAuth token
/// (via the Keychain refresh token) when it is expired or rejected.
final class UsageClient {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-cli/2.1.160 (external, cli)"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    func fetch() async throws -> UsageSnapshot {
        var creds = try Keychain.readCredentials()
        if isExpiringSoon(creds) {
            creds = try await refresh(creds)
        }
        do {
            return try await getUsage(token: creds.accessToken)
        } catch UsageError.auth {
            // Stored token was rejected — force one refresh and retry.
            creds = try await refresh(creds)
            return try await getUsage(token: creds.accessToken)
        }
    }

    // MARK: - Private

    /// True if the token expires within the next 60 seconds (or is already past).
    private func isExpiringSoon(_ creds: OAuthCredentials) -> Bool {
        let nowMs = Date().timeIntervalSince1970 * 1000
        return creds.expiresAt - nowMs < 60_000
    }

    private func getUsage(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.auth }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }

        guard let dto = try? JSONDecoder().decode(UsageDTO.self, from: data) else {
            throw UsageError.decode
        }
        return UsageSnapshot(
            fiveHour: dto.five_hour?.window,
            sevenDay: dto.seven_day?.window,
            sevenDayOpus: dto.seven_day_opus?.window,
            sevenDaySonnet: dto.seven_day_sonnet?.window,
            fetchedAt: Date()
        )
    }

    /// Exchanges the refresh token for a fresh access token and persists the
    /// rotated credentials back into the shared Keychain item.
    private func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.transport("no response") }
        // Only a genuine token rejection should raise the loud "sign in" warning.
        // 429 / 5xx are transient: surface them as .http so the menu bar stays calm
        // ("…") and we simply retry, instead of falsely claiming the user is logged out.
        switch http.statusCode {
        case 200:            break
        case 429, 500...599: throw UsageError.http(http.statusCode)
        default:             throw UsageError.auth
        }
        guard let tr = try? JSONDecoder().decode(TokenDTO.self, from: data) else {
            throw UsageError.decode
        }

        var updated = creds
        updated.accessToken = tr.access_token
        if let rt = tr.refresh_token { updated.refreshToken = rt }
        let expiresIn = tr.expires_in ?? 3600
        updated.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        // Non-fatal: the in-memory token still works this cycle. But don't swallow
        // a failure silently — if the write-back keeps failing, Claude Code is left
        // holding the now-rotated (dead) refresh token, so leave a breadcrumb.
        do {
            try Keychain.writeCredentials(updated)
        } catch {
            NSLog("ClaudeUsage: token write-back to Keychain failed: \(error)")
        }
        return updated
    }
}

// MARK: - Wire format

private struct UsageDTO: Decodable {
    let five_hour: WindowDTO?
    let seven_day: WindowDTO?
    let seven_day_opus: WindowDTO?
    let seven_day_sonnet: WindowDTO?
}

private struct WindowDTO: Decodable {
    let utilization: Double?
    let resets_at: String?

    /// Maps to a `LimitWindow`, dropping windows that carry no utilization value.
    var window: LimitWindow? {
        guard let utilization else { return nil }
        return LimitWindow(utilization: utilization, resetsAt: ISO.parse(resets_at))
    }
}

private struct TokenDTO: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
}

/// Lenient ISO-8601 parsing (the endpoint emits fractional seconds, e.g.
/// "2026-06-02T15:40:00.217970+00:00").
enum ISO {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}
