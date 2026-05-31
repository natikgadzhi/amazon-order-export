import AmazonAuth
import AppKit
import SwiftUI

/// Bridges swift-argument-parser commands to an AppKit run loop, because
/// WKWebView needs one even when we never show a window.
enum AppRunLoop {
    /// Windowed mode (`.regular`): show the login window until authenticated, then quit.
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
        app.run()
    }

    /// Headless mode (`.prohibited`): no Dock icon, no window. Run async work,
    /// then exit with its status code.
    @MainActor
    static func runHeadless(_ work: @escaping @MainActor () async -> Int32) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            let code = await work()
            exit(code)
        }
        app.run()
    }
}
