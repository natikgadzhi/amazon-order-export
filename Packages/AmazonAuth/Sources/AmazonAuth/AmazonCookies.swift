import Foundation

/// The cookies that, together, mark a fully signed-in amazon.com session.
///
/// Why these five: `at-main`/`sess-at-main` are the actual auth tokens, `x-main`
/// is the signed-in marker, and `session-id`/`ubid-main` keep us out of bot
/// interstitials. If any are missing, Amazon bounces us to `/ap/signin`. We only
/// persist a session once all five are present so a half-finished login can't be
/// mistaken for a good one.
public enum AmazonCookies: String, CaseIterable, Sendable {
  case sessionId = "session-id"
  case ubidMain = "ubid-main"
  case xMain = "x-main"
  case atMain = "at-main"
  case sessAtMain = "sess-at-main"

  public static let required: [AmazonCookies] = allCases

  public static func requiredCookiesPresent(in cookies: [HTTPCookie]) -> Bool {
    required.allSatisfy { req in cookies.contains { $0.name == req.rawValue } }
  }

  public static func missingRequiredNames(in cookies: [HTTPCookie]) -> [String] {
    required.compactMap { req in
      cookies.contains { $0.name == req.rawValue } ? nil : req.rawValue
    }
  }
}
