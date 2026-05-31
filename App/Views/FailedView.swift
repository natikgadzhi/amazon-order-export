import SwiftUI

/// A failed export. Offers re-authentication when the session expired.
struct FailedView: View {
  let message: String
  let canReauth: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Export failed").font(.title).bold()
      Text(message).foregroundStyle(.secondary)
      Button(canReauth ? "Sign in again" : "Back", action: retry)
        .buttonStyle(PrimaryButtonStyle())
    }
    .screenLayout()
  }
}
