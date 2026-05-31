import AmazonAuth
import SwiftUI
import WebKit

/// Hosts the auth manager's login web view in SwiftUI.
struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
struct LoginWindowContent: View {
    let manager: AmazonAuthManager
    let onAuthenticated: () -> Void

    var body: some View {
        LoginWebView(webView: manager.loginWebView)
            .frame(minWidth: 480, minHeight: 720)
            .onChange(of: manager.state) { _, newValue in
                if newValue == .authenticated { onAuthenticated() }
            }
            .onAppear { manager.startLogin() }
    }
}
