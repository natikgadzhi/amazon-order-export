import AmazonOrders
import SwiftUI

/// A compact card for one order — the thing that slides through the export
/// progress view as each order's details are fetched.
struct OrderCard: View {
  let order: OrderSummary

  var body: some View {
    HStack(spacing: DS.Spacing.standard) {
      Image(systemName: "shippingbox.fill")
        .font(.title2)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)  // decorative
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: DS.Spacing.standard)
      if let total = order.total?.raw {
        Text(total)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(DS.Spacing.standard)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .quaternary, in: RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// One spoken phrase for the whole card, so VoiceOver doesn't read it as
  /// three disconnected fragments.
  private var accessibilityLabel: String {
    var parts = [title, subtitle]
    if let total = order.total?.raw { parts.append(total) }
    return parts.joined(separator: ", ")
  }

  /// Prefer the first item's title; fall back to a short order number.
  private var title: String {
    if let itemTitle = order.items.first?.title, !itemTitle.isEmpty { return itemTitle }
    return "Order \(order.id)"
  }

  private var subtitle: String {
    let count = order.items.count
    let items = "\(count) item\(count == 1 ? "" : "s")"
    return order.orderPlacedRaw.isEmpty ? items : "\(order.orderPlacedRaw) · \(items)"
  }
}
