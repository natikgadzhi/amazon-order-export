import SwiftUI

/// Preferences (Cmd-,): the crash-reporting opt-out.
struct SettingsView: View {
  @AppStorage(Telemetry.enabledKey) private var crashReportsEnabled = true

  var body: some View {
    Form {
      Toggle("Send anonymous crash reports", isOn: $crashReportsEnabled)
        .accessibilityIdentifier("crash-reports-toggle")
      Text(
        "Crash traces only — your orders and Amazon cookies never leave your Mac. "
          + "Quit and reopen Amazon Order Export for a change to take effect."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(DS.Spacing.loose)
    .frame(width: 420)
    .accessibilityIdentifier("settings-screen")
  }
}
