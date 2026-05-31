import SwiftUI

/// One-time, dismissible disclosure that crash reporting is on (opt-out).
struct CrashReportingNotice: View {
  @AppStorage("telemetry.firstRunNoticeSeen") private var seen = false

  var body: some View {
    if !seen && Telemetry.isEnabled {
      HStack(alignment: .top, spacing: DS.Spacing.standard) {
        Image(systemName: "info.circle").foregroundStyle(.secondary)
        Text(
          "Crash reports are on. No orders or cookies ever leave your Mac. "
            + "Turn off in Settings (⌘,)."
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)  // wrap, don't truncate
        Spacer(minLength: DS.Spacing.tight)
        Button("Got it") { seen = true }
      }
      .padding(DS.Spacing.standard)
      .background(
        .quaternary, in: RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
      )
      .accessibilityIdentifier("crash-reporting-notice")
    }
  }
}
