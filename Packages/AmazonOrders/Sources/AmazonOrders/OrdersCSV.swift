import Foundation

/// Renders parsed orders to the two CSVs the user reconciles against:
/// `orders.csv` (one row per order — the bank-matching grain) and
/// `items.csv` (one row per line item — what Copilot categorizes).
///
/// Pure string-in/string-out so it's unit-tested without touching the disk.
public enum OrdersCSV {
  public static func ordersCSV(_ orders: [OrderSummary]) -> String {
    var rows = [
      [
        "order_id", "date_placed", "total_amount", "total_raw", "recipient", "item_count",
        "and_more",
      ]
    ]
    for o in orders {
      rows.append([
        o.id,
        o.orderPlaced.map(isoDay) ?? o.orderPlacedRaw,
        o.total?.amount.map { "\($0)" } ?? "",
        o.total?.raw ?? "",
        o.recipient ?? "",
        "\(o.items.count)",
        "\(o.andMoreCount)",
      ])
    }
    return table(rows)
  }

  public static func itemsCSV(_ orders: [OrderSummary]) -> String {
    var rows = [["order_id", "asin", "quantity", "title"]]
    for o in orders {
      for item in o.items {
        rows.append([o.id, item.asin ?? "", "\(item.quantity)", item.title ?? ""])
      }
    }
    return table(rows)
  }

  /// The bank-reconciliation spine: one row per order joining the list-page date
  /// to the detail-page grand total + card last-4 + `transactionTag`. Skips orders
  /// we didn't fetch a detail page for. Date comes from the matching `OrderSummary`.
  public static func transactionsCSV(orders: [OrderSummary], detailsByID: [String: OrderDetail])
    -> String
  {
    var rows = [
      [
        "order_id", "date_placed", "grand_total", "grand_total_raw", "card_last4",
        "transactions_tag",
      ]
    ]
    for o in orders {
      guard let d = detailsByID[o.id] else { continue }
      rows.append([
        o.id,
        o.orderPlaced.map(isoDay) ?? o.orderPlacedRaw,
        d.grandTotal?.amount.map { "\($0)" } ?? "",
        d.grandTotal?.raw ?? "",
        d.payment?.lastFour ?? "",
        d.transactionsTag ?? "",
      ])
    }
    return table(rows)
  }

  // MARK: - CSV mechanics

  private static func isoDay(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  private static func table(_ rows: [[String]]) -> String {
    rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
  }

  /// Quote a field iff it contains a comma, quote, or newline (RFC 4180).
  private static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
    else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
