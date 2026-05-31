import Foundation

/// The handful of amazon.com URLs the auth layer touches.
public enum AmazonEndpoint: Sendable {
  case signIn
  case orders
  case account

  public var url: URL {
    switch self {
    case .signIn:
      return URL(string: "https://www.amazon.com/ap/signin")!
    case .orders:
      return URL(string: "https://www.amazon.com/your-orders/orders")!
    case .account:
      return URL(string: "https://www.amazon.com/gp/css/homepage.html")!
    }
  }

  /// True when a URL is Amazon's sign-in page. This is our expiry signal: an
  /// expired session loads fine (HTTP 200) but redirects to `/ap/signin`, so we
  /// classify on the final URL rather than the status code.
  public static func isSignInRedirect(_ url: URL) -> Bool {
    url.path().hasPrefix("/ap/signin")
  }
}
