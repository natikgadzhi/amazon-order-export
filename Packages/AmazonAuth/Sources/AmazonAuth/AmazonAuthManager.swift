import Foundation
import Observation
import WebKit
import os

/// Coordinates the interactive login: owns the `WKWebView` the user signs into,
/// and snapshots the session cookies once they're all present.
///
/// Why a real WebView instead of scripted HTTP: Amazon's login (and the order
/// pages we'll scrape later) are JS-rendered and defended against headless
/// clients, so we let a genuine browser do the OAuth/2FA dance and just read the
/// resulting cookies out of its cookie store.
@MainActor @Observable
public final class AmazonAuthManager: NSObject {
  private let secretStore: any AmazonSecretStoring
  private let log = Logger(subsystem: "io.respawn.AmazonOrderExport", category: "auth")

  public private(set) var state: AuthenticationState = .new
  public private(set) var secrets: AmazonSessionSecrets?

  private var webView: WKWebView?

  public init(secretStore: any AmazonSecretStoring) {
    self.secretStore = secretStore
    super.init()
  }

  /// The login web view; the caller embeds this in a window. Uses the default
  /// (persistent) data store on purpose so Amazon's "remember this device" can
  /// reduce repeat 2FA prompts.
  public var loginWebView: WKWebView {
    if let webView { return webView }
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.navigationDelegate = self
    webView.isInspectable = true
    self.webView = webView
    return webView
  }

  /// Start login by loading the orders page; Amazon redirects to sign-in if the
  /// user isn't authenticated yet.
  public func startLogin() {
    let url = AmazonEndpoint.orders.url
    log.info("startLogin: loading \(url.absoluteString, privacy: .public)")
    state = .authenticating
    loginWebView.load(URLRequest(url: url))
  }

  /// Single capture point — persists only when the full required cookie set is
  /// present. Pure (no WebView), so it's unit-testable.
  public func ingest(cookies: [HTTPCookie]) {
    guard AmazonCookies.requiredCookiesPresent(in: cookies) else { return }
    let secrets = AmazonSessionSecrets(cookies: cookies)
    secretStore.write(secrets: secrets)
    self.secrets = secrets
    state = .authenticated
  }

  public func initSessionFromSecureStorage() {
    guard let stored = secretStore.read(),
      AmazonCookies.requiredCookiesPresent(in: stored.cookies)
    else {
      state = .unauthenticated
      return
    }
    secrets = stored
    state = .authenticated
  }

  public func reset() {
    secretStore.clear()
    secrets = nil
    state = .unauthenticated
  }
}

extension AmazonAuthManager: WKNavigationDelegate {
  public func webView(
    _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    log.info("didStart: \(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    log.error("didFailProvisional: \(error.localizedDescription, privacy: .public)")
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    log.error("didFail: \(error.localizedDescription, privacy: .public)")
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    log.info("didFinish: \(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
  }

  /// The web content process crashing is the classic "blank page" cause — log it
  /// loudly so we can tell it apart from a network/navigation failure.
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    log.error("webContentProcessDidTerminate — WKWebView render process died")
  }

  /// After each navigation commit, peek at the cookie store; `ingest` no-ops
  /// until all required cookies have landed (post-2FA), then persists once.
  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    log.info("didCommit: \(webView.url?.absoluteString ?? "<nil>", privacy: .public)")
    guard state != .authenticated else { return }
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
      [weak self] cookies in
      self?.ingest(cookies: cookies)
    }
  }
}
