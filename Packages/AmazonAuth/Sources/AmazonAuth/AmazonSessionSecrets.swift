import Foundation

/// The secret we persist: the captured session cookies.
///
/// Stored in the Keychain as **JSON** (see `KeychainAmazonSecretStore`) rather
/// than an opaque archive, so the item is:
///   - auditable by eye (security review), and
///   - readable by other tools / scripts that want to reuse the session, e.g.
///     `security find-generic-password -s io.respawn.AmazonOrderExport -w | jq`.
///
/// Security note for auditors: these cookies ARE the bearer credential for the
/// user's Amazon account. They live only in the Keychain and are never logged.
public final class AmazonSessionSecrets: @unchecked Sendable {
    public let cookies: [HTTPCookie]

    public init(cookies: [HTTPCookie]) {
        self.cookies = cookies
    }

    /// On-the-wire (and on-Keychain) JSON shape for one cookie. We keep only what's
    /// needed to replay the cookie in a request; httpOnly is irrelevant for sending.
    private struct Wire: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expiresAt: Double?
    }

    public func encoded() throws -> Data {
        let wire = cookies.map { c in
            Wire(
                name: c.name, value: c.value, domain: c.domain, path: c.path,
                secure: c.isSecure, expiresAt: c.expiresDate?.timeIntervalSince1970)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(wire)
    }

    public static func decoded(from data: Data) throws -> AmazonSessionSecrets {
        let wire = try JSONDecoder().decode([Wire].self, from: data)
        let cookies = wire.compactMap { w -> HTTPCookie? in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: w.name, .value: w.value, .domain: w.domain, .path: w.path,
            ]
            if w.secure { props[.secure] = "TRUE" }
            if let expiresAt = w.expiresAt {
                props[.expires] = Date(timeIntervalSince1970: expiresAt)
            }
            return HTTPCookie(properties: props)
        }
        return AmazonSessionSecrets(cookies: cookies)
    }
}
