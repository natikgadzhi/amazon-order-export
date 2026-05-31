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
        .frame(minWidth: DS.screenWidth, minHeight: 420)
    }
    .windowResizability(.contentSize)
  }
}
