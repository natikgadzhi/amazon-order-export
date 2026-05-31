import SwiftUI

/// The whole "design system": a few spacing + sizing constants over system
/// fonts and colors. Deliberately tiny and self-contained — no external
/// dependency — so the look stays consistent without ceremony.
enum DS {
  enum Spacing {
    static let tight: CGFloat = 8
    static let standard: CGFloat = 16
    static let loose: CGFloat = 24
  }
  /// Max content width for the single window's screens.
  static let screenWidth: CGFloat = 520
  static let buttonHeight: CGFloat = 44
  static let cornerRadius: CGFloat = 10
}
