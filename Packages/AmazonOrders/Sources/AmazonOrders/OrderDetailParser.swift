import Foundation
import SwiftSoup

/// Parses the `/your-orders/order-details` page into an `OrderDetail`.
///
/// This is the transactions-spine source: the charge breakdown, the card last-4,
/// and the `/cpe/yourpayments/transactions?transactionTag=…` link — the fields
/// that let an order be matched to a bank-statement line. The page is built from
/// `data-component="…"` blocks, which we key on rather than fragile class chains.
public enum OrderDetailParser {
  public static func parse(html: String) throws -> OrderDetail {
    let doc = try SwiftSoup.parse(html)
    let root = try doc.select(Sel.orderDetailsRoot).first() ?? doc.body() ?? doc

    let id = try text(root, component: "orderId")
    let placedRaw = try text(root, component: "orderDate")?
      .replacingOccurrences(of: "›", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let charges = try parseCharges(root)
    let grandTotal = charges.first { $0.label.lowercased().contains("grand total") }?.amount

    return OrderDetail(
      id: id, orderPlaced: placedRaw.flatMap(Parse.date), orderPlacedRaw: placedRaw,
      grandTotal: grandTotal, charges: charges, payment: try parsePayment(root),
      transactionsTag: try transactionsTag(root), items: try parseItems(root))
  }

  private static func parseCharges(_ root: Element) throws -> [ChargeLine] {
    try root.select(Sel.chargeRow).array().compactMap { row in
      guard
        let labelRaw = try row.firstText(Sel.chargeLabel),
        let valueRaw = try row.firstText(Sel.chargeContent)
      else { return nil }
      let label = labelRaw.trimmingCharacters(in: CharacterSet(charactersIn: ": \n"))
      return ChargeLine(label: label, amount: Money(valueRaw))
    }
  }

  private static func parsePayment(_ root: Element) throws -> PaymentInstrument? {
    guard let text = try root.firstText(Sel.paymentInstrumentRow) else { return nil }
    let condensed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return PaymentInstrument(description: condensed, lastFour: Parse.lastFour(in: condensed))
  }

  private static func transactionsTag(_ root: Element) throws -> String? {
    guard let href = try root.firstAttr(Sel.transactionsLink, "href") else { return nil }
    return Parse.queryValue("transactionTag", inHref: href)
  }

  private static func parseItems(_ root: Element) throws -> [OrderItem] {
    try root.select(Sel.component("purchasedItemsRightGrid")).array().map { grid in
      let titleLink = try grid.select("\(Sel.component("itemTitle")) a").first()
      let href = try titleLink?.attr("href")
      let soldBy = try grid.firstText(Sel.component("orderedMerchant"))?
        .replacingOccurrences(of: "Sold by: ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let price = try grid.firstText("\(Sel.component("unitPrice")) .a-offscreen")
        .map(Money.init)
      return OrderItem(
        asin: href.flatMap(Parse.asin(fromHref:)),
        title: try titleLink.map { try $0.text() },
        quantity: 1, unitPrice: price, soldBy: soldBy)
    }
  }

  private static func text(_ root: Element, component: String) throws -> String? {
    let trimmed = try root.firstText(Sel.component(component))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed : nil
  }
}
