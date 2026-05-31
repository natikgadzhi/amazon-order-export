import AmazonAuth
import AmazonOrders
import WebKit
import os

/// Offscreen WKWebView that renders a logged-in Amazon page and hands back its
/// post-JavaScript HTML, so the `AmazonOrders` parsers see the same DOM a real
/// browser would (order pages are JS-rendered — plain URLSession returns a shell).
///
/// Seeds a fresh, non-persistent cookie store from the Keychain session, so a
/// headless run reuses the login without depending on any on-disk WebKit state.
@MainActor
final class OrderPageRenderer: NSObject, WKNavigationDelegate {
  private let webView: WKWebView
  private let log = Logger(subsystem: "io.respawn.AmazonOrderExport", category: "render")
  private var navigation: CheckedContinuation<Void, Error>?

  /// A recent Safari UA; the order pages serve a degraded/blocked experience to
  /// obviously-automated clients.
  private static let safariUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

  init(secrets: AmazonSessionSecrets) async {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    webView = WKWebView(
      frame: .init(x: 0, y: 0, width: 1280, height: 1600), configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.customUserAgent = Self.safariUA
    let store = config.websiteDataStore.httpCookieStore
    for cookie in secrets.cookies {
      await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        store.setCookie(cookie) { k.resume() }
      }
    }
  }

  /// Load `url`, wait for the page's JS to populate `readySelector`, and return
  /// `document.documentElement.outerHTML`. Throws `ExpiredSessionError` if Amazon
  /// bounced us to the sign-in page.
  func renderedHTML(url: URL, readySelector: String, timeout: Duration = .seconds(20))
    async throws -> String
  {
    log.info("render: \(url.absoluteString, privacy: .public)")
    try await load(url)

    if let current = webView.url, AmazonEndpoint.isSignInRedirect(current) {
      throw ExpiredSessionError()
    }

    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      let count =
        (try? await webView.evaluateJavaScript(
          "document.querySelectorAll('\(readySelector)').length") as? Int) ?? 0
      if count > 0 { break }
      try? await Task.sleep(for: .milliseconds(250))
    }

    let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
    return (html as? String) ?? ""
  }

  private func load(_ url: URL) async throws {
    // Not re-entrant: a second concurrent navigation would overwrite the first
    // continuation (the wrong caller gets resumed, the other hangs). Callers
    // render pages sequentially; make a violation a loud crash, not silent corruption.
    precondition(navigation == nil, "OrderPageRenderer.renderedHTML is not re-entrant")
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
      navigation = k
      webView.load(URLRequest(url: url))
    }
  }

  func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
    navigation?.resume()
    navigation = nil
  }

  func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    navigation?.resume(throwing: error)
    navigation = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
  ) {
    navigation?.resume(throwing: error)
    navigation = nil
  }
}

extension OrderPageRenderer: OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String {
    try await renderedHTML(url: url, readySelector: readySelector, timeout: .seconds(20))
  }
}
