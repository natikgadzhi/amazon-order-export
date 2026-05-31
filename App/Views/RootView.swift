import AmazonAuth
import SwiftUI

/// Switches the single window's content on the export phase, and presents the
/// login web view as a sheet while authenticating.
struct RootView: View {
  @Bindable var model: ExportModel

  var body: some View {
    content
      .sheet(isPresented: authenticatingBinding) {
        VStack(spacing: 0) {
          HStack {
            Spacer()
            Button("Cancel") { model.reset() }
              .padding(DS.Spacing.tight)
              .keyboardShortcut(.cancelAction)
              .accessibilityIdentifier("cancel-login")
          }
          LoginWindowContent(manager: model.authManager) {
            model.didAuthenticate()
          }
        }
      }
  }

  /// A settable binding so the user can dismiss the login sheet (Cancel / Escape),
  /// returning the model to idle instead of soft-locking on a hung login.
  private var authenticatingBinding: Binding<Bool> {
    Binding(get: { model.isAuthenticating }, set: { if !$0 { model.reset() } })
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .idle:
      IdleView(model: model)
    case .verifying:
      VerifyingView()
    case .authenticating:
      // The sheet is up; keep the idle screen behind it.
      IdleView(model: model)
    case .exporting(let progress):
      ExportingView(progress: progress) { model.cancel() }
    case .finished(let summary):
      FinishedView(summary: summary) { model.reset() }
    case .failed(let message, let canReauth):
      FailedView(message: message, canReauth: canReauth) {
        if canReauth { model.authenticateAndExport() } else { model.reset() }
      }
    }
  }
}
