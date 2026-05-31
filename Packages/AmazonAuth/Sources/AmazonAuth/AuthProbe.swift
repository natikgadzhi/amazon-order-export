import Foundation
import WebKit

public enum AuthProbeResult: Sendable, Equatable {
    case valid
    case expired
    case noStoredSession
}

/// Headless session check for the `check` command. Seeds an offscreen WebView
/// with the stored cookies, loads the orders page, and sees where it lands.
public enum AuthProbe {
    /// Pure: classify the final URL of the probe navigation.
    public static func classify(finalURL: URL) -> AuthProbeResult {
        AmazonEndpoint.isSignInRedirect(finalURL) ? .expired : .valid
    }

    @MainActor
    public static func run(secretStore: any AmazonSecretStoring) async -> AuthProbeResult {
        guard let secrets = secretStore.read() else { return .noStoredSession }

        // Non-persistent store: this is a throwaway probe, so we don't want the
        // seeded credential cookies leaking into any on-disk WebKit storage.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        for cookie in secrets.cookies {
            await cookieStore.setCookie(cookie)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let driver = NavigationProbeDriver()
        webView.navigationDelegate = driver
        let finalURL = await driver.load(AmazonEndpoint.orders.url, in: webView)
        return classify(finalURL: finalURL)
    }
}

/// Drives one navigation and resolves with the final URL.
@MainActor
private final class NavigationProbeDriver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<URL, Never>?

    func load(_ url: URL, in webView: WKWebView) async -> URL {
        await withCheckedContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: webView.url ?? AmazonEndpoint.orders.url)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Treat a failed load as expired-ish; the user can re-auth.
        continuation?.resume(returning: webView.url ?? AmazonEndpoint.signIn.url)
        continuation = nil
    }
}
