import AppKit

/// The app's About panel — the GUI equivalent of a CLI's `--help` overview.
///
/// Uses the standard macOS About panel (icon + name + version) enriched with a
/// description, a source link, and a feedback link via its credits field. That
/// keeps it visually consistent with every other Mac app while still saying what
/// *this* one is for. To reuse in a sibling app, change only `summary` + `repo`.
enum About {
  /// Per-app copy — the only thing that differs between apps.
  private static let summary = """
    Export your own Amazon order and transaction history to CSV, for reconciling \
    against bank transactions and budgeting (e.g. Copilot). Personal-data export \
    only — your own order history, on your own machine.
    """
  private static let repo = URL(string: "https://github.com/natikgadzhi/amazon-order-export")!

  static func showPanel() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits()])
  }

  private static func credits() -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.paragraphSpacing = 8
    let base: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: style,
    ]
    let text = NSMutableAttributedString(string: summary + "\n\n", attributes: base)
    text.append(linkRun("View source on GitHub", repo, base))
    text.append(NSAttributedString(string: "\n", attributes: base))
    text.append(NSAttributedString(string: "Found a bug or have an idea? ", attributes: base))
    text.append(linkRun("Open an issue", repo.appendingPathComponent("issues"), base))
    text.append(NSAttributedString(string: ".", attributes: base))
    return text
  }

  private static func linkRun(
    _ text: String, _ url: URL, _ base: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    var attrs = base
    attrs[.link] = url
    return NSAttributedString(string: text, attributes: attrs)
  }
}
