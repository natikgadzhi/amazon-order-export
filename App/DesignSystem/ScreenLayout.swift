import SwiftUI

/// Consistent screen chrome: left-aligned column, capped width, generous padding.
struct ScreenLayout: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: DS.screenWidth, alignment: .leading)
      .padding(DS.Spacing.loose)
  }
}

extension View {
  func screenLayout() -> some View { modifier(ScreenLayout()) }
}
