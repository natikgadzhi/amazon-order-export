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
        // Fixed, compact size sized to fit the tallest (idle) screen, with content
        // pinned top-leading so every screen's heading sits in the same spot.
        // minHeight is a floor (grows for large Dynamic Type), not a fixed clip.
        .frame(
          minWidth: DS.screenWidth, maxWidth: DS.screenWidth, minHeight: 360,
          alignment: .topLeading)
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
