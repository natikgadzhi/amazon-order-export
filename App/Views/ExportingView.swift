import AmazonOrders
import SwiftUI

/// Live export progress: a spinner while finding orders, then a determinate bar
/// with each order sliding through as its details are crawled.
struct ExportingView: View {
  let progress: ExportProgress
  let cancel: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // Animate on a lightweight token, not the OrderSummary-carrying enum, so
    // SwiftUI doesn't deep-compare the items array on every progress tick.
    .animation(.smooth(duration: 0.3), value: animationKey)
  }

  /// Cheap identity for the animation — exactly what changes visibly each tick.
  private var animationKey: String {
    switch progress {
    case .fetchingOrders(let collected): "f\(collected)"
    case .crawlingDetails(let done, let total, let current):
      "c\(done)/\(total)/\(current?.id ?? "")"
    case .writingFiles: "w"
    }
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
          .accessibilityLabel("Export progress")
          .accessibilityValue("Order \(done) of \(total)")
        Text("Order \(done) of \(total)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .accessibilityHidden(true)  // the bar already announces this
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
  /// view and runs the transition. The slide is replaced by a plain crossfade
  /// when Reduce Motion is on.
  @ViewBuilder private func ticker(_ order: OrderSummary?) -> some View {
    ZStack(alignment: .leading) {
      if let order {
        OrderCard(order: order)
          .id(order.id)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
      }
    }
    // minHeight (not a fixed height) so the card isn't clipped at large Dynamic
    // Type sizes; clip keeps the horizontal slide tidy within the row.
    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    .clipped()
  }
}
