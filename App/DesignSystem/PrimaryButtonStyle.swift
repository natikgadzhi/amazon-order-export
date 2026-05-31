import SwiftUI

/// The prominent call-to-action button: full-width, accent-filled, rounded.
struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.bold())
      .frame(maxWidth: .infinity)
      .frame(height: DS.buttonHeight)
      .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
      .foregroundStyle(.white)
      .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous))
  }
}
