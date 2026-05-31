import AmazonOrders
import AppKit
import SwiftUI

/// Success: report the count and offer to reveal the files or run again.
struct FinishedView: View {
  let summary: ExportSummary
  let exportAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Done").font(.title).bold()
      Text("Exported \(summary.orderCount) orders to \(summary.outputDir.path).")
        .foregroundStyle(.secondary)
      HStack(spacing: DS.Spacing.standard) {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([
            summary.outputDir.appendingPathComponent("orders.csv")
          ])
        }
        .keyboardShortcut(.defaultAction)  // Return reveals the result
        .accessibilityIdentifier("reveal-in-finder")
        Button("Export Again", action: exportAgain)
          .accessibilityIdentifier("export-again")
      }
    }
    .screenLayout()
    .accessibilityIdentifier("finished-screen")
  }
}
