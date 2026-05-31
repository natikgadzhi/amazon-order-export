import Foundation

public enum AuthProbeResult: Sendable, Equatable {
  case valid
  case expired
  case noStoredSession
}

/// Headless session check for the `check` command.
///
/// Why plain URLSession (not WKWebView): whether the stored cookies are still
/// valid is decided by a server-side redirect to `/ap/signin`, which happens
/// before any JavaScript runs. So we don't need to render the (JS-heavy) orders
/// page — we just replay the cookies in an HTTP GET and see where we land. This
/// keeps `check` scriptable with no GUI/app-bundle requirement.
public enum AuthProbe {
  /// Pure: classify the final URL the request landed on.
  public static func classify(finalURL: URL) -> AuthProbeResult {
    AmazonEndpoint.isSignInRedirect(finalURL) ? .expired : .valid
  }

  public static func run(secretStore: any AmazonSecretStoring) async -> AuthProbeResult {
    guard let secrets = secretStore.read() else { return .noStoredSession }

    let config = URLSessionConfiguration.ephemeral
    for cookie in secrets.cookies {
      config.httpCookieStorage?.setCookie(cookie)
    }
    // A browser-like UA keeps Amazon from serving a degraded/blocking page.
    config.httpAdditionalHeaders = [
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ]
    let session = URLSession(configuration: config)

    do {
      // URLSession follows redirects by default, so response.url is the
      // final landing page — orders (valid) or /ap/signin (expired).
      let (_, response) = try await session.data(
        for: URLRequest(url: AmazonEndpoint.orders.url))
      return classify(finalURL: response.url ?? AmazonEndpoint.signIn.url)
    } catch {
      return .expired
    }
  }
}
