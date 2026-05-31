import AmazonOrders
import SwiftUI

/// Progress while the crawl runs. Indeterminate while fetching the order list,
/// determinate while crawling detail pages.
struct ExportingView: View {
  let progress: ExportProgress
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Exporting…").font(.title).bold()
      switch progress {
      case .fetchingOrders(let collected):
        ProgressView("Fetching orders… \(collected)")
      case .crawlingDetails(let done, let total):
        ProgressView(value: Double(done), total: Double(max(total, 1))) {
          Text("Order \(done) of \(total)")
        }
      case .writingFiles:
        ProgressView("Writing CSV files…")
      }
      Button("Cancel", role: .cancel) { cancel() }
    }
    .screenLayout()
  }
}
