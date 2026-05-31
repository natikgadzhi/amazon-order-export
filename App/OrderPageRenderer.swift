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
  private var navigationTimeout: Task<Void, Never>?

  /// A navigation that never reported back (a `-999` redirect that stalled, or a
  /// dead WebContent process) — surfaced so the caller fails one page instead of
  /// hanging the whole export.
  struct RenderTimeout: Error {}
  /// The WKWebView's WebContent helper process crashed mid-load.
  struct WebContentCrashed: Error {}

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
    try await load(url, timeout: timeout)

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

  private func load(_ url: URL, timeout: Duration) async throws {
    // Not re-entrant: a second concurrent navigation would overwrite the first
    // continuation (the wrong caller gets resumed, the other hangs). Callers
    // render pages sequentially; make a violation a loud crash, not silent corruption.
    precondition(navigation == nil, "OrderPageRenderer.renderedHTML is not re-entrant")
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
      navigation = k
      // Safety net: if no navigation callback ever fires (a stalled `-999`
      // redirect, or a dead WebContent process), fail this load rather than hang
      // the whole export. Cancelled the moment the navigation resolves normally.
      navigationTimeout = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.resumeNavigation(throwing: RenderTimeout())
      }
      webView.load(URLRequest(url: url))
    }
  }

  /// Resume the pending load continuation exactly once and cancel its timeout.
  /// Every caller runs on the main actor, so the nil-check is enough to prevent a
  /// double-resume (which would trap).
  private func resumeNavigation(throwing error: Error?) {
    navigationTimeout?.cancel()
    navigationTimeout = nil
    guard let k = navigation else { return }
    navigation = nil
    if let error { k.resume(throwing: error) } else { k.resume() }
  }

  func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
    resumeNavigation(throwing: nil)
  }

  func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    failUnlessSuperseded(error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
  ) {
    failUnlessSuperseded(error)
  }

  /// The WebContent helper process died mid-load (the log shows it being denied
  /// and respawned). Without this the load continuation would never resume.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    log.error("WebContent process terminated mid-render")
    resumeNavigation(throwing: WebContentCrashed())
  }

  /// A `-999` (`NSURLErrorCancelled`) means the navigation was superseded — almost
  /// always by a server or client-side redirect, which Amazon fires on the orders
  /// page right after a fresh sign-in. It is *not* a real failure: ignore it and
  /// let the redirect target's `didFinish` resume the original `load` (the load
  /// timeout still guards against a redirect that never completes). Only a genuine
  /// error fails the continuation.
  private func failUnlessSuperseded(_ error: Error) {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      log.info("navigation superseded (-999); waiting for the redirect to finish")
      return
    }
    resumeNavigation(throwing: error)
  }
}

extension OrderPageRenderer: OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String {
    try await renderedHTML(url: url, readySelector: readySelector, timeout: .seconds(20))
  }
}
