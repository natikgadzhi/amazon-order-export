import AmazonAuth
import AmazonOrders
import AppKit
import SwiftUI

/// The resting screen: pick a folder + range, then export.
struct IdleView: View {
  @Bindable var model: ExportModel

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      CrashReportingNotice()
      Text("Export your Amazon orders")
        .font(.title).bold()
      Text(
        "Choose a folder and a date range. Amazon Order Export signs you in, "
          + "then writes orders.csv, items.csv, and transactions.csv."
      )
      .foregroundStyle(.secondary)

      folderRow
      Picker("Range", selection: $model.range) {
        Text("Last 30 days").tag(TimeRange.last30)
        Text("Past 3 months").tag(TimeRange.months3)
        Text("This year").tag(TimeRange.year(Calendar.current.component(.year, from: Date())))
        Text("All time").tag(TimeRange.allTime)
      }
      .pickerStyle(.menu)
      .accessibilityLabel("Export date range")
      .accessibilityIdentifier("range-picker")

      Button(buttonTitle) { model.authenticateAndExport() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.outputDir == nil)
        .keyboardShortcut(.defaultAction)  // Return triggers Export
        .accessibilityIdentifier("export-button")
    }
    .screenLayout()
    .accessibilityIdentifier("idle-screen")
  }

  private var buttonTitle: String {
    model.authManager.state == .authenticated ? "Export" : "Sign in & Export"
  }

  private var folderRow: some View {
    HStack(spacing: DS.Spacing.tight) {
      Image(systemName: "folder").accessibilityHidden(true)
      Text(model.outputDir?.path ?? "No folder chosen")
        .foregroundStyle(model.outputDir == nil ? .secondary : .primary)
        .lineLimit(1).truncationMode(.middle)
        .accessibilityLabel("Output folder")
        .accessibilityValue(model.outputDir?.path ?? "None chosen")
        .accessibilityIdentifier("output-folder-path")
      Spacer()
      Button("Choose…") { chooseFolder() }
        .accessibilityLabel("Choose output folder")
        .accessibilityIdentifier("choose-folder")
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true  // shows the "New Folder" button
    panel.directoryURL = model.outputDir  // start where we'll export to
    if panel.runModal() == .OK, let url = panel.url {
      model.setOutputDir(url)
    }
  }
}
