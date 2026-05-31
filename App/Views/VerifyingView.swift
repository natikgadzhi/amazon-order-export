import SwiftUI

/// Shown briefly after pressing Export while we confirm the stored Amazon session
/// is still good — before committing to the full export UI. If the session is
/// dead, the model jumps straight to the login sheet instead of here.
struct VerifyingView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Verifying session…").font(.title).bold()
      HStack(spacing: DS.Spacing.standard) {
        ProgressView().controlSize(.small)
        Text("Checking your Amazon sign-in.").foregroundStyle(.secondary)
      }
    }
    .screenLayout()
  }
}
