import AmazonAuth
import SwiftUI

/// The app: one window over an `ExportModel`. WKWebView (login + scraping) works
/// because a SwiftUI app already runs an AppKit run loop — no manual shim needed.
@main
struct AmazonOrderExportApp: App {
  @State private var model = ExportModel(
    authManager: AmazonAuthManager(secretStore: KeychainAmazonSecretStore()))

  var body: some Scene {
    Window("Amazon Order Export", id: "main") {
      RootView(model: model)
        // Fixed width; height hugs the current screen (windowResizability below),
        // so the window stays compact with no dead vertical space.
        .frame(width: DS.screenWidth)
    }
    .windowResizability(.contentSize)
    .commands {
      // Replace the stock About item with our branded panel.
      CommandGroup(replacing: .appInfo) {
        Button("About Amazon Order Export") { About.showPanel() }
      }
    }
  }
}
