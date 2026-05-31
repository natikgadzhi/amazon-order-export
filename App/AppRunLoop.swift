import AmazonAuth
import AppKit
import SwiftUI

/// Bridges the `authenticate` command to an AppKit run loop, because WKWebView
/// needs one. Only the GUI login needs this; `check` is plain HTTP.
enum AppRunLoop {
    /// Show the login window until authenticated, then quit.
    @MainActor
    static func runLogin(manager: AmazonAuthManager) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let hosting = NSHostingController(
            rootView: LoginWindowContent(manager: manager) {
                NSApplication.shared.terminate(nil)
            })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to Amazon"
        window.setContentSize(NSSize(width: 480, height: 720))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // Drive the load here (not via SwiftUI onAppear) so it's deterministic.
        manager.startLogin()
        app.run()
    }

    /// Run an async body inside an AppKit run loop with **no** UI (`.prohibited`),
    /// then quit. WKWebView's render process still needs a live run loop even when
    /// the view is offscreen, which is why `sync`/`dump-orders` can't be plain
    /// async commands the way `check` is.
    @MainActor
    static func runHeadless(_ body: @escaping @MainActor () async -> Void) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await body()
            NSApplication.shared.terminate(nil)
        }
        app.run()
    }
}
