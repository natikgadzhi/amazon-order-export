import Foundation

/// The secret we persist: the captured session cookies, nothing else.
///
/// Why a class with NSSecureCoding: `HTTPCookie` isn't `Codable`, but its
/// `properties` dictionary archives cleanly, and `NSKeyedArchiver` is what the
/// Keychain store reads/writes. Security note for auditors: these cookies ARE
/// the bearer credential for the user's Amazon account — they live only in the
/// Keychain (see `KeychainAmazonSecretStore`) and are never logged or written to
/// disk in the clear.
public final class AmazonSessionSecrets: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let cookies: [HTTPCookie]

    public init(cookies: [HTTPCookie]) {
        self.cookies = cookies
    }

    public func encode(with coder: NSCoder) {
        let props = cookies.compactMap(\.properties)
        coder.encode(props as NSArray, forKey: "cookieProperties")
    }

    public required init?(coder: NSCoder) {
        let classes = [NSArray.self, NSDictionary.self, NSString.self, NSDate.self, NSURL.self]
        guard
            let raw = coder.decodeObject(of: classes, forKey: "cookieProperties")
                as? [[String: Any]]
        else {
            return nil
        }
        self.cookies = raw.compactMap { dict in
            HTTPCookie(
                properties: dict.reduce(into: [:]) { acc, kv in
                    acc[HTTPCookiePropertyKey(kv.key)] = kv.value
                })
        }
    }
}
