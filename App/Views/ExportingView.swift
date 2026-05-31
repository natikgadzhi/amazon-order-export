import AmazonOrders
import SwiftUI

/// Live export progress: a spinner while finding orders, then a determinate bar
/// with each order sliding through as its details are crawled.
struct ExportingView: View {
  let progress: ExportProgress
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text(title)
        .font(.title).bold()
        .contentTransition(.opacity)

      detail

      Button("Cancel", role: .cancel) { cancel() }
        .padding(.top, DS.Spacing.tight)
    }
    .screenLayout()
    // One animation drives everything: the title crossfade, the numeric
    // counters, and the order card sliding in/out as `progress` changes.
    .animation(.smooth(duration: 0.3), value: progress)
  }

  private var title: String {
    switch progress {
    case .fetchingOrders: return "Finding your orders…"
    case .crawlingDetails: return "Exporting orders…"
    case .writingFiles: return "Finishing up…"
    }
  }

  @ViewBuilder private var detail: some View {
    switch progress {
    case .fetchingOrders(let collected):
      HStack(spacing: DS.Spacing.standard) {
        ProgressView().controlSize(.small)
        Text("Found \(collected) order\(collected == 1 ? "" : "s")…")
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      }

    case .crawlingDetails(let done, let total, let current):
      VStack(alignment: .leading, spacing: DS.Spacing.standard) {
        ProgressView(value: Double(done), total: Double(max(total, 1)))
        Text("Order \(done) of \(total)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
        ticker(current)
      }

    case .writingFiles:
      HStack(spacing: DS.Spacing.standard) {
        ProgressView().controlSize(.small)
        Text("Writing CSV files…").foregroundStyle(.secondary)
      }
    }
  }

  /// The current order, sliding in from the trailing edge and out the leading
  /// edge as it changes. Re-keyed by order id so SwiftUI treats each as a new
  /// view and runs the transition.
  @ViewBuilder private func ticker(_ order: OrderSummary?) -> some View {
    ZStack(alignment: .leading) {
      if let order {
        OrderCard(order: order)
          .id(order.id)
          .transition(
            .asymmetric(
              insertion: .move(edge: .trailing).combined(with: .opacity),
              removal: .move(edge: .leading).combined(with: .opacity)))
      }
    }
    .frame(height: 60)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
  }
}
